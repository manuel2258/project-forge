defmodule ForgeWeb.NotFound do
  @moduledoc """
  What a missed address was asking for, in the app's own terms (`docs/design/ui.md` § Not found,
  `20c`): a ticket of a project, a project, a job, a chat, a machine, or a page that is not one —
  with the likeliest reasons and the two places worth going.

  **A project the viewer is not a member of is a project that does not exist.** Membership is
  decided by `Forge.Access`, the same model every page and endpoint is guarded by
  (`ForgeWeb.Access`), and only once it says yes is anything inside the project looked up: so a
  non-member is never told a number range, a ticket's existence, or anything the project's own
  members are told (`docs/design/identity.md` § Projects and members). The name in the address is
  said back, because the person typed or followed it.

  The not-allowed page (`not_allowed/0`) is for `/accounts` alone, the one page whose existence
  is no secret.
  """

  alias Forge.Accounts.Scope
  alias Forge.{Projects, Tickets}

  @type place :: %{label: String.t(), path: String.t()}
  @type t :: %{
          asked: String.t(),
          headline: String.t(),
          reasons: String.t(),
          project: String.t() | nil,
          places: [place()]
        }

  @queue %{label: "Back to the queue", path: "/"}
  @projects %{label: "Projects", path: "/projects"}

  @doc "What `path_info` asked for, as the person reading `scope`'s page is allowed to learn it."
  @spec describe([String.t()], Scope.t()) :: t()
  def describe(path_info, %Scope{} = scope) do
    case path_info do
      ["tickets", name, number | rest] -> in_project(scope, name, {:ticket, number, rest})
      ["projects", "new" | _] -> nowhere(path_info)
      ["projects", name | rest] -> in_project(scope, name, {:project, rest})
      ["chats", _id | _] -> chat()
      ["workers", _id | _] -> machine()
      ["board" | _] -> board()
      _other -> nowhere(path_info)
    end
  end

  @doc "The page `/accounts` draws for an account that is not a node admin's."
  @spec not_allowed() :: t()
  def not_allowed do
    %{
      asked: "accounts",
      headline: "Accounts are for node admins.",
      reasons:
        "Approving, suspending and promoting accounts is what a node admin does, and only that. " <>
          "Ask one of this node's admins to do it for you.",
      project: nil,
      places: [@projects, @queue]
    }
  end

  # The project is resolved first, and as the guard resolves it: absent and not the viewer's are
  # one answer, and nothing inside it is read until the viewer may read it.
  defp in_project(scope, name, inner) do
    with %{} = project <- Projects.by_name(name),
         true <- ForgeWeb.Access.member?(scope, project) do
      inside(project, inner)
    else
      _no -> no_project(name)
    end
  end

  defp no_project(name) do
    %{
      asked: name,
      headline: "There is no project #{name}.",
      reasons:
        "The name may be misspelt, or the link is from another node. A project is shown only " <>
          "to its members, so one you were never added to is not here either.",
      project: nil,
      places: [@projects, @queue]
    }
  end

  defp inside(project, {:ticket, number, rest}) do
    case Tickets.fetch(project.name, number) do
      {:ok, ticket, _project} -> in_ticket(project, ticket, rest)
      :error -> no_ticket(project, number)
    end
  end

  defp inside(project, {:project, ["repo", "commits", sha | _]}) do
    %{
      asked: "#{project.name} #{String.slice(sha, 0, 12)}",
      headline: "#{project.name} has no commit #{String.slice(sha, 0, 12)}.",
      reasons:
        "It may be on a branch that was deleted since, or the link is from another project.",
      project: project.name,
      places: [
        %{label: "Open #{project.name}'s repository", path: "/projects/#{project.name}/repo"},
        @queue
      ]
    }
  end

  defp inside(project, {:project, _rest}) do
    %{
      asked: project.name,
      headline: "#{project.name} has no page here.",
      reasons: "The link may be from an earlier forge, whose pages have moved.",
      project: project.name,
      places: [open(project), @queue]
    }
  end

  defp no_ticket(project, number) do
    last = Tickets.last_number(project)

    range =
      if last,
        do: " #{project.name}'s tickets run up to ##{last}.",
        else: " #{project.name} has no tickets yet."

    %{
      asked: "#{project.name}##{number}",
      headline: "#{project.name} has no ticket ##{number}.",
      reasons:
        "It may have been declined before it was admitted, or the link is from another " <>
          "project." <> range,
      project: project.name,
      places: [open(project), @queue]
    }
  end

  # The removed review page lands here with the place it became.
  defp in_ticket(project, ticket, ["review" | _]) do
    ref = "#{project.name}##{ticket.number}"

    %{
      asked: "#{ref} review",
      headline: "#{ref} has no review page.",
      reasons: "A ticket's change and its review are its Changes view now.",
      project: project.name,
      places: [
        %{
          label: "Open #{ref}'s Changes",
          path: "/tickets/#{project.name}/#{ticket.number}?tab=changes"
        },
        @queue
      ]
    }
  end

  defp in_ticket(project, ticket, ["jobs", id | _]) do
    ref = "#{project.name}##{ticket.number}"

    %{
      asked: "#{ref} job #{String.slice(id, 0, 8)}",
      headline: "#{ref} has no job #{String.slice(id, 0, 8)}.",
      reasons:
        "The link may be from another ticket. Every job the ticket ran is in its Activity.",
      project: project.name,
      places: [%{label: "Open #{ref}", path: "/tickets/#{project.name}/#{ticket.number}"}, @queue]
    }
  end

  defp in_ticket(project, ticket, _rest) do
    ref = "#{project.name}##{ticket.number}"

    %{
      asked: ref,
      headline: "#{ref} has no page here.",
      reasons: "The link may be from an earlier forge, whose pages have moved.",
      project: project.name,
      places: [%{label: "Open #{ref}", path: "/tickets/#{project.name}/#{ticket.number}"}, @queue]
    }
  end

  defp chat do
    %{
      asked: "a chat",
      headline: "There is no chat at this address.",
      reasons:
        "The link may be from another node, or the chat is about a project you are not a " <>
          "member of: a chat is shown only to its project's members.",
      project: nil,
      places: [%{label: "Chats", path: "/chats"}, @queue]
    }
  end

  defp machine do
    %{
      asked: "a machine",
      headline: "There is no machine at this address.",
      reasons:
        "A machine is shown only to its owner, and one destroyed long ago may be gone. The link " <>
          "may also be from another node.",
      project: nil,
      places: [%{label: "Machines", path: "/workers"}, @queue]
    }
  end

  defp board do
    %{
      asked: "the board",
      headline: "There is no board any more.",
      reasons: "Each project's Tickets view is what the board showed, one project at a time.",
      project: nil,
      places: [@projects, @queue]
    }
  end

  defp nowhere(path_info) do
    path = "/" <> Enum.join(path_info, "/")

    %{
      asked: String.slice(path, 0, 60),
      headline: "There is no page at #{String.slice(path, 0, 60)}.",
      reasons: "The link may be mistyped, or from an earlier forge whose pages have moved.",
      project: nil,
      places: [@projects, @queue]
    }
  end

  defp open(project), do: %{label: "Open #{project.name}", path: "/projects/#{project.name}"}
end
