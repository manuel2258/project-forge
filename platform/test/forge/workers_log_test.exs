defmodule Forge.WorkersLogTest do
  @moduledoc """
  A machine's own history (`docs/design/worker-log.md`): what the platform writes as it happens
  to a machine, what it keeps of the lines a machine sends, and how much of either it keeps.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Provider, Provisioning, Workers}
  alias Forge.Workers.Log

  setup do
    Provider.Fake.watch()
    previous = Application.get_env(:forge, Workers, [])

    on_exit(fn ->
      Provider.Fake.allow()
      Application.put_env(:forge, Workers, previous)
    end)

    :ok
  end

  defp machine(attrs \\ %{}) do
    {:ok, worker, _token} = Workers.create(Map.merge(%{provider: "fake"}, attrs))
    worker
  end

  defp lines(worker), do: Log.for_worker(worker.id)
  defp types(worker), do: worker |> lines() |> Enum.map(& &1.type) |> Enum.reverse()
  defp of_type(worker, type), do: Enum.filter(lines(worker), &(&1.type == type))

  defp one(worker, type) do
    assert [line] = of_type(worker, type)
    line
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Workers, [])
    Application.put_env(:forge, Workers, Keyword.merge(current, opts))
  end

  defp keep(n) do
    current = Application.get_env(:forge, Log, [])
    on_exit(fn -> Application.put_env(:forge, Log, current) end)
    Application.put_env(:forge, Log, keep: n)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)
  defp iso(at), do: DateTime.to_iso8601(at)

  defp with_template(attrs) do
    user = Forge.AccountsFixtures.user_fixture()
    n = System.unique_integer([:positive])

    {:ok, project} =
      Forge.Projects.register(
        %{name: "log-#{n}", repo_path: Path.join(Forge.GitFixtures.tmp_dir("wl"), "p.git")},
        user
      )

    {:ok, template} =
      Provisioning.create_template(
        user,
        Enum.into(attrs, %{
          name: "t-#{n}",
          provider: "fake",
          memory: 8_000,
          cores: 4,
          max_workers: 1
        })
      )

    {:ok, _} = Provisioning.assign(user, template.id, project.id)
    %{user: user, project: project, template: template}
  end

  defp demand(project), do: %{kind: :workflow, memory: 1, cores: 1, project_id: project.id}

  describe "a line a machine sends" do
    test "is kept as the machine's, at the time the machine says" do
      worker = machine()
      at = ago(90) |> DateTime.truncate(:second)
      job_id = Ecto.UUID.generate()

      :ok =
        Log.accept(worker.id, %{
          "at" => iso(at),
          "type" => "job.accepted",
          "level" => "info",
          "message" => "took on a workflow job, attempt 2",
          "job_id" => job_id
        })

      assert [line] = lines(worker)
      assert line.source == :worker
      assert {line.type, line.level, line.job_id} == {"job.accepted", :info, job_id}
      assert line.message == "took on a workflow job, attempt 2"
      assert DateTime.compare(line.at, at) == :eq
    end

    # Lower-case words and dots, at most 64 bytes. Anything else is kept as `unknown` rather
    # than refused, so a newer release's line is still a line.
    test "a type that does not look like one is unknown" do
      worker = machine()
      longest = String.duplicate("a", 64)

      for type <- ["Job.Accepted", "job..accepted", "job.", "<b>x</b>", String.duplicate("a", 65)] do
        :ok = Log.accept(worker.id, %{"type" => type})
      end

      # `$` would take this one: it matches before a final newline, and `\z` does not.
      :ok = Log.accept(worker.id, %{"type" => "job.accepted\n"})
      :ok = Log.accept(worker.id, %{"type" => 7})
      :ok = Log.accept(worker.id, %{})
      :ok = Log.accept(worker.id, %{"type" => longest})
      :ok = Log.accept(worker.id, %{"type" => "seed.fetched"})

      assert Enum.frequencies(types(worker)) == %{
               "unknown" => 8,
               longest => 1,
               "seed.fetched" => 1
             }
    end

    test "a level is one of three, or info" do
      worker = machine()

      for level <- ["error", "warning", "info", "fatal", nil, 3],
          do: :ok = Log.accept(worker.id, %{"type" => "x", "level" => level})

      assert worker |> lines() |> Enum.map(& &1.level) |> Enum.frequencies() ==
               %{error: 1, warning: 1, info: 4}
    end

    # Text, cut to 500 code points, with NUL removed — which Postgres will not store at all, so a
    # line carrying one would crash the channel that received it.
    test "a message is text, bounded" do
      worker = machine()

      :ok = Log.accept(worker.id, %{"type" => "a", "message" => String.duplicate("é", 600)})
      :ok = Log.accept(worker.id, %{"type" => "b", "message" => "nul\0here"})
      :ok = Log.accept(worker.id, %{"type" => "c", "message" => <<0xFF, 0xFE>>})
      :ok = Log.accept(worker.id, %{"type" => "d", "message" => %{"not" => "text"}})

      assert String.length(one(worker, "a").message) == 500
      assert one(worker, "b").message == "nulhere"
      assert one(worker, "c").message == ""
      assert one(worker, "d").message == ""
    end

    # **Only what is kept is read.** Checked whole and then cut, a ten-megabyte message cost the
    # channel ten seconds and half a gigabyte; what lies past the cut is now never looked at.
    test "a message is cut as it is read, and nothing past the cut is looked at" do
      assert Log.clean(String.duplicate("a", 600) <> <<0xFF>>, 500) == String.duplicate("a", 500)
      assert Log.clean("ab" <> <<0xFF>> <> "cd", 500) == nil
      assert Log.clean(<<0, 0>> <> "abc", 2) == "ab"

      {micros, kept} = :timer.tc(fn -> Log.clean(String.duplicate("a", 10_000_000), 500) end)
      assert kept == String.duplicate("a", 500)
      assert micros < 1_000_000
    end

    test "a job id is kept only if it is one" do
      worker = machine()

      :ok = Log.accept(worker.id, %{"type" => "a", "job_id" => "'; drop table jobs; --"})
      :ok = Log.accept(worker.id, %{"type" => "b", "job_id" => 12})

      assert one(worker, "a").job_id == nil
      assert one(worker, "b").job_id == nil
    end

    # Believed a little ahead, for drift, and a week behind, for a line held while the machine
    # was away; outside that it is a clock that is wrong, and the line is placed when it arrived.
    test "the machine's clock is believed only within a window of the platform's" do
      worker = machine()
      before = DateTime.utc_now()

      believed = [{"ahead", ago(-4 * 60)}, {"behind", ago(6 * 24 * 3600)}]
      doubted = [{"far.ahead", ago(-6 * 60)}, {"far.behind", ago(8 * 24 * 3600)}]

      for {type, at} <- believed ++ doubted,
          do: :ok = Log.accept(worker.id, %{"type" => type, "at" => iso(at)})

      :ok = Log.accept(worker.id, %{"type" => "garbled", "at" => "yesterday-ish"})
      :ok = Log.accept(worker.id, %{"type" => "absent"})

      for {type, at} <- believed,
          do: assert(DateTime.compare(one(worker, type).at, at) == :eq, type)

      for type <- ["far.ahead", "far.behind", "garbled", "absent"] do
        at = one(worker, type).at
        assert DateTime.diff(at, before) in 0..5, type
      end
    end
  end

  describe "how much is kept" do
    # By insertion and not by the machine's clock: a line held while the machine was away
    # arrives late with an old time, and is not the one to lose first.
    test "the last lines written, per machine" do
      keep(3)
      worker = machine()
      other = machine()
      :ok = Log.accept(other.id, %{"type" => "theirs"})

      for n <- 1..3, do: :ok = Log.accept(worker.id, %{"type" => "line.#{spell(n)}"})
      :ok = Log.accept(worker.id, %{"type" => "late", "at" => iso(ago(3600))})

      assert Enum.sort(types(worker)) == ["late", "line.three", "line.two"]
      assert types(other) == ["theirs"]
    end

    # **The platform's record of a machine is not the machine's to erase.** With one budget, a
    # machine sending lines pushed out every one the platform had written about it.
    test "a machine's lines do not push out the platform's, and each is trimmed alike" do
      keep(3)
      worker = machine()

      :ok = Log.record(worker.id, "joined", :info, "the platform's")
      for n <- 1..5, do: :ok = Log.accept(worker.id, %{"type" => "flood", "message" => "#{n}"})

      assert types(worker) == ["joined", "flood", "flood", "flood"]
      assert worker |> of_type("flood") |> Enum.map(& &1.message) == ["5", "4", "3"]

      for _ <- 1..4, do: :ok = Log.record(worker.id, "job.lost", :warning, "")
      assert worker |> lines() |> Enum.count(&(&1.source == :platform)) == 3
      assert length(of_type(worker, "flood")) == 3
    end

    # Another machine's lines written after this one's are not counted against it.
    test "one machine's lines do not push out another's" do
      keep(3)
      worker = machine()
      other = machine()

      for n <- 1..3, do: :ok = Log.accept(worker.id, %{"type" => "line.#{spell(n)}"})
      for _ <- 1..3, do: :ok = Log.accept(other.id, %{"type" => "theirs"})

      assert types(worker) == ["line.one", "line.two", "line.three"]
    end

    test "five hundred from each source unless configured, and two hundred shown" do
      worker = machine()
      now = DateTime.utc_now()

      rows =
        for n <- 1..500,
            do: %{
              worker_id: worker.id,
              source: :worker,
              type: "old",
              level: :info,
              message: "#{n}",
              at: now,
              inserted_at: now
            }

      {500, _} = Forge.Repo.insert_all(Forge.Workers.LogEntry, rows)
      :ok = Log.accept(worker.id, %{"type" => "new"})

      kept = Log.for_worker(worker.id, 1_000)
      assert length(kept) == 500
      refute Enum.any?(kept, &(&1.message == "1"))
      assert length(Log.for_worker(worker.id)) == 200
    end

    # Two lines at the same moment — a machine's clock is only so fine — are newest-written first.
    test "lines at the same moment are shown in the order they were written, newest first" do
      worker = machine()
      at = iso(ago(30))

      for type <- ["first", "second", "third"],
          do: :ok = Log.accept(worker.id, %{"type" => type, "at" => at})

      assert worker |> lines() |> Enum.map(& &1.type) == ["third", "second", "first"]
    end

    test "the page is shown newest first, by the time each line says" do
      worker = machine()
      :ok = Log.record(worker.id, "second", :info, "")
      :ok = Log.accept(worker.id, %{"type" => "first", "at" => iso(ago(60))})
      :ok = Log.record(worker.id, "third", :info, "")

      assert worker |> lines() |> Enum.map(& &1.type) == ["third", "second", "first"]
      assert worker.id |> Log.for_worker(2) |> Enum.map(& &1.type) == ["third", "second"]
    end
  end

  # The driver's words reach these lines, and they are text from outside as a machine's are.
  test "a line the platform writes is bounded the same way" do
    worker = machine()

    :ok =
      Log.record(worker.id, "create.refused", :error, "nul\0here" <> String.duplicate("é", 600))

    message = one(worker, "create.refused").message
    assert String.starts_with?(message, "nulhere")
    assert String.length(message) == 500
  end

  describe "a line the platform would otherwise repeat" do
    test "is written once until the machine next joins" do
      worker = machine()

      :ok = Log.record(worker.id, "unreachable", :warning, "one", once: true)
      :ok = Log.record(worker.id, "unreachable", :warning, "two", once: true)
      assert Enum.map(of_type(worker, "unreachable"), & &1.message) == ["one"]

      # Another type is its own.
      :ok = Log.record(worker.id, "destroy.refused", :error, "no", once: true)
      assert length(of_type(worker, "destroy.refused")) == 1

      :ok = Log.record(worker.id, "joined", :info, "back")
      :ok = Log.record(worker.id, "unreachable", :warning, "three", once: true)
      assert Enum.map(of_type(worker, "unreachable"), & &1.message) == ["three", "one"]
    end

    # A machine may send a line of any type, shown as its own — and neither lifts nor imposes
    # the platform's silence.
    test "is not silenced or released by a line the machine sent" do
      worker = machine()
      :ok = Log.accept(worker.id, %{"type" => "unreachable"})
      :ok = Log.record(worker.id, "unreachable", :warning, "the platform's", once: true)
      assert length(of_type(worker, "unreachable")) == 2

      :ok = Log.accept(worker.id, %{"type" => "joined"})
      :ok = Log.record(worker.id, "unreachable", :warning, "again", once: true)
      assert length(of_type(worker, "unreachable")) == 2
    end

    test "is released by every join, not only the first" do
      worker = machine()

      for n <- 1..3 do
        :ok = Log.record(worker.id, "unreachable", :warning, "#{n}", once: true)
        :ok = Log.record(worker.id, "unreachable", :warning, "again", once: true)
        :ok = Log.record(worker.id, "joined", :info, "back")
      end

      assert worker |> of_type("unreachable") |> Enum.map(& &1.message) == ["3", "2", "1"]
    end

    # One machine's silence is its own: a fleet that drops at once is a line per machine.
    test "is not imposed by another machine's line" do
      worker = machine()
      other = machine()
      :ok = Log.record(other.id, "unreachable", :warning, "theirs", once: true)
      :ok = Log.record(worker.id, "unreachable", :warning, "mine", once: true)
      assert length(of_type(worker, "unreachable")) == 1
    end

    test "is not released by another machine joining" do
      worker = machine()
      other = machine()
      :ok = Log.record(worker.id, "unreachable", :warning, "one", once: true)
      :ok = Log.record(other.id, "joined", :info, "elsewhere")
      :ok = Log.record(worker.id, "unreachable", :warning, "two", once: true)
      assert length(of_type(worker, "unreachable")) == 1
    end

    test "a line without once is written every time" do
      worker = machine()
      :ok = Log.record(worker.id, "job.lost", :warning, "a")
      :ok = Log.record(worker.id, "job.lost", :warning, "a")
      assert length(of_type(worker, "job.lost")) == 2
    end
  end

  describe "what the platform writes" do
    test "a machine provisioned by hand says so; a bare managed row says nothing yet" do
      permanent = machine(%{managed: false})
      managed = machine()

      assert one(permanent, "created").message =~ "provisioned by hand, on fake"
      assert one(permanent, "created").source == :platform
      assert lines(managed) == []
    end

    test "a machine made from a template, with the driver's id and the template's name" do
      %{project: project, template: template} = with_template(%{})

      assert {:error, :creating} = Workers.create_machine(demand(project))
      assert [worker] = Workers.list()

      assert one(worker, "created").message ==
               "fake made #{worker.provider_id} from template #{template.name}"
    end

    # Deleting a template is allowed at any time, including while the driver is making a machine
    # from it; the row's `template_id` then names nothing, and the line still says which it was.
    test "a template deleted while its machine was being made is still named" do
      %{user: user, project: project, template: template} = with_template(%{})

      Provider.Fake.during_create(fn _opts ->
        :ok = Provisioning.delete_template(user, template.id)
      end)

      assert {:error, :creating} = Workers.create_machine(demand(project))
      assert [worker] = Workers.list()
      assert worker.template_id == nil
      assert one(worker, "created").message =~ "from template #{template.name}"
    end

    test "a machine that arrived for a row retired while it was being made" do
      %{user: user, project: project} = with_template(%{})

      Provider.Fake.during_create(fn opts ->
        {:ok, []} = Workers.retire_by_owner(user, opts.worker_id)
      end)

      assert {:error, :at_capacity} = Workers.create_machine(demand(project))
      assert [worker] = Workers.list()

      assert types(worker) == ["destroyed", "destroyed"]
      [late, retired] = of_type(worker, "destroyed")

      assert retired.message ==
               "row retired; no machine had been made for it — by its owner, " <>
                 "from the workers page"

      assert late.level == :warning
      assert late.message =~ "fake made fake-#{worker.id} after the row was retired"
    end

    test "a driver's refusal to make one, in its words" do
      %{project: project} = with_template(%{})
      Provider.Fake.refuse({:hetzner, 400, "server type not available"})

      assert {:error, {:create_failed, _}} = Workers.create_machine(demand(project))

      assert [worker] = Workers.list()
      line = one(worker, "create.refused")
      assert line.level == :error
      assert line.message == "fake refused: 400: server type not available"
      assert of_type(worker, "created") == []
    end

    test "what a ready machine offers" do
      worker = machine()

      {:ok, _} =
        Workers.ready(worker, %{
          "memory_budget" => 8 * 1024 ** 3,
          "cores" => 4,
          "accepts" => ["workflow", "chat"]
        })

      assert one(worker, "ready").message ==
               "offers 8.0 GiB of memory, 4 cores, for workflow, chat"
    end

    test "a machine that takes no kinds in particular is not said to take none" do
      worker = machine(%{accepts: []})
      {:ok, _} = Workers.ready(worker, %{"memory_budget" => 1024 ** 3, "cores" => 2})
      assert one(worker, "ready").message == "offers 1.0 GiB of memory, 2 cores"
      assert one(worker, "ready").level == :info
    end

    test "a machine offering nothing in particular" do
      worker = machine()
      {:ok, _} = Workers.ready(worker, %{})
      assert one(worker, "ready").message == "offers 0.0 GiB of memory"
    end

    # Refused and still knocking: a permanent machine keeps its row and rejoins on a backoff,
    # and each knock is not a line.
    test "a permanent machine refused at the join, once" do
      worker = machine(%{managed: false})
      too_new = ForgeCore.WorkerProtocol.current() + 1

      for _ <- 1..3, do: {:error, _} = Workers.admit(worker.id, %{"protocol" => too_new})

      line = one(worker, "join.refused")
      assert line.level == :error
      assert line.message =~ "speaks protocol #{too_new} and this platform accepts"
      assert line.message =~ "its row stays"
      assert of_type(worker, "destroyed") == []
    end

    test "a protocol that cannot be read is said to be one" do
      worker = machine(%{managed: false})
      {:error, _} = Workers.admit(worker.id, %{"protocol" => "two"})
      assert one(worker, "join.refused").message =~ "speaks a protocol this platform cannot read"
    end

    test "a managed machine refused at the join is destroyed, and the log says why" do
      worker = machine(%{provider_id: "fake-7"})

      {:error, _} =
        Workers.admit(worker.id, %{"protocol" => ForgeCore.WorkerProtocol.current() + 1})

      assert types(worker) == ["join.refused", "destroyed"]
      assert one(worker, "join.refused").message =~ "destroying it"
      assert one(worker, "join.refused").level == :error

      assert one(worker, "destroyed").message ==
               "destroyed fake-7 on fake — it speaks a protocol this platform refuses"
    end

    # Its destroy refused, the row stays, and the machine knocks again.
    test "a managed machine refused at the join and not yet gone, once" do
      Provider.Fake.refuse_destroy({:fake, "the API is down"})
      worker = machine(%{provider_id: "fake-8"})
      too_new = ForgeCore.WorkerProtocol.current() + 1

      for _ <- 1..3, do: {:error, _} = Workers.admit(worker.id, %{"protocol" => too_new})

      assert types(worker) == ["join.refused", "destroy.refused"]

      assert one(worker, "destroy.refused").message =~
               "it speaks a protocol this platform refuses"
    end

    test "a machine destroyed for being idle" do
      configure(idle_period_ms: 60_000)
      worker = machine(%{provider_id: "fake-1"})
      {:ok, _} = Workers.update(worker, %{status: :idle, idle_since: ago(120)})

      assert Workers.sweep_idle() == 1
      line = one(worker, "destroyed")

      assert {line.level, line.message} ==
               {:info, "destroyed fake-1 on fake — idle past its period"}
    end

    test "a machine its owner ended from the page, and one the host's command line did" do
      user = Forge.AccountsFixtures.user_fixture()
      mine = machine(%{provider_id: "fake-2", user_id: user.id})
      permanent = machine(%{managed: false, user_id: user.id})

      {:ok, []} = Workers.retire_by_owner(user, mine.id)
      {:ok, []} = Workers.retire(permanent, by: :command_line)

      assert one(mine, "destroyed").message ==
               "destroyed fake-2 on fake — by its owner, from the workers page"

      assert one(permanent, "destroyed").message ==
               "retired: forgotten, not destroyed, since the machine was never the platform's " <>
                 "to stop — from the host's command line"
    end

    test "a row whose driver never made anything had no machine to destroy" do
      worker = machine()
      :ok = Workers.destroy(worker)
      assert one(worker, "destroyed").message == "row retired; no machine had been made for it"
    end

    # A cause this does not know raises before the driver is asked — not after the machine has gone
    # and before its row says so.
    test "an unknown cause is refused before anything is destroyed" do
      worker = machine(%{provider_id: "fake-6"})

      assert_raise FunctionClauseError, fn -> Workers.destroy(worker, by: :whim) end

      refute_received {:provider_destroy, "fake-6", _credential}
      refute Workers.get!(worker.id).status == :destroyed
    end

    # A Destroy pressed on the page is asked once; only what a sweep or a knock asked is asked again
    # (`docs/design/ui.md` § The workers page).
    test "a refused destroy promises a retry only where one will be made" do
      Provider.Fake.refuse_destroy({:fake, "the API is down"})
      user = Forge.AccountsFixtures.user_fixture()
      mine = machine(%{provider_id: "fake-9", user_id: user.id})

      assert {:error, _} = Workers.retire_by_owner(user, mine.id)

      refused = one(mine, "destroy.refused")
      assert refused.message =~ "— by its owner, from the workers page: "
      assert refused.message =~ ~r/The row is kept, so the machine is still counted$/
      refute refused.message =~ "tries again"
    end

    test "a machine whose provider is gone, as a warning that says where to look" do
      worker = machine(%{provider: "departed", provider_id: "srv-1"})
      :ok = Workers.destroy(worker, by: :command_line)

      line = one(worker, "destroyed")
      assert line.level == :warning

      assert line.message =~
               "row retired — from the host's command line, but its provider departed"

      assert line.message =~ "check that provider's console"
    end

    test "a destroy forced past a refusal, as a warning" do
      Provider.Fake.refuse_destroy({:fake, "nope"})
      worker = machine(%{provider_id: "fake-3"})

      :ok = Workers.destroy(worker, force: true, by: :command_line)

      line = one(worker, "destroyed")
      assert line.level == :warning

      assert line.message =~
               "retired by force — from the host's command line; fake would not destroy"

      assert line.message =~ "fake-3: "
      assert line.message =~ "nope"
    end

    # The sweep retries a refused destroy on every pass; the log says it once, and the row's
    # `last_error` holds the latest words.
    test "an unreachable machine whose destroy is refused, said once however often it is swept" do
      configure(worker_timeout_ms: 60_000)
      Provider.Fake.refuse_destroy({:fake, "the API is down"})
      worker = machine(%{provider_id: "fake-4"})
      {:ok, _} = Workers.update(worker, %{last_seen_at: ago(600)})

      for _ <- 1..3, do: assert(Workers.sweep_unreachable() == 0)

      assert types(worker) == ["unreachable", "destroy.refused"]
      assert one(worker, "unreachable").message =~ "not heard from since"
      assert one(worker, "unreachable").message =~ "requeued 0 job(s) and destroying it"

      refused = one(worker, "destroy.refused")
      assert refused.level == :error
      assert refused.message =~ ~r/The row is kept, and the platform tries again$/
      assert refused.message =~ "fake would not destroy fake-4 — unreachable: "
      assert refused.message =~ "the API is down"

      Provider.Fake.allow()
      assert Workers.sweep_unreachable() == 1
      assert one(worker, "destroyed").message == "destroyed fake-4 on fake — unreachable"
    end

    test "an unreachable managed machine's jobs, counted, as a warning" do
      configure(worker_timeout_ms: 60_000)
      worker = machine(%{provider_id: "fake-10"})
      for _ <- 1..2, do: job_fixture(%{status: :running, worker_id: worker.id})
      {:ok, _} = Workers.update(worker, %{last_seen_at: ago(600)})

      assert Workers.sweep_unreachable() == 1

      line = one(worker, "unreachable")
      assert line.level == :warning
      assert line.message =~ "requeued 2 job(s) and destroying it"
    end

    test "a machine that never called home is said to have never connected" do
      configure(worker_timeout_ms: 60_000)
      worker = machine(%{provider_id: "fake-5"})

      Forge.Repo.update!(
        Ecto.Changeset.change(worker, inserted_at: DateTime.truncate(ago(600), :second))
      )

      assert Workers.sweep_unreachable() == 1
      assert one(worker, "unreachable").message =~ "and never connected"
    end

    test "an unreachable permanent machine's jobs, and that its row stays" do
      configure(worker_timeout_ms: 60_000)
      worker = machine(%{managed: false})

      for _ <- 1..2, do: job_fixture(%{status: :running, worker_id: worker.id})
      {:ok, _} = Workers.update(worker, %{last_seen_at: ago(600)})

      assert Workers.sweep_unreachable() == 1

      line = one(worker, "unreachable")
      assert line.level == :warning
      assert line.message =~ "requeued 2 job(s). Its row stays"
      assert of_type(worker, "destroyed") == []
    end

    # **The log outlives the machine**: "why did it go away?" is asked afterwards.
    test "a destroyed machine keeps its log" do
      worker = machine(%{managed: false})
      {:ok, []} = Workers.retire(worker)
      assert types(worker) == ["created", "destroyed"]
    end
  end

  defp spell(1), do: "one"
  defp spell(2), do: "two"
  defp spell(3), do: "three"
end
