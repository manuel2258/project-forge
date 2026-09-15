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

    test "with no inputs says so rather than leaving the section blank" do
      assert Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1") =~ "- none"
    end
  end
end
