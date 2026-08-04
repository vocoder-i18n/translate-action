#!/usr/bin/env bash
# Runs every *.test.sh file in this directory and fails if any of them do.
# This repo has no test framework — each *.test.sh is a self-contained bash
# script that prints PASS/FAIL per case and exits non-zero on any failure.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS=0

for test_file in "$TEST_DIR"/*.test.sh; do
  echo "== $(basename "$test_file") =="
  if ! bash "$test_file"; then
    STATUS=1
  fi
  echo ""
done

exit "$STATUS"
