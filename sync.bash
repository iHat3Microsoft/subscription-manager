#!/usr/bin/env bash
set -euo pipefail

# Future manual sync helper (does not run build/deploy).
# Usage:
#   ./sync.bash
#   SSH_CONFIG=/path/to/ssh_config REMOTE=nether2 REMOTE_DIR=/opt/subscription-manager ./sync.bash

SSH_CONFIG="${SSH_CONFIG:-/home/chm0d777/.config/ssh-mcp/ssh_config}"
REMOTE="${REMOTE:-nether2}"
REMOTE_DIR="${REMOTE_DIR:-/opt/subscription-manager}"

# Sync the whole src/ set: build.js requires parsers.js, so shipping
# only build.js would put a new build on top of an old parser.
rsync -avz --progress \
  -e "ssh -F ${SSH_CONFIG}" \
  src/build.js src/parsers.js \
  "${REMOTE}:${REMOTE_DIR}/src/"

echo "Synced src/build.js, src/parsers.js to ${REMOTE}:${REMOTE_DIR}/src/"
