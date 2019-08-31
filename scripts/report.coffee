jwt = require 'jsonwebtoken'

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

newIssue = (res) ->
  lines = res.match[1].split('\n')
  title = lines.shift()
  user_body = lines.trim().join('\n')
  attribution = "Issue reported by slack user #{res.envelope.user.real_name}"
  body = [user_body, attribution].join('\n\n')
  JSON.stringify({title, body})

new_jwt = ->
  now = Math.floor(Date.now() / 1000)
  claims = {iat: now, exp: now + 30, iss: appId}
  jwt.sign(claims, privateKey, { algorithm: 'RS256' })

with_access_token = (robot, res, callback) ->
  accessToken = robot.brain.get('accessToken')
  if accessToken? and (new Date(accessToken.expires_at) > new Date)
    robot.logger.info("Reusing access token with expiry #{accessToken.expires_at}")
    callback(accessToken.token)
  else
    robot.logger.info("Generating a new access token")
    jwt = new_jwt()
    robot.http("https://api.github.com/app/installations/#{installId}/access_tokens")
      .header('Accept', 'application/vnd.github.machine-man-preview+json')
      .header('Authorization', "Bearer #{jwt}")
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

  robot.respond /report ([\s\S]+)/i, (res) ->
    with_access_token(robot, res, (accessToken) ->
      issue = newIssue(res)
      robot.logger.info("Reporting issue: #{issue}")
      robot.http("https://api.github.com/repos/#{repository}/issues")
        .header('Authorization', "Bearer #{accessToken}")
        .post(issue) (err, response, body) ->
          if err?
            errorResponse(res, "an error ocurred while attempting to create the issue")
          else if response.statusCode isnt 201
            wrongStatusResponse(res)
          else
            issue_url = JSON.parse(body).html_url
            res.send(
              """
              Thanks <@#{res.envelope.user.id}>, I've raised your issue here: #{issue_url}
              If you'd like to add anything please thread additional comments below.
              """
            )
    )
    # report robot, res
