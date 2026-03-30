#!/usr/bin/env bash
# Format all Haskell source files using fourmolu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

HS_FILES=$(find src app -name "*.hs" 2>/dev/null)

if [ -z "$HS_FILES" ]; then
  echo "No .hs files found in src/ or app/"
  exit 0
fi

# Try fourmolu first, fall back to ormolu
if command -v fourmolu &>/dev/null; then
  echo "$HS_FILES" | xargs fourmolu --mode inplace
  echo "Formatted all .hs files (fourmolu)"
elif command -v ormolu &>/dev/null; then
  echo "$HS_FILES" | xargs ormolu --mode inplace
  echo "Formatted all .hs files (ormolu)"
else
  echo "Neither fourmolu nor ormolu found. Install one to format code."
  exit 1
fi
