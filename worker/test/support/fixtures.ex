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
        ticket: %{number: 7, title: "Persist the high score table", ticket_type: nil},
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

  @doc """
  `secrets` sealed for `job_id` the way the platform seals them (`Forge.Secrets.for_wire/3`): for
  this machine's token and the purpose `:secrets`. The token is the one configured, or a new one,
  removed again when the test exits.
  """
  def sealed_secrets(secrets, job_id) do
    %ForgeWorker.Job.Secrets{
      job_id: job_id,
      sealed:
        ForgeCore.Job.Credential.seal(Jason.encode!(secrets), token_hash(), job_id, :secrets)
    }
  end

  defp token_hash do
    token =
      case Application.get_env(:forge_worker, :token) do
        token when is_binary(token) ->
          token

        nil ->
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          Application.put_env(:forge_worker, :token, token)
          ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:forge_worker, :token) end)
          token
      end

    {:ok, hash} = ForgeCore.Job.Credential.token_hash(token)
    hash
  end

  @doc "A random UUID (the worker does not depend on Ecto)."
  def uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> then(&:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", &1))
    |> IO.iodata_to_binary()
  end

  @doc """
  A fresh temporary directory, removed when the test process exits.

  Named by the OS process as well as `System.unique_integer/1`, which is unique only within one
  BEAM: suites run side by side from sibling worktrees share the system temp directory, and two
  of them made — and removed — each other's directories.
  """
  def tmp_dir(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-forge-#{context}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
