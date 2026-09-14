defmodule ForgeCore.PromptTest do
  use ExUnit.Case, async: true

  import ForgeCore.Fixtures

  alias ForgeCore.Prompt

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
end
