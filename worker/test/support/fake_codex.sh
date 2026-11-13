#!/usr/bin/env bash
# A stand-in for `codex app-server`: JSON-RPC over stdio, as OpenAI describes it. **Written to that
# description and not captured from an installed codex** (docs/design/codex.md § Not verified
# here). Answers `initialize`, `thread/start` and `thread/resume`, and runs one turn per
# `turn/start`: writes $FORGE_JOB/out/plan.md, streams two model calls' usage and the account's
# windows, and completes. Exits when stdin reaches EOF, which is how a runner ends a job.
#
# FAKE_CODEX_SCENARIO: success (default) | runaway (calls that never stop, for a budget) |
# limit (a turn that fails with a usage limit) | rotates (rewrites auth.json, as a refresh does).
set -u

if [ "${1:-}" = "--version" ]; then
  echo "codex-cli 9.9.9"
  exit 0
fi

# What the process was given: its argv, whether the login reached it as a file and not as a
# variable, and what is left in its environment.
printf 'args: %s\n' "$*" > "$FORGE_JOB/fake-args.txt"
if [ -f "$CODEX_HOME/auth.json" ]; then
  cp "$CODEX_HOME/auth.json" "$FORGE_JOB/fake-auth.json"
  stat -c '%a' "$CODEX_HOME/auth.json" > "$FORGE_JOB/fake-auth-mode.txt"
fi
printf '%s' "${FORGE_CODEX_AUTH-unset}" > "$FORGE_JOB/fake-auth-env.txt"
printf '%s' "${CODEX_ACCESS_TOKEN-unset}" > "$FORGE_JOB/fake-token-env.txt"

emit() { printf '%s\n' "$1"; }
id_of() { printf '%s' "$1" | sed 's/.*"id":\([0-9"a-z-]*\),.*/\1/'; }
usage() { # total input cached output
  emit "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"th-fake\",\"tokenUsage\":{\"total\":{\"totalTokens\":$1},\"last\":{\"inputTokens\":$2,\"cachedInputTokens\":$3,\"outputTokens\":$4}}}}"
}

turn=0
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      emit '{"id":0,"result":{"userAgent":"fake"}}'
      ;;
    *'"method":"thread/start"'* | *'"method":"thread/resume"'*)
      # What the thread was asked for (model, sandbox, ...), for a test of what reached the driver.
      # `turn/start`, below, is kept in the same file: it is where an effort is sent.
      printf '%s\n' "$line" >> "$FORGE_JOB/fake-thread.json"
      emit "{\"id\":$(id_of "$line"),\"result\":{\"thread\":{\"id\":\"th-fake\"}}}"
      ;;
    *'"method":"turn/start"'*)
      printf '%s\n' "$line" >> "$FORGE_JOB/fake-thread.json"
      turn=$((turn + 1))
      emit "{\"id\":$(id_of "$line"),\"result\":{\"turn\":{\"id\":\"t$turn\"}}}"
      emit "{\"method\":\"turn/started\",\"params\":{\"turn\":{\"id\":\"t$turn\"}}}"
      case "${FAKE_CODEX_SCENARIO:-success}" in
        rotates_then_fixes)
          # Round one: an invalid document and a refreshed login; round two (the correction's
          # process) is told what login it was started with, then writes a valid document.
          round=$(find "$FORGE_JOB" -maxdepth 1 -name 'fake-round-*' | wc -l)
          round=$((round + 1))
          touch "$FORGE_JOB/fake-round-$round"
          cp "$CODEX_HOME/auth.json" "$FORGE_JOB/fake-auth-round-$round.json"
          mkdir -p "$FORGE_JOB/out"
          if [ "$round" = 1 ]; then
            printf -- '---\noutcome: done\n' > "$FORGE_JOB/out/plan.md"
            printf '{"rotated":true,"tokens":{"refresh_token":"rotated"}}' > "$CODEX_HOME/auth.json"
          else
            printf -- '---\noutcome: done\n---\n# Plan\n\nFixed.\n' > "$FORGE_JOB/out/plan.md"
          fi
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"i2","text":"ok"}}}'
          ;;
        runaway)
          i=0
          while [ "$i" -lt 400 ]; do
            i=$((i + 1))
            usage $((i * 50000)) 0 0 10000
            sleep 0.05
          done
          ;;
        limit)
          emit '{"method":"turn/completed","params":{"turn":{"id":"t1","status":"failed","error":{"message":"You have hit your usage limit"}}}}'
          continue
          ;;
        *)
          mkdir -p "$FORGE_JOB/out"
          printf -- '---\noutcome: done\n---\n# Plan\n\nDone by the fake codex.\n' > "$FORGE_JOB/out/${FAKE_DOC:-plan.md}"
          [ "${FAKE_CODEX_SCENARIO:-}" = "rotates" ] && printf '{"rotated":true,"tokens":{"refresh_token":"rotated"}}' > "$CODEX_HOME/auth.json"
          # The login's directory swapped for a link to somewhere else, holding a changed login.
          if [ "${FAKE_CODEX_SCENARIO:-}" = "linkdir" ]; then
            real=$(mktemp -d)
            printf '{"elsewhere":true}' > "$real/auth.json"
            rm -rf "$CODEX_HOME" && ln -s "$real" "$CODEX_HOME"
          fi
          # Far past what a login can be: not read at all.
          [ "${FAKE_CODEX_SCENARIO:-}" = "huge" ] && head -c 70000 /dev/zero | tr '\0' 'x' > "$CODEX_HOME/auth.json"
          # A job's user owns this path: a link in its place must not be followed by the worker.
          [ "${FAKE_CODEX_SCENARIO:-}" = "linked" ] && rm -f "$CODEX_HOME/auth.json" && ln -s /etc/hostname "$CODEX_HOME/auth.json"
          emit '{"method":"item/started","params":{"item":{"type":"commandExecution","id":"i1","command":"ls"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"i1","aggregatedOutput":"x","exitCode":0,"status":"completed"}}}'
          # Two model calls: 1000 in (400 cached) + 200 out, then 1500 in (1000 cached) + 100 out.
          usage 1200 1000 400 200
          usage 2800 1500 1000 100
          # The same notification again: the same call.
          usage 2800 1500 1000 100
          emit '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":12,"resetsAt":1800000000},"secondary":{"usedPercent":3,"resetsAt":1800500000}}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"i2","text":"All done."}}}'
          ;;
      esac
      emit "{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"t$turn\",\"status\":\"completed\"}}}"
      ;;
    *'"method":"turn/interrupt"'*)
      emit "{\"id\":$(id_of "$line"),\"result\":{}}"
      emit "{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"t$turn\",\"status\":\"interrupted\"}}}"
      ;;
  esac
done
exit 0
