#!/bin/bash
# Local agent install script — run from WSL Ubuntu.
set -e
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

echo "=== pip install starting at $(date) ==="
.venv/bin/pip install --disable-pip-version-check \
  langgraph \
  langchain \
  langchain-openai \
  'langchain-azure-ai[tools]>=1.2.3' \
  langchain-mcp-adapters \
  'azure-identity>=1.19.0' \
  python-dotenv \
  'langgraph-cli[inmem]' \
  2>&1
echo "=== pip install DONE (exit $?) at $(date) ==="
