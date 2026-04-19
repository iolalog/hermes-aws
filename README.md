# hermes-aws

Terraform infrastructure for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on AWS EC2. Single always-on instance connected to Slack via Socket Mode.

## Architecture

- **EC2 t4g.small** (ARM64, 2GB RAM) running Ubuntu 24.04 — ~$13/month
- **Hermes Agent** (Python 3.11) installed from source, running as a systemd service
- **Slack Socket Mode** — outbound-only WebSocket, no inbound ports needed
- **SSM Session Manager** — only terminal access path; port 22 never opened
- **SSM Parameter Store** — all secrets stored encrypted, fetched at boot; none in Terraform state
- **DLM daily snapshots** — 7-day retention (~$0.40/month)

**Total: ~$14/month**

## Security notes

- **Zero ingress rules** — the security group has no inbound rules; all access is via SSM Session Manager
- **IMDSv2 required** — EC2 metadata endpoint enforces token auth (`http_tokens = required`)
- **Runs as root** — this is a single-purpose host with no other users; mitigated by network isolation
- **Unpinned bootstrap dependencies** — `curl | sh` from astral.sh (uv installer) and a `git clone` run at first boot; supply-chain exposure window is bootstrap time only
- **`ignore_changes = [user_data, ami]`** — bootstrap script changes are not auto-applied on `terraform apply`; taint the instance to force re-bootstrap
- **Open Slack access by default** — until `SLACK_ALLOWED_USERS` is set in `/root/.hermes/.env`, any Slack user who DMs the bot can pair with it. Lock it down immediately after pairing (see [docs/setup.md](docs/setup.md))

## Quick start

See [docs/setup.md](docs/setup.md) for the full guide. In brief:

1. Create a Slack app from [`docs/slack-manifest.json`](docs/slack-manifest.json)
2. Store 4 secrets in SSM Parameter Store (interactive prompts):
   ```bash
   REGION=eu-north-1
   printf "Slack Bot Token (xoxb-...): ";     read -s V; echo; aws ssm put-parameter --region $REGION --name /hermes/slack-bot-token    --value "$V" --type SecureString --overwrite
   printf "Slack App Token (xapp-...): ";     read -s V; echo; aws ssm put-parameter --region $REGION --name /hermes/slack-app-token    --value "$V" --type SecureString --overwrite
   printf "Anthropic API Key (sk-ant-...): "; read -s V; echo; aws ssm put-parameter --region $REGION --name /hermes/anthropic-api-key  --value "$V" --type SecureString --overwrite
   printf "OpenRouter API Key (sk-or-...): "; read -s V; echo; aws ssm put-parameter --region $REGION --name /hermes/openrouter-api-key --value "$V" --type SecureString --overwrite
   ```
3. Deploy:
   ```bash
   cd infra && terraform init && terraform apply
   ```
4. Wait ~5 minutes for bootstrap to complete, then check logs:
   ```bash
   aws ssm start-session --target $(terraform -chdir=infra output -raw instance_id) --region eu-north-1
   # on the instance:
   journalctl -u hermes-gateway -f
   ```
5. DM the Hermes bot in Slack — approve the pairing code, then immediately lock down access:
   ```bash
   echo 'SLACK_ALLOWED_USERS=<your-slack-user-id>' >> /root/.hermes/.env
   systemctl restart hermes-gateway
   ```
6. Run smoke tests:
   ```bash
   uv run pytest tests/smoke/ -v
   ```

## Connect via SSM

```bash
aws ssm start-session --target $(terraform -chdir=infra output -raw instance_id) --region eu-north-1
```

## Teardown

```bash
cd infra && terraform destroy
```
