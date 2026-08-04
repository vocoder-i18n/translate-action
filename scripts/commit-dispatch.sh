#!/usr/bin/env bash
# Delivers already-staged translation changes via the commit mode named by
# $COMMIT_MODE: a direct push to $TARGET_BRANCH for "direct", or a pull
# request against $TARGET_BRANCH for "pr". Matching is case-insensitive. Any
# other value is refused outright — it is never treated as "pr" by default,
# since guessing at an unrecognized delivery mode would silently deliver
# translations in a way nobody asked for.
#
# Required environment:
#   COMMIT_MODE      "pr" or "direct" (case-insensitive)
#   TARGET_BRANCH    branch to push to directly, or to base a pull request on
#   SKIP_CI           "true" appends a [skip ci] trailer to the direct-push commit
#   AUTO_MERGE        "true" enables auto-merge on the created pull request
#
# Assumes the caller already staged the changes to commit. Requires `git` and
# `gh` on PATH, and (for PR mode) a GH_TOKEN with permission to push and open
# pull requests against the current repository.
set -euo pipefail

COMMIT_MESSAGE="chore(i18n): update translations"
COMMIT_MODE_NORMALIZED="$(printf '%s' "$COMMIT_MODE" | tr '[:lower:]' '[:upper:]')"

case "$COMMIT_MODE_NORMALIZED" in
  DIRECT)
    if [ "$SKIP_CI" = "true" ]; then
      git commit -m "$COMMIT_MESSAGE" -m "[skip ci]"
    else
      git commit -m "$COMMIT_MESSAGE"
    fi
    git push origin "HEAD:$TARGET_BRANCH"
    ;;

  PR)
    PR_BRANCH="vocoder/translate-$TARGET_BRANCH"
    # -B creates the branch or resets it to current HEAD (staged changes travel with us)
    git checkout -B "$PR_BRANCH"
    git commit -m "$COMMIT_MESSAGE"
    git push origin "$PR_BRANCH" --force

    PR_COUNT=$(gh pr list \
      --head "$PR_BRANCH" \
      --base "$TARGET_BRANCH" \
      --json number \
      --jq 'length')
    if [ "$PR_COUNT" = "0" ]; then
      gh pr create \
        --title "$COMMIT_MESSAGE" \
        --body "Automated translation update by [Vocoder](https://vocoder.app)." \
        --base "$TARGET_BRANCH" \
        --head "$PR_BRANCH"
    fi

    if [ "$AUTO_MERGE" = "true" ]; then
      gh pr merge "$PR_BRANCH" --auto --squash 2>/dev/null || true
    fi
    ;;

  *)
    echo "::error::Unrecognized commit-mode '$COMMIT_MODE' — expected \"pr\" or \"direct\". Refusing to guess; no push or pull request was created." >&2
    exit 1
    ;;
esac
