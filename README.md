# Chop Bot 3000

Chop Bot 3000 is a chat bot built on the [Hubot][hubot] framework. It listens
in on a Slack channel for bug reports, and then raises them as GitHub issues on
a given repository. It was designed to act as a method for users on the
[Stimhack](https://stimhack.com) Slack to raise issues for the [jinteki.net
project](https://github.com/mtgred/netrunner) without having to create a user
on GitHub.

### Requirements

In order to run Chop Bot 3000 you need
 - A Slack app, which will listen in on one or several Slack channels for issues
 - A GitHub app, which will create and update issues Chop Bot is told about
 - A publicly readable S3 bucket, in which Chop Bot will store files uploaded through slack

Additionally, Redis can be used as persistant storage; persistance is required
to keep track of mappings from Slack threads to GitHub issues.

### Running Chop Bot 3000 Locally

In order to interface correctly with Slack and GitHub, Chop Bot 3000
requires the following environment variables to be set at run-time:
  - `HUBOT_GITHUB_APP_ID`: the ID of your GitHub app, generated when you create the app with GitHub
  - `HUBOT_GITHUB_APP_PRIVATE_KEY`: the private key used by Chop Bot to authenticate as your GitHub app
  - `HUBOT_GITHUB_APP_INSTALL_ID`: the "install ID" of your GitHub app for the repo you want to allow Slack users to comment on (this can be obtained via the [GitHub API](https://developer.github.com/v3/apps/installations/#list-installations-for-a-user))
  - `HUBOT_GITHUB_REPOSITORY`: the name of the repository you want to raise issues for, e.g. `ouroboros8/chopbot3000`
  - `HUBOT_SLACK_TOKEN`: the token used by Chop Bot to authenticate as your Slack app (generated when you create a Slack app)
  - `HUBOT_SLACK_MAINTAINER_ID`: your Slack Member ID (obtained under your user profile in the menu to the right of Edit Profile); this is used to tell people who to contact if Chop Bot throws an error.

Additionally you will need to provide AWS credentials so that the AWS node SDK
can read/write the S3 bucket; the easiest way is to create an IAM user for Chop
Bot, give it access to your bucket, and provide `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY_ID` as environment variables.

Once you've set these environment variables you can start Chop Bot 3000 with

    % bin/hubot -a slack

##  Persistence

If you are going to use the `hubot-redis-brain` package (strongly suggested),
you will need to add the Redis to Go addon on Heroku which requires a verified
account or you can create an account at [Redis to Go][redistogo] and manually
set the `REDISTOGO_URL` variable.

    % heroku config:add REDISTOGO_URL="..."

If you don't need any persistence feel free to remove the `hubot-redis-brain`
from `external-scripts.json` and you don't need to worry about redis at all.

[redistogo]: https://redistogo.com/

## Deployment

    % heroku create --stack cedar
    % git push heroku master

If your Heroku account has been verified you can run the following to enable
and add the Redis to Go addon to your app.

    % heroku addons:add redistogo:nano

If you run into any problems, checkout Heroku's [docs][heroku-node-docs].

You'll need to edit the `Procfile` to set the name of your hubot.

More detailed documentation can be found on the [deploying hubot onto
Heroku][deploy-heroku] wiki page.

### Deploying to UNIX or Windows

If you would like to deploy to either a UNIX operating system or Windows.
Please check out the [deploying hubot onto UNIX][deploy-unix] and [deploying
hubot onto Windows][deploy-windows] wiki pages.

[heroku-node-docs]: http://devcenter.heroku.com/articles/node-js
[deploy-heroku]: https://github.com/github/hubot/blob/master/docs/deploying/heroku.md
[deploy-unix]: https://github.com/github/hubot/blob/master/docs/deploying/unix.md
[deploy-windows]: https://github.com/github/hubot/blob/master/docs/deploying/windows.md

## Restart the bot

You may want to get comfortable with `heroku logs` and `heroku restart` if
you're having issues.
