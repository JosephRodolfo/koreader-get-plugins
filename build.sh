#!/usr/bin/env bash
# Bundle the plugin into a .koplugin archive that leaf-casa can relay.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p dist
rm -f dist/getplugins.koplugin

# Archive the *contents* of the plugin folder so main.lua and _meta.lua are at
# the archive root. The Get Plugins client wraps them into getplugins.koplugin/.
( cd getplugins.koplugin && zip -r -X -q ../dist/getplugins.koplugin . )

echo "Built dist/getplugins.koplugin"
