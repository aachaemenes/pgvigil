#!/usr/bin/env bash
# TAGTREE's draw() timing (scripts/tree-timing-entry.ts): the entry bundled with web/'s own esbuild, opened in headless
# Chromium from a file, its <pre id="out"> printed. Needs web/node_modules (npm ci in web/) and chromium.
# usage: bash scripts/tree-timing.sh
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
web/node_modules/.bin/esbuild scripts/tree-timing-entry.ts --bundle --format=iife --log-level=warning --outfile="$W/t.js"
# an error thrown in the page (a module's top-level code, mountTree) is written into the result, which then fails
printf '<!doctype html><html><head><meta charset="utf-8"></head><body><div id="tree"></div><pre id="out">no result</pre><script>window.onerror = function (m) { document.getElementById("out").textContent = "ERROR " + m; };</script><script src="t.js"></script></body></html>' > "$W/t.html"
R=$(chromium --headless=new --disable-gpu --no-first-run --user-data-dir="$W/chrome" --window-size=1500,1000 --dump-dom "file://$W/t.html" 2>/dev/null \
  | python3 -c 'import sys, re, html; m = re.search(r"<pre id=\"out\">(.*?)</pre>", sys.stdin.read(), re.S); print(html.unescape(m.group(1)) if m else "no <pre id=out> in the page")')
echo "$R"
[[ $R == shape\ * ]] || { echo "FAIL: the timing gave no result"; exit 1; }
