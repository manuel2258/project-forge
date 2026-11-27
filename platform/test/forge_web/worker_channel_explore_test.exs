defmodule ForgeWeb.WorkerChannelExploreTest do
  @moduledoc """
  The channel's half of looking into a command copy and of live lines (`docs/design/worker-channel.md`
  § Protocol 18): a question reaches the machine with a ref and its answer reaches whoever asked, by
  that connection and no other; lines are taken from the machine running the command, while it runs;
  a failed command carries its steps.
  """

  use ForgeWeb.ChannelCase, async: false

  import Forge.ForgeFixtures
  import Forge.WarmFixtures, only: [kept!: 3, ticket_in_checking!: 0]

  alias Forge.{Explore, Jobs, WarmBuilds, Workers}
  alias Forge.Jobs.Lines
  alias ForgeWeb.{WorkerChannel, WorkerSocket}

  # `running` is what the machine says it is running when it joins: a job the platform has running
  # there that it does not list is requeued, which is what a rejoin reconciles.
  defp open_socket(worker, token, running \\ [], protocol \\ ForgeCore.WorkerProtocol.current()) do
    {:ok, socket} =
      connect(WorkerSocket, %{"worker_id" => worker.id},
        connect_info: %{x_headers: [{"x-forge-worker-token", token}]}
      )

    {:ok, _reply, socket} =
      subscribe_and_join(socket, WorkerChannel, "worker:#{worker.id}", %{
        "protocol" => protocol,
        "running" => Enum.map(running, &%{"job_id" => &1})
      })

    socket
  end

  defp running_command(worker) do
    %{commands: [command | _]} = ticket_in_checking!()

    {:ok, command} =
      command
      |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
      |> Forge.Repo.update()

    command
  end

  describe "live lines" do
    setup do
      {:ok, worker, token} = Workers.create(%{provider: "local"})
      {:ok, other, other_token} = Workers.create(%{provider: "local"})
      command = running_command(worker)
      on_exit(fn -> Lines.drop(command.id) end)

      %{
        worker: worker,
        socket: open_socket(worker, token, [command.id]),
        other: open_socket(other, other_token),
        command: command
      }
    end

    test "are held and broadcast when the machine running the command sends them", ctx do
      Lines.subscribe(ctx.command.id)
      id = ctx.command.id

      push(ctx.socket, "lines", %{
        "job_id" => id,
        "from" => 0,
        "lines" => [[3, "hello"], [9, "x"]]
      })

      assert_receive {:command_lines, ^id, 0, [[3, "hello"], [9, "x"]]}, 1_000
      assert %{lines: [[3, "hello"], [9, "x"]]} = Lines.all(id)
    end

    test "are dropped from a machine that is not running the command", ctx do
      id = ctx.command.id
      push(ctx.other, "lines", %{"job_id" => id, "from" => 0, "lines" => [[3, "forged"]]})

      # Unacked: a message the same channel handles next is one it handled the forged lines before.
      ref = push(ctx.other, "heartbeat", %{})
      assert_reply ref, :ok

      push(ctx.socket, "lines", %{"job_id" => id, "from" => 0, "lines" => [[1, "real"]]})
      wait_until(fn -> Lines.all(id) != nil end)

      assert %{lines: [[1, "real"]]} = Lines.all(id)
    end

    test "are dropped for a command that is not running, and for a job that is not a command",
         ctx do
      {:ok, finished} =
        ctx.command
        |> Jobs.Job.progress_changeset(%{
          status: :finished,
          outcome: :converged,
          finished_at: DateTime.utc_now(:second)
        })
        |> Forge.Repo.update()

      agent = job_fixture()

      {:ok, agent} =
        agent
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: ctx.worker.id})
        |> Forge.Repo.update()

      on_exit(fn -> Lines.drop(agent.id) end)

      push(ctx.socket, "lines", %{"job_id" => finished.id, "from" => 0, "lines" => [[1, "late"]]})
      push(ctx.socket, "lines", %{"job_id" => agent.id, "from" => 0, "lines" => [[1, "agent"]]})
      push(ctx.socket, "lines", %{"job_id" => "nonsense", "from" => 0, "lines" => [[1, "x"]]})
      # A message the channel handles after those two is a message they were handled before.
      ref = push(ctx.socket, "heartbeat", %{})
      assert_reply ref, :ok

      assert Lines.all(finished.id) == nil
      assert Lines.all(agent.id) == nil
    end

    test "add no event to the log", ctx do
      id = ctx.command.id
      before = length(Forge.Events.for_job(id))
      push(ctx.socket, "lines", %{"job_id" => id, "from" => 0, "lines" => [[1, "x"], [2, "y"]]})
      wait_until(fn -> Lines.all(id) != nil end)

      assert length(Forge.Events.for_job(id)) == before
    end
  end

  test "a failed command carries its steps" do
    {:ok, worker, token} = Workers.create(%{provider: "local"})
    command = running_command(worker)
    socket = open_socket(worker, token, [command.id])

    steps = [
      %{"name" => "snapshot", "at" => 5, "ms" => 7},
      %{"name" => "fetch", "at" => 12, "ms" => 3}
    ]

    ref =
      push(socket, "failed", %{"job_id" => command.id, "reason" => "no fetch", "steps" => steps})

    assert_reply ref, :ok

    assert {:steps, ^steps} = Jobs.command_steps(command.id)
  end

  describe "asking a machine about a copy" do
    setup do
      {:ok, worker, token} = Workers.create(%{provider: "local"})
      {:ok, other, other_token} = Workers.create(%{provider: "local"})
      socket = open_socket(worker, token)
      other_socket = open_socket(other, other_token)

      ticket = ticket_fixture()
      kept = kept!(ticket, Workers.get!(worker.id), [])
      {:ok, copy} = WarmBuilds.copy(ticket, kept.id)

      %{socket: socket, other: other_socket, copy: copy, ticket: ticket, kept: kept}
    end

    defp ask(fun), do: Task.async(fn -> fun.() end)

    test "reaches the machine with the ticket, the copy and the path, and its answer reaches the asker",
         ctx do
      task = ask(fn -> Explore.list(ctx.copy, "src", 400) end)

      assert_push "explore", %{"ref" => ref, "op" => "list"} = payload
      assert payload["ticket"] == ctx.ticket.id
      assert payload["copy"] == ctx.kept.id
      assert payload["path_b64"] == Base.encode64("src")
      assert payload["offset"] == 400

      entry = %{
        "name_b64" => Base.encode64(<<"a", 255>>),
        "kind" => "file",
        "size" => 3,
        "mtime" => 9
      }

      push(ctx.socket, "explored", %{
        "ref" => ref,
        "ok" => %{"entries" => [entry], "total" => 401, "offset" => 400}
      })

      assert {:ok,
              %{entries: [%{name: <<"a", 255>>, kind: :file, size: 3}], total: 401, offset: 400}} =
               Task.await(task)
    end

    test "an answer from a machine that was not asked is ignored", ctx do
      task = ask(fn -> Explore.file(ctx.copy, "a") end)
      assert_push "explore", %{"ref" => ref}

      push(ctx.other, "explored", %{"ref" => ref, "ok" => %{"kind" => "file", "size" => 666}})
      assert Task.yield(task, 100) == nil

      push(ctx.socket, "explored", %{"ref" => ref, "ok" => %{"kind" => "file", "size" => 1}})
      assert {:ok, %{size: 1}} = Task.await(task)
    end

    test "an error word is the asker's error, and one it does not know is a failure", ctx do
      task = ask(fn -> Explore.file(ctx.copy, "a") end)
      assert_push "explore", %{"ref" => ref}
      push(ctx.socket, "explored", %{"ref" => ref, "error" => "path_not_found"})
      assert Task.await(task) == {:error, :path_not_found}

      task = ask(fn -> Explore.file(ctx.copy, "a") end)
      assert_push "explore", %{"ref" => ref}
      push(ctx.socket, "explored", %{"ref" => ref, "error" => "the moon is full"})
      assert Task.await(task) == {:error, :failed}
    end

    test "silence for the answer time is the machine not answering, and progress keeps it alive",
         ctx do
      put_answer_ms(200)

      test = self()

      task =
        ask(fn ->
          Explore.hash(ctx.copy, "big", fn done, total -> send(test, {:progress, done, total}) end)
        end)

      assert_push "explore", %{"ref" => ref}

      for done <- [10, 20] do
        Process.sleep(120)

        push(ctx.socket, "explored", %{
          "ref" => ref,
          "progress" => %{"done" => done, "total" => 100}
        })
      end

      Process.sleep(120)

      push(ctx.socket, "explored", %{
        "ref" => ref,
        "ok" => %{"sha256" => String.duplicate("a", 64), "size" => 100}
      })

      assert {:ok, %{sha256: sha, size: 100}} = Task.await(task)
      assert_received {:progress, 10, 100}
      assert_received {:progress, 20, 100}
      assert sha == String.duplicate("a", 64)

      silent = ask(fn -> Explore.file(ctx.copy, "a") end)
      assert_push "explore", %{"ref" => _silent_ref}
      assert Task.await(silent) == {:error, :machine_not_answering}
    end

    test "a machine that says nothing for the answer time did not answer, whatever is asked",
         ctx do
      put_answer_ms(30)

      for request <- [
            fn -> Explore.list(ctx.copy, "", 0) end,
            fn -> Explore.file(ctx.copy, "a") end,
            fn -> Explore.hash(ctx.copy, "a", nil) end
          ] do
        task = ask(request)
        assert_push "explore", %{"ref" => _ref}
        assert Task.await(task) == {:error, :machine_not_answering}
      end
    end

    test "a path that is not inside the copy is refused before the machine is asked", ctx do
      for path <- ["..", "a/../b", "/etc", "a//b", "a\0b"] do
        assert Explore.list(ctx.copy, path, 0) == {:error, :path_refused}
      end

      refute_push "explore", _payload, 50
    end

    test "a machine that leaves while it is asked is not connected", ctx do
      task = ask(fn -> Explore.file(ctx.copy, "a") end)
      assert_push "explore", _payload
      Process.unlink(ctx.socket.channel_pid)
      GenServer.stop(ctx.socket.channel_pid)

      assert Task.await(task) == {:error, :machine_not_connected}
    end
  end

  defp put_answer_ms(ms) do
    previous = Application.get_env(:forge, :explore_answer_ms)
    Application.put_env(:forge, :explore_answer_ms, ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:forge, :explore_answer_ms, previous),
        else: Application.delete_env(:forge, :explore_answer_ms)
    end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("did not happen")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
