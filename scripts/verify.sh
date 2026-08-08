#!/usr/bin/env bash
#
# The gate (constitution §12). Same contract as sdk's and app's
# ./scripts/verify.sh — see sdk/specs/022-verify-acceptance-manifest/contracts/verify-cli.md
# for the full behavior spec, which this follows as closely as a bash-only
# repo allows. Two deliberate departures, both because this repo has no
# package.json and no node runtime dependency:
#
#   - No build/typecheck/lint checks. There is nothing to build, typecheck,
#     or lint — those rows are omitted rather than faked as skipped.
#   - "Unit tests" are bash files under tests/ (see tests/run.sh), each
#     printing one "PASS: <name>" / "FAIL: <name>" line per case instead of
#     a JSON reporter. An acceptance criterion's `test` field names
#     "<file>::<case name>", e.g.
#     "tests/commit-locale-files.test.sh::returns early when no result file
#     exists" — same key shape as sdk's vitest-backed gate, sourced from
#     PASS:/FAIL: lines instead.
#
# The disclosure scan (constitution §13.7) applies here exactly as in sdk —
# this repo is public too.
#
#   ./scripts/verify.sh              # verify the current branch
#   ./scripts/verify.sh --evidence   # emit only the evidence block, no checks
#
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/disclosure-scan.sh
source "$ROOT/scripts/lib/disclosure-scan.sh"

EVIDENCE_ONLY=false
[[ "${1:-}" == "--evidence" ]] && EVIDENCE_ONLY=true

log() { printf '%s\n' "$*" >&2; }

for tool in git jq shasum grep; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'FAIL  gate tooling missing\n      "%s" not found on PATH\n' "$tool" >&2
		printf '## Gate\n\n| Check | Result |\n|---|---|\n'
		exit 2
	fi
done

CHECK_NAMES=()
CHECK_OUTCOMES=()
CHECK_DETAILS=()
FAILURES=()

add_check() { CHECK_NAMES+=("$1"); CHECK_OUTCOMES+=("$2"); CHECK_DETAILS+=("${3:-}"); }

add_failure() {
	local title="$1"
	shift
	local msg="FAIL  $title"
	local line
	for line in "$@"; do
		msg="$msg
      $line"
	done
	FAILURES+=("$msg")
}

# Renders the evidence block from whatever the check/failure/criteria arrays
# hold at call time. Defined this early because the malformed-record path
# (below) calls it before most of those arrays are ever populated — safe,
# since an unset array expands to nothing without `set -u`.
render_evidence() {
	printf '## Gate\n\n| Check | Result |\n|---|---|\n'
	for ((i = 0; i < ${#CHECK_NAMES[@]}; i++)); do
		local label="${CHECK_OUTCOMES[$i]}"
		[[ -n "${CHECK_DETAILS[$i]}" ]] && label="${CHECK_OUTCOMES[$i]} — ${CHECK_DETAILS[$i]}"
		printf '| %s | %s |\n' "${CHECK_NAMES[$i]}" "$label"
	done

	if [[ "${#DISCLOSURE_FILES[@]}" -gt 0 ]]; then
		printf '\n## Disclosure findings\n\n| File | Line | Matched term | Category |\n|---|---|---|---|\n'
		for ((i = 0; i < ${#DISCLOSURE_FILES[@]}; i++)); do
			printf '| %s | %s | "%s" | %s |\n' "${DISCLOSURE_FILES[$i]}" "${DISCLOSURE_LINES[$i]}" "${DISCLOSURE_TERMS[$i]}" "${DISCLOSURE_CATEGORIES[$i]}"
		done
	fi

	if [[ -n "$DISPLAY_TICKET" ]]; then
		printf '\n## Acceptance criteria — %s\n\n' "$DISPLAY_TICKET"
		printf '| AC | Statement | Evidence | Result |\n|---|---|---|---|\n'
		for ((i = 0; i < ${#RES_IDS[@]}; i++)); do
			[[ "${RES_OUTCOMES[$i]}" == "observational" ]] && continue
			printf '| %s | %s | `%s` | %s |\n' "${RES_IDS[$i]}" "${RES_STATEMENTS[$i]}" "${RES_REFS[$i]}" "${RES_OUTCOMES[$i]}"
		done

		have_observational=false
		for outcome in "${RES_OUTCOMES[@]}"; do
			[[ "$outcome" == "observational" ]] && have_observational=true && break
		done
		if [[ "$have_observational" == true ]]; then
			printf '\n### Proven by observation\n\n| AC | Statement | Reference |\n|---|---|---|\n'
			for ((i = 0; i < ${#RES_IDS[@]}; i++)); do
				[[ "${RES_OUTCOMES[$i]}" != "observational" ]] && continue
				printf '| %s | %s | %s |\n' "${RES_IDS[$i]}" "${RES_STATEMENTS[$i]}" "${RES_REFS[$i]}"
			done
		fi
	fi
}

# ---------------------------------------------------------------- 1. branch -> ticket
BRANCH_NAME="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
if [[ -z "$BRANCH_NAME" ]]; then
	BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
fi

TICKET=""
if [[ "$BRANCH_NAME" =~ ^([0-9]{3})- ]]; then
	TICKET="${BASH_REMATCH[1]}"
	log "verify: branch \"$BRANCH_NAME\" names ticket $TICKET"
else
	log "verify: branch \"$BRANCH_NAME\" names no ticket — exempt"
fi
DISPLAY_TICKET="$TICKET"

# ---------------------------------------------------------------- 2/3. acceptance record
RECORD_PATH="$ROOT/.vocoder/acceptance/${TICKET}.json"
RECORD_LOADED=false
RECORD_TICKET=""
CRITERIA_IDS=()
CRITERIA_STATEMENTS=()
CRITERIA_TESTS=()       # empty string when this criterion uses evidence instead
CRITERIA_EVIDENCE_REFS=() # empty string when this criterion uses a test instead

emit_evidence_and_exit() {
	# $1 = exit code. Renders whatever's accumulated so far and exits.
	local code="$1"
	render_evidence
	exit "$code"
}

if [[ -n "$TICKET" ]]; then
	if [[ ! -f "$RECORD_PATH" ]]; then
		add_failure "acceptance record" \
			"expected .vocoder/acceptance/${TICKET}.json — branch $BRANCH_NAME names ticket $TICKET" \
			"create the record, or branch without a ticket number if this work is exempt"
	elif ! jq empty "$RECORD_PATH" >/dev/null 2>&1; then
		add_failure "acceptance record malformed" \
			".vocoder/acceptance/${TICKET}.json" \
			"invalid JSON"
		log "${FAILURES[${#FAILURES[@]}-1]}"
		emit_evidence_and_exit 2
	else
		RECORD_ERRORS=()

		RECORD_TICKET="$(jq -r '.ticket // ""' "$RECORD_PATH")"
		[[ -z "$RECORD_TICKET" ]] && RECORD_ERRORS+=('`ticket` must be a non-empty string')

		CRITERIA_COUNT="$(jq '(.criteria // []) | if type == "array" then length else -1 end' "$RECORD_PATH")"
		if [[ "$CRITERIA_COUNT" -le 0 ]]; then
			RECORD_ERRORS+=('`criteria` must be a non-empty array')
		else
			ALL_IDS_TMP="$(mktemp)"
			for ((i = 0; i < CRITERIA_COUNT; i++)); do
				id="$(jq -r ".criteria[$i].id // \"\"" "$RECORD_PATH")"
				statement="$(jq -r ".criteria[$i].statement // \"\"" "$RECORD_PATH")"
				has_test="$(jq -r "(.criteria[$i].test | type == \"string\" and length > 0)" "$RECORD_PATH")"
				has_evidence="$(jq -r "(.criteria[$i].evidence | type == \"object\")" "$RECORD_PATH")"

				[[ -z "$id" ]] && RECORD_ERRORS+=("criteria[$i].id must be a non-empty string")
				[[ -n "$id" ]] && printf '%s\n' "$id" >>"$ALL_IDS_TMP"
				[[ -z "$statement" ]] && RECORD_ERRORS+=("criteria[$i].statement must be a non-empty string")

				if [[ "$has_test" == "$has_evidence" ]]; then
					RECORD_ERRORS+=("criteria[$i] must declare exactly one of \`test\` or \`evidence\`")
				fi

				CRITERIA_IDS+=("$id")
				CRITERIA_STATEMENTS+=("$statement")
				if [[ "$has_test" == "true" ]]; then
					CRITERIA_TESTS+=("$(jq -r ".criteria[$i].test" "$RECORD_PATH")")
					CRITERIA_EVIDENCE_REFS+=("")
				else
					CRITERIA_TESTS+=("")
					CRITERIA_EVIDENCE_REFS+=("$(jq -r ".criteria[$i].evidence.ref // \"\"" "$RECORD_PATH")")
				fi
			done
			DUPES="$(sort "$ALL_IDS_TMP" | uniq -d)"
			rm -f "$ALL_IDS_TMP"
			if [[ -n "$DUPES" ]]; then
				while IFS= read -r dupe; do
					RECORD_ERRORS+=("criteria id \"$dupe\" is duplicated")
				done <<<"$DUPES"
			fi
		fi

		if [[ "${#RECORD_ERRORS[@]}" -gt 0 ]]; then
			add_failure "acceptance record malformed" ".vocoder/acceptance/${TICKET}.json" "${RECORD_ERRORS[@]}"
			log "${FAILURES[${#FAILURES[@]}-1]}"
			emit_evidence_and_exit 2
		fi

		RECORD_LOADED=true
	fi
fi

[[ "$RECORD_LOADED" == true && -n "$RECORD_TICKET" ]] && DISPLAY_TICKET="$RECORD_TICKET"

# ---------------------------------------------------------------- 4. constitution drift
log "verify: checking constitution drift..."
CONSTITUTION_PATH="$ROOT/.specify/memory/constitution.md"
if [[ ! -f "$CONSTITUTION_PATH" ]]; then
	add_check "Constitution" "fail" "missing .specify/memory/constitution.md"
	add_failure "constitution missing" "expected .specify/memory/constitution.md" "run: specify init --here --integration claude"
else
	DECLARED_HASH="$(grep -m1 -oE '<!-- hash: [a-f0-9]{64} -->' "$CONSTITUTION_PATH" | grep -oE '[a-f0-9]{64}')"
	STAMPED_TEXT="$(awk '
		/<!-- STAMPED:BEGIN -->/ { on=1; next }
		/<!-- STAMPED:END -->/ { on=0; next }
		on {
			t=$0; gsub(/^[ \t]+|[ \t]+$/, "", t)
			if (t ~ /^<!-- hash: [a-f0-9]{64} -->$/) next
			print
		}
	' "$CONSTITUTION_PATH")"
	COMPUTED_HASH=""
	[[ -n "$STAMPED_TEXT" ]] && COMPUTED_HASH="$(printf '%s' "$STAMPED_TEXT" | shasum -a 256 | cut -d' ' -f1)"

	if [[ -z "$DECLARED_HASH" || -z "$COMPUTED_HASH" || "$DECLARED_HASH" != "$COMPUTED_HASH" ]]; then
		add_check "Constitution" "fail" "hand-edited — content no longer matches its own hash marker"
		add_failure "constitution drift" \
			"repo copy's content no longer hashes to its own embedded marker" \
			"fix: ../scripts/sync-constitution.sh"
	else
		SYNC_SCRIPT="$ROOT/../scripts/sync-constitution.sh"
		if [[ ! -f "$SYNC_SCRIPT" ]]; then
			add_check "Constitution" "pass" "tier two skipped — ../scripts/sync-constitution.sh not reachable — expected in CI, which checks out only this repo"
		elif "$SYNC_SCRIPT" --check >/dev/null 2>&1; then
			add_check "Constitution" "pass"
		else
			add_check "Constitution" "fail" "constitution copy is stale relative to the workspace source — run ../scripts/sync-constitution.sh"
			add_failure "constitution drift" "constitution copy is stale relative to the workspace source — run ../scripts/sync-constitution.sh"
		fi
	fi
fi

# ---------------------------------------------------------------- 5. tests (unit-test analogue)
# Every tests/*.test.sh prints one "PASS: <name>" or "FAIL: <name>" line per
# case it covers (see tests/run.sh) — no test framework, no JSON reporter.
# That line is this repo's only source of per-case identity, so it doubles
# as the enumeration criteria resolve against, at "file::name" granularity —
# the same key shape sdk's vitest-backed gate uses, just sourced from PASS:/
# FAIL: lines instead of a JSON reporter. A criterion's `test` field is
# therefore e.g. "tests/commit-locale-files.test.sh::returns early when no
# result file exists", matching .vocoder/acceptance/*.json already committed
# in this repo.
RAN_FILE_LIST=()
RAN_FILE_OK=()   # parallel to RAN_FILE_LIST: "pass" or "fail" (the file's own exit code)
RAN_KEYS=()      # "file::case name" for every PASS:/FAIL: line seen
RAN_STATUSES=()  # parallel to RAN_KEYS: "pass" or "fail"

run_one_test_file() {
	local abs="$1" rel out file_ok ln
	rel="tests/$(basename "$abs")"
	out="$(mktemp)"
	log "verify: running $rel..."
	if bash "$abs" >"$out" 2>&1; then
		file_ok="pass"
	else
		file_ok="fail"
	fi
	RAN_FILE_LIST+=("$rel")
	RAN_FILE_OK+=("$file_ok")

	while IFS= read -r ln; do
		case "$ln" in
		"PASS: "*)
			RAN_KEYS+=("${rel}::${ln#PASS: }")
			RAN_STATUSES+=("pass")
			;;
		"FAIL: "*)
			RAN_KEYS+=("${rel}::${ln#FAIL: }")
			RAN_STATUSES+=("fail")
			;;
		esac
	done <"$out"

	if [[ "$file_ok" == "fail" ]]; then
		TEST_FAIL_DETAIL="$TEST_FAIL_DETAIL
$rel:
$(tail -15 "$out")"
	fi
	rm -f "$out"
}

TEST_FAIL_DETAIL=""

if [[ "$EVIDENCE_ONLY" == true ]]; then
	if [[ "$RECORD_LOADED" == true ]]; then
		SEEN_TMP="$(mktemp)"
		for t in "${CRITERIA_TESTS[@]}"; do
			[[ -z "$t" ]] && continue
			file_part="${t%%::*}"
			grep -qxF "$file_part" "$SEEN_TMP" 2>/dev/null && continue
			printf '%s\n' "$file_part" >>"$SEEN_TMP"
			candidate="$ROOT/$file_part"
			[[ -f "$candidate" ]] && run_one_test_file "$candidate"
		done
		rm -f "$SEEN_TMP"
	fi
	add_check "Tests" "skip" "not run (--evidence)"
else
	PASS_COUNT=0
	FAIL_COUNT=0
	for f in "$ROOT"/tests/*.test.sh; do
		[[ -e "$f" ]] || continue
		run_one_test_file "$f"
	done
	for file_ok in "${RAN_FILE_OK[@]}"; do
		if [[ "$file_ok" == "pass" ]]; then
			PASS_COUNT=$((PASS_COUNT + 1))
		else
			FAIL_COUNT=$((FAIL_COUNT + 1))
		fi
	done
	if [[ "${#RAN_FILE_LIST[@]}" -eq 0 ]]; then
		add_check "Tests" "fail" "no tests/*.test.sh files found"
		add_failure "tests" "no tests/*.test.sh files found"
	elif [[ "$FAIL_COUNT" -eq 0 ]]; then
		add_check "Tests" "pass" "${PASS_COUNT} file(s) passed"
	else
		add_check "Tests" "fail" "${PASS_COUNT} passed, ${FAIL_COUNT} failed"
		add_failure "tests" "${PASS_COUNT} passed, ${FAIL_COUNT} failed${TEST_FAIL_DETAIL}"
	fi
fi

# ---------------------------------------------------------------- 6. disclosure scan
log "verify: disclosure scan..."
DISCLOSURE_OUT="$(mktemp)"
disclosure_run_scan "$ROOT" "" "$DISCLOSURE_OUT"

DISCLOSURE_FILES=()
DISCLOSURE_LINES=()
DISCLOSURE_CATEGORIES=()
DISCLOSURE_TERMS=()
if [[ -s "$DISCLOSURE_OUT" ]]; then
	while IFS='|' read -r d_file d_line d_category d_term; do
		[[ -z "$d_file" ]] && continue
		DISCLOSURE_FILES+=("$d_file")
		DISCLOSURE_LINES+=("$d_line")
		DISCLOSURE_CATEGORIES+=("$d_category")
		DISCLOSURE_TERMS+=("$d_term")
	done <"$DISCLOSURE_OUT"
fi
rm -f "$DISCLOSURE_OUT"

if [[ "$DISCLOSURE_SKIPPED" == 1 ]]; then
	add_check "Disclosure" "pass" "skipped — $DISCLOSURE_SKIP_DETAIL"
elif [[ "${#DISCLOSURE_FILES[@]}" -gt 0 ]]; then
	n="${#DISCLOSURE_FILES[@]}"
	plural="s"
	[[ "$n" -eq 1 ]] && plural=""
	add_check "Disclosure" "fail" "${n} finding${plural}"
	for ((i = 0; i < n; i++)); do
		add_failure "disclosure" \
			"${DISCLOSURE_FILES[$i]}:${DISCLOSURE_LINES[$i]} — \"${DISCLOSURE_TERMS[$i]}\"" \
			"remove pricing/rate/margin/quota data from this diff, or use a plan identifier alone"
	done
else
	add_check "Disclosure" "pass"
fi

# ---------------------------------------------------------------- 7. resolve criteria
RES_IDS=()
RES_STATEMENTS=()
RES_REFS=()
RES_OUTCOMES=()

if [[ "$RECORD_LOADED" == true ]]; then
	for ((i = 0; i < ${#CRITERIA_IDS[@]}; i++)); do
		id="${CRITERIA_IDS[$i]}"
		statement="${CRITERIA_STATEMENTS[$i]}"
		test_key="${CRITERIA_TESTS[$i]}"

		if [[ -z "$test_key" ]]; then
			ref="${CRITERIA_EVIDENCE_REFS[$i]}"
			RES_IDS+=("$id")
			RES_STATEMENTS+=("$statement")
			RES_REFS+=("$ref")
			RES_OUTCOMES+=("observational")
			continue
		fi

		found=-1
		for ((j = 0; j < ${#RAN_KEYS[@]}; j++)); do
			if [[ "${RAN_KEYS[$j]}" == "$test_key" ]]; then
				found="$j"
				break
			fi
		done

		RES_IDS+=("$id")
		RES_STATEMENTS+=("$statement")
		RES_REFS+=("$test_key")
		if [[ "$found" -eq -1 ]]; then
			RES_OUTCOMES+=("unresolvable")
			add_failure "$id unresolvable" "\"$test_key\"" "no test case with that name — it may have been renamed"
		elif [[ "${RAN_STATUSES[$found]}" == "pass" ]]; then
			RES_OUTCOMES+=("passed")
		else
			RES_OUTCOMES+=("failed")
			add_failure "$id failed" "\"$test_key\" did not pass"
		fi
	done
fi

# ---------------------------------------------------------------- 8/9. evidence + exit
for failure in "${FAILURES[@]}"; do
	log "$failure"
done

if [[ "${#FAILURES[@]}" -eq 0 ]]; then
	log "verify: pass"
	render_evidence
	exit 0
else
	log "verify: fail"
	render_evidence
	exit 1
fi
