#!/usr/bin/env bash
# sub_vless.sh — зеркало sub.sh для vless-ключей.
#
# Логика (клон sub.sh):
#   1) ssh на NETHER_HOST: читает data/<user>/ папки (список юзеров).
#   2) Если нет --reuse-local — спрашивает panel/admin/inbound/limit/expire
#      и запускает gen_vless.sh <server-alias> <user1> <user2> ...
#      с этим списком (сгенерит ./out_keys/<alias>/<user>.vless).
#   3) Для каждого юзера кладёт ./out_keys/<server>/<user>.vless
#      в data/<user>/foreign/<remote-filename>.txt на удалёнке.
#   4) Запускает buildvpn на удалёнке (если не --skip-build).
#
# Зависимости: bash, ssh, jq, curl (нужны для gen_vless.sh при запуске).
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"
LOCAL_OUT_DIR="./out_keys"
GEN_SCRIPT="${GEN_SCRIPT:-./gen_vless.sh}"

DRY_RUN=0
SKIP_BUILD=0
REUSE_LOCAL=0
REMOTE_FILENAME=""
USERS_OVERRIDE=""

# Args, прокидываемые в gen_vless.sh при запуске
GEN_PANEL=""
GEN_ADMIN=""
GEN_INBOUND=""
GEN_LIMIT_GB=0
GEN_EXPIRE_DAYS=0
GEN_RESET_STRATEGY=""
GEN_FLOW=""
GEN_OUT_DIR=""
GEN_PASSWORD_ENV=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] <vpn-server-alias>

Example:
  $SCRIPT_NAME marzban1
  $SCRIPT_NAME --name 'Швеция1гбитVLESS.txt' marzban1
  $SCRIPT_NAME --dry-run --name 'Швеция1гбитVLESS.txt' marzban1
  $SCRIPT_NAME --reuse-local --skip-build --name 'Marzban.txt' marzban1

Options:
  --nether HOST         Subscription-manager SSH alias, default: nether2
  --data-dir PATH       Remote data dir, default: /opt/subscription-manager/data
  --name FILENAME       Remote filename in foreign/, e.g. 'Швеция1гбитVLESS.txt'
                        If omitted, asked interactively.
  --users "u1 u2 ..."   Override user list (skip ssh enumeration; useful for
                        --dry-run without ssh access to nether)
  --gen-script PATH     Local generator script, default: ./gen_vless.sh
  --build-cmd CMD       Remote build command, default: buildvpn
  --local-out DIR       Base dir for outputs, default: ./out_keys
                        Keys live in <DIR>/<server-alias>/<user>.vless
  --reuse-local         Skip gen_vless.sh; require ./out_keys/<alias>/<user>.vless
                        to already exist for every remote user.
  --skip-build          Do not run buildvpn after upload
  --dry-run             Only show what would be done

Options passed through to gen_vless.sh (only used without --reuse-local):
  --panel URL            Marzban panel URL
  --admin USERNAME       Marzban admin username
  --inbound TAG          Default: VLESS TCP VISION REALITY
  --limit-gb N           Data limit per user, default 0 (unlimited)
  --expire-days N        Account lifetime, default 0 (no expiry)
  --reset-strategy KEY   Default: day
  --flow NAME            Default: xtls-rprx-vision
  --out-dir DIR          Default: matches --local-out
  --password-env VAR     Env var holding admin password (skips interactive prompt)

  -h, --help             Show this help
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
            BUILD_CMD="${2:?missing build cmd}"
            shift 2
            ;;
        --local-out)
            LOCAL_OUT_DIR="${2:?missing local out dir}"
            shift 2
            ;;
        --users)
            USERS_OVERRIDE="${2:?missing users}"
            shift 2
            ;;
        --reuse-local)
            REUSE_LOCAL=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --panel)
            GEN_PANEL="${2:?missing panel}"
            shift 2
            ;;
        --admin)
            GEN_ADMIN="${2:?missing admin}"
            shift 2
            ;;
        --inbound)
            GEN_INBOUND="${2:?missing inbound}"
            shift 2
            ;;
        --limit-gb)
            GEN_LIMIT_GB="${2:?missing gb}"
            shift 2
            ;;
        --expire-days)
            GEN_EXPIRE_DAYS="${2:?missing days}"
            shift 2
            ;;
        --reset-strategy)
            GEN_RESET_STRATEGY="${2:?missing strategy}"
            shift 2
            ;;
        --flow)
            GEN_FLOW="${2:?missing flow}"
            shift 2
            ;;
        --out-dir)
            GEN_OUT_DIR="${2:?missing out-dir}"
            shift 2
            ;;
        --password-env)
            GEN_PASSWORD_ENV="${2:?missing var name}"
            shift 2
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

if [[ ! "$SERVER_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[!] Server alias must match ^[A-Za-z0-9._-]+\$" >&2
    exit 1
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    if [[ "$DRY_RUN" -eq 0 ]] && { exec 3</dev/tty; } 2>/dev/null; then
        read -rp "Filename inside foreign/, e.g. Marzban.txt: " REMOTE_FILENAME <&3
    fi
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

echo "[*] Server alias:       $SERVER_ALIAS"
echo "[*] Subscription host:  $NETHER_HOST"
echo "[*] Data dir:           $DATA_DIR"
echo "[*] Local keys dir:     $LOCAL_OUT_DIR/$SERVER_ALIAS"
echo "[*] Foreign filename:   $REMOTE_FILENAME"
if [[ $REUSE_LOCAL -eq 1 ]]; then
    echo "[*] Reuse-local:        yes (skip gen_vless.sh)"
else
    echo "[*] Reuse-local:        no  (will run $GEN_SCRIPT)"
fi
echo

if [[ -n "$USERS_OVERRIDE" ]]; then
    mapfile -t USERS < <(printf '%s\n' "$USERS_OVERRIDE" | tr ' ' '\n' | sed '/^$/d')
    echo "[*] Using --users override: ${#USERS[@]} user(s)"
else
    echo "[*] Reading users from $NETHER_HOST..."
    mapfile -t USERS < <(
        ssh_nether "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | LC_ALL=C sort"
    ) || {
        echo "[!] Could not list users on $NETHER_HOST:$DATA_DIR" >&2
        echo "    Use --users 'u1 u2 ...' for offline testing / --dry-run." >&2
        exit 1
    }
fi

if [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "[!] No users found." >&2
    exit 1
fi

echo "[*] Found users: ${#USERS[@]}"
printf '    %s\n' "${USERS[@]}"
echo

for u in "${USERS[@]}"; do
    if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[!] User folder name is not suitable: $u" >&2
        echo "    Allowed: letters, digits, dot, underscore, dash." >&2
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
    echo "[!] Abort: these remote files already exist, refusing to overwrite:" >&2
    printf '    %s\n' "${EXISTING_REMOTE[@]}" >&2
    exit 1
fi

echo "[*] Preflight OK"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ $REUSE_LOCAL -eq 1 ]]; then
        echo "[DRY-RUN] Would reuse existing local keys (skipping $GEN_SCRIPT)"
    else
        echo "[DRY-RUN] Would run:"
        printf '    bash %q %q' "$GEN_SCRIPT" "$SERVER_ALIAS"
        printf ' %q' "${USERS[@]}"
        echo
    fi
    echo
    echo "[DRY-RUN] Would upload:"
    for u in "${USERS[@]}"; do
        echo "    $LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless -> $NETHER_HOST:$DATA_DIR/$u/foreign/$REMOTE_FILENAME"
    done
    echo
    if [[ "$SKIP_BUILD" -eq 0 ]]; then
        echo "[DRY-RUN] Would run on $NETHER_HOST:"
        echo "    cd $DATA_DIR && $BUILD_CMD"
    fi
    exit 0
fi

if [[ $REUSE_LOCAL -eq 1 ]]; then
    echo "[*] Reuse-local: skipping $GEN_SCRIPT"
    MISSING_LOCAL=()
    for u in "${USERS[@]}"; do
        conf="$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless"
        if [[ ! -s "$conf" ]]; then
            MISSING_LOCAL+=("$u (missing $conf)")
        fi
    done
    if [[ ${#MISSING_LOCAL[@]} -gt 0 ]]; then
        echo "[!] --reuse-local: missing local generated files for:" >&2
        printf '    %s\n' "${MISSING_LOCAL[@]}" >&2
        echo "    Need $LOCAL_OUT_DIR/$SERVER_ALIAS/<user>.vless for every user." >&2
        echo "    Drop --reuse-local to regenerate via gen_vless.sh." >&2
        exit 1
    fi
else
    if [[ ! -f "$GEN_SCRIPT" ]]; then
        echo "[!] gen script not found: $GEN_SCRIPT" >&2
        exit 1
    fi

    GEN_CMD=(bash "$GEN_SCRIPT")
    [[ -n "$GEN_PANEL" ]]            && GEN_CMD+=(--panel "$GEN_PANEL")
    [[ -n "$GEN_ADMIN" ]]            && GEN_CMD+=(--admin "$GEN_ADMIN")
    [[ -n "$GEN_INBOUND" ]]          && GEN_CMD+=(--inbound "$GEN_INBOUND")
    [[ -n "$GEN_RESET_STRATEGY" ]]   && GEN_CMD+=(--reset-strategy "$GEN_RESET_STRATEGY")
    [[ -n "$GEN_FLOW" ]]             && GEN_CMD+=(--flow "$GEN_FLOW")
    [[ -n "$GEN_PASSWORD_ENV" ]]     && GEN_CMD+=(--password-env "$GEN_PASSWORD_ENV")
    [[ "$GEN_OUT_DIR" != "" ]]       && GEN_CMD+=(--out-dir "$GEN_OUT_DIR")
    [[ "${GEN_LIMIT_GB:-0}" -gt 0 ]] && GEN_CMD+=(--limit-gb "$GEN_LIMIT_GB")
    [[ "${GEN_EXPIRE_DAYS:-0}" -gt 0 ]] && GEN_CMD+=(--expire-days "$GEN_EXPIRE_DAYS")
    GEN_CMD+=(--skip-existing)
    GEN_CMD+=("$SERVER_ALIAS")
    GEN_CMD+=("${USERS[@]}")

    echo "[*] Generating vless configs with $GEN_SCRIPT..."
    echo "    ${GEN_CMD[*]}"
    echo
    "${GEN_CMD[@]}"
fi

echo
echo "[*] Checking generated configs..."
for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless"
    if [[ ! -s "$conf" ]]; then
        echo "[!] Missing generated vless: $conf" >&2
        exit 1
    fi
done

echo "[*] Uploading vless files to $NETHER_HOST..."
for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless"
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

ssh -tt "$NETHER_HOST" "bash -ic $(sq "cd $(sq "$DATA_DIR") && $BUILD_CMD")"
