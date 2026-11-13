defmodule Forge.UsageFixtures do
  @moduledoc """
  Spend and window reports for usage: a credential's report of its windows, as a worker sends one
  from a harness's rate-limit event, and a run that spent something at a given moment.

  `Forge.Jobs.Runs` is the only writer of runs in the product, with tests of its own; these are for
  a test or a look whose subject is what `Forge.Usage` reads back.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Jobs.{Job, Run}
  alias Forge.Repo

  @doc """
  Records `credential` reporting its windows, `%{"five_hour" => {utilization, resets_at}, …}`,
  through a conversation in `project` that runs on it — the smallest thing that can carry one.
  """
  def reported!(project, credential, windows) do
    chat = Forge.ForgeFixtures.chat_fixture(%{project: project})
    Repo.update_all(from(j in Job, where: j.id == ^chat.id), set: [credential_id: credential.id])

    entries =
      Map.new(windows, fn {type, {utilization, resets_at}} ->
        {type, %{"utilization" => utilization, "resets_at" => DateTime.to_unix(resets_at)}}
      end)

    {type, {utilization, resets_at}} = Enum.min_by(windows, &elem(&1, 0))

    :ok =
      Forge.Jobs.record_harness_event(chat.id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "allowed",
          rate_limit_type: type,
          utilization: utilization,
          resets_at: DateTime.to_unix(resets_at),
          windows: entries
        }
      })

    credential
  end

  @doc """
  A run of `job` on `credential` that used `usage` weighted tokens, written at `at`: closed then,
  or with `open: true` still open and last counted then — which is the moment `Forge.Usage` draws
  it at.
  """
  def spent!(job, credential, usage, %DateTime{} = at, opts \\ []) when is_integer(usage) do
    at = DateTime.truncate(at, :second)
    open = Keyword.get(opts, :open, false)

    run =
      Repo.insert!(%Run{
        job_id: job.id,
        credential_id: credential.id,
        started_at: DateTime.add(at, -600),
        usage: usage,
        finished_at: if(open, do: nil, else: at)
      })

    # `updated_at` is the moment an open run was last counted; set after the insert, which stamps
    # its own.
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [updated_at: at])
    %{run | updated_at: at}
  end
end
