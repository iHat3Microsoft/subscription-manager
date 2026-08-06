#!/usr/bin/env bash
# sub_vless.sh — генерация vless-ключей через Marzban API для всех
# локальных юзеров на subscription-manager'е. Зеркало gen.sh + sub.sh для vless.
#
# Просто запусти `sub_vless.sh` и ответь на 3-4 вопроса — оно сгенерит
# ключи на каждого юзера, прочитав их с удалёнки ssh-ом.
#
# Алгоритм (на каждого юзера):
#   1. SSH на nether -> data/<user>/  -> список папок-юзеров
#   2. POST /api/admin/token          -> holder Bearer
#   3. На каждого user:
#        - GET  /api/user/<u>          (если уже есть — skip создание)
#        - POST /api/user              (если нет    — создать)
#        - GET  /api/user/<u>.links[] -> vless://-строки
#   4. Save ./out_keys/<server>/<user>.vless
#   5. Upload -> nether:data/<user>/foreign/<name>.txt
#   6. ssh buildvpn
#
# Зависимости: bash, ssh, jq, curl.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"
OUT_DIR="${OUT_DIR:-./out_keys/vless}"
REMOTE_FILENAME="${REMOTE_FILENAME:-Marzban.txt}"
DRY_RUN=0
SKIP_BUILD=1   # default: do NOT run buildvpn (run --build to override)
NO_CACHE=0      # by default: skip users whose local <u>.vless already exists
MODE="url"      # default: save subscription_url instead of vless keys

PANEL=""
ADMIN_USER=""
INBOUND_TAG="VLESS TCP VISION REALITY"
LIMIT_GB=0
EXPIRE_DAYS=0
RESET_STRATEGY="day"
PASSWORD_ENV_NAME="MARZBAN_ADMIN_PASSWORD"

have_tty() { [[ -t 0 ]]; }

ask() {
    local var="$1" msg="$2"
    if [[ -n "${!var:-}" ]]; then return 0; fi
    if ! have_tty; then
        echo "[!] $msg" >&2
        echo "    (stdin isn't a TTY; pass --${var,,} <value>)" >&2
        exit 1
    fi
    echo "$msg"
    read -rp "> " "$var"
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME                          # interactive — asks everything
  $SCRIPT_NAME [options]

Options:
  --nether HOST         Subscription-manager SSH alias, default: nether2
  --data-dir PATH       Remote data dir, default: $DATA_DIR
  --out-dir PATH        Local outputs go here, default: $OUT_DIR
  --build-cmd CMD       Remote build command, default: $BUILD_CMD
  --name FILE           Remote filename in foreign/ (default: empty,
                        always asked interactively)
  --mode [url|vless]    Output mode: 'url' (default) for subscription_url,
                        or 'vless' for raw vless:// strings.
  --panel URL           Marzban panel URL (no /api)
  --admin USER          Marzban sudoer username
  --inbound TAG         Default: $INBOUND_TAG
  --limit-gb N          Data limit per user, 0 = unlimited
  --expire-days N       Expire in N days, 0 = never
  --password-env VAR    Env var with admin password, default: $PASSWORD_ENV_NAME
  --dry-run             Plan only, do not create users or upload
  --no-cache            Force-refresh vless:// for every user (ignore
                        local ./out_keys/<u>.vless; even if the cached
                        file is from a different panel, re-fetch from the
                        current one)
  --skip-build          Do not run buildvpn (default: skip buildvpn)
  --build               Run buildvpn after upload (overrides skip)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nether)
            NETHER_HOST="${2:?missing}"; shift 2 ;;
        --data-dir)
            DATA_DIR="${2:?missing}"; shift 2 ;;
        --out-dir)
            OUT_DIR="${2:?missing}"; shift 2 ;;
        --build-cmd)
            BUILD_CMD="${2:?missing}"; shift 2 ;;
        --mode)
            MODE="${2:?missing}"; shift 2 ;;
        --name)
            REMOTE_FILENAME="${2:?missing}"; shift 2 ;;
        --panel)
            PANEL="${2:?missing}"; shift 2 ;;
        --admin)
            ADMIN_USER="${2:?missing}"; shift 2 ;;
        --inbound)
            INBOUND_TAG="${2:?missing}"; shift 2 ;;
        --limit-gb)
            LIMIT_GB="${2:?missing}"; shift 2 ;;
        --expire-days)
            EXPIRE_DAYS="${2:?missing}"; shift 2 ;;
        --password-env)
            PASSWORD_ENV_NAME="${2:?missing}"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --skip-build)
            SKIP_BUILD=1; shift ;;
        --build)
            SKIP_BUILD=0; shift ;;
        --no-cache)
            NO_CACHE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            echo "[!] Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            echo "[!] Unexpected positional: $1" >&2; usage >&2; exit 1 ;;
    esac
done

sq() { printf "'"; printf "%s" "$1" | sed "s/'/'\\\\''/g"; printf "'"; }

# 1) Ask panel + admin + password (only what's missing)
ask PANEL "Marzban panel URL (no /api)"
# Ask filename early (before any ssh/api side-effects).
if [[ -z "$REMOTE_FILENAME" ]]; then
    echo
    echo "Pick a basename for"
    echo "    $NETHER_HOST:$DATA_DIR/<user>/foreign/<FILE>"
    echo "(just the file basename, no path; pick anything you like)"
    ask REMOTE_FILENAME "Filename"
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
[[ -z "$PANEL" && -z "${DRY_RUN+x}" ]] && { echo "[!] panel URL required" >&2; exit 1; }
if [[ -n "$PANEL" ]]; then
    if ! [[ "$PANEL" =~ ^https?:// ]]; then
        echo "[!] not an http(s) URL: $PANEL" >&2; exit 1
    fi
    # Strip anything past host:port. Marzban /api lives at the bare origin
    # even when there's a web-mordа tenant prefix.
    ORIGIN=$(printf '%s' "$PANEL" | grep -oE 'https?://[^/]+' | head -1)
    if [[ -z "$ORIGIN" ]]; then
        echo "[!] could not parse host:port from $PANEL" >&2
        exit 1
    fi
    if [[ "$ORIGIN" != "$PANEL" ]]; then
        echo "[*] Stripping path -> using $ORIGIN (panel URL path is ignored;"
        echo "    /api lives at the bare origin regardless of web-mordа prefix)"
    fi
    PANEL="$ORIGIN"
fi
ask ADMIN_USER "Marzban admin / sudoer username"
[[ -z "$ADMIN_USER" && -z "${DRY_RUN+x}" ]] && { echo "[!] admin user required" >&2; exit 1; }

# 2) Read remote user list
echo "[*] Reading users from $NETHER_HOST..."
mapfile -t USERS < <(
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$NETHER_HOST" "cd $(sq "$DATA_DIR") && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n'" \
        || { echo "[!] ssh failed" >&2; exit 1; } \
        | LC_ALL=C sort
)

if [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "[!] No users in $NETHER_HOST:$DATA_DIR" >&2
    exit 1
fi

echo "[*] ${#USERS[@]} remote user folders:"
printf '    %s\n' "${USERS[@]}"
echo "[*] Remote filename: $REMOTE_FILENAME"
echo

# Validate + ensure folder name matches Marzban naming rules
declare -a TO_CREATE=()
declare -a TO_FETCH=()
for u in "${USERS[@]}"; do
    if [[ ! "$u" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[!] Bad folder name (skip): '$u'" >&2
        continue
    fi
    TO_FETCH+=("$u")
done

# 3) Authenticate with Marzban
if [[ "$DRY_RUN" -eq 0 ]]; then
    ADMIN_PASS=""
    if [[ -n "${!PASSWORD_ENV_NAME:-}" ]]; then
        ADMIN_PASS="${!PASSWORD_ENV_NAME}"
    elif have_tty; then
        read -rsp "Admin password (input hidden): " ADMIN_PASS
        echo
    else
        echo "[!] Set $PASSWORD_ENV_NAME or run with a TTY" >&2
        exit 1
    fi
    [[ -z "$ADMIN_PASS" ]] && { echo "[!] empty password" >&2; exit 1; }

    echo "[*] Authenticating with Marzban..."
    TOKEN_RESP=$(curl -fsS -X POST "$PANEL/api/admin/token" \
        --data-urlencode "username=$ADMIN_USER" \
        --data-urlencode "password=$ADMIN_PASS" 2>&1) || {
            echo "[!] Failed to obtain admin token" >&2
            echo "    Response head: $(printf '%s' "$TOKEN_RESP" | head -c 200)" >&2
            exit 1
        }
    ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESP" | jq -r '.access_token // empty')
    if [[ -z "$ACCESS_TOKEN" ]]; then
        echo "[!] No access_token in response" >&2
        printf '    %s\n' "$TOKEN_RESP" | head >&2
        exit 1
    fi
fi

# 4) Pre-flight: refuse to overwrite remote files
echo "[*] Pre-flight: refusing to overwrite remote files"
EXISTING_REMOTE=()
for u in "${TO_FETCH[@]}"; do
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$NETHER_HOST" "test -e $(sq "$DATA_DIR/$u/foreign/$REMOTE_FILENAME")" 2>/dev/null; then
        EXISTING_REMOTE+=("$DATA_DIR/$u/foreign/$REMOTE_FILENAME")
    fi
done
if [[ "${#EXISTING_REMOTE[@]}" -gt 0 ]]; then
    echo "[!] Abort: remote files already exist:" >&2
    printf '    %s\n' "${EXISTING_REMOTE[@]}" >&2
    exit 1
fi

# 5) Prepare local out dir
mkdir -p "$OUT_DIR" 2>/dev/null || true
chmod 700 "$(dirname "$OUT_DIR")" 2>/dev/null || true

NOW=$(date +%s)
if [[ "$EXPIRE_DAYS" -gt 0 ]]; then
    EXPIRE_JSON=$((NOW + EXPIRE_DAYS * 86400))
else
    EXPIRE_JSON=null
fi
if [[ "$LIMIT_GB" -gt 0 ]]; then
    DL_JSON=$((LIMIT_GB * 1073741824))
else
    DL_JSON=null
fi
mkdir -p "$OUT_DIR" 2>/dev/null || true

# Marzban username rules: 3..32 chars, only [a-z0-9_]. Our local folders
# (Me, Vasya, artem_mirea, friend_nikita-kurilkin) often violate these.
# Sanitize to a stable, deterministic, safe username; keep an orig<->safe
# map file at $OUT_DIR/_users.tsv so re-runs use the same Marzban name.
MAP_FILE="$OUT_DIR/_users.tsv"
mk_safe() {
    # mk_safe <orig>
    local s="${1,,}"
    s="${s//[^a-z0-9_]/_}"
    while [[ "${#s}" -lt 3 ]]; do s="${s}_x"; done
    while [[ "${#s}" -gt 30 ]]; do s="${s%_}"; done
    printf '%s' "$s"
}
declare -A ORIG_TO_SAFE=()
declare -A SAFE_TO_ORIG=()
if [[ -f "$MAP_FILE" ]]; then
    while IFS=$'\t' read -r safe orig; do
        [[ -z "$safe" || -z "$orig" ]] && continue
        ORIG_TO_SAFE["$orig"]="$safe"
        SAFE_TO_ORIG["$safe"]="$orig"
    done < "$MAP_FILE"
fi
resolve_safe() {
    # resolve_safe <orig>  -> echoes a stable safe username
    local orig="$1" safe="" hash=""
    if [[ -n "${ORIG_TO_SAFE[$orig]:-}" ]]; then echo "${ORIG_TO_SAFE[$orig]}"; return; fi
    safe=$(mk_safe "$orig")
    if [[ -n "${SAFE_TO_ORIG[$safe]:-}" && "${SAFE_TO_ORIG[$safe]}" != "$orig" ]]; then
        # collision: append 4-hex suffix from sha1 of orig
        if command -v sha1sum >/dev/null 2>&1; then
            hash=$(printf '%s' "$orig" | sha1sum | cut -c1-4)
        else
            hash=$(printf '%s' "$orig" | md5sum 2>/dev/null | cut -c1-4)
        fi
        safe="${safe}_${hash}"
    fi
    ORIG_TO_SAFE["$orig"]="$safe"
    SAFE_TO_ORIG["$safe"]="$orig"
    printf '%s\t%s\n' "$safe" "$orig" >> "$MAP_FILE"
    echo "$safe"
}

# 6) For each user: ensure exists on Marzban, then fetch .links[]
GEN_TS=$(date -u '+%F %T')

for u in "${TO_FETCH[@]}"; do
    SAFE_U=$(resolve_safe "$u")
    echo "[*] $u -> Marzban user '$SAFE_U'"
    if [[ "$NO_CACHE" -eq 1 ]]; then
        rm -f "$OUT_DIR/${u}.vless"
    fi
    if [[ -e "$OUT_DIR/${u}.vless" ]]; then
        # The cached file records which panel produced it; reuse only if
        # this run's panel matches. If you switched panel for a new server,
        # we don't want to upload keys from the old one.
        cached_panel=$(awk -F'# Panel:[[:space:]]*' '/^# Panel:/ {print $2; exit}' "$OUT_DIR/${u}.vless" 2>/dev/null || true)
        if [[ -n "$cached_panel" && "$cached_panel" != "$PANEL" ]]; then
            echo "    cached file is from a different panel ($cached_panel); not reusing -- regenerating"
            rm -f "$OUT_DIR/${u}.vless"
        else
            echo "    cached locally (delete or pass --no-cache to refetch): $OUT_DIR/${u}.vless"
            echo "    [SKIP] $u"
            continue
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    [DRY] Would ensure Marzban has '$SAFE_U' and fetch vless:// into $OUT_DIR/${u}.vless"
        continue
    fi

    # Fetch vless:// from .links[]
    USER_DATA=$(curl -fsS --max-time 15 -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$PANEL/api/user/$SAFE_U" 2>&1) || true
    HIT=$(printf '%s' "$USER_DATA" | jq -r '.username // empty' 2>/dev/null || true)

    if [[ "$HIT" != "$SAFE_U" ]]; then
        echo "    POST $PANEL/api/user (creating '$SAFE_U')"
        PAYLOAD=$(jq -n \
            --arg u "$SAFE_U" \
            --arg inbound "$INBOUND_TAG" \
            --arg note "added by sub_vless.sh @ ${GEN_TS} (folder: ${u})" \
            --argjson expire "$EXPIRE_JSON" \
            --argjson dl "$DL_JSON" \
            --arg strategy "$RESET_STRATEGY" \
            '{
                status: "active",
                username: $u,
                note: $note,
                proxies: { vless: { flow: "xtls-rprx-vision" } },
                data_limit: $dl,
                expire: $expire,
                data_limit_reset_strategy: $strategy,
                inbounds: { vless: [ $inbound ] }
            }')
        # Capture POST response + HTTP code so we can detect 422 cleanly.
        POST_RESP=$(mktemp)
        POST_CODE=$(curl -sS --max-time 15 -o "$POST_RESP" -w '%{http_code}' \
            -X POST "$PANEL/api/user" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$PAYLOAD" 2>&1)
        printf '      -> HTTP %s\n' "$POST_CODE"
        head -c 400 "$POST_RESP"
        printf '\n'
        rm -f "$POST_RESP"

        if [[ "$POST_CODE" == "200" || "$POST_CODE" == "201" ]]; then
            : # created
        elif [[ "$POST_CODE" == "409" ]]; then
            echo "    (409, will read existing)"
        elif [[ "$POST_CODE" == "422" ]]; then
            echo "    [!] 422 on create: Marzban rejected (probably bad chars). Check $MAP_FILE." >&2
            continue
        else
            echo "    [!] HTTP $POST_CODE -> abort this user" >&2
            continue
        fi

        # Re-read to get fresh .links[]
        USER_DATA=$(curl -fsS --max-time 15 -H "Authorization: Bearer $ACCESS_TOKEN" \
            "$PANEL/api/user/$SAFE_U" 2>&1) || {
                echo "[!] Could not GET $SAFE_U after POST" >&2
                exit 1
            }
    else
        echo "    already exists on Marzban"
    fi

    if [[ "$MODE" == "url" ]]; then
        LINKS=$(printf '%s' "$USER_DATA" | jq -r '.subscription_url // empty' 2>/dev/null || true)
        if [[ -z "$(printf '%s' "$LINKS" | tr -d '[:space:]')" ]]; then
            echo "    [!] no subscription_url for $u" >&2
            printf '        user data head: %s\n' "$USER_DATA" | head -c 400 >&2
            continue
        fi
    else
        LINKS=$(printf '%s' "$USER_DATA" | jq -r '.links[]?' 2>/dev/null | grep '^vless://' || true)
        if [[ -z "$(printf '%s' "$LINKS" | tr -d '[:space:]')" ]]; then
            echo "    [!] no vless:// from .links[] for $u" >&2
            printf '        user data head: %s\n' "$USER_DATA" | head -c 400 >&2
            continue
        fi
    fi

    {
        printf '# sub_vless.sh generated\n'
        printf '# Local folder:  %s\n' "$u"
        printf '# Marzban user:  %s\n' "$SAFE_U"
        printf '# Panel:         %s\n' "$PANEL"
        printf '# Mode:          %s\n' "$MODE"
        printf '# Generated at:  %s\n' "$GEN_TS"
        printf '%s\n' "$LINKS"
    } > "$OUT_DIR/${u}.vless"
    chmod 600 "$OUT_DIR/${u}.vless"
    
    if [[ "$MODE" == "url" ]]; then
        echo "    [OK] saved $OUT_DIR/${u}.vless (subscription_url)"
    else
        echo "    [OK] saved $OUT_DIR/${u}.vless ($(printf '%s' "$LINKS" | grep -c '^vless://' || echo 0) link(s))"
    fi
done

# 7) Upload each .vless to remote foreign/<REMOTE_FILENAME>
echo
echo "[*] Uploading to $NETHER_HOST..."

for u in "${TO_FETCH[@]}"; do
    conf="$OUT_DIR/${u}.vless"
    [[ ! -s "$conf" ]] && { echo "[!] Missing local $conf (skipped)" >&2; continue; }
    remote_dir="$DATA_DIR/$u/foreign"
    remote_dst="$remote_dir/$REMOTE_FILENAME"
    remote_tmp="$remote_dir/.$REMOTE_FILENAME.tmp.$$"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$NETHER_HOST" "set -e; mkdir -p $(sq "$remote_dir"); test ! -e $(sq "$remote_dst")"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$NETHER_HOST" "set -e; umask 077; cat > $(sq "$remote_tmp")" < "$conf"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$NETHER_HOST" "set -e; test ! -e $(sq "$remote_dst"); mv $(sq "$remote_tmp") $(sq "$remote_dst")"
    echo "    [OK] $u -> $remote_dst"
done

echo
echo "[+] Done"

if [[ "$DRY_RUN" -eq 1 ]]; then
    exit 0
fi

if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "[*] Skipping buildvpn (pass --build to run it)"
    exit 0
fi

echo "[*] Running buildvpn..."
cd_esc=$(printf '%s' "$DATA_DIR" | sed "s/'/'\\\\''/g")
ssh -tt -o ConnectTimeout=10 -o ServerAliveInterval=15 "$NETHER_HOST" "bash -ic 'cd ${cd_esc} && ${BUILD_CMD}'"
