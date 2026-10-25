#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/phoenix_rewrite" && pwd)"
PORT="${1:-4001}"

cd "$APP_DIR"
export MIX_ENV="dev"
export PHX_SERVER="true"
export PORT="$PORT"

exec mix phx.server
