#!/usr/bin/env bash
# A stand-in for `claude -p --output-format stream-json`. Reads the prompt from stdin, emits a
# realistic line stream, and writes outputs under $FORGE_JOB/out according to $FAKE_SCENARIO.
set -u
prompt="$(cat)"
out="$FORGE_JOB/out"
doc="$out/${FAKE_DOC:-plan.md}"
emit() { printf '%s\n' "$1"; }

printf 'args: %s\n' "$*" > "$FORGE_JOB/fake-args.txt"
printf 'ANTHROPIC_API_KEY=%s\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "${ANTHROPIC_API_KEY-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" > "$FORGE_JOB/fake-env.txt"
printf '%s' "$prompt" > "$FORGE_JOB/fake-prompt.txt"
env | sort > "$FORGE_JOB/fake-env-all.txt"
echo "some diagnostics on stderr" >&2

case "${FAKE_SCENARIO:-success}" in
  no_start) exit 1 ;;
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
    emit "$result_success" ;;
  plan_invalid)
    printf -- '---\noutcome: plan_invalid\n---\n# Plan\n\nThe plan cannot work.\n' > "$doc"
    emit "$result_success" ;;
  blocking)
    printf -- '---\noutcome: done\n---\n# Plan\n\n```question\nkey: backend\ntext: Which backend?\noptions: [a, b]\ndefault: a\nblocking: true\n```\n' > "$doc"
    emit "$result_success" ;;
  max_turns)
    emit '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":40,"duration_ms":99,"total_cost_usd":1.5,"session_id":"sess-42"}'
    exit 1 ;;
  max_budget)
    # A runaway: it spends up to whatever budget it was handed and the harness stops it there.
    emit '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":7,"duration_ms":99,"total_cost_usd":30.0,"session_id":"sess-42"}'
    exit 1 ;;
  crash)
    emit 'this is not json'
    emit '{"type":"weird_thing","x":1}'
    exit 1 ;;
  undeclared)
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    printf 'scratch' > "$out/notes.md"
    emit "$result_success" ;;
  invalid_document)
    printf -- '---\noutcome: done\n' > "$doc"
    emit "$result_success" ;;
  noeol)
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    printf '%s' "$result_success" ;;
  hang)
    sleep 60 ;;
esac
