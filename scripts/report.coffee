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

newIssue = (res) ->
  lines = res.match[1].split('\n')
  title = lines.shift()
  body = attributeTo(res.envelope.user.real_name, lines.join('\n').trim())
  JSON.stringify({
    title: title,
    body: body
  })

newComment = (res) ->
  JSON.stringify({
    body: attributeTo(res.envelope.user.real_name, res.match[1].trim())
  })

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

uploadFiles = (res) ->
  res.message.rawMessage.files.map (file) ->
    axios.get(file.url_private, {
      headers: {'Authorization': "Bearer #{robot.adapter.options.token}"}
      responseType: 'stream'
    }).then (response) ->
      fileNameParts = file.name.split('.')
      ext = file.name.split('.').pop()
      if ext != file.name
        objectKey += '.' + ext
      params =
        ACL: 'public-read'
        Body: response.data
        Bucket: 'chopshots'
        Key: objectKey
        ContentType: file.mimetype
      console.log('generated params')
      s3.upload params, (err, data) ->
        console.log('uploaded or err')
        if err
          constructError(robot, res, err, "an error occurred", "uploading #{file.name} to S3")
        else
          console.log("uploaded #{objectKey}")
          # console.log(data)
    .catch (err) ->
      console.log(err)

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
  s3 = new S3()

  robot.hear /!bug ([\s\S]+)/i, (res) ->
    thread_response(res)
    if not res.message.thread_ts?
      with_access_token robot, res, (accessToken) ->
        issue = newIssue(res)
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
    thread_response(res)
    thread = res.message.thread_ts
    if thread?
      issue = getWatchList(robot)[thread]
      if issue?
        robot.logger.info("Got a message relating to issue ##{issue.number} in thread #{thread}")
        web.reactions.add
          name: "speech_balloon"
          channel: res.message.room
          timestamp: res.message.id
        with_access_token robot, res, (accessToken) ->
          comment = newComment(res)
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

  robot.hear /([\s\S]*)/i, (res) ->
    thread_response(res)
    if res.message.rawMessage.files?
      console.log('processing file')
      uploadFiles res
