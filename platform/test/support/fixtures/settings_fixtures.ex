defmodule Forge.SettingsFixtures do
  @moduledoc """
  What project settings' tests and its look (`Forge.Look.Setups.Settings`) build on: a harness
  that said which model it started with, and a mirror that says what its last push did.
  """

  alias Forge.{Events, Projects}

  @doc """
  Records that a job's harness started on `model` — the event a worker sends from the harness's
  own init line, and the only place the platform learns what "the machine's" model was
  (`Forge.Projects.observed_model/1`).
  """
  def harness_started!(%Forge.Jobs.Job{} = job, model) do
    {:ok, event} =
      Events.append("job.harness.started", {:job, job.id}, %{
        job_id: job.id,
        ticket_id: job.ticket_id,
        payload: %{
          "model" => model,
          "session_id" => "session-#{System.unique_integer([:positive])}"
        }
      })

    event
  end

  @doc """
  Writes what the post-receive hook would have written about a mirror's last push
  (`docs/design/git-hosting.md` § What the mirrors say about themselves).
  """
  def mirror_pushed!(project, name, status, opts \\ []) do
    repo = Projects.repo_path(project)

    config = [
      {"lastStatus", status},
      {"lastAt", opts[:at]},
      {"lastError", opts[:error]},
      {"lastOkAt", opts[:ok_at]}
    ]

    for {key, value} <- config, value do
      {:ok, _} = Forge.Git.run(repo, ["config", "--local", "forge.mirror.#{name}.#{key}", value])
    end

    :ok
  end
end
