# hermes-aws

Terraform infrastructure for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on AWS EC2. Single always-on instance connected to Slack via Socket Mode.

## Architecture

- **EC2 t4g.small** (ARM64, 2GB RAM) running Ubuntu 24.04 — ~$13/month
- **Hermes Agent** (Python 3.11) installed from source, running as a systemd service
- **Slack Socket Mode** — outbound-only WebSocket, no inbound ports
- **SSM Session Manager** — only terminal access path, no SSH
- **SSM Parameter Store** — all secrets stored encrypted, fetched at boot
- **DLM daily snapshots** — 7-day retention (~$0.40/month)

Total: ~$14/month

## Quick start

See [docs/setup.md](docs/setup.md) for the full setup guide.

```bash
# Store secrets in SSM Parameter Store, then:
cd infra
terraform init
terraform apply

# Wait ~5 min for bootstrap, then check via SSM:
aws ssm start-session --target <instance_id> --region eu-north-1
journalctl -u hermes-gateway -f

# Run smoke tests:
uv run pytest tests/smoke/ -v
```

## Connect via SSM

```bash
aws ssm start-session --target $(terraform -chdir=infra output -raw instance_id) --region eu-north-1
```
