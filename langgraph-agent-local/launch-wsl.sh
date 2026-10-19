#!/bin/bash
# Local agent — launch langgraph dev on port 2024, bind to all interfaces
# so Windows browser at localhost:2024 can reach WSL.
# The default KB profile is custom; run with FOUNDRY_KB_PROFILE=baseline to fall back.
set -e
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"
rm -f langgraph.log
nohup .venv/bin/python -m langgraph_cli dev --port 2024 --no-browser --host 0.0.0.0 --allow-blocking > langgraph.log 2>&1 &
LG_PID=$!
disown
echo "PID=$LG_PID"
sleep 10
echo "--- log ---"
cat langgraph.log
echo "--- port check ---"
ss -tln | grep :2024 || echo "not listening"
