#!/usr/bin/env bash
# Stages the locale files the Vocoder CLI wrote and delivers them via
# commit-dispatch.sh, using the commit mode the server selected (falling back
# to this action's own `commit-mode` input via $VOCODER_COMMIT_MODE, then to
# "pr", when the server did not specify one).
#
# This script does not write locale files. The CLI is the only writer: it
# applies the server's tree, and for TypeScript projects it turns the server's
# `locales/loader.js` key into a typed `locales/loader.ts` and deletes the
# `.js`. Re-deriving paths from `localeFileTree` here would stage the request
# rather than the result — which is exactly how every TypeScript repository
# ended up committing an untyped loader.js while the loader.ts its app imports
# went unstaged. $RUNNER_TEMP/vocoder-result.json reports `writtenPaths` and
# `removedPaths` per app; those are staged verbatim.
#
# Requires `git`, `gh`, and `jq` on PATH, and a GH_TOKEN with permission to
# push and open pull requests against the current repository.
set -euo pipefail

# `set -e` exits silently on the failing command, which in a composite action
# surfaces as a red step with whatever the last tool happened to print. Name
# the script and line so a failure is attributable without re-running with
# bash -x.
trap 'status=$?; [ "$status" -ne 0 ] && echo "::error::${BASH_SOURCE[0]}: failed at line ${LINENO}: ${BASH_COMMAND} (exit $status)" >&2; exit $status' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_FILE="${RUNNER_TEMP}/vocoder-result.json"

if [ ! -f "$RESULT_FILE" ]; then
  echo "No translate result file — skipping commit (branch not targeted or dry run)"
  exit 0
fi

# A result file that does not parse is a broken run, not an empty one. Reading
# it as "nothing to do" would end the job with a green check and no
# translations delivered.
if ! jq -e 'type == "object"' "$RESULT_FILE" >/dev/null 2>&1; then
  echo "::error::$RESULT_FILE is not valid JSON — the translate step wrote a malformed result. Refusing to treat this as an empty result." >&2
  exit 1
fi

STATUS=$(jq -r '.status // "unknown"' "$RESULT_FILE")
if [ "$STATUS" != "complete" ]; then
  echo "Translation status: $STATUS — skipping commit"
  exit 0
fi

# Locale files the CLI could not account for: present on disk, no longer a
# target. Surfaced rather than deleted — the same test also matches a file a
# developer added by hand, and `vocoder clean` is the deliberate way to remove
# them. Without this the CLI's warning is invisible in CI.
while IFS= read -r ORPHAN; do
  [ -n "$ORPHAN" ] || continue
  echo "::warning file=${ORPHAN}::${ORPHAN} is not in the project's target locales. Run 'vocoder clean' locally to remove it."
done < <(jq -r '.orphanedPaths // [] | .[]' "$RESULT_FILE")

# Paths the CLI wrote, NUL-delimited so a path containing a space, a quote or
# a newline survives — the previous `xargs git add` split on whitespace and
# interpreted quotes, so `my locales/fr.json` failed the pathspec match and
# `q/it's.json` was an unterminated quote.
#
# `writtenPaths` is absent only when an older pinned CLI produced the result;
# falling back to the tree keys stages the same files for every project except
# a TypeScript one, which is the pre-existing behaviour rather than a new
# failure.
written_paths_nul() {
  jq -j '
    if any(.apps[]?; has("writtenPaths"))
    then [.apps[]? | .writtenPaths // [] | .[]]
    else [.apps[]? | .localeFileTree // {} | keys[]]
    end
    | unique | .[] | . + "\u0000"
  ' "$RESULT_FILE"
}

# Paths the CLI deleted — a loader.js superseded by loader.ts. Only those git
# already tracks are staged: `git add` on a path that is neither on disk nor in
# the index fails the pathspec match, and under `set -e` that would take the
# whole run with it.
removed_tracked_paths_nul() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      printf '%s\0' "$path"
    fi
  done < <(jq -r '[.apps[]? | .removedPaths // [] | .[]] | unique | .[]' "$RESULT_FILE")
}

STAGE_LIST="$(mktemp)"
trap 'rm -f "$STAGE_LIST"' EXIT

written_paths_nul > "$STAGE_LIST"

# A reported path that is not on disk means the CLI and this script disagree
# about what happened — the exact failure this script was rewritten to remove.
# `git add` would report it as an opaque "pathspec did not match" and, under
# `set -e`, take the run down with no indication of which half was wrong.
MISSING=""
while IFS= read -r -d '' STAGED_PATH; do
  [ -e "$STAGED_PATH" ] || MISSING="${MISSING}  ${STAGED_PATH}"$'\n'
done < "$STAGE_LIST"

if [ -n "$MISSING" ]; then
  echo "::error::The translate step reported locale files that are not on disk. This is a bug in @vocoder/cli, not in your repository — please report it." >&2
  printf '%s' "$MISSING" >&2
  exit 1
fi

removed_tracked_paths_nul >> "$STAGE_LIST"

if [ ! -s "$STAGE_LIST" ]; then
  echo "No locale files in result — skipping commit"
  exit 0
fi

# -A so a reported deletion stages as a deletion rather than being ignored.
git add -A --pathspec-from-file="$STAGE_LIST" --pathspec-file-nul

if git diff --staged --quiet; then
  echo "Locale files unchanged — nothing to commit"
  exit 0
fi

git config user.name "vocoder-bot[bot]"
git config user.email "vocoder-bot[bot]@users.noreply.github.com"

# Returns the one value every app agrees on for a commitConfig field, or the
# given default when no app set it.
#
# Delivery is a single git operation over the whole staged tree, so there is
# exactly one commit mode available per run. Taking the first app's value —
# which is what `| first` did — silently delivered every app in a monorepo the
# way whichever app happened to sort first wanted, even though commitMode is
# per-app in the schema. Disagreement is refused rather than guessed at.
agreed_commit_config() {
  local field="$1" default="$2" values count
  values=$(jq -r --arg f "$field" \
    '[.apps[]? | .commitConfig[$f] | select(. != null) | tostring] | unique | .[]' \
    "$RESULT_FILE")
  if [ -z "$values" ]; then
    printf '%s' "$default"
    return 0
  fi
  count=$(printf '%s\n' "$values" | wc -l | tr -d ' ')
  if [ "$count" -gt 1 ]; then
    echo "::error::Apps in this repository disagree about ${field}: $(printf '%s' "$values" | tr '\n' ' '). A single workflow run delivers every app in one commit, so it cannot honour both. Give the apps the same setting, or run them from separate workflows with their own app-dir." >&2
    return 1
  fi
  printf '%s' "$values"
}

# Server-returned commitMode takes precedence over the action input
COMMIT_MODE=$(agreed_commit_config commitMode "")
COMMIT_MODE="${COMMIT_MODE:-${VOCODER_COMMIT_MODE:-pr}}"

AUTO_MERGE=$(agreed_commit_config autoMergePRs false)
SKIP_CI=$(agreed_commit_config skipCiOnDirectCommit true)

# `git rev-parse --abbrev-ref HEAD` returns the literal string "HEAD" whenever
# the checkout is detached, which is the normal state for pull_request events,
# tag pushes and `with: ref: <sha>`. Direct mode then pushed to the unusable
# refspec "HEAD:HEAD"; PR mode was worse, creating and force-pushing a branch
# literally named vocoder/translate-HEAD into the repository before failing at
# `gh pr create --base HEAD`. The runner knows the real branch, so the action
# passes it in.
TARGET_BRANCH="${VOCODER_TARGET_BRANCH:-}"
if [ -z "$TARGET_BRANCH" ]; then
  TARGET_BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi
if [ "$TARGET_BRANCH" = "HEAD" ] || [ -z "$TARGET_BRANCH" ]; then
  echo "::error::Could not determine the branch to deliver translations to — the checkout is detached and no branch name was supplied. Nothing was pushed. If you are running this action outside a normal push or pull_request event, set the VOCODER_TARGET_BRANCH environment variable on the step." >&2
  exit 1
fi

COMMIT_MODE="$COMMIT_MODE" \
TARGET_BRANCH="$TARGET_BRANCH" \
SKIP_CI="$SKIP_CI" \
AUTO_MERGE="$AUTO_MERGE" \
  "$SCRIPT_DIR/commit-dispatch.sh"
