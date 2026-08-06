#!/usr/bin/env bash
# gen_vless.sh — создаёт юзеров в Marzban через REST API и вытаскивает
# для каждого vless://-ссылку. Структура output совместима с sub_vless.sh.
#
# Зависимости: bash, curl, jq.
#
# Использовать так:
#   1) Запустить gen_vless.sh <server-alias> [<user>... | prefix:count].
#      Если panel/admin не переданы через --panel/--admin/--password-env,
#      скрипт спросит URL/логин и попросит пароль через read -s.
#   2) Запустить sub_vless.sh --name <remote-filename> <server-alias>,
#      который раскидает out_keys/<server-alias>/<user>.vless
#      в data/<user>/foreign/<remote-filename>.txt на удалённом сервере.
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

DRY_RUN=0
PANEL_URL=""
ADMIN_USER=""
INBOUND_TAG=""
INBOUND_DEFAULT="VLESS TCP VISION REALITY"
LIMIT_GB=0
EXPIRE_DAYS=0
OUT_DIR="./out_keys"
DATA_RESET_STRATEGY="day"
PROXIES_FLOW="xtls-rprx-vision"
PASSWORD_ENV=""
SKIP_EXISTING=0

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] <server-alias> [<user>... | prefix:count]

Examples:
  $SCRIPT_NAME marzban1 alice bob
  $SCRIPT_NAME marzban1 user:10
  $SCRIPT_NAME --panel https://marz.example.com --admin sheets --inbound 'VLESS TCP VISION REALITY' marzban1 alice

Options:
  --panel URL              Marzban panel base URL, e.g. https://marz.example.com
                           (no trailing slash). If omitted, asked interactively.
  --admin USERNAME         Admin/Sudoer username. If omitted, asked interactively.
  --inbound TAG            Inbound tag for vless, default: ${INBOUND_DEFAULT}
  --limit-gb N             Data limit per user in GB; 0 = unlimited (default 0).
  --expire-days N          Account lifetime in days; 0 = no expiry (default 0).
  --reset-strategy KEY     'day' | 'week' | 'month' | 'no_reset', default: day.
  --flow NAME              vless flow, default: xtls-rprx-vision.
  --out-dir DIR            Local output dir, default: ./out_keys
  --password-env VAR       Name of env var holding admin password
                           (skips interactive prompt).
  --skip-existing          If a user already exists on the panel,
                           skip it instead of failing.
  --dry-run                Print payloads, do not call the API.
  -h, --help               Show this help.

Notes:
  * Usernames must match ^[A-Za-z0-9._-]+\$ to be safe for filenames.
  * Each user produces one file: \$OUT_DIR/<server-alias>/<user>.vless with
    one vless://-link per line. Trailing comments describe sub-URL and time.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel)
            PANEL_URL="${2:?missing panel URL}"
            shift 2
            ;;
        --admin)
            ADMIN_USER="${2:?missing admin username}"
            shift 2
            ;;
        --inbound)
            INBOUND_TAG="${2:?missing inbound tag}"
            shift 2
            ;;
        --limit-gb)
            LIMIT_GB="${2:?missing GB}"
            shift 2
            ;;
        --expire-days)
            EXPIRE_DAYS="${2:?missing days}"
            shift 2
            ;;
        --reset-strategy)
            DATA_RESET_STRATEGY="${2:?missing strategy}"
            shift 2
            ;;
        --flow)
            PROXIES_FLOW="${2:?missing flow}"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="${2:?missing out-dir}"
            shift 2
            ;;
        --password-env)
            PASSWORD_ENV="${2:?missing env var name}"
            shift 2
            ;;
        --skip-existing)
            SKIP_EXISTING=1
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
        --)
            shift
            break
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
shift 2>/dev/null || true

if [[ -z "$SERVER_ALIAS" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[!] Server alias is required even for --dry-run." >&2
        usage >&2
        exit 1
    fi
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        echo "[!] Server alias is required (no TTY for prompt)." >&2
        usage >&2
        exit 1
    fi
    read -rp "Marzban server alias (folder under $OUT_DIR, e.g. marzban1): " SERVER_ALIAS <&3
fi

if [[ -z "$SERVER_ALIAS" ]]; then
    echo "[!] Empty server alias." >&2
    usage >&2
    exit 1
fi

if [[ ! "$SERVER_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[!] Server alias must match ^[A-Za-z0-9._-]+\$" >&2
    exit 1
fi

if [[ $# -lt 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[!] Need at least one username or prefix:count even for --dry-run." >&2
        usage >&2
        exit 1
    fi
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        echo "[!] Need usernames (no TTY for prompt)." >&2
        usage >&2
        exit 1
    fi
    read -rp "Usernames (space-separated, e.g. 'alice bob' or 'user:5'): " USERS_LINE <&3
    if [[ -z "$USERS_LINE" ]]; then
        echo "[!] Empty usernames." >&2
        exit 1
    fi
    set -- $USERS_LINE
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
        echo "[!] Duplicate username: $u" >&2
        exit 1
    fi
    SEEN[$u]=1
done

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[!] Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ -n "$PANEL_URL" ]]; then
    PANEL_URL="${PANEL_URL%/}"
fi

if [[ -z "$PANEL_URL" ]]; then
    read -rp "Marzban panel URL (e.g. https://marz.example.com): " PANEL_URL
    PANEL_URL="${PANEL_URL%/}"
    if [[ -z "$PANEL_URL" ]]; then
        echo "[!] Empty panel URL" >&2
        exit 1
    fi
fi

if [[ -z "$ADMIN_USER" ]]; then
    read -rp "Admin username: " ADMIN_USER
    if [[ -z "$ADMIN_USER" ]]; then
        echo "[!] Empty admin username" >&2
        exit 1
    fi
fi

if [[ -z "$INBOUND_TAG" ]]; then
    INBOUND_TAG="$INBOUND_DEFAULT"
fi

mkdir -p "$OUT_DIR/$SERVER_ALIAS"
chmod 700 "$OUT_DIR" "$OUT_DIR/$SERVER_ALIAS" 2>/dev/null || true

for u in "${USERS[@]}"; do
    out="$OUT_DIR/$SERVER_ALIAS/${u}.vless"
    if [[ -e "$out" ]]; then
        echo "[!] Local output already exists: $out" >&2
        echo "    Remove it or choose a different username." >&2
        exit 1
    fi
done

echo "[*] Server alias:    $SERVER_ALIAS"
echo "[*] Panel:           $PANEL_URL"
echo "[*] Admin user:      $ADMIN_USER"
echo "[*] Inbound:         $INBOUND_TAG"
echo "[*] Flow:            $PROXIES_FLOW"
echo "[*] Data limit:      ${LIMIT_GB} GB (0 = unlimited)"
echo "[*] Expire (days):   ${EXPIRE_DAYS} (0 = no expiry)"
echo "[*] Reset strategy:  $DATA_RESET_STRATEGY"
echo "[*] Users:           ${USERS[*]}"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY] Would POST $PANEL_URL/api/admin/token (form)"
    echo "[DRY] For each user, would POST $PANEL_URL/api/user with payload:"
    cat <<'JSON'
{
  "status": "active",
  "username": "<user>",
  "note": "",
  "proxies": { "vless": { "flow": "<flow>" } },
  "data_limit": <bytes_or_0>,
  "expire": <unix_ts_or_0>,
  "data_limit_reset_strategy": "<strategy>",
  "inbounds": { "vless": ["<inbound>"] }
}
JSON
    echo
    echo "[DRY] Then GET <subscription_url> with 'User-Agent: clash.meta', base64-decode."
    echo "[DRY] Final local file paths:"
    for u in "${USERS[@]}"; do
        echo "    $OUT_DIR/$SERVER_ALIAS/${u}.vless"
    done
    exit 0
fi

if [[ -z "$PASSWORD_ENV" ]]; then
    PASSWORD_ENV="MARZBAN_ADMIN_PASSWORD_FOR_${SERVER_ALIAS^^}"
    PASSWORD_ENV="${PASSWORD_ENV//[^A-Z0-9_]/_}"
fi

ADMIN_PASS=""
if [[ -n "${!PASSWORD_ENV:-}" ]]; then
    ADMIN_PASS="${!PASSWORD_ENV}"
fi

if [[ -z "$ADMIN_PASS" ]]; then
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        echo "[!] No TTY available; pass password via env var $PASSWORD_ENV." >&2
        exit 1
    fi
    read -rsp "Admin password (input hidden): " ADMIN_PASS <&3
    echo >&3
    exec 3<&-
    if [[ -z "$ADMIN_PASS" ]]; then
        echo "[!] Empty password" >&2
        exit 1
    fi
fi

TOKEN_RESP=$(curl -fsS -X POST "$PANEL_URL/api/admin/token" \
    --data-urlencode "username=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASS")
ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESP" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    echo "[!] Failed to obtain admin token." >&2
    echo "    Panel response was:" >&2
    printf '    %s\n' "$TOKEN_RESP" >&2
    exit 1
fi

NOW=$(date +%s)
if [[ "$EXPIRE_DAYS" -gt 0 ]]; then
    EXPIRE_UNIX=$((NOW + EXPIRE_DAYS * 86400))
else
    EXPIRE_UNIX=0
fi
if [[ "$LIMIT_GB" -gt 0 ]]; then
    DATA_LIMIT_BYTES=$((LIMIT_GB * 1073741824))
else
    DATA_LIMIT_BYTES=0
fi

GEN_TS=$(date -u +%F %T)

for u in "${USERS[@]}"; do
    if [[ "$SKIP_EXISTING" -eq 1 ]]; then
        CHECK=$(curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" \
            "$PANEL_URL/api/user/$u" 2>/dev/null || true)
        if [[ -n "$CHECK" ]]; then
            USERNAME_HIT=$(printf '%s' "$CHECK" | jq -r '.username // empty')
            if [[ "$USERNAME_HIT" == "$u" ]]; then
                echo "[*] $u already exists on panel, skipping creation"
                continue
            fi
        fi
    fi

    PAYLOAD=$(jq -n \
        --arg username "$u" \
        --arg inbound "$INBOUND_TAG" \
        --arg flow "$PROXIES_FLOW" \
        --arg strategy "$DATA_RESET_STRATEGY" \
        --argjson data_limit "$DATA_LIMIT_BYTES" \
        --argjson expire "$EXPIRE_UNIX" \
        '{
            status: "active",
            username: $username,
            note: "",
            proxies: { vless: { flow: $flow } },
            data_limit: $data_limit,
            expire: $expire,
            data_limit_reset_strategy: $strategy,
            inbounds: { vless: [ $inbound ] }
        }')

    echo "[*] $u -> POST /api/user"
    RESP=$(curl -fsS -X POST "$PANEL_URL/api/user" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$PAYLOAD") || {
            echo "[!] Failed to create user $u" >&2
            echo "    Use --skip-existing to silently skip pre-existing users." >&2
            exit 1
        }

    SUB_URL=$(printf '%s' "$RESP" | jq -r '.subscription_url // empty')
    if [[ -z "$SUB_URL" || "$SUB_URL" == "null" ]]; then
        echo "[!] No subscription_url in response for $u:" >&2
        printf '    %s\n' "$RESP" >&2
        exit 1
    fi

    SUB_BODY=$(curl -fsS -H "User-Agent: clash.meta" "$SUB_URL" || true)
    if [[ -z "$SUB_BODY" ]]; then
        echo "[!] Empty subscription response for $u at $SUB_URL" >&2
        exit 1
    fi

    LINKS=$(printf '%s' "$SUB_BODY" | base64 -d 2>/dev/null \
            | awk 'NF && $0 !~ /^#/' || true)

    if [[ -z "$(printf '%s' "$LINKS" | tr -d '[:space:]')" ]]; then
        echo "[!] No vless://-links decoded for $u." >&2
        exit 1
    fi

    OUT="$OUT_DIR/$SERVER_ALIAS/${u}.vless"
    {
        printf '# Marzban user: %s\n' "$u"
        printf '# Panel:         %s\n' "$PANEL_URL"
        printf '# Subscription:  %s\n' "$SUB_URL"
        printf '# Generated at:  %s\n' "$GEN_TS"
        printf '# Inbounds:      vless=%s\n' "$INBOUND_TAG"
        printf '%s\n' "$LINKS"
    } > "$OUT"
    chmod 600 "$OUT"

    echo "    [OK] $u -> $OUT"
done

echo
echo "[+] Done."
echo "[+] Run sub_vlass.sh to lay files into subscription-manager."
