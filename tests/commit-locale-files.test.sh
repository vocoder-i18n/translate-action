#!/usr/bin/env bash
# Proves scripts/commit-locale-files.sh's staging logic: what it does with
# $RUNNER_TEMP/vocoder-result.json before ever reaching commit-dispatch.sh.
#
# The script does not write locale files — @vocoder/cli does, and this script
# stages the paths the CLI reports. These tests therefore stand in for the
# CLI: they place files on disk themselves (see cli_wrote), then hand the
# script a result describing them. Runs the real script against a real scratch git
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
# Scoped to commit-locale-files.sh's own logic only (result parsing, staging,
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

# Stands in for @vocoder/cli, the only thing that writes locale files. Takes
# repo-relative path/content pairs.
cli_wrote() {
  while [ "$#" -gt 1 ]; do
    mkdir -p "$SCRATCH_REPO/$(dirname "$1")"
    printf '%s' "$2" > "$SCRATCH_REPO/$1"
    shift 2
  done
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

test_stages_the_paths_the_cli_reported_writing() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  cli_wrote "apps/web/locales/fr.json" '{"hello":"Bonjour"}'
  # A commit-mode nothing recognizes: commit-dispatch.sh refuses it and
  # exits 1 before ever committing, which freezes the staged state so it can
  # be inspected after the script (necessarily) exits non-zero.
  write_result_file '{"status":"complete","apps":[{"writtenPaths":["apps/web/locales/fr.json"],"commitConfig":{"commitMode":"not-a-real-mode"}}]}'

  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || true

  local result=0
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

# The headline bug. The CLI rewrites the server's locales/loader.js key into a
# typed locales/loader.ts and deletes the .js; this script used to re-create
# the .js from the tree and stage that key, so the loader.ts the app actually
# imports was never staged at all.
test_stages_loader_ts_and_never_the_loader_js_key() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  cli_wrote "locales/loader.ts" 'export async function loadLocale(locale: string) {}'
  write_result_file '{"status":"complete","apps":[{"localeFileTree":{"locales/loader.js":"export async function loadLocale(locale) {}"},"writtenPaths":["locales/loader.ts"],"commitConfig":{"commitMode":"not-a-real-mode"}}]}'

  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || true

  local result=0
  local staged
  staged="$(git -C "$SCRATCH_REPO" diff --staged --name-only)"
  if ! echo "$staged" | grep -qF "locales/loader.ts"; then
    echo "  expected locales/loader.ts to be staged, staged files were:"
    echo "$staged" | sed 's/^/    /'
    result=1
  fi
  if echo "$staged" | grep -qF "locales/loader.js"; then
    echo "  did not expect locales/loader.js to be staged, staged files were:"
    echo "$staged" | sed 's/^/    /'
    result=1
  fi
  if [ -e "$SCRATCH_REPO/locales/loader.js" ]; then
    echo "  did not expect the script to re-create locales/loader.js"
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

test_stages_the_deletion_of_a_superseded_loader_js() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  # A loader.js already committed, as it would be for a repo that has run an
  # older CLI, then removed from disk by this run's TypeScript rewrite.
  mkdir -p "$SCRATCH_REPO/locales"
  printf '%s' 'old js' > "$SCRATCH_REPO/locales/loader.js"
  git -C "$SCRATCH_REPO" add -A
  git -C "$SCRATCH_REPO" commit --quiet -m "committed loader.js"
  rm "$SCRATCH_REPO/locales/loader.js"

  cli_wrote "locales/loader.ts" 'export async function loadLocale(locale: string) {}'
  write_result_file '{"status":"complete","apps":[{"writtenPaths":["locales/loader.ts"],"removedPaths":["locales/loader.js"],"commitConfig":{"commitMode":"not-a-real-mode"}}]}'

  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || true

  local result=0
  local staged
  staged="$(git -C "$SCRATCH_REPO" diff --staged --name-status)"
  if ! echo "$staged" | grep -qE '^D[[:space:]]+locales/loader\.js'; then
    echo "  expected a staged deletion of locales/loader.js, staged changes were:"
    echo "$staged" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

# A removedPaths entry git never tracked must not fail the pathspec match and
# take the whole run down with it.
test_ignores_a_removed_path_git_never_tracked() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  cli_wrote "locales/fr.json" '{"hello":"Bonjour"}'
  write_result_file '{"status":"complete","apps":[{"writtenPaths":["locales/fr.json"],"removedPaths":["locales/never-existed.js"],"commitConfig":{"commitMode":"direct","skipCiOnDirectCommit":true}}]}'

  local exit_code=0
  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || exit_code=$?

  local result=0
  if [ "$exit_code" -ne 0 ]; then
    echo "  expected exit 0, got $exit_code"
    result=1
  fi
  if ! git -C "$BARE_REMOTE" log -1 --format=%B "$SCRATCH_BRANCH" >/dev/null 2>&1; then
    echo "  expected the direct push to have gone through"
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

# The old staging pipeline was `jq ... | xargs git add --`. xargs splits on
# whitespace and interprets quotes, so a spaced path failed the pathspec match
# and an apostrophe was an unterminated quote — while the write loop, which
# used `while IFS= read -r`, handled both fine. Staging is NUL-delimited now.
test_stages_paths_containing_spaces_and_quotes() {
  setup_scratch_repo
  local call_log apostrophe spaced_path quoted_path
  call_log="$(mktemp)"
  apostrophe="$(printf '\047')"
  spaced_path="my locales/fr.json"
  quoted_path="q/it${apostrophe}s.json"

  cli_wrote "$spaced_path" '{"hello":"Bonjour"}' "$quoted_path" '{"hi":"salut"}'
  write_result_file "$(jq -nc --arg a "$spaced_path" --arg b "$quoted_path" \
    '{status:"complete",apps:[{writtenPaths:[$a,$b],commitConfig:{commitMode:"not-a-real-mode"}}]}')"

  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || true

  local result=0
  local staged
  staged="$(git -C "$SCRATCH_REPO" diff --staged --name-only -z | tr '\0' '\n')"
  if ! printf '%s\n' "$staged" | grep -qxF "$spaced_path"; then
    echo "  expected a path with a space to be staged, staged files were:"
    printf '%s\n' "$staged" | sed 's/^/    /'
    result=1
  fi
  if ! printf '%s\n' "$staged" | grep -qxF "$quoted_path"; then
    echo "  expected a path with an apostrophe to be staged, staged files were:"
    printf '%s\n' "$staged" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

# Malformed JSON used to read as "nothing to do": the keys query ended in
# `2>/dev/null`, so the run exited 0 with a green check and no translations
# delivered, having already paid for them.
test_malformed_result_json_fails_loudly() {
  setup_scratch_repo
  local call_log stderr_file
  call_log="$(mktemp)"
  stderr_file="$(mktemp)"
  write_result_file '{"status":"complete","apps":[{'

  local exit_code=0
  run_sut "CALL_LOG=$call_log" >/dev/null 2>"$stderr_file" || exit_code=$?

  local result=0
  if [ "$exit_code" -eq 0 ]; then
    echo "  expected a non-zero exit, got 0"
    result=1
  fi
  if ! grep -qF "::error::" "$stderr_file"; then
    echo "  expected an ::error:: annotation on stderr, got:"
    sed 's/^/    /' "$stderr_file"
    result=1
  fi

  rm -f "$call_log" "$stderr_file"
  cleanup_scratch_repo
  return "$result"
}

# The CLI warns about locale files that are no longer a target. That warning
# was invisible in CI, so a dropped locale left its stale .json committed with
# nothing anywhere to say so.
test_orphaned_paths_surface_as_annotations() {
  setup_scratch_repo
  local call_log stdout_file
  call_log="$(mktemp)"
  stdout_file="$(mktemp)"

  cli_wrote "locales/fr.json" '{"hello":"Bonjour"}'
  write_result_file '{"status":"complete","orphanedPaths":["locales/de.json"],"apps":[{"writtenPaths":["locales/fr.json"],"commitConfig":{"commitMode":"not-a-real-mode"}}]}'

  run_sut "CALL_LOG=$call_log" >"$stdout_file" 2>&1 || true

  local result=0
  if ! grep -qF "::warning file=locales/de.json::" "$stdout_file"; then
    echo "  expected a ::warning:: annotation naming locales/de.json, got:"
    sed 's/^/    /' "$stdout_file"
    result=1
  fi

  rm -f "$call_log" "$stdout_file"
  cleanup_scratch_repo
  return "$result"
}

# A pinned older CLI produces a result with no writtenPaths. Staging the tree
# keys is the pre-existing behaviour, still correct for any project that is
# not TypeScript.
test_falls_back_to_tree_keys_when_written_paths_absent() {
  setup_scratch_repo
  local call_log
  call_log="$(mktemp)"

  cli_wrote "locales/fr.json" '{"hello":"Bonjour"}'
  write_result_file '{"status":"complete","apps":[{"localeFileTree":{"locales/fr.json":"{\"hello\":\"Bonjour\"}"},"commitConfig":{"commitMode":"not-a-real-mode"}}]}'

  run_sut "CALL_LOG=$call_log" >/dev/null 2>&1 || true

  local result=0
  local staged
  staged="$(git -C "$SCRATCH_REPO" diff --staged --name-only)"
  if ! echo "$staged" | grep -qF "locales/fr.json"; then
    echo "  expected locales/fr.json to be staged from the tree keys, staged files were:"
    echo "$staged" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log"
  cleanup_scratch_repo
  return "$result"
}

# If the CLI reports a path it did not write, the two halves disagree — the
# exact class of bug this rewrite removes. git would report it as an opaque
# "pathspec did not match"; name the path and say which half is wrong instead.
test_reports_a_written_path_that_is_not_on_disk() {
  setup_scratch_repo
  local call_log stderr_file
  call_log="$(mktemp)"
  stderr_file="$(mktemp)"

  write_result_file '{"status":"complete","apps":[{"writtenPaths":["locales/never-written.json"],"commitConfig":{"commitMode":"direct"}}]}'

  local exit_code=0
  run_sut "CALL_LOG=$call_log" >/dev/null 2>"$stderr_file" || exit_code=$?

  local result=0
  if [ "$exit_code" -eq 0 ]; then
    echo "  expected a non-zero exit, got 0"
    result=1
  fi
  if ! grep -qF "locales/never-written.json" "$stderr_file"; then
    echo "  expected the offending path to be named on stderr, got:"
    sed 's/^/    /' "$stderr_file"
    result=1
  fi
  local remote_refs
  remote_refs="$(git -C "$BARE_REMOTE" for-each-ref)"
  if [ -n "$remote_refs" ]; then
    echo "  expected nothing pushed, got refs:"
    echo "$remote_refs" | sed 's/^/    /'
    result=1
  fi

  rm -f "$call_log" "$stderr_file"
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
  write_result_file '{"status":"complete","apps":[{"writtenPaths":["apps/web/locales/fr.json"],"commitConfig":{"commitMode":"direct"}}]}'

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
  cli_wrote "apps/web/locales/ja.json" '{"hi":"konnichiwa"}'
  write_result_file '{"status":"complete","apps":[{"writtenPaths":["apps/web/locales/ja.json"],"commitConfig":{"commitMode":"direct","autoMergePRs":false,"skipCiOnDirectCommit":true}}]}'

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

  cli_wrote "apps/web/locales/de.json" '{"hi":"hallo"}'
  write_result_file '{"status":"complete","apps":[{"writtenPaths":["apps/web/locales/de.json"],"commitConfig":{"commitMode":"pr","autoMergePRs":true}}]}'

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
run_test "stages the paths the CLI reported writing" test_stages_the_paths_the_cli_reported_writing
run_test "stages loader.ts and never the loader.js key the server sent" test_stages_loader_ts_and_never_the_loader_js_key
run_test "stages the deletion of a loader.js superseded by loader.ts" test_stages_the_deletion_of_a_superseded_loader_js
run_test "ignores a removed path git never tracked instead of failing the run" test_ignores_a_removed_path_git_never_tracked
run_test "stages paths containing spaces and quotes" test_stages_paths_containing_spaces_and_quotes
run_test "a malformed result file fails loudly instead of reading as nothing to do" test_malformed_result_json_fails_loudly
run_test "orphaned locale files surface as CI annotations" test_orphaned_paths_surface_as_annotations
run_test "falls back to localeFileTree keys when an older CLI reported no writtenPaths" test_falls_back_to_tree_keys_when_written_paths_absent
run_test "fails loudly, naming the path, when the CLI reports a file it did not write" test_reports_a_written_path_that_is_not_on_disk
run_test "exits before dispatch when written content matches what is already committed" test_exits_before_dispatch_when_content_matches_what_is_already_committed
run_test "server-provided commitMode overrides the action's own commit-mode input" test_server_commit_mode_overrides_action_input
run_test "hands off to commit-dispatch.sh with the correct target branch, auto-merge, and skip-ci values" test_hands_off_to_dispatch_with_correct_branch_and_auto_merge

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
