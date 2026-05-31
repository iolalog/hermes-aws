# Hermes WebUI — deployment plan (not yet implemented)

This documents a planned deployment of [hermes-webui](https://github.com/nesquena/hermes-webui), a lightweight browser-based chat interface for Hermes. It has not been implemented yet.

## What it is

hermes-webui is a Python `ThreadingHTTPServer` application with vanilla JS/CSS frontend (no build step). It connects to hermes-agent via direct Python import (`from run_agent import AIAgent`). Requires Python 3.12+. Default port: 8787.

## Approach: same instance, localhost bind, SSM port-forward access

Deploy alongside the existing `hermes-gateway` on the t4g.small instance. Bind to `127.0.0.1:8787` — never exposed to the internet. Access via an SSM port-forwarding session from your local machine.

**Why this fits:**
- Zero-ingress security model stays intact — no security group changes needed.
- The webui is lightweight (~100–200 MB RAM). Fits alongside the gateway's 1400M cap and 2 GB swap.
- hermes-agent is already cloned at `/root/.hermes/hermes-agent` — the webui can point straight at it.
- Python 3.12 can be added via `uv python install 3.12` without disturbing the 3.11 gateway venv.

## Access workflow

```bash
aws ssm start-session \
  --target $(terraform -chdir=infra output -raw instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8787"],"localPortNumber":["8787"]}' \
  --region eu-north-1

# Then open http://localhost:8787 in your browser
```

## Implementation steps

### 1. `infra/scripts/bootstrap.sh.tpl` — add webui install phase

After the hermes-agent install phase, add:

```bash
# Install Python 3.12 (webui requires 3.12+; gateway uses 3.11)
uv python install 3.12

# Clone hermes-webui
git clone https://github.com/nesquena/hermes-webui.git /root/.hermes/hermes-webui

# Install webui dependencies into its own venv
cd /root/.hermes/hermes-webui
uv sync --python 3.12

# State directory
mkdir -p /root/.hermes/webui
```

### 2. `infra/scripts/bootstrap.sh.tpl` — add hermes-webui systemd service

```ini
[Unit]
Description=Hermes WebUI
After=network.target hermes-gateway.service
Wants=hermes-gateway.service

[Service]
Type=simple
WorkingDirectory=/root/.hermes/hermes-webui
EnvironmentFile=/root/.hermes/.env
Environment=HERMES_WEBUI_AGENT_DIR=/root/.hermes/hermes-agent
Environment=HERMES_WEBUI_HOST=127.0.0.1
Environment=HERMES_WEBUI_PORT=8787
Environment=HERMES_WEBUI_STATE_DIR=/root/.hermes/webui
Environment=HERMES_WEBUI_DEFAULT_WORKSPACE=/root
ExecStart=/root/.hermes/hermes-webui/.venv/bin/python start.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start: `systemctl enable --now hermes-webui`

### 3. Optional: webui password via SSM

Add `/hermes/webui-password` to SSM and fetch it in the bootstrap secret-fetch block, writing `HERMES_WEBUI_PASSWORD` to `.env`. If not set, the webui runs without a password (fine since the port is never public).

```bash
aws ssm put-parameter \
  --name /hermes/webui-password \
  --type SecureString \
  --value "your-password-here" \
  --region eu-north-1
```

## Memory budget

| Component       | Expected usage |
|----------------|---------------|
| hermes-gateway | 1400M cap     |
| hermes-webui   | ~150M         |
| OS + SSM agent | ~200M         |
| Swap available | 2 GB          |
| t4g.small RAM  | 1.8 GiB       |

Tight but workable; the webui is intentionally lightweight.

## Verification (after implementation)

```bash
# On the instance (via SSM session):
systemctl status hermes-webui
journalctl -u hermes-webui -n 50
free -h

# Locally:
aws ssm start-session \
  --target <instance_id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8787"],"localPortNumber":["8787"]}' \
  --region eu-north-1
# Open http://localhost:8787 — send a test message, confirm agent responds
```
