#!/usr/bin/env bash
# Build task for the free compute broker.
# Runs against the TARGET repo (cwd is the checked-out target).
set -euo pipefail

echo "::group::Detect project type"
DETECTED="unknown"
if [ -f package.json ]; then
  DETECTED="node"
  PKG_MANAGER="npm"
  command -v bun >/dev/null 2>&1 && PKG_MANAGER="bun"
  [ -f bun.lockb ] || [ -f bun.lock ] && PKG_MANAGER="bun"
elif [ -f go.mod ]; then
  DETECTED="go"
elif [ -f Cargo.toml ]; then
  DETECTED="rust"
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  DETECTED="python"
elif [ -f Dockerfile ]; then
  DETECTED="docker"
fi
echo "Detected: $DETECTED"
echo "::endgroup::"

# Build tooling echoes file paths, dependency names and source excerpts on
# failure. This repo is PUBLIC, so task output is captured and only a
# summary is emitted. Set VERBOSE=1 locally (not in CI) to see the detail.
run_quiet() {
  local label="$1"; shift
  local log; log="$(mktemp)"
  if "$@" >"$log" 2>&1; then
    echo "$label: OK"
    rm -f "$log"; return 0
  fi
  echo "::error::$label failed (output suppressed; see job summary for details)"
  # Keep a bounded, redacted tail so a failure is still diagnosable without
  # dumping source. Absolute paths are stripped to basenames.
  echo "--- last lines of $label (paths stripped) ---"
  tail -20 "$log" | sed -E 's#(/[A-Za-z0-9._-]+)+/([A-Za-z0-9._-]+)#\2#g' || true
  echo "--- end ---"
  rm -f "$log"
  return 1
}

case "$DETECTED" in
  node)
    echo "::group::Install dependencies"
    if [ "$PKG_MANAGER" = "bun" ]; then
      run_quiet "bun install" bun install --frozen-lockfile
    else
      run_quiet "npm ci" npm ci
    fi
    echo "::endgroup::"
    echo "::group::Build"
    # Use the project's own script when it declares one.
    if [ -f package.json ] && grep -q '"build"[[:space:]]*:' package.json; then
      if [ "$PKG_MANAGER" = "bun" ]; then run_quiet "build" bun run build; else run_quiet "build" npm run build; fi
    else
      echo "No 'build' script in package.json; nothing to do."
    fi
    echo "::endgroup::"
    ;;
  go)
    echo "::group::Build"
    run_quiet "go build" go build ./...
    echo "::endgroup::"
    ;;
  rust)
    echo "::group::Build"
    run_quiet "cargo build" cargo build --release
    echo "::endgroup::"
    ;;
  python)
    echo "::group::Build"
    run_quiet "python compile" python -m compileall -q .
    echo "Python byte-compile OK"
    echo "::endgroup::"
    ;;
  docker)
    echo "::group::Build"
    run_quiet "docker build" docker build -t "free-compute-preview:${TARGET_REF//\//-}" .
    echo "::endgroup::"
    ;;
  *)
    echo "::warning::Could not detect a build system; treating as a no-op."
    ;;
esac

echo "Build task completed."