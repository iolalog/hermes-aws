# Hermes AWS Setup Guide

## Pre-flight check

```bash
# Verify no existing Hermes deployment
cd infra && terraform state list 2>/dev/null | grep hermes && echo "WARNING: existing state found" || echo "Clean"
```

## Step 1 — Create a Slack app

1. Go to https://api.slack.com/apps → **Create New App** → **From a manifest**
2. Select your workspace → paste the contents of [`docs/slack-manifest.json`](slack-manifest.json) → **Next** → **Create**
3. **Basic Information** → **Display Information** → upload [`docs/hermes-slack-icon.png`](hermes-slack-icon.png) as the app icon
4. **Basic Information** → **App-Level Tokens** → **Generate Token and Scopes** → name it (e.g. "hermes-socket") → add scope `connections:write` → **Generate** → copy the token (`xapp-...`)
5. **Install to Workspace** → **Allow** → copy the **Bot User OAuth Token** (`xoxb-...`)

## Step 2 — Gather API keys

You need:
- Slack Bot Token (`xoxb-...`)
- Slack App Token (`xapp-...`)
- Anthropic API key (`sk-ant-...`)
- OpenRouter API key (`sk-or-...`) — sign up at https://openrouter.ai

## Step 3 — Store secrets in SSM Parameter Store

```bash
REGION=eu-north-1

printf "Slack Bot Token (xoxb-...): ";     read -s V; echo; aws ssm put-parameter --region eu-north-1 --name /hermes/slack-bot-token    --value "$V" --type SecureString --overwrite
printf "Slack App Token (xapp-...): ";     read -s V; echo; aws ssm put-parameter --region eu-north-1 --name /hermes/slack-app-token    --value "$V" --type SecureString --overwrite
printf "Anthropic API Key (sk-ant-...): "; read -s V; echo; aws ssm put-parameter --region eu-north-1 --name /hermes/anthropic-api-key  --value "$V" --type SecureString --overwrite
printf "OpenRouter API Key (sk-or-...): "; read -s V; echo; aws ssm put-parameter --region eu-north-1 --name /hermes/openrouter-api-key --value "$V" --type SecureString --overwrite
```

## Step 4 — Deploy with Terraform

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars if you need a different region

terraform init
terraform apply
```

Note the `instance_id` from the output.

## Step 5 — Monitor bootstrap

Bootstrap takes ~5 minutes. Watch the log via SSM:

```bash
INSTANCE_ID=$(terraform -chdir=infra output -raw instance_id)
aws ssm start-session --target $INSTANCE_ID --region eu-north-1
```

Inside the session:
```bash
tail -f /var/log/hermes-bootstrap.log
# Once done:
journalctl -u hermes-gateway -f
```

## Step 6 — Test via Slack

Send a DM to your Hermes bot in Slack. It should respond within a few seconds.

If it doesn't respond, check the logs:
```bash
journalctl -u hermes-gateway -n 50 --no-pager
# Or run the status helper:
/usr/local/bin/hermes-status
```

## Step 7 — Restrict access (recommended)

By default, any Slack user can DM the bot. To restrict to yourself:

```bash
# Your Slack user ID appears in hermes logs on first DM, or find it in your Slack profile
echo 'SLACK_ALLOWED_USERS=U0123ABCDEF' >> /root/.hermes/.env
systemctl restart hermes-gateway
```

## Step 8 — Run smoke tests

From your local machine (requires `uv` and AWS credentials):

```bash
uv sync
uv run pytest tests/smoke/ -v
```

## Ongoing operations

**Check status:**
```bash
aws ssm send-command --instance-ids $INSTANCE_ID --region eu-north-1 \
  --document-name HermesStatus --query 'Command.CommandId' --output text
```

**Restart service:**
```bash
aws ssm send-command --instance-ids $INSTANCE_ID --region eu-north-1 \
  --document-name HermesRestart
```

**Upgrade hermes-agent:**
```bash
# Via SSM session:
/usr/local/bin/hermes-upgrade
```

**View live logs:**
```bash
# Via SSM session:
journalctl -u hermes-gateway -f
```
