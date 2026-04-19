# CLAUDE.md — Agent instructions for hermes-aws

## What this repo is

Terraform infrastructure for a [Hermes Agent](https://github.com/NousResearch/hermes-agent) autonomous agent on EC2. One instance, one agent, minimal IAM surface. EC2 instance role provides auto-rotating credentials via IMDS — no access keys on disk. See `docs/setup.md` for the full setup guide.

## Key conventions

- **Terraform**: all config under `infra/`. Run `terraform fmt` before committing. State is local (`terraform.tfstate`, gitignored).
- **Secrets**: never committed. `infra/terraform.tfvars` is gitignored. `infra/terraform.tfvars.example` shows the shape with placeholder values.
- **Python tooling**: `uv sync` to install; `uv run pytest tests/smoke/` to run smoke tests; `uv run ruff format` to format.

## Important files

| File | Purpose |
|---|---|
| `infra/main.tf` | VPC, EC2 instance (t4g.small), security group (no inbound), EIP, DLM snapshot policy |
| `infra/iam.tf` | EC2 instance role + profile (SSM + Parameter Store read on `/hermes/*`); DLM role |
| `infra/scripts/bootstrap.sh.tpl` | user_data — installs SSM agent, uv, Python 3.11, Node 22, hermes-agent; fetches all secrets from Parameter Store |
| `infra/variables.tf` | Non-secret input variables (AWS region) |
| `tests/smoke/test_hermes.py` | Post-deploy assertions (SSM online, service active, security group, IAM scope) |
| `docs/setup.md` | Full setup guide including pre-flight check |

## Hermes config on the instance

| Path | Purpose |
|---|---|
| `/root/.hermes/.env` | All credentials (Slack tokens, API keys) — fetched from SSM at boot |
| `/root/.hermes/config.yaml` | Model, tools, compression settings |
| `/root/.hermes/SOUL.md` | Agent personality/identity |
| `/root/.hermes/hermes-agent/` | Cloned source repo |
| `/root/.hermes/venv/` | Python 3.11 virtualenv |
| `/root/.hermes/venv/bin/hermes` | CLI entry point |

## Security constraints — do not relax without explicit instruction

- Security group `hermes-sg` must have zero ingress rules — no inbound traffic
- Port 22 must never appear in the security group ingress rules
- EC2 instance role has SSM Parameter Store read on `/hermes/*` only — expand per skill, deliberately
- No secrets in committed files — all secrets (Slack, Anthropic, OpenRouter) fetched from Parameter Store at boot; none in `terraform.tfvars` or user_data
- SSM Session Manager is the only terminal access path
- IMDSv2 is required (`http_tokens = "required"`) — protects against SSRF credential theft

## Accepted risks

- **Runs as root**: Hermes is configured with `HOME=/root`; this is a single-purpose host with no other users or services. Mitigation: no inbound network access, SSM-only terminal access.
- **`ignore_changes = [user_data, ami]`**: Intentional. Bootstrap changes require instance replacement or manual intervention — they are not silently applied on `terraform apply`. To apply bootstrap changes: taint the instance and re-apply.
- **Unpinned bootstrap dependencies**: `curl … | sh` from astral.sh (uv) and `git clone` from GitHub run as root at instance creation. This is a supply-chain exposure on first boot only. Accepted because this is a single-purpose, long-lived host that is rarely re-provisioned.

## Expanding IAM permissions

Add only when a specific skill requires it. Pattern to follow in `infra/iam.tf`:

```hcl
resource "aws_iam_role_policy" "hermes_s3" {
  name = "hermes-s3"
  role = aws_iam_role.hermes.id
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::YOUR-BUCKET/*"
    }]
  })
}
```

## Hermes upgrades

Always upgrade via `/usr/local/bin/hermes-upgrade` — never `pip install` or `hermes update` while the service is running. The upgrade wrapper does stop → git pull → pip install → start, and restarts the service even if the install fails.

## Cron file gotchas

- **`/etc/cron.d/` commands must be single-line** — Vixie cron does not reliably support `\` line continuation. Always write one complete command per line.

## SLACK_ALLOWED_USERS

After deploy, restrict DM access to your Slack user ID:
```bash
# Get your Slack user ID from the Hermes logs or Slack profile
# Then edit /root/.hermes/.env via SSM:
aws ssm start-session --target <instance_id> --region eu-north-1
echo 'SLACK_ALLOWED_USERS=U0123ABCDEF' >> /root/.hermes/.env
systemctl restart hermes-gateway
```
