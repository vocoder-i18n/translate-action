#!/usr/bin/env bash
# Reads the Vocoder CLI's translate result from $RUNNER_TEMP/vocoder-result.json,
# writes any translated locale files it contains, stages them, and delivers
# them via commit-dispatch.sh using the commit mode the server selected
# (falling back to this action's own `commit-mode` input via
# $VOCODER_COMMIT_MODE, then to "pr", when the server did not specify one).
#
# Requires `git`, `gh`, and `jq` on PATH, and a GH_TOKEN with permission to
# push and open pull requests against the current repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_FILE="${RUNNER_TEMP}/vocoder-result.json"

if [ ! -f "$RESULT_FILE" ]; then
  echo "No translate result file — skipping commit (branch not targeted or dry run)"
  exit 0
fi

STATUS=$(jq -r '.status // "unknown"' "$RESULT_FILE")
if [ "$STATUS" != "complete" ]; then
  echo "Translation status: $STATUS — skipping commit"
  exit 0
fi

# Write all locale files from the result tree
WROTE_FILES=0
while IFS= read -r FILE_PATH; do
  CONTENT=$(jq -r --arg p "$FILE_PATH" \
    '[.apps[] | .localeFileTree // {} | .[$p]] | map(select(. != null)) | first // empty' \
    "$RESULT_FILE")
  if [ -n "$CONTENT" ]; then
    mkdir -p "$(dirname "$FILE_PATH")"
    printf '%s' "$CONTENT" > "$FILE_PATH"
    WROTE_FILES=$((WROTE_FILES + 1))
  fi
done < <(jq -r '[.apps[] | .localeFileTree // {} | keys[]] | unique[]' "$RESULT_FILE" 2>/dev/null)

if [ "$WROTE_FILES" -eq 0 ]; then
  echo "No locale files in result — skipping commit"
  exit 0
fi

# Stage locale files
jq -r '[.apps[] | .localeFileTree // {} | keys[]] | unique[]' "$RESULT_FILE" | \
  xargs git add --

if git diff --staged --quiet; then
  echo "Locale files unchanged — nothing to commit"
  exit 0
fi

git config user.name "vocoder-bot[bot]"
git config user.email "vocoder-bot[bot]@users.noreply.github.com"

# Server-returned commitMode takes precedence over the action input
COMMIT_MODE=$(jq -r \
  '[.apps[] | .commitConfig.commitMode | select(. != null)] | first // empty' \
  "$RESULT_FILE")
COMMIT_MODE="${COMMIT_MODE:-${VOCODER_COMMIT_MODE:-pr}}"

AUTO_MERGE=$(jq -r \
  '[.apps[] | .commitConfig.autoMergePRs | select(. != null)] | first // false' \
  "$RESULT_FILE")
SKIP_CI=$(jq -r \
  '[.apps[] | .commitConfig.skipCiOnDirectCommit | select(. != null)] | first // true' \
  "$RESULT_FILE")

TARGET_BRANCH=$(git rev-parse --abbrev-ref HEAD)

COMMIT_MODE="$COMMIT_MODE" \
TARGET_BRANCH="$TARGET_BRANCH" \
SKIP_CI="$SKIP_CI" \
AUTO_MERGE="$AUTO_MERGE" \
  "$SCRIPT_DIR/commit-dispatch.sh"
