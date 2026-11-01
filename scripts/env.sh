#!/usr/bin/env bash
# Source from bash: . scripts/env.sh
INKNOTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IDF_TOOLS_PATH="$INKNOTE_ROOT/tools/espressif"
export PATH="$INKNOTE_ROOT/tools/host-venv/bin:$PATH"
. "$INKNOTE_ROOT/tools/esp-idf/export.sh"
