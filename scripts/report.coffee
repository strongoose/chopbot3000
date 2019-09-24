# Description:
#   This script allows Slack users to raise issues on a GitHub repository through Slack.
#
# Dependencies:
#    "@slack/client": "^5.0.2",
#    "aws-sdk": "^2.521.0",
#    "axios": "^0.19.0",
#    "hubot": "^3.3.2",
#    "hubot-diagnostics": "^1.0.0",
#    "hubot-google-images": "^0.2.7",
#    "hubot-google-translate": "^0.2.1",
#    "hubot-help": "^1.0.1",
#    "hubot-heroku-keepalive": "^1.0.3",
#    "hubot-maps": "0.0.3",
#    "hubot-pugme": "^0.1.1",
#    "hubot-redis-brain": "^1.0.0",
#    "hubot-rules": "^1.0.0",
#    "hubot-scripts": "^2.17.2",
#    "hubot-shipit": "^0.2.1",
#    "hubot-slack": "^4.7.1",
#    "jsonwebtoken": "^8.5.1",
#    "uuid": "^3.3.3",
#    "ws": ">=3.3.1"
#
# Configuration:
#   HUBOT_GITHUB_APP_ID
#   HUBOT_GITHUB_APP_PRIVATE_KEY
#   HUBOT_GITHUB_APP_INSTALL_ID
#   HUBOT_GITHUB_REPOSITORY
#   HUBOT_SLACK_TOKEN
#   HUBOT_SLACK_MAINTAINER_ID
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#
# Commands:
#   !bug <bug report> - Raises an issue with title set to the first line of the
#                       message with further lines added to the issue body. Threaded
#                       messages will be added to the issue as comments. Files in the
#                       issue or comments will be added as markdown images.
#
# Author:
#   ouroboros8

jwt = require 'jsonwebtoken'
{WebClient} = require "@slack/client"
S3 = require('aws-sdk/clients/s3')
uuid = require('uuid/v4')
axios = require('axios')

appId = process.env.HUBOT_GITHUB_APP_ID
privateKey = process.env.HUBOT_GITHUB_APP_PRIVATE_KEY
maintainer_id = process.env.HUBOT_SLACK_MAINTAINER_ID
repository = process.env.HUBOT_GITHUB_REPOSITORY
installId = process.env.HUBOT_GITHUB_APP_INSTALL_ID

fileBucketName = "chopshots"
fileBucketUrl = "https://#{fileBucketName}.s3.eu-west-2.amazonaws.com"

s3 = new S3()

fileExt = (filename) ->
  parts = filename.split('.')

capitalize = (string) ->
  string.charAt(0).toUpperCase() + string.slice(1)

constructError = (robot, res, err, errMsg, contextMsg) ->
  friendlyMessage = "#{errMsg} while #{contextMsg}"
  logMessage = capitalize(friendlyMessage).concat(":\n#{err}")
  slackMessage = """
    :boom: sorry <@#{res.envelope.user.id}>, #{friendlyMessage}.
    Please report this to <@#{maintainer_id}>.
  """
  robot.logger.error(logMessage)
  res.send(slackMessage)

attributeTo = (user, body) ->
  attribution = "\n\n*-- reported on slack by #{user}.*"
  body.concat("\n\n", attribution)

newIssueJson = (res, file_urls) ->
  lines = res.match[1].split('\n')
  title = lines.shift() #FIXME this is undocumented and should be clarified
  file_links = file_urls.map markdownFile
  lines_with_files = lines.concat(file_links).join('\n').trim()
  JSON.stringify({
    title: title,
    body: attributeTo(res.envelope.user.real_name, lines_with_files)
  })

newCommentJson = (res, file_urls) ->
  file_links = file_urls.map markdownFile
  comment_with_files = [res.match[1]].concat(file_links).join('\n').trim()
  JSON.stringify({
    body: attributeTo(res.envelope.user.real_name, comment_with_files)
  })

markdownFile = (file_url) ->
  "![](#{file_url})"

new_jwt = ->
  now = Math.floor(Date.now() / 1000)
  claims = {iat: now, exp: now + 30, iss: appId}
  jwt.sign(claims, privateKey, { algorithm: 'RS256' })

addToWatchlist = (robot, thread_ts, issue) ->
  watchList = getWatchList(robot)
  watchList[thread_ts] = issue
  robot.brain.set('watchList', watchList)

getWatchList = (robot) ->
  robot.brain.get('watchList') or {}

thread_response = (res) ->
  res.message.thread_ts = res.message.rawMessage.ts

withErrorHandling = (robot, res, contextMsg, fn) ->
  (err, response, body) ->
    if err
      constructError(robot, res, err, "an HTTP error occurred", contextMsg)
    else if response.statusCode >= 299
      constructError(robot, res, body, "an unexpected status code #{response.statusCode} was returned", contextMsg)
    else
      fn(err, response, body)

storeFile = (sourceUrl, slackToken, mimetype) ->
  storageKey = uuid()
  axios.get(sourceUrl, {
    headers: {'Authorization': "Bearer #{slackToken}"}
    responseType: 'stream'
  }).then (response) ->
    params =
      ACL: 'public-read'
      Body: response.data
      Bucket: fileBucketName
      Key: storageKey
      ContentType: mimetype
    s3.upload params, (err, data) ->
      if err
        console.log("Error uploading files to s3: #{err}") #FIXME bad error handling
  .catch (err) ->
    console.log("Error fetching files from Slack: #{err}") #FIXME bad error handling
  "#{fileBucketUrl}/#{storageKey}"

storeFiles = (robot, res) ->
  files = res.message.rawMessage.files
  if files?
    files.map (file) ->
      storeFile(file.url_private, robot.adapter.options.token, file.mimetype)
  else
    []

with_access_token = (robot, res, callback) ->
  accessToken = robot.brain.get('accessToken')
  if accessToken? and (new Date(accessToken.expires_at) > new Date)
    robot.logger.info("Reusing access token with expiry #{accessToken.expires_at}")
    callback(accessToken.token)
  else
    robot.logger.info("Generating a new access token")
    app_token = new_jwt()
    robot.http("https://api.github.com/app/installations/#{installId}/access_tokens")
      .header('Accept', 'application/vnd.github.machine-man-preview+json')
      .header('Authorization', "Bearer #{app_token}")
      .post() withErrorHandling robot, res, "generating an access token", (err, response, body) ->
        accessToken = JSON.parse(body)
        robot.logger.info("New access token expires in #{accessToken.expires_at}")
        robot.brain.set('accessToken', accessToken)
        callback(accessToken.token)

module.exports = (robot) ->
  web = new WebClient robot.adapter.options.token

  robot.hear /!bug ([\s\S]+)/i, (res) ->
    if not res.message.thread_ts?
      robot.logger.debug("Heard a new bug report")
      thread_response(res)
      with_access_token robot, res, (accessToken) ->
        file_urls = storeFiles(robot, res)
        issue = newIssueJson(res, file_urls)
        robot.logger.debug("Reporting issue: #{issue}")
        robot.http("https://api.github.com/repos/#{repository}/issues")
          .header('Authorization', "Bearer #{accessToken}")
          .post(issue) withErrorHandling robot, res, "creating the issue", (err, response, body) ->
            issue = JSON.parse(body)
            res.send(
              """
              Thanks <@#{res.envelope.user.id}>, I've raised your issue here: #{issue.html_url}
              If you'd like to add anything please add additional comments below.
              """
            )
            addToWatchlist(robot, res.message.thread_ts, issue)

  robot.hear /([\s\S]+)/i, (res) ->
    thread = res.message.thread_ts
    if thread?
      issue = getWatchList(robot)[thread]
      if issue?
        robot.logger.debug("Got a message relating to issue ##{issue.number} in thread #{thread}")
        thread_response(res)
        web.reactions.add
          name: "speech_balloon"
          channel: res.message.room
          timestamp: res.message.id
        with_access_token robot, res, (accessToken) ->
          file_urls = storeFiles(robot, res)
          comment = newCommentJson(res, file_urls)
          robot.logger.debug("Adding a comment to issue #{issue.number}")
          robot.http(issue.comments_url)
            .header('Authorization', "Bearer #{accessToken}")
            .post(comment) withErrorHandling robot, res, "adding a comment to issue #{issue.number}", (err, response, body) ->
              web.reactions.remove
                name: "speech_balloon"
                channel: res.message.room
                timestamp: res.message.id
              web.reactions.add
                name: "heavy_check_mark"
                channel: res.message.room
                timestamp: res.message.id
