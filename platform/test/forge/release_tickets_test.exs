defmodule Forge.ReleaseTicketsTest do
  @moduledoc """
  A project's native release (`docs/design/ticket-types.md` § Releases): who starts one, what it is
  called, how it is renamed, and that it concludes by itself when its workflow says nobody need
  approve. No workflow in this repository sets `release: true` yet, so every test here runs
  against a fixture repository a test made.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{
    Artifacts,
    Engine,
    Events,
    FakeWorker,
    Git,
    Jobs,
    Operator,
    ReleaseTickets,
    Tickets
  }

  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow.Parser

  @dev """
  version: 1
  description: Ordinary work.
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md]
      budget: { turns: 10, cost: 1.00 }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits: { ticket_cost: 5.00 }
  """

  # The last edge asks for nobody: the job ends, the ticket merges and is done.
  @release """
  version: 1
  description: Cut a release.
  release: true
  initial: releasing
  states:
    releasing:
      prompt: agents/release.md
      produces: [release-notes.md, changeset, commit-message]
      budget: { turns: 10, cost: 1.00 }
    merged:
      on_enter: merge
  transitions:
    - { from: releasing, to: merged }
  limits: { ticket_cost: 5.00 }
  """

  setup do
    data_dir = tmp_dir("release-data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("release-store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    %{worker: FakeWorker.connect()}
  end

  defp project_with(files) do
    repo =
      seeded_repo(
        Map.merge(
          %{
            ".forge/workflow.yml" => nil,
            ".forge/agents/implement.md" => "Do it.\n",
            ".forge/agents/release.md" => "Cut it.\n",
            ".forge/workflows/dev.yml" => @dev,
            ".forge/workflows/release.yml" => @release
          },
          files
        )
      )

    {:ok, project} =
      register_owned!(%{name: "rel-#{System.unique_integer([:positive])}", repo_path: repo})

    %{project: project, bare: repo, admin: member_fixture(project)}
  end

  defp start!(project, admin, note \\ "") do
    {:ok, ticket} = Operator.start_release(project, admin, note)
    ticket
  end

  defp run_pending(worker, ticket, scenario \\ "success", opts) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    {:ok, _job} = FakeWorker.run(job, worker, scenario, opts)
    Tickets.get!(ticket.id)
  end

  defp notes(version) do
    %{"release-notes.md" => "---\noutcome: done\nversion: #{version}\n---\n# Notes\n"}
  end

  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)

  describe "start" do
    test "gives the placeholder title, the note as the body, and the release's type" do
      %{project: project, admin: admin} = project_with(%{})

      ticket = start!(project, admin, "  Fixes only.  \n")

      assert ticket.title == "Release in progress"
      assert ticket.body == "Fixes only."
      assert ticket.ticket_type == "release"
      assert ticket.workflow["release"] == true
      assert ticket.state == "releasing"

      assert %{content: "# Release in progress\n\nFixes only."} =
               Artifacts.latest(ticket.id, "ticket")
    end

    test "with no note the body is empty and the ticket document is the title alone" do
      %{project: project, admin: admin} = project_with(%{})

      for note <- ["", nil, "   "] do
        # One open at a time, so each is concluded before the next.
        ticket = start!(project, admin, note)
        assert ticket.body == ""
        assert %{content: "# Release in progress\n\n"} = Artifacts.latest(ticket.id, "ticket")
        {:ok, _} = Engine.cancel(ticket, {:user, admin.id})
      end
    end

    test "is a project admin's: a member, a stranger and a node admin who is neither are refused" do
      %{project: project} = project_with(%{})
      member = member_fixture(project, :member)

      for user <- [member, user_fixture(), node_admin_fixture()] do
        assert {:error, :forbidden} = Operator.start_release(project, user, "")
      end

      assert Repo.all(Ticket) == []
    end

    test "a note that cannot be a document is refused before anything is written" do
      %{project: project, admin: admin} = project_with(%{})

      assert {:error, {:invalid_note, _why}} = Operator.start_release(project, admin, "a\0b")
      assert Repo.all(Ticket) == []
    end

    test "says why when no workflow sets the flag, when two do, and when the release is broken" do
      %{project: none, admin: admin} =
        project_with(%{
          ".forge/workflows/release.yml" => String.replace(@release, "release: true\n", "")
        })

      assert {:error, :no_release_workflow} = Operator.start_release(none, admin, "")

      %{project: two, admin: admin2} =
        project_with(%{".forge/workflows/dev.yml" => "release: true\n" <> @dev})

      assert {:error, {:several_release_workflows, paths}} =
               Operator.start_release(two, admin2, "")

      assert paths == [".forge/workflows/dev.yml", ".forge/workflows/release.yml"]

      %{project: broken, admin: admin3} =
        project_with(%{".forge/workflows/release.yml" => @release <> "bogus: 1\n"})

      assert {:error, [%ForgeCore.Error{path: "bogus"}]} =
               Operator.start_release(broken, admin3, "")

      assert Repo.all(Ticket) == []
    end

    test "the single file can never be the release" do
      %{project: project, admin: admin} =
        project_with(%{
          ".forge/workflows/dev.yml" => nil,
          ".forge/workflows/release.yml" => nil,
          ".forge/workflow.yml" => @release
        })

      assert {:error, :no_release_workflow} = Operator.start_release(project, admin, "")

      # And it is refused, with the reason, rather than quietly read as an ordinary workflow — and
      # it is not hidden from the ticket form as a release, which nobody could start.
      assert {:ok,
              %{types: [%{release: false, workflow: {:error, [%{path: "release"}]}} = single]}} =
               Tickets.types(project)

      assert {:ok, %{types: [^single]}} = project |> Tickets.types() |> ReleaseTickets.ordinary()
    end

    test "a release that is not YAML at all cannot say it is one, and is not the release" do
      %{project: project, admin: admin} =
        project_with(%{".forge/workflows/release.yml" => "states: [unclosed\n"})

      assert {:error, :no_release_workflow} = Operator.start_release(project, admin, "")
    end

    test "a release cancelled before its version is known keeps the placeholder" do
      %{project: project, admin: admin} = project_with(%{})
      ticket = start!(project, admin)

      {:ok, cancelled} = Engine.cancel(ticket, {:user, admin.id})

      assert {cancelled.status, cancelled.title} == {:cancelled, "Release in progress"}
      assert ReleaseTickets.open(project) == nil
    end

    # One at a time, and the second names the first. The lock that makes this hold under two
    # concurrent starts is the project row's, taken in the same transaction as the check; the
    # sandbox gives every process this test starts the one connection, so two starts cannot be
    # interleaved here and the lock's position is the one mutation no test reaches. What this
    # asserts is the check the lock protects: the second start sees the first.
    test "while one is open another is refused, naming it; a done one does not block" do
      %{project: project, admin: admin} = project_with(%{})
      first = start!(project, admin)

      assert {:error, {:release_open, %Ticket{id: id}}} =
               Operator.start_release(project, admin, "")

      assert id == first.id
      assert length(Tickets.list(project)) == 1

      {:ok, _} = Engine.cancel(first, {:user, admin.id})
      second = start!(project, admin)
      assert second.number == 2
    end

    test "a release open in another project does not block this one" do
      %{project: one, admin: admin_one} = project_with(%{})
      %{project: two, admin: admin_two} = project_with(%{})

      start!(one, admin_one)
      assert {:ok, _} = Operator.start_release(two, admin_two, "")
    end
  end

  describe "open/1" do
    test "counts only a ticket pinned with the flag, in this project, that is active or stuck" do
      %{project: project, admin: admin} = project_with(%{})
      other = project_with(%{})

      # A pin with no key, which is every ticket admitted before the flag: not a release.
      {:ok, ordinary} = Tickets.admit(project, %{title: "x", ticket_type: "dev"})
      refute Map.has_key?(ordinary.workflow, "release")
      assert ReleaseTickets.open(project) == nil

      # The same ticket with the key present and false is not one either.
      ordinary
      |> Ecto.Changeset.change(workflow: Map.put(ordinary.workflow, "release", false))
      |> Repo.update!()

      assert ReleaseTickets.open(project) == nil

      release = start!(other.project, other.admin)
      assert ReleaseTickets.open(project) == nil
      assert %Ticket{id: id} = ReleaseTickets.open(other.project)
      assert id == release.id

      mine = start!(project, admin)
      assert ReleaseTickets.open(project).id == mine.id

      for status <- [:done, :cancelled] do
        mine |> Ecto.Changeset.change(status: status) |> Repo.update!()
        assert ReleaseTickets.open(project) == nil
      end

      mine |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()
      assert ReleaseTickets.open(project).id == mine.id
    end
  end

  describe "the doors that are not Release" do
    test "admission refuses the release type, and a project of nothing else" do
      %{project: project} = project_with(%{})

      assert {:error, {:release_ticket_type, "release"}} =
               Tickets.admit(project, %{title: "x", ticket_type: "release"})

      # With the release taken out, the one ordinary type left is implied.
      assert {:ok, %{ticket_type: "dev"}} = Tickets.admit(project, %{title: "x"})

      %{project: only} = project_with(%{".forge/workflows/dev.yml" => nil})

      assert {:error, {:only_release_types, [".forge/workflows/release.yml"]}} =
               Tickets.admit(only, %{title: "x"})

      assert {:error, {:release_ticket_type, "release"}} =
               Tickets.admit(only, %{title: "x", ticket_type: "release"})
    end

    test "the ordinary listing leaves the release out and says so when nothing is left" do
      %{project: project} = project_with(%{})

      assert {:ok, %{types: [%{name: "dev"}]}} =
               project |> Tickets.types() |> ReleaseTickets.ordinary()

      %{project: only} = project_with(%{".forge/workflows/dev.yml" => nil})

      assert {:error, {:only_release_types, [".forge/workflows/release.yml"]}} =
               only |> Tickets.types() |> ReleaseTickets.ordinary()
    end

    test "status reads the same rule as starting" do
      %{project: project} = project_with(%{})

      assert {:ok, %{name: "release", workflow: {:ok, _}}} =
               project |> Tickets.types() |> ReleaseTickets.status()

      %{project: none} = project_with(%{".forge/workflows/release.yml" => nil})
      assert {:error, :no_release_workflow} = none |> Tickets.types() |> ReleaseTickets.status()

      %{project: two} = project_with(%{".forge/workflows/dev.yml" => "release: true\n" <> @dev})

      assert {:error, {:several_release_workflows, [_, _]}} =
               two |> Tickets.types() |> ReleaseTickets.status()
    end

    test "a release whose YAML parses but does not validate is still the release, shown broken" do
      %{project: project} =
        project_with(%{".forge/workflows/release.yml" => @release <> "bogus: 1\n"})

      assert {:ok, %{name: "release", release: true, workflow: {:error, _}}} =
               project |> Tickets.types() |> ReleaseTickets.status()
    end

    test "a ticket pinned before the flag existed reads as not a release" do
      %{project: project} = project_with(%{})
      {:ok, ticket} = Tickets.admit(project, %{title: "x", ticket_type: "dev"})
      pinned = Map.delete(ticket.workflow, "release")

      assert {:ok, %{release: false}} = Tickets.parsed_workflow(%{ticket | workflow: pinned})
      assert {:ok, %{release: true}} = Parser.from_pinned(Map.put(pinned, "release", true))
    end
  end

  describe "renaming" do
    test "a version in a document's front matter renames the release and says so", %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})
      ticket = release_run(w, start!(project, admin), "0.17.0")

      assert ticket.title == "0.17.0"

      assert %{
               actor: actor,
               payload: %{
                 "from" => "Release in progress",
                 "to" => "0.17.0",
                 "document" => "release-notes.md"
               }
             } = ticket.id |> Events.for_ticket() |> Enum.find(&(&1.type == "ticket.renamed"))

      assert actor["kind"] == "job"

      assert Events.summary(%Events.Event{
               type: "ticket.renamed",
               payload: %{"to" => "0.17.0", "document" => "release-notes.md"}
             }) ==
               "renamed to 0.17.0, from release-notes.md"
    end

    test "a v prefix, a pre-release and build metadata are versions", %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})

      for version <- ["v1.2.3", "1.2.3-rc.1", "1.2.3+build.5"] do
        assert release_run(w, start!(project, admin), version).title == version
      end
    end

    test "the same document on an ordinary ticket renames nothing", %{worker: w} do
      %{project: project} = project_with(%{})
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores", ticket_type: "dev"})

      document = "---\noutcome: done\nversion: 0.17.0\n---\n# Done\n"
      ticket = run_pending(w, ticket, written: %{"implementation.md" => document})

      assert ticket.title == "Persist scores"
      refute "ticket.renamed" in types(ticket)
    end

    test "what is not a version leaves the placeholder, and the job finishes as it would have",
         %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})
      too_long = "1.2.3-" <> String.duplicate("a", 59)
      assert byte_size(too_long) == 65

      # The quoted ones are YAML escapes: a version carrying a newline is not one, and `$` would
      # have let a trailing newline through where `\z` does not.
      for bad <- [
            "<b>1</b>",
            too_long,
            "0.17",
            "latest",
            "release 1.2.3",
            ~S("1.2.3\nx"),
            ~S("1.2.3\n"),
            ~s("1.2.3 ")
          ] do
        ticket = release_run(w, start!(project, admin), bad)

        assert ticket.title == "Release in progress", inspect(bad)
        refute "ticket.renamed" in types(ticket)
        assert ticket.status == :done
      end
    end

    test "a document with no version, and no document at all, leave it", %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})
      ticket = start!(project, admin)

      written = %{
        "release-notes.md" => "---\noutcome: done\n---\n# Notes\n",
        "commit-message" => FakeWorker.commit_message()
      }

      ticket = run_pending(w, ticket, commit: {"VERSION", "x\n"}, written: written)
      assert ticket.title == "Release in progress"
    end

    test "the first document by name wins, and a later one is not looked at", %{worker: w} do
      %{project: project, admin: admin} =
        project_with(%{
          ".forge/workflows/release.yml" =>
            String.replace(@release, "[release-notes.md,", "[release-notes.md, a-notes.md,")
        })

      written = %{
        "release-notes.md" => "---\noutcome: done\nversion: 2.0.0\n---\n",
        "a-notes.md" => "---\nversion: 1.0.0\n---\n",
        "commit-message" => FakeWorker.commit_message()
      }

      ticket =
        run_pending(w, start!(project, admin), commit: {"VERSION", "x\n"}, written: written)

      assert ticket.title == "1.0.0"
    end

    test "a version the title already is renames nothing and records nothing", %{
      worker: w
    } do
      %{project: project, admin: admin} = project_with(%{})
      ticket = start!(project, admin)
      ticket |> Ecto.Changeset.change(title: "0.17.0") |> Repo.update!()

      ticket = release_run(w, Tickets.get!(ticket.id), "0.17.0")
      assert ticket.title == "0.17.0"
      refute "ticket.renamed" in types(ticket)
    end
  end

  describe "concluding is the workflow's" do
    test "a job into on_enter: merge with no approve ends done and merged, nobody taking a step",
         %{worker: w} do
      %{project: project, admin: admin, bare: bare} = project_with(%{})
      ticket = release_run(w, start!(project, admin), "0.17.0")

      assert {ticket.state, ticket.status, ticket.pending_transition} == {"merged", :done, nil}
      assert Forge.Merge.merged?(ticket)
      assert {:ok, "0.17.0\n"} = Git.show(bare, "refs/heads/main", "VERSION")
      assert "ticket.merged" in types(ticket)

      # The admin started it, which is admitting the ticket and writing its ticket document, and nothing else
      # a person did.
      assert ["artifact.version_written", "ticket.admitted"] =
               ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.actor["kind"] == "user"))
               |> Enum.map(& &1.type)
               |> Enum.sort()
    end

    test "a final state that merges nothing ends done", %{worker: w} do
      %{project: project, admin: admin} =
        project_with(%{
          ".forge/workflows/release.yml" =>
            @release
            |> String.replace(
              "[release-notes.md, changeset, commit-message]",
              "[release-notes.md]"
            )
            |> String.replace("  merged:\n    on_enter: merge\n", "  published: {}\n")
            |> String.replace("to: merged", "to: published")
        })

      ticket = run_pending(w, start!(project, admin), written: notes("0.18.0"))

      assert {ticket.state, ticket.status} == {"published", :done}
      assert ticket.title == "0.18.0"
    end

    test "approve on the last edge still waits for a person", %{worker: w} do
      %{project: project, admin: admin} =
        project_with(%{
          ".forge/workflows/release.yml" =>
            String.replace(@release, "to: merged }", "to: merged, approve: [changeset] }")
        })

      ticket = release_run(w, start!(project, admin), "0.19.0")

      assert ticket.state == "releasing"
      assert ticket.status == :active
      assert %{"to" => "merged", "approve" => ["changeset"]} = ticket.pending_transition
      assert ticket.title == "0.19.0"

      {:ok, done} = Operator.decide(ticket, admin, :approved, nil)
      assert {done.state, done.status} == {"merged", :done}
    end

    test "a failed job does not conclude it and keeps the placeholder", %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})
      ticket = run_pending(w, start!(project, admin), "max_turns", [])

      assert ticket.status == :stuck
      assert ticket.state == "releasing"
      assert ticket.title == "Release in progress"
      assert ReleaseTickets.open(project).id == ticket.id
    end
  end

  describe "a release is one for life, whatever the file says now" do
    test "re-pinning an ordinary ticket onto a file that now sets the flag does not make it one",
         %{worker: w} do
      %{project: project, admin: admin} =
        project_with(%{
          ".forge/workflows/release.yml" => String.replace(@release, "release: true\n", "")
        })

      # Admitted the old way, as forge's own release tickets were.
      {:ok, old} = Tickets.admit(project, %{title: "Next release", ticket_type: "release"})
      refute ReleaseTickets.release?(old)
      # A ticket with a job live is not re-pinned; this one's failed.
      old = run_pending(w, old, "max_turns", [])

      commit_to_default(project, %{".forge/workflows/release.yml" => @release <> "# later\n"})

      member = member_fixture(project, :member)
      assert {:ok, repinned} = Operator.repin(old, member)

      assert repinned.workflow_commit != old.workflow_commit
      refute ReleaseTickets.release?(repinned)
      assert {:ok, %{release: false}} = Tickets.parsed_workflow(repinned)
      assert ReleaseTickets.open(project) == nil

      # So a real release can still be started, and a version document does not rename the old one.
      assert {:ok, _} = Operator.start_release(project, admin, "")
    end

    test "re-pinning a release onto a file that dropped the flag leaves it the release", %{
      worker: w
    } do
      %{project: project, admin: admin} = project_with(%{})
      release = run_pending(w, start!(project, admin), "max_turns", [])

      commit_to_default(project, %{
        ".forge/workflows/release.yml" => String.replace(@release, "release: true\n", "")
      })

      assert {:ok, repinned} = Operator.repin(release, admin)

      assert repinned.workflow_commit != release.workflow_commit
      assert ReleaseTickets.release?(repinned)
      assert ReleaseTickets.open(project).id == release.id
    end

    test "restoring a cancelled release while another is open is refused, naming the open one" do
      %{project: project, admin: admin} = project_with(%{})
      first = start!(project, admin)
      {:ok, first} = Engine.cancel(first, {:user, admin.id})
      second = start!(project, admin)

      member = member_fixture(project, :member)
      assert {:error, {:release_open, %Ticket{id: id}}} = Operator.restore(first, member)
      assert id == second.id
      assert Tickets.get!(first.id).status == :cancelled

      # Once the other is over, it comes back as a ticket does, stuck where it was.
      {:ok, _} = Engine.cancel(second, {:user, admin.id})
      assert {:ok, %{status: :stuck}} = Operator.restore(first, member)
      assert ReleaseTickets.open(project).id == first.id
    end

    test "restoring an ordinary ticket is not held up by an open release" do
      %{project: project, admin: admin} = project_with(%{})
      {:ok, ordinary} = Tickets.admit(project, %{title: "x", ticket_type: "dev"})
      {:ok, ordinary} = Engine.cancel(ordinary, {:user, admin.id})
      start!(project, admin)

      assert {:ok, %{status: :stuck}} = Operator.restore(ordinary, admin)
    end

    test "if two are somehow open, the lower number is the one named" do
      %{project: project, admin: admin} = project_with(%{})
      first = start!(project, admin)
      {:ok, first} = Engine.cancel(first, {:user, admin.id})
      second = start!(project, admin)
      first |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()

      assert ReleaseTickets.open(project).id == first.id
      assert second.number == 2
    end
  end

  describe "the plumbing around a start" do
    test "tells the pages watching, once the ticket is committed" do
      %{project: project, admin: admin} = project_with(%{})
      Events.subscribe()

      ticket = start!(project, admin)

      assert_receive {:ticket_changed, id}
      assert id == ticket.id
    end

    test "a version of exactly 64 bytes is a title, and 65 is not", %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})
      exact = "1.2.3-" <> String.duplicate("a", 58)
      assert byte_size(exact) == 64

      assert release_run(w, start!(project, admin), exact).title == exact
    end

    test "the rename event names the job that wrote the document", %{worker: w} do
      %{project: project, admin: admin} = project_with(%{})
      ticket = release_run(w, start!(project, admin), "0.20.0")

      [job] = Jobs.for_ticket(ticket.id)
      event = ticket.id |> Events.for_ticket() |> Enum.find(&(&1.type == "ticket.renamed"))
      assert event.job_id == job.id
    end

    test "release?/1 is true of a pin that says true and of nothing else" do
      for {pin, expected} <- [
            {%{"release" => true}, true},
            {%{"release" => false}, false},
            {%{"release" => "true"}, false},
            {%{"release" => 1}, false},
            {%{}, false}
          ] do
        assert ReleaseTickets.release?(%Ticket{workflow: pin}) == expected, inspect(pin)
      end
    end

    test "ordinary/1 leaves a listing with no types as it found it" do
      listing = {:ok, %{form: :single, types: [], not_types: []}}
      assert ReleaseTickets.ordinary(listing) == listing
    end
  end

  # The agent's whole run on a release: commits the version and writes notes saying it.
  defp release_run(worker, ticket, version) do
    written = Map.put(notes(version), "commit-message", FakeWorker.commit_message())
    run_pending(worker, ticket, commit: {"VERSION", "#{version}\n"}, written: written)
  end
end
