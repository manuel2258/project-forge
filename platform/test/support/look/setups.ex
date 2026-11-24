defmodule Forge.Look.Setups do
  @moduledoc """
  The data a look runs over, by name (`docs/design/look.md` § Setups).

  A setup is a module with `build/0`, built from the suite's own fixtures into the look's
  throwaway database, returning the users a look may log in as and the paths a `visit :name`
  may use. It is code kept in the repository, compiled by the gate and built by
  `setups_test.exs`, so one that rots fails the gate and not the next ticket. The step lists —
  which page, what to click — are not kept.

  **Made-up data only, and never a project secret's value** (`docs/design/look.md` § Only
  made-up data): the database is this run's own and nothing here reads any other.

  To add one, write a module beside `Forge.Look.Setups.Ticket` and list it in `@setups`.
  """

  @type built :: %{users: %{String.t() => struct}, paths: %{String.t() => String.t()}}

  @callback build() :: built

  @setups %{
    "decision" => Forge.Look.Setups.Decision,
    "queue" => Forge.Look.Setups.Queue,
    "queue_past" => Forge.Look.Setups.QueuePast,
    "jump" => Forge.Look.Setups.Jump,
    "ticket" => Forge.Look.Setups.Ticket,
    "repo_file" => Forge.Look.Setups.RepoFile,
    "repo" => Forge.Look.Setups.Repo,
    "accounts" => Forge.Look.Setups.Accounts,
    "signin_provider" => Forge.Look.Setups.SigninProvider,
    "settings" => Forge.Look.Setups.Settings,
    "machines" => Forge.Look.Setups.Machines,
    "machine_updates" => Forge.Look.Setups.MachineUpdates,
    "codex" => Forge.Look.Setups.Codex,
    "weighted_usage" => Forge.Look.Setups.WeightedUsage,
    "extend" => Forge.Look.Setups.Extend,
    "templates" => Forge.Look.Setups.Templates,
    "usage" => Forge.Look.Setups.Usage,
    "projects" => Forge.Look.Setups.Projects,
    "ticket_views" => Forge.Look.Setups.TicketViews,
    "attachments" => Forge.Look.Setups.Attachments,
    "project" => Forge.Look.Setups.Project,
    "proposals" => Forge.Look.Setups.Proposals,
    "job" => Forge.Look.Setups.Job,
    "changes" => Forge.Look.Setups.Changes,
    "chats" => Forge.Look.Setups.Chats,
    "forge_release" => Forge.Look.Setups.ForgeRelease,
    "image_builds" => Forge.Look.Setups.ImageBuilds,
    "milestones" => Forge.Look.Setups.Milestones,
    "schedules" => Forge.Look.Setups.Schedules,
    "update_step" => Forge.Look.Setups.UpdateStep,
    "paged_streams" => Forge.Look.Setups.PagedStreams,
    "warm_build" => Forge.Look.Setups.WarmBuild,
    "pages" => Forge.Look.Setups.Pages
  }

  @doc "The registered setups, by name."
  @spec all() :: %{String.t() => module}
  def all, do: @setups

  @doc "The module for `name`, or an error naming the ones there are."
  @spec fetch(String.t()) :: {:ok, module} | {:error, String.t()}
  def fetch(name) do
    case Map.fetch(@setups, name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         "no setup #{inspect(name)}; there are: #{@setups |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
    end
  end
end
