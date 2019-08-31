jwt = require 'jsonwebtoken'
{WebClient} = require "@slack/client"

appId = process.env.HUBOT_GITHUB_APP_ID
privateKey = process.env.HUBOT_GITHUB_APP_PRIVATE_KEY

# FIXME: hardcoded config
installId = 1731296
repository = 'ouroboros8/test'

errorResponse = (res, error) ->
  res.send("""
    :boom: sorry <@#{res.envelope.user.id}>, #{error}.
    Please report this to <@#{maintainer_id}>.
  """)

wrongStatusResponse = (res) ->
  errorResponse(
    res, "an unexpected status code #{response.statusCode} was returned while creating your issue."
  )

attributeTo = (user, body) ->
  attribution = "From slack user #{user}"
  body.concat("\n\n", attribution)

newIssue = (res) ->
  lines = res.match[1].split('\n')
  title = lines.shift()
  body = attributeTo(
    res.envelope.user.real_name,
    lines.join('\n').trim()
  )
  JSON.stringify({
    title: title,
    body: body
  })

new_jwt = ->
  now = Math.floor(Date.now() / 1000)
  claims = {iat: now, exp: now + 30, iss: appId}
  jwt.sign(claims, privateKey, { algorithm: 'RS256' })

addToWatchlist = (robot, thread_ts, issue_url) ->
  watchList = getWatchList(robot)
  watchList[thread_ts] = issue_url
  robot.brain.set('watchList', watchList)

getWatchList = (robot) ->
  robot.brain.get('watchList') or {}

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
      .post() (err, response, body) ->
        if err
          res.send(":boom: error authenticating App: #{err}")
          errorResponse(res, "an error ocurred while attempting to generate a jwt token")
        else if response.statusCode isnt 201
          wrongStatusResponse(res)
        else
          accessToken = JSON.parse(body)
          robot.logger.info("New access token expires in #{accessToken.expires_at}")
          robot.brain.set('accessToken', accessToken)
          callback(accessToken.token)

module.exports = (robot) ->

  robot.hear /!bug ([\s\S]+)/i, (res) ->
    res.message.thread_ts = res.message.rawMessage.ts # thread all responses
    with_access_token robot, res, (accessToken) ->
      issue = newIssue(res)
      robot.logger.debug("Reporting issue: #{issue}")
      robot.http("https://api.github.com/repos/#{repository}/issues")
        .header('Authorization', "Bearer #{accessToken}")
        .post(issue) (err, response, body) ->
          if err?
            errorResponse(res, "an error ocurred while attempting to create the issue")
          else if response.statusCode isnt 201
            wrongStatusResponse(res)
          else
            {html_url, url} = JSON.parse(body)
            res.send(
              """
              Thanks <@#{res.envelope.user.id}>, I've raised your issue here: #{html_url}
              If you'd like to add anything please add additional comments below.
              """
            )
            addToWatchlist(robot, res.message.thread_ts, url)

  robot.hear /.*/i, (res) ->
    console.log('Huh? What?')
    thread = res.message.thread_ts
    if thread?
      console.log("Ooh thread: #{thread}")
      console.log(getWatchList(robot))
      issue_url = getWatchList(robot)[thread]
      if issue_url?
        robot.logger.info("Got a message relating to #{issue_url} in #{thread}")
        with_access_token robot, res, (accessToken) ->
          comment = attributeTo(res.envelope.user.real_name, res.match[0])
          console.log(comment)
