defmodule Forge.PresentationTest do
  @moduledoc """
  What a job's `produces` entry ending `!` becomes on the ticket: an artifact of kind
  `presentation`, which is what every surface reads to draw it `VIEW ONLY` with no approval slot
  (`docs/design/workflow-grammar-v1.md` § Semantics, `docs/design/ui.md` § Changes).

  The declaration is the only thing that says so. A document arrives from the worker under the
  name on disk whichever it was declared as, so a platform that did not look the state's
  `produces` up would record a presentation as an ordinary document — approvable, consumable, and
  rendered as part of the chain the change was built from.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, FakeWorker, Jobs, Tickets}

  @example Path.expand("../../../core/test/fixtures/workflow_example.yml", __DIR__)

  setup :register_and_log_in_user

  setup %{user: user} do
    workflow =
      @example
      |> File.read!()
      |> String.replace("produces: [refinement.md]", "produces: [refinement.md, deck.md!]")

    bare = seeded_repo(%{".forge/workflow.yml" => workflow})

    {:ok, project} =
      register_owned!(%{
        name: "present#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    join!(project, user)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "They vanish."}, {:user, user.id})

    %{project: project, ticket: ticket, worker: FakeWorker.connect()}
  end

  test "the state's declaration decides each document's kind", context do
    %{ticket: ticket, worker: worker} = context
    [job] = Jobs.for_ticket(ticket.id)

    assert ForgeCore.Job.Spec.presentation_outputs(Jobs.spec(job)) == ["deck.md"]

    {:ok, job} =
      FakeWorker.run(job, worker, "success",
        written: %{
          "refinement.md" => "---\noutcome: done\n---\nRefined.\n",
          "deck.md" => "---\noutcome: done\n---\nWhat I did and why.\n"
        }
      )

    assert job.outcome == :converged

    kinds =
      for artifact <- Artifacts.list(ticket.id), into: %{}, do: {artifact.name, artifact.kind}

    assert kinds["deck.md"] == :presentation
    assert kinds["refinement.md"] == :document

    assert %{content: "---\noutcome: done\n---\nWhat I did and why.\n", version: 1} =
             Artifacts.latest(ticket.id, "deck.md")
  end

  # The job page draws `produces` as the workflow declared it and looks each entry up by the name
  # the artifact is recorded under. Comparing the declaration itself would call every presentation
  # ever written "not written", on the one page a reader goes to to find out what a run produced.
  test "the job page says a written presentation was written", context do
    %{conn: conn, project: project, ticket: ticket, worker: worker} = context
    [job] = Jobs.for_ticket(ticket.id)

    {:ok, job} =
      FakeWorker.run(job, worker, "success",
        written: %{
          "refinement.md" => "---\noutcome: done\n---\nRefined.\n",
          "deck.md" => "---\noutcome: done\n---\nWhat I did and why.\n"
        }
      )

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    assert html =~ "deck.md!"
    refute html =~ "not written"
  end
end
