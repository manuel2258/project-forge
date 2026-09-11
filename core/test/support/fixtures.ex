defmodule ForgeCore.Fixtures do
  @moduledoc "Shared test data for forge_core."

  alias ForgeCore.Job.Spec
  alias ForgeCore.Job.Spec.Input

  @doc "A job spec for the planned state of the grammar example."
  def spec do
    %Spec{
      job_id: "job-1",
      ticket: %{number: 7, title: "Persist the high score table"},
      state: "planned",
      attempt: 1,
      prompt: "Write a plan.",
      prompt_path: "agents/plan.md",
      env: "implement",
      commit: String.duplicate("a", 40),
      branch: "ticket/7",
      budget: %{turns: 40, cost: 2.0},
      preamble_hash: "sha256:x",
      inputs: [
        %Input{name: "ticket", version: 1, content: "Scores vanish."},
        %Input{name: "refinement.md", version: 2, content: "---\noutcome: done\n---\nRefined."}
      ],
      produces: ["plan.md", "changeset"],
      outcomes: ["done", "plan_invalid"]
    }
  end
end
