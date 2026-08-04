#!/usr/bin/env bash
# Proves scripts/commit-dispatch.sh's direct-vs-PR dispatch decision: given a
# commit-mode value, does it push directly or open a pull request. Runs the
# real dispatch script against fake `git`/`gh` executables on PATH (see
# fixtures/bin) that record every invocation instead of touching a real
# repository or GitHub — so these tests catch drift in the actual script, not
# a reimplementation of it.
#
# This is deliberately scoped to the direct-vs-PR dispatch decision only —
# not branch/push mechanics, `on-failure` handling, or anything else in
# action.yml. Broader coverage of this repo's bash logic is VOC-35's
# responsibility.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
DISPATCH_SCRIPT="$REPO_ROOT/scripts/commit-dispatch.sh"
FAKE_BIN="$TEST_DIR/fixtures/bin"

PASS=0
FAIL=0

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  if ! grep -qF -- "$needle" "$haystack_file"; then
    echo "  expected a line containing: $needle"
    echo "  actual contents of $haystack_file:"
    sed 's/^/    /' "$haystack_file"
    return 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack_file="$2"
  if grep -qF -- "$needle" "$haystack_file"; then
    echo "  did not expect a line containing: $needle"
    echo "  actual contents of $haystack_file:"
    sed 's/^/    /' "$haystack_file"
    return 1
  fi
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

test_direct_mode_pushes_without_opening_pr() {
  local call_log
  call_log="$(mktemp)"

  PATH="$FAKE_BIN:$PATH" \
  CALL_LOG="$call_log" \
  COMMIT_MODE="DIRECT" \
  TARGET_BRANCH="main" \
  SKIP_CI="true" \
  AUTO_MERGE="false" \
    "$DISPATCH_SCRIPT" >/dev/null

  assert_contains "git push origin HEAD:main" "$call_log" &&
  assert_not_contains "gh pr create" "$call_log" &&
  assert_not_contains "gh pr list" "$call_log"
  local result=$?
  rm -f "$call_log"
  return "$result"
}

test_pr_mode_opens_pr_and_never_pushes_direct() {
  local call_log
  call_log="$(mktemp)"

  PATH="$FAKE_BIN:$PATH" \
  CALL_LOG="$call_log" \
  COMMIT_MODE="PR" \
  TARGET_BRANCH="main" \
  SKIP_CI="true" \
  AUTO_MERGE="false" \
  FAKE_GH_PR_COUNT="0" \
    "$DISPATCH_SCRIPT" >/dev/null

  assert_contains "git checkout -B vocoder/translate-main" "$call_log" &&
  assert_contains "git push origin vocoder/translate-main --force" "$call_log" &&
  assert_contains "gh pr create" "$call_log" &&
  assert_not_contains "git push origin HEAD:main" "$call_log"
  local result=$?
  rm -f "$call_log"
  return "$result"
}

test_pr_mode_is_case_insensitive() {
  local call_log
  call_log="$(mktemp)"

  PATH="$FAKE_BIN:$PATH" \
  CALL_LOG="$call_log" \
  COMMIT_MODE="pr" \
  TARGET_BRANCH="main" \
  SKIP_CI="true" \
  AUTO_MERGE="false" \
  FAKE_GH_PR_COUNT="0" \
    "$DISPATCH_SCRIPT" >/dev/null

  assert_contains "gh pr create" "$call_log"
  local result=$?
  rm -f "$call_log"
  return "$result"
}

test_unrecognized_mode_fails_loudly_and_never_dispatches() {
  local call_log stderr_file exit_code
  call_log="$(mktemp)"
  stderr_file="$(mktemp)"
  exit_code=0

  PATH="$FAKE_BIN:$PATH" \
  CALL_LOG="$call_log" \
  COMMIT_MODE="COMMIT" \
  TARGET_BRANCH="main" \
  SKIP_CI="true" \
  AUTO_MERGE="false" \
    "$DISPATCH_SCRIPT" >/dev/null 2>"$stderr_file" || exit_code=$?

  local result=0
  if [ "$exit_code" -eq 0 ]; then
    echo "  expected a non-zero exit code for an unrecognized commit-mode"
    result=1
  fi
  grep -qi "unrecognized" "$stderr_file" || {
    echo "  expected stderr to explain the mode was unrecognized, got:"
    sed 's/^/    /' "$stderr_file"
    result=1
  }
  if [ -s "$call_log" ]; then
    echo "  expected no git or gh invocation, got:"
    sed 's/^/    /' "$call_log"
    result=1
  fi

  rm -f "$call_log" "$stderr_file"
  return "$result"
}

run_test "commit-mode DIRECT pushes directly, never opens a PR" test_direct_mode_pushes_without_opening_pr
run_test "commit-mode PR opens a pull request, never pushes directly" test_pr_mode_opens_pr_and_never_pushes_direct
run_test "commit-mode pr (lowercase) still opens a pull request" test_pr_mode_is_case_insensitive
run_test "an unrecognized commit-mode fails loudly instead of falling through to PR mode" test_unrecognized_mode_fails_loudly_and_never_dispatches

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
