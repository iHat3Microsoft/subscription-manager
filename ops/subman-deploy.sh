#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/subscription-manager"

cd "$REPO_DIR"
git pull --ff-only origin master
npm ci --omit=dev
BASE_URL="https://sub.k3k.lol" node src/build.js
