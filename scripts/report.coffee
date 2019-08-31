jwt = require 'jsonwebtoken'

appId = process.env.HUBOT_GITHUB_APP_ID
privateKey = process.env.HUBOT_GITHUB_APP_PRIVATE_KEY

# FIXME: hardcoded config
installId = 1731296
repository = 'ouroboros8/test'

# Basic flow will be:
#   1. If we need a new access token
#     a. get a JWT
#     a. use it to get an access token
#     - Will start out by just getting a new token every time, should probably
#       put this in hubot's brain later?
#   2. Use access token to raise an issue
#   3. Report issue with URL to slack

report = (robot, res) ->
  now = Math.floor(Date.now() / 1000)
  claims = {
    iat: now
    exp: now + 30,
    iss: appId
  }
  app_token = jwt.sign(claims, privateKey, { algorithm: 'RS256' })
  console.log(app_token)
  robot.http("https://api.github.com/app/installations/#{installId}/access_tokens")
    .header('Accept', 'application/vnd.github.machine-man-preview+json')
    .header('Authorization', "Bearer #{app_token}")
    .post() (err, response, body) ->
      if err
        res.send ":boom: error authenticating App: #{err}"
      else
        console.log(body)
        installation_token = JSON.parse(body).token
        issue = JSON.stringify({
          title: res.match[1]
          body: 'TODO: have bodies?' # FIXME
        })
        robot.http("https://api.github.com/repos/#{repository}/issues")
          .header('Authorization', "Bearer #{installation_token}")
          .post(issue) (err, response, body) ->
            if err
              res.send ":boom: error creating issue: #{err}"
            else
              issue_url = JSON.parse(body).html_url
              res.send "Thanks #{res.envelope.user.name}, I've raised your issue here: #{issue_url}"

module.exports = (robot) ->

  robot.respond /report (.*)/i, (res) ->
    report robot, res
