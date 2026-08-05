#!/usr/bin/env bash
# Proves scripts/commit-locale-files.sh's file-write and staging logic: what
# it does with $RUNNER_TEMP/vocoder-result.json before ever reaching
# commit-dispatch.sh. Runs the real script against a real scratch git
# repository (mktemp -d && git init) because file-diff detection needs real
# git semantics that tests/fixtures/bin/git — which always exits 0 regardless
# of actual content — cannot provide.
#
# commit-locale-files.sh invokes commit-dispatch.sh via an absolute path next
# to its own location, so it can't be swapped out with a PATH-based fake:
# these tests genuinely reach real commit-dispatch.sh logic too. Its `git`
# calls run for real against a local bare "origin" remote (git init --bare),
# so direct-mode pushes are real but touch nothing but disk. Its `gh` calls
# are neutralized with a directory containing only a symlink to the existing
# tests/fixtures/bin/gh fixture, prepended to PATH — this shadows the real
# `gh` on this machine without shadowing real `git`.
#
# Scoped to commit-locale-files.sh's own logic only (file writes, staging,
# the unchanged-content short-circuit, and commit-mode/auto-merge/skip-ci
# precedence) — not commit-dispatch.sh's own PR-vs-direct decision, which is
# tests/commit-dispatch.test.sh's job.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SUT_SCRIPT="$REPO_ROOT/scripts/commit-locale-files.sh"

# A directory containing only a symlink to the existing gh fixture — used
# instead of the whole fixtures/bin directory so the fake `git` in that
# directory (which always exits 0 regardless of real content) never shadows
# the real `git` these tests depend on.
FAKE_GH_BIN_DIR="$(mktemp -d)"
ln -s "$TEST_DIR/fixtures/bin/gh" "$FAKE_GH_BIN_DIR/gh"
trap 'rm -rf "$FAKE_GH_BIN_DIR"' EXIT

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

# Sets SCRATCH_REPO, BARE_REMOTE, RESULT_DIR, SCRATCH_BRANCH as globals (not
# `local`) so each test function can use them after calling this helper.
# Every call uses fresh mktemp directories, so tests never share state.
setup_scratch_repo() {
  SCRATCH_REPO="$(mktemp -d)"
  BARE_REMOTE="$(mktemp -d)"
  RESULT_DIR="$(mktemp -d)"

  git init --quiet "$SCRATCH_REPO"
  git -C "$SCRATCH_REPO" config user.name "Vocoder Test"
  git -C "$SCRATCH_REPO" config user.email "vocoder-test@example.com"

  mkdir -p "$SCRATCH_REPO/locales"
  printf '%s' '{}' > "$SCRATCH_REPO/locales/en.json"
  git -C "$SCRATCH_REPO" add -A
  git -C "$SCRATCH_REPO" commit --quiet -m "initial commit"

  SCRATCH_BRANCH="$(git -C "$SCRATCH_REPO" rev-parse --abbrev-ref HEAD)"

  git init --quiet --bare "$BARE_REMOTE"
  git -C "$SCRATCH_REPO" remote add origin "$BARE_REMOTE"
}

cleanup_scratch_repo() {
  rm -rf "$SCRATCH_REPO" "$BARE_REMOTE" "$RESULT_DIR"
}

write_result_file() {
  printf '%s' "$1" > "$RESULT_DIR/vocoder-result.json"
}

# Runs the real script with cwd set to the scratch repo (its file writes and
# git commands are all relative to the checkout it's invoked from) and a
# fresh CALL_LOG for the faked `gh` to write to, plus whatever extra env
# assignments the caller passes (e.g. VOCODER_COMMIT_MODE, FAKE_GH_PR_COUNT).
run_sut() {
  (
    cd "$SCRATCH_REPO" &&
    RUNNER_TEMP="$RESULT_DIR" \
    GH_TOKEN="fake-token-for-tests" \
    PATH="$FAKE_GH_BIN_DIR:$PATH" \
      env "$@" "$SUT_SCRIPT"
  )
}

test_returns_early_when_no_result_file_exists() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"
  # deliberately not writing $RESULT_DIR/vocoder-result.json

  local exit_code=0
  run_sut "CALL_LOG=$call_log" >/dev/null || exit_code=$?

  local result=0
  if [ "$exit_code" -ne 0 ]; then
    echo "  expected exit 0, got $exit_code"
    result=1
  fi
  local status
  status="$(git -C "$SCRATCH_REPO" status --porcelain)"
  if [ -n "$status" ]; then
    echo "  expected a clean working tree, got:"
    echo "$status" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

test_returns_early_when_status_is_not_complete() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"
  write_result_file '{"status":"pending","apps":[]}'

  local exit_code=0
  run_sut "CALL_LOG=$call_log" >/dev/null || exit_code=$?

  local result=0
  if [ "$exit_code" -ne 0 ]; then
    echo "  expected exit 0, got $exit_code"
    result=1
  fi
  local status
  status="$(git -C "$SCRATCH_REPO" status --porcelain)"
  if [ -n "$status" ]; then
    echo "  expected a clean working tree, got:"
    echo "$status" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

test_writes_and_stages_every_file_in_locale_file_tree() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"
  # A commit-mode nothing recognizes: commit-dispatch.sh refuses it and
  # exits 1 before ever committing, which freezes the staged state so it can
  # be inspected after the script (necessarily) exits non-zero.
  write_result_file '{"status":"complete","apps":[{"localeFileTree":{"apps/web/locales/fr.json":"{\"hello\":\"Bonjour\"}"},"commitConfig":{"commitMode":"not-a-real-mode"}}]}'

  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || true

  local result=0
  local written_file="$SCRATCH_REPO/apps/web/locales/fr.json"
  local expected_content='{"hello":"Bonjour"}'
  if [ ! -f "$written_file" ]; then
    echo "  expected $written_file to exist"
    result=1
  else
    local actual_content
    actual_content="$(cat "$written_file")"
    if [ "$actual_content" != "$expected_content" ]; then
      echo "  expected content: $expected_content"
      echo "  actual content:   $actual_content"
      result=1
    fi
  fi

  local staged
  staged="$(git -C "$SCRATCH_REPO" diff --staged --name-only)"
  if ! echo "$staged" | grep -qF "apps/web/locales/fr.json"; then
    echo "  expected apps/web/locales/fr.json to be staged, staged files were:"
    echo "$staged" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

test_exits_before_dispatch_when_content_matches_what_is_already_committed() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  mkdir -p "$SCRATCH_REPO/apps/web/locales"
  printf '%s' '{"hello":"Bonjour"}' > "$SCRATCH_REPO/apps/web/locales/fr.json"
  git -C "$SCRATCH_REPO" add -A
  git -C "$SCRATCH_REPO" commit --quiet -m "pre-existing translation"

  # commitMode is valid ("direct") on purpose: if the unchanged-content
  # short-circuit failed to fire, this would actually try to push.
  write_result_file '{"status":"complete","apps":[{"localeFileTree":{"apps/web/locales/fr.json":"{\"hello\":\"Bonjour\"}"},"commitConfig":{"commitMode":"direct"}}]}'

  local exit_code=0
  run_sut "CALL_LOG=$call_log" >/dev/null || exit_code=$?

  local result=0
  if [ "$exit_code" -ne 0 ]; then
    echo "  expected exit 0, got $exit_code"
    result=1
  fi

  local remote_refs
  remote_refs="$(git -C "$BARE_REMOTE" for-each-ref)"
  if [ -n "$remote_refs" ]; then
    echo "  expected no push to the bare remote, got refs:"
    echo "$remote_refs" | sed 's/^/    /'
    result=1
  fi

  if [ -s "$call_log" ]; then
    echo "  expected no gh invocation, got:"
    sed 's/^/    /' "$call_log"
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

test_server_commit_mode_overrides_action_input() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  # Server says "direct" with a [skip ci] trailer; the action's own input
  # (VOCODER_COMMIT_MODE) says the opposite ("pr") — the server value must win.
  write_result_file '{"status":"complete","apps":[{"localeFileTree":{"apps/web/locales/ja.json":"{\"hi\":\"konnichiwa\"}"},"commitConfig":{"commitMode":"direct","autoMergePRs":false,"skipCiOnDirectCommit":true}}]}'

  run_sut "CALL_LOG=$call_log" "VOCODER_COMMIT_MODE=pr" >/dev/null

  local result=0
  local remote_commit_msg
  if ! remote_commit_msg="$(git -C "$BARE_REMOTE" log -1 --format=%B "$SCRATCH_BRANCH" 2>/dev/null)"; then
    echo "  expected the bare remote to have received a direct push to $SCRATCH_BRANCH"
    result=1
  else
    if ! echo "$remote_commit_msg" | grep -q "chore(i18n): update translations"; then
      echo "  expected the pushed commit message to contain the standard subject, got:"
      echo "$remote_commit_msg" | sed 's/^/    /'
      result=1
    fi
    if ! echo "$remote_commit_msg" | grep -q "\[skip ci\]"; then
      echo "  expected the pushed commit message to contain a [skip ci] trailer, got:"
      echo "$remote_commit_msg" | sed 's/^/    /'
      result=1
    fi
  fi

  assert_not_contains "gh pr create" "$call_log" || result=1

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

test_hands_off_to_dispatch_with_correct_branch_and_auto_merge() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  write_result_file '{"status":"complete","apps":[{"localeFileTree":{"apps/web/locales/de.json":"{\"hi\":\"hallo\"}"},"commitConfig":{"commitMode":"pr","autoMergePRs":true}}]}'

  run_sut "CALL_LOG=$call_log" "FAKE_GH_PR_COUNT=0" >/dev/null

  local result=0
  local pr_branch="vocoder/translate-$SCRATCH_BRANCH"

  assert_contains "gh pr create" "$call_log" || result=1
  assert_contains "--base $SCRATCH_BRANCH" "$call_log" || result=1
  assert_contains "--head $pr_branch" "$call_log" || result=1
  assert_contains "gh pr merge $pr_branch --auto" "$call_log" || result=1

  if ! git -C "$BARE_REMOTE" show-ref --verify --quiet "refs/heads/$pr_branch"; then
    echo "  expected the bare remote to have a $pr_branch ref"
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

run_test "returns early when no result file exists" test_returns_early_when_no_result_file_exists
run_test "returns early when status is not complete" test_returns_early_when_status_is_not_complete
run_test "writes every file in localeFileTree at its exact path with exact content and stages it via git add" test_writes_and_stages_every_file_in_locale_file_tree
run_test "exits before dispatch when written content matches what is already committed" test_exits_before_dispatch_when_content_matches_what_is_already_committed
run_test "server-provided commitMode overrides the action's own commit-mode input" test_server_commit_mode_overrides_action_input
run_test "hands off to commit-dispatch.sh with the correct target branch, auto-merge, and skip-ci values" test_hands_off_to_dispatch_with_correct_branch_and_auto_merge

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
