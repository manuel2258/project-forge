defmodule Forge.ArchiveTest do
  @moduledoc """
  The project's archive as the platform composes it (`docs/design/archive.md`): what is listed,
  in what names, with what figures, and — the part that is a guard — only ever from the project
  the question is asked in.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Archive, Artifacts, Events, Storage}
  alias Forge.Artifacts.Version

  setup do
    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-archive-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      File.rm_rf!(dir)
    end)

    project = project_fixture()
    %{project: project, ticket: ticket_fixture(%{project: project, number: 1})}
  end

  defp document!(ticket, name, content) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :document, {:user, Ecto.UUID.generate()}, %{
        content: content,
        parse: false
      })

    version
  end

  defp blob!(ticket, name, bytes) do
    key = "archive-test/#{System.unique_integer([:positive])}"
    {:ok, %{hash: hash}} = Storage.put(key, bytes)

    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :blob, {:user, Ecto.UUID.generate()}, %{
        blob_uri: Storage.uri(key),
        content_hash: hash
      })

    version
  end

  defp paths({:ok, %{"files" => files}}), do: files |> Enum.map(& &1["path"]) |> Enum.sort()

  describe "the root" do
    test "has a line per ticket of every status, with what each holds and when it was taken",
         %{project: project, ticket: ticket} do
      document!(ticket, "plan.md", "one")
      document!(ticket, "plan.md", "two")
      blob!(ticket, "log.txt", "build output")

      done = ticket_fixture(%{project: project, number: 2, title: "Done one"})
      gone = ticket_fixture(%{project: project, number: 3, title: "Gone"})
      Repo.update!(Ecto.Changeset.change(done, status: :done))
      Repo.update!(Ecto.Changeset.change(gone, status: :cancelled))
      document!(done, "report.md", "ok")

      now = ~U[2026-03-04 05:06:07Z]
      root = Archive.root(project, now)

      assert root["taken_at"] == "2026-03-04T05:06:07Z"
      assert root["tickets"] == [1, 2, 3]
      assert Enum.map(root["files"], & &1["path"]) == ["index.md", "jobs.tsv"]

      %{"inline" => index} = Enum.find(root["files"], &(&1["path"] == "index.md"))
      assert index =~ "Taken at 2026-03-04T05:06:07Z"
      assert index =~ "number | title | type | state | status | documents | versions | files"

      # Documents, versions and files: ticket 1 has plan.md twice and one file.
      assert index =~
               ~r/^1 \| Persist the high score table \| n\/a \| refining \| active \| 1 \| 3 \| 1$/m

      assert index =~ ~r/^2 \| Done one \| n\/a \| refining \| done \| 1 \| 1 \| 0$/m
      assert index =~ ~r/^3 \| Gone \| n\/a \| refining \| cancelled \| 0 \| 0 \| 0$/m
    end

    test "a title cannot open a second cell or a second line", %{project: project} do
      ticket_fixture(%{project: project, number: 7, title: "a | b\tc\nd"})

      %{"inline" => index} =
        Enum.find(Archive.root(project)["files"], &(&1["path"] == "index.md"))

      assert index =~ "7 | a b c d | n/a"
    end

    test "does not list another project's tickets", %{project: project} do
      other = project_fixture()
      ticket_fixture(%{project: other, number: 41, title: "Theirs"})

      assert Archive.root(project)["tickets"] == [1]
      refute inspect(Archive.root(project)) =~ "Theirs"
    end
  end

  describe "the jobs ledger" do
    test "has a line for every job, `n/a` for what was never recorded, and no account",
         %{project: project, ticket: ticket} do
      started = ~U[2026-03-04 05:06:07Z]
      # A job that ran on a credential and a machine, both of which the ledger must leave out.
      credential = credential_fixture(Forge.AccountsFixtures.user_fixture())
      worker = Forge.FakeWorker.connect()

      never =
        job_fixture(%{ticket: ticket})
        |> Ecto.Changeset.change(credential_id: credential.id, worker_id: worker.id)
        |> Repo.update!()

      ran =
        job_fixture(%{ticket: ticket, attempt: 2, status: :running})
        |> Ecto.Changeset.change(started_at: started, turns: 12, cost_usd: Decimal.new("1.50"))
        |> Repo.update!()

      run!(ran)
      run!(ran)
      chat = chat_fixture(%{project: project, model: "opus", effort: "high"})

      other =
        job_fixture(%{
          ticket: ticket_fixture(%{project: project_fixture(), number: 1}),
          state: "zz-theirs"
        })

      %{"inline" => all} = Enum.find(Archive.root(project)["files"], &(&1["path"] == "jobs.tsv"))
      [header | rows] = String.split(all, "\n", trim: true)

      assert header ==
               "ticket\tstate\tattempt\tkind\toutcome\tstatus\tstarted_at\tfinished_at\tturns\tcost_usd\tmodel\teffort\tmemory_max\tcores\truns"

      assert length(rows) == 3
      fields = Enum.map(rows, &String.split(&1, "\t"))
      assert Enum.all?(fields, &(length(&1) == 15))

      refute all =~ credential.id
      refute all =~ worker.id

      [never_row] = Enum.filter(fields, &(Enum.at(&1, 2) == "1" and Enum.at(&1, 3) == "workflow"))
      # memory_max and cores are what the job asked for, in their own columns.
      assert Enum.at(never_row, 12) == Integer.to_string(never.memory_max)
      assert Enum.at(never_row, 13) == Integer.to_string(never.cores)
      assert Enum.at(never_row, 4) == "n/a"
      assert Enum.at(never_row, 6) == "n/a"
      assert Enum.at(never_row, 14) == "0"

      [ran_row] = Enum.filter(fields, &(Enum.at(&1, 2) == "2"))
      assert Enum.at(ran_row, 5) == "running"
      assert Enum.at(ran_row, 6) == "2026-03-04T05:06:07Z"
      assert Enum.at(ran_row, 8) == "12"
      assert Enum.at(ran_row, 9) == "1.50"
      assert Enum.at(ran_row, 14) == "2"
      assert Enum.at(ran_row, 12) == Integer.to_string(never.memory_max)

      [chat_row] = Enum.filter(fields, &(Enum.at(&1, 3) == "chat"))
      # A project chat has no ticket.
      assert Enum.at(chat_row, 0) == "n/a"
      assert Enum.at(chat_row, 10) == "opus"
      assert Enum.at(chat_row, 11) == "high"

      refute all =~ other.state
    end

    test "a ticket's own ledger is that ticket's jobs only", %{project: project, ticket: ticket} do
      job_fixture(%{ticket: ticket})
      job_fixture(%{ticket: ticket_fixture(%{project: project, number: 2})})

      {:ok, %{"files" => files}} = Archive.ticket(project, "1")
      %{"inline" => ledger} = Enum.find(files, &(&1["path"] == "jobs.tsv"))
      assert length(String.split(ledger, "\n", trim: true)) == 2
    end
  end

  describe "a ticket" do
    test "has the latest under its name and every version under a versioned one",
         %{project: project, ticket: ticket} do
      document!(ticket, "plan.md", "one")
      document!(ticket, "plan.md", "twö")
      document!(ticket, "ticket", "the body")

      {:ok, %{"files" => files}} = Archive.ticket(project, "1")
      by_path = Map.new(files, &{&1["path"], &1})

      assert paths({:ok, %{"files" => files}}) ==
               ["jobs.tsv", "plan.md", "plan.v001.md", "plan.v002.md", "ticket", "ticket.v001"]

      # The latest is the same version as the newest, and the size is bytes, not characters.
      assert by_path["plan.md"]["ref"] == by_path["plan.v002.md"]["ref"]
      refute by_path["plan.v001.md"]["ref"] == by_path["plan.v002.md"]["ref"]
      assert by_path["plan.v002.md"]["size"] == 4

      assert by_path["plan.v001.md"]["sha256"] ==
               :crypto.hash(:sha256, "one") |> Base.encode16(case: :lower)
    end

    test "has uploaded files and groups with their names, bytes as they are",
         %{project: project, ticket: ticket} do
      binary = <<0, 255, 254, "x", 0>>
      first = blob!(ticket, "reports/test.txt", binary)
      blob!(ticket, "reports/test.txt", "second")
      blob!(ticket, "build.log", "log")

      {:ok, %{"files" => files} = listing} = Archive.ticket(project, 1)

      assert paths({:ok, listing}) ==
               [
                 "build.log",
                 "build.v001.log",
                 "jobs.tsv",
                 "reports/test.txt",
                 "reports/test.v001.txt",
                 "reports/test.v002.txt"
               ]

      entry = Enum.find(files, &(&1["path"] == "reports/test.v001.txt"))
      assert entry["ref"] == first.id
      assert entry["size"] == byte_size(binary)
      assert entry["sha256"] == :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    end

    test "pads to three digits and goes wider past 999" do
      assert Archive.versioned("plan.md", 1) == "plan.v001.md"
      assert Archive.versioned("plan.md", 999) == "plan.v999.md"
      assert Archive.versioned("plan.md", 1000) == "plan.v1000.md"
      assert Archive.versioned("ticket", 12) == "ticket.v012"
      assert Archive.versioned("reports/out.txt", 3) == "reports/out.v003.txt"
      assert Archive.versioned(".hidden", 1) == ".hidden.v001"
    end

    test "leaves out the changeset, proposals and transcripts", %{
      project: project,
      ticket: ticket
    } do
      document!(ticket, "plan.md", "p")
      artifact = artifact_fixture(%{ticket: ticket, name: "changeset", kind: :blob})

      version_fixture(%{
        artifact: artifact,
        content: nil,
        blob_uri: "git:" <> String.duplicate("a", 40)
      })

      document!(ticket, "proposal-x.md", "x")
      blob!(ticket, "transcript-1.jsonl", "t")

      assert paths(Archive.ticket(project, 1)) == ["jobs.tsv", "plan.md", "plan.v001.md"]
    end

    # Two guards that each cover the other in the ordinary case: the reserved name, and a version
    # that is a commit whatever it is called (`Artifacts.commit/1` is what says a changeset is one).
    test "leaves out a changeset by its name, and a commit by what it points at",
         %{project: project, ticket: ticket} do
      blob!(ticket, "changeset", "stored like a file")
      artifact = artifact_fixture(%{ticket: ticket, name: "patch.diff", kind: :blob})

      version_fixture(%{
        artifact: artifact,
        content: nil,
        blob_uri: "git:" <> String.duplicate("b", 40)
      })

      assert paths(Archive.ticket(project, 1)) == ["jobs.tsv"]

      # And the index does not count them: what it says a ticket holds is what can be opened.
      %{"inline" => index} =
        Enum.find(Archive.root(project)["files"], &(&1["path"] == "index.md"))

      assert index =~ ~r/^1 \| .* \| 0 \| 0 \| 0$/m
    end

    test "does not let a file called jobs.tsv stand in for the ledger", %{
      project: project,
      ticket: ticket
    } do
      document!(ticket, "jobs.tsv", "forged ledger")
      job_fixture(%{ticket: ticket})

      {:ok, %{"files" => files}} = Archive.ticket(project, 1)
      ledgers = Enum.filter(files, &(&1["path"] == "jobs.tsv"))

      # Nor are its versions listed under names that look like the ledger's.
      refute Enum.any?(files, &String.starts_with?(&1["path"], "jobs.v"))

      assert [%{"inline" => ledger}] = ledgers
      refute ledger =~ "forged"
      assert ledger =~ "ticket\tstate"
    end

    test "drops a blob whose bytes are gone rather than listing what cannot be read",
         %{project: project, ticket: ticket} do
      artifact = artifact_fixture(%{ticket: ticket, name: "gone.log", kind: :blob})
      version_fixture(%{artifact: artifact, content: nil, blob_uri: "store:nothing/here"})

      assert paths(Archive.ticket(project, 1)) == ["jobs.tsv"]
    end

    test "is not found for a number the project does not have, whoever has it",
         %{project: project} do
      other = project_fixture()
      theirs = ticket_fixture(%{project: other, number: 50})
      document!(theirs, "secret.md", "theirs")

      assert Archive.ticket(project, 50) == :not_found
      assert Archive.ticket(project, "50") == :not_found
      assert Archive.ticket(project, "abc") == :not_found
      assert Archive.ticket(project, "1; drop") == :not_found
      assert Archive.ticket(project, "-1") == :not_found
      assert Archive.ticket(project, "99999999999999") == :not_found
      assert Archive.ticket(project, nil) == :not_found
    end

    test "never lists a name that is not one, or a file and a folder of one name" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 1})
      document!(ticket, "ok.md", "x")
      document!(ticket, "a", "file")

      for name <- ["a/b", "x/..", "../etc", "a/b/c"],
          do:
            artifact_fixture(%{ticket: ticket, name: name, kind: :document})
            |> then(&version_fixture(%{artifact: &1}))

      listed = paths(Archive.ticket(project, 1))
      assert "ok.md" in listed
      assert "a" in listed
      refute "a/b" in listed
      assert listed == ["a", "a.v001", "jobs.tsv", "ok.md", "ok.v001.md"]
      refute "a/b/c" in listed
    end

    test "valid_path? is one name or a group's folder and a name" do
      assert Archive.valid_path?("plan.md")
      assert Archive.valid_path?("reports/out.txt")
      refute Archive.valid_path?("a/b/c")
      refute Archive.valid_path?("")
      refute Archive.valid_path?("..")
      refute Archive.valid_path?("a/..")
      refute Archive.valid_path?("a/")
      refute Archive.valid_path?("a" <> <<0>>)
      refute Archive.valid_path?(String.duplicate("x", 256))
      refute Archive.valid_path?(<<255>>)
      refute Archive.valid_path?(nil)
    end
  end

  describe "a version" do
    test "is found in its own project by ticket and id", %{project: project, ticket: ticket} do
      version = document!(ticket, "plan.md", "x")

      assert {:ok, %Version{id: id}, %{ticket: 1, artifact: "plan.md"}} =
               Archive.version(project, 1, version.id)

      assert id == version.id
      assert {:ok, _, _} = Archive.version(project, "1", version.id)
    end

    test "is not found in another project's, in another ticket, or as anything but a version id",
         %{project: project, ticket: ticket} do
      other = project_fixture()
      theirs = ticket_fixture(%{project: other, number: 1})
      foreign = document!(theirs, "plan.md", "theirs")
      version = document!(ticket, "plan.md", "mine")
      sibling = ticket_fixture(%{project: project, number: 2})

      # B's version through A's door, under B's own ticket number and under A's.
      assert Archive.version(project, 1, foreign.id) == :not_found
      assert Archive.version(project, 2, foreign.id) == :not_found
      # The right project, the wrong ticket.
      assert Archive.version(project, sibling.number, version.id) == :not_found
      assert Archive.version(project, 1, "not-an-id") == :not_found
      assert Archive.version(project, 1, "../" <> version.id) == :not_found
      assert Archive.version(project, 1, Ecto.UUID.generate()) == :not_found
      assert Archive.version(project, "x", version.id) == :not_found
    end

    test "is not found for the changeset, a proposal or a transcript", %{
      project: project,
      ticket: ticket
    } do
      changeset = artifact_fixture(%{ticket: ticket, name: "changeset", kind: :blob})

      git =
        version_fixture(%{
          artifact: changeset,
          content: nil,
          blob_uri: "git:" <> String.duplicate("a", 40)
        })

      proposal = document!(ticket, "proposal-x.md", "p")
      transcript = blob!(ticket, "transcript-1.jsonl", "t")

      for version <- [git, proposal, transcript],
          do: assert(Archive.version(project, 1, version.id) == :not_found)
    end
  end

  describe "the record of what was opened, in the lists an operator reads" do
    test "is in none of them, and is still there to be read", %{project: project, ticket: ticket} do
      job = job_fixture(%{ticket: ticket})
      version = document!(ticket, "plan.md", "one")
      {:ok, v, facts} = Archive.version(project, 1, version.id)
      :recorded = Archive.record_read(job, v, facts)

      for events <- [
            Events.for_job(job.id),
            Events.for_ticket(ticket.id),
            Events.for_project(project.id, 50)
          ] do
        refute Enum.any?(events, &(&1.type == "job.archive_read"))
      end

      assert [%{type: "job.archive_read"}] = Events.archive_reads(job.id)
      # And the rest of what a list holds is still there: the version's own write.
      assert Enum.any?(Events.for_ticket(ticket.id), &(&1.type == "artifact.version_written"))
    end
  end

  describe "the record of what was opened" do
    test "is one event per distinct version, and a count that says so", %{
      project: project,
      ticket: ticket
    } do
      job = job_fixture(%{ticket: ticket})
      other_job = job_fixture(%{ticket: ticket, attempt: 2})
      one = document!(ticket, "plan.md", "one")
      two = document!(ticket, "plan.md", "two")

      assert Archive.reads(job.id) == 0

      {:ok, v1, facts} = Archive.version(project, 1, one.id)
      assert Archive.record_read(job, v1, facts) == :recorded
      assert Archive.record_read(job, v1, facts) == :seen
      {:ok, v2, facts2} = Archive.version(project, 1, two.id)
      assert Archive.record_read(job, v2, facts2) == :recorded

      assert Archive.reads(job.id) == 2
      assert Archive.reads(other_job.id) == 0

      # What was opened, as ticket, artifact and version.
      reads =
        for %{payload: payload} <- Events.archive_reads(job.id), do: payload

      assert Enum.map(reads, &{&1["ticket"], &1["artifact"], &1["version"]}) == [
               {1, "plan.md", 1},
               {1, "plan.md", 2}
             ]

      # The same version, opened by another job, is that job's own record.
      assert Archive.record_read(other_job, v1, facts) == :recorded
    end
  end
end
