defmodule ForgeWorker.Fixtures do
  @moduledoc "Shared test data and directories for forge_worker."

  alias ForgeCore.Job.Spec
  alias ForgeCore.Job.Spec.Input

  @fake Path.expand("fake_claude.sh", __DIR__)

  def fake_executable, do: @fake

  def spec(overrides \\ %{}) do
    Map.merge(
      %Spec{
        job_id: uuid(),
        ticket: %{number: 7, title: "Persist the high score table"},
        state: "planning",
        attempt: 1,
        prompt: "Write a plan for the ticket.",
        prompt_path: "agents/plan.md",
        env: "implement",
        commit: String.duplicate("a", 40),
        branch: "ticket/7",
        budget: %{turns: 40, cost: 2.0},
        preamble_hash: ForgeCore.Prompt.preamble_hash(),
        inputs: [
          %Input{name: "ticket", version: 1, content: "Scores vanish on restart."},
          %Input{
            name: "refinement.md",
            version: 2,
            content: "---\noutcome: done\n---\nRefined.\n"
          }
        ],
        produces: ["plan.md", "changeset"],
        outcomes: ["done", "plan_invalid"]
      },
      overrides
    )
  end

  @doc "A random UUID (the worker does not depend on Ecto)."
  def uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> then(&:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", &1))
    |> IO.iodata_to_binary()
  end

  @doc "A fresh temporary directory, removed when the test process exits."
  def tmp_dir(context) do
    dir = Path.join(System.tmp_dir!(), "forge-#{context}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
