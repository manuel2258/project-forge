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

# What `systemd-run` does when PID 1 does not answer: it never reads its stdin, says why on stderr
# and exits (docs/design/worker-tier.md § A machine whose systemd stops answering). After a moment,
# so that a streaming runner has already written its prompt into the pipe, which is what left the
# relay waiting for a line that never came. The process group is written down first, so a test
# can see that nothing of the run is left in it afterwards.
# The signals it was started ignoring are written down too: the wrapper ignores `USR1` itself, and
# a harness has to be started with the default back.
if [ "${FAKE_SCENARIO:-}" = "exits_unread" ]; then
  ps -o pgid= -p $$ | tr -d ' ' > "$FORGE_JOB/fake-pgid.txt"
  sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status > "$FORGE_JOB/fake-sigign.txt"
  sleep "${FAKE_EXIT_AFTER:-0.5}"
  echo "Failed to start transient service unit: Connection timed out" >&2
  exit 1
fi

out="$FORGE_JOB/out"
doc="$out/${FAKE_DOC:-plan.md}"
emit() { printf '%s\n' "$1"; }

# Enough of a JSON string encoder for the text these tests send.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# The session a run resumes, kept as Claude Code keeps one (docs/measurements.md § Session
# resume): under $HOME/.claude/projects/<cwd, each character not a letter or digit a dash>/<id>.jsonl,
# found on `--resume` under any project directory, and forked under a new id. Sets `resume` (the
# id asked for, or empty), `here` (this working directory's), `found` (the file, or empty when a
# resume finds nothing) and `sid` (the id this run goes on under).
open_session() {
  resume=""
  fork=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "--resume" ] && resume="$a"
    [ "$a" = "--fork-session" ] && fork=1
    prev="$a"
  done
  projects="$HOME/.claude/projects"
  here="$projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$here"
  sid="sess-42"
  found=""
  if [ -n "$resume" ]; then
    found="$(find "$projects" -name "$resume.jsonl" 2> /dev/null | head -n 1)"
    if [ -n "$found" ]; then
      sid="$resume"
      [ -n "$fork" ] && sid="$resume-fork"
      [ "$found" = "$here/$sid.jsonl" ] || cp "$found" "$here/$sid.jsonl"
    fi
  fi
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
  # Never says it started: what a `nix develop` still building, or a harness stuck before its
  # first line, looks like from the worker. Two chats sat like this for 38 minutes in production.
  # More stderr than the tail a report carries, so the head and the tail differ.
  long_stderr)
    for i in $(seq 1 400); do echo "early line $i of a long nix develop" >&2; done
    echo "the last thing it said" >&2
    sleep 60
    ;;
  # Round one writes a document that does not parse (below). Resumed to correct it, it works on
  # and never finishes — or, with FAKE_SILENT_RESUME, never says it started either.
  hangs_when_resumed)
    case " $* " in
      *" --resume "*)
        [ -n "${FAKE_SILENT_RESUME-}" ] ||
          emit '{"type":"system","subtype":"init","session_id":"sess-43","model":"fake-model","tools":[]}'
        sleep 60
        ;;
    esac
    ;;
  never_starts)
    echo "copying path '/nix/store/abc-android-sdk' from 'https://cache.nixos.org'..." >&2
    sleep 60
    ;;
  # A first run writes a session that remembers a word. A resume with nothing to find exits
  # before `init` the way the real harness does; found, it says what it remembers in its
  # document (`open_session` above).
  session)
    open_session "$@"
    if [ -z "$resume" ]; then
      printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"$sid\",\"parentUuid\":null,\"uuid\":\"u1\",\"message\":{\"content\":\"remember ${FAKE_WORD:-PELICAN}\"}}" > "$here/$sid.jsonl"
      remembered="nothing"
    elif [ -z "$found" ]; then
      echo "No conversation found with session ID: $resume" >&2
      emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":0,\"duration_ms\":1,\"total_cost_usd\":0,\"session_id\":\"$resume\"}"
      exit 1
    else
      remembered="$(sed -n 's/.*remember \([A-Z]*\).*/\1/p' "$found" | head -n 1)"
    fi
    printf 'args: %s\n' "$*" > "$FORGE_JOB/fake-args.txt"
    emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"model\":\"fake-model\",\"claude_code_version\":\"9.9.9\",\"tools\":[]}"
    printf -- '---\noutcome: done\n---\n# Plan\n\nRemembered %s.\n' "$remembered" > "$doc"
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"duration_ms\":5,\"total_cost_usd\":0.01,\"result\":\"Done.\",\"session_id\":\"$sid\"}"
    exit 0
    ;;
  chat)
    turns=0
    cost=0
    # Its session (`open_session` above): a resume with nothing to find ends before it reads a
    # message. What the restored file remembered is written where a test can read it.
    open_session "$@"
    if [ -n "$resume" ]; then
      if [ -z "$found" ]; then
        echo "No conversation found with session ID: $resume" >&2
        exit 1
      fi
      sed -n 's/.*remember \([A-Z]*\).*/\1/p' "$found" | head -n 1 > "$FORGE_JOB/fake-remembered.txt"
    fi
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
          emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"duration_ms\":20,\"total_cost_usd\":$cost,\"result\":null,\"session_id\":\"$sid\"}"
          continue
          ;;
      esac

      text="$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')"
      turns=$((turns + 1))
      printf '%s\n' "$text" >> "$FORGE_JOB/fake-messages.txt"
      # The whole line as well, because `text` above stops at the first escaped quote — and a
      # composed prompt is full of them. A test about what one message carried reads this.
      printf '%s\n' "$line" >> "$FORGE_JOB/fake-lines.jsonl"

      emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"model\":\"fake-model\",\"claude_code_version\":\"9.9.9\",\"tools\":[\"Read\"]}"
      printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"$sid\",\"parentUuid\":null,\"uuid\":\"u$turns\",\"message\":{\"content\":\"remember ${FAKE_WORD:-PELICAN}\"}}" >> "$here/$sid.jsonl"
      # The echo, which the real harness writes only when it takes the message.
      emit "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}]}}"

      # A request written before the turn could end, for the interrupted case: the file is on
      # disk and the turn never finished (`docs/design/conversations.md` § Taking a transition).
      case "$text" in
        *PREMOVE*)
          printf '{"to": "implementing", "comment": "cut off mid-thought"}\n' \
            > "$FORGE_JOB/transition.json"
          ;;
      esac

      # A request written and then a turn that ends badly: `ERRMOVE` on an error subtype,
      # `BUDGETMOVE` on a success subtype that is still an error. Both must have the file
      # removed unread (`docs/design/conversations.md` § Taking a transition).
      case "$text" in
        *ERRMOVE*)
          printf '{"to": "implementing"}\n' > "$FORGE_JOB/transition.json"
          emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"duration_ms\":9,\"total_cost_usd\":$cost,\"result\":null,\"session_id\":\"$sid\"}"
          continue
          ;;
        *BUDGETMOVE*)
          printf '{"to": "implementing"}\n' > "$FORGE_JOB/transition.json"
          emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"num_turns\":1,\"duration_ms\":9,\"total_cost_usd\":$cost,\"result\":\"stopped\",\"session_id\":\"$sid\"}"
          continue
          ;;
      esac

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
            emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"duration_ms\":20,\"total_cost_usd\":$cost,\"result\":null,\"session_id\":\"$sid\"}"
            continue
          fi
          ;;
      esac

      if [ -n "${FAKE_COMMIT-}" ]; then
        printf '%s\n' "turn $turns" > "turn-$turns.md"
        git add "turn-$turns.md" >&2
        git commit --quiet -m "turn $turns" >&2
      fi

      # A conversation writing a document, which it means to keep by leaving it in `out/`.
      case "$text" in
        *WRITE*)
          printf -- '# Notes\n\nWhat the conversation found.\n' > "$out/notes.md"
          ;;
      esac

      # A conversation filing a ticket. Written once and left there, because `out/` is not
      # cleared between turns — which is the case the platform's record-by-content rule is for.
      case "$text" in
        *PROPOSE*)
          mkdir -p "$out/proposals"
          printf -- '# Extract the score table\n\nThe person asked for this to be filed.\n' \
            > "$out/proposals/score-table.md"
          ;;
      esac

      # A conversation asking the platform to move its ticket, and one writing a file that is
      # not a request at all (`docs/design/conversations.md` § Taking a transition).
      # `BADMOVE` first: `*MOVE*` matches it too, and `case` takes the first pattern that fits.
      case "$text" in
        *BADMOVE*)
          printf 'not a request\n' > "$FORGE_JOB/transition.json"
          ;;
        *MOVE*)
          printf '{"to": "implementing", "comment": "the tests were the problem"}\n' \
            > "$FORGE_JOB/transition.json"
          ;;
      esac

      emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply to $(json_escape "$text")\"}]}}"
      # Cumulative, as measured. A platform that adds this per turn over-counts every turn but
      # the first, and the number stays plausible while it does.
      cost=$(awk -v c="$cost" 'BEGIN { printf "%.4f", c + 0.01 }')
      emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"duration_ms\":12,\"total_cost_usd\":$cost,\"usage\":{\"input_tokens\":1,\"output_tokens\":2},\"result\":\"reply to $(json_escape "$text")\",\"session_id\":\"$sid\"}"
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
  # A run that ends with work in the tree it never committed: the mutation lens of ticket 1,
  # killed between breaking the code and restoring it. A tracked file modified and an untracked
  # one written, which is both halves of what `git add -A` would sweep into a commit.
  leaves_dirty)
    printf -- '---\noutcome: done\n---\n# Report\n\nReviewed.\n' > "$doc"
    printf 'mutated by the reviewer\n' >> README.md
    printf 'scratch\n' > SCRATCH.md
    emit "$result_success"
    ;;
  plan_invalid)
    printf -- '---\noutcome: plan_invalid\n---\n# Plan\n\nThe plan cannot work.\n' > "$doc"
    emit "$result_success"
    ;;
  blocking)
    # shellcheck disable=SC2016 # the fenced question block is literal; nothing here expands
    printf -- '---\noutcome: done\n---\n# Plan\n\n```question\nkey: backend\ntext: Which backend?\noptions:\n  - {label: A, detail: The first., recommended: true}\n  - {label: B, detail: The second.}\nblocking: true\n```\n' > "$doc"
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
  rate_limited)
    # Stopped by the account's limit mid-run. Nothing recorded in this repository shows the
    # shape; this is the one third-party reports give: a `rejected` report, then the process ends
    # with an error result naming the limit. See docs/design/credentials.md § A limit reached
    # mid-run.
    emit '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":4102444800,"rateLimitType":"five_hour","utilization":0.97},"session_id":"sess-42"}'
    emit '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":4102444800,"rateLimitType":"five_hour"},"session_id":"sess-42"}'
    emit '{"type":"result","subtype":"success","is_error":true,"num_turns":2,"duration_ms":99,"total_cost_usd":0.2,"result":"You have hit your session limit","session_id":"sess-42"}'
    exit 1
    ;;
  leaks_secret)
    # An agent that prints what it holds, two ways: into a document, and in an assistant message
    # as the harness writes it — JSON-escaped (`docs/design/secrets.md` § Masking).
    printf -- '---\noutcome: done\n---\n# Plan\n\nThe key is %s.\n' "$STRIPE_TEST_KEY" > "$doc"
    emit "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"the key is $(json_escape "$STRIPE_TEST_KEY")\"}]}}"
    emit "$result_success"
    ;;
  crash)
    emit 'this is not json'
    emit '{"type":"weird_thing","x":1}'
    exit 1
    ;;
  proposes)
    # A job that did its own work and also said a ticket should exist. One proposal that reads
    # and one that does not, because the malformed one must not cost the job its outcome.
    printf -- '---\noutcome: done\n---\n# Plan\n\nDo the thing.\n' > "$doc"
    mkdir -p "$out/proposals"
    printf -- '# Extract the score table\n\nThe plan assumes a module that is not there.\n' \
      > "$out/proposals/score-table.md"
    printf -- 'no heading, so this one cannot be read\n' > "$out/proposals/half.md"
    # Proof the agent could read the backlog it was handed, recorded where a test can see it.
    cat "$FORGE_JOB/tickets/index.md" > "$FORGE_JOB/fake-backlog.txt" 2> /dev/null || true
    emit "$result_success"
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
  fixes_when_resumed)
    # The production failure and its remedy: a question block whose unquoted text holds `: `,
    # which is not YAML — and, told so on the resumed session, the same document with the text
    # quoted. Each run's prompt is kept, numbered, for the test to read.
    n=$(find "$FORGE_JOB" -maxdepth 1 -name 'fake-prompt-*.txt' | wc -l)
    printf '%s' "$prompt" > "$FORGE_JOB/fake-prompt-$((n + 1)).txt"
    case " $* " in
      *" --resume "*) text='"Split by region, e.g. Lesson 1: open strings?"' ;;
      *) text='Split by region, e.g. Lesson 1: open strings?' ;;
    esac
    # shellcheck disable=SC2016 # the fenced question block is literal; nothing here expands
    printf -- '---\noutcome: done\n---\n# Plan\n\n```question\nkey: split\ntext: %s\noptions:\n  - {label: By region, detail: One lesson per region.}\n  - {label: By string, detail: One lesson per string.}\nblocking: true\n```\n' "$text" > "$doc"
    emit "$result_success"
    ;;
  hangs_when_resumed)
    printf -- '---\noutcome: done\n' > "$doc"
    emit "$result_success"
    ;;
  result_then_linger)
    # Its result says success, its document does not parse, and it takes a moment to exit — the
    # window in which an operator's cancel arrives after the result and before the end.
    printf -- '---\noutcome: done\n' > "$doc"
    emit "$result_success"
    sleep 2
    ;;
  noeol)
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    printf '%s' "$result_success"
    ;;
  invokes)
    # Asks for a build and a test run and stops, as docs/design/commands.md § How an agent
    # invokes describes: the file, then a clean end. What it wrote to out/ is kept for the resume.
    printf -- '---\noutcome: done\n---\n# Plan\n\nHalf done.\n' > "$doc"
    printf '[{"command": "build", "args": ["--release", "a b"]}, {"command": "test"}]' \
      > "$FORGE_JOB/invoke.json"
    emit "$result_success"
    ;;
  invokes_badly)
    printf '{"command": "build"}' > "$FORGE_JOB/invoke.json"
    emit "$result_success"
    ;;
  invokes_over_budget)
    printf '[{"command": "build"}]' > "$FORGE_JOB/invoke.json"
    emit '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":40,"duration_ms":99,"total_cost_usd":1.5,"session_id":"sess-42"}'
    exit 1
    ;;
  invokes_with_shots)
    # Parks having written into a group: the files are kept for the resume, not staged now.
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    mkdir -p "$out/shots"
    printf 'first' > "$out/shots/home.png"
    printf '[{"command": "build"}]' > "$FORGE_JOB/invoke.json"
    emit "$result_success"
    ;;
  invokes_is_error)
    # A success subtype that is still an error: the run did not end cleanly.
    printf '[{"command": "build"}]' > "$FORGE_JOB/invoke.json"
    emit '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"duration_ms":9,"total_cost_usd":0.1,"result":"failed","session_id":"sess-42"}'
    ;;
  invokes_error_subtype)
    # An error subtype that does not say is_error: not clean either.
    printf '[{"command": "build"}]' > "$FORGE_JOB/invoke.json"
    emit '{"type":"result","subtype":"error_during_execution","is_error":false,"num_turns":1,"duration_ms":9,"total_cost_usd":0.1,"session_id":"sess-42"}'
    ;;
  reads_logs)
    # A resumed run proving it can read what its commands left it.
    printf -- '---\noutcome: done\n---\n# Plan\n\n' > "$doc"
    cat "$FORGE_JOB"/commands/*.log >> "$doc"
    emit "$result_success"
    ;;
  shots)
    # A group of files beside the document: bytes that are not text, and a name that is not one.
    printf -- '---\noutcome: done\n---\n# Plan\n' > "$doc"
    mkdir -p "$out/shots"
    printf '\211PNG\r\n\032\n\000\001' > "$out/shots/home.png"
    printf 'second' > "$out/shots/menu.png"
    printf 'hidden' > "$out/shots/.hidden"
    emit "$result_success"
    ;;
  hang)
    sleep 60
    ;;
  # The mutation lens of ticket 1 as it really ended: the tree broken, and then the process
  # stopped from outside before anything restored it. `leaves_dirty` proves the converged
  # ending; this one proves the killed-partway ending the acceptance criteria also name.
  dirties_then_hangs)
    printf 'mutated by the reviewer\n' >> README.md
    printf 'scratch\n' > SCRATCH.md
    # Written last, and the only thing that says the tree is now dirty. A test that cancels on
    # a channel event instead is racing a timer: this scenario emits nothing, so the first event
    # to arrive is the runner's own and says nothing about what this script has done.
    printf 'yes\n' > "$FORGE_JOB/fake-dirtied.txt"
    sleep 60
    ;;
  # And the third ending the criteria name: the tree broken and the run then failing on its own.
  # No document, so the job cannot converge however the commit went.
  dirties_then_fails)
    printf 'mutated by the reviewer\n' >> README.md
    printf 'scratch\n' > SCRATCH.md
    emit '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":2,"duration_ms":9,"total_cost_usd":0.02,"session_id":"sess-42"}'
    exit 1
    ;;
esac
