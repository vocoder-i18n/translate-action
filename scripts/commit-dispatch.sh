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

# `set -e` exits silently on the failing command, which in a composite action
# surfaces as a red step with whatever the last tool happened to print. Name
# the script and line so a failure is attributable without re-running with
# bash -x.
trap 'status=$?; [ "$status" -ne 0 ] && echo "::error::${BASH_SOURCE[0]}: failed at line ${LINENO}: ${BASH_COMMAND} (exit $status)" >&2; exit $status' ERR

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
    # Slashes in the target branch are flattened. git stores refs as files, so
    # a branch "vocoder/translate-feat" and a branch "vocoder/translate-feat/x"
    # cannot both exist — the second is a directory/file conflict and the push
    # is rejected. Flattening keeps one ref per target branch and takes the
    # conflict off the table.
    PR_BRANCH="vocoder/translate-$(printf '%s' "$TARGET_BRANCH" | tr '/' '-')"
    # -B creates the branch or resets it to current HEAD (staged changes travel with us)
    git checkout -B "$PR_BRANCH"
    git commit -m "$COMMIT_MESSAGE"
    # --force because each run regenerates the full locale tree: the branch is
    # machine-owned and its history is not meant to accumulate. The pull request
    # body says so, since anything committed here by hand is lost on the next run.
    git push origin "$PR_BRANCH" --force

    PR_COUNT=$(gh pr list \
      --head "$PR_BRANCH" \
      --base "$TARGET_BRANCH" \
      --json number \
      --jq 'length')
    if [ "$PR_COUNT" = "0" ]; then
      gh pr create \
        --title "$COMMIT_MESSAGE" \
        --body "Automated translation update by [Vocoder](https://vocoder.app).

This branch is regenerated and force-pushed on every run, so commits made to it by hand will be lost. To correct a translation, edit it in Vocoder or in your source locale files on \`$TARGET_BRANCH\`." \
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
