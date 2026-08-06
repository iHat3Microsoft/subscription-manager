#!/usr/bin/env bash
# sub_vless.sh — сгенерить vless-ключи на всех юзеров subscription-manager'а
# через Marzban API и разложить в data/<user>/foreign/<name>.txt.
#
# Просто запусти `sub_vless.sh` — он сам спросит что нужно:
#   Panel URL (например https://mirror.uvx.lol)
#   Admin username (sudoer)
#   Admin password (ввод скрыт, либо из $MARZBAN_ADMIN_PASSWORD)
#   Имя файла в foreign/ (по умолчанию Marzban.txt)
#
# Опциональные ключи:
#   --dry-run              ничего не менять, только показать план
#   --skip-build           не запускать buildvpn после раскладки
#   --shared-url URL       один URL для ВСЕХ юзеров (без API/ключей)
#   --server-alias NAME    имя папки для out_keys/ (любое, дефолт: vless)
#   --reuse-local          использовать уже готовые out_keys/<a>/<u>.vless
#   --limit-gb N / --expire-days N
#
# Зависимости: bash, ssh, scp, jq, curl.
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"
LOCAL_OUT_DIR="./out_keys"
GEN_SCRIPT="${GEN_SCRIPT:-./gen_vless.sh}"
REMOTE_FILENAME="${REMOTE_FILENAME:-Marzban.txt}"
SERVER_ALIAS="${SERVER_ALIAS:-vless}"
USERS_OVERRIDE=""

DRY_RUN=0
SKIP_BUILD=0
REUSE_LOCAL=0
SHARED_URL=""

# gen_vless pass-throughs
GEN_PANEL=""
GEN_ADMIN=""
GEN_PASSWORD_ENV="${MARZBAN_PASSWORD_ENV:-MARZBAN_ADMIN_PASSWORD}"
GEN_INBOUND=""
GEN_LIMIT_GB=0
GEN_EXPIRE_DAYS=0

have_tty() { [[ -t 0 ]]; }

ask() {
    # ask <varname> <prompt>
    local var="$1" msg="$2"
    if [[ -n "${!var:-}" ]]; then return 0; fi
    if ! have_tty; then
        echo "[!] $msg (stdin not a TTY; pass via --${var,,} <value>)" >&2
        return 1
    fi
    printf '%s\n' "$msg"
    read -rp "> " "$var"
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME                  # interactive — asks everything
  $SCRIPT_NAME [options]

Options:
  --nether HOST         Subscription-manager SSH alias, default: nether2
  --data-dir PATH       Remote data dir, default: /opt/subscription-manager/data

  --shared-url URL      Lay a single http URL into every user's
                        data/<u>/foreign/<name>.txt (no Marzban API call)
                        Most useful when a single Marzban sub URL is shared
                        by all users. mihomo fetches & parses it itself.
  --name FILENAME       Remote filename in foreign/, default: $REMOTE_FILENAME
  --users "u1 u2 ..."   Restrict to subset (skip ssh enumeration)
  --skip-build          Do not run buildvpn after upload
  --dry-run             Show plan only

gen_vless.sh mode (default if no --shared-url):
  --server-alias NAME   Local folder name for out_keys/, default: vless
  --reuse-local         Skip gen_vless.sh; need files already in out_keys/
  --panel URL           Marzban panel URL (forwarded to gen_vless.sh)
  --admin USERNAME      Marzban sudoer username (forwarded to gen_vless.sh)
  --password-env VAR    Env var holding admin password, default: MARZBAN_ADMIN_PASSWORD
  --inbound TAG         Default: VLESS TCP VISION REALITY
  --limit-gb N          Data limit per user, 0 = unlimited
  --expire-days N       Account lifetime, 0 = no expiry
  --gen-script PATH     Default: $GEN_SCRIPT

  -h, --help            Show this help
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
        --shared-url)
            SHARED_URL="${2:?missing url}"
            shift 2
            ;;
        --name)
            REMOTE_FILENAME="${2:?missing filename}"
            shift 2
            ;;
        --server-alias)
            SERVER_ALIAS="${2:?missing alias}"
            shift 2
            ;;
        --users)
            USERS_OVERRIDE="${2:?missing users}"
            shift 2
            ;;
        --build-cmd)
            BUILD_CMD="${2:?missing build cmd}"
            shift 2
            ;;
        --gen-script)
            GEN_SCRIPT="${2:?missing gen script}"
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
        --password-env)
            GEN_PASSWORD_ENV="${2:?missing var}"
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
            echo "[!] Unexpected positional: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Filename: required
if [[ -z "$REMOTE_FILENAME" ]]; then
    ask REMOTE_FILENAME "Filename inside foreign/, e.g. Marzban.txt"
    [[ -z "$REMOTE_FILENAME" ]] && REMOTE_FILENAME="Marzban.txt"
fi
case "$REMOTE_FILENAME" in
    */*|.*|..)
        echo "[!] Bad filename: $REMOTE_FILENAME" >&2
        exit 1
        ;;
esac

sq() { printf "'"; printf "%s" "$1" | sed "s/'/'\\\\''/g"; printf "'"; }

# ===========================================================
# Mode 1: shared URL (simple)
# ===========================================================
if [[ -n "$SHARED_URL" ]]; then
    echo "[*] Mode: shared URL -> every user"
    echo "[*] URL:        $SHARED_URL"
    echo "[*] Filename:   $REMOTE_FILENAME"
    echo "[*] Remote:     $NETHER_HOST"

    if [[ -n "$USERS_OVERRIDE" ]]; then
        mapfile -t USERS < <(printf '%s\n' "$USERS_OVERRIDE" | tr ' ' '\n' | sed '/^$/d')
    else
        mapfile -t USERS < <(
            ssh "$NETHER_HOST" "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n'" 2>/dev/null \
                | LC_ALL=C sort
        )
    fi

    if [[ "${#USERS[@]}" -eq 0 ]]; then
        echo "[!] No users found" >&2
        exit 1
    fi

    echo "[*] Users: ${#USERS[@]}"
    printf '    %s\n' "${USERS[@]}"
    echo

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY] Would write URL into $NETHER_HOST:$DATA_DIR/<u>/foreign/$REMOTE_FILENAME"
        for u in "${USERS[@]}"; do
            ssh "$NETHER_HOST" "test -e $(sq "$DATA_DIR/$u/foreign/$REMOTE_FILENAME")" 2>/dev/null && \
                echo "[DRY]   (remote already exists: $u)" >&2
        done
        exit 0
    fi

    EXISTING_REMOTE=()
    for u in "${USERS[@]}"; do
        if ssh "$NETHER_HOST" "test -e $(sq "$DATA_DIR/$u/foreign/$REMOTE_FILENAME")" 2>/dev/null; then
            EXISTING_REMOTE+=("$DATA_DIR/$u/foreign/$REMOTE_FILENAME")
        fi
    done
    if [[ "${#EXISTING_REMOTE[@]}" -gt 0 ]]; then
        echo "[!] Abort: existing remote files:" >&2
        printf '    %s\n' "${EXISTING_REMOTE[@]}" >&2
        exit 1
    fi

    for u in "${USERS[@]}"; do
        remote_dir="$DATA_DIR/$u/foreign"
        remote_dst="$remote_dir/$REMOTE_FILENAME"
        remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"
        ssh "$NETHER_HOST" "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
        ssh "$NETHER_HOST" "set -e; umask 077; cat > $(sq "$remote_tmp")" <<< "$SHARED_URL"
        ssh "$NETHER_HOST" "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
        echo "    [OK] $u"
    done

    echo "[+] Done pushing"
    [[ "$SKIP_BUILD" -eq 1 ]] && exit 0
    echo "[*] Running buildvpn..."
    cd_esc=$(printf '%s' "$DATA_DIR" | sed "s/'/'\\\\''/g")
    ssh -tt "$NETHER_HOST" "bash -ic 'cd ${cd_esc} && ${BUILD_CMD}'"
    exit 0
fi

# ===========================================================
# Mode 2 (default): per-user via Marzban API (or --reuse-local)
# ===========================================================

# Ask minimal: panel URL, admin username, password (env or tty)
# Server-alias defaults to 'vless' - just a local folder name
# Filename defaults to 'Marzban.txt'

ask GEN_PANEL "Marzban panel URL (e.g. https://mirror.uvx.lol, NO /api)"
if [[ -z "$GEN_PANEL" ]]; then
    echo "[!] panel URL required (or pass --shared-url instead)" >&2
    exit 1
fi
# Strip trailing slash just in case
GEN_PANEL="${GEN_PANEL%/}"
if ! [[ "$GEN_PANEL" =~ ^https?:// ]]; then
    echo "[!] not an http(s) URL: $GEN_PANEL" >&2
    exit 1
fi

ask GEN_ADMIN "Admin / sudoer username"

echo
echo "[*] Subscription host: $NETHER_HOST"
echo "[*] Data dir:          $DATA_DIR"
echo "[*] Remote filename:   $REMOTE_FILENAME"
echo "[*] Local folder:      $LOCAL_OUT_DIR/$SERVER_ALIAS/"
echo

# User list via ssh
if [[ -n "$USERS_OVERRIDE" ]]; then
    mapfile -t USERS < <(printf '%s\n' "$USERS_OVERRIDE" | tr ' ' '\n' | sed '/^$/d')
    echo "[*] Using --users: ${#USERS[@]} user(s)"
else
    echo "[*] Reading users from $NETHER_HOST..."
    mapfile -t USERS < <(
        ssh "$NETHER_HOST" "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n'" \
            || { echo "[!] ssh failed" >&2; exit 1; }
    ) || true
fi

if [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "[!] No users found on $NETHER_HOST:$DATA_DIR" >&2
    exit 1
fi

echo "[*] ${#USERS[@]} users will get a key. Names: ${USERS[*]}"
echo

# Pre-flight: existing remote files
EXISTING_REMOTE=()
for u in "${USERS[@]}"; do
    if ssh "$NETHER_HOST" "test -e $(sq "$DATA_DIR/$u/foreign/$REMOTE_FILENAME")" 2>/dev/null; then
        EXISTING_REMOTE+=("$DATA_DIR/$u/foreign/$REMOTE_FILENAME")
    fi
done
if [[ "${#EXISTING_REMOTE[@]}" -gt 0 ]]; then
    echo "[!] Abort: these remote files already exist:" >&2
    printf '    %s\n' "${EXISTING_REMOTE[@]}" >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "$REUSE_LOCAL" -eq 1 ]] && echo "[DRY] Reuse-local: skip gen_vless.sh" || echo "[DRY] Would run gen_vless.sh for ${#USERS[@]} users"
    echo "[DRY] Would upload ${#USERS[@]} files"
    for u in "${USERS[@]}"; do
        echo "    out_keys/$SERVER_ALIAS/${u}.vless -> $NETHER_HOST:$DATA_DIR/$u/foreign/$REMOTE_FILENAME"
    done
    exit 0
fi

if [[ "$REUSE_LOCAL" -eq 1 ]]; then
    MISSING_LOCAL=()
    for u in "${USERS[@]}"; do
        [[ ! -s "$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless" ]] && MISSING_LOCAL+=("$u")
    done
    if [[ "${#MISSING_LOCAL[@]}" -gt 0 ]]; then
        echo "[!] Missing files in $LOCAL_OUT_DIR/$SERVER_ALIAS/: ${MISSING_LOCAL[*]}" >&2
        exit 1
    fi
else
    [[ ! -f "$GEN_SCRIPT" ]] && { echo "[!] $GEN_SCRIPT not found" >&2; exit 1; }

    GEN_CMD=(bash "$GEN_SCRIPT"
        --panel "$GEN_PANEL"
        --admin "$GEN_ADMIN"
        --skip-existing
        --password-env "$GEN_PASSWORD_ENV"
        --out-dir "$LOCAL_OUT_DIR"
    )
    if [[ -n "$GEN_INBOUND" ]]; then
        GEN_CMD+=(--inbound "$GEN_INBOUND")
    fi
    if [[ "${GEN_LIMIT_GB:-0}" -gt 0 ]]; then
        GEN_CMD+=(--limit-gb "$GEN_LIMIT_GB")
    fi
    if [[ "${GEN_EXPIRE_DAYS:-0}" -gt 0 ]]; then
        GEN_CMD+=(--expire-days "$GEN_EXPIRE_DAYS")
    fi
    GEN_CMD+=("$SERVER_ALIAS")
    GEN_CMD+=("${USERS[@]}")

    echo "[*] Running: ${GEN_CMD[*]}"
    echo
    "${GEN_CMD[@]}"
fi

echo
echo "[*] Uploading to $NETHER_HOST..."
for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless"
    remote_dir="$DATA_DIR/$u/foreign"
    remote_dst="$remote_dir/$REMOTE_FILENAME"
    remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"
    ssh "$NETHER_HOST" "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
    ssh "$NETHER_HOST" "set -e; umask 077; cat > $(sq "$remote_tmp")" < "$conf"
    ssh "$NETHER_HOST" "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
    echo "    [OK] $u"
done

echo "[+] Done"
[[ "$SKIP_BUILD" -eq 1 ]] && exit 0
echo "[*] Running buildvpn..."
cd_esc=$(printf '%s' "$DATA_DIR" | sed "s/'/'\\\\''/g")
ssh -tt "$NETHER_HOST" "bash -ic 'cd ${cd_esc} && ${BUILD_CMD}'"
