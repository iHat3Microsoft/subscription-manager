#!/usr/bin/env bash
# sub_vless.sh — интерактивная утилита для раздачи vless всем юзерам на nether2.
#
# Запускай `sub_vless.sh` без аргументов — всё спросит сам.
#
# Два режима (выбирается в начале интерактивно):
#   1) shared-url: один Marzban sub URL прокидывается во все foreign/<name>.txt
#      каждого юзера на nether2. mihomo сам подтянет YAML с User-Agent clash.meta.
#   2) legacy / per-user: генерит vless:// каждый через Marzban API (POST /api/user)
#      или берёт локальные out_keys/<server>/<user>.vless. Кладёт содержимое в foreign/.
#
# Зависимости: bash, ssh, curl, jq.
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
SHARED_URL=""
SERVER_ALIAS=""

# gen_vless passthroughs
GEN_PANEL=""
GEN_ADMIN=""
GEN_INBOUND=""
GEN_LIMIT_GB=0
GEN_EXPIRE_DAYS=0
GEN_RESET_STRATEGY=""
GEN_FLOW=""
GEN_OUT_DIR=""
GEN_PASSWORD_ENV=""

# ----- interactive prompt helpers -----
have_tty() { [[ -t 0 ]]; }
prompt() {
    local msg="$1" var="$2" optional="${3:-0}"
    if [[ -n "${!var:-}" ]]; then return; fi
    if ! have_tty; then
        if [[ "$optional" == 1 ]]; then
            printf '%s%s (env %s=[..] or use --%s argument)' \
                "$msg" "$([ -n "$msg" ] && echo ":")" \
                "${var}" "${var,,}" >&2
            return 1 2>/dev/null || return 0
        fi
        echo "[!] $msg (stdin not a TTY; pass via flag or env)" >&2
        return 1
    fi
    printf '%s\n' "$msg"
    read -rp "> " "$var"
}
yes_no() {
    local msg="${1:-proceed?}" def="${2:-Y}"
    if ! have_tty; then
        echo "[!] $msg (stdin not a TTY; cannot prompt)" >&2
        return 1
    fi
    read -rp "$msg [$def]> " ans
    [[ -z "$ans" ]] && ans="$def"
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME                                 # interactive — asks everything
  $SCRIPT_NAME [options]                       # or pass flags

Run without flags for fully interactive flow.

Options:
  --nether HOST         Subscription-manager SSH alias, default: nether2
  --data-dir PATH       Remote data dir, default: /opt/subscription-manager/data

  --shared-url URL      Mode 1: lay one HTTP sub URL into every user's
                        data/<user>/foreign/<name>.txt
  --legacy             Force Mode 2 (per-user vless::keys) explicitly

  --name FILENAME       Remote filename in foreign/, e.g. 'Marzban.txt'
                        Required in --shared-url mode unless asked
  --users "u1 u2 ..."   Restrict to subset (skip ssh enumeration)
  --build-cmd CMD       Remote build command, default: buildvpn
  --skip-build          Do not run buildvpn after upload
  --dry-run             Only show what would be done

Legacy / per-user mode (no --shared-url):
  --server-alias NAME   Local folder under $LOCAL_OUT_DIR/, e.g. marz
                        (any plain name; not the panel server)
  --reuse-local         Skip gen_vless.sh; need files in out_keys/<alias>/<u>.vless
  --gen-script PATH     Local generator script, default: ./gen_vless.sh
  --panel URL           Marzban panel URL
  --admin USERNAME      Marzban admin username
  --inbound TAG         Default: VLESS TCP VISION REALITY
  --limit-gb N          Data limit per user, 0 = unlimited
  --expire-days N       Account lifetime, 0 = no expiry
  --reset-strategy KEY  Default: day
  --flow NAME           Default: xtls-rprx-vision
  --password-env VAR    Env var with admin password

  -h, --help            Show this help
EOF
}

INTERACTIVE_LEGACY=""

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
        --legacy)
            INTERACTIVE_LEGACY=1
            shift
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
        --local-out)
            LOCAL_OUT_DIR="${2:?missing local out dir}"
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
            echo "[!] Unexpected positional arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ===========================================================
# Mode selection (interactive if nothing passed)
# ===========================================================
if [[ -z "$SHARED_URL" && -z "$INTERACTIVE_LEGACY" ]]; then
    if have_tty; then
        echo
        echo "Pick mode:"
        echo "  1) SHARED URL (one Marzban sub URL -> every user); easier for 1 panel"
        echo "  2) PER-USER (gen_vless.sh over Marzban API or local out_keys/)"
        read -rp "Choose [1/2]: > " MODE_CHOICE
        case "${MODE_CHOICE:-1}" in
            1|SHARED|s|shared) SHARED_URL="__ask__" ;;
            2|LEGACY|l|legacy) INTERACTIVE_LEGACY=1 ;;
            *)
                # If user pasted a URL directly, treat as shared URL
                if [[ "$MODE_CHOICE" =~ ^https?:// ]]; then
                    SHARED_URL="$MODE_CHOICE"
                else
                    echo "[!] bad choice" >&2
                    exit 1
                fi
                ;;
        esac
    fi
fi

# Shared URL interactive: ask for the URL if placeholder
if [[ "${SHARED_URL:-}" == "__ask__" ]]; then
    prompt "Paste the subscription URL your Marzban panel gave you (https://mirror.uvx.lol/<token>)" SHARED_URL
    if [[ -z "${SHARED_URL:-}" ]]; then
        echo "[!] empty URL" >&2
        exit 1
    fi
    if ! [[ "$SHARED_URL" =~ ^https?:// ]]; then
        echo "[!] not http(s): $SHARED_URL" >&2
        exit 1
    fi
fi

# Filename interactive (both modes)
if [[ -z "$REMOTE_FILENAME" ]]; then
    prompt "Filename inside foreign/, e.g. Marzban.txt" REMOTE_FILENAME
fi

if [[ -z "$REMOTE_FILENAME" ]]; then
    echo "[!] empty filename" >&2
    exit 1
fi
case "$REMOTE_FILENAME" in
    */*|.*|..)
        echo "[!] Bad filename: $REMOTE_FILENAME" >&2
        exit 1
        ;;
esac

# ===========================================================
# ============== MODE 1: shared URL ==========================
# ===========================================================
if [[ -n "$SHARED_URL" ]]; then
    echo "[*] Mode: shared URL"
    echo "[*] URL:           $SHARED_URL"
    echo "[*] Filename:      $REMOTE_FILENAME (in each data/<user>/foreign/)"
    echo "[*] Subscription:  $NETHER_HOST"
    echo "[*] Data dir:      $DATA_DIR"

    # User list
    if [[ -n "$USERS_OVERRIDE" ]]; then
        mapfile -t USERS < <(printf '%s\n' "$USERS_OVERRIDE" | tr ' ' '\n' | sed '/^$/d')
        echo "[*] Users (override): ${#USERS[@]}"
    else
        echo "[*] Reading users from $NETHER_HOST..."
        sq() { printf "'"; printf "%s" "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
        mapfile -t USERS < <(
            ssh "$NETHER_HOST" "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n'" \
                2>/dev/null | LC_ALL=C sort
        )
        if [[ "${#USERS[@]}" -eq 0 ]]; then
            echo "[!] No users found on $NETHER_HOST:$DATA_DIR" >&2
            exit 1
        fi
    fi

    echo "[*] Users: ${#USERS[@]}"
    printf '    %s\n' "${USERS[@]}"
    echo

    for u in "${USERS[@]}"; do
        if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "[!] Bad user folder name: $u" >&2
            exit 1
        fi
    done

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] Would write URL into each of these files:"
        for u in "${USERS[@]}"; do
            echo "    $NETHER_HOST:$DATA_DIR/$u/foreign/$REMOTE_FILENAME"
        done
        echo
        for u in "${USERS[@]}"; do
            ssh "$NETHER_HOST" "test -e $(sq "$DATA_DIR/$u/foreign/$REMOTE_FILENAME")" 2>/dev/null && \
                echo "    (remote file already exists: $u)" >&2
        done
        [[ "$SKIP_BUILD" -eq 0 ]] && echo "[DRY-RUN] Would run '$BUILD_CMD' on $NETHER_HOST"
        exit 0
    fi

    sq() { printf "'"; printf "%s" "$1" | sed "s/'/'\\\\''/g"; printf "'"; }

    # Pre-flight: refuse if any dest file already exists
    EXISTING_REMOTE=()
    for u in "${USERS[@]}"; do
        if ssh "$NETHER_HOST" "test -e $(sq "$DATA_DIR/$u/foreign/$REMOTE_FILENAME")" 2>/dev/null; then
            EXISTING_REMOTE+=("$DATA_DIR/$u/foreign/$REMOTE_FILENAME")
        fi
    done
    if [[ "${#EXISTING_REMOTE[@]}" -gt 0 ]]; then
        echo "[!] Abort: these remote files already exist, refusing to overwrite:" >&2
        printf '    %s\n' "${EXISTING_REMOTE[@]}" >&2
        exit 1
    fi

    echo "[*] Pushing URL into ${#USERS[@]} users' foreign/$REMOTE_FILENAME ..."
    for u in "${USERS[@]}"; do
        remote_dir="$DATA_DIR/$u/foreign"
        remote_dst="$remote_dir/$REMOTE_FILENAME"
        remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"
        ssh "$NETHER_HOST" "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
        ssh "$NETHER_HOST" "set -e; umask 077; cat > $(sq "$remote_tmp")" <<< "$SHARED_URL"
        ssh "$NETHER_HOST" "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
        echo "    [OK] $u"
    done

    echo
    echo "[+] Pushed. Mihomo will fetch $SHARED_URL every 3600s with UA clash.meta."

    if [[ "$SKIP_BUILD" -eq 1 ]]; then
        echo "[*] --skip-build set; not running buildvpn"
        exit 0
    fi
    echo
    echo "[*] Running buildvpn on $NETHER_HOST..."
    REMOTE_CD_ESC=$(printf '%s' "$DATA_DIR" | sed "s/'/'\\\\''/g")
    ssh -tt "$NETHER_HOST" "bash -ic 'cd ${REMOTE_CD_ESC} && ${BUILD_CMD}'"
    exit 0
fi

# ===========================================================
# ============== MODE 2: legacy / per-user ===================
# ===========================================================
if [[ "$INTERACTIVE_LEGACY" -eq 1 || -z "$SHARED_URL" ]]; then
    if [[ -z "$SERVER_ALIAS" ]] && have_tty; then
        echo
        echo "Server-alias (just a folder name for out_keys/, e.g. vless, marzban, eu1):"
        echo "  (any plain name; doesn't have to match panel)"
        read -rp "> " SERVER_ALIAS
    fi
fi

if [[ -z "$SERVER_ALIAS" ]]; then
    echo "[!] Server alias is required in legacy mode." >&2
    usage >&2
    exit 1
fi
if [[ ! "$SERVER_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[!] Server alias must match ^[A-Za-z0-9._-]+\$" >&2
    exit 1
fi

# gen_vless passthroughs: ask interactively if not given
if [[ "$REUSE_LOCAL" -ne 1 ]]; then
    if [[ -z "$GEN_PANEL" ]] && have_tty; then
        echo
        echo "Marzban panel URL (without /api):"
        echo "  Example: https://mirror.uvx.lol"
        read -rp "> " GEN_PANEL
    fi
    if [[ -z "$GEN_ADMIN" ]] && have_tty; then
        echo "Marzban admin / sudoer username:"
        read -rp "> " GEN_ADMIN
    fi
fi

echo
echo "[*] Server alias:       $SERVER_ALIAS"
echo "[*] Subscription host:  $NETHER_HOST"
echo "[*] Data dir:           $DATA_DIR"
echo "[*] Local keys dir:     $LOCAL_OUT_DIR/$SERVER_ALIAS"
echo "[*] Remote filename:    $REMOTE_FILENAME"
[[ "$REUSE_LOCAL" -eq 1 ]] && echo "[*] Reuse-local:        yes (skip gen_vless.sh)"
[[ "$REUSE_LOCAL" -ne 1 ]] && echo "[*] Reuse-local:        no (will run $GEN_SCRIPT)"
echo

# User list
if [[ -n "$USERS_OVERRIDE" ]]; then
    mapfile -t USERS < <(printf '%s\n' "$USERS_OVERRIDE" | tr ' ' '\n' | sed '/^$/d')
    echo "[*] Using --users override: ${#USERS[@]} user(s)"
else
    echo "[*] Reading users from $NETHER_HOST..."
    sq() { printf "'"; printf "%s" "$1" | sed "s/'/'\\\\''/g" printf "'"; }
    mapfile -t USERS < <(
        ssh "$NETHER_HOST" "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n'" \
            || {
            echo "[!] Could not list users on $NETHER_HOST:$DATA_DIR" >&2
            echo "    Use --users 'u1 u2 ...' for dry-run." >&2
            exit 1
        }
    )
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
        echo "[!] Bad user folder name: $u" >&2
        exit 1
    fi
done

# Pre-flight: existing remote
echo "[*] Preflight: checking remote target files..."
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
echo "[*] Preflight OK"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$REUSE_LOCAL" -eq 1 ]]; then
        echo "[DRY-RUN] Would reuse existing local keys"
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
    [[ "$SKIP_BUILD" -eq 0 ]] && echo "[DRY-RUN] Would run on $NETHER_HOST: cd $DATA_DIR && $BUILD_CMD"
    exit 0
fi

if [[ "$REUSE_LOCAL" -eq 1 ]]; then
    echo "[*] Reuse-local: skipping $GEN_SCRIPT"
    MISSING_LOCAL=()
    for u in "${USERS[@]}"; do
        conf="$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless"
        [[ ! -s "$conf" ]] && MISSING_LOCAL+=("$u (missing $conf)")
    done
    if [[ "${#MISSING_LOCAL[@]}" -gt 0 ]]; then
        echo "[!] Missing local generated files for:" >&2
        printf '    %s\n' "${MISSING_LOCAL[@]}" >&2
        exit 1
    fi
else
    [[ ! -f "$GEN_SCRIPT" ]] && { echo "[!] gen script not found: $GEN_SCRIPT" >&2; exit 1; }

    GEN_CMD=(bash "$GEN_SCRIPT")
    [[ -n "$GEN_PANEL" ]]            && GEN_CMD+=(--panel "$GEN_PANEL")
    [[ -n "$GEN_ADMIN" ]]            && GEN_CMD+=(--admin "$GEN_ADMIN")
    [[ -n "$GEN_INBOUND" ]]          && GEN_CMD+=(--inbound "$GEN_INBOUND")
    [[ -n "$GEN_RESET_STRATEGY" ]]   && GEN_CMD+=(--reset-strategy "$GEN_RESET_STRATEGY")
    [[ -n "$GEN_FLOW" ]]             && GEN_CMD+=(--flow "$GEN_FLOW")
    [[ -n "$GEN_PASSWORD_ENV" ]]     && GEN_CMD+=(--password-env "$GEN_PASSWORD_ENV")
    [[ -n "$GEN_OUT_DIR" ]]          && GEN_CMD+=(--out-dir "$GEN_OUT_DIR")
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
    [[ ! -s "$conf" ]] && { echo "[!] Missing: $conf" >&2; exit 1; }
done

echo "[*] Uploading vless files to $NETHER_HOST..."
for u in "${USERS[@]}"; do
    conf="$LOCAL_OUT_DIR/$SERVER_ALIAS/${u}.vless"
    remote_dir="$DATA_DIR/$u/foreign"
    remote_dst="$remote_dir/$REMOTE_FILENAME"
    remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"
    echo "    $u -> $remote_dst"
    ssh "$NETHER_HOST" "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
    ssh "$NETHER_HOST" "set -e; umask 077; cat > $(sq "$remote_tmp")" < "$conf"
    ssh "$NETHER_HOST" "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
done

echo
echo "[+] Upload done"

if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "[*] Skipping buildvpn"
    exit 0
fi

echo
echo "[*] Running buildvpn on $NETHER_HOST..."
REMOTE_CD_ESC=$(printf '%s' "$DATA_DIR" | sed "s/'/'\\\\''/g")
ssh -tt "$NETHER_HOST" "bash -ic 'cd ${REMOTE_CD_ESC} && ${BUILD_CMD}'"
