#!/usr/bin/env bash
# Lint task for the free compute broker.
# Runs against the TARGET repo (cwd is the checked-out target).
set -euo pipefail

echo "::group::Detect linter"
FOUND=0
if [ -f package.json ] && grep -q '"lint"[[:space:]]*:' package.json; then
  FOUND=1
  PKG_MANAGER="npm"
  command -v bun >/dev/null 2>&1 && PKG_MANAGER="bun"
  [ -f bun.lockb ] || [ -f bun.lock ] && PKG_MANAGER="bun"
elif [ -f .golangci.yml ] || [ -f .golangci.yaml ]; then
  FOUND=1
elif [ -f Cargo.toml ]; then
  FOUND=1
elif [ -f .shellcheckrc ]; then
  FOUND=1
fi
echo "Has linter: $FOUND"
echo "::endgroup::"

# Linter output quotes source lines and file paths. This repo is PUBLIC,
# so capture it and emit only a summary.
run_quiet() {
  local label="$1"; shift
  local log; log="$(mktemp)"
  if "$@" >"$log" 2>&1; then
    echo "$label: OK"
    rm -f "$log"; return 0
  fi
  echo "::error::$label failed (output suppressed to protect private source)"
  echo "--- last lines of $label (paths stripped) ---"
  tail -20 "$log" | sed -E 's#(/[A-Za-z0-9._-]+)+/([A-Za-z0-9._-]+)#\2#g' || true
  echo "--- end ---"
  rm -f "$log"
  return 1
}

if [ "$FOUND" -eq 0 ]; then
  echo "::warning::No linter detected; nothing to run."
  exit 0
fi

if [ -f package.json ] && grep -q '"lint"[[:space:]]*:' package.json; then
  echo "::group::Install dependencies"
  if [ "$PKG_MANAGER" = "bun" ]; then run_quiet "bun install" bun install --frozen-lockfile; else run_quiet "npm ci" npm ci; fi
  echo "::endgroup::"
  echo "::group::Lint"
  if [ "$PKG_MANAGER" = "bun" ]; then run_quiet "lint" bun run lint; else run_quiet "lint" npm run lint; fi
  echo "::endgroup::"
elif [ -f .golangci.yml ] || [ -f .golangci.yaml ]; then
  echo "::group::Lint"
  run_quiet "golangci-lint" golangci-lint run
  echo "::endgroup::"
elif [ -f Cargo.toml ]; then
  echo "::group::Lint"
  run_quiet "cargo clippy" cargo clippy -- -D warnings
  echo "::endgroup::"
elif [ -f .shellcheckrc ]; then
  echo "::group::Lint"
  # shellcheck prints offending FILE PATHS and SOURCE LINES on failure.
  # That is private source going into a public log, so capture it and emit
  # only a count. Re-running with -f gcc lets us count without echoing.
  if find . -name '*.sh' -not -path './.git/*' -print0 \
       | xargs -0 -r shellcheck -f gcc > /tmp/lint.out 2>&1; then
    echo "shellcheck: clean"
  else
    COUNT=$(grep -c . /tmp/lint.out || true)
    echo "::error::shellcheck found ${COUNT} issue(s) in shell scripts."
    echo "Issue details are suppressed to avoid exposing private paths and source."
    echo "Run shellcheck locally to see them."
    exit 1
  fi
  rm -f /tmp/lint.out
  echo "::endgroup::"
fi

echo "Lint task completed."