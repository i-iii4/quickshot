#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/QuickShot.app"
LOG_ROOT="$(mktemp -d -t quickshot-build-failure)"
trap 'rm -rf "$LOG_ROOT"' EXIT

if [ ! -d "$APP" ]; then
  echo "error: build QuickShot.app before running failure-preservation tests" >&2
  exit 1
fi

fingerprint() {
  find "$APP" -type f -print0 \
    | xargs -0 shasum -a 256 \
    | LC_ALL=C sort \
    | shasum -a 256 \
    | awk '{print $1}'
}

assert_preserved() {
  local label="$1"
  local before="$2"
  local after
  after="$(fingerprint)"
  if [ "$after" != "$before" ]; then
    echo "error: $label replaced the last valid app" >&2
    exit 1
  fi
}

BASELINE="$(fingerprint)"

if QUICKSHOT_TEST_FAIL_BEFORE_COMPILE=1 \
  "$ROOT/build.sh" >"$LOG_ROOT/compiler.log" 2>&1; then
  echo "error: injected compiler failure unexpectedly succeeded" >&2
  exit 1
fi
assert_preserved "compiler failure" "$BASELINE"

if QUICKSHOT_SIGN_IDENTITY="QuickShot Invalid Test Identity" \
  "$ROOT/build.sh" >"$LOG_ROOT/signing.log" 2>&1; then
  echo "error: invalid signing identity unexpectedly succeeded" >&2
  exit 1
fi
assert_preserved "signing failure" "$BASELINE"

if QUICKSHOT_TEST_FAIL_BEFORE_INSTALL=1 \
  "$ROOT/build.sh" >"$LOG_ROOT/install.log" 2>&1; then
  echo "error: injected installation failure unexpectedly succeeded" >&2
  exit 1
fi
assert_preserved "pre-install failure" "$BASELINE"

echo "BuildFailurePreservationTests: OK"
