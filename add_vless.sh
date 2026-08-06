#!/usr/bin/env bash
# add_vless.sh — добавить vless-ноду ОДНОМУ юзеру.
#
# Поддерживает два режима ввода:
#   1) Sub URL (например, https://mirror.uvx.lol/<token>) —
#      скрипт сам curl'ит с User-Agent: clash.meta, base64/Clash-YAML
#      декодирует, вытаскивает vless://, сохраняет локально и раскладывает.
#   2) Прямой vless:// (одна или несколько строк в stdin) — сохраняет как есть.
#
# Зависимости: bash, curl, jq, ssh (для upload), base64 (обычно встроен).
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
LOCAL_OUT_DIR_BASE="./out_keys"

DRY_RUN=0
SKIP_BUILD=0
CLONE_VIA_SUB_URL=""
DIRECT_VLESS_TEXT=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME                                     # интерактивно
  $SCRIPT_NAME --sub-url URL --server ALIAS --user U --name FILE [--no-build]
  $SCRIPT_NAME --vless-stdin --server ALIAS --user U --name FILE

Modes:
  --sub-url URL    Pull vless://-ссылки из Marzban-style subscription URL.
                   (sets User-Agent: clash.meta to force Clash YAML).
  --vless-stdin    Read raw vless:// lines from stdin until EOF.
                   Stdin should end with a single dot '.' line or EOF (Ctrl-D).

Common:
  --server   ALIAS   Folder name under $LOCAL_OUT_DIR_BASE/, e.g. marzban1
  --user     U       Target username on subscription-manager, e.g. Me
  --name     FILE    Filename in data/<user>/foreign/, e.g. Marzban.txt
  --nether   HOST    Subscription-manager SSH alias, default: nether2
  --data-dir PATH    Remote data dir, default: /opt/subscription-manager/data
  --skip-build       Do not run buildvpn after upload
  --dry-run          Only print what would be done
  -h, --help         Show this help

Interactive: запустите без флагов — скрипт сам спросит всё, что нужно,
и зайдёт в режим sub-url или vless-stdin в зависимости от вашего ввода.
EOF
}

# Parse args
SERVER_ALIAS=""
USER=""
REMOTE_FILENAME=""
SUB_URL=""
FROM_STDIN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            SERVER_ALIAS="${2:?missing server alias}"
            shift 2
            ;;
        --user)
            USER="${2:?missing user}"
            shift 2
            ;;
        --name)
            REMOTE_FILENAME="${2:?missing filename}"
            shift 2
            ;;
        --sub-url)
            SUB_URL="${2:?missing URL}"
            shift 2
            ;;
        --vless-stdin)
            FROM_STDIN=1
            shift
            ;;
        --nether)
            NETHER_HOST="${2:?missing nether host}"
            shift 2
            ;;
        --data-dir)
            DATA_DIR="${2:?missing data dir}"
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
            echo "[!] Unexpected positional: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Interactive prompts (only if not --dry-run and TTY available)
have_tty() { { exec 3</dev/tty; } 2>/dev/null; }

if [[ "$DRY_RUN" -eq 0 ]] && have_tty && [[ -z "$SERVER_ALIAS" ]]; then
    read -rp "Server-alias (folder under $LOCAL_OUT_DIR_BASE, e.g. marzban1): " SERVER_ALIAS <&3
fi
if [[ "$DRY_RUN" -eq 0 ]] && have_tty && [[ -z "$USER" ]]; then
    read -rp "Target username on subscription-manager (e.g. Me): " USER <&3
fi
if [[ "$DRY_RUN" -eq 0 ]] && have_tty && [[ -z "$REMOTE_FILENAME" ]]; then
    read -rp "Filename in data/<user>/foreign/ (e.g. Marzban.txt): " REMOTE_FILENAME <&3
fi

# Validate
if [[ -z "$SERVER_ALIAS" ]]; then
    echo "[!] Server alias is required." >&2
    usage >&2
    exit 1
fi
if [[ ! "$SERVER_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[!] Server alias must match ^[A-Za-z0-9._-]+\$" >&2
    exit 1
fi
if [[ -z "$USER" ]]; then
    echo "[!] User is required." >&2
    exit 1
fi
if [[ ! "$USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[!] User folder name must match ^[A-Za-z0-9._-]+\$" >&2
    exit 1
fi
if [[ -z "$REMOTE_FILENAME" ]]; then
    echo "[!] Filename is required." >&2
    exit 1
fi
case "$REMOTE_FILENAME" in
    */*|.*|..)
        echo "[!] Bad filename: $REMOTE_FILENAME (no path, no leading dot)" >&2
        exit 1
        ;;
esac

# If interactive and no mode chosen: ask
if [[ "$DRY_RUN" -eq 0 ]] && have_tty && [[ -z "$SUB_URL" && $FROM_STDIN -eq 0 ]]; then
    echo
    echo "Choose input mode:"
    echo "  1) Sub URL (Marzban https://mirror.uvx.lol/<token>) [default]"
    echo "  2) Direct vless:// lines from stdin"
    read -rp "Choose [1/2]: " MODE_CHOICE <&3
    case "$MODE_CHOICE" in
        2|"")
            FROM_STDIN=1
            ;;
        1|"")
            ;;
        *)
            SUB_URL="$MODE_CHOICE"
            ;;
    esac
fi

LOCAL_OUT_DIR="$LOCAL_OUT_DIR_BASE/$SERVER_ALIAS"
mkdir -p "$LOCAL_OUT_DIR" 2>/dev/null
chmod 700 "$LOCAL_OUT_DIR_BASE" 2>/dev/null || true

LOCAL_FILE="$LOCAL_OUT_DIR/${USER}.vless"
if [[ -e "$LOCAL_FILE" ]]; then
    echo "[!] Local output already exists: $LOCAL_FILE" >&2
    echo "    Remove it or choose a different username." >&2
    exit 1
fi

echo "[*] Server alias:     $SERVER_ALIAS"
echo "[*] Target user:      $USER"
echo "[*] Local file:       $LOCAL_FILE"
echo "[*] Remote target:    $NETHER_HOST:$DATA_DIR/$USER/foreign/$REMOTE_FILENAME"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY] Would pull VLESS into $LOCAL_FILE according to mode."
    echo "[DRY] Would upload to $NETHER_HOST:$DATA_DIR/$USER/foreign/$REMOTE_FILENAME"
    [[ $SKIP_BUILD -eq 0 ]] && echo "[DRY] Would run buildvpn on $NETHER_HOST"
    exit 0
fi

# ====== Mode 1: Sub URL ======
if [[ -n "$SUB_URL" || $FROM_STDIN -eq 0 ]]; then
    if [[ -z "$SUB_URL" ]] && [[ "$DRY_RUN" -eq 0 ]] && have_tty; then
        echo
        echo "Paste the sub URL (ends with leading dot '.' or Ctrl-D):"
        SUB_URL=""
        while IFS= read -r line <&3; do
            [[ "$line" == "." ]] && break
            SUB_URL+="$line"
        done
        SUB_URL="${SUB_URL//[[:space:]]/}"
    fi

    if [[ -z "$SUB_URL" ]]; then
        echo "[!] Empty sub URL." >&2
        exit 1
    fi

    if ! [[ "$SUB_URL" =~ ^https?:// ]]; then
        echo "[!] Not an http(s) URL: $SUB_URL" >&2
        exit 1
    fi

    echo "[*] Fetching: $SUB_URL"
    BODY=$(curl -fsS -H "User-Agent: clash.meta" "$SUB_URL") || {
        echo "[!] curl failed: $SUB_URL" >&2
        exit 1
    }

    LINKS=""

    # Try to parse as Clash YAML first (when panel returns YAML on clash.meta UA)
    if command -v jq >/dev/null 2>&1; then
        if echo "$BODY" | jq -e '.proxies' >/dev/null 2>&1; then
            echo "[*] Body looks like Clash YAML, extracting proxies[]"
            LINKS=$(echo "$BODY" | jq -r '.proxies[] | (
                "- name=\"" + .name + "\""
                + (if .server then " server=\"" + .server + "\"" else "" end)
                + " port=\"" + (.port|tostring) + "\""
                + " type=\"" + (.type // "vless") + "\""
                + (if .uuid then " uuid=\"" + .uuid + "\"" else "" end)
                + (if .flow != null then " flow=\"" + .flow + "\"" else "" end)
                + (if .tls == true then " tls=true" else "" end)
                + (if (.servername // "") != "" then " sni=\"" + .servername + "\"" else "" end)
                + (if (.["client-fingerprint"] // "") != "" then " fp=\"" + .["client-fingerprint"] + "\"" else "" end)
                + (if .["reality-opts"] then
                    " pbk=\"" + (.["reality-opts"]["public-key"] // "") + "\""
                    + " sid=\"" + (.["reality-opts"]["short-id"] // "") + "\""
                  else "" end)
                + " tag=vless://placeholder@" + .server + ":" + (.port|tostring)
            )' 2>/dev/null || true)
        fi
    fi

    # Fallback: try to base64-decode (v2ray style)
    if [[ -z "$LINKS" ]]; then
        DECODED=$(printf '%s' "$BODY" | base64 -d 2>/dev/null || true)
        if [[ -n "$DECODED" ]]; then
            LINKS=$(printf '%s' "$DECODED" | grep -E '^vless://' || true)
        fi
    fi

    # Last fallback: keep the body raw (maybe it is already vless://...)
    if [[ -z "$LINKS" ]]; then
        LINKS=$(printf '%s' "$BODY" | grep -E '^vless://' || true)
    fi

    if [[ -z "$(printf '%s' "$LINKS" | tr -d '[:space:]')" ]]; then
        echo "[!] Could not extract any vless:// from sub URL response." >&2
        echo "    Body head: $(printf '%s' "$BODY" | head -c 200)" >&2
        exit 1
    fi

    echo "[*] Writing $(printf '%s' "$LINKS" | grep -c '^vless://' || true) vless:// to $LOCAL_FILE"
fi

# ====== Mode 2: stdin ======
if [[ $FROM_STDIN -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 0 ]] && have_tty; then
        echo
        echo "Paste vless:// links (one per line, end with '.' or Ctrl-D):"
        LINKS=""
        while IFS= read -r line <&3; do
            [[ "$line" == "." ]] && break
            LINKS+="$line"$'\n'
        done
    else
        # Read from stdin if no TTY
        LINKS=$(cat || true)
    fi

    LINKS=$(printf '%s' "$LINKS" | grep -E '^vless://' || true)
    if [[ -z "$(printf '%s' "$LINKS" | tr -d '[:space:]')" ]]; then
        echo "[!] No vless:// lines on stdin." >&2
        exit 1
    fi
    echo "[*] Read $(printf '%s' "$LINKS" | grep -c '^vless://') vless:// lines from stdin"
fi

# Write local file with header comments
{
    printf '# add_vless.sh generated\n'
    printf '# Server alias: %s\n' "$SERVER_ALIAS"
    printf '# Target user:  %s\n' "$USER"
    printf '# Generated at: %s\n' "$(date -u +%F %T)"
    if [[ -n "$SUB_URL" ]]; then
        printf '# Source:       %s\n' "$SUB_URL"
    else
        printf '# Source:       stdin\n'
    fi
    printf '%s\n' "$LINKS"
} > "$LOCAL_FILE"
chmod 600 "$LOCAL_FILE"

echo
echo "[*] Saved: $LOCAL_FILE"

# ====== Upload to nether2 ======
REMOTE_DIR="$DATA_DIR/$USER/foreign"
REMOTE_DST="$REMOTE_DIR/$REMOTE_FILENAME"
REMOTE_TMP="$REMOTE_DIR/.$REMOTE_FILENAME.tmp.$$"

echo "[*] Pre-flight: $REMOTE_DST must not exist"
sq() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

if ssh "$NETHER_HOST" "test -e $(sq "$REMOTE_DST")" 2>/dev/null; then
    echo "[!] Remote file already exists, refusing to overwrite: $REMOTE_DST" >&2
    exit 1
fi
echo "[*] Upload: $LOCAL_FILE -> $NETHER_HOST:$REMOTE_DST"
ssh "$NETHER_HOST" "set -e; mkdir -p $(sq "$REMOTE_DIR")"
ssh "$NETHER_HOST" "set -e; umask 077; cat > $(sq "$REMOTE_TMP")" < "$LOCAL_FILE"
ssh "$NETHER_HOST" "set -e; mv $(sq "$REMOTE_TMP") $(sq "$REMOTE_DST")"
echo "[+] Upload done"

# ====== run buildvpn ======
if [[ $SKIP_BUILD -eq 1 ]]; then
    echo "[*] --skip-build set; not running buildvpn"
    exit 0
fi

echo
echo "[*] Running buildvpn on $NETHER_HOST..."
extract_remote_cd() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}
REMOTE_CD=$(extract_remote_cd "$DATA_DIR")
ssh -tt "$NETHER_HOST" "bash -ic 'cd ${REMOTE_CD} && buildvpn'"
