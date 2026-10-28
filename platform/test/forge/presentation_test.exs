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
      |> String.replace(
        "produces: [refinement.md]",
        "produces: [refinement.md, deck.md!]\n    optional: [deck.md]"
      )

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

  # `optional` is how a workflow says an artifact is not required (the answered
  # `presentation-required`). The whole of it: the job ends `done` having written nothing, the
  # ticket moves on, and no artifact exists.
  test "a state may finish without writing an optional presentation", context do
    %{ticket: ticket, worker: worker} = context
    [job] = Jobs.for_ticket(ticket.id)

    assert ForgeCore.Job.Spec.optional_outputs(Jobs.spec(job)) == ["deck.md"]

    {:ok, job} =
      FakeWorker.run(job, worker, "success",
        written: %{"refinement.md" => "---\noutcome: done\n---\nRefined.\n"}
      )

    assert job.outcome == :converged
    assert job.declared_outcome == "done"
    assert Artifacts.latest(ticket.id, "deck.md") == nil

    # Nothing is stuck and nothing is missing: the ticket is on its way out of the state, waiting
    # only on the approval this transition has always asked for.
    assert %{pending_transition: %{"to" => "planning"}, status: :active} =
             Tickets.get!(ticket.id)
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

  # A presentation is parsed exactly as a document is, and this is the half of that which is not
  # cosmetic: `insert_questions/3` is the only writer of question rows anywhere, so without it a
  # blocking question in a presentation parks its job with nothing on any surface to answer and no
  # transition out while the job is live — the ticket stuck one state short, silently.
  test "a blocking question in a presentation can be answered", context do
    %{ticket: ticket, worker: worker} = context
    [job] = Jobs.for_ticket(ticket.id)

    {:ok, job} =
      FakeWorker.run(job, worker, "blocking",
        written: %{
          "refinement.md" => "---\noutcome: done\n---\nRefined.\n",
          "deck.md" => """
          ---
          outcome: done
          ---
          # Deck

          ```question
          key: shape
          text: Which shape?
          options: [{label: a, detail: About a, recommended: true}]
          blocking: true
          ```
          """
        }
      )

    assert job.status == :waiting

    assert [%{key: "shape"}] =
             ticket.id |> Artifacts.open_blocking_questions() |> Enum.filter(&(&1.key == "shape"))

    # And the front matter reached the version, which is the other half of "only the kind differs".
    assert %{meta: %{"outcome" => "done"}} = Artifacts.latest(ticket.id, "deck.md")
  end

  # The worker composes the manifest, collects `out/` and decides the outcome, and all three now
  # turn on the marker and on `optional` (`docs/design/worker-channel.md` § Versions). A release
  # from before them names `out/deck.md!` in the manifest, collects the file under that name —
  # which this platform records as an approvable *document* — and reports `error` for an absent
  # optional document the manifest said could be skipped. So the job asks for a machine that
  # speaks protocol 7, and the gate keeps it off every older one.
  test "a job declaring a presentation or an optional output needs protocol 7", context do
    [job] = Jobs.for_ticket(context.ticket.id)

    assert Jobs.protocol_needs(job)[:outputs] == 7
    assert Jobs.protocol(job) <= ForgeCore.WorkerProtocol.current()

    # Each half on its own, and a state that declares neither asking no more than any agent job.
    assert Jobs.protocol_needs(respec(job, ["refinement.md", "deck.md!"], []))[:outputs] == 7
    assert Jobs.protocol_needs(respec(job, ["refinement.md"], ["refinement.md"]))[:outputs] == 7
    assert Jobs.protocol_needs(respec(job, ["refinement.md"], []))[:outputs] == 0
  end

  defp respec(job, produces, optional) do
    spec = job.spec |> Map.put("produces", produces) |> Map.put("optional", optional)
    %{job | spec: spec}
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
