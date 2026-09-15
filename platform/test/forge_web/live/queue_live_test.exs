defmodule ForgeWeb.QueueLiveTest do
  @moduledoc """
  The home screen, on the two things its own doc says it is: "one ordered list of decisions,
  oldest first" and one interruption per stopped job rather than one per question.

  Both are properties of arrangement, and arrangement is what a page-wide `assert html =~` cannot
  see — every item is on the page in any order, and every question is on the page whether or not
  it was answered. So the assertions here are on position and on what is left open afterwards.

  `docs/design/ui.md` § The affordance rule and `ForgeWeb.QueueLive`'s moduledoc are the standard.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Jobs, Projects, Repo, Tickets}
  alias Forge.Artifacts.Question

  setup :register_and_log_in_user

  setup do
    {:ok, project} =
      Projects.register(%{
        name: "queue-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    %{project: project}
  end

  defp admit(project, title) do
    {:ok, ticket} = Tickets.admit(project, %{title: title}, :system)
    ticket
  end

  # A document as an agent writes one, with the question blocks it left behind. Recorded rather
  # than run, because what these tests are about is the queue's arrangement of questions and not
  # the harness that produced them.
  defp ask(ticket, blocks) do
    [job | _] = Jobs.for_ticket(ticket.id)

    content = """
    ---
    outcome: done
    ---
    # Plan

    #{Enum.join(blocks, "\n")}
    """

    {:ok, version} =
      Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
        content: content
      })

    version
  end

  defp blocking(key, text) do
    """
    ```question
    key: #{key}
    text: #{text}
    options: [a, b]
    default: a
    blocking: true
    ```
    """
  end

  defp non_blocking(key, text) do
    """
    ```question
    key: #{key}
    text: #{text}
    options: [a, b]
    default: a
    blocking: false
    assumption: went with a
    ```
    """
  end

  defp aged(version, seconds) do
    Repo.update_all(
      from(q in Question, where: q.artifact_version_id == ^version.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -seconds, :second)]
    )
  end

  # "One ordered list of decisions, oldest first" is the first line of the page's own doc, and it
  # is what makes the queue drainable: the operator works down it and the thing that has been
  # waiting longest is never at the bottom where a long list hides it. Reversing the order leaves
  # every item on the page, so only position can tell the two apart.
  test "items are oldest first", %{conn: conn, project: project} do
    older = admit(project, "Waiting since yesterday")
    newer = admit(project, "Only just arrived")

    older_version = ask(older, [blocking("backend", "Which backend?")])
    newer_version = ask(newer, [blocking("format", "Which format?")])

    aged(older_version, 3600)
    aged(newer_version, 60)

    {:ok, _view, html} = live(conn, ~p"/")

    assert index(html, "item-questions-#{older_version.id}") <
             index(html, "item-questions-#{newer_version.id}")
  end

  # "Accept all N recommendations" is one tap that commits N decisions, so what it may reach has
  # to be exactly what the operator was shown. A non-blocking question is not shown here at all —
  # it never stopped the job, and the agent already recorded the assumption it proceeded with —
  # and answering it from this button would be the product deciding something on the operator's
  # behalf and reporting it as theirs.
  test "accepting all recommendations answers only the questions that were shown", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")

    ask(ticket, [
      blocking("backend", "Which backend?"),
      blocking("format", "Which format?"),
      non_blocking("naming", "What should the table be called?")
    ])

    {:ok, view, _html} = live(conn, ~p"/")

    # Only the blocking pair is an interruption, so only they are counted on the affordance.
    assert view |> element(~s([phx-click="answer_all"])) |> render() =~
             "Accept all 2 recommendations"

    view |> element(~s([phx-click="answer_all"])) |> render_click()

    assert render(view) =~ "Accepted 2 recommendations"

    assert ticket.id |> Artifacts.open_questions() |> Enum.map(& &1.key) == ["naming"]
  end

  # `ForgeWeb.QueueLive`: "A blocking question has halted a job; a non-blocking one has not, and
  # must never compete with work that is actually waiting." A non-blocking question is the
  # assumption an agent recorded and carried on from, so it is not a decision at all: not a row,
  # not a line in the digest, and not part of the figure the nav badge carries. Counting it would
  # put a number on the operator's home screen that never goes down by answering anything.
  test "a non-blocking question is not an interruption", %{conn: conn, project: project} do
    ticket = admit(project, "Persist scores")

    ask(ticket, [
      blocking("backend", "Which backend?"),
      non_blocking("naming", "What should the table be called?")
    ])

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Which backend?"
    refute html =~ "What should the table be called?"
    assert view |> element("main header span.font-mono") |> render() =~ "1 decision · 1 item"
  end

  # `ForgeWeb.Operator.Actions.ticket/1` casts before it queries, which is CLAUDE.md's "a guard
  # must use the same model as the operation it guards" written as code: `Tickets.get!/1` on a
  # string that is not a UUID raises `Ecto.Query.CastError`, which the `rescue` in `handle/3` does
  # not catch, and the whole LiveView dies rather than flashing. Nothing on the page can send such
  # an id, which is exactly why nothing exercised it — but a stale tab, a crafted payload or a
  # renamed param all can.
  test "a malformed ticket id is refused rather than killing the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_click(view, "transition", %{"ticket" => "not-a-uuid", "to" => "planning"}) =~
             "That ticket no longer exists."

    # Still there, and still usable: the flash is only a friendly error if the page survives it.
    assert has_element?(view, "#queue-end")
  end

  defp index(html, id) do
    [{position, _length}] = :binary.matches(html, ~s(id="#{id}"))
    position
  end
end
