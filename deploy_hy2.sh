#!/usr/bin/env bash
# deploy_hy2.sh — standalone interactive deployer for Hysteria 2 on a remote VPN server.
# Installs official Hysteria 2 via https://get.hy2.sh/ (if not installed), configures
# /etc/hysteria/config.yaml (no port hopping, no salamanders, userpass auth, masquerade),
# and enables/starts hysteria-server.service.
#
# Usage:
#   ./deploy_hy2.sh [target-server-alias]
#
# Examples:
#   ./deploy_hy2.sh
#   ./deploy_hy2.sh sweden
#   ./deploy_hy2.sh --domain deb.uvx.lol sweden
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

TARGET=""
DOMAIN=""
EMAIL=""
HY2_PORT="443"
INSECURE=0
IDENTITY=""
SSH_PORT=""
USE_SSHPASS=0

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] [ssh-target]

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME sweden
  $SCRIPT_NAME --domain deb.uvx.lol sweden
  $SCRIPT_NAME --domain deb.uvx.lol --email admin@deb.uvx.lol sweden

Options:
  --domain DOMAIN           Domain name for TLS/ACME (e.g. deb.uvx.lol)
  --email EMAIL             Email for Let's Encrypt ACME
  --port PORT               Hysteria listen UDP port, default: 443
  --insecure                Force self-signed certificate (skip ACME)
  -i, --identity PATH       SSH private key
  -p, --ssh-port PORT       SSH port
  --password                Use sshpass with SSHPASS env var
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            DOMAIN="${2:?missing domain}"; shift 2 ;;
        --email)
            EMAIL="${2:?missing email}"; shift 2 ;;
        --port)
            HY2_PORT="${2:?missing port}"; shift 2 ;;
        --insecure)
            INSECURE=1; shift ;;
        -i|--identity)
            IDENTITY="${2:?missing identity path}"; shift 2 ;;
        -p|--ssh-port)
            SSH_PORT="${2:?missing ssh port}"; shift 2 ;;
        --password)
            USE_SSHPASS=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            echo "[!] Unknown option: $1" >&2
            usage >&2
            exit 1 ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"
                shift
            else
                echo "[!] Unexpected argument: $1" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

ask() {
    local var="$1"
    local prompt="$2"
    local default_val="${3:-}"

    if [[ -n "${!var:-}" ]]; then
        return 0
    fi

    local display_prompt="$prompt"
    if [[ -n "$default_val" ]]; then
        display_prompt="$prompt [$default_val]: "
    else
        display_prompt="$prompt: "
    fi

    local reply=""
    if [[ -t 0 ]]; then
        read -rp "$display_prompt" reply
    elif [[ -e /dev/tty ]]; then
        read -rp "$display_prompt" reply < /dev/tty
    else
        reply="$default_val"
    fi

    if [[ -z "$reply" ]]; then
        reply="$default_val"
    fi

    printf -v "$var" '%s' "$reply"
}

# Interactive prompts
if [[ -z "$TARGET" ]]; then
    KNOWN_HOSTS=$(grep -E '^[[:space:]]*Host[[:space:]]+' ~/.ssh/config 2>/dev/null | awk '{print $2}' | grep -vE '(\*|gitlab|nether)' | paste -sd ', ' - || true)
    if [[ -n "$KNOWN_HOSTS" ]]; then
        echo "Found SSH servers in ~/.ssh/config: $KNOWN_HOSTS"
    fi
    ask TARGET "Target VPN server SSH alias (e.g. sweden, vds)"
fi

if [[ -z "$TARGET" ]]; then
    echo "[!] Target server is required." >&2
    usage >&2
    exit 1
fi

ask DOMAIN "Domain for Hysteria (e.g. deb.uvx.lol, or press Enter for server IP / self-signed)" ""
if [[ -n "$DOMAIN" ]]; then
    ask EMAIL "Email for Let's Encrypt ACME (optional, press Enter to skip)" ""
fi

ask HY2_PORT "Hysteria UDP port" "443"

echo
echo "========================================="
echo " Deploy Plan:"
echo "   Target Server: $TARGET"
echo "   Domain:        ${DOMAIN:-[None - server IP with self-signed cert]}"
echo "   Port:          $HY2_PORT"
if [[ -n "$EMAIL" ]]; then
    echo "   ACME Email:    $EMAIL"
fi
echo "========================================="
echo

if [[ -t 0 ]]; then
    read -rp "Proceed with deployment on $TARGET? [Y/n]: " CONFIRM_DEPLOY
    if [[ "$CONFIRM_DEPLOY" =~ ^[Nn] ]]; then
        echo "[*] Aborted by user."
        exit 0
    fi
fi

if [[ "$USE_SSHPASS" -eq 1 ]]; then
    SSH_BIN=(sshpass -e ssh)
    SCP_BIN=(sshpass -e scp)
else
    SSH_BIN=(ssh)
    SCP_BIN=(scp)
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

COMMON_OPTS=(
    -o ControlMaster=auto
    -o ControlPersist=5m
    -o ControlPath="$TMPDIR/ssh_mux_%C"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
)

SSH_OPTS=("${COMMON_OPTS[@]}")
SCP_OPTS=("${COMMON_OPTS[@]}")

if [[ -n "$SSH_PORT" ]]; then
    SSH_OPTS+=(-p "$SSH_PORT")
    SCP_OPTS+=(-P "$SSH_PORT")
fi

if [[ -n "$IDENTITY" ]]; then
    SSH_OPTS+=(-i "$IDENTITY")
    SCP_OPTS+=(-i "$IDENTITY")
fi

ssh_remote() {
    "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "$TARGET" "$@"
}

scp_to_remote() {
    local src="$1"
    local dst="$2"
    "${SCP_BIN[@]}" "${SCP_OPTS[@]}" "$src" "$TARGET:$dst"
}

sq() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

echo "[*] Connecting to $TARGET..."
CHECK_CONN=$(ssh_remote "echo ok" 2>&1) || {
    echo "[!] Failed to connect to $TARGET via SSH." >&2
    echo "    SSH output: $CHECK_CONN" >&2
    exit 1
}

# 1. Install Hysteria 2 if not installed
echo "[*] Checking if Hysteria 2 is installed on $TARGET..."
HY2_INSTALLED="$(
    ssh_remote "command -v hysteria >/dev/null 2>&1 && echo 'yes' || (test -x /usr/local/bin/hysteria && echo 'yes' || echo 'no')" \
    | tr -d '\r\n'
)"

if [[ "$HY2_INSTALLED" != "yes" ]]; then
    echo "[*] Installing official Hysteria 2 via https://get.hy2.sh/ ..."
    ssh_remote "curl -fsSL https://get.hy2.sh/ | sudo bash"
    echo "[+] Hysteria 2 installed successfully"
else
    HY2_VER="$(ssh_remote "/usr/local/bin/hysteria version 2>/dev/null | head -n1 || echo 'installed'")"
    echo "[*] Hysteria 2 is already installed ($HY2_VER)"
fi

# 2. Configure directories and TLS
echo "[*] Configuring /etc/hysteria..."
ssh_remote "sudo mkdir -p /etc/hysteria && sudo chmod 750 /etc/hysteria"

USE_SELF_SIGNED=0
if [[ -z "$DOMAIN" || "$INSECURE" -eq 1 ]]; then
    USE_SELF_SIGNED=1
fi

if [[ "$USE_SELF_SIGNED" -eq 1 ]]; then
    SNI_NAME="${DOMAIN:-$TARGET}"
    echo "[*] Ensuring self-signed certificate for $SNI_NAME..."
    ssh_remote "if [ ! -f /etc/hysteria/server.crt ] || [ ! -f /etc/hysteria/server.key ]; then
        sudo openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
            -days 3650 -subj '/CN=$SNI_NAME'
        sudo chmod 640 /etc/hysteria/server.key /etc/hysteria/server.crt
    fi"
fi

# 3. Read existing userpass (if any) to preserve existing credentials
EXISTING_USERS_FILE="$TMPDIR/existing_users.tsv"
ssh_remote "if [ -f /etc/hysteria/config.yaml ]; then
    python3 - <<'PY'
import re, sys
try:
    with open('/etc/hysteria/config.yaml', 'r', encoding='utf-8', errors='ignore') as f:
        in_userpass = False
        for line in f:
            if re.match(r'^\s*userpass:\s*$', line):
                in_userpass = True
                continue
            if in_userpass:
                m = re.match(r'^\s{4,}([A-Za-z0-9._-]+)\s*:\s*[\"\\\']?([^\"\\\'\s]+)[\"\\\']?', line)
                if m:
                    print(f'{m.group(1)}\t{m.group(2)}')
                elif re.match(r'^\S', line) or (re.match(r'^\s{1,2}\S', line) and not line.strip().startswith('#')):
                    in_userpass = False
except Exception:
    pass
PY
fi" > "$EXISTING_USERS_FILE" 2>/dev/null || true

declare -A USER_PASSWORDS=()
if [[ -f "$EXISTING_USERS_FILE" ]]; then
    while IFS=$'\t' read -r u p; do
        [[ -z "$u" || -z "$p" ]] && continue
        USER_PASSWORDS["$u"]="$p"
    done < "$EXISTING_USERS_FILE"
fi

# Ensure at least one default user if empty
if [[ "${#USER_PASSWORDS[@]}" -eq 0 ]]; then
    INIT_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24 || true)"
    USER_PASSWORDS["admin"]="$INIT_PASS"
fi

# 4. Generate /etc/hysteria/config.yaml
LOCAL_SERVER_CONF="$TMPDIR/config.yaml"
{
    echo "# Hysteria 2 server configuration (managed by subscription-manager)"
    echo "listen: :${HY2_PORT}"
    echo ""
    if [[ "$USE_SELF_SIGNED" -eq 1 ]]; then
        echo "tls:"
        echo "  cert: /etc/hysteria/server.crt"
        echo "  key: /etc/hysteria/server.key"
        echo "  sniGuard: disable"
    else
        echo "acme:"
        echo "  domains:"
        echo "    - ${DOMAIN}"
        if [[ -n "$EMAIL" ]]; then
            echo "  email: ${EMAIL}"
        fi
    fi
    echo ""
    echo "auth:"
    echo "  type: userpass"
    echo "  userpass:"
    for u in "${!USER_PASSWORDS[@]}"; do
        echo "    ${u}: \"${USER_PASSWORDS[$u]}\""
    done
    echo ""
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://news.ycombinator.com/"
    echo "    rewriteHost: true"
} > "$LOCAL_SERVER_CONF"

REMOTE_TMP_CONF="/tmp/hy2_deploy_${$}.yaml"
scp_to_remote "$LOCAL_SERVER_CONF" "$REMOTE_TMP_CONF"
ssh_remote "sudo cp $(sq "$REMOTE_TMP_CONF") /etc/hysteria/config.yaml && rm -f $(sq "$REMOTE_TMP_CONF")"
ssh_remote "sudo chown -R hysteria:hysteria /etc/hysteria 2>/dev/null || true; sudo chmod 640 /etc/hysteria/config.yaml"

# 5. Enable and start service
echo "[*] Starting hysteria-server.service..."
ssh_remote "sudo systemctl daemon-reload && sudo systemctl enable hysteria-server.service && sudo systemctl restart hysteria-server.service"

SERVICE_STATUS="$(ssh_remote "systemctl is-active hysteria-server.service 2>/dev/null || systemctl is-active hysteria.service 2>/dev/null || echo 'inactive'" | tr -d '\r\n')"

if [[ "$SERVICE_STATUS" == "active" ]]; then
    echo
    echo "[+] SUCCESS: Hysteria 2 is active and running on $TARGET:${HY2_PORT}!"
    echo "[+] You can now run ./sub_hy2.sh to issue keys for all users and push to subscription-manager."
else
    echo "[!] Service status is '$SERVICE_STATUS'. Recent logs:" >&2
    ssh_remote "journalctl -u hysteria-server -n 20 --no-pager 2>/dev/null || true" >&2
    exit 1
fi
