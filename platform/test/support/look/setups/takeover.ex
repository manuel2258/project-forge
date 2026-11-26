defmodule Forge.Look.Setups.Takeover do
  @moduledoc """
  Tickets worked on outside forge (`docs/design/outside-work.md`, ticket 79), in one project of one
  member: `look-takeover#1` open and refining, with nothing running (the details' *Take over*);
  `#2` taken over by the member, for the band, its fetch line and the hand-back picker; `#3` taken
  over by a project token called `my-pc`, so a holder who is not a person is drawn; `#4` stuck because
  its branch moved under a job, with three commits that arrived, two pushers and the job's work kept
  aside, for the stuck item and its three ways out. Users: `member` (a project admin). Paths:
  `open`, `taken`, `token`, `moved`, `project`, `queue`.

  Made-up data: the commits, the ids and the pushers are invented, and no value is a secret.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-takeover"}) |> join!(member)

    open = ticket(project, 1, "Persist the high score table")
    taken = ticket(project, 2, "Cache the leaderboard")
    token = ticket(project, 3, "Replace the parser, <b>by hand</b>")
    moved = ticket(project, 4, "Rework the settings screen")

    {:ok, _} = Forge.Operator.take_over(taken, member, via: :page)

    {:ok, _secret, writer} =
      Forge.Git.Tokens.issue(project, name: "my-pc", git: :developer, api: :write)

    {:ok, _} = Forge.Operator.take_over(token, writer, via: :mcp)

    {:ok, _} =
      Forge.Engine.stick(
        moved,
        "the branch moved while refining ran; its work is kept aside",
        {:branch_moved,
         %{
           "job_id" => Ecto.UUID.generate(),
           "outcome" => "done",
           "lease" => sha("a"),
           "kept" => sha("b"),
           "head" => sha("e"),
           "arrived" => [
             %{"sha" => sha("c"), "subject" => "Fix the parser's handling of empty lines"},
             %{"sha" => sha("d"), "subject" => "Add a test for the empty file"},
             %{
               "sha" => sha("e"),
               "subject" => "Rename Parser.run/1 to Parser.parse/1, <i>again</i>"
             }
           ],
           "pushers" => [
             %{"kind" => "api", "id" => writer.id, "name" => "my-pc"},
             %{"kind" => "user", "id" => member.id}
           ]
         }}
      )

    %{
      users: %{"member" => member},
      paths: %{
        "queue" => "/",
        "project" => "/projects/#{project.name}",
        "open" => "/tickets/#{project.name}/#{open.number}",
        "taken" => "/tickets/#{project.name}/#{taken.number}",
        "token" => "/tickets/#{project.name}/#{token.number}",
        "moved" => "/tickets/#{project.name}/#{moved.number}"
      }
    }
  end

  defp ticket(project, number, title) do
    ticket_fixture(%{project: project, number: number, branch: "ticket/#{number}", title: title})
  end

  defp sha(char), do: String.duplicate(char, 40)
end
