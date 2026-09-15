# shellcheck shell=bash
# The streaming-input spike: does the harness do what docs/design/conversations.md says?
#
# That note asserts, as fact, that `claude -p --input-format stream-json` gives one long-lived
# process taking many user messages on stdin with a `result` per turn — and the whole design of
# conversations rests on it. Nothing in this repository checked it. This does.
#
# It is here rather than in the test suite for the same reason M1 to M4 are: it runs a real
# harness against the real API, costs real money, and cannot run in CI.
#
# Every question is an assertion. The script exits non-zero when a load-bearing answer
# contradicts the note, because the point is to find that out now and not in slice 2.

FORGE_M_SPIKE_ANSWERS=()

spike_answer() {
  FORGE_M_SPIKE_ANSWERS+=("$1|$2|$3")
}

spike_report() {
  local row question answer verdict bad=0
  printf '\n  %-42s %-30s %s\n' "QUESTION" "ANSWER" "VERDICT"
  for row in "${FORGE_M_SPIKE_ANSWERS[@]}"; do
    question=${row%%|*}
    answer=${row#*|}
    verdict=${answer#*|}
    answer=${answer%%|*}
    printf '  %-42s %-30s %s\n' "$question" "$answer" "$verdict"
    [ "$verdict" = "CONTRADICTS THE NOTE" ] && bad=$((bad + 1))
  done
  printf '\n'
  if [ "$bad" -gt 0 ]; then
    die "$bad answer(s) contradict docs/design/conversations.md; change the note before the code"
  fi
  info "the note's assumptions hold"
}

# `grep -c` prints 0 and *also* exits 1 when it matches nothing, so `$(grep -c … || echo 0)`
# yields "0\n0" and every arithmetic test after it is a syntax error. Assign, then default.
spike_count() {
  local n
  n=$(grep -c "$1" "$2" 2> /dev/null) || n=0
  printf '%s' "$n"
}

# Waits for the nth `result` line to appear, or times out. Polling a file is what there is:
# the process writes as it pleases and we are outside it. Awaiting for real matters — the first
# version of this script did not, and the turns raced each other into one muddled transcript.
spike_await_result() {
  local file=$1 want=$2 waited=0
  while [ "$(spike_count '"type":"result"' "$file")" -lt "$want" ]; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge 180 ] && return 1
  done
  return 0
}

spike_send() {
  local fd=$1 text=$2
  printf '%s\n' "$(jq -cn --arg t "$text" \
    '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}')" >&"$fd"
}

# The nth result's text, 1-indexed.
spike_result_text() {
  jq -r 'select(.type=="result") | .result // ""' "$1" | head -n "$2" | tail -n 1
}

cmd_streaming() {
  local keep=0
  while [ $# -gt 0 ]; do
    case $1 in
      --keep)
        keep=1
        shift
        ;;
      *) die "usage: bin/measure streaming [--keep]" ;;
    esac
  done

  have claude || fail_add "claude is not on PATH"
  have jq || fail_add "jq is not on PATH"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] ||
    fail_add "no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY in the environment"
  fail_report

  run_dir_init streaming
  section "streaming input"

  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/forge-spike-XXXXXX")
  [ "$keep" = 1 ] || trap 'rm -rf "$dir"' RETURN

  git -C "$dir" init -q
  git -C "$dir" -c user.name=spike -c user.email=spike@forge commit -q --allow-empty -m base
  mkfifo "$dir/in"

  # The FIFO is held open by a spare fd so the child never sees EOF and never exits. That is
  # the whole trick, and it is also what the worker's runner will have to do with its port.
  # --replay-user-messages is on because the note needs to know whether `message_delivered`
  # can be derived from the harness's own echo rather than invented by the worker.
  (cd "$dir" && claude -p --input-format stream-json --output-format stream-json --verbose \
    --replay-user-messages --permission-mode bypassPermissions < in > out.jsonl 2> err.log) &
  local pid=$!
  exec 9> "$dir/in"

  info "harness pid $pid, scratch $dir"

  # --- turn 1 ---------------------------------------------------------------------------
  phase_begin turn1
  spike_send 9 "Reply with exactly the word ALPHA and nothing else."
  spike_await_result "$dir/out.jsonl" 1 || die "no result for turn 1 within 180s; see $dir/err.log"
  phase_end turn1

  if kill -0 "$pid" 2> /dev/null; then
    spike_answer "process alive after turn 1" "yes" "as the note says"
  else
    spike_answer "process alive after turn 1" "NO — it exited" "CONTRADICTS THE NOTE"
  fi

  # --- turn 2: does it remember? ---------------------------------------------------------
  phase_begin turn2
  spike_send 9 "What single word did I ask you to reply with a moment ago? Reply with just it."
  spike_await_result "$dir/out.jsonl" 2 || die "no result for turn 2; see $dir/err.log"
  phase_end turn2

  local results
  results=$(spike_count '"type":"result"' "$dir/out.jsonl")
  spike_answer "a result per turn" "$results after 2 turns" \
    "$([ "$results" = 2 ] && echo "turn boundaries exist" || echo "CONTRADICTS THE NOTE")"

  if spike_result_text "$dir/out.jsonl" 2 | grep -qi ALPHA; then
    spike_answer "turn 2 remembers turn 1" "yes" "context is the process"
  else
    spike_answer "turn 2 remembers turn 1" "NO" "CONTRADICTS THE NOTE"
  fi

  # One session across turns, even if the harness announces itself more than once.
  local sessions inits
  sessions=$(jq -r '.session_id // empty' "$dir/out.jsonl" | sort -u | wc -l)
  inits=$(spike_count '"subtype":"init"' "$dir/out.jsonl")
  spike_answer "distinct sessions (init lines)" "$sessions ($inits init)" \
    "$([ "$sessions" = 1 ] && echo "one session, init repeats" || echo "CONTRADICTS THE NOTE")"

  # Per-turn or cumulative decides whether progress_attrs/2 adds or sets, separately for each
  # field. Getting either wrong corrupts a conversation's recorded spend, silently.
  local turn_counts costs t1 t2 c1 c2 turns_cumulative=no cost_cumulative=no
  turn_counts=$(jq -r 'select(.type=="result") | .num_turns' "$dir/out.jsonl" | paste -sd, -)
  costs=$(jq -r 'select(.type=="result") | .total_cost_usd' "$dir/out.jsonl" | paste -sd, -)
  t1=$(echo "$turn_counts" | cut -d, -f1)
  t2=$(echo "$turn_counts" | cut -d, -f2)
  c1=$(echo "$costs" | cut -d, -f1)
  c2=$(echo "$costs" | cut -d, -f2)
  [ "$t2" -gt "$t1" ] && turns_cumulative=yes
  [ "$(jq -n --argjson a "$c1" --argjson b "$c2" '$b > $a')" = true ] && cost_cumulative=yes

  spike_answer "num_turns cumulative" "$turns_cumulative ($turn_counts)" \
    "$([ "$turns_cumulative" = yes ] && echo "record must SET turns" || echo "record may ADD turns")"
  spike_answer "total_cost_usd cumulative" "$cost_cumulative ($costs)" \
    "$([ "$cost_cumulative" = yes ] && echo "record must SET cost" || echo "record may ADD cost")"

  # --- turn 3: can a turn be interrupted without killing the process? --------------------
  # The turn must still be running when the interrupt lands, or this proves nothing. Asking for
  # 40 numbers does not do it — the model emits them in two seconds. It has to be told to spend
  # real time, so the work is a shell loop that sleeps, and the assertion is that the turn ends
  # far sooner than that loop could have. The first version of this spike asked for the numbers,
  # interrupted an already-finished turn and called it proof.
  phase_begin interrupt
  spike_send 9 "Use the Bash tool to run exactly this, and then tell me the last number printed: for i in \$(seq 1 90); do echo \$i; sleep 1; done"
  sleep 20
  printf '%s\n' '{"type":"control_request","request_id":"spike-1","request":{"subtype":"interrupt"}}' >&9
  local interrupted_at=3
  spike_await_result "$dir/out.jsonl" "$interrupted_at" || true
  phase_end interrupt

  local control duration
  control=$(spike_count '"type":"control_response"' "$dir/out.jsonl")
  duration=$(jq -s -r '[.[] | select(.type=="result")] | .[2].duration_ms // 0' "$dir/out.jsonl")

  if ! kill -0 "$pid" 2> /dev/null; then
    spike_answer "interrupt keeps the process" "NO — it died" "CONTRADICTS THE NOTE"
  elif [ "$duration" -lt 60000 ]; then
    spike_answer "interrupt keeps the process" "yes, turn cut at ${duration}ms" \
      "force and Stop are possible"
  else
    spike_answer "interrupt keeps the process" "process yes, turn ran ${duration}ms" \
      "CONTRADICTS THE NOTE"
  fi
  info "control_response count: $control"

  # --- turn 4: a message sent while a turn is running ------------------------------------
  # Interleaved into the running turn or held for the next one? The note assumes the platform
  # must queue; if the harness interleaves, "force" is the default and queueing is the feature.
  local before
  before=$(spike_count '"type":"result"' "$dir/out.jsonl")
  phase_begin midturn
  spike_send 9 "Count slowly from 1 to 30, one number per line, pausing between each."
  sleep 5
  spike_send 9 "IGNORE the counting. Reply with exactly the word BRAVO and nothing else."
  spike_await_result "$dir/out.jsonl" $((before + 1)) || true
  local first_after
  first_after=$(spike_result_text "$dir/out.jsonl" $((before + 1)))
  spike_await_result "$dir/out.jsonl" $((before + 2)) || true
  phase_end midturn

  local after
  after=$(spike_count '"type":"result"' "$dir/out.jsonl")
  if echo "$first_after" | grep -q BRAVO; then
    spike_answer "mid-turn message" "interleaved (1 result)" "the platform must queue it itself"
  elif [ "$after" -gt $((before + 1)) ] && grep -q BRAVO "$dir/out.jsonl"; then
    spike_answer "mid-turn message" "queued ($((after - before)) results)" "the harness queues it"
  else
    spike_answer "mid-turn message" "NOT SEEN" "CONTRADICTS THE NOTE"
  fi

  # Does the harness echo what it was sent? If so `message_delivered` is observed, not invented.
  local replays
  replays=$(spike_count '"type":"user"' "$dir/out.jsonl")
  if [ "$replays" -gt 0 ]; then
    spike_answer "--replay-user-messages echoes" "yes ($replays)" "delivery is observable"
  else
    spike_answer "--replay-user-messages echoes" "no" "the worker must report delivery"
  fi

  # --- shutdown --------------------------------------------------------------------------
  exec 9>&-
  sleep 5
  if kill -0 "$pid" 2> /dev/null; then
    spike_answer "exits on stdin EOF" "no" "closing needs a signal"
    kill -TERM "$pid" 2> /dev/null || true
  else
    spike_answer "exits on stdin EOF" "yes" "closing the pipe is enough"
  fi
  wait "$pid" 2> /dev/null || true

  record measurement=streaming results="$after" sessions="$sessions" \
    turns_cumulative="$turns_cumulative" cost_cumulative="$cost_cumulative" \
    transcript="$dir/out.jsonl"

  [ "$keep" = 1 ] && info "kept $dir"
  spike_report
}
