#!/usr/bin/env bash
# Creates the venv on first run, then starts the API. The Godot client
# auto-invokes this once if the backend is down (see ui/llm_client.gd).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  python3 -m venv .venv
  ./.venv/bin/pip install --quiet --upgrade pip
  ./.venv/bin/pip install --quiet -r requirements.txt
fi
[ -f .env ] || cp .env.example .env

# 127.0.0.1 only: this process holds the API key and has no auth of its own.
#
# When autostarted by the game (not a tty) the output goes to a file rather than
# to the inherited pipe. The backend outlives the client that started it and
# keeps generating the next world in the background — with an inherited pipe,
# the moment the client exits, that background work dies on its first write to
# a reader that is gone.
if [ -t 1 ]; then
  exec ./.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
fi
exec ./.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000 >> backend.log 2>&1
