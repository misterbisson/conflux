#!/bin/sh
#
# Measure one llama-server at several --parallel settings, one after another,
# and print a table comparing them. See docs/phase-0.md.
#
#   tools/bench/sweep.sh --images DIR [options] -- <llama-server model arguments>
#
# Everything after `--` goes to llama-server, for example `-hf <repo>:<quant>`,
# or `-m model.gguf --mmproj projector.gguf`.
#
# Options:
#   --images DIR             images to send (required; they never leave this machine)
#   --slots "1 2 4 8"        --parallel values to try
#   --ctx-per-slot 8192      context per slot; llama-server splits -c across slots
#   --requests-per-slot 12   measured requests per slot, after warmup
#   --prompt-file PATH       prompt sent with every image
#   --max-tokens N           completion limit per request
#   --max-dimension PX       downscale images to this longer side
#   --port 8091              port for llama-server, on loopback only
#   --label TEXT             prefix for each run's label
#
# Results go to tools/bench/results/<timestamp>/, which git ignores.

set -eu

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

images="" slots="1 2 4 8" ctx=8192 per=12 port=8091 label=""
prompt_file="" max_tokens="" max_dimension=""
while [ $# -gt 0 ]; do
	case "$1" in
	--images) images=$2; shift 2 ;;
	--slots) slots=$2; shift 2 ;;
	--ctx-per-slot) ctx=$2; shift 2 ;;
	--requests-per-slot) per=$2; shift 2 ;;
	--prompt-file) prompt_file=$2; shift 2 ;;
	--max-tokens) max_tokens=$2; shift 2 ;;
	--max-dimension) max_dimension=$2; shift 2 ;;
	--port) port=$2; shift 2 ;;
	--label) label="$2 "; shift 2 ;;
	--) shift; break ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
	esac
done
[ -n "$images" ] || { echo "--images is required" >&2; exit 64; }
[ $# -gt 0 ] || { echo "pass the model to llama-server after --" >&2; exit 64; }
command -v llama-server >/dev/null || { echo "llama-server not found (brew install llama.cpp)" >&2; exit 69; }

root=$(cd "$(dirname "$0")/../.." && pwd)
results="$root/tools/bench/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$results"
swift build -c release --package-path "$root" --product conflux-bench >/dev/null
bench="$(swift build -c release --package-path "$root" --show-bin-path)/conflux-bench"

server=""
cleanup() { if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi; }
trap cleanup EXIT INT TERM

for n in $slots; do
	log="$results/server-parallel-$n.log"
	echo "== --parallel $n (llama-server log: $log)"
	llama-server --host 127.0.0.1 --port "$port" --parallel "$n" -c $((ctx * n)) "$@" >"$log" 2>&1 &
	server=$!

	# The first run may download the model, so allow up to 30 minutes.
	waited=0
	until curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
		if ! kill -0 "$server" 2>/dev/null; then
			echo "llama-server exited; see $log" >&2
			exit 1
		fi
		waited=$((waited + 1))
		[ "$waited" -le 1800 ] || { echo "llama-server wasn't ready after 30 minutes" >&2; exit 1; }
		sleep 1
	done

	# Twice as many requests in flight as slots, so a slot never waits for the
	# next request to arrive. llama-server queues the rest.
	inflight=$((n * 2))
	"$bench" run --endpoint "127.0.0.1:$port" --images "$images" \
		--concurrency "$inflight" --warmup "$inflight" --requests $((inflight + per * n)) \
		${prompt_file:+--prompt-file "$prompt_file"} ${max_tokens:+--max-tokens "$max_tokens"} \
		${max_dimension:+--max-dimension "$max_dimension"} \
		--label "${label}parallel $n" --json "$results/parallel-$n.json" | tee "$results/parallel-$n.txt"

	kill "$server"
	wait "$server" 2>/dev/null || true
	server=""
done

echo
"$bench" compare "$results"/parallel-*.json | tee "$results/compare.txt"
echo
echo "results in $results"
