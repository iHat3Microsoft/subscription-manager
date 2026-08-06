#!/usr/bin/env bash
# sub_vless.sh — кладёт vless://-ключи из out_keys/<server-alias>/<user>.vless
# в data/<user>/foreign/<remote-filename>.txt на удалённом сервере и
# запускает buildvpn. Зеркало sub.sh, но для vless-ключей.
#
# Зависимости: bash, ssh, scp.
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"
LOCAL_OUT_DIR_BASE="./out_keys"

DRY_RUN=0
SKIP_BUILD=0
REMOTE_FILENAME=""
USERS_OVERRIDE=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] <server-alias>

Example:
  $SCRIPT_NAME marzban1
  $SCRIPT_NAME --name 'Marzban.txt' marzban1
  $SCRIPT_NAME --dry-run --name 'Marzban.txt' marzban1

Options:
  --nether HOST        Subscription-manager SSH alias, default: nether2
  --data-dir PATH      Remote data dir, default: /opt/subscription-manager/data
  --name FILENAME      Remote filename in foreign/ for every user
                       (e.g. Marzban.txt)
  --build-cmd CMD      Remote build command, default: buildvpn
  --local-out DIR      Base dir with generated keys, default: ./out_keys
                       Keys taken from <DIR>/<server-alias>/<user>.vless
  --users "u1 u2 ..."  Override user list (skip ssh enumeration)
  --skip-build         Do not run buildvpn after upload
  --dry-run            Only show what would be done
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nether)
            NETHER_HOST="${2:?missing nether host}"
            shift 2
            ;;
        --data-dir)
            DATA_DIR="${2:?missing data dir}"
            shift 2
            ;;
        --name)
            REMOTE_FILENAME="${2:?missing filename}"
            shift 2
            ;;
        --build-cmd)
            BUILD_CMD="${2:?missing build cmd}"
            shift 2
            ;;
        --local-out)
            LOCAL_OUT_DIR_BASE="${2:?missing local out dir}"
            shift 2
            ;;
        --users)
            USERS_OVERRIDE="${2:?missing users}"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "[!] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

SERVER_ALIAS="${1:-}"
if [[ -z "$SERVER_ALIAS" ]]; then
    echo "[!] Server alias is required." >&2
    usage >&2
    exit 1
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    read -rp "Filename inside foreign/, e.g. Marzban.txt: " REMOTE_FILENAME
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    echo "[!] Empty filename" >&2
    exit 1
fi

case "$REMOTE_FILENAME" in
    */*|.*|..)
        echo "[!] Bad filename: $REMOTE_FILENAME" >&2
        echo "    Use only plain filename, no path, not starting with dot." >&2
        exit 1
        ;;
esac

sq() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

ssh_nether() {
    ssh "$NETHER_HOST" "$@"
}

LOCAL_OUT_DIR="$LOCAL_OUT_DIR_BASE/$SERVER_ALIAS"

echo "[*] Server alias:       $SERVER_ALIAS"
echo "[*] Subscription host:  $NETHER_HOST"
echo "[*] Data dir:           $DATA_DIR"
echo "[*] Local keys dir:     $LOCAL_OUT_DIR"
echo "[*] Remote filename:    $REMOTE_FILENAME"
echo

if [[ -n "$USERS_OVERRIDE" ]]; then
    mapfile -t USERS < <(printf '%s\n' "$USERS_OVERRIDE" | tr ' ' '\n' | sed '/^$/d')
    echo "[*] Using --users override: ${#USERS[@]} user(s)"
else
    echo "[*] Reading users from $NETHER_HOST..."
    mapfile -t USERS < <(
        ssh_nether "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | LC_ALL=C sort"
    )
fi

if [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "[!] No users found in $NETHER_HOST:$DATA_DIR" >&2
    exit 1
fi

echo "[*] Found users: ${#USERS[@]}"
printf '    %s\n' "${USERS[@]}"
echo

for u in "${USERS[@]}"; do
    if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[!] Bad user folder name: $u" >&2
        exit 1
    fi
done

echo "[*] Preflight: local vless files..."
MISSING_LOCAL=()
for u in "${USERS[@]}"; do
    local_file="$LOCAL_OUT_DIR/${u}.vless"
    if [[ ! -s "$local_file" ]]; then
        MISSING_LOCAL+=("$u (missing $local_file)")
    fi
done
if [[ "${#MISSING_LOCAL[@]}" -gt 0 ]]; then
    echo "[!] Missing local vless files for:" >&2
    printf '    %s\n' "${MISSING_LOCAL[@]}" >&2
    echo "    Run gen_vless.sh $SERVER_ALIAS <users> first." >&2
    exit 1
fi

echo "[*] Preflight: checking remote target files..."
EXISTING_REMOTE=()
for u in "${USERS[@]}"; do
    dst="$DATA_DIR/$u/foreign/$REMOTE_FILENAME"
    if ssh_nether "test -e $(sq "$dst")"; then
        EXISTING_REMOTE+=("$dst")
    fi
done

if [[ "${#EXISTING_REMOTE[@]}" -gt 0 ]]; then
    echo "[!] Abort: these remote files already exist, refusing to overwrite:" >&2
    printf '    %s\n' "${EXISTING_REMOTE[@]}" >&2
    exit 1
fi

echo "[*] Preflight OK"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would upload:"
    for u in "${USERS[@]}"; do
        echo "    $LOCAL_OUT_DIR/${u}.vless -> $NETHER_HOST:$DATA_DIR/$u/foreign/$REMOTE_FILENAME"
    done
    echo
    if [[ "$SKIP_BUILD" -eq 0 ]]; then
        echo "[DRY-RUN] Would run on $NETHER_HOST:"
        echo "    cd $DATA_DIR && $BUILD_CMD"
    fi
    exit 0
fi

echo "[*] Uploading vless files to $NETHER_HOST..."
for u in "${USERS[@]}"; do
    local_file="$LOCAL_OUT_DIR/${u}.vless"
    remote_dir="$DATA_DIR/$u/foreign"
    remote_dst="$remote_dir/$REMOTE_FILENAME"
    remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"

    echo "    $u -> $remote_dst"

    ssh_nether "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
    ssh_nether "set -e; umask 077; cat > $(sq "$remote_tmp")" < "$local_file"
    ssh_nether "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
done

echo
echo "[+] Upload done"

if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "[*] Skipping buildvpn"
    exit 0
fi

echo
echo "[*] Running build command on $NETHER_HOST..."
echo "    cd $DATA_DIR && $BUILD_CMD"
echo

ssh -tt "$NETHER_HOST" "bash -ic $(sq "cd $(sq "$DATA_DIR") && $BUILD_CMD")"
