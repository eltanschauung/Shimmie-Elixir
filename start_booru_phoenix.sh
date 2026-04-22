#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/home/USERNAME/shimmie2-elixir/phoenix_rewrite"
PORT="${1:-4001}"

cd "$APP_DIR"
export MIX_ENV="${MIX_ENV:-prod}"
export PHX_SERVER="true"
export PORT="$PORT"

exec mix phx.server
