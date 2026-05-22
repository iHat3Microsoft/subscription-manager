#!/usr/bin/env bash
set -euo pipefail

DEPLOY_USER="deploy-bot"
REPO_DIR="/opt/subscription-manager"
DEPLOY_SCRIPT="${REPO_DIR}/ops/subman-deploy.sh"
SSH_DIR="/home/${DEPLOY_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root: sudo bash ops/setup-deploy-bot.sh"
  exit 1
fi

id "$DEPLOY_USER" >/dev/null 2>&1 || {
  echo "User ${DEPLOY_USER} does not exist"
  exit 1
}

install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"
touch "$AUTH_KEYS"
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if [[ -f "$DEPLOY_SCRIPT" ]]; then
  chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_SCRIPT"
  chmod 750 "$DEPLOY_SCRIPT"
else
  echo "Missing deploy script: $DEPLOY_SCRIPT"
  exit 1
fi

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$REPO_DIR"

usermod -s /usr/sbin/nologin "$DEPLOY_USER"
passwd -l "$DEPLOY_USER" >/dev/null 2>&1 || true

echo "Setup complete."
echo "Add a restricted key line to: $AUTH_KEYS"
echo "command=\"${DEPLOY_SCRIPT}\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding <PUBLIC_KEY>"
