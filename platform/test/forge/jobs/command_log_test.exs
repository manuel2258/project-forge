defmodule Forge.Jobs.CommandLogTest do
  @moduledoc """
  A command's log with each line's time (`Forge.Jobs.CommandLog`): the live lines while it runs,
  the stored log and its times after, the tail a page shows and the lines before it on request.
  """

  use Forge.DataCase, async: false

  import Forge.WarmFixtures, only: [ticket_in_checking!: 0]

  alias Forge.{FakeWorker, Jobs}
  alias Forge.Jobs.{CommandLog, Lines}

  setup do
    %{project: project, commands: [build | _]} = ticket_in_checking!()
    on_exit(fn -> Lines.drop(build.id) end)
    %{build: build, worker: FakeWorker.connect(project: project)}
  end

  defp finish(ctx, opts) do
    {:ok, job} = ctx.build |> FakeWorker.assign(ctx.worker) |> FakeWorker.finish_command(0, opts)
    job
  end

  describe "a command that ended" do
    test "has each line with its time, from the stored log and the times beside it", ctx do
      job = finish(ctx, log: "one\ntwo\nthree\n", times: "5\n20\n61000\n")

      assert %{lines: [{5, "one"}, {20, "two"}, {61_000, "three"}], total: 3, source: :stored} =
               CommandLog.read(job, [])
    end

    test "has the lines and no times when none were kept", ctx do
      job = finish(ctx, log: "one\ntwo\n")
      assert %{lines: [{nil, "one"}, {nil, "two"}]} = CommandLog.read(job, [])
    end

    test "leaves a times blob past the limit unread, and draws the lines without times", ctx do
      Application.put_env(:forge, :command_times_limit, 8)
      on_exit(fn -> Application.delete_env(:forge, :command_times_limit) end)
      job = finish(ctx, log: "one\ntwo\nthree\n", times: "5\n20\n61000\n")

      assert %{lines: [{nil, "one"}, {nil, "two"}, {nil, "three"}], total: 3} =
               CommandLog.read(job, [])

      assert {:ok, _bytes, nil} = CommandLog.raw(job)

      Application.put_env(:forge, :command_times_limit, 11)
      assert %{lines: [{5, "one"} | _]} = CommandLog.read(job, [])
    end

    test "has a line's time only when the times blob reaches it", ctx do
      job = finish(ctx, log: "a\nb\nc\n", times: "1\n2\n")
      assert %{lines: [{1, "a"}, {2, "b"}, {nil, "c"}]} = CommandLog.read(job, [])
    end

    test "shows the last lines, and the earlier ones when asked for, counted from the first",
         ctx do
      log = Enum.map_join(0..9, "", &"line #{&1}\n")
      times = Enum.map_join(0..9, "", &"#{&1 * 10}\n")
      job = finish(ctx, log: log, times: times)

      assert %{lines: lines, total: 10, shown_from: 7} = CommandLog.read(job, tail: 3)
      assert lines == [{70, "line 7"}, {80, "line 8"}, {90, "line 9"}]

      assert %{shown_from: 4, lines: [{40, "line 4"} | _]} =
               CommandLog.read(job, tail: 3, earlier: 3)

      assert %{shown_from: 0} = CommandLog.read(job, tail: 3, earlier: 100)
    end

    test "a log with bytes that are not text still has lines a page can draw", ctx do
      job = finish(ctx, log: <<"a", 255, "\nb\n">>, times: "1\n2\n")
      assert %{lines: [{1, first}, {2, "b"}]} = CommandLog.read(job, [])
      assert String.valid?(first)
    end

    test "a command that never uploaded a log has none", ctx do
      assignment = FakeWorker.assign(ctx.build, ctx.worker)

      {:ok, job} =
        Jobs.complete(assignment["job_id"], %ForgeCore.Job.Result{
          status: :finished,
          outcome: :error
        })

      assert %{lines: [], total: 0, source: :stored} = CommandLog.read(job, [])
    end

    test "raw/1 is the log as written, with its times", ctx do
      job = finish(ctx, log: "x\ny\n", times: "3\n4\n")
      assert {:ok, "x\ny\n", [3, 4]} = CommandLog.raw(job)
    end
  end

  describe "a command that runs" do
    test "has the lines held in memory, which are the tail of what has been seen", ctx do
      {:ok, running} =
        ctx.build |> Jobs.Job.progress_changeset(%{status: :running}) |> Forge.Repo.update()

      assert %{lines: [], source: :live} = CommandLog.read(running, [])

      Lines.put(running.id, 0, for(n <- 0..4, do: [n * 100, "line #{n}"]))

      assert %{lines: [{300, "line 3"}, {400, "line 4"}], total: 5, shown_from: 3, source: :live} =
               CommandLog.read(running, tail: 2)
    end
  end

  test "lines/1 does not count the empty piece after a final newline" do
    assert CommandLog.lines("a\nb\n") == ["a", "b"]
    assert CommandLog.lines("a\nb") == ["a", "b"]
    assert CommandLog.lines("a\n\nb\n") == ["a", "", "b"]
    assert CommandLog.lines("") == []
  end
end
