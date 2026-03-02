#!/usr/bin/env bash
# patch-copilot.sh — Neuter undici assert() calls in the GitHub Copilot CLI
# bundle that cause AssertionError crashes on Node.js v25+.
#
# The bundled undici imports Node's assert module and sprinkles invariant
# checks throughout the connection pool / HTTP client code.  On Node v25 the
# built-in undici changed internal state semantics, causing these assertions
# to fire on long-lived sessions (see github/copilot-cli#1754).
#
# Strategy: find every `var NAME=require("assert")` (or `require("node:assert")`)
# that lives inside an undici module and replace it with a no-op function.
# This is safe because these are debug invariants, not control flow, and
# Node's own undici ships without them.
#
# Usage:
#   ./scripts/patch-copilot.sh            # auto-detect install path
#   ./scripts/patch-copilot.sh /path/to/@github/copilot

set -euo pipefail

# ── Locate the copilot package ────────────────────────────────────────────────
find_package_dir() {
  local npm_root
  npm_root="$(npm root -g 2>/dev/null || true)"
  if [[ -f "$npm_root/@github/copilot/index.js" ]]; then
    echo "$npm_root/@github/copilot"
    return
  fi

  while IFS= read -r bin; do
    local resolved dir
    resolved="$(readlink -f "$bin" 2>/dev/null || true)"
    dir="$(dirname "$resolved")"
    if [[ -f "$dir/index.js" ]]; then
      echo "$dir"
      return
    fi
  done < <(command -v -a copilot 2>/dev/null || true)
}

if [[ $# -ge 1 ]]; then
  COPILOT_DIR="$1"
else
  COPILOT_DIR="$(find_package_dir)"
  if [[ -z "$COPILOT_DIR" ]]; then
    echo "❌  Could not locate the @github/copilot npm package." >&2
    echo "    Pass the package directory explicitly: $0 /path/to/@github/copilot" >&2
    exit 1
  fi
fi

if [[ ! -d "$COPILOT_DIR" ]]; then
  echo "❌  Directory not found: $COPILOT_DIR" >&2
  exit 1
fi

echo "📦  Copilot package: $COPILOT_DIR"

# ── Patch a single JS bundle file ────────────────────────────────────────────
patch_bundle() {
  local file="$1"
  local label
  label="$(basename "$(dirname "$file")")/$(basename "$file")"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  if grep -q '__UNDICI_ASSERT_PATCH__' "$file" 2>/dev/null; then
    echo "  ✅  $label — already patched"
    return 0
  fi

  # Backup
  local backup="${file}.bak"
  if [[ ! -f "$backup" ]]; then
    cp "$file" "$backup"
    echo "  💾  Backup: $backup"
  fi

  local tmp
  tmp="$(mktemp --suffix=.js)"
  cp "$file" "$tmp"

  # Apply patch: replace undici assert imports with no-ops
  local patched
  patched=$(python3 - "$tmp" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Detect which require alias this bundle uses (ve or z)
# by checking which one appears with "node:assert"
req_fn = None
for candidate in ['ve', 'z']:
    if f'{candidate}("node:assert")' in content or f'{candidate}("assert")' in content:
        req_fn = candidate
        break
if req_fn is None:
    print(0)
    sys.exit(0)

# Undici keyword fingerprints — if any appear within 2000 chars of the
# assert import, we know it belongs to undici (not some other module).
UNDICI_KEYWORDS = [
    'kRunning', 'kPending', 'kSize', 'kBusy', 'kConnected', 'kFree',
    'kUrl', 'kClose', 'kDestroy', 'kDispatch', 'kNeedDrain',
    'kKeepAliveTimeout', 'kSocket', 'kClient', 'kHeadersList',
    'kDestroyed', 'kBodyUsed',
]

# Match:  var NAME=REQFN("assert")  or  var NAME=REQFN("node:assert")
pattern = re.compile(
    r'var (\w+)=' + re.escape(req_fn) + r'\("(?:node:)?assert"\)'
)

total = 0
# Process from end to start so offsets stay valid
for m in reversed(list(pattern.finditer(content))):
    name = m.group(1)
    pos = m.start()
    ctx = content[pos:pos+2000]
    if any(kw in ctx for kw in UNDICI_KEYWORDS):
        # Replace:  var NAME=require("assert")
        # With:     var NAME=()=>{}             (no-op function, same var binding)
        replacement = f'var {name}=()=>{{}}'
        content = content[:m.start()] + replacement + content[m.end():]
        total += 1

with open(path, 'w') as f:
    f.write(content)
print(total)
PYEOF
)

  if [[ "$patched" -eq 0 ]]; then
    echo "  ⚠️   $label — no undici assert imports found (already clean or different build)"
    rm -f "$tmp"
    return 0
  fi

  echo "  🔍  $label — neutered $patched undici assert import(s)"

  echo "" >> "$tmp"
  echo "// __UNDICI_ASSERT_PATCH__" >> "$tmp"

  # Syntax check
  if ! node --check "$tmp" 2>/dev/null; then
    echo "  ❌  $label — syntax check failed, restoring backup" >&2
    cp "$backup" "$file"
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$file"
  echo "  ✅  $label — patched successfully"
}

# ── Patch all known bundle files ─────────────────────────────────────────────
ERRORS=0
patch_bundle "$COPILOT_DIR/index.js"     || ERRORS=$((ERRORS + 1))
patch_bundle "$COPILOT_DIR/sdk/index.js" || ERRORS=$((ERRORS + 1))

if [[ "$ERRORS" -gt 0 ]]; then
  echo ""
  echo "❌  $ERRORS bundle(s) failed to patch." >&2
  exit 1
fi

echo ""
echo "✅  All bundles patched successfully."
