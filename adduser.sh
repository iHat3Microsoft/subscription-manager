#!/usr/bin/env bash
set -euo pipefail

NETHER_HOST="${NETHER_HOST:-nether2}"
DATA_DIR="${DATA_DIR:-/opt/subscription-manager/data}"
GEN_SCRIPT="${GEN_SCRIPT:-./gen.sh}"
BUILD_CMD="${BUILD_CMD:-buildvpn}"

DRY_RUN=0
SKIP_BUILD=0
REUSE_LOCAL=0
USERNAME=""

usage() {
    cat <<EOF
Usage:
  $0 [options] <username>

Example:
  $0 friend_alexey
  $0 --reuse-local friend_alexey
  $0 --dry-run --reuse-local friend_alexey

Options:
  --nether HOST        Subscription-manager SSH alias, default: nether2
  --data-dir PATH      Remote data dir, default: /opt/subscription-manager/data
  --gen-script PATH    Local generator script, default: ./gen.sh
  --build-cmd CMD      Remote build command, default: buildvpn
  --reuse-local        Skip gen.sh, reuse already-generated ./out_keys/<server>/<user>.conf
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
        --gen-script)
            GEN_SCRIPT="${2:?missing gen script}"
            shift 2
            ;;
        --build-cmd)
            BUILD_CMD="${2:?missing build command}"
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

USERNAME="${1:-}"

if [[ -z "$USERNAME" ]]; then
    usage
    exit 1
fi

if [[ ! "$USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[!] Bad username '$USERNAME'. Use only letters, digits, dot, underscore, dash."
    exit 1
fi

if [[ ! -f "$GEN_SCRIPT" ]]; then
    echo "[!] gen script not found: $GEN_SCRIPT"
    exit 1
fi

sq() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

ssh_nether() {
    ssh "$NETHER_HOST" "$@"
}

parse_csv_aliases() {
    local raw="$1"
    local -n out=$2
    out=()
    if [[ -z "$raw" ]]; then
        return
    fi
    IFS=',' read -ra parts <<< "$raw"
    for p in "${parts[@]}"; do
        p="${p// /}"
        if [[ -n "$p" ]]; then
            out+=("$p")
        fi
    done
}

ask_filename() {
    local alias="$1"
    local default_name="$2"
    local raw
    while true; do
        read -rp "Display filename for '$alias' [$default_name]: " raw
        if [[ -z "$raw" ]]; then
            raw="$default_name"
        fi
        case "$raw" in
            */*|.*|..)
                echo "[!] Bad filename '$raw'. Use plain filename, no path, not starting with dot."
                continue
                ;;
        esac
        if [[ -z "$raw" ]]; then
            echo "[!] Empty filename"
            continue
        fi
        printf '%s' "$raw"
        return
    done
}

echo "[*] Username: $USERNAME"
echo "[*] Subscription host: $NETHER_HOST"
echo "[*] Data dir: $DATA_DIR"
echo

echo "RU server SSH aliases (comma-separated, empty to skip):"
read -r RU_INPUT
parse_csv_aliases "$RU_INPUT" RU_ALIASES

echo "Foreign server SSH aliases (comma-separated, empty to skip):"
read -r FOREIGN_INPUT
parse_csv_aliases "$FOREIGN_INPUT" FOREIGN_ALIASES

if [[ "${#RU_ALIASES[@]}" -eq 0 && "${#FOREIGN_ALIASES[@]}" -eq 0 ]]; then
    echo "[!] Need at least one server alias"
    exit 1
fi

declare -A SEEN_ALIAS=()
for a in "${RU_ALIASES[@]}" "${FOREIGN_ALIASES[@]}"; do
    if [[ -n "${SEEN_ALIAS[$a]:-}" ]]; then
        echo "[!] Duplicate alias: $a"
        exit 1
    fi
    SEEN_ALIAS[$a]=1
done

SERVERS=()

if [[ "${#RU_ALIASES[@]}" -gt 0 ]]; then
    echo
    echo "[*] RU servers:"
    for a in "${RU_ALIASES[@]}"; do
        fname="$(ask_filename "$a" "$a")"
        SERVERS+=("$a|ru|$fname")
    done
fi

if [[ "${#FOREIGN_ALIASES[@]}" -gt 0 ]]; then
    echo
    echo "[*] Foreign servers:"
    for a in "${FOREIGN_ALIASES[@]}"; do
        fname="$(ask_filename "$a" "$a")"
        SERVERS+=("$a|foreign|$fname")
    done
fi

echo
echo "[*] Preflight..."

if ssh_nether "test -e $(sq "$DATA_DIR/$USERNAME")"; then
    echo "[!] User folder already exists on $NETHER_HOST: $DATA_DIR/$USERNAME"
    exit 1
fi

for entry in "${SERVERS[@]}"; do
    IFS='|' read -r alias cat fname <<< "$entry"
    conf="./out_keys/$alias/$USERNAME.conf"
    info="./out_keys/$alias/$USERNAME.info"

    if [[ "$REUSE_LOCAL" -eq 1 ]]; then
        if [[ ! -e "$conf" || ! -e "$info" ]]; then
            echo "[!] --reuse-local: missing $conf or $info"
            exit 1
        fi
    else
        if [[ -e "$conf" || -e "$info" ]]; then
            echo "[!] Local config already exists: $conf"
            echo "    Move/remove or use --reuse-local"
            exit 1
        fi
    fi
done

echo "[*] Preflight OK"
echo

echo "[*] Plan for '$USERNAME':"
for entry in "${SERVERS[@]}"; do
    IFS='|' read -r alias cat fname <<< "$entry"
    echo "    $alias -> $NETHER_HOST:$DATA_DIR/$USERNAME/$cat/$fname"
done
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
    exit 0
fi

NEED_RU=0
NEED_FOREIGN=0
for entry in "${SERVERS[@]}"; do
    IFS='|' read -r alias cat fname <<< "$entry"
    if [[ "$cat" == "ru" ]]; then
        NEED_RU=1
    else
        NEED_FOREIGN=1
    fi
done

if [[ "$NEED_RU" -eq 1 ]]; then
    ssh_nether "mkdir -p $(sq "$DATA_DIR/$USERNAME/ru")"
fi
if [[ "$NEED_FOREIGN" -eq 1 ]]; then
    ssh_nether "mkdir -p $(sq "$DATA_DIR/$USERNAME/foreign")"
fi

for entry in "${SERVERS[@]}"; do
    IFS='|' read -r alias cat fname <<< "$entry"
    conf="./out_keys/$alias/$USERNAME.conf"

    if [[ "$REUSE_LOCAL" -eq 0 ]]; then
        echo "[*] Generating on '$alias' for '$USERNAME'..."
        bash "$GEN_SCRIPT" "$alias" "$USERNAME"
    else
        echo "[*] Reusing local configs for '$alias'"
    fi

    if [[ ! -s "$conf" ]]; then
        echo "[!] Missing config: $conf"
        exit 1
    fi

    remote_dir="$DATA_DIR/$USERNAME/$cat"
    remote_dst="$remote_dir/$fname"
    remote_tmp="$remote_dir/.$fname.tmp.$$"

    echo "    upload -> $remote_dst"

    ssh_nether "set -e; test ! -e $(sq "$remote_dst")"
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
