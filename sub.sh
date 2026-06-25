#!/usr/bin/env bash
set -euo pipefail

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
GEN_SCRIPT="${GEN_SCRIPT:-./gen.sh}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"

DRY_RUN=0
SKIP_BUILD=0
REMOTE_FILENAME=""

usage() {
    cat <<EOF
Usage:
  $0 [options] <vpn-server-alias>

Example:
  $0 finland
  $0 --name 'Финляндия.txt' finland
  $0 --dry-run --name 'Финляндия.txt' finland

Options:
  --nether HOST        Subscription-manager SSH alias, default: nether2
  --data-dir PATH      Remote data dir, default: /opt/subscription-manager/data
  --name FILENAME      Filename inside every foreign/ dir, example: Финляндия.txt
  --gen-script PATH    Local generator script, default: ./gen.sh
  --build-cmd CMD      Remote build command, default: buildvpn
  --skip-build         Do not run buildvpn after upload
  --dry-run            Only show what would be done
  -h, --help           Show help
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
        --gen-script)
            GEN_SCRIPT="${2:?missing gen script}"
            shift 2
            ;;
        --build-cmd)
            BUILD_CMD="${2:?missing build command}"
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
            echo "[!] Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

VPN_SERVER="${1:-}"

if [[ -z "$VPN_SERVER" ]]; then
    usage
    exit 1
fi

if [[ ! -f "$GEN_SCRIPT" ]]; then
    echo "[!] gen script not found: $GEN_SCRIPT"
    exit 1
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    read -rp "Filename inside every foreign/ folder, example Финляндия.txt: " REMOTE_FILENAME
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    echo "[!] Empty filename"
    exit 1
fi

case "$REMOTE_FILENAME" in
    */*|.*|..)
        echo "[!] Bad filename: $REMOTE_FILENAME"
        echo "    Use only plain filename, not path."
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

echo "[*] VPN server: $VPN_SERVER"
echo "[*] Subscription host: $NETHER_HOST"
echo "[*] Data dir: $DATA_DIR"
echo "[*] Foreign filename: $REMOTE_FILENAME"
echo

echo "[*] Reading users from $NETHER_HOST..."

mapfile -t USERS < <(
    ssh_nether "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | LC_ALL=C sort"
)

if [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "[!] No users found in $NETHER_HOST:$DATA_DIR"
    exit 1
fi

echo "[*] Found users: ${#USERS[@]}"
printf '    %s\n' "${USERS[@]}"
echo

for u in "${USERS[@]}"; do
    if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[!] User folder name is not suitable for gen.sh: $u"
        echo "    Allowed: letters, digits, dot, underscore, dash."
        exit 1
    fi
done

echo "[*] Preflight: checking remote target files..."

EXISTING_REMOTE=()

for u in "${USERS[@]}"; do
    dst="$DATA_DIR/$u/foreign/$REMOTE_FILENAME"

    if ssh_nether "test -e $(sq "$dst")"; then
        EXISTING_REMOTE+=("$dst")
    fi
done

if [[ "${#EXISTING_REMOTE[@]}" -gt 0 ]]; then
    echo "[!] Abort: these remote files already exist, refusing to overwrite:"
    printf '    %s\n' "${EXISTING_REMOTE[@]}"
    exit 1
fi

LOCAL_OUT_DIR="./out_keys/$VPN_SERVER"
EXISTING_LOCAL=()

for u in "${USERS[@]}"; do
    [[ -e "$LOCAL_OUT_DIR/$u.conf" ]] && EXISTING_LOCAL+=("$LOCAL_OUT_DIR/$u.conf")
    [[ -e "$LOCAL_OUT_DIR/$u.info" ]] && EXISTING_LOCAL+=("$LOCAL_OUT_DIR/$u.info")
done

if [[ "${#EXISTING_LOCAL[@]}" -gt 0 ]]; then
    echo "[!] Abort: local generated files already exist, refusing to continue:"
    printf '    %s\n' "${EXISTING_LOCAL[@]}"
    echo
    echo "    Move/remove old files or use a clean output directory for gen.sh."
    exit 1
fi

echo "[*] Preflight OK"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would run:"
    printf '    bash %q %q' "$GEN_SCRIPT" "$VPN_SERVER"
    printf ' %q' "${USERS[@]}"
    echo
    echo
    echo "[DRY-RUN] Would upload:"
    for u in "${USERS[@]}"; do
        echo "    $LOCAL_OUT_DIR/$u.conf -> $NETHER_HOST:$DATA_DIR/$u/foreign/$REMOTE_FILENAME"
    done
    echo
    if [[ "$SKIP_BUILD" -eq 0 ]]; then
        echo "[DRY-RUN] Would run on $NETHER_HOST:"
        echo "    cd $DATA_DIR && $BUILD_CMD"
    fi
    exit 0
fi

echo "[*] Generating VPN configs with $GEN_SCRIPT..."
bash "$GEN_SCRIPT" "$VPN_SERVER" "${USERS[@]}"

echo
echo "[*] Checking generated configs..."

for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$u.conf"

    if [[ ! -s "$conf" ]]; then
        echo "[!] Missing generated config: $conf"
        exit 1
    fi
done

echo "[*] Uploading configs to $NETHER_HOST..."

for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$u.conf"
    remote_dir="$DATA_DIR/$u/foreign"
    remote_dst="$remote_dir/$REMOTE_FILENAME"
    remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"

    echo "    $u -> $remote_dst"

    ssh_nether "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"

    ssh_nether "set -e; umask 077; cat > $(sq "$remote_tmp")" < "$conf"

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

ssh -tt "$NETHER_HOST" "cd $(sq "$DATA_DIR") && $BUILD_CMD"
