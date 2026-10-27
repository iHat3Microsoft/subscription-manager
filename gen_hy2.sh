#!/usr/bin/env bash
# gen_hy2.sh — installs official Hysteria 2 (if missing), configures it (no port hopping,
# no salamanders, auth: userpass), and issues client keys using `hysteria share -c client.yaml`.
#
# Usage:
#   ./gen_hy2.sh [options] <ssh-target> <user... | prefix:count>
#
# Outputs:
#   ./out_keys/<ssh-target>/<user>.txt
#   ./out_keys/<ssh-target>/<user>.info
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

OUT_DIR="./out_keys"
IDENTITY=""
SSH_PORT=""
USE_SSHPASS=0

HY2_PORT=443
DOMAIN=""
EMAIL=""
SNI=""
INSECURE=""
ENDPOINT_OVERRIDE=""
ENDPOINT_HOST_OVERRIDE=""

FORCE=0
SKIP_EXISTING=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] <ssh-target> <user... | prefix:count>

Examples:
  $SCRIPT_NAME vds user1
  $SCRIPT_NAME vds user1 user2 user3
  $SCRIPT_NAME vds user:10
  $SCRIPT_NAME --domain myhost.com --email me@myhost.com vds user:5
  $SCRIPT_NAME --hy2-port 8443 --insecure vds user1

Options:
  -i, --identity PATH       SSH private key
  -p, --port PORT           SSH port
  --password                Use sshpass with SSHPASS env var
  --out-dir DIR             Local output dir, default: ./out_keys
  --hy2-port PORT           Hysteria listen UDP port, default: 443
  --domain DOMAIN           Domain name for TLS/ACME
  --email EMAIL             Email address for ACME (Let's Encrypt)
  --sni SNI                 SNI override in client links
  --insecure                Force insecure=1 (skip cert verify)
  --endpoint HOST:PORT      Override final client endpoint
  --endpoint-host HOST      Override endpoint host, port from --hy2-port
  --skip-existing           Skip users whose local output already exists
  --force                   Overwrite existing credentials/output files
  --dry-run                 Preview what would be done without making changes
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--identity)
            IDENTITY="${2:?missing identity path}"; shift 2 ;;
        -p|--port)
            SSH_PORT="${2:?missing ssh port}"; shift 2 ;;
        --password)
            USE_SSHPASS=1; shift ;;
        --out-dir)
            OUT_DIR="${2:?missing out dir}"; shift 2 ;;
        --hy2-port)
            HY2_PORT="${2:?missing hy2 port}"; shift 2 ;;
        --domain)
            DOMAIN="${2:?missing domain}"; shift 2 ;;
        --email)
            EMAIL="${2:?missing email}"; shift 2 ;;
        --sni)
            SNI="${2:?missing sni}"; shift 2 ;;
        --insecure)
            INSECURE=1; shift ;;
        --endpoint)
            ENDPOINT_OVERRIDE="${2:?missing endpoint}"; shift 2 ;;
        --endpoint-host)
            ENDPOINT_HOST_OVERRIDE="${2:?missing endpoint host}"; shift 2 ;;
        --skip-existing)
            SKIP_EXISTING=1; shift ;;
        --force)
            FORCE=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift; break ;;
        -*)
            echo "[!] Unknown option: $1" >&2
            usage >&2
            exit 1 ;;
        *)
            break ;;
    esac
done

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    usage
    exit 1
fi
shift

if [[ $# -lt 1 ]]; then
    echo "[!] Need at least one username or prefix:count" >&2
    usage >&2
    exit 1
fi

USERS=()
while [[ $# -gt 0 ]]; do
    ARG="$1"
    shift
    if [[ "$ARG" =~ ^([A-Za-z0-9._-]+):([0-9]+)$ ]]; then
        PREFIX="${BASH_REMATCH[1]}"
        COUNT="${BASH_REMATCH[2]}"
        if [[ "$COUNT" -lt 1 ]]; then
            echo "[!] Bad count: $ARG" >&2
            exit 1
        fi
        for i in $(seq 1 "$COUNT"); do
            USERS+=("${PREFIX}${i}")
        done
    else
        USERS+=("$ARG")
    fi
done

declare -A SEEN=()
for u in "${USERS[@]}"; do
    if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[!] Bad username '$u'. Use only letters, digits, dot, underscore, dash." >&2
        exit 1
    fi
    if [[ -n "${SEEN[$u]:-}" ]]; then
        echo "[!] Duplicate username in arguments: $u" >&2
        exit 1
    fi
    SEEN[$u]=1
done

if [[ "$USE_SSHPASS" -eq 1 ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "[!] sshpass not found locally" >&2
        exit 1
    fi
    if [[ -z "${SSHPASS:-}" ]]; then
        echo "[!] Set SSHPASS env var" >&2
        exit 1
    fi
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

echo "[*] Target: $TARGET"
echo "[*] Users: ${USERS[*]}"

# Resolve endpoint host
ENDPOINT_HOST="$ENDPOINT_HOST_OVERRIDE"
if [[ -z "$ENDPOINT_HOST" && -n "$DOMAIN" ]]; then
    ENDPOINT_HOST="$DOMAIN"
fi

if [[ -z "$ENDPOINT_HOST" ]]; then
    ENDPOINT_HOST="$(
        ssh -G "$TARGET" 2>/dev/null \
        | awk '/^hostname / {print $2; exit}' \
        | tr -d '\r\n'
    )"
fi

if [[ -z "$ENDPOINT_HOST" || "$ENDPOINT_HOST" == "$TARGET" ]]; then
    ENDPOINT_HOST="$(
        ssh_remote "curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null || wget -qO- -T 3 https://api.ipify.org 2>/dev/null || true" \
        | tr -d '\r\n'
    )"
fi

if [[ -z "$ENDPOINT_HOST" ]]; then
    ENDPOINT_HOST="$(
        ssh_remote "ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"src\") print \$(i+1)}' | head -n1 || true" \
        | tr -d '\r\n'
    )"
fi

if [[ -z "$ENDPOINT_HOST" ]]; then
    echo "[!] Could not determine endpoint host. Use --endpoint-host or --domain." >&2
    exit 1
fi

if [[ -n "$ENDPOINT_OVERRIDE" ]]; then
    FINAL_ENDPOINT="$ENDPOINT_OVERRIDE"
else
    FINAL_ENDPOINT="${ENDPOINT_HOST}:${HY2_PORT}"
fi

# Determine SNI & TLS mode
FINAL_SNI="$SNI"
if [[ -z "$FINAL_SNI" ]]; then
    FINAL_SNI="$ENDPOINT_HOST"
fi

# If domain is not provided and --insecure not explicitly passed,
# check if endpoint is an IP address; if so, default to self-signed with insecure
IS_IP=0
if [[ "$ENDPOINT_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IS_IP=1
fi

if [[ -z "$DOMAIN" && "$IS_IP" -eq 1 ]]; then
    USE_SELF_SIGNED=1
    FINAL_INSECURE=1
elif [[ "$INSECURE" == "1" ]]; then
    USE_SELF_SIGNED=1
    FINAL_INSECURE=1
else
    USE_SELF_SIGNED=0
    FINAL_INSECURE=0
fi

echo "[*] Endpoint: $FINAL_ENDPOINT"
echo "[*] TLS mode: $([[ "$USE_SELF_SIGNED" -eq 1 ]] && echo 'Self-signed (insecure)' || echo "ACME / domain ($DOMAIN)")"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Target host: $TARGET"
    echo "[DRY-RUN] Would verify/install Hysteria 2 on remote"
    echo "[DRY-RUN] Would update /etc/hysteria/config.yaml for users: ${USERS[*]}"
    echo "[DRY-RUN] Would run 'hysteria share -c client.yaml' for each user"
    exit 0
fi

# Step 1: Check if hysteria is installed on remote
echo "[*] Checking Hysteria 2 installation on remote..."
HY2_INSTALLED="$(
    ssh_remote "command -v hysteria >/dev/null 2>&1 && echo 'yes' || (test -x /usr/local/bin/hysteria && echo 'yes' || echo 'no')" \
    | tr -d '\r\n'
)"

if [[ "$HY2_INSTALLED" != "yes" ]]; then
    echo "[*] Hysteria 2 is not installed on $TARGET. Installing official version via get.hy2.sh..."
    ssh_remote "curl -fsSL https://get.hy2.sh/ | sudo bash"
    echo "[+] Hysteria 2 installed successfully"
else
    echo "[*] Hysteria 2 is already installed"
fi

# Step 2: Ensure directories and certificates
echo "[*] Configuring Hysteria 2 environment on remote..."
ssh_remote "sudo mkdir -p /etc/hysteria && sudo chmod 750 /etc/hysteria"

if [[ "$USE_SELF_SIGNED" -eq 1 ]]; then
    echo "[*] Ensuring self-signed certificate in /etc/hysteria..."
    ssh_remote "if [ ! -f /etc/hysteria/server.crt ] || [ ! -f /etc/hysteria/server.key ]; then
        sudo openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
            -days 3650 -subj '/CN=$FINAL_SNI'
        sudo chmod 640 /etc/hysteria/server.key /etc/hysteria/server.crt
    fi"
fi

# Step 3: Read existing userpass from /etc/hysteria/config.yaml (if any)
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

echo "[*] Found ${#USER_PASSWORDS[@]} existing user(s) in server config"

# Step 4: Generate passwords for target users (keep existing unless --force)
GEN_TS="$(date '+%F %T')"
mkdir -p "$OUT_DIR/$TARGET"
chmod 700 "$OUT_DIR" "$OUT_DIR/$TARGET" 2>/dev/null || true

for u in "${USERS[@]}"; do
    if [[ "$FORCE" -eq 0 && -n "${USER_PASSWORDS[$u]:-}" ]]; then
        echo "    $u -> using existing password"
    else
        # Generate clean alphanumeric password
        NEW_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24 || true)"
        USER_PASSWORDS["$u"]="$NEW_PASS"
        echo "    $u -> generated new credentials"
    fi
done

# Step 5: Build updated /etc/hysteria/config.yaml
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

# Upload and apply config on server
REMOTE_TMP_CONF="/tmp/hy2_conf_${$}.yaml"
scp_to_remote "$LOCAL_SERVER_CONF" "$REMOTE_TMP_CONF"
ssh_remote "sudo cp $(sq "$REMOTE_TMP_CONF") /etc/hysteria/config.yaml && rm -f $(sq "$REMOTE_TMP_CONF")"
ssh_remote "sudo chown -R hysteria:hysteria /etc/hysteria 2>/dev/null || true; sudo chmod 640 /etc/hysteria/config.yaml"

# Restart hysteria service
echo "[*] Restarting hysteria-server.service..."
ssh_remote "sudo systemctl daemon-reload && sudo systemctl enable hysteria-server.service && sudo systemctl restart hysteria-server.service"

# Verify service is running
SERVICE_ACTIVE="$(ssh_remote "systemctl is-active hysteria-server.service 2>/dev/null || systemctl is-active hysteria.service 2>/dev/null || echo 'failed'" | tr -d '\r\n')"
if [[ "$SERVICE_ACTIVE" != "active" ]]; then
    echo "[!] Warning: Hysteria service status is '$SERVICE_ACTIVE'" >&2
    echo "    Logs:" >&2
    ssh_remote "journalctl -u hysteria-server -n 20 --no-pager 2>/dev/null || true" >&2
fi

# Step 6: Generate keys for target users using `hysteria share` or canonical URI fallback
echo
echo "[*] Generating client credentials..."

for u in "${USERS[@]}"; do
    PASS="${USER_PASSWORDS[$u]}"
    OUT_FILE="$OUT_DIR/$TARGET/${u}.txt"
    INFO_FILE="$OUT_DIR/$TARGET/${u}.info"

    if [[ -e "$OUT_FILE" && "$FORCE" -eq 0 && "$SKIP_EXISTING" -eq 1 ]]; then
        echo "    Skipping existing local output for $u"
        continue
    fi

    # Build temporary client.yaml on remote to run `hysteria share`
    REMOTE_CLIENT_TMP="/tmp/hy2_client_${u}_$$.yaml"
    ssh_remote "cat > $(sq "$REMOTE_CLIENT_TMP") <<'EOF'
server: ${FINAL_ENDPOINT}
auth: ${u}:${PASS}
tls:
  sni: ${FINAL_SNI}
  insecure: $([[ "$FINAL_INSECURE" -eq 1 ]] && echo 'true' || echo 'false')
EOF
chmod 600 $(sq "$REMOTE_CLIENT_TMP")"

    # Try `hysteria share -c ...`
    SHARE_URI="$(ssh_remote "sudo hysteria share -c $(sq "$REMOTE_CLIENT_TMP") 2>/dev/null || sudo /usr/local/bin/hysteria share -c $(sq "$REMOTE_CLIENT_TMP") 2>/dev/null || true" \
        | grep -oE '(hysteria2|hy2)://[^[:space:]]+' \
        | head -n1 || true)"

    # Clean up remote temporary client.yaml
    ssh_remote "rm -f $(sq "$REMOTE_CLIENT_TMP")"

    # If hysteria share produced a URI, use it. Otherwise, format the standard canonical URI:
    if [[ -z "$SHARE_URI" ]]; then
        INSECURE_PARAM=""
        if [[ "$FINAL_INSECURE" -eq 1 ]]; then
            INSECURE_PARAM="&insecure=1"
        fi
        SHARE_URI="hysteria2://${u}:${PASS}@${ENDPOINT_HOST}:${HY2_PORT}/?sni=${FINAL_SNI}${INSECURE_PARAM}#${TARGET}"
    fi

    {
        printf '# Hysteria 2 connection link for %s\n' "$u"
        printf '%s\n' "$SHARE_URI"
    } > "$OUT_FILE"
    chmod 600 "$OUT_FILE"

    {
        echo "username=$u"
        echo "server=$FINAL_ENDPOINT"
        echo "auth=${u}:${PASS}"
        echo "sni=$FINAL_SNI"
        echo "insecure=$FINAL_INSECURE"
        echo "uri=$SHARE_URI"
        echo "created_at=$GEN_TS"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"

    echo "    [OK] $u -> $OUT_FILE"
done

echo
echo "[+] Done. Configs saved in $OUT_DIR/$TARGET"
ls -lah "$OUT_DIR/$TARGET"
