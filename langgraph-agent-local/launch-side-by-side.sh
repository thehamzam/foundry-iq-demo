#!/bin/bash
# Set up two isolated az CLI config dirs — one per persona — so we can run two
# Local agent instances at the same time, each authenticated as a different user.
#
#   ~/.azure-admin/      <- admin token cache
#   ~/.azure-frontline/  <- frontline token cache
#
# Then launches two langgraph dev processes:
#   port 2024 → dispute_agent as admin
#   port 2025 → dispute_agent as frontline
# Both use the custom KB profile by default; set FOUNDRY_KB_PROFILE=baseline to fall back.
#
# You still need to complete `az login` inside each config dir once (device code).
# This script prints instructions.

set -e
CFG_ADMIN=${CFG_ADMIN:-"$HOME/.azure-admin"}
CFG_FRONTLINE=${CFG_FRONTLINE:-"$HOME/.azure-frontline"}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TENANT_ARGS=()
if [ -n "${AZURE_TENANT_ID:-}" ]; then
  TENANT_ARGS=(--tenant "$AZURE_TENANT_ID")
fi

mkdir -p "$CFG_ADMIN" "$CFG_FRONTLINE"

echo "=== admin config dir ==="
if AZURE_CONFIG_DIR=$CFG_ADMIN az account show --query 'user.name' -o tsv >/dev/null 2>&1; then
  echo "  already signed in as admin"
else
  echo "  running device-code login in $CFG_ADMIN; sign in as the admin persona"
  AZURE_CONFIG_DIR=$CFG_ADMIN az login --use-device-code "${TENANT_ARGS[@]}"
fi

echo
echo "=== frontline config dir ==="
if AZURE_CONFIG_DIR=$CFG_FRONTLINE az account show --query 'user.name' -o tsv >/dev/null 2>&1; then
  echo "  already signed in as frontline"
else
  echo "  running device-code login in $CFG_FRONTLINE; sign in as the frontline persona"
  AZURE_CONFIG_DIR=$CFG_FRONTLINE az login --use-device-code "${TENANT_ARGS[@]}"
fi

echo
echo "=== kill any existing langgraph dev processes ==="
pkill -9 -f langgraph_cli 2>/dev/null || true
sleep 3

echo
echo "=== launch Local agent (admin) on port 2024 ==="
cd "$SCRIPT_DIR"
rm -f langgraph.admin.log
AZURE_CONFIG_DIR=$CFG_ADMIN nohup .venv/bin/python -m langgraph_cli dev --port 2024 --no-browser --host 0.0.0.0 --allow-blocking > langgraph.admin.log 2>&1 &
disown
echo "  PID_admin=$!"

sleep 2

echo "=== launch Local agent (frontline) on port 2025 ==="
AZURE_CONFIG_DIR=$CFG_FRONTLINE nohup .venv/bin/python -m langgraph_cli dev --port 2025 --no-browser --host 0.0.0.0 --allow-blocking > langgraph.frontline.log 2>&1 &
disown
echo "  PID_frontline=$!"

sleep 60
echo
echo "=== port check ==="
ss -tln | grep -E ':2024|:2025' || echo "not yet listening"

echo
echo "=== Studio URLs ==="
echo "  admin: https://smith.langchain.com/studio/?baseUrl=http://localhost:2024"
echo "  frontline: https://smith.langchain.com/studio/?baseUrl=http://localhost:2025"
