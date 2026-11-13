defmodule Forge.Look.Setups.Accounts do
  @moduledoc """
  The accounts page and You (`12i`, `12j`): a node admin with an inference credential that has
  reported both windows, two accounts waiting that came through an issuer, one approved account
  from the same issuer and one suspended local account. Users: `admin` (the node admin).
  Paths: `accounts`, `you`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  @issuer "https://id.example.test"

  @impl true
  def build do
    admin = node_admin_fixture(%{email: "you@example.com"})

    waiting!("sam@example.com", "1093847562", 20 * 60)
    waiting!("lee@contractor.dev", "2210983311", 2 * 86_400)

    {:ok, ana} = identity!("ana@example.com", "7730021198")
    {:ok, _ana} = Forge.Accounts.approve_user(ana, admin)

    old = user_fixture(%{email: "old@example.com"})
    {:ok, old} = Forge.Accounts.suspend_user(old, admin)
    backdate!(old, :suspended_at, 21 * 86_400)

    credential!(admin)

    %{users: %{"admin" => admin}, paths: %{"accounts" => "/accounts", "you" => "/users/settings"}}
  end

  defp waiting!(email, subject, age) do
    {:ok, user} = identity!(email, subject)
    backdate!(user, :inserted_at, age)
  end

  defp identity!(email, subject),
    do: Forge.Accounts.log_in_with_identity(%{issuer: @issuer, subject: subject, email: email})

  defp backdate!(user, field, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)
    user |> Ecto.Changeset.change([{field, at}]) |> Forge.Repo.update!()
  end

  # Named, in a project's pool, and reported on by a conversation that ran on it: what draws its
  # row's windows on You. 42 % of the five-hour, 18 % of the week.
  defp credential!(admin) do
    project = project_fixture(%{name: "look-site"}) |> join!(admin)
    credential = pool!(project, credential_fixture(admin, %{name: "work subscription"}))
    chat = chat_fixture(%{project: project})
    {:ok, _} = chat |> Ecto.Changeset.change(credential_id: credential.id) |> Forge.Repo.update()
    now = System.os_time(:second)

    :ok =
      Forge.Jobs.record_harness_event(chat.id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "allowed",
          rate_limit_type: "five_hour",
          utilization: 0.42,
          resets_at: now + 2 * 3600,
          windows: %{
            "five_hour" => %{"utilization" => 0.42, "resets_at" => now + 2 * 3600},
            "seven_day" => %{"utilization" => 0.18, "resets_at" => now + 4 * 86_400}
          }
        }
      })
  end
end
