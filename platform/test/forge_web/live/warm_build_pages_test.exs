defmodule ForgeWeb.WarmBuildPagesTest do
  @moduledoc """
  What a person sees of a ticket's warm build (`docs/design/ui.md` § The details, § The job page,
  § A job waiting for a machine): the details' block and its Clear, a command's two facts and its
  wait, and the Tickets row of a command that waits for the machine holding the copy.

  The copy is made as the platform holds one — a finished command with its `warm_*` columns — so
  these tests read the pages and not the recording (`Forge.WarmBuilds` has its own).
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Projects, Repo, Tickets}
  alias Forge.Jobs.Job

  @keeping """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      produces: build.log
      timeout: 20m
      keep_build: [0, 1]
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 3 }
      budget: { turns: 20, tokens: 400k }
    done: {}
  transitions:
    - { from: implementing, to: done }
  limits:
    ticket_tokens: 5M
  """

  @plain String.replace(@keeping, "    keep_build: [0, 1]\n", "")

  @no_copy "No warm build yet: the first command that keeps its build leaves one."

  @wait "Waiting for the machine that holds this ticket's warm build: up to two minutes, " <>
          "then any machine with room."

  setup :register_and_log_in_user

  setup do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)
    %{worker: FakeWorker.connect()}
  end

  defp ticket_on(workflow, user) do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => workflow,
        ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
      })

    {:ok, project} =
      Projects.register(
        %{name: "wb-#{System.unique_integer([:positive])}", repo_path: repo},
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Build it"}, {:user, user.id})
    {project, ticket}
  end

  defp page(project, ticket, rest \\ ""), do: "/tickets/#{project.name}/#{ticket.number}" <> rest

  # The agent invokes `build` once for each list of arguments, which is how a ticket has commands:
  # the jobs come back oldest first, all pending.
  defp invoke_builds(ticket, worker, args_lists) do
    [job] = Jobs.for_ticket(ticket.id)
    invocations = Enum.map(args_lists, &%{"command" => "build", "args" => &1})
    {:ok, _parked} = FakeWorker.park(FakeWorker.assign(job, worker), invocations)
    ticket |> then(&Jobs.commands_for_ticket(&1.id)) |> Enum.sort_by(& &1.attempt)
  end

  defp invoke_build(ticket, worker, args) do
    [command] = invoke_builds(ticket, worker, [args])
    command
  end

  defp finish_with(command, worker, status, warm) do
    {:ok, _} = command |> FakeWorker.assign(worker) |> FakeWorker.finish_command(status)
    Repo.update_all(from_job(command), set: warm)
    Jobs.get!(command.id)
  end

  defp from_job(command), do: from(j in Job, where: j.id == ^command.id)

  defp kept(size),
    do: [warm_epoch: 0, warm_source: "clone", warm_kept: true, warm_size: size]

  describe "the ticket's details" do
    test "draw no block at all when no command declares keep_build", %{conn: conn, user: user} do
      {project, ticket} = ticket_on(@plain, user)
      {:ok, view, html} = live(conn, page(project, ticket))

      refute html =~ "Warm build"
      refute has_element?(view, "#ticket-warm-build")
    end

    test "say there is none, in the exact words, until a command keeps its build", %{
      conn: conn,
      user: user
    } do
      {project, ticket} = ticket_on(@keeping, user)
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#ticket-warm-build", "Warm build")
      assert view |> element("#warm-build-none") |> render() =~ @no_copy
      refute has_element?(view, "#warm-build-copies")
      refute has_element?(view, "#clear-warm-build-ask")
    end

    test "show the copy the next command goes to, its arguments as text", %{
      conn: conn,
      user: user,
      worker: worker
    } do
      {project, ticket} = ticket_on(@keeping, user)
      command = invoke_build(ticket, worker, ["<b>x</b>", "a b"])
      done = finish_with(command, worker, 0, kept(5_242_880))
      {:ok, view, _html} = live(conn, page(project, ticket))

      refute has_element?(view, "#warm-build-none")
      block = view |> element("#ticket-warm-build") |> render()
      assert block =~ "5 MB"
      assert block =~ "machine " <> String.slice(done.worker_id, 0, 8)
      assert block =~ "build"
      assert block =~ String.slice(Jobs.spec(done).command["at"], 0, 12)
      assert block =~ "just now"

      # JSON, so `a b` is visibly one argument, and the markup is text and not an element.
      assert block =~ "[&quot;&lt;b&gt;x&lt;/b&gt;&quot;,&quot;a b&quot;]"
      refute block =~ "<b>x</b>"

      # Long values wrap on a phone rather than push the page sideways.
      assert has_element?(view, "#warm-build-machine-#{done.id}.break-all")
      assert has_element?(view, "#warm-build-command-#{done.id}.break-all")
      assert has_element?(view, "#clear-warm-build-ask", "Clear")

      # The way into the explorer, and the mark of the copy the next command starts from.
      assert has_element?(
               view,
               ~s(#warm-build-explore-#{done.id}[href$="/builds/#{done.id}"]),
               "Explore"
             )

      assert has_element?(view, "#warm-build-next-#{done.id}", "next command starts here")
    end

    test "list every kept copy, one row per machine, the one the next command starts from first",
         %{conn: conn, user: user, worker: worker} do
      {project, ticket} = ticket_on(@keeping, user)
      other = FakeWorker.connect()
      [first, second] = invoke_builds(ticket, worker, [[], ["--other"]])
      earlier = [finished_at: DateTime.add(DateTime.utc_now(:second), -600)]
      first = finish_with(first, worker, 0, kept(1_024) ++ earlier)
      second = finish_with(second, other, 0, kept(2_048))
      {:ok, view, _html} = live(conn, page(project, ticket))

      html = view |> element("#warm-build-copies") |> render()
      {at_first, _} = :binary.match(html, "warm-build-copy-#{first.id}")
      {at_second, _} = :binary.match(html, "warm-build-copy-#{second.id}")

      # The later command's copy is the one the next command is sent to, so it is listed first.
      assert at_second < at_first
      assert has_element?(view, "#warm-build-next-#{second.id}")
      refute has_element?(view, "#warm-build-next-#{first.id}")
      refute has_element?(view, "#warm-build-cleared-#{first.id}")

      assert has_element?(
               view,
               "#warm-build-machine-#{first.id}",
               "machine " <> String.slice(worker.id, 0, 8)
             )

      assert has_element?(
               view,
               "#warm-build-machine-#{second.id}",
               "machine " <> String.slice(other.id, 0, 8)
             )

      assert has_element?(view, "#warm-build-explore-#{first.id}")
      assert has_element?(view, "#warm-build-explore-#{second.id}")
      assert has_element?(view, "#clear-warm-build-ask", "Clear")
    end

    test "Clear makes the copy unusable: it stays listed, marked cleared, and is no longer next",
         %{conn: conn, user: user, worker: worker} do
      {project, ticket} = ticket_on(@keeping, user)
      done = finish_with(invoke_build(ticket, worker, []), worker, 0, kept(1_024))
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#warm-build-copy-#{done.id}")
      refute has_element?(view, "#warm-build-cleared-#{done.id}")

      view |> element("#clear-warm-build") |> render_click()

      assert Tickets.get!(ticket.id).warm_epoch == 1
      assert has_element?(view, "#warm-build-cleared-#{done.id}", "cleared")
      refute has_element?(view, "#warm-build-next-#{done.id}")
      # Nothing left to clear.
      refute has_element?(view, "#clear-warm-build-ask")
    end

    test "a copy a clear made unusable is drawn as cleared when the page is opened", %{
      conn: conn,
      user: user,
      worker: worker
    } do
      {project, ticket} = ticket_on(@keeping, user)
      done = finish_with(invoke_build(ticket, worker, []), worker, 0, kept(1_024))
      {:ok, _ticket} = Forge.WarmBuilds.clear(Tickets.get!(ticket.id), {:user, user.id})
      {:ok, view, _html} = live(conn, page(project, ticket))

      refute has_element?(view, "#warm-build-none")
      assert has_element?(view, "#warm-build-cleared-#{done.id}", "cleared")
    end
  end

  describe "a command's page" do
    test "shows where its tree came from and whether its build was kept", %{
      conn: conn,
      user: user,
      worker: worker
    } do
      {project, ticket} = ticket_on(@keeping, user)
      first = finish_with(invoke_build(ticket, worker, []), worker, 0, kept(2_048))

      {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{first.id}"))
      assert view |> element("#job-warm-source") |> render() =~ "started from a fresh clone"

      assert view |> element("#job-warm-kept") |> render() =~
               "kept as this ticket&#39;s warm build"

      assert view |> element("#job-warm-kept") |> render() =~ "2 KB"
      refute has_element?(view, "#job-warm-from")
    end

    test "names the command that left the warm copy it started from, with the reason it kept none",
         %{conn: conn, user: user, worker: worker} do
      {project, ticket} = ticket_on(@keeping, user)
      [first, second] = invoke_builds(ticket, worker, [[], []])
      first = finish_with(first, worker, 0, kept(2_048))

      Repo.update_all(from_job(second),
        set: [
          warm_source: "copy",
          warm_from_id: first.id,
          warm_kept: false,
          warm_unkept: "timeout"
        ]
      )

      {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{second.id}"))
      source = view |> element("#job-warm-source") |> render()
      assert source =~ "started from this ticket&#39;s warm build"
      assert has_element?(view, ~s(#job-warm-from[href$="/jobs/#{first.id}"]), "left by build")

      assert view |> element("#job-warm-kept") |> render() =~
               "not kept as this ticket&#39;s warm build: it was stopped by its timeout"
    end

    test "shows neither when the worker reported nothing", %{
      conn: conn,
      user: user,
      worker: worker
    } do
      {project, ticket} = ticket_on(@keeping, user)
      command = invoke_build(ticket, worker, [])
      {:ok, _} = command |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0)

      {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{command.id}"))
      refute has_element?(view, "#job-warm-source")
      refute has_element?(view, "#job-warm-kept")
    end

    test "reads the warm wait's sentence while it waits, and another wait in the scheduler's words",
         %{conn: conn, user: user, worker: worker} do
      {project, ticket} = ticket_on(@keeping, user)
      command = invoke_build(ticket, worker, [])
      :ok = Jobs.record_wait(command, "warm", "scheduler's own text")

      {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{command.id}"))
      assert has_element?(view, "#job-wait", @wait)

      :ok = Jobs.record_wait(command, "at_capacity", "Waiting for room: busy")
      html = render(view)
      assert has_element?(view, "#job-wait", "Waiting for room: busy")
      refute html =~ @wait
    end
  end

  describe "the Tickets row" do
    test "reads the warm wait's sentence as its latest line while the command waits for it", %{
      conn: conn,
      user: user,
      worker: worker
    } do
      {project, ticket} = ticket_on(@keeping, user)
      command = invoke_build(ticket, worker, [])
      :ok = Jobs.record_wait(command, "warm", "scheduler's own text")

      {:ok, view, _html} = live(conn, "/projects/#{project.name}")
      row = "#tickets-rest-#{ticket.number}"
      assert has_element?(view, row <> " .ui-row-latest", @wait)
      assert has_element?(view, row <> " .ticket-doing", "waiting for a machine")
    end

    test "keeps every other wait as waiting for a machine alone", %{
      conn: conn,
      user: user,
      worker: worker
    } do
      {project, ticket} = ticket_on(@keeping, user)
      command = invoke_build(ticket, worker, [])
      :ok = Jobs.record_wait(command, "at_capacity", "Waiting for room: busy")

      {:ok, view, html} = live(conn, "/projects/#{project.name}")

      assert has_element?(
               view,
               "#tickets-rest-#{ticket.number} .ticket-doing",
               "waiting for a machine"
             )

      refute html =~ @wait
    end
  end
end
