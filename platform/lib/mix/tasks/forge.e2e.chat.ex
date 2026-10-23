defmodule Mix.Tasks.Forge.E2e.Chat do
  @shortdoc "Drives a whole conversation against a live node and asserts what happened"

  @moduledoc """
  The end-to-end check for conversations, run by `bin/e2e-chat`.

      mix forge.e2e.chat PROJECT --node forge@host

  It talks to a real worker running a real harness and asserts on rows and events rather than on
  what anything printed. Every assertion is a fact the feature would be broken without, and each
  says what it would mean if it failed. It exits non-zero on the first one that does not hold.

  This is a Mix task rather than a test because it needs the live node: a running platform, a
  connected worker, and a credential that costs money. `bin/check` cannot run it, the same way it
  cannot run `bin/measure`.

  **`--node` is not optional in practice, and the reason is worth stating.** Sending to a
  conversation reaches its worker through `Workers.push/2`, which looks the machine up in the
  registry of *this* node. Run in a node of its own, this task starts a second platform against
  the same database — a second scheduler, and a registry with no workers in it — so every message
  it sent would be written to the log and delivered to nobody, and the failure would look like a
  conversation that stopped replying. With `--node` the whole run happens inside the live node
  through one call, and this process is only a driver.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias Forge.{CLI, Conversations, Git, Jobs, Merge, Projects, Queue, Repo, Tickets, Workers}
  alias Forge.Events.Event
  alias Forge.Jobs.Job

  # A conversation with a real model is slower than a test; these are patience, not timing.
  @reply_timeout 180_000
  @machine_timeout 300_000

  @impl Mix.Task
  def run(args) do
    # With the scheduler off: booting it here would put a second scheduler beside the live node's,
    # competing for the same pending work, and its recovery pass would put every running
    # conversation to sleep — including the one this is about to start.
    CLI.boot()

    {opts, rest} = OptionParser.parse!(args, strict: [keep: :boolean, node: :string])
    name = List.first(rest) || Mix.raise("usage: mix forge.e2e.chat PROJECT --node forge@host")

    case opts[:node] do
      nil -> local(name, opts)
      node -> remote(String.to_atom(node), name, opts)
    end
  end

  # Everything runs where the workers are. What comes back is the list of results, so the
  # driver prints them and decides the exit status.
  defp remote(node, name, opts) do
    unless Node.connect(node) do
      Mix.raise("cannot reach #{node}; is the platform running with that name and cookie?")
    end

    case :erpc.call(node, __MODULE__, :run_there, [name, opts], :infinity) do
      {:ok, results} -> report(results)
      {:error, reason} -> Mix.raise("the run failed: #{inspect(reason)}")
    end
  end

  defp local(name, opts) do
    {:ok, results} = run_there(name, opts)
    report(results)
  end

  @doc false
  # Called on the live node by `remote/3`, and directly by `local/2`.
  def run_there(name, opts) do
    case Projects.by_name(name) do
      nil ->
        {:error, {:no_project, name}}

      project ->
        Process.put(:results, [])
        check(project, opts)
        {:ok, Process.get(:results)}
    end
  end

  defp check(project, opts) do
    # A word the model has no other reason to say, so finding it later proves memory rather
    # than coincidence.
    token = "ZEPHYR#{System.unique_integer([:positive])}"

    # Asked before anything is opened: a conversation in a project with nothing in its pool waits
    # for a credential, and five minutes of "it never started" would say the wrong thing about why.
    case step("the project has a credential to run on", fn -> pooled(project) end) do
      {:failed, _reason} -> :ok
      _described -> converse(project, pool(project), token, opts)
    end
  end

  defp pool(project), do: Forge.Credentials.pool(project.id, Jobs.harness(%Job{}))

  # What `report/1` prints beside the tick, so a sentence and never the rows.
  defp pooled(project) do
    case pool(project) do
      [] ->
        fail(
          "no credential is in #{project.name}'s pool; add one in /users/settings and " <>
            "assign it to the project"
        )

      pool ->
        "#{length(pool)} in its pool"
    end
  end

  defp converse(project, pool, token, opts) do
    chat = step_start(project, token)

    step("it runs on a credential from the project's pool", fn ->
      unless Jobs.get!(chat.id).credential_id in Enum.map(pool, & &1.id),
        do: fail("the job records no credential from the pool, so its spend is nobody's")
    end)

    step("a reply arrives", fn -> reply_arrives(chat) end)
    step("the reply streamed rather than arriving at the end", fn -> streamed(chat) end)
    step("it remembers the previous turn", fn -> remembers(chat, token) end)
    step("a message sent mid-turn is queued, then delivered", fn -> mid_turn(chat) end)
    step("force ends the turn and the process survives", fn -> survives_interrupt(chat) end)
    step("it commits to its own branch", fn -> commits(chat, project, token) end)
    step("it writes the message its merge will carry", fn -> writes_commit_message(chat) end)
    step("the queue is not starved by it", fn -> not_starved(project, token) end)
    step("a waiting conversation is in the queue", fn -> in_queue(chat) end)
    step("closing it releases the machine", fn -> closing_releases(chat) end)
    step("it still reads afterwards", fn -> still_reads(chat) end)

    step("merging puts its work on the default branch and takes the branch away", fn ->
      merges(chat, project)
    end)

    # A cleanup for a run whose closing step failed before it closed anything. After one that
    # passed, the conversation has already stopped, and closing it again is refused — which here
    # is the nothing there is left to do.
    unless opts[:keep] do
      case Conversations.close(chat, "e2e") do
        :ok -> :ok
        {:error, :not_live} -> :ok
      end
    end
  end

  defp step_start(project, token) do
    {:ok, chat} =
      Conversations.open(
        project,
        "Remember the word #{token}. Reply with just: ready. Then wait for what I say next."
      )

    step("a conversation starts and reaches a worker", fn -> reaches_a_worker(chat) end)
    chat
  end

  defp reaches_a_worker(chat) do
    # `await/2` answers whether the condition held, not what it saw — reading a field off it is
    # how the first version of this reported "it never started" for a chat that had.
    unless await(fn -> live_chat(chat.id) != nil end, @machine_timeout) do
      fail("it never started; is a worker connected and is the day's cap clear?")
    end

    case Jobs.get!(chat.id).worker_id do
      nil -> fail("it is running but no worker is recorded on it")
      worker_id -> "on worker #{String.slice(worker_id, 0, 8)}"
    end
  end

  defp reply_arrives(chat) do
    await(fn -> turns(chat.id) >= 1 end, @reply_timeout) || fail("no turn in #{@reply_timeout}ms")
    "#{turns(chat.id)} turn"
  end

  # The events are separated in time and all before the turn ended, which is the mechanism under
  # streaming. Whether it *looks* live in a browser is the one thing nothing here can reach.
  defp streamed(chat) do
    texts = events(chat.id, "job.harness.text")
    finished = List.first(events(chat.id, "chat.turn"))

    cond do
      texts == [] -> fail("no text events at all")
      finished == nil -> fail("no turn boundary")
      not before?(texts, finished) -> fail("text arrived after the turn ended")
      true -> "#{length(texts)} text event(s) before the turn ended"
    end
  end

  defp remembers(chat, token) do
    before = turns(chat.id)
    {:ok, _event} = Conversations.send(chat, "What word did I ask you to remember? Just it.")
    await(fn -> turns(chat.id) > before end, @reply_timeout) || fail("no second turn")

    reply = last_reply(chat.id)

    if reply && String.contains?(String.upcase(reply), token),
      do: "it said #{token} back",
      else: fail("turn 2 did not remember #{token}; it said #{inspect(reply)}")
  end

  defp mid_turn(chat) do
    before = turns(chat.id)
    {:ok, _slow} = Conversations.send(chat, "Count slowly from 1 to 30, one number per line.")
    Process.sleep(4_000)
    {:ok, event} = Conversations.send(chat, "Ignore the counting. Reply with just: BRAVO.")
    id = to_string(event.seq)

    await(fn -> delivered?(chat.id, id) end, @reply_timeout) ||
      fail("the second message was never taken by the harness")

    # Queued before delivered, in that order: the message exists in the log the moment it is
    # sent and only says it arrived when the harness says so.
    sent_at = Repo.get!(Event, event.seq).inserted_at

    unless before?([sent_at], delivery(chat.id, id)) do
      fail("delivery was recorded before the message")
    end

    await(fn -> turns(chat.id) > before + 1 end, @reply_timeout)
    "queued, then delivered"
  end

  defp survives_interrupt(chat) do
    session = Jobs.get!(chat.id).harness_session_id
    before = turns(chat.id)

    {:ok, _event} =
      Conversations.send(chat, "Count slowly from 1 to 90, one per line, pausing between.")

    Process.sleep(5_000)
    :ok = Conversations.stop(chat)
    await(fn -> turns(chat.id) > before end, @reply_timeout) || fail("the turn never ended")

    {:ok, _event} = Conversations.send(chat, "Reply with just: still here.")

    await(fn -> turns(chat.id) > before + 1 end, @reply_timeout) ||
      fail("the process did not survive the interrupt")

    unless Jobs.get!(chat.id).harness_session_id == session do
      fail("it is a different session; the process was restarted rather than interrupted")
    end

    "same session #{String.slice(session || "", 0, 8)}"
  end

  defp commits(chat, project, token) do
    before = turns(chat.id)

    # The commit message in the same turn as the file, because the merge below needs one: nothing
    # on the default branch may land without it (`docs/design/conversations.md` § Commits), and a
    # conversation that only wrote NOTES.md reached `merges/2` and failed there with
    # `:no_commit_message`.
    {:ok, _event} =
      Conversations.send(
        chat,
        "Create a file NOTES.md containing exactly the word #{token}, " <>
          "write a commit-message document saying what the branch does, " <>
          "then reply with just: written."
      )

    await(fn -> turns(chat.id) > before end, @reply_timeout) || fail("no turn for the write")

    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    case Git.resolve(repo, "refs/heads/" <> branch) do
      {:ok, sha} -> notes_on(repo, sha, branch, token)
      {:error, _reason} -> fail("refs/heads/#{branch} does not exist")
    end
  end

  defp notes_on(repo, sha, branch, token) do
    case Git.show(repo, sha, "NOTES.md") do
      {:ok, content} ->
        if String.contains?(content, token),
          do: "NOTES.md is on #{branch}",
          else: fail("NOTES.md is there but does not contain #{token}")

      {:error, _reason} ->
        fail("the branch exists but NOTES.md is not on it; the turn did not commit")
    end
  end

  # What the merge below will commit, written by the agent and used as it stands. Asserted here
  # rather than left to `merges/2`, so a conversation that did not write one says so where the
  # writing was asked for.
  defp writes_commit_message(chat) do
    name = ForgeCore.Workflow.commit_message_artifact()

    case chat |> Conversations.document_scope(name) |> Forge.Artifacts.versions(name) do
      [] -> fail("the conversation wrote no #{name}, so its merge has nothing to say")
      versions -> "#{name} v#{List.last(versions).version}"
    end
  end

  # At one worker the conversation holds the only slice, which is exactly why closing one had to
  # exist before the queue did. The ticket's first job must still get a machine.
  defp not_starved(project, token) do
    {:ok, ticket} = Tickets.admit(project, %{title: "e2e #{token}", body: "anything"}, :system)

    started? =
      await(
        fn ->
          Jobs.for_ticket(ticket.id)
          |> Enum.any?(&(&1.status in [:running, :waiting, :finished]))
        end,
        @machine_timeout
      )

    if started?,
      do: "ticket ##{ticket.number} got a machine",
      else: fail("ticket ##{ticket.number} never started; the conversation starved the queue")
  end

  defp in_queue(chat) do
    item = Enum.find(Queue.items(), &(&1.kind == :chat and &1.detail.chat_id == chat.id))

    if item,
      do: "it is there",
      else: fail("a conversation waiting on a person is not in the queue")
  end

  defp closing_releases(chat) do
    worker_id = Jobs.get!(chat.id).worker_id
    :ok = Conversations.close(chat, "e2e")

    await(fn -> Jobs.get!(chat.id).status in [:finished, :hibernated] end, @machine_timeout) ||
      fail("it never stopped")

    if worker_id do
      await(fn -> Workers.get!(worker_id).status != :busy end, @machine_timeout) ||
        fail("the worker is still busy after the conversation ended")
    end

    "released"
  end

  defp still_reads(chat) do
    count = length(Conversations.messages(chat.id))
    if count >= 2, do: "#{count} messages", else: fail("the conversation is gone")
  end

  defp merges(chat, project) do
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    case Merge.perform_chat(chat, nil) do
      # `already: true` means this branch has landed already — its head on the default branch, or
      # a merge of it recorded by `refs/forge/merged/chat/<id>` — which is what an empty
      # conversation looks like, and what this used to accept as a successful merge.
      {:ok, %{already: true}} ->
        fail("there was nothing to merge; the conversation committed nothing")

      {:ok, %{sha: sha}} ->
        merged_state(repo, project, branch, chat, sha)

      other ->
        fail("merge said #{inspect(other)}")
    end
  end

  defp merged_state(repo, project, branch, chat, sha) do
    {:ok, head} = Git.resolve(repo, "refs/heads/" <> project.default_branch)

    cond do
      head != sha ->
        fail("the default branch is not at the merge commit")

      not match?({:ok, _}, Git.show(repo, sha, "NOTES.md")) ->
        fail("the merge commit does not carry the conversation's work")

      Git.branch_exists?(repo, branch) ->
        fail("#{branch} is still there")

      not match?({:ok, _}, Git.resolve(repo, "refs/forge/chat/#{chat.id}")) ->
        fail("the branch is gone and nothing pins the commit")

      true ->
        "merged as #{String.slice(sha, 0, 12)}"
    end
  end

  # -- the machinery ---------------------------------------------------------------------------

  # Each step records its own result rather than raising, so a failure early on still leaves the
  # rest of the run's evidence — which is what tells "it never started" from "it started and then
  # one thing was wrong". A step after a failed one may well fail too; that is information.
  defp step(what, fun) do
    detail =
      try do
        fun.()
      rescue
        error -> {:failed, Exception.message(error)}
      catch
        :throw, {:fail, reason} -> {:failed, reason}
      end

    Process.put(:results, Process.get(:results) ++ [{what, detail}])
    detail
  end

  defp fail(reason), do: throw({:fail, reason})

  defp report(results) do
    Enum.each(results, fn
      {what, {:failed, reason}} -> Mix.shell().error("  ✗ #{what}\n      #{reason}")
      {what, detail} -> Mix.shell().info("  ✓ #{what} — #{detail}")
    end)

    failed = Enum.filter(results, &match?({_what, {:failed, _}}, &1))
    Mix.shell().info("")

    if failed == [] do
      Mix.shell().info("all #{length(results)} assertions hold")
    else
      Mix.raise("#{length(failed)} of #{length(results)} assertions failed")
    end
  end

  defp await(fun, timeout, waited \\ 0) do
    cond do
      fun.() -> true
      waited >= timeout -> false
      true -> Process.sleep(1_000) && await(fun, timeout, waited + 1_000)
    end
  end

  defp live_chat(id) do
    case Jobs.get!(id) do
      %Job{status: :running} = chat -> chat
      _other -> nil
    end
  end

  defp turns(id), do: length(events(id, "chat.turn"))

  defp events(id, type) do
    Repo.all(from e in Event, where: e.job_id == ^id and e.type == ^type, order_by: e.seq)
  end

  defp before?(earlier, %Event{} = later),
    do: Enum.all?(earlier, &(DateTime.compare(at(&1), later.inserted_at) in [:lt, :eq]))

  defp before?(_earlier, nil), do: false

  defp at(%Event{inserted_at: at}), do: at
  defp at(%DateTime{} = at), do: at

  defp delivery(id, message_id) do
    id
    |> events("job.harness.delivered")
    |> Enum.find(&(&1.payload["message_id"] == message_id))
  end

  defp delivered?(id, message_id), do: delivery(id, message_id) != nil

  defp last_reply(id) do
    case id |> Conversations.messages() |> Enum.filter(&(&1.role == :assistant)) |> List.last() do
      nil -> nil
      message -> message.text
    end
  end
end
