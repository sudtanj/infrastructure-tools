#!/usr/bin/env bash
# Test task for the free compute broker.
# Runs against the TARGET repo (cwd is the checked-out target).
set -euo pipefail

echo "::group::Detect test runner"
HAS_TESTS=0
if [ -f package.json ] && grep -q '"test"[[:space:]]*:' package.json; then
  HAS_TESTS=1
  PKG_MANAGER="npm"
  command -v bun >/dev/null 2>&1 && PKG_MANAGER="bun"
  [ -f bun.lockb ] || [ -f bun.lock ] && PKG_MANAGER="bun"
elif [ -f go.mod ]; then
  HAS_TESTS=1
elif [ -f Cargo.toml ]; then
  HAS_TESTS=1
elif [ -f pytest.ini ] || [ -f pyproject.toml ]; then
  HAS_TESTS=1
fi
echo "Has tests: $HAS_TESTS"
echo "::endgroup::"

# Test output leaks test names and source paths on failure. This repo is
# PUBLIC, so output is captured; only a redacted summary is emitted.
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

if [ "$HAS_TESTS" -eq 0 ]; then
  echo "::warning::No test suite detected; nothing to run."
  exit 0
fi

case "${DETECTED:-auto}" in
  auto) : ;;
esac

if [ -f package.json ] && grep -q '"test"[[:space:]]*:' package.json; then
  echo "::group::Install dependencies"
  if [ "$PKG_MANAGER" = "bun" ]; then run_quiet "bun install" bun install --frozen-lockfile; else run_quiet "npm ci" npm ci; fi
  echo "::endgroup::"
  echo "::group::Test"
  if [ "$PKG_MANAGER" = "bun" ]; then run_quiet "test" bun run test; else run_quiet "test" npm test; fi
  echo "::endgroup::"
elif [ -f go.mod ]; then
  echo "::group::Test"
  run_quiet "go test" go test ./...
  echo "::endgroup::"
elif [ -f Cargo.toml ]; then
  echo "::group::Test"
  run_quiet "cargo test" cargo test
  echo "::endgroup::"
elif [ -f pytest.ini ] || [ -f pyproject.toml ]; then
  echo "::group::Test"
  run_quiet "pytest" python -m pytest -q
  echo "::endgroup::"
fi

echo "Test task completed."