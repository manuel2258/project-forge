#!/usr/bin/env bash
# A stand-in for `claude -p --output-format stream-json`. Reads the prompt from stdin, emits a
# realistic line stream, and writes outputs under $FORGE_JOB/out according to $FAKE_SCENARIO.
#
# The `chat` scenario stands in for `--input-format stream-json` instead: it reads messages from
# stdin for as long as stdin is open, answers each with one turn, and reproduces the three
# behaviours the spike measured on the real harness (measure/lib/streaming.sh) — the message is
# echoed back when it is taken, num_turns counts one turn, and total_cost_usd is cumulative
# across the session.
set -u

# Answered before anything else and without a job directory, because that is how the real binary
# answers it: the probe at join runs the harness with no job at all (docs/design/worker-channel.md
# § What a worker offers).
if [ "${1:-}" = "--version" ]; then
  echo "9.9.9 (Fake Claude)"
  exit 0
fi

out="$FORGE_JOB/out"
doc="$out/${FAKE_DOC:-plan.md}"
emit() { printf '%s\n' "$1"; }

# Enough of a JSON string encoder for the text these tests send.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

if [ "${FAKE_SCENARIO:-success}" != "chat" ]; then
  prompt="$(cat)"
  printf '%s' "$prompt" > "$FORGE_JOB/fake-prompt.txt"
fi

printf 'args: %s\n' "$*" > "$FORGE_JOB/fake-args.txt"
printf 'ANTHROPIC_API_KEY=%s\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "${ANTHROPIC_API_KEY-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" > "$FORGE_JOB/fake-env.txt"
env | sort > "$FORGE_JOB/fake-env-all.txt"
echo "some diagnostics on stderr" >&2

case "${FAKE_SCENARIO:-success}" in
  no_start) exit 1 ;;
  chat)
    turns=0
    cost=0
    # Every message the runner writes arrives here as one JSON line. Reading until stdin closes
    # is what makes this a conversation: the process outlives each turn and ends on EOF.
    while IFS= read -r line; do
      case "$line" in
        *'"control_request"'*)
          id="$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')"
          emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{\"still_queued\":[]}}}"
          # What a cut turn really reports: an execution error with no result. Only the runner
          # knows it asked for this, which is the point of the test that reads it.
          turns=$((turns + 1))
          emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"duration_ms\":20,\"total_cost_usd\":$cost,\"result\":null,\"session_id\":\"sess-42\"}"
          continue
          ;;
      esac

      text="$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')"
      turns=$((turns + 1))
      printf '%s\n' "$text" >> "$FORGE_JOB/fake-messages.txt"

      emit '{"type":"system","subtype":"init","session_id":"sess-42","model":"fake-model","tools":["Read"]}'
      # The echo, which the real harness writes only when it takes the message.
      emit "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}]}}"

      # A turn that takes time and can be cut while it does. Sleeping outright would make the
      # interrupt land after the turn had already ended, which proves nothing — the same trap
      # the spike fell into against the real harness.
      case "$text" in
        *SLOW*)
          remaining="${FAKE_TURN_SECONDS:-5}"
          cut=0
          while [ "$remaining" -gt 0 ]; do
            if IFS= read -r -t 1 ctl; then
              case "$ctl" in
                *'"control_request"'*)
                  id="$(printf '%s' "$ctl" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')"
                  emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{\"still_queued\":[]}}}"
                  cut=1
                  break
                  ;;
              esac
            fi
            remaining=$((remaining - 1))
          done

          if [ "$cut" = 1 ]; then
            emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"duration_ms\":20,\"total_cost_usd\":$cost,\"result\":null,\"session_id\":\"sess-42\"}"
            continue
          fi
          ;;
      esac

      if [ -n "${FAKE_COMMIT-}" ]; then
        printf '%s\n' "turn $turns" > "turn-$turns.md"
        git add "turn-$turns.md" >&2
        git commit --quiet -m "turn $turns" >&2
      fi

      emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply to $(json_escape "$text")\"}]}}"
      # Cumulative, as measured. A platform that adds this per turn over-counts every turn but
      # the first, and the number stays plausible while it does.
      cost=$(awk -v c="$cost" 'BEGIN { printf "%.4f", c + 0.01 }')
      emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"duration_ms\":12,\"total_cost_usd\":$cost,\"usage\":{\"input_tokens\":1,\"output_tokens\":2},\"result\":\"reply to $(json_escape "$text")\",\"session_id\":\"sess-42\"}"
    done
    exit 0
    ;;
esac

# An agent that actually changes the repository. The harness runs in the checkout, so this is
# what a real one does: ordinary commits on the current branch, which the platform then pushes.
if [ -n "${FAKE_COMMIT-}" ]; then
  printf '%s\n' "$FAKE_COMMIT" > "$FAKE_COMMIT"
  git add "$FAKE_COMMIT" >&2
  git commit --quiet -m "add $FAKE_COMMIT" >&2
fi

emit '{"type":"system","subtype":"init","session_id":"sess-42","model":"fake-model","tools":["Read","Edit"]}'
emit '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Reading the plan."},{"type":"tool_use","id":"t1","name":"Read","input":{"path":"plan.md"}}]}}'
emit '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"contents of plan.md"}]}}'
emit '{"type":"stream_event","event":{"type":"message_start"}}'

result_success='{"type":"result","subtype":"success","is_error":false,"num_turns":3,"duration_ms":1234,"total_cost_usd":0.0421,"usage":{"input_tokens":10,"output_tokens":20},"result":"Done.","session_id":"sess-42"}'

case "${FAKE_SCENARIO:-success}" in
  success)
    printf -- '---\noutcome: done\n---\n# Plan\n\nDo the thing.\n' > "$doc"
    # In the worktree, which is where the agent's actual work goes: the job directory is the
    # interface, the worktree is the change.
    printf 'edited by the agent\n' > CHANGED.md
    emit "$result_success"
    ;;
  plan_invalid)
    printf -- '---\noutcome: plan_invalid\n---\n# Plan\n\nThe plan cannot work.\n' > "$doc"
    emit "$result_success"
    ;;
  blocking)
    # shellcheck disable=SC2016 # the fenced question block is literal; nothing here expands
    printf -- '---\noutcome: done\n---\n# Plan\n\n```question\nkey: backend\ntext: Which backend?\noptions: [a, b]\ndefault: a\nblocking: true\n```\n' > "$doc"
    emit "$result_success"
    ;;
  max_turns)
    emit '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":40,"duration_ms":99,"total_cost_usd":1.5,"session_id":"sess-42"}'
    exit 1
    ;;
  max_budget)
    # A runaway: it spends up to whatever budget it was handed and the harness stops it there.
    emit '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":7,"duration_ms":99,"total_cost_usd":30.0,"session_id":"sess-42"}'
    exit 1
    ;;
  unauthenticated)
    # Verbatim from a machine whose credential never arrived: `is_error` set, exit 1, one turn,
    # not a token spent — and it still calls itself a success. The cause is only ever in
    # `result`. See docs/design/claude-code-events.md § Naming the failure.
    emit '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"duration_ms":103,"total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"result":"Not logged in · Please run /login","session_id":"sess-42"}'
    exit 1
    ;;
  crash)
    emit 'this is not json'
    emit '{"type":"weird_thing","x":1}'
    exit 1
    ;;
  undeclared)
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    printf 'scratch' > "$out/notes.md"
    emit "$result_success"
    ;;
  invalid_document)
    printf -- '---\noutcome: done\n' > "$doc"
    emit "$result_success"
    ;;
  noeol)
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    printf '%s' "$result_success"
    ;;
  hang)
    sleep 60
    ;;
esac
