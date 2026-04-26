#!/usr/bin/env bash
# Strip ANSI escape codes from a captured demo log so it can be embedded
# into the README as plain code blocks.
#
# Usage: ./scripts/log-to-markdown.sh /tmp/e2e-demo.log > docs/demo-output.txt

set -euo pipefail
sed -E 's/\x1b\[[0-9;]*[mGKHF]//g' "$1"
