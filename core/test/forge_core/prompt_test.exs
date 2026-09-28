defmodule ForgeCore.PromptTest do
  use ExUnit.Case, async: true

  import ForgeCore.Fixtures

  alias ForgeCore.Job.Spec
  alias ForgeCore.Prompt

  # A conversation's spec: no ticket, no state, no budget, no outcomes. Everything the workflow
  # fixture has and a chat does not, which is exactly what the chat prompt has to cope with.
  defp chat_spec(overrides \\ %{}) do
    Map.merge(
      %Spec{
        job_id: "chat-1",
        kind: :chat,
        prompt: "Tell me about this repository.",
        branch: "chat/2026-09-15-abc",
        commit: String.duplicate("b", 40),
        preamble_hash: "sha256:y"
      },
      overrides
    )
  end

  test "the preamble is the shipped file and has a stable hash" do
    assert String.starts_with?(Prompt.preamble(), "# You are one job in a ticket lifecycle")
    assert "sha256:" <> hex = Prompt.preamble_hash()
    assert String.length(hex) == 64
  end

  test "compose/2 layers preamble, state prompt and manifest" do
    prompt = Prompt.compose(spec(), "/var/forge/jobs/job-1")

    assert [preamble, project, manifest] = String.split(prompt, "\n---\n\n")
    assert String.starts_with?(preamble, "# You are one job")
    assert String.trim(project) == "# Project instructions for state `planning`\n\nWrite a plan."
    assert String.starts_with?(manifest, "# Job manifest")

    assert manifest =~ "- Ticket 7: Persist the high score table"

    assert manifest =~
             "- `refinement.md` version 2 -> `/var/forge/jobs/job-1/inputs/refinement.md`"

    assert manifest =~ "- `plan.md` -> `/var/forge/jobs/job-1/out/plan.md` (carries the outcome)"
    assert manifest =~ "- `changeset`: the diff of your commits on `ticket/7`; no file to write"
    assert manifest =~ "`done`, `plan_invalid`, or `did_not_converge`"
    assert manifest =~ "- Turns: 40\n- Cost: 2.0 USD"
  end

  # `docs/design/job-prompt.md` § Commands: a job is told what it may run and how to ask, and a
  # resumed one what came back — in the manifest, so a cold start knows too.
  describe "commands" do
    test "a job that may invoke is told what, how many remain, and how to ask" do
      spec = %{
        spec()
        | may_invoke: %{
            "test" => %{"max" => 20, "concurrent" => 4, "remaining" => 17},
            "build" => %{"max" => 40, "concurrent" => nil}
          }
      }

      manifest = Prompt.manifest(spec, "/j")

      assert manifest =~ "## Commands you may run"

      assert manifest =~
               "- `build`: 40 of 40 invocations left\n- `test`: 17 of 20 invocations left, at most 4 at once"

      assert manifest =~ "write `/j/invoke.json`"
      assert manifest =~ ~s([{"command": "build", "args": ["--release"]}, {"command": "test"}])
    end

    test "a group of files is told where its files go and what they are kept as" do
      manifest = Prompt.manifest(%{spec() | produces: ["plan.md", "shots/*"]}, "/j")

      assert manifest =~
               "- `shots/*` -> any number of files in `/j/out/shots/`, each kept as `shots/<file>`"
    end

    test "a job that may not invoke is not told the file exists" do
      manifest = Prompt.manifest(spec(), "/j")
      refute manifest =~ "invoke.json"
      refute manifest =~ "Commands you"
    end

    test "a resumed job is told what each command did, and where its log is" do
      results = [
        %{
          "command" => "build",
          "args" => ["--release", "a b"],
          "at" => String.duplicate("c", 40),
          "exit_status" => 0,
          "outcome" => "converged",
          "duration_ms" => 42_300,
          "log" => "1-build.log"
        },
        %{
          "command" => "test",
          "args" => [],
          "exit_status" => nil,
          "outcome" => "error",
          "log" => "2-test.log"
        },
        %{"command" => "bench", "args" => [], "outcome" => "cancelled"},
        %{"command" => "lint", "args" => [], "refused" => "this state may not run lint"}
      ]

      manifest = Prompt.manifest(%{spec() | command_results: results}, "/j")

      assert manifest =~
               "- `build` `[\"--release\",\"a b\"]` at `cccccccccccc`: exit 0 in 42s; log `/j/commands/1-build.log`"

      assert manifest =~
               "- `test`: no exit status — it outlived its timeout or could not be run; log `/j/commands/2-test.log`"

      assert manifest =~ "- `bench`: cancelled before it finished"
      assert manifest =~ "- `lint`: refused — this state may not run lint"
    end
  end

  # `docs/design/job-prompt.md` § How the job arrived: a job sent back has to be told by what, and
  # a person's note on the way is the reason itself.
  describe "how the job arrived" do
    test "names the state, the outcome and who took it, with what they wrote" do
      manifest = Prompt.manifest(spec(), "/j")

      assert manifest =~
               "The ticket came from `refining` on `done`; a person took the transition."

      assert manifest =~ "They wrote:\n\n```text\nKeep the table local.\n```"
    end

    test "the engine's transition carries no note" do
      entered = %{"from" => "reviewing", "outcome" => "changes_requested", "by" => "engine"}
      manifest = Prompt.manifest(%{spec() | entered: entered}, "/j")

      assert manifest =~ "came from `reviewing` on `changes_requested`; the engine took"
      refute manifest =~ "They wrote"
    end

    # Out of a human state there is no job's outcome to name, and inventing the transition's
    # default `done` would say a job finished that never ran.
    test "a person's choice with no job behind it names no outcome" do
      entered = %{"from" => "human_testing", "outcome" => nil, "by" => "person"}

      assert Prompt.manifest(%{spec() | entered: entered}, "/j") =~
               "The ticket came from `human_testing`; a person took the transition."
    end

    test "the first state says so" do
      assert Prompt.manifest(%{spec() | entered: nil}, "/j") =~
               "This is the ticket's first state."
    end

    test "a note is fenced past any backticks in it" do
      entered = %{spec().entered | "comment" => "run ```mix test``` first"}

      assert Prompt.manifest(%{spec() | entered: entered}, "/j") =~
               "````text\nrun ```mix test``` first\n````"
    end

    test "an optional input not written yet is named as such" do
      manifest = Prompt.manifest(spec(), "/j")

      assert manifest =~
               "- `implementation.md`: not written on this ticket yet; it may be on a later visit"

      refute Prompt.manifest(%{spec() | absent_inputs: []}, "/j") =~ "not written on this ticket"
    end
  end

  # Both affordances are files, and a file an agent is never told about is a file it never
  # opens. These are the four things it has to know: where to read, where to write, that a
  # proposal is a suggestion rather than a ticket, and that the format has no front matter —
  # which the parser refuses, so an agent that guesses wrong loses the proposal.
  describe "what the preamble says about proposing and reading" do
    test "a job is told where the other tickets are and what is not in them" do
      flat = Prompt.preamble() |> String.replace("\n", " ")

      assert flat =~ "$FORGE_JOB/tickets/"
      assert flat =~ "index.md"
      assert flat =~ "snapshot"
      assert flat =~ "not yours to read"
    end

    test "a job is told how to propose, and that it is a suggestion" do
      flat = Prompt.preamble() |> String.replace("\n", " ")

      assert flat =~ "$FORGE_JOB/out/proposals/"
      assert flat =~ "No front matter"
      assert flat =~ "suggestion, not a ticket"
    end

    # The preamble tells a job that an undeclared file in `out/` is refused. `proposals/` is the
    # exception, so the rule has to name it — otherwise the preamble forbids in one paragraph what
    # it asks for in the next.
    test "the undeclared-output rule names the one directory it does not cover" do
      [rule] =
        Prompt.preamble()
        |> String.split("\n\n")
        |> Enum.filter(&(&1 =~ "An undeclared file"))

      assert rule =~ "proposals/"
    end

    # The examples are what an agent copies. Two refinements failed in production on question
    # blocks that were not YAML, and one project's own prompt showed the shape that failed. The
    # platform's examples are parsed by the platform's parser, as a job's and a chat's would be.
    test "the question blocks the preambles show are ones the parser accepts" do
      for {preamble, opts} <- [
            {Prompt.preamble(), []},
            {Prompt.chat_preamble(), [blocking: :always]}
          ] do
        [block] = Regex.run(~r/```question\n.*?\n```\n/s, preamble)
        assert {:ok, %{questions: [question]}} = ForgeCore.Document.parse(block, opts)
        assert question.key == "storage-backend"
      end
    end

    test "a job is told to quote question text, that it is resumed to fix a refused output, " <>
           "and what tools it has" do
      flat = Prompt.preamble() |> String.replace("\n", " ")

      assert flat =~ "Put `text`, `anchor` and `assumption` in double quotes"
      assert flat =~ "you are told exactly what is wrong and resumed to fix it"
      assert flat =~ "`python3`"
      refute ForgeCore.Workflow.platform_overview() =~ "`python3`"
    end

    test "a conversation is told the same two things, in its own words" do
      preamble = Prompt.chat_preamble()
      # Wrapped prose, so the sentences are matched with the line breaks taken out. A test that
      # matched the raw text would pass or fail on where the paragraph happened to wrap.
      flat = String.replace(preamble, "\n", " ")

      assert preamble =~ "$FORGE_JOB/tickets/"
      assert preamble =~ "$FORGE_JOB/out/proposals/"
      assert flat =~ "No front matter"

      # It has a person in it, so a question belongs in the reply rather than in the file.
      assert flat =~ "ask it in your reply"
    end

    # The preamble said proposals were recorded "when the conversation ends". They are recorded
    # at the end of each turn — and the sentence argued against itself, because its own reason
    # was that there is no goodbye to save them for. Nothing checked the timing claim.
    test "a conversation is told when its proposals are recorded, and it is per turn" do
      flat = Prompt.chat_preamble() |> String.replace("\n", " ")

      assert flat =~ "recorded at the end of each turn"
      refute flat =~ "recorded when the conversation ends"
    end
  end

  # The whole of the chat path was unexercised: nothing called `chat_preamble/0`,
  # `chat_manifest/2` or `compose/2` on a chat spec. The module's own docstring spends nine lines
  # saying that handing a conversation the job preamble "was not economy; it was telling the
  # agent to be a job" — and restoring that bug is a one-word edit the suite could not see.
  describe "a conversation" do
    test "gets its own preamble, which is a different document from a job's" do
      assert String.starts_with?(Prompt.chat_preamble(), "# You are in a conversation")

      # The point of the pair. If `chat_preamble/0` ever returns `@preamble` again, this is what
      # says so — and the hashes must differ too, since a chat's spec records its own.
      refute Prompt.chat_preamble() == Prompt.preamble()
      refute Prompt.chat_preamble_hash() == Prompt.preamble_hash()
      assert "sha256:" <> hex = Prompt.chat_preamble_hash()
      assert String.length(hex) == 64
    end

    test "is never told it is one job in a ticket lifecycle" do
      prompt = Prompt.compose(chat_spec(), "/var/forge/jobs/chat-1")

      assert String.starts_with?(prompt, "# You are in a conversation")

      # The four things the job preamble says that a conversation has no version of. Asserting
      # the absence rather than the presence, because the failure being guarded is the job
      # preamble arriving whole.
      refute prompt =~ "# You are one job in a ticket lifecycle"
      refute prompt =~ "Allowed outcomes"
      refute prompt =~ "# Job manifest"
      refute prompt =~ "Budget"
    end

    test "is layered preamble, manifest and the person's words" do
      prompt = Prompt.compose(chat_spec(), "/var/forge/jobs/chat-1")

      assert [preamble, manifest, said] = String.split(prompt, "\n---\n\n")
      assert String.starts_with?(preamble, "# You are in a conversation")
      assert String.starts_with?(manifest, "# This is a conversation")
      assert String.trim(said) == "Tell me about this repository."
    end

    # There is no state to leave and no outcome to declare, so the manifest says what a chat
    # actually has: a branch whose commits are kept, and where it is.
    test "is told the branch its work is kept on, and where it is" do
      manifest = Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1")

      # Unwrapped first: the sentence is hard-wrapped in the heredoc, and a test that pinned the
      # line break would fail the next time the paragraph was re-flowed rather than changed.
      unwrapped = String.replace(manifest, "\n", " ")
      assert unwrapped =~ "Work you commit on `chat/2026-09-15-abc` is kept and can be merged"

      assert manifest =~ "- Job directory: `/var/forge/jobs/chat-1`"
      assert manifest =~ "- Branch: `chat/2026-09-15-abc`"
    end

    # A chat started from a project rather than a ticket. It must not be told it is working a
    # ticket, and must not be pointed at a `history/` directory that was never written.
    test "about the repository as a whole is not given a ticket or a history" do
      manifest = Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1")

      assert manifest =~ "- About the repository as a whole."
      refute manifest =~ "About ticket"
      refute manifest =~ "What already ran on this ticket"
      refute manifest =~ "/history"
    end

    # A chat started from a ticket gets both: which ticket it is about, and the transcripts of
    # every job that already ran on it.
    test "about a ticket is told which, and where the jobs that already ran are" do
      spec = chat_spec(%{ticket: %{number: 7, title: "Persist the high score table"}})
      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")

      assert manifest =~ "- About ticket 7: Persist the high score table"
      assert manifest =~ "## What already ran on this ticket"
      assert manifest =~ "/var/forge/jobs/chat-1/history"
    end

    # A reopened conversation is a new process, and the message at the end of its prompt is the
    # next thing the person said. Without this section the agent is handed a file it is never
    # told about and a message it takes for an opening, and it answers as though nothing had
    # been said — the failure `docs/design/conversations.md` § Lifetime is built against.
    test "that was reopened is pointed at what was said before, and told it is not the first" do
      spec = chat_spec(%{replay: "# The conversation so far\n", prompt: nil})
      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")
      flat = String.replace(manifest, "\n", " ")

      assert manifest =~ "## This conversation was reopened"
      assert manifest =~ "`/var/forge/jobs/chat-1/conversation.md`"
      assert flat =~ "Read it before you reply"
      assert flat =~ "the next thing the person said — not the first"
    end

    # And a first start is not told about a file nobody wrote.
    test "that was never reopened is not pointed at a conversation file" do
      manifest = Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1")

      refute manifest =~ "reopened"
      refute manifest =~ "conversation.md"
    end

    # Ending a conversation deletes an unmerged branch, and the agent is the one the person asks
    # about their work — so it is told, and can say so before rather than after.
    test "is told what ending the conversation does to its branch" do
      flat = Prompt.chat_preamble() |> String.replace("\n", " ")

      assert flat =~ "a branch they have not merged is deleted unless it would not merge cleanly"
    end

    # A file an agent is never told about is a file it never writes. What it is told has to match
    # what is recorded: where, which names are kept, and that each turn records it.
    test "is told where a document it means to keep goes, and which names are not its" do
      flat = Prompt.chat_preamble() |> String.replace("\n", " ")

      assert flat =~ "`$FORGE_JOB/out/`, one per document"
      assert flat =~ "recorded at the end of each turn as a version"
      assert flat =~ "The name is one path segment"

      for reserved <- ["`ticket`", "`answers.md`", "`changeset`", "`proposals`", "`proposal-`"] do
        assert flat =~ reserved
      end

      # It said there was nowhere for a document to go, which stopped being true.
      refute flat =~ "nowhere for those to go"
    end

    # A reopen is a cold start and a cold start clears `out/`, so the agent is told where what it
    # wrote before now is, and that writing it to `out/` again is what changes it.
    test "is told where what it wrote before a reopen is, and how to change it" do
      flat = Prompt.chat_preamble() |> String.replace(~r/\s+/, " ")

      assert flat =~ "otherwise the documents this conversation wrote itself"
      assert flat =~ "copy it from `inputs/` into `out/`"
    end

    # It said a ticket's next job reads what a chat wrote. A job reads the inputs its state
    # declares, pinned when the job was created — so a name no state produces reaches no job.
    test "is not told that the ticket's next job reads whatever it writes" do
      flat = Prompt.chat_preamble() |> String.replace(~r/\s+/, " ")

      refute flat =~ "which its next job reads"
      assert flat =~ "a name the workflow never produces reaches no job at all"
    end

    # What the platform does with a document is what the agent is told: a question block in one
    # is text, and a document a person is deciding about is refused until they have.
    test "is told a document asks nothing, and which of a ticket's it may not write" do
      flat = Prompt.chat_preamble() |> String.replace(~r/\s+/, " ")

      assert flat =~ "asks nobody anything"
      assert flat =~ "one holding the question a waiting job stopped on"
      assert flat =~ "one waiting for their approval"
    end

    test "is told in its preamble where a reopened conversation's past is kept" do
      assert Prompt.chat_preamble() =~ "$FORGE_JOB/conversation.md"
    end

    test "with no inputs says so rather than leaving the section blank" do
      assert Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1") =~ "- none"
    end
  end

  # A run that resumes its harness session already holds the preamble and the state prompt. What
  # it lacks is what happened while it was stopped, which is what `continuation/3` says —
  # `docs/design/job-prompt.md` § The continuation prompt.
  describe "a continuation" do
    @answers "# Answers\n\nDecisions a person made on this ticket, oldest first.\n\n" <>
               "## backend\n\nQ: Local file or SQLite?\n\nA: sqlite\n"

    defp resumed_spec(answers \\ @answers) do
      spec = spec()

      %{
        spec
        | inputs: spec.inputs ++ [%Spec.Input{name: "answers.md", version: 3, content: answers}]
      }
    end

    # The whole saving. A continuation that carried the preamble or the state prompt would be
    # `compose/2` with a paragraph on top, and a resumed session would read its contract twice.
    test "is not the whole prompt again: no preamble and no state prompt" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      assert String.starts_with?(prompt, "# Continue this job")
      refute prompt =~ "# You are one job in a ticket lifecycle"
      refute prompt =~ "# Project instructions for state"
      refute prompt =~ "Write a plan."
    end

    # Asked of the Answers section and nothing else: the manifest below it lists the same input
    # with its version and path, so a whole-prompt match passed with both dropped from here.
    test "names the answers, verbatim, with the version and path they were pinned at" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      [_before, from_answers] = String.split(prompt, "## Answers\n", parts: 2)
      [section, _rest] = String.split(from_answers, "\n## Your branch", parts: 2)
      flat = String.replace(section, ~r/\s+/, " ")

      assert flat =~ "`answers.md` version 3"
      assert flat =~ "`/var/forge/jobs/job-1/inputs/answers.md`"
      assert section =~ "```markdown\n" <> String.trim(@answers) <> "\n```\n"
    end

    # A free-text answer is a person's words, and a person may quote a fenced block. A fence that
    # did not outgrow it would close early and leave the rest of the prompt inside a code block.
    test "fences the answers with more backticks than they contain" do
      quoted = @answers <> "\n## format\n\nQ: Which?\n\nA: like this:\n\n````\nx = 1\n````\n"
      prompt = Prompt.continuation(resumed_spec(quoted), "/var/forge/jobs/job-1", nil)

      assert prompt =~ "`````markdown\n# Answers"
      assert prompt =~ "x = 1\n````\n`````\n"
    end

    test "names the branch and the commit the worktree is at" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      assert prompt =~ "## Your branch\n\n`ticket/7`, at `c0ffee`, checked out"
    end

    test "says only the branch when the commit could not be read" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", nil)

      assert prompt =~ "## Your branch\n\n`ticket/7`, checked out"
    end

    # The manifest is whole and last, because it is what may have moved: the answers are now an
    # input, and the budget is the one this run was assigned.
    test "ends with the manifest as it stands, answers among the inputs" do
      spec = %{resumed_spec() | budget: %{turns: 40, cost: 0.75}}
      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee")

      assert [_changes, manifest] = String.split(prompt, "\n---\n\n")
      assert manifest == Prompt.manifest(spec, "/var/forge/jobs/job-1")
      assert manifest =~ "- `answers.md` version 3 -> `/var/forge/jobs/job-1/inputs/answers.md`"
      assert manifest =~ "- Cost: 0.75 USD"
    end

    # No path resumes a session without an answer today — only a run that stopped to ask records
    # one — but this is handed a spec, not that history, and must not say a person answered when
    # the spec carries no answer.
    test "with no answers among the inputs says nothing about answers" do
      prompt = Prompt.continuation(spec(), "/var/forge/jobs/job-1", "c0ffee")

      refute prompt =~ "## Answers"
      refute prompt =~ "A person answered"
      assert prompt =~ "## Your branch"
    end
  end
end
