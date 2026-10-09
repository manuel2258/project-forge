defmodule Forge.TicketTypesTest do
  @moduledoc """
  Ticket types and the libraries they import (`docs/design/ticket-types.md`), from the platform's
  side: what admission reads from the repository and what it pins.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.Tickets

  @library """
  commands:
    build: { run: .forge/commands/build.sh, produces: build.log, timeout: 20m }
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      budget: { turns: 20, cost: 2.00 }
  """

  @importing """
  version: 1
  import: [common.yml]
  initial: implementing
  states:
    implementing:
      extends: implementing
      inputs: [ticket]
    checking:
      invoke: [build]
      exit: { 0: done, "*": failed }
    review_ready: {}
  transitions:
    - { from: implementing, to: checking }
    - { from: checking, to: review_ready }
  limits:
    ticket_cost: 25.00
  """

  @bug """
  version: 1
  description: Something that worked and does not.
  import: [common.yml]
  initial: reproducing
  states:
    reproducing:
      prompt: agents/reproduce.md
      inputs: [ticket]
      produces: [reproduction.md]
      budget: { turns: 5, cost: 1.00 }
    implementing:
      extends: implementing
      inputs: [ticket, reproduction.md]
    review_ready: {}
  transitions:
    - { from: reproducing, to: implementing }
    - { from: implementing, to: review_ready }
  limits: { ticket_cost: 8.00 }
  """

  @feature """
  version: 1
  description: Something new.
  import: [common.yml]
  initial: implementing
  states:
    implementing:
      extends: implementing
      inputs: [ticket]
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits: { ticket_cost: 25.00 }
  """

  # A project in the directory form: no single file, a library, two types and their prompts.
  defp typed_project(extra \\ %{}) do
    project_with(
      Map.merge(
        %{
          ".forge/workflow.yml" => nil,
          ".forge/common.yml" => @library,
          ".forge/agents/reproduce.md" => "Reproduce it.\n",
          ".forge/workflows/bug.yml" => @bug,
          ".forge/workflows/feature.yml" => @feature
        },
        extra
      )
    )
  end

  defp project_with(files) do
    repo =
      seeded_repo(Map.merge(%{".forge/commands/build.sh" => "#!/bin/sh\nexec make\n"}, files))

    {:ok, project} =
      register_owned!(%{name: "types-#{System.unique_integer([:positive])}", repo_path: repo})

    project
  end

  describe "imports at admission" do
    # A ticket's workflow is read back with `Parser.from_map/2` and no repository, on every read —
    # the board, the queue, the engine. A pinned map that still said `import` could be read nowhere.
    test "what is pinned is the definition with its imports resolved" do
      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => @library})

      assert {:ok, ticket} = Tickets.admit(project, %{title: "Fix the save"})

      refute Map.has_key?(ticket.workflow, "import")
      refute Map.has_key?(ticket.workflow["states"]["implementing"], "extends")
      assert ticket.workflow["commands"]["build"]["run"] == ".forge/commands/build.sh"

      {:ok, workflow} = Tickets.parsed_workflow(Tickets.get!(ticket.id))
      assert workflow.states["implementing"].prompt == "agents/implement.md"
      assert workflow.states["implementing"].inputs == ["ticket"]
    end

    test "a library is read at the commit the workflow is, under .forge/" do
      project = project_with(%{".forge/workflow.yml" => @importing, "common.yml" => @library})

      assert {:error, [%ForgeCore.Error{path: "import[0]", message: message}]} =
               Tickets.admit(project, %{title: "Fix the save"})

      assert message =~ "does not exist at this commit"
    end

    test "a mistake in a library is refused, naming the library" do
      broken = String.replace(@library, "turns: 20", "turns: 0")

      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => broken})

      assert {:error, errors} = Tickets.admit(project, %{title: "Fix the save"})

      assert ForgeCore.Error.format(errors) =~
               "common.yml: states.implementing.budget.turns: must be a positive integer"

      assert {:ok, %{types: [%{name: nil, workflow: {:error, [_ | _]}}]}} = Tickets.types(project)
    end
  end

  describe "admitting by type" do
    test "a type is required when there is more than one, and nothing is chosen for you" do
      project = typed_project()

      assert Tickets.admit(project, %{title: "x"}) ==
               {:error, {:ticket_type_required, ["bug", "feature"]}}

      # A form's untouched select sends an empty string, which is no choice either.
      assert Tickets.admit(project, %{title: "x", ticket_type: ""}) ==
               {:error, {:ticket_type_required, ["bug", "feature"]}}
    end

    test "the chosen type's workflow is what is pinned, and the ticket says which" do
      project = typed_project()

      assert {:ok, ticket} =
               Tickets.admit(project, %{title: "Save loses slot", ticket_type: "bug"})

      assert ticket.ticket_type == "bug"
      assert ticket.state == "reproducing"
      assert ticket.workflow["limits"]["ticket_cost"] == 8.0

      assert %{payload: %{"ticket_type" => "bug"}} =
               ticket.id
               |> Forge.Events.for_ticket()
               |> Enum.find(&(&1.type == "ticket.admitted"))

      assert {:ok, feature} = Tickets.admit(project, %{title: "Co-op", ticket_type: "feature"})
      assert {feature.ticket_type, feature.state} == {"feature", "implementing"}
    end

    test "a type the project does not have is refused, naming the ones it has" do
      assert Tickets.admit(typed_project(), %{title: "x", ticket_type: "chore"}) ==
               {:error, {:unknown_ticket_type, "chore", ["bug", "feature"]}}
    end

    test "a type that is not a string is refused as not a name" do
      for odd <- [%{"a" => 1}, ["bug"], 3] do
        assert Tickets.admit(typed_project(), %{title: "x", ticket_type: odd}) ==
                 {:error, {:invalid_ticket_type, :not_a_name}}
      end
    end

    test "one type in the directory is implied" do
      project = typed_project(%{".forge/workflows/feature.yml" => nil})

      assert {:ok, %{ticket_type: "bug", state: "reproducing"}} =
               Tickets.admit(project, %{title: "x"})
    end

    test "the single file has no types: none is recorded, and naming one is refused" do
      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => @library})

      assert {:ok, %{ticket_type: nil}} = Tickets.admit(project, %{title: "x"})

      assert Tickets.admit(project, %{title: "x", ticket_type: "bug"}) ==
               {:error, {:no_ticket_types, "bug"}}
    end

    # Only a `.yml` file says the author meant the directory form; notes beside the single file
    # do not make a project with both.
    test "a file in workflows/ that is not a .yml leaves the single file in charge" do
      project =
        project_with(%{
          ".forge/workflow.yml" => @importing,
          ".forge/common.yml" => @library,
          ".forge/workflows/README.md" => "later\n"
        })

      assert {:ok, %{ticket_type: nil}} = Tickets.admit(project, %{title: "x"})
    end

    test "both forms at once is refused, because nothing says which wins" do
      project = typed_project(%{".forge/workflow.yml" => @importing})

      assert Tickets.admit(project, %{title: "x", ticket_type: "bug"}) ==
               {:error, {:both_workflow_forms, ".forge/workflow.yml", ".forge/workflows/"}}

      assert Tickets.types(project) ==
               {:error, {:both_workflow_forms, ".forge/workflow.yml", ".forge/workflows/"}}
    end

    test "a broken type is offered broken, and the others still admit" do
      project = typed_project(%{".forge/workflows/feature.yml" => "version: 1\n"})

      assert {:ok, %{form: :types, types: [bug, feature]}} = Tickets.types(project)

      assert {%{name: "bug", workflow: {:ok, _}}, %{name: "feature", workflow: {:error, _}}} =
               {bug, feature}

      assert {:ok, %{ticket_type: "bug"}} =
               Tickets.admit(project, %{title: "x", ticket_type: "bug"})

      assert {:error, [_ | _]} = Tickets.admit(project, %{title: "x", ticket_type: "feature"})
    end
  end

  describe "what is in the directory and is not a type" do
    test "is reported, with why, and blocks nothing" do
      project =
        typed_project(%{
          ".forge/workflows/README.md" => "notes\n",
          ".forge/workflows/chore.yaml" => @feature,
          ".forge/workflows/-x.yml" => @feature,
          ".forge/workflows/old/bug.yml" => @bug
        })

      assert {:ok, %{types: types, not_types: not_types}} = Tickets.types(project)
      assert Enum.map(types, & &1.name) == ["bug", "feature"]

      assert [
               {".forge/workflows/-x.yml", "\"-x\" is not a type name" <> _},
               {".forge/workflows/README.md", "not a .yml file"},
               {".forge/workflows/chore.yaml", "not a .yml file"},
               {".forge/workflows/old", "a directory" <> _}
             ] = Enum.map(not_types, &{&1.path, &1.why})

      assert {:ok, _ticket} = Tickets.admit(project, %{title: "x", ticket_type: "bug"})
    end

    # What the author put there, and why it is not a type, is the answer — not a sentence about a
    # `workflow.yml` they never meant to write.
    test "a directory with no type in it, and no single file, says what it holds and why" do
      project =
        project_with(%{".forge/workflow.yml" => nil, ".forge/workflows/Bug Fix.yml" => @bug})

      assert {:error,
              {:no_ticket_type_in, ".forge/workflows/",
               [%{path: ".forge/workflows/Bug Fix.yml", why: why}]} = reason} =
               Tickets.admit(project, %{title: "x"})

      assert why =~ "is not a type name"
      assert Tickets.types(project) == {:error, reason}

      assert ForgeWeb.Operator.Admission.explain(reason) =~
               "there is no .forge/workflow.yml, and nothing in .forge/workflows/ is a ticket " <>
                 "type: .forge/workflows/Bug Fix.yml is "
    end

    test "an empty directory and no single file is no workflow" do
      project = project_with(%{".forge/workflow.yml" => nil})

      assert Tickets.admit(project, %{title: "x"}) ==
               {:error, {:no_workflow_file, ".forge/workflow.yml"}}
    end

    # A stray file blocks nothing: beside the single file it is reported, not taken for the
    # directory form, which would have refused every admission as "both".
    test "a stray .yml beside the single file leaves the single file in charge" do
      project =
        project_with(%{
          ".forge/workflow.yml" => @importing,
          ".forge/common.yml" => @library,
          ".forge/workflows/Bug Fix.yml" => @bug
        })

      assert {:ok, %{ticket_type: nil}} = Tickets.admit(project, %{title: "x"})

      assert {:ok, %{form: :single, not_types: [%{path: ".forge/workflows/Bug Fix.yml"}]}} =
               Tickets.types(project)
    end

    test "a file whose name ends in a newline is not a type" do
      project = typed_project(%{".forge/workflows/feature\n.yml" => @feature})

      assert {:ok, %{types: types, not_types: [%{path: ".forge/workflows/feature\n.yml"}]}} =
               Tickets.types(project)

      assert Enum.map(types, & &1.name) == ["bug", "feature"]

      assert {:error, {:unknown_ticket_type, "feature\n", _names}} =
               Tickets.admit(project, %{title: "x", ticket_type: "feature\n"})
    end

    # A file named like a type but not a regular file. `ls-tree` reports a link as a blob of mode
    # 120000; reading it would hand the parser the link's target as text.
    test "a symbolic link is not a type" do
      repo = typed_project().repo_path
      work = Path.join(tmp_dir("link"), "work")
      {:ok, _} = Forge.Git.run(Path.dirname(work), ["clone", "-q", repo, work])
      File.ln_s!("bug.yml", Path.join(work, ".forge/workflows/alias.yml"))
      {:ok, _} = Forge.Git.run(work, ["add", "-A"])

      {:ok, _} =
        Forge.Git.run(work, ["-c", "user.name=t", "-c", "user.email=t@f", "commit", "-qm", "l"])

      {:ok, sha} = Forge.Git.run(work, ["rev-parse", "HEAD"])

      assert {:ok, %{types: types, not_types: [%{path: ".forge/workflows/alias.yml", why: why}]}} =
               Forge.TicketTypes.layout(work, String.trim(sha))

      assert why == "a symbolic link, not a file"
      assert Enum.map(types, & &1.name) == ["bug", "feature"]
    end

    # A submodule is a commit in the tree, under whatever name it was given.
    test "a submodule is not a type" do
      repo = typed_project().repo_path
      work = Path.join(tmp_dir("submodule"), "work")
      {:ok, _} = Forge.Git.run(Path.dirname(work), ["clone", "-q", repo, work])
      {:ok, head} = Forge.Git.run(work, ["rev-parse", "HEAD"])
      gitlink = "160000,#{String.trim(head)},.forge/workflows/vendored.yml"
      {:ok, _} = Forge.Git.run(work, ["update-index", "--add", "--cacheinfo", gitlink])

      {:ok, _} =
        Forge.Git.run(work, ["-c", "user.name=t", "-c", "user.email=t@f", "commit", "-qm", "s"])

      {:ok, sha} = Forge.Git.run(work, ["rev-parse", "HEAD"])

      assert {:ok,
              %{types: types, not_types: [%{path: ".forge/workflows/vendored.yml", why: why}]}} =
               Forge.TicketTypes.layout(work, String.trim(sha))

      assert why == "not a file"
      assert Enum.map(types, & &1.name) == ["bug", "feature"]
    end
  end

  describe "re-pinning" do
    test "reads the ticket's own type, and never changes it" do
      project = typed_project()
      {:ok, ticket} = Tickets.admit(project, %{title: "x", ticket_type: "bug"})

      head =
        commit_to_default(project, %{
          ".forge/workflows/bug.yml" =>
            String.replace(@bug, "ticket_cost: 8.00", "ticket_cost: 9.00")
        })

      assert {:ok, prepared} = Tickets.prepare_repin(project, ticket)
      assert {prepared.base, prepared.ticket_type} == {head, "bug"}
      assert prepared.yaml_map["limits"]["ticket_cost"] == 9.0
    end

    # Admitted, then its first job writes nothing it declared and ends in `error`; with no edge for
    # that the ticket is stuck with nothing live — the state a re-pin is for.
    defp stuck(project, attrs) do
      funded!(project)
      user = member_fixture(project)
      store = Application.get_env(:forge, Forge.Storage, [])
      Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
      on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

      {:ok, ticket} = Tickets.admit(project, Map.put(attrs, :title, "x"))
      [job] = Forge.Jobs.for_ticket(ticket.id)
      {:ok, _job} = Forge.FakeWorker.run(job, Forge.FakeWorker.connect())
      assert %{status: :stuck} = ticket = Tickets.get!(ticket.id)
      {ticket, user}
    end

    test "Engine.repin/2 pins the ticket's own type's file" do
      project = typed_project()
      {ticket, user} = stuck(project, %{ticket_type: "bug"})

      commit_to_default(project, %{
        ".forge/workflows/bug.yml" =>
          String.replace(@bug, "ticket_cost: 8.00", "ticket_cost: 9.00")
      })

      assert {:ok, repinned} = Forge.Engine.repin(ticket, user.id)
      assert repinned.workflow["limits"]["ticket_cost"] == 9.0
    end

    # The guess the refusal is there to prevent: a single file's ticket on a project now with one
    # type would otherwise be pinned to that type's workflow, with no type on its record.
    test "Engine.repin/2 refuses a single file's ticket once the project has moved to types" do
      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => @library})

      {ticket, user} = stuck(project, %{})

      commit_to_default(project, %{
        ".forge/workflow.yml" => nil,
        ".forge/workflows/feature.yml" => @feature
      })

      assert Forge.Engine.repin(ticket, user.id) ==
               {:error, {:ticket_type_gone, nil, ".forge/workflow.yml"}}
    end

    test "a typed ticket refuses once the project has gone back to the single file" do
      project = typed_project()
      {:ok, ticket} = Tickets.admit(project, %{title: "x", ticket_type: "bug"})

      commit_to_default(project, %{
        ".forge/workflows/bug.yml" => nil,
        ".forge/workflows/feature.yml" => nil,
        ".forge/workflow.yml" => @importing
      })

      assert Tickets.prepare_repin(project, ticket) ==
               {:error, {:ticket_type_gone, "bug", ".forge/workflows/bug.yml"}}
    end

    test "a type whose file is gone refuses, naming the file" do
      project = typed_project()
      {:ok, ticket} = Tickets.admit(project, %{title: "x", ticket_type: "bug"})
      commit_to_default(project, %{".forge/workflows/bug.yml" => nil})

      assert Tickets.prepare_repin(project, ticket) ==
               {:error, {:ticket_type_gone, "bug", ".forge/workflows/bug.yml"}}
    end

    test "a ticket from the single file refuses once the project has moved to types" do
      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => @library})

      {:ok, ticket} = Tickets.admit(project, %{title: "x"})

      commit_to_default(project, %{
        ".forge/workflow.yml" => nil,
        ".forge/workflows/feature.yml" => @feature
      })

      assert Tickets.prepare_repin(project, ticket) ==
               {:error, {:ticket_type_gone, nil, ".forge/workflow.yml"}}
    end
  end

  describe "drift" do
    test "another type's file changing is not this ticket's, its own and a library are" do
      project = typed_project()
      {:ok, ticket} = Tickets.admit(project, %{title: "x", ticket_type: "bug"})

      commit_to_default(project, %{
        ".forge/workflows/feature.yml" => String.replace(@feature, "25.00", "30.00")
      })

      assert Tickets.drift(ticket, project) == nil

      commit_to_default(project, %{".forge/common.yml" => @library <> "\n"})
      assert %{paths: [".forge/common.yml"]} = Tickets.drift(ticket, project)

      commit_to_default(project, %{".forge/workflows/bug.yml" => @bug <> "\n"})

      assert %{paths: [".forge/common.yml", ".forge/workflows/bug.yml"]} =
               Tickets.drift(ticket, project)
    end
  end

  describe "accepting a proposal" do
    defp proposed(project, front_matter) do
      user = user_fixture()
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      version =
        proposal_fixture(%{
          job: job,
          content: front_matter <> "# Lost slot\n\nSaving twice loses it."
        })

      {user, version}
    end

    test "takes the type the proposal suggests when the person names none" do
      project = typed_project()
      {user, version} = proposed(project, "---\ntype: bug\n---\n")

      assert {:ok, ticket} = Forge.Proposals.accept(version.id, user.id)
      assert {ticket.ticket_type, ticket.state} == {"bug", "reproducing"}

      # The suggestion is the proposal's; the ticket's body is the title and body alone.
      assert {ticket.title, ticket.body} == {"Lost slot", "Saving twice loses it."}

      assert %{content: "# Lost slot\n\nSaving twice loses it."} =
               Forge.Artifacts.latest(ticket.id, "ticket")
    end

    # The page's select sends the suggestion preselected; to send nothing a person has to choose
    # nothing, and that is not taken as the suggestion.
    test "a type chosen as none is not the suggestion" do
      project = typed_project()
      {user, version} = proposed(project, "---\ntype: bug\n---\n")

      assert Forge.Proposals.accept(version.id, user.id, nil, "") ==
               {:error, {:ticket_type_required, ["bug", "feature"]}}
    end

    test "the person's type wins over the suggestion" do
      project = typed_project()
      {user, version} = proposed(project, "---\ntype: bug\n---\n")

      assert {:ok, %{ticket_type: "feature"}} =
               Forge.Proposals.accept(version.id, user.id, nil, "feature")
    end

    test "a suggestion that is not a type now is no suggestion" do
      project = typed_project()
      {user, version} = proposed(project, "---\ntype: chore\n---\n")

      assert Forge.Proposals.accept(version.id, user.id) ==
               {:error, {:ticket_type_required, ["bug", "feature"]}}

      # And nothing was decided: the proposal is still open to be accepted with a type.
      assert Forge.Proposals.decision(version.id) == nil

      assert {:ok, %{ticket_type: "bug"}} =
               Forge.Proposals.accept(version.id, user.id, nil, "bug")
    end

    test "with no suggestion, a project with several types asks for one" do
      {user, version} = proposed(typed_project(), "")

      assert Forge.Proposals.accept(version.id, user.id) ==
               {:error, {:ticket_type_required, ["bug", "feature"]}}
    end

    test "on the single file a suggestion is ignored" do
      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => @library})

      {user, version} = proposed(project, "---\ntype: bug\n---\n")

      assert {:ok, %{ticket_type: nil}} = Forge.Proposals.accept(version.id, user.id)
    end

    test "a suggestion is kept in what is stored, so accepting can read it" do
      job = job_fixture(%{ticket: ticket_fixture(%{project: typed_project()})})
      proposal = ForgeCore.Proposal.parse!("---\ntype: bug\n---\n# Lost slot\n\nWhy.")

      {:ok, _changes} =
        Ecto.Multi.new()
        |> Forge.Proposals.put_from_result(job, %{"lost-slot.md" => proposal}, %{})
        |> Repo.transaction()

      assert [%{version: %{content: content}}] = Forge.Proposals.open(job.project_id)
      assert content == "---\ntype: bug\n---\n# Lost slot\n\nWhy."
    end
  end

  describe "what a job is told" do
    test "the backlog lists the types, and each ticket's" do
      project = typed_project()
      {:ok, _bug} = Tickets.admit(project, %{title: "Lost slot", ticket_type: "bug"})

      %{"index" => index, "tickets" => [%{"content" => file}]} = Forge.Backlog.compose(project)

      assert index =~ "## Ticket types"
      assert index =~ "| bug | reproducing | Something that worked and does not. |"
      assert index =~ "| feature | implementing | Something new. |"
      assert index =~ "| # | type | state | status | title |"
      assert index =~ "| 1 | bug | reproducing | active | Lost slot |"
      assert file =~ "<!-- ticket 1 · bug · reproducing · active · ticket/1 -->"
    end

    # Every assignment composes the backlog, so a library the parser could not read used to fail
    # every job of the project, chats included. An empty section is the natural way to write one.
    test "a library with an empty section is read, and the backlog composes" do
      project = typed_project(%{".forge/common.yml" => @library <> "defaults:\n"})

      %{"index" => index} = Forge.Backlog.compose(project)
      assert index =~ "| bug | reproducing |"

      assert {:ok, %{ticket_type: "bug"}} =
               Tickets.admit(project, %{title: "x", ticket_type: "bug"})
    end

    test "a broken type is listed as broken, so a job does not suggest it blind" do
      project = typed_project(%{".forge/workflows/feature.yml" => "version: 1\n"})
      %{"index" => index} = Forge.Backlog.compose(project)
      assert index =~ "| feature | — | (its workflow does not parse) |"
    end

    test "the single file says nothing about types" do
      project =
        project_with(%{".forge/workflow.yml" => @importing, ".forge/common.yml" => @library})

      {:ok, _ticket} = Tickets.admit(project, %{title: "Lost slot"})

      %{"index" => index, "tickets" => [%{"content" => file}]} = Forge.Backlog.compose(project)

      refute index =~ "Ticket types"
      assert index =~ "| # | state | status | title |"
      assert file =~ "<!-- ticket 1 · implementing · active · ticket/1 -->"
    end

    test "a job's spec names its ticket's type" do
      {:ok, ticket} = Tickets.admit(typed_project(), %{title: "x", ticket_type: "bug"})
      [job] = Forge.Jobs.for_ticket(ticket.id)
      assert Forge.Jobs.spec(job).ticket.ticket_type == "bug"
    end
  end
end
