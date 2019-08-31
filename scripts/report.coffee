jwt = require 'jsonwebtoken'
{WebClient} = require "@slack/client"

appId = process.env.HUBOT_GITHUB_APP_ID
privateKey = process.env.HUBOT_GITHUB_APP_PRIVATE_KEY

maintainer_id = 'UG4KE3QRH'

# FIXME: hardcoded config
installId = 1731296
repository = 'ouroboros8/test'

errorResponse = (res, error) ->
  res.send("""
    :boom: sorry <@#{res.envelope.user.id}>, #{error}.
    Please report this to <@#{maintainer_id}>.
  """)

wrongStatusResponse = (res, statusCode) ->
  errorResponse(
    res, "an unexpected status code #{statusCode} was returned."
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

addToWatchlist = (robot, thread_ts, comments_url) ->
  watchList = getWatchList(robot)
  watchList[thread_ts] = comments_url
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
          robot.logger.error("An HTTP error ocurred while attempting to generate an access token:\n #{err}")
          errorResponse(res, "an error ocurred while attempting to generate a jwt token")
        else if response.statusCode isnt 201
          robot.logger.error("Unexpected statue code #{response.statusCode} while attempting to generate an access token:\n#{body}")
          wrongStatusResponse(res, response.statusCode)
        else
          accessToken = JSON.parse(body)
          robot.logger.info("New access token expires in #{accessToken.expires_at}")
          robot.brain.set('accessToken', accessToken)
          callback(accessToken.token)

module.exports = (robot) ->
  web = new WebClient robot.adapter.options.token

  robot.hear /!bug ([\s\S]+)/i, (res) ->
    res.message.thread_ts = res.message.rawMessage.ts # thread all responses
    with_access_token robot, res, (accessToken) ->
      issue = newIssue(res)
      robot.logger.debug("Reporting issue: #{issue}")
      robot.http("https://api.github.com/repos/#{repository}/issues")
        .header('Authorization', "Bearer #{accessToken}")
        .post(issue) (err, response, body) ->
          if err?
            robot.logger.error("An HTTP error ocurred while attempting to create the issue:\n #{err}")
            errorResponse(res, "an error ocurred while attempting to create the issue")
          else if response.statusCode isnt 201
            robot.logger.error("Unexpected statue code #{response.statusCode} while creating an issue:\n#{body}")
            wrongStatusResponse(res, response.statusCode)
          else
            {html_url, comments_url} = JSON.parse(body)
            res.send(
              """
              Thanks <@#{res.envelope.user.id}>, I've raised your issue here: #{html_url}
              If you'd like to add anything please add additional comments below.
              """
            )
            addToWatchlist(robot, res.message.thread_ts, comments_url)

  robot.hear /.*/i, (res) ->
    thread = res.message.thread_ts
    if thread?
      comments_url = getWatchList(robot)[thread]
      if comments_url?
        robot.logger.info("Got a message relating to #{comments_url} in #{thread}")
        res.message.thread_ts = res.message.rawMessage.ts # thread all responses
        web.reactions.add
          name: "speech_balloon"
          channel: res.message.room
          timestamp: res.message.id
        with_access_token robot, res, (accessToken) ->
          comment = JSON.stringify({
            body: attributeTo(res.envelope.user.real_name, res.match[0])
          })
          robot.http(comments_url)
            .header('Authorization', "Bearer #{accessToken}")
            .post(comment) (err, response, body) ->
              if err?
                robot.logger.error("An HTTP error ocurred while attempting to create the issue:\n #{err}")
                errorResponse(res, "an error ocurred while attempting to post your comment")
              else if response.statusCode isnt 201
                robot.logger.error("Unexpected statue code #{response.statusCode} while posting a comment:\n#{body}")
                wrongStatusResponse(res, response.statusCode)
              else
                web.reactions.remove
                  name: "speech_balloon"
                  channel: res.message.room
                  timestamp: res.message.id
                web.reactions.add
                  name: "heavy_check_mark"
                  channel: res.message.room
                  timestamp: res.message.id
