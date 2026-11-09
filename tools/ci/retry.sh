#!/usr/bin/env bash
#
# Runs a command, and runs it again while it fails, waiting longer each time:
# 15, 30, 60, 120 and 240 seconds, so six tries over about eight minutes.
#
#   tools/ci/retry.sh swift package resolve
#
# For the downloads every build starts with. GitHub's release downloads go
# down for minutes at a time: on 2026-11-09 they answered 504 for about a
# minute, and every job that fetched from them failed, on GitHub and on Xcode
# Cloud. A real failure, such as a checksum that doesn't match, fails six times
# and takes the eight minutes to say so.

set -uo pipefail

[ "$#" -gt 0 ] || {
	echo "usage: tools/ci/retry.sh command [argument ...]" >&2
	exit 2
}

wait=15
for try in 1 2 3 4 5 6; do
	"$@" && exit 0
	status=$?
	[ "$try" -lt 6 ] || break
	echo "retry: '$1' failed (exit $status), try $try of 6; trying again in ${wait}s" >&2
	sleep "$wait"
	wait=$((wait * 2))
done
echo "retry: '$1' failed six times; giving up (exit $status)" >&2
exit "$status"
