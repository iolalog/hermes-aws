#!/bin/bash
set -eu
exec > /var/log/hermes-bootstrap.log 2>&1

echo "[bootstrap] Starting at $(date)"

export HOME=/root
export DEBIAN_FRONTEND=noninteractive

# ── 1. Install SSM agent ──────────────────────────────────────────────────────
snap install amazon-ssm-agent --classic || true

sleep 5

systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service

echo "[bootstrap] SSM agent installed and started"

# ── 2. Install system dependencies ───────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl gnupg git build-essential python3-dev libffi-dev ripgrep ffmpeg

echo "[bootstrap] System dependencies installed"

# ── 3. Install Node.js v22 (needed for Hermes browser automation tools) ───────
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

echo "[bootstrap] Node.js $(node --version) installed"

# ── 4. Install uv (fast Python package manager) ───────────────────────────────
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="/root/.local/bin:$PATH"

echo "[bootstrap] uv $(uv --version) installed"

# ── 5. Install Python 3.11 via uv ─────────────────────────────────────────────
uv python install 3.11

echo "[bootstrap] Python 3.11 installed via uv"

# ── 6. Clone hermes-agent and create virtualenv ───────────────────────────────
mkdir -p /root/.hermes

git clone https://github.com/NousResearch/hermes-agent.git /root/.hermes/hermes-agent

uv venv /root/.hermes/venv --python 3.11

echo "[bootstrap] hermes-agent cloned, virtualenv created"

# ── 7. Install hermes-agent into the virtualenv ───────────────────────────────
cd /root/.hermes/hermes-agent
/root/.local/bin/uv pip install --python /root/.hermes/venv/bin/python -e ".[all]"

echo "[bootstrap] hermes-agent installed: $(/root/.hermes/venv/bin/hermes --version 2>/dev/null || echo '(version check failed)')"

# ── 8. Fetch secrets from SSM and write /root/.hermes/.env ───────────────────
# Uses boto3 (installed with hermes-agent[all]) rather than the aws CLI, which
# is not reliably in PATH during cloud-init on Ubuntu.
# SLACK_ALLOWED_USERS is left unset — all users can DM the bot by default.
# Post-deploy: restrict by adding SLACK_ALLOWED_USERS=U... to .env and restarting.
/root/.hermes/venv/bin/python3 << 'PYEOF'
import boto3, os, sys
client = boto3.client("ssm", region_name="${aws_region}")
def get(name):
    try:
        return client.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
    except Exception as e:
        print(f"[bootstrap] WARNING: could not fetch {name}: {e}", file=sys.stderr)
        return ""
lines = [
    "SLACK_BOT_TOKEN="    + get("/hermes/slack-bot-token"),
    "SLACK_APP_TOKEN="    + get("/hermes/slack-app-token"),
    "ANTHROPIC_API_KEY="  + get("/hermes/anthropic-api-key"),
    "OPENROUTER_API_KEY=" + get("/hermes/openrouter-api-key"),
    "HOME=/root",
]
path = "/root/.hermes/.env"
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(path, 0o600)
print(f"[bootstrap] .env written ({os.path.getsize(path)} bytes)")
PYEOF

# ── 10. Write /root/.hermes/config.yaml ───────────────────────────────────────
cat > /root/.hermes/config.yaml <<'CONFIG'
model:
  default: "anthropic/claude-sonnet-4-6"
  provider: auto
  base_url: "https://openrouter.ai/api/v1"

terminal:
  backend: local

compression:
  enabled: true
  threshold: 0.85
CONFIG

echo "[bootstrap] config.yaml written"

# ── 11. Write /root/.hermes/SOUL.md ───────────────────────────────────────────
cat > /root/.hermes/SOUL.md <<'SOUL'
You are Hermes, an autonomous AI assistant. You are helpful, curious, and direct.
You run on AWS and connect to users via Slack.
SOUL

echo "[bootstrap] SOUL.md written"

# ── 12. Install helper scripts ────────────────────────────────────────────────

# Status: show service state and recent logs
cat > /usr/local/bin/hermes-status <<'STATUS'
#!/bin/bash
echo "=== Service state ==="
systemctl is-active hermes-gateway && echo "STATUS: active" || echo "STATUS: $(systemctl is-failed hermes-gateway 2>/dev/null || echo inactive)"
systemctl status hermes-gateway --no-pager -l 2>/dev/null | head -10

echo ""
echo "=== Config files ==="
for f in /root/.hermes/.env /root/.hermes/config.yaml /root/.hermes/SOUL.md; do
  if [ -f "$f" ]; then
    echo "  EXISTS  $(stat -c '%y' "$f" | cut -d. -f1)  $f"
  else
    echo "  MISSING $f"
  fi
done

echo ""
echo "=== hermes-agent version ==="
/root/.hermes/venv/bin/hermes --version 2>/dev/null || echo "(unknown)"

echo ""
echo "=== Last 40 journal lines ==="
journalctl -u hermes-gateway -n 40 --no-pager
STATUS
chmod +x /usr/local/bin/hermes-status

# Upgrade: stop service, pull latest, reinstall deps, restart
cat > /usr/local/bin/hermes-upgrade <<'UPGRADE'
#!/bin/bash
set -uo pipefail

trap 'echo "[hermes-upgrade] ERROR — restarting service with existing install"; systemctl start hermes-gateway || true' ERR

echo "[hermes-upgrade] stopping service..."
systemctl stop hermes-gateway

echo "[hermes-upgrade] pulling latest hermes-agent..."
git -C /root/.hermes/hermes-agent pull

echo "[hermes-upgrade] reinstalling dependencies..."
cd /root/.hermes/hermes-agent
/root/.local/bin/uv pip install --python /root/.hermes/venv/bin/python -e ".[all]"

echo "[hermes-upgrade] version: $(/root/.hermes/venv/bin/hermes --version 2>&1 | head -1)"
echo "[hermes-upgrade] starting service..."
systemctl start hermes-gateway
echo "[hermes-upgrade] done."
UPGRADE
chmod +x /usr/local/bin/hermes-upgrade

echo "[bootstrap] Helper scripts installed"

# ── 13. Install and start the hermes-gateway systemd service ──────────────────
cat > /etc/systemd/system/hermes-gateway.service <<SERVICE
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/.hermes
Environment=HOME=/root
Environment=PATH=/root/.hermes/venv/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=/root/.hermes/.env
ExecStart=/root/.hermes/venv/bin/hermes gateway run
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable hermes-gateway
systemctl start  hermes-gateway

echo "[bootstrap] hermes-gateway service enabled and started"

# ── 14. Harden OS ─────────────────────────────────────────────────────────────
# Disable SSH password auth (access is via SSM Session Manager only)
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
  echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# Enable UFW: deny all inbound, allow all outbound
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

echo "[bootstrap] OS hardening applied (UFW active, SSH password auth disabled)"
echo "[bootstrap] Done at $(date)"
