#!/usr/bin/env bash
# Runs the tomedown.koplugin test suite.
#   ./run.sh              uses `lua` from PATH (5.3+: the test md5 needs
#                          bitwise operators)
#   LUA=lua5.4 ./run.sh   to pick a specific interpreter (CI does this)
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "${LUA:-}" ]; then
    :
elif command -v lua >/dev/null 2>&1; then
    LUA=lua
else
    for candidate in lua5.5 lua5.4 lua5.3; do
        if command -v "$candidate" >/dev/null 2>&1; then
            LUA=$candidate
            break
        fi
    done
fi
: "${LUA:=lua}"

PLUGIN="${TOMEDOWN_PLUGIN_DIR:-$(cd .. && pwd)}"
export TOMEDOWN_PLUGIN_DIR="$PLUGIN"

if [ ! -f "$PLUGIN/main.lua" ]; then
    echo "plugin not found: $PLUGIN" >&2
    exit 1
fi

echo "=== test_render"
"$LUA" test_render.lua
echo "=== test_po"
"$LUA" test_po.lua
echo "=== test_i18n"
"$LUA" test_i18n.lua
echo "=== test_main"
"$LUA" test_main.lua

if command -v luac5.1 >/dev/null 2>&1; then
    echo "=== syntax check (luac5.1, the interpreter that runs on the Kindle)"
    for f in "$PLUGIN"/*.lua; do
        luac5.1 -p "$f"
    done
    echo "OK"
fi

echo "ALL GREEN"
