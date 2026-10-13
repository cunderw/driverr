#!/usr/bin/env bash
# ci-warnings.sh LOG... — list the compiler warnings a hosted run produced in this repo's
# own files, as annotations on the run.
#
# A hosted run starts from an empty build directory, so it compiles every file and its log
# covers the tree, not only the diff. Warnings from a dependency's checkout are left out:
# nothing here can fix them.
#
# It reports and exits 0. Make it fail the job once a run on `main` has shown zero.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FOUND="$(cat "$@" 2>/dev/null | grep -F 'warning:' | grep -F "$ROOT/" |
  grep -v -e '/\.build/' -e '/SourcePackages/' | sort -u || true)"

if [ -z "$FOUND" ]; then
  echo "no warnings in this repo's files"
  exit 0
fi

while IFS= read -r line; do
  echo "::warning::${line#"$ROOT"/}"
done <<< "$FOUND"
echo "$(wc -l <<< "$FOUND" | tr -d ' ') warning(s) in this repo's files"
