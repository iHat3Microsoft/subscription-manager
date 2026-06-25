#!/usr/bin/env bash
set -euo pipefail

CONTAINER="amnezia-awg2"
AWG_CONF="/opt/amnezia/awg/awg0.conf"
CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
SERVER_PUB_FILE="/opt/amnezia/awg/wireguard_server_public_key.key"
PSK_FILE="/opt/amnezia/awg/wireguard_psk.key"

OUT_DIR="./out_keys"

IDENTITY=""
SSH_PORT=""
USE_SSHPASS=0

ENDPOINT_OVERRIDE=""
ENDPOINT_HOST_OVERRIDE=""
DNS_OVERRIDE=""

usage() {
    cat <<EOF
Usage:
  $0 [options] <ssh-target> <user... | prefix:count>

Examples:
  $0 vds2 user1
  $0 vds2 user1 user2 user3
  $0 vds2 user:10
  $0 -i ~/.ssh/id_ed25519 root@87.232.123.191 user:10
  SSHPASS='password' $0 --password root@87.232.123.191 user:10

Options:
  -i, --identity PATH       SSH private key
  -p, --port PORT           SSH port
  --password                Use sshpass with SSHPASS env var
  --container NAME          Docker container name, default: amnezia-awg2
  --out-dir DIR             Local output dir, default: ./out_keys
  --endpoint HOST:PORT      Override final Endpoint
  --endpoint-host HOST      Override endpoint host, port is taken from awg0.conf
  --dns "A, B"              Override DNS in generated client configs
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--identity)
            IDENTITY="${2:?missing identity path}"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="${2:?missing ssh port}"
            shift 2
            ;;
        --password)
            USE_SSHPASS=1
            shift
            ;;
        --container)
            CONTAINER="${2:?missing container name}"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="${2:?missing out dir}"
            shift 2
            ;;
        --endpoint)
            ENDPOINT_OVERRIDE="${2:?missing endpoint}"
            shift 2
            ;;
        --endpoint-host)
            ENDPOINT_HOST_OVERRIDE="${2:?missing endpoint host}"
            shift 2
            ;;
        --dns)
            DNS_OVERRIDE="${2:?missing dns value}"
            shift 2
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
            echo "[!] Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    usage
    exit 1
fi
shift

if [[ $# -lt 1 ]]; then
    echo "[!] Need at least one username or prefix:count"
    usage
    exit 1
fi

USERS=()

while [[ $# -gt 0 ]]; do
    ARG="$1"
    shift

    if [[ "$ARG" =~ ^([A-Za-z0-9._-]+):([0-9]+)$ ]]; then
        PREFIX="${BASH_REMATCH[1]}"
        COUNT="${BASH_REMATCH[2]}"

        if [[ "$COUNT" -lt 1 ]]; then
            echo "[!] Bad count: $ARG"
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
        echo "[!] Bad username '$u'. Use only letters, digits, dot, underscore, dash."
        exit 1
    fi

    if [[ -n "${SEEN[$u]:-}" ]]; then
        echo "[!] Duplicate username in arguments: $u"
        exit 1
    fi

    SEEN[$u]=1
done

if [[ "$USE_SSHPASS" -eq 1 ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "[!] sshpass not found locally"
        exit 1
    fi

    if [[ -z "${SSHPASS:-}" ]]; then
        echo "[!] Set SSHPASS env var, example:"
        echo "    SSHPASS='password' $0 --password root@host user:10"
        exit 1
    fi

    SSH_BIN=(sshpass -e ssh)
    SCP_BIN=(sshpass -e scp)
else
    SSH_BIN=(ssh)
    SCP_BIN=(scp)
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

COMMON_OPTS=(
    -o ControlMaster=auto
    -o ControlPersist=5m
    -o ControlPath="$TMPDIR/ssh_mux_%C"
    -o StrictHostKeyChecking=accept-new
)

SSH_OPTS=("${COMMON_OPTS[@]}")
SCP_OPTS=("${COMMON_OPTS[@]}")

if [[ -n "$SSH_PORT" ]]; then
    SSH_OPTS+=(-p "$SSH_PORT")
    SCP_OPTS+=(-P "$SSH_PORT")
fi

if [[ -n "$IDENTITY" ]]; then
    SSH_OPTS+=(-i "$IDENTITY")
    SCP_OPTS+=(-i "$IDENTITY")
fi

ssh_remote() {
    "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "$TARGET" "$@"
}

scp_to_remote() {
    local src="$1"
    local dst="$2"
    "${SCP_BIN[@]}" "${SCP_OPTS[@]}" "$src" "$TARGET:$dst"
}

sq() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

valid_wg_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

REMOTE_CONTAINER="$(sq "$CONTAINER")"
REMOTE_AWG_CONF="$(sq "$AWG_CONF")"
REMOTE_CLIENTS_TABLE="$(sq "$CLIENTS_TABLE")"
REMOTE_SERVER_PUB_FILE="$(sq "$SERVER_PUB_FILE")"
REMOTE_PSK_FILE="$(sq "$PSK_FILE")"

echo "[*] Target: $TARGET"
echo "[*] Container: $CONTAINER"
echo "[*] Users: ${USERS[*]}"

echo "[*] Checking remote container..."
ssh_remote "sudo docker inspect $REMOTE_CONTAINER >/dev/null"

SERVER_CONF_LOCAL="$TMPDIR/awg0.conf"
CLIENTS_TABLE_LOCAL="$TMPDIR/clientsTable"

echo "[*] Reading server awg0.conf..."
ssh_remote "sudo docker exec $REMOTE_CONTAINER cat $REMOTE_AWG_CONF" > "$SERVER_CONF_LOCAL"

echo "[*] Reading clientsTable..."
ssh_remote "sudo docker exec $REMOTE_CONTAINER cat $REMOTE_CLIENTS_TABLE 2>/dev/null || printf '[]\n'" > "$CLIENTS_TABLE_LOCAL"

echo "[*] Reading server public key directly from file..."
SERVER_PUBLIC_KEY="$(
    ssh_remote "sudo docker exec $REMOTE_CONTAINER cat $REMOTE_SERVER_PUB_FILE 2>/dev/null || true" \
    | tr -d '\r\n'
)"

if ! valid_wg_key "$SERVER_PUBLIC_KEY"; then
    echo "[!] Server public key from $SERVER_PUB_FILE looks invalid:"
    echo "    '$SERVER_PUBLIC_KEY'"
    echo
    echo "Debug locally:"
    echo "    ssh $TARGET \"sudo docker exec $CONTAINER cat $SERVER_PUB_FILE\" | xxd -p -c 256"
    exit 1
fi

echo "[*] Reading preshared key..."
PRESHARED_KEY="$(
    ssh_remote "sudo docker exec $REMOTE_CONTAINER cat $REMOTE_PSK_FILE 2>/dev/null || true" \
    | tr -d '\r\n'
)"

if ! valid_wg_key "$PRESHARED_KEY"; then
    PRESHARED_KEY="$(
        awk -F'= *' '
            /^[[:space:]]*PresharedKey[[:space:]]*=/ {
                print $2
                exit
            }
        ' "$SERVER_CONF_LOCAL" | tr -d '\r\n'
    )"
fi

if ! valid_wg_key "$PRESHARED_KEY"; then
    echo "[!] Could not get valid PresharedKey"
    exit 1
fi

LISTEN_PORT="$(
    awk -F'= *' '
        /^\[Interface\]/ { in_iface=1; next }
        /^\[/ && in_iface { exit }
        in_iface && /^[[:space:]]*ListenPort[[:space:]]*=/ {
            print $2
            exit
        }
    ' "$SERVER_CONF_LOCAL" | tr -d ' \r\n'
)"

if [[ -z "$LISTEN_PORT" ]]; then
    echo "[!] Could not find ListenPort in $AWG_CONF"
    exit 1
fi

AWG_EXTRA="$(
    awk '
        /^\[Interface\]/ {
            in_iface=1
            next
        }

        /^\[/ && in_iface {
            exit
        }

        in_iface && /^[[:space:]]*#?[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5])[[:space:]]*=/ {
            print
        }
    ' "$SERVER_CONF_LOCAL" \
    | sed -E 's/^[[:space:]]*#[[:space:]]*//' \
    | sed '/^[[:space:]]*$/d'
)"

if [[ -z "$AWG_EXTRA" ]]; then
    echo "[!] Could not extract AmneziaWG params: Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5"
    exit 1
fi

DNS_VALUE="$DNS_OVERRIDE"

if [[ -z "$DNS_VALUE" ]]; then
    DNS_VALUE="$(
        awk -F'= *' '
            /^\[Interface\]/ { in_iface=1; next }
            /^\[/ && in_iface { exit }
            in_iface && /^[[:space:]]*DNS[[:space:]]*=/ {
                print $2
                exit
            }
        ' "$SERVER_CONF_LOCAL" | tr -d '\r' | xargs || true
    )"
fi

# Если DNS не записан в awg0.conf, повторяем логику Amnezia:
# берём docker gateway основной Amnezia-сети, например 172.29.172.1,
# и превращаем его в 172.29.172.254.
if [[ -z "$DNS_VALUE" ]]; then
    DOCKER_GATEWAY="$(
        ssh_remote "sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{println .Gateway}}{{end}}' $REMOTE_CONTAINER 2>/dev/null || true" \
        | tr -d '\r' \
        | awk '
            /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 != "172.17.0.1" {
                print
                exit
            }
        '
    )"

    if [[ -n "$DOCKER_GATEWAY" ]]; then
        DNS_PRIMARY="$(
            printf '%s\n' "$DOCKER_GATEWAY" \
            | awk -F. '{print $1 "." $2 "." $3 ".254"}'
        )"

        DNS_VALUE="${DNS_PRIMARY}, 1.0.0.1"
    fi
fi

if [[ -z "$DNS_VALUE" ]]; then
    DNS_VALUE="172.29.172.254, 1.0.0.1"
fi

if [[ -n "$ENDPOINT_OVERRIDE" ]]; then
    ENDPOINT_VALUE="$ENDPOINT_OVERRIDE"
else
    ENDPOINT_HOST="$ENDPOINT_HOST_OVERRIDE"

    if [[ -z "$ENDPOINT_HOST" ]]; then
        ENDPOINT_HOST="$(
            ssh -G "$TARGET" 2>/dev/null \
            | awk '/^hostname / {print $2; exit}' \
            | tr -d '\r\n'
        )"
    fi

    if [[ -z "$ENDPOINT_HOST" || "$ENDPOINT_HOST" == "$TARGET" ]]; then
        ENDPOINT_HOST="$(
            ssh_remote "curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null || wget -qO- -T 3 https://api.ipify.org 2>/dev/null || true" \
            | tr -d '\r\n'
        )"
    fi

    if [[ -z "$ENDPOINT_HOST" ]]; then
        ENDPOINT_HOST="$(
            ssh_remote "ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"src\") print \$(i+1)}' | head -n1 || true" \
            | tr -d '\r\n'
        )"
    fi

    if [[ -z "$ENDPOINT_HOST" ]]; then
        echo "[!] Could not determine endpoint host. Use --endpoint or --endpoint-host."
        exit 1
    fi

    ENDPOINT_VALUE="${ENDPOINT_HOST}:${LISTEN_PORT}"
fi

read -r NET_PREFIX MAX_OCTET < <(
python3 - "$SERVER_CONF_LOCAL" <<'PY_NET'
import re
import sys

path = sys.argv[1]
prefix = None
max_octet = 1

def consider_value(value: str):
    global prefix, max_octet

    # Берём только первую часть до запятой:
    # "10.8.1.5/32, ..." -> "10.8.1.5/32"
    first = value.split(",", 1)[0].strip()

    m = re.match(r"^(\d+)\.(\d+)\.(\d+)\.(\d+)(?:/\d+)?$", first)
    if not m:
        return

    a, b, c, d = map(int, m.groups())

    # Игнорируем клиентские маршруты вида 0.0.0.0/0
    if (a, b, c, d) == (0, 0, 0, 0):
        return

    prefix = f"{a}.{b}.{c}"

    if d > max_octet:
        max_octet = d

with open(path, "r", encoding="utf-8", errors="ignore") as f:
    for raw in f:
        line = raw.strip()

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if key in ("AllowedIPs", "Address"):
            consider_value(value)

if prefix is None:
    prefix = "10.8.1"

print(prefix, max_octet)
PY_NET
)

mkdir -p "$OUT_DIR/$TARGET"
chmod 700 "$OUT_DIR" "$OUT_DIR/$TARGET" 2>/dev/null || true

PEERS_APPEND="$TMPDIR/peers.append"
ADDITIONS="$TMPDIR/additions.tsv"
: > "$PEERS_APPEND"
: > "$ADDITIONS"

echo "[*] DNS: $DNS_VALUE"
echo "[*] Endpoint: $ENDPOINT_VALUE"
echo "[*] Existing max IP: ${NET_PREFIX}.${MAX_OCTET}"
echo

for USERNAME in "${USERS[@]}"; do
    MAX_OCTET=$((MAX_OCTET + 1))
    CLIENT_IP="${NET_PREFIX}.${MAX_OCTET}"
    CLIENT_ADDR="${CLIENT_IP}/32"

    CLIENT_CONF="$OUT_DIR/$TARGET/${USERNAME}.conf"
    CLIENT_INFO="$OUT_DIR/$TARGET/${USERNAME}.info"

    if [[ -e "$CLIENT_CONF" || -e "$CLIENT_INFO" ]]; then
        echo "[!] Output already exists for $USERNAME:"
        echo "    $CLIENT_CONF"
        echo "    $CLIENT_INFO"
        echo "    Remove old files or choose another username."
        exit 1
    fi

    echo "[*] Generating $USERNAME -> $CLIENT_ADDR"

    CLIENT_PRIVATE_KEY="$(
        ssh_remote "sudo docker exec $REMOTE_CONTAINER awg genkey" \
        | tr -d '\r\n'
    )"

    if ! valid_wg_key "$CLIENT_PRIVATE_KEY"; then
        echo "[!] Generated bad private key for $USERNAME"
        exit 1
    fi

    CLIENT_PUBLIC_KEY="$(
        printf '%s\n' "$CLIENT_PRIVATE_KEY" \
        | "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "$TARGET" "sudo docker exec -i $REMOTE_CONTAINER awg pubkey" \
        | tr -d '\r\n'
    )"

    if ! valid_wg_key "$CLIENT_PUBLIC_KEY"; then
        echo "[!] Generated bad public key for $USERNAME"
        exit 1
    fi

    cat >> "$PEERS_APPEND" <<EOF_PEER

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = $CLIENT_ADDR
EOF_PEER

    cat > "$CLIENT_CONF" <<EOF_CONF
[Interface]
Address = $CLIENT_ADDR
DNS = $DNS_VALUE
PrivateKey = $CLIENT_PRIVATE_KEY
$AWG_EXTRA

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $ENDPOINT_VALUE
PersistentKeepalive = 25
EOF_CONF

    cat > "$CLIENT_INFO" <<EOF_INFO
username=$USERNAME
client_ip=$CLIENT_ADDR
client_private_key=$CLIENT_PRIVATE_KEY
client_public_key=$CLIENT_PUBLIC_KEY
preshared_key=$PRESHARED_KEY
server_public_key=$SERVER_PUBLIC_KEY
dns=$DNS_VALUE
endpoint=$ENDPOINT_VALUE
config=$CLIENT_CONF
created_at=$(date '+%F %T')
EOF_INFO

    chmod 600 "$CLIENT_CONF" "$CLIENT_INFO"

    CREATION_DATE="$(LC_ALL=C date '+%a %b %d %H:%M:%S %Y')"
    printf '%s\t%s\t%s\n' "$USERNAME" "$CLIENT_PUBLIC_KEY" "$CREATION_DATE" >> "$ADDITIONS"
done

CLIENTS_TABLE_NEW="$TMPDIR/clientsTable.new"

python3 - "$CLIENTS_TABLE_LOCAL" "$ADDITIONS" "$CLIENTS_TABLE_NEW" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
additions = Path(sys.argv[2])
dst = Path(sys.argv[3])

try:
    data = json.loads(src.read_text())
except Exception:
    data = []

if not isinstance(data, list):
    data = []

new_items = []
new_ids = set()

for line in additions.read_text().splitlines():
    if not line.strip():
        continue

    name, pub, creation = line.split("\t", 2)
    new_ids.add(pub)
    new_items.append({
        "clientId": pub,
        "userData": {
            "clientName": name,
            "creationDate": creation
        }
    })

data = [x for x in data if x.get("clientId") not in new_ids]
data.extend(new_items)

dst.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n")
PY

TS="$(date '+%Y%m%d_%H%M%S')_$$"
REMOTE_PEERS="/tmp/amnezia_gen_${TS}.peers"
REMOTE_CLIENTS="/tmp/amnezia_gen_${TS}.clientsTable"
CONTAINER_PEERS="/tmp/amnezia_gen_${TS}.peers"

echo
echo "[*] Uploading peer block like Amnezia..."
scp_to_remote "$PEERS_APPEND" "$REMOTE_PEERS"

REMOTE_PEERS_Q="$(sq "$REMOTE_PEERS")"
REMOTE_CLIENTS_Q="$(sq "$REMOTE_CLIENTS")"
CONTAINER_PEERS_Q="$(sq "$CONTAINER_PEERS")"

ssh_remote "sudo docker cp $REMOTE_PEERS_Q $REMOTE_CONTAINER:$CONTAINER_PEERS_Q"

APPEND_CMD="cat $CONTAINER_PEERS_Q >> $REMOTE_AWG_CONF && rm -f $CONTAINER_PEERS_Q"
ssh_remote "sudo docker exec $REMOTE_CONTAINER sh -c $(sq "$APPEND_CMD")"

ssh_remote "shred -u $REMOTE_PEERS_Q 2>/dev/null || rm -f $REMOTE_PEERS_Q"

echo "[*] Applying awg syncconf..."
SYNC_CMD="awg syncconf awg0 <(awg-quick strip $REMOTE_AWG_CONF)"
ssh_remote "sudo docker exec $REMOTE_CONTAINER bash -c $(sq "$SYNC_CMD")"

echo "[*] Uploading updated clientsTable..."
scp_to_remote "$CLIENTS_TABLE_NEW" "$REMOTE_CLIENTS"
ssh_remote "sudo docker cp $REMOTE_CLIENTS_Q $REMOTE_CONTAINER:$REMOTE_CLIENTS_TABLE"
ssh_remote "shred -u $REMOTE_CLIENTS_Q 2>/dev/null || rm -f $REMOTE_CLIENTS_Q"

echo
echo "[+] Done"
echo "[+] Configs saved in:"
echo "    $OUT_DIR/$TARGET"
echo
ls -lah "$OUT_DIR/$TARGET"

echo
echo "[*] Remote peer count:"
ssh_remote "sudo docker exec $REMOTE_CONTAINER awg show awg0 | grep -c '^peer:' || true"
