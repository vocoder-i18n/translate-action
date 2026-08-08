# Disclosure scan library. Sourced by scripts/verify.sh and exercised
# directly by tests/disclosure-scan.test.sh.
#
# translate-action is public (constitution §13.7), same as sdk, so the same
# scan applies: a pricing-shaped value (currency, a margin percentage, a
# per-period quota) is a finding only when a pricing-domain keyword also
# appears on the same line — a shape alone is never enough, and plan
# identifiers (free/starter/pro/enterprise) never match on their own. This
# is a bash port of sdk/scripts/verify/disclosure.ts; keep the two in sync
# if either's matching rules change.
#
# This file's own fixtures (and tests/disclosure-scan.test.sh's) necessarily
# contain synthetic pricing-shaped strings to prove the matcher works — see
# DISCLOSURE_EXCLUDED_PREFIXES below, which is what keeps this feature's own
# PR from failing on the very lines that prove it.

DISCLOSURE_KEYWORD_RE='(^|[^a-zA-Z])(credits?|plans?|subscriptions?|costs?|prices?|rates?|margins?|quotas?)([^a-zA-Z]|$)'
DISCLOSURE_CURRENCY_RE='[$€£¥][[:space:]]?[0-9][0-9,]*(\.[0-9]+)?([[:space:]]*/[[:space:]]*[a-zA-Z]+|[[:space:]]+per[[:space:]]+[a-zA-Z]+)?'
DISCLOSURE_RATE_SUFFIX_RE='(/[[:space:]]*[a-zA-Z]+|per[[:space:]]+[a-zA-Z]+)'
DISCLOSURE_PERCENT_RE='[0-9]{1,3}(\.[0-9]+)?[[:space:]]?%'
DISCLOSURE_QUOTA_RE='[0-9][0-9,]*[[:space:]]*(characters?|chars?|words?|tokens?|requests?|credits?|seats?)[[:space:]]*(/|per)[[:space:]]*(month|year|day)'

DISCLOSURE_EXCLUDED_PREFIXES=("tests/disclosure-scan.test.sh" "scripts/lib/disclosure-scan.sh")

# Held in a variable rather than inlined at the call site — see the comment
# where it's used in disclosure_run_scan.
DISCLOSURE_HUNK_HEADER_RE='^@@ -[0-9]+(,[0-9]+)?[[:space:]]\+([0-9]+)(,[0-9]+)?[[:space:]]@@'

disclosure_is_excluded_path() {
	local file="$1" prefix
	for prefix in "${DISCLOSURE_EXCLUDED_PREFIXES[@]}"; do
		[[ "$file" == "$prefix" ]] && return 0
	done
	return 1
}

# Scans one line of text for pricing-shaped values gated on a pricing-domain
# keyword being present anywhere on the same line. Prints zero or more
# "category|matched term" lines to stdout. Pure — no filesystem or git
# access — so it's directly testable against string fixtures.
disclosure_match_line() {
	local line="$1"
	grep -qiE "$DISCLOSURE_KEYWORD_RE" <<<"$line" || return 0

	local currency_match
	currency_match=$(grep -oiE "$DISCLOSURE_CURRENCY_RE" <<<"$line" | head -1)
	if [[ -n "$currency_match" ]]; then
		if grep -qiE "$DISCLOSURE_RATE_SUFFIX_RE" <<<"$currency_match"; then
			printf 'rate|%s\n' "$currency_match"
		else
			printf 'price|%s\n' "$currency_match"
		fi
	fi

	if grep -qi 'margin' <<<"$line" && grep -qiE "$DISCLOSURE_PERCENT_RE" <<<"$line"; then
		local margin_match
		margin_match=$(grep -oiE "(${DISCLOSURE_PERCENT_RE}[^%]{0,20}margin|margin[^%]{0,20}${DISCLOSURE_PERCENT_RE})" <<<"$line" | head -1)
		[[ -n "$margin_match" ]] && printf 'margin|%s\n' "$margin_match"
	fi

	local quota_match
	quota_match=$(grep -oiE "$DISCLOSURE_QUOTA_RE" <<<"$line" | head -1)
	[[ -n "$quota_match" ]] && printf 'quota|%s\n' "$quota_match"

	return 0
}

disclosure_default_base_ref() {
	printf 'origin/%s\n' "${GITHUB_BASE_REF:-main}"
}

# Diffs HEAD against the merge base with $2 (default: disclosure_default_base_ref)
# and scans every added line, writing "file|line|category|term" rows to $3
# (truncated first). Sets DISCLOSURE_SKIPPED=1 and DISCLOSURE_SKIP_DETAIL
# when the merge base or diff can't be determined (shallow clone, detached
# HEAD, first commit) rather than silently passing or failing against no
# data. Called directly (not via command substitution) so these globals
# reach the caller.
disclosure_run_scan() {
	local root="$1" base_ref="${2:-$(disclosure_default_base_ref)}" out_file="$3"
	: >"$out_file"
	DISCLOSURE_SKIPPED=0
	DISCLOSURE_SKIP_DETAIL=""

	local merge_base
	if ! merge_base=$(git -C "$root" merge-base "$base_ref" HEAD 2>/dev/null); then
		DISCLOSURE_SKIPPED=1
		DISCLOSURE_SKIP_DETAIL="could not determine merge base against $base_ref"
		return 0
	fi

	local diff_text
	if ! diff_text=$(git -C "$root" diff --unified=0 "${merge_base}...HEAD" 2>/dev/null); then
		DISCLOSURE_SKIPPED=1
		DISCLOSURE_SKIP_DETAIL="could not diff against merge base $merge_base"
		return 0
	fi

	local current_file="" line_no=0 ln
	while IFS= read -r ln; do
		if [[ "$ln" == "+++ "* ]]; then
			local f="${ln#+++ }"
			if [[ "$f" == "/dev/null" ]]; then
				current_file=""
			else
				current_file="${f#b/}"
			fi
			continue
		fi
		[[ "$ln" == "--- "* ]] && continue
		# Held in a variable rather than inlined here: an inline =~ pattern
		# with backslash-escaped metacharacters (`\+`) is a known bash
		# portability trap across regex-library versions, whereas a pattern
		# stored in a variable and referenced unquoted is passed to the
		# regex engine untouched regardless of shell/version.
		if [[ "$ln" =~ $DISCLOSURE_HUNK_HEADER_RE ]]; then
			line_no="${BASH_REMATCH[2]}"
			continue
		fi
		if [[ "$ln" == "+"* ]]; then
			if [[ -n "$current_file" ]] && ! disclosure_is_excluded_path "$current_file"; then
				local content="${ln#+}" match
				while IFS= read -r match; do
					[[ -z "$match" ]] && continue
					printf '%s|%s|%s|%s\n' "$current_file" "$line_no" "${match%%|*}" "${match#*|}" >>"$out_file"
				done < <(disclosure_match_line "$content")
			fi
			line_no=$((line_no + 1))
			continue
		fi
		[[ "$ln" == "-"* ]] && continue
		[[ -n "$current_file" ]] && line_no=$((line_no + 1))
	done <<<"$diff_text"
}
