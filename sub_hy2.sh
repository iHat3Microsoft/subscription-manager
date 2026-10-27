#!/usr/bin/env bash
# sub_hy2.sh — installs Hysteria 2 on VPN node (if missing), generates keys for all users
# from subscription-manager, uploads them to data/<user>/foreign/<name>.txt (or ru/),
# and executes `buildvpn` if no errors.
#
# Usage:
#   ./sub_hy2.sh [options] <vpn-server-alias>
#
# Examples:
#   ./sub_hy2.sh vds
#   ./sub_hy2.sh --name "Нидерланды_Hy2.txt" vds
#   ./sub_hy2.sh --domain mydomain.com --name "Нидерланды_Hy2.txt" vds
#   ./sub_hy2.sh --ru --name "Москва_Hy2.txt" moscow
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
GEN_SCRIPT="${GEN_SCRIPT:-./gen_hy2.sh}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"

DRY_RUN=0
SKIP_BUILD=0
REUSE_LOCAL=0
FORCE=0
CATEGORY="foreign"
REMOTE_FILENAME=""

VPN_SERVER=""
DOMAIN=""
EMAIL=""
HY2_PORT=""
INSECURE=0

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] <vpn-server-alias>

Examples:
  $SCRIPT_NAME vds
  $SCRIPT_NAME --name 'Нидерланды_Hy2.txt' vds
  $SCRIPT_NAME --domain mynode.com --name 'Нидерланды_Hy2.txt' vds
  $SCRIPT_NAME --ru --name 'Москва_Hy2.txt' moscow
  $SCRIPT_NAME --dry-run --name 'Нидерланды_Hy2.txt' vds

Options:
  --nether HOST        Subscription-manager SSH alias, default: nether2
  --data-dir PATH      Remote data dir, default: /opt/subscription-manager/data
  --name FILENAME      Filename inside target dir, example: Нидерланды_Hy2.txt
  --ru                 Upload to ru/ instead of foreign/
  --category DIR       Target directory inside user folder (foreign or ru), default: foreign
  --gen-script PATH    Local generator script, default: ./gen_hy2.sh
  --build-cmd CMD      Remote build command, default: buildvpn
  --hy2-port PORT      Hysteria listen UDP port, default: 443
  --domain DOMAIN      Domain name for TLS/ACME
  --email EMAIL        Email for Let's Encrypt ACME
  --insecure           Force self-signed certificate / insecure=1
  --skip-build         Do not run buildvpn after upload
  --reuse-local        Skip gen_hy2.sh, reuse already-generated ./out_keys/<server>/*.txt
  --force              Overwrite existing remote files instead of skipping them
  --dry-run            Only show what would be done
  -h, --help           Show help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nether)
            NETHER_HOST="${2:?missing nether host}"; shift 2 ;;
        --data-dir)
            DATA_DIR="${2:?missing data dir}"; shift 2 ;;
        --ru)
            CATEGORY="ru"; shift ;;
        --category|--dir)
            CATEGORY="${2:?missing category (foreign or ru)}"; shift 2 ;;
        --name)
            REMOTE_FILENAME="${2:?missing filename}"; shift 2 ;;
        --gen-script)
            GEN_SCRIPT="${2:?missing gen script}"; shift 2 ;;
        --build-cmd)
            BUILD_CMD="${2:?missing build command}"; shift 2 ;;
        --hy2-port)
            HY2_PORT="${2:?missing hy2 port}"; shift 2 ;;
        --domain)
            DOMAIN="${2:?missing domain}"; shift 2 ;;
        --email)
            EMAIL="${2:?missing email}"; shift 2 ;;
        --insecure)
            INSECURE=1; shift ;;
        --skip-build)
            SKIP_BUILD=1; shift ;;
        --reuse-local)
            REUSE_LOCAL=1; shift ;;
        --force)
            FORCE=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            echo "[!] Unknown option: $1" >&2
            usage >&2
            exit 1 ;;
        *)
            if [[ -z "${VPN_SERVER:-}" ]]; then
                VPN_SERVER="$1"
                shift
            else
                echo "[!] Unexpected argument: $1" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

have_tty() { [[ -t 0 ]]; }

if [[ -z "${VPN_SERVER:-}" ]]; then
    if have_tty; then
        read -rp "VPN server SSH alias (e.g. vds or finland): " VPN_SERVER
    fi
fi

if [[ -z "${VPN_SERVER:-}" ]]; then
    usage
    exit 1
fi

if [[ ! -f "$GEN_SCRIPT" ]]; then
    echo "[!] Generator script not found: $GEN_SCRIPT" >&2
    exit 1
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    if have_tty; then
        example_name=$([[ "$CATEGORY" == "ru" ]] && echo "Москва_Hy2.txt" || echo "Нидерланды_Hy2.txt")
        read -rp "Filename inside every ${CATEGORY}/ folder, example ${example_name}: " REMOTE_FILENAME
    fi
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    echo "[!] Empty filename" >&2
    exit 1
fi

case "$REMOTE_FILENAME" in
    */*|.*|..)
        echo "[!] Bad filename: $REMOTE_FILENAME" >&2
        echo "    Use only plain filename, not path." >&2
        exit 1
        ;;
esac

sq() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

SSH_TMP_DIR=$(mktemp -d "/tmp/sub_hy2_ssh.XXXXXX")
trap 'ssh -O exit -o ControlPath="$SSH_TMP_DIR/master.sock" "$NETHER_HOST" 2>/dev/null || true; rm -rf "$SSH_TMP_DIR"' EXIT

SSH_OPTS=(
    -o "ControlMaster=auto"
    -o "ControlPath=$SSH_TMP_DIR/master.sock"
    -o "ControlPersist=5m"
    -o "ConnectTimeout=15"
    -o "ServerAliveInterval=15"
    -o "ServerAliveCountMax=3"
    -o "StrictHostKeyChecking=accept-new"
)

ssh_nether() {
    ssh "${SSH_OPTS[@]}" "$NETHER_HOST" "$@"
}

echo "[*] VPN server: $VPN_SERVER"
echo "[*] Subscription host: $NETHER_HOST"
echo "[*] Data dir: $DATA_DIR"
echo "[*] Category: $CATEGORY"
echo "[*] Target filename: $REMOTE_FILENAME"
echo

echo "[*] Reading users from $NETHER_HOST..."

mapfile -t ALL_USERS < <(
    ssh_nether "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | LC_ALL=C sort"
)

if [[ "${#ALL_USERS[@]}" -eq 0 ]]; then
    echo "[!] No users found in $NETHER_HOST:$DATA_DIR" >&2
    exit 1
fi

echo "[*] Found users: ${#ALL_USERS[@]}"
printf '    %s\n' "${ALL_USERS[@]}"
echo

for u in "${ALL_USERS[@]}"; do
    if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[!] User folder name is not suitable for $GEN_SCRIPT: $u" >&2
        echo "    Allowed: letters, digits, dot, underscore, dash." >&2
        exit 1
    fi
done

echo "[*] Preflight: checking remote target files..."

NEEDED_USERS=()
SKIPPED_USERS=()

for u in "${ALL_USERS[@]}"; do
    dst="$DATA_DIR/$u/$CATEGORY/$REMOTE_FILENAME"

    if ssh_nether "test -e $(sq "$dst")"; then
        if [[ "$FORCE" -eq 1 ]]; then
            NEEDED_USERS+=("$u")
        else
            SKIPPED_USERS+=("$u")
        fi
    else
        NEEDED_USERS+=("$u")
    fi
done

if [[ "${#SKIPPED_USERS[@]}" -gt 0 ]]; then
    echo "[*] Already provisioned (${#SKIPPED_USERS[@]} user(s), skipping):"
    printf '    %s\n' "${SKIPPED_USERS[@]}"
    echo
fi

if [[ "${#NEEDED_USERS[@]}" -eq 0 ]]; then
    echo "[+] All users already have $REMOTE_FILENAME. Nothing to generate."
    exit 0
fi

USERS=("${NEEDED_USERS[@]}")
echo "[*] Target users to generate and upload (${#USERS[@]} user(s)):"
printf '    %s\n' "${USERS[@]}"
echo

LOCAL_OUT_DIR="./out_keys/$VPN_SERVER"

if [[ "$REUSE_LOCAL" -eq 1 ]]; then
    MISSING_LOCAL=()
    for u in "${USERS[@]}"; do
        [[ ! -e "$LOCAL_OUT_DIR/$u.txt" ]] && MISSING_LOCAL+=("$u")
    done

    if [[ "${#MISSING_LOCAL[@]}" -gt 0 ]]; then
        echo "[!] --reuse-local: missing local generated files for:" >&2
        printf '    %s\n' "${MISSING_LOCAL[@]}" >&2
        echo "    Need <user>.txt in $LOCAL_OUT_DIR" >&2
        exit 1
    fi
else
    EXISTING_LOCAL=()
    for u in "${USERS[@]}"; do
        [[ -e "$LOCAL_OUT_DIR/$u.txt" ]] && EXISTING_LOCAL+=("$LOCAL_OUT_DIR/$u.txt")
        [[ -e "$LOCAL_OUT_DIR/$u.info" ]] && EXISTING_LOCAL+=("$LOCAL_OUT_DIR/$u.info")
    done

    if [[ "${#EXISTING_LOCAL[@]}" -gt 0 ]]; then
        echo "[*] Removing stale local generated files for target users..."
        rm -f "${EXISTING_LOCAL[@]}"
    fi
fi

# Prepare arguments for gen_hy2.sh
GEN_ARGS=()
if [[ -n "$HY2_PORT" ]]; then
    GEN_ARGS+=(--hy2-port "$HY2_PORT")
fi
if [[ -n "$DOMAIN" ]]; then
    GEN_ARGS+=(--domain "$DOMAIN")
fi
if [[ -n "$EMAIL" ]]; then
    GEN_ARGS+=(--email "$EMAIL")
fi
if [[ "$INSECURE" -eq 1 ]]; then
    GEN_ARGS+=(--insecure)
fi
if [[ "$FORCE" -eq 1 ]]; then
    GEN_ARGS+=(--force)
fi

echo "[*] Preflight OK"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$REUSE_LOCAL" -eq 1 ]]; then
        echo "[DRY-RUN] Reusing existing local configs (skipping $GEN_SCRIPT)"
    else
        echo "[DRY-RUN] Would run:"
        printf '    bash %q' "$GEN_SCRIPT"
        printf ' %q' "${GEN_ARGS[@]}" "$VPN_SERVER" "${USERS[@]}"
        echo
    fi
    echo
    echo "[DRY-RUN] Would upload:"
    for u in "${USERS[@]}"; do
        echo "    $LOCAL_OUT_DIR/$u.txt -> $NETHER_HOST:$DATA_DIR/$u/$CATEGORY/$REMOTE_FILENAME"
    done
    echo
    if [[ "$SKIP_BUILD" -eq 0 ]]; then
        echo "[DRY-RUN] Would run on $NETHER_HOST:"
        echo "    cd $DATA_DIR && $BUILD_CMD"
    fi
    exit 0
fi

if [[ "$REUSE_LOCAL" -eq 1 ]]; then
    echo "[*] Reusing existing local configs in $LOCAL_OUT_DIR (skipping $GEN_SCRIPT)"
else
    echo "[*] Deploying Hysteria 2 and generating client keys with $GEN_SCRIPT..."
    bash "$GEN_SCRIPT" "${GEN_ARGS[@]}" "$VPN_SERVER" "${USERS[@]}"
fi

echo
echo "[*] Checking generated configs..."

for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$u.txt"
    if [[ ! -s "$conf" ]]; then
        echo "[!] Missing generated config: $conf" >&2
        exit 1
    fi
done

echo "[*] Uploading configs to $NETHER_HOST..."

for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$u.txt"
    remote_dir="$DATA_DIR/$u/$CATEGORY"
    remote_dst="$remote_dir/$REMOTE_FILENAME"
    remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"

    echo "    $u -> $remote_dst"

    ssh_nether "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
    ssh_nether "set -e; umask 077; cat > $(sq "$remote_tmp")" < "$conf"
    ssh_nether "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
done

echo
echo "[+] Upload done successfully"

if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "[*] Skipping buildvpn (--skip-build specified)"
    exit 0
fi

echo
echo "[*] Running build command on $NETHER_HOST..."
echo "    cd $DATA_DIR && $BUILD_CMD"
echo

ssh -tt "$NETHER_HOST" "bash -ic $(sq "cd $(sq "$DATA_DIR") && $BUILD_CMD")"
