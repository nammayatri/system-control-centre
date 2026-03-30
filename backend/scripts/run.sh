#!/usr/bin/env bash
# Run System Control Centre backend
# Usage: ./scripts/run.sh
#
# This script:
# 1. Sets up the local database (if needed)
# 2. Builds the Haskell project
# 3. Starts the server on PORT (default 8012)
#
# Environment variables:
#   SC_DB_NAME  — database name (default: system_control)
#   SC_DB_USER  — database user (default: current user)
#   SC_DB_HOST  — database host (default: localhost)
#   SC_DB_PORT  — database port (default: 5432)
#   PORT        — server port (default: 8012)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

DB_NAME="${SC_DB_NAME:-system_control}"
DB_USER="${SC_DB_USER:-$(whoami)}"
DB_HOST="${SC_DB_HOST:-localhost}"
DB_PORT="${SC_DB_PORT:-5432}"
SERVER_PORT="${PORT:-8012}"

echo "╔══════════════════════════════════════╗"
echo "║     System Control Centre            ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Step 1: Setup database
echo "── Step 1: Database ──"
bash "$SCRIPT_DIR/setup-db.sh"

# Step 2: Build
echo ""
echo "── Step 2: Build ──"
cabal build 2>&1 | tail -5

# Step 3: Start server
echo ""
echo "── Step 3: Starting server ──"
echo "  Port: $SERVER_PORT"
echo "  DB:   postgres://$DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
echo ""

export NammaAP_DATABASE_URL="postgres://$DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
export PORT="$SERVER_PORT"

exec cabal run namma-ap-exe
