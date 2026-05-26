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
    "TAVILY_API_KEY="     + get("/hermes/tavily-api-key"),
    "GITHUB_TOKEN="       + get("/hermes/github-token"),
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
You are Hermes, an autonomous AI assistant running on AWS EC2 and connected to Slack.

You can:
- Receive and respond to direct messages and channel messages (including @mentions) in Slack
- Run code, search the web, read and write files, and use tools
- Schedule tasks via cron jobs
- Remember things across conversations via your memory system

You are helpful, curious, and direct. You acknowledge your actual capabilities honestly — you are a fully connected Slack bot and can see messages sent to you in channels and DMs.
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

# ── 12b. Deterministic gateway health check (no LLM) ─────────────────────────
# Mirrors the openclaw-heartbeat-check pattern.
# Runs every 10 minutes. On failure: 3 attempts with exponential backoff
# (0s / 60s / 120s between tries), then alerts via Slack API if all fail.
# Sends a recovery notification when the service comes back up.
# Never uses the Hermes LLM — Slack API only.
cat > /usr/local/bin/hermes-heartbeat-check <<'HEARTBEAT'
#!/bin/bash
set -uo pipefail

STATE_DIR=/var/lib/hermes
ALERT_SENT_FILE="$STATE_DIR/heartbeat-alert-sent"
LOCK_FILE=/var/lock/hermes-heartbeat.lock
LOG=/var/log/hermes-heartbeat.log
STALE_SECONDS=3900
ALERT_REPEAT_SECS=3600

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

get_slack_token() {
  grep -m1 '^SLACK_BOT_TOKEN=' /root/.hermes/.env 2>/dev/null | cut -d= -f2-
}

get_owner_id() {
  grep -m1 '^SLACK_ALLOWED_USERS=' /root/.hermes/.env 2>/dev/null \
    | cut -d= -f2- | tr ',' '\n' | grep -m1 '^U' || true
}

slack_dm() {
  local msg="$1"
  local token owner payload resp ok
  token=$(get_slack_token) || { log "ERROR: cannot read Slack token"; return 1; }
  [ -z "$token" ] && { log "ERROR: empty Slack token"; return 1; }
  owner=$(get_owner_id) || { log "ERROR: cannot determine owner Slack ID"; return 1; }
  [ -z "$owner" ] && { log "ERROR: SLACK_ALLOWED_USERS not set — cannot send DM"; return 1; }
  payload=$(python3 -c "import json,sys; print(json.dumps({'channel':sys.argv[1],'text':sys.argv[2]}))" \
    "$owner" "$msg")
  resp=$(curl -sf -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || { log "ERROR: curl failed"; return 1; }
  ok=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('ok',False))" <<< "$resp" 2>/dev/null || echo False)
  [ "$ok" = "True" ] && log "Slack DM sent" || log "ERROR: Slack DM failed: $resp"
}

check_gateway() {
  systemctl is-active --quiet hermes-gateway || return 1
  # Secondary: heartbeat.json freshness (written by hermes framework every 30 min)
  local hb="$STATE_DIR/heartbeat.json"
  if [ -f "$hb" ]; then
    local ts age
    ts=$(python3 -c "import json; d=json.load(open('$hb')); print(d.get('ts',''))" 2>/dev/null || true)
    if [ -n "$ts" ]; then
      age=$(( $(date -u +%s) - $(date -u -d "$ts" +%s 2>/dev/null || echo 0) ))
      [ "$age" -lt "$STALE_SECONDS" ] || return 1
    fi
  fi
}

probed_check() {
  local delays=(0 60 120)
  for i in 0 1 2; do
    [ "$${delays[$i]}" -gt 0 ] && { log "Waiting $${delays[$i]}s before retry..."; sleep "$${delays[$i]}"; }
    if check_gateway; then
      log "Attempt $((i+1))/3: healthy"
      return 0
    fi
    log "Attempt $((i+1))/3: failed (service=$(systemctl is-active hermes-gateway 2>/dev/null || echo unknown))"
  done
  return 1
}

exec 9>"$LOCK_FILE"
flock -n 9 || { log "Another check running — skipping"; exit 0; }

mkdir -p "$STATE_DIR"

if probed_check; then
  if [ -f "$ALERT_SENT_FILE" ]; then
    log "Service recovered — notifying"
    slack_dm "✅ Hermes gateway recovered ($(date -u +%FT%TZ))."
    rm -f "$ALERT_SENT_FILE"
  fi
  exit 0
fi

# All 3 attempts failed
now=$(date +%s)
if [ -f "$ALERT_SENT_FILE" ]; then
  last=$(stat -c %Y "$ALERT_SENT_FILE" 2>/dev/null || echo 0)
  elapsed=$((now - last))
  if [ "$elapsed" -lt "$ALERT_REPEAT_SECS" ]; then
    log "Still down — alert suppressed (last sent $${elapsed}s ago, cooldown $${ALERT_REPEAT_SECS}s)"
    exit 0
  fi
  log "Still down — re-alerting after $${elapsed}s"
else
  log "Confirmed down after 3 attempts — alerting"
fi

slack_dm "🔴 Hermes gateway DOWN ($(date -u +%FT%TZ)). All 3 checks failed. Run: journalctl -u hermes-gateway -n 50"
touch "$ALERT_SENT_FILE"
HEARTBEAT
chmod +x /usr/local/bin/hermes-heartbeat-check

cat > /etc/cron.d/hermes-heartbeat <<'CRON'
# Deterministic gateway health check — no LLM. Alerts via Slack API after 3 failed probes.
*/10 * * * * root /usr/local/bin/hermes-heartbeat-check
CRON
chmod 644 /etc/cron.d/hermes-heartbeat

echo "[bootstrap] Deterministic heartbeat check installed"

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
MemoryMax=1400M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable hermes-gateway
systemctl start  hermes-gateway

echo "[bootstrap] hermes-gateway service enabled and started"

# ── 14. Memory sync to GitHub ─────────────────────────────────────────────────
ssh-keygen -t ed25519 -f /root/.ssh/hermes_memory -N "" -C "hermes-memory-deploy"

echo "[bootstrap] MEMORY DEPLOY KEY (add to iolalog/hermes-memory as deploy key, write access):"
cat /root/.ssh/hermes_memory.pub

cat >> /root/.ssh/config <<'SSHCONFIG'

Host github-hermes-memory
  HostName github.com
  IdentityFile /root/.ssh/hermes_memory
  StrictHostKeyChecking yes
SSHCONFIG

git config --global user.email "hermes@instance"
git config --global user.name "Hermes"

# Clone memory repo (will fail until deploy key is added to GitHub)
git clone git@github-hermes-memory:iolalog/hermes-memory.git /root/.hermes/memory-repo 2>&1 \
  && echo "[bootstrap] memory repo cloned" \
  || echo "[bootstrap] WARNING: memory repo clone failed — add deploy key to GitHub, then: git clone git@github-hermes-memory:iolalog/hermes-memory.git /root/.hermes/memory-repo"

cat > /usr/local/bin/hermes-sync-memory <<'SYNC'
#!/bin/bash
export HOME=/root
REPO=/root/.hermes/memory-repo

# Sync memories
rsync -a --delete /root/.hermes/memories/ $REPO/memories/

# Sync config and identity
cp /root/.hermes/config.yaml $REPO/config.yaml 2>/dev/null || true
cp /root/.hermes/SOUL.md $REPO/SOUL.md 2>/dev/null || true

# Sync user-created skills only
# Use the name field from SKILL.md frontmatter — this matches .bundled_manifest keys
# (directory names differ from manifest keys for many bundled skills)
mkdir -p $REPO/skills
BUNDLED=$(cut -d: -f1 /root/.hermes/skills/.bundled_manifest 2>/dev/null | sort)
find /root/.hermes/skills -name SKILL.md | while read f; do
  skill_name=$(grep -m1 "^name:" "$f" | cut -d: -f2 | xargs)
  if [ -z "$skill_name" ] || echo "$BUNDLED" | grep -qx "$skill_name"; then
    continue
  fi
  skill_dir=$(dirname "$f")
  rel="$${skill_dir#/root/.hermes/skills/}"
  mkdir -p "$REPO/skills/$(dirname $rel)"
  rsync -a "$skill_dir/" "$REPO/skills/$rel/"
done

cd $REPO
git add -A
if ! git diff --cached --quiet; then
  git commit -m "sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git push
fi
SYNC
chmod +x /usr/local/bin/hermes-sync-memory

printf '0 2 * * * root /usr/local/bin/hermes-sync-memory\n' > /etc/cron.d/hermes-memory-sync
chmod 644 /etc/cron.d/hermes-memory-sync

echo "[bootstrap] Memory sync script and cron job installed"

# Initial sync — run once at bootstrap so the repo isn't empty until 2am
/usr/local/bin/hermes-sync-memory || echo "[bootstrap] WARNING: initial memory sync failed (deploy key may not be added yet)"

# ── 15. Swap (2 GB safety net for 1.8 GiB instance) ──────────────────────────
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
  sysctl -p /etc/sysctl.d/99-swap.conf
fi

echo "[bootstrap] Swapfile configured (2 GB, swappiness=10)"

# ── 16. Harden OS ─────────────────────────────────────────────────────────────
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
