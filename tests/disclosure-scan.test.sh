#!/usr/bin/env bash
# Proves scripts/lib/disclosure-scan.sh's line matcher: a pricing shape
# (currency, margin percentage, per-period quota) only counts when a
# pricing-domain keyword is also on the line, and plan identifiers alone
# never match. Every value below is synthetic — constitution §13.7 requires
# this scanner's own source and fixtures carry no real Vocoder figures.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/disclosure-scan.sh
source "$REPO_ROOT/scripts/lib/disclosure-scan.sh"

PASS=0
FAIL=0

# assert_match <label> <line> <expected category, or "" for none>
assert_match() {
	local label="$1" line="$2" expected="$3"
	local got
	got="$(disclosure_match_line "$line" | head -1 | cut -d'|' -f1)"
	if [[ "$got" == "$expected" ]]; then
		PASS=$((PASS + 1))
		echo "PASS: $label"
	else
		FAIL=$((FAIL + 1))
		echo "FAIL: $label"
		echo "      expected category \"$expected\", got \"$got\" (line: $line)"
	fi
}

assert_match "currency + rate keyword -> rate" \
	'This plan costs $0.05/character to run.' "rate"

assert_match "currency + price keyword, no rate suffix -> price" \
	'The one-time setup price is $250.' "price"

assert_match "margin percentage near the word margin -> margin" \
	'Current cost margin sits around 23% this quarter.' "margin"

assert_match "quota shape + credits keyword -> quota" \
	'The starter plan includes 500000 characters/month of credits.' "quota"

assert_match "bare currency shape, no pricing keyword -> no match" \
	'Format currency like $1,234.56 in the locale selector demo.' ""

assert_match "plan identifier alone -> no match" \
	'Gate the feature behind the enterprise plan identifier, not a number.' ""

assert_match "bare percentage, no margin word -> no match" \
	'Test coverage is at 92% for this package.' ""

assert_match "keyword with no shape nearby -> no match" \
	'Update the pricing page copy and the rate limit docs.' ""

echo ""
echo "disclosure-scan.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
