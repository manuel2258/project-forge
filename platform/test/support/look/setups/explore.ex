defmodule Forge.Look.Setups.Explore do
  @moduledoc """
  A ticket's kept builds and a command's run on a machine (`docs/design/ui.md` § The details,
  § The job page, § The explorer; ticket 84): a ticket whose commands kept a build on three
  machines (the newest on a machine that is another's, one of them cleared), with the saved sizes of
  their ignored folders, and the explorer answered by `Forge.FakeExplore` over a copy with a folder of
  450 entries, a name with markup, a name 300 characters long, a link, a file that is not text and a
  text file of 40 MiB; a command that is running, with output that has a silence in it; and one that
  ended, with its steps and the times of its lines.

  Users: `member`. Paths: `details` (the ticket), `folder` (the copy's top), `src` (a folder), `many`
  (the folder of 450), `file` (a text file), `big` (a text file longer than is shown), `binary`,
  `link`, `running` and `finished` (the command pages), `kept` (a command that kept its build, whose
  page links the explorer). Made from fixtures, with made-up data only.
  """

  @behaviour Forge.Look.Setups

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.BuildFixtures

  alias Forge.{FakeExplore, FakeWorker, Jobs, Repo, Storage}
  alias Forge.Jobs.{Job, Lines}
  alias ForgeCore.Job.Result

  @impl true
  def build do
    member = user_fixture()
    workflow = String.replace(keeping(), "max: 3", "max: 8")
    {project, ticket} = look_ticket(member, workflow)
    [one, two, three] = for _n <- 1..3, do: FakeWorker.connect()

    [old, newest, cleared, running, ended] =
      invoke_builds(ticket, one, [
        ["--only", "<b>scores</b>", "--trace"],
        ["--release"],
        [],
        ["--watch"],
        ["--ci"]
      ])

    now = DateTime.utc_now(:second)
    old = kept!(old, one, 3 * 3_600, now, size: 412 * 1_048_576, folders: nil)
    newest = kept!(newest, two, 600, now, size: 5_368_709_120, folders: folders())
    _cleared = kept!(cleared, three, 1_800, now, size: 96 * 1_048_576, epoch: 1)

    running = running!(running, one)
    ended = ended!(ended, one)

    FakeExplore.install(files(), on_exit: false)

    ticket_page = "/tickets/#{project.name}/#{ticket.number}"
    build = ticket_page <> "/builds/#{newest.id}"
    job = &(ticket_page <> "/jobs/#{&1.id}")

    %{
      users: %{"member" => member},
      paths: %{
        "details" => ticket_page,
        "folder" => build,
        "src" => build <> "?path=src",
        "many" => build <> "?path=many",
        "file" => build <> "?path=src%2Fmain.rs",
        "big" => build <> "?path=big.log",
        "binary" => build <> "?path=target%2Fdebug%2Fapp",
        "link" => build <> "?path=to-etc",
        "running" => job.(running),
        "finished" => job.(ended),
        "kept" => job.(newest),
        "older" => job.(old)
      }
    }
  end

  # The project and its ticket, on a repository made the way the other setups make theirs: not
  # with `Forge.GitFixtures`, which cleans up with `ExUnit.Callbacks` a look has no test for. A
  # repository registered by name outlives the sandbox, so the one a previous build left goes first.
  defp look_ticket(member, workflow) do
    project = Forge.Look.Setups.Decision.project!("look-explore", workflow, member)

    Forge.ProjectFixtures.commit_files!(Forge.Projects.repo_path(project), "main", %{
      ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
    })

    {:ok, ticket} = Forge.Tickets.admit(project, %{title: "Build it"}, {:user, member.id})
    {project, ticket}
  end

  # A command that kept its build `ago` seconds before `now`.
  defp kept!(command, worker, ago, now, opts) do
    job = keep(command, worker, 0, opts)
    at = DateTime.add(now, -ago, :second)
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [finished_at: at])
    Jobs.get!(job.id)
  end

  # Running, with a minute of output and a silence of 42 seconds in the middle of it.
  defp running!(command, worker) do
    FakeWorker.assign(command, worker)

    lines = for n <- 0..39, do: [n * 500, "   Compiling dep_#{n} v0.#{n}.0"]

    tail = [
      [20_500, "    Finished dev [unoptimized] target(s) in 20.5s"],
      [62_500, "     Running tests/scores.rs"],
      [63_000, "test ties_are_broken_by_time ... ok"],
      [63_200, "warning: unused <b>variable</b> in a_very_long_path/that/never/breaks/src/lib.rs"]
    ]

    :ok = Lines.put(command.id, 0, lines ++ tail)
    Jobs.get!(command.id)
  end

  # Ended without keeping, with its steps and the times of its three lines.
  defp ended!(command, worker) do
    assignment = FakeWorker.assign(command, worker)
    {:ok, _} = Storage.put(assignment["store"]["log_key"], "building\nlinking\n3 passed\n")
    {:ok, _} = Storage.put(assignment["store"]["times_key"], "0\n14000\n61000\n")

    {:ok, _job} =
      Jobs.complete(command.id, %Result{
        status: :finished,
        outcome: :converged,
        exit_status: 3,
        duration_ms: 61_500,
        log: assignment["store"]["log_key"],
        times: assignment["store"]["times_key"]
      })

    job = Jobs.get!(command.id)
    :ok = record_steps(job, steps())
    job
  end

  defp steps do
    [
      %{"name" => "snapshot", "at" => 1_795_000_000_000, "ms" => 1_900, "source" => "copy"},
      %{"name" => "fetch", "at" => 1_795_000_001_900, "ms" => 700},
      %{"name" => "reset", "at" => 1_795_000_002_600, "ms" => 400},
      %{"name" => "own", "at" => 1_795_000_003_000, "ms" => 9_800},
      %{"name" => "devshell", "at" => 1_795_000_012_800, "ms" => 4_100},
      %{"name" => "script", "at" => 1_795_000_016_900, "ms" => 41_000},
      %{"name" => "ignored", "at" => 1_795_000_057_900, "skipped" => "not_kept"},
      %{"name" => "hand_back", "at" => 1_795_000_057_900, "ms" => 8_200},
      %{"name" => "keep", "at" => 1_795_000_066_100, "skipped" => "status"},
      %{"name" => "upload", "at" => 1_795_000_066_100, "ms" => 900},
      %{"name" => "discard", "at" => 1_795_000_067_000, "ms" => 600},
      %{"name" => "sweep", "at" => 1_795_000_067_600, "ms" => 40},
      %{"name" => "other", "at" => 1_795_000_067_640, "ms" => 60}
    ]
  end

  # What the machine holds, as `Forge.FakeExplore` answers it.
  defp files do
    many =
      for n <- 1..450,
          into: %{},
          do: {"many/file-#{String.pad_leading("#{n}", 3, "0")}.o", {:file, "x"}}

    Map.merge(many, %{
      "src/main.rs" => {:file, "fn main() {\n    println!(\"scores\");\n}\n"},
      "src/lib.rs" => {:file, "pub fn rank() {}\n"},
      "target/debug/app" => {:file, <<0, 1, 2, 3, 255>>},
      "target/debug/deps/libscores.rlib" => {:file, <<0>>, 312_000_000},
      "README.md" => {:file, "# scores\n"},
      "to-etc" => {:link, "/etc/shadow"},
      "<b>markup.txt" => {:file, "x"},
      String.duplicate("a-very-long-name-", 18) => {:file, "x"},
      <<0xFF, 0xFE, "bad-name">> => {:file, "x"},
      "big.log" => {:file, "the first of it\n" <> String.duplicate("a line\n", 100), 41_943_040}
    })
  end
end
