defmodule Forge.ReleaseRecordsTest do
  @moduledoc """
  The record a release leaves when it ends `done` (`docs/design/ticket-types.md` § The record, the
  tag, the history): when it is written, what it holds, and that the tag outcome never changes the
  release. Real repositories and real hooks, the fake worker for the jobs.
  """

  use Forge.DataCase, async: false

  import Ecto.Query
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
    Projects,
    ReleaseRecords,
    Repo,
    Storage,
    Tickets
  }

  alias Forge.Jobs.Job
  alias Forge.ReleaseRecords.{Record, Tag}

  # Two job states, so that two jobs can write the same group and the later one is the release's.
  @release """
  version: 1
  description: Cut a release.
  release: true
  release_files: ["dist/*"]
  release_notes: release-notes.md
  initial: building
  states:
    building:
      prompt: agents/release.md
      produces: [build.md, "dist/*", "shots/*"]
      budget: { turns: 10, cost: 1.00 }
    releasing:
      prompt: agents/release.md
      produces: [release-notes.md, changeset, commit-message]
      budget: { turns: 10, cost: 1.00 }
    merged:
      on_enter: merge
  transitions:
    - { from: building, to: releasing }
    - { from: releasing, to: merged }
  limits: { ticket_cost: 5.00 }
  """

  @no_keys @release
           |> String.replace("release_files: [\"dist/*\"]\n", "")
           |> String.replace("release_notes: release-notes.md\n", "")

  # Ends in a state that merges nothing.
  @no_merge """
  version: 1
  description: Cut a release.
  release: true
  initial: releasing
  states:
    releasing:
      prompt: agents/release.md
      produces: [release-notes.md]
      budget: { turns: 10, cost: 1.00 }
    shipped: {}
  transitions:
    - { from: releasing, to: shipped }
  limits: { ticket_cost: 5.00 }
  """

  @dev """
  version: 1
  description: Ordinary work.
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset, commit-message]
      budget: { turns: 10, cost: 1.00 }
    merged:
      on_enter: merge
  transitions:
    - { from: implementing, to: merged }
  limits: { ticket_cost: 5.00 }
  """

  setup do
    data_dir = tmp_dir("rr-data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("rr-store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    %{worker: FakeWorker.connect()}
  end

  defp project_with(workflow \\ @release, files \\ %{}) do
    repo =
      seeded_repo(
        Map.merge(
          %{
            ".forge/workflow.yml" => nil,
            ".forge/agents/implement.md" => "Do it.\n",
            ".forge/agents/release.md" => "Cut it.\n",
            ".forge/workflows/dev.yml" => @dev,
            ".forge/workflows/release.yml" => workflow
          },
          files
        )
      )

    {:ok, project} =
      register_owned!(%{name: "rr-#{System.unique_integer([:positive])}", repo_path: repo})

    %{project: project, repo: Projects.repo_path(project), admin: member_fixture(project)}
  end

  defp start!(project, admin) do
    {:ok, ticket} = Operator.start_release(project, admin, "")
    ticket
  end

  defp pending(ticket) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    job
  end

  defp run_pending(worker, ticket, scenario \\ "success", opts) do
    {:ok, _job} = FakeWorker.run(pending(ticket), worker, scenario, opts)
    Tickets.get!(ticket.id)
  end

  defp doc(front \\ "", body \\ "# Notes\n\nWhat changed.\n"),
    do: "---\noutcome: done\n" <> front <> "---\n" <> body

  defp building(worker, ticket, front \\ "") do
    run_pending(worker, ticket, written: %{"build.md" => doc(front)})
  end

  defp releasing(worker, ticket, version, front \\ "") do
    front = if version, do: "version: #{version}\n" <> front, else: front

    run_pending(worker, ticket,
      commit: {"VERSION", "#{version}-#{System.unique_integer([:positive])}\n"},
      written: %{
        "release-notes.md" => doc(front),
        "commit-message" => FakeWorker.commit_message()
      }
    )
  end

  # The whole release, concluded: returns the done ticket and its record.
  defp conclude!(worker, ticket, version, front \\ "") do
    ticket = worker |> building(ticket) |> then(&releasing(worker, &1, version, front))
    assert ticket.status == :done
    {ticket, Repo.get_by(Record, ticket_id: ticket.id)}
  end

  defp head(repo) do
    {:ok, sha} = Git.resolve(repo, "refs/heads/main")
    sha
  end

  defp tags(repo) do
    {:ok, out} = Git.run(repo, ["tag", "--list"])
    String.split(out, "\n", trim: true)
  end

  defp blob!(ticket, job, name, bytes) do
    key = Storage.Key.job(job.id, "#{name}-#{System.unique_integer([:positive])}")
    {:ok, %{hash: hash}} = Storage.put(key, bytes)

    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :blob, {:job, job.id}, %{
        blob_uri: Storage.uri(key),
        content_hash: hash
      })

    version
  end

  describe "when it is written" do
    test "a release that merges leaves one record: version, commit, date, ticket and tag", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()

      {ticket, record} = conclude!(ctx.worker, start!(project, admin), "0.18.0")

      assert record.version == "0.18.0"
      assert record.project_id == project.id
      assert record.commit_sha == head(repo)
      refute record.commit_sha == ""
      assert DateTime.diff(DateTime.utc_now(), record.concluded_at) in 0..60
      assert %Record{ticket_id: ticket_id} = record
      assert ticket_id == ticket.id
      assert {record.tag_name, record.tag_status} == {"v0.18.0", :tagged}
      assert tags(repo) == ["v0.18.0"]
    end

    test "the tag is on the record's commit and carries the notes without their front matter",
         ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), "v1.2.3")

      assert record.version == "v1.2.3"
      assert record.tag_name == "v1.2.3"
      assert record.notes == "# Notes\n\nWhat changed."
      assert {record.notes_document, record.notes_version} == {"release-notes.md", 1}

      assert {:ok, peeled} = Git.run(repo, ["rev-parse", "refs/tags/v1.2.3^{commit}"])
      assert String.trim(peeled) == record.commit_sha
      assert {:ok, tag} = Git.run(repo, ["cat-file", "tag", "refs/tags/v1.2.3"])
      assert tag =~ "\n\n# Notes\n\nWhat changed.\n"
      refute tag =~ "outcome: done"
    end

    test "concluding twice leaves one record and one tag", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      {ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")

      assert {:ok, again} = ReleaseRecords.conclude(ticket, head(repo))
      assert again.id == record.id
      Engine.enter(ticket, Tickets.workflow(ticket), "merged", nil)

      assert Repo.aggregate(Record, :count) == 1
      assert tags(repo) == ["v1.0.0"]
    end

    test "records the commit it is given, not whatever the head has moved to", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      {ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      Repo.delete!(record)
      moved = commit_to_default(project, %{"later.txt" => "later\n"})
      refute moved == record.commit_sha

      assert {:ok, again} = ReleaseRecords.conclude(ticket, record.commit_sha)
      assert again.commit_sha == record.commit_sha
      assert head(repo) == moved
    end

    test "a release whose commit was already on the default branch records that commit", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      ticket = building(ctx.worker, start!(project, admin))

      # No commit of its own: the changeset is the base, already in the default branch's history.
      ticket =
        run_pending(ctx.worker, ticket,
          written: %{
            "release-notes.md" => doc("version: 2.0.0\n"),
            "commit-message" => FakeWorker.commit_message()
          }
        )

      assert ticket.status == :done

      assert %Record{commit_sha: sha, tag_status: :tagged} =
               Repo.get_by(Record, ticket_id: ticket.id)

      assert sha == head(repo)
    end

    test "a release that merges nothing records the default branch's head", ctx do
      %{project: project, admin: admin, repo: repo} = project_with(@no_merge)
      before = head(repo)

      ticket =
        run_pending(ctx.worker, start!(project, admin),
          written: %{"release-notes.md" => doc("version: 3.0.0\n")}
        )

      assert ticket.status == :done

      assert %Record{commit_sha: ^before, version: "3.0.0"} =
               Repo.get_by(Record, ticket_id: ticket.id)

      assert tags(repo) == ["v3.0.0"]
    end

    @tag :capture_log
    test "whatever raises while writing is an error answered, and the release stays done", ctx do
      %{project: project, admin: admin} = project_with(@no_merge)

      ticket =
        run_pending(ctx.worker, start!(project, admin),
          written: %{"release-notes.md" => doc("version: 3.0.0\n")}
        )

      Repo.delete_all(Record)

      # A commit the column refuses: the insert raises, and the conclusion reports it.
      assert {:error, %Postgrex.Error{}} =
               ReleaseRecords.conclude(ticket, String.duplicate("a", 300))

      assert Repo.aggregate(Record, :count) == 0
      assert Tickets.get!(ticket.id).status == :done
    end

    @tag :capture_log
    test "a head that cannot be resolved writes no record and fails nothing", ctx do
      %{project: project, admin: admin} = project_with(@no_merge)

      ticket =
        run_pending(ctx.worker, start!(project, admin),
          written: %{"release-notes.md" => doc("version: 3.0.0\n")}
        )

      Repo.delete_all(Record)

      Repo.update_all(from(p in Forge.Projects.Project, where: p.id == ^project.id),
        set: [default_branch: "ghost"]
      )

      assert {:error, {:unknown_ref, "refs/heads/ghost"}} = ReleaseRecords.conclude(ticket, :head)
      assert Repo.aggregate(Record, :count) == 0
      assert Tickets.get!(ticket.id).status == :done
    end

    test "no version is a record with no tag, and says why", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), nil)

      assert record.version == nil
      assert {record.tag_name, record.tag_status} == {nil, :no_version}
      assert record.tag_detail =~ "no version"
      assert tags(repo) == []
    end

    test "an ordinary ticket, a stuck release and a cancelled one leave none", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()

      {:ok, ordinary} = Tickets.admit(project, %{title: "x", ticket_type: "dev"})

      ordinary =
        run_pending(ctx.worker, ordinary,
          commit: {"x.txt", "x\n"},
          written: %{
            "implementation.md" => doc(),
            "commit-message" => FakeWorker.commit_message()
          }
        )

      assert ordinary.status == :done

      stuck = run_pending(ctx.worker, start!(project, admin), "max_turns", [])
      assert stuck.status == :stuck
      assert :skipped = ReleaseRecords.conclude(stuck, head(repo))

      {:ok, cancelled} = Engine.cancel(stuck, {:user, admin.id})
      assert cancelled.status == :cancelled
      assert :skipped = ReleaseRecords.conclude(cancelled, head(repo))

      assert Repo.aggregate(Record, :count) == 0
      assert tags(repo) == []
    end

    test "a done ticket is only concluded when the database says it is done", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      ticket = start!(project, admin)

      # The struct says done; the row does not.
      assert :skipped = ReleaseRecords.conclude(%{ticket | status: :done}, head(repo))
      assert Repo.aggregate(Record, :count) == 0
      _ = ctx
    end

    test "the page's subscribers are told when it is written", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      {ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      Repo.delete!(record)
      Events.subscribe()
      flush()

      assert {:ok, _} = ReleaseRecords.conclude(ticket, head(repo))
      id = ticket.id
      assert_receive {:ticket_changed, ^id}
    end

    defp flush do
      receive do
        _ -> flush()
      after
        0 -> :ok
      end
    end
  end

  describe "the tag" do
    test "a name taken by another commit is reported, named and left alone", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      older = head(repo)
      assert {:tagged, "v1.2.3"} = Tag.make(project, "1.2.3", older, nil)

      {ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.2.3")

      assert ticket.status == :done
      assert {record.tag_name, record.tag_status, record.tag_detail} == {"v1.2.3", :taken, older}
      refute record.commit_sha == older
      assert {:ok, still} = Git.run(repo, ["rev-parse", "refs/tags/v1.2.3^{commit}"])
      assert String.trim(still) == older
    end

    test "two releases of one version are two records and one tag", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      {_first, one} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      {_second, two} = conclude!(ctx.worker, start!(project, admin), "1.0.0")

      assert one.id != two.id
      assert {one.tag_status, two.tag_status} == {:tagged, :taken}
      assert two.tag_detail == one.commit_sha
      assert tags(repo) == ["v1.0.0"]
    end

    test "a tag that cannot be made leaves the release done and says why", ctx do
      %{project: project, admin: admin, repo: repo} = project_with()
      hook = Path.join([repo, "hooks", "pre-receive"])
      original = File.read!(hook)

      File.write!(hook, """
      #!/usr/bin/env bash
      while read -r old new ref; do
        case "$ref" in refs/tags/*) echo "forge: tags are closed today" >&2; exit 1 ;; esac
      done
      exit 0
      """)

      {ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      File.write!(hook, original)

      assert ticket.status == :done
      assert {record.tag_name, record.tag_status} == {"v1.0.0", :failed}
      assert record.tag_detail =~ "git refused the tag"
      assert record.tag_detail =~ "tags are closed today"
      assert tags(repo) == []
      assert record.commit_sha == head(repo)
    end
  end

  describe "files" do
    # Both jobs of the release, with the blobs each wrote put on the ticket before it concludes.
    defp with_blobs(ctx, fun) do
      %{project: project, admin: admin} = project_with()
      ticket = start!(project, admin)
      first = pending(ticket)
      fun.(:first, first, ticket)
      ticket = building(ctx.worker, ticket)
      second = pending(ticket)
      fun.(:second, second, ticket)
      releasing(ctx.worker, ticket, "1.0.0")
    end

    test "lists the named group's files from the last job that wrote any, exact versions", ctx do
      done =
        with_blobs(ctx, fn
          :first, job, ticket ->
            blob!(ticket, job, "dist/old.txt", "old")
            blob!(ticket, job, "dist/app.zip", "first build")
            blob!(ticket, job, "shots/a.png", "png")

          :second, job, ticket ->
            blob!(ticket, job, "dist/app.zip", "second build!")
            blob!(ticket, job, "dist/extra.bin", "xyz")
        end)

      record = Repo.get_by!(Record, ticket_id: done.id)

      assert [
               %{"name" => "dist/app.zip", "version" => 2, "size" => 13},
               %{"name" => "dist/extra.bin", "version" => 1, "size" => 3}
             ] = record.files
    end

    test "a later version of an artifact changes nothing the record lists", ctx do
      done =
        with_blobs(ctx, fn
          :first, _job, _ticket -> :ok
          :second, job, ticket -> blob!(ticket, job, "dist/app.zip", "build")
        end)

      record = Repo.get_by!(Record, ticket_id: done.id)
      job = Jobs.for_ticket(done.id) |> List.last()
      blob!(done, job, "dist/app.zip", "a newer build")

      assert [%{"name" => "dist/app.zip", "version" => 1}] = Repo.reload!(record).files
    end

    test "a workflow without the key has no release files, and an empty group is no error", ctx do
      %{project: project, admin: admin} = project_with(@no_keys)
      ticket = start!(project, admin)
      blob!(ticket, pending(ticket), "dist/app.zip", "build")
      {_ticket, record} = conclude!(ctx.worker, ticket, "1.0.0")
      assert record.files == []

      %{project: project, admin: admin} = project_with()
      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      assert record.files == []
    end
  end

  describe "notes" do
    test "none without the key, and none when the document was never written", ctx do
      %{project: project, admin: admin} = project_with(@no_keys)
      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      assert {record.notes, record.notes_document, record.notes_version} == {nil, nil, nil}

      %{project: project, admin: admin} =
        project_with(
          @no_merge
          |> String.replace("produces: [release-notes.md]", "produces: [other.md]")
          |> String.replace("initial: releasing", "initial: releasing\nrelease_notes: other.md"),
          %{}
        )

      ticket = start!(project, admin)
      done = run_pending(ctx.worker, ticket, written: %{"other.md" => doc("", "   \n")})
      assert Repo.get_by!(Record, ticket_id: done.id).notes == nil
    end

    test "the latest version when it concluded is the one kept", ctx do
      %{project: project, admin: admin} = project_with()
      ticket = start!(project, admin)

      {:ok, _} =
        Artifacts.record_version(ticket.id, "release-notes.md", :document, {:user, admin.id}, %{
          content: "---\noutcome: done\n---\nA person's first text.\n"
        })

      ticket = building(ctx.worker, ticket)
      done = releasing(ctx.worker, ticket, "1.0.0")
      record = Repo.get_by!(Record, ticket_id: done.id)

      assert record.notes_version == 2
      assert record.notes == "# Notes\n\nWhat changed."
    end
  end

  describe "links" do
    @good ~s|links: [{label: Image, url: "https://ghcr.io/x/forge@sha256:abc"}, {label: Docs, url: "http://example.com/d"}]\n|

    test "come from the latest version of each job document, entry by entry", ctx do
      %{project: project, admin: admin} = project_with()
      ticket = start!(project, admin)

      ticket =
        building(
          ctx.worker,
          ticket,
          "links: [{label: Build log, url: \"https://ci.example/1\"}]\n"
        )

      done =
        releasing(ctx.worker, ticket, "1.0.0", @good)

      record = Repo.get_by!(Record, ticket_id: done.id)

      assert [
               %{"label" => "Build log", "document" => "build.md", "version" => 1},
               %{
                 "label" => "Image",
                 "url" => "https://ghcr.io/x/forge@sha256:abc",
                 "document" => "release-notes.md",
                 "version" => 1
               },
               %{"label" => "Docs", "url" => "http://example.com/d"}
             ] = record.links
    end

    test "a malformed list or entry is dropped alone and never fails the job", ctx do
      %{project: project, admin: admin} = project_with()

      bad = """
      links:
        - {label: Fine, url: "https://ok.example/a"}
        - {label: "", url: "https://ok.example/b"}
        - {label: "   ", url: "https://ok.example/b2"}
        - {label: No url}
        - {label: Script, url: "javascript:alert(1)"}
        - {label: Data, url: "data:text/html,x"}
        - {label: Ftp, url: "ftp://ok.example/f"}
        - {label: Relative, url: "/just/a/path"}
        - {label: Hostless, url: "https:///path"}
        - {label: Spaces, url: "https://ok.example/a b"}
        - {label: Control, url: "https://ok.example/a\\x01b"}
        - {label: 7, url: "https://ok.example/c"}
        - just a string
        - {label: Last, url: "https://ok.example/d"}
      """

      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0", bad)
      assert Enum.map(record.links, & &1["label"]) == ["Fine", "Last"]

      %{project: project, admin: admin} = project_with()
      {done, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0", "links: nonsense\n")
      assert done.status == :done
      assert record.links == []
    end

    test "only the first fifty entries of a document are read", ctx do
      %{project: project, admin: admin} = project_with()
      entries = Enum.map_join(1..60, ", ", &~s|{label: L#{&1}, url: "https://x.example/#{&1}"}|)

      {_ticket, record} =
        conclude!(ctx.worker, start!(project, admin), "1.0.0", "links: [#{entries}]\n")

      assert length(record.links) == 50
      assert List.last(record.links)["label"] == "L50"
    end

    test "a label of exactly the bound is kept", ctx do
      %{project: project, admin: admin} = project_with()
      label = String.duplicate("l", 200)

      {_ticket, record} =
        conclude!(
          ctx.worker,
          start!(project, admin),
          "1.0.0",
          ~s|links: [{label: #{label}, url: "https://x.example/a"}]\n|
        )

      assert [%{"label" => ^label}] = record.links
    end

    test "labels and urls over their bounds are dropped", ctx do
      %{project: project, admin: admin} = project_with()
      long_label = String.duplicate("l", 201)
      long_url = "https://ok.example/" <> String.duplicate("u", 2048)

      front =
        "links: [{label: #{long_label}, url: \"https://ok.example/a\"}, {label: Long, url: \"#{long_url}\"}, {label: Edge, url: \"https://ok.example/#{String.duplicate("e", 2029)}\"}]\n"

      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0", front)
      assert Enum.map(record.links, & &1["label"]) == ["Edge"]
    end

    test "a person's later version, or a chat's document, publishes none", ctx do
      %{project: project, admin: admin} = project_with()
      ticket = start!(project, admin)
      first = pending(ticket)

      ticket =
        building(
          ctx.worker,
          ticket,
          "links: [{label: From a chat, url: \"https://x.example/1\"}]\n"
        )

      Repo.update_all(from(j in Job, where: j.id == ^first.id),
        set: [kind: :chat, state: nil, spec: nil]
      )

      {:ok, _} =
        Artifacts.record_version(ticket.id, "by-hand.md", :document, {:user, admin.id}, %{
          content: "---\nlinks: [{label: By hand, url: \"https://x.example/2\"}]\n---\nx\n"
        })

      done =
        releasing(
          ctx.worker,
          ticket,
          "1.0.0",
          "links: [{label: Kept, url: \"https://x.example/3\"}]\n"
        )

      record = Repo.get_by!(Record, ticket_id: done.id)

      assert Enum.map(record.links, & &1["label"]) == ["Kept"]
    end

    test "a presentation's links are read, as its version: is", ctx do
      %{project: project, admin: admin} = project_with()
      ticket = start!(project, admin)
      job = pending(ticket)
      ticket = building(ctx.worker, ticket)

      {:ok, _} =
        Artifacts.record_version(ticket.id, "deck.md", :presentation, {:job, job.id}, %{
          content: "---\nlinks: [{label: Deck, url: \"https://x.example/deck\"}]\n---\nx\n"
        })

      done = releasing(ctx.worker, ticket, "1.0.0")

      assert [%{"label" => "Deck", "document" => "deck.md"}] =
               Repo.get_by!(Record, ticket_id: done.id).links
    end

    test "the later version of a document is the one read", ctx do
      %{project: project, admin: admin} = project_with()
      ticket = start!(project, admin)
      job = pending(ticket)

      ticket =
        building(ctx.worker, ticket, "links: [{label: Old, url: \"https://x.example/old\"}]\n")

      {:ok, _} =
        Artifacts.record_version(ticket.id, "build.md", :document, {:job, job.id}, %{
          content: "---\nlinks: [{label: New, url: \"https://x.example/new\"}]\n---\nx\n"
        })

      done = releasing(ctx.worker, ticket, "1.0.0")
      record = Repo.get_by!(Record, ticket_id: done.id)
      assert [%{"label" => "New", "version" => 2}] = record.links
    end
  end

  describe "reading" do
    test "get! is not found for another project's record and for anything that is not an id",
         ctx do
      %{project: project, admin: admin} = project_with()
      %{project: other} = project_with()
      {_ticket, record} = conclude!(ctx.worker, start!(project, admin), "1.0.0")

      assert ReleaseRecords.get!(project, record.id).id == record.id
      assert_raise Ecto.NoResultsError, fn -> ReleaseRecords.get!(other, record.id) end
      assert_raise Ecto.NoResultsError, fn -> ReleaseRecords.get!(project, "not-an-id") end

      assert_raise Ecto.NoResultsError, fn ->
        ReleaseRecords.get!(project, Ecto.UUID.generate())
      end
    end

    test "list, count and latest read one project's records and no other's", ctx do
      %{project: project, admin: admin} = project_with()
      %{project: other, admin: other_admin} = project_with()
      {_t, mine} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      {_t, theirs} = conclude!(ctx.worker, start!(other, other_admin), "2.0.0")

      assert Enum.map(ReleaseRecords.list(project, 10), & &1.id) == [mine.id]
      assert Enum.map(ReleaseRecords.list(other, 10), & &1.id) == [theirs.id]
      assert ReleaseRecords.count(project) == 1
      assert ReleaseRecords.latest(project).id == mine.id
      assert ReleaseRecords.latest(other).id == theirs.id
    end

    test "list is newest first, bounded, and counted", ctx do
      %{project: project, admin: admin} = project_with()
      {_t, one} = conclude!(ctx.worker, start!(project, admin), "1.0.0")
      {_t, two} = conclude!(ctx.worker, start!(project, admin), "1.1.0")

      assert ReleaseRecords.count(project) == 2
      assert Enum.map(ReleaseRecords.list(project, 10), & &1.id) == [two.id, one.id]
      assert Enum.map(ReleaseRecords.list(project, 1), & &1.id) == [two.id]
      assert ReleaseRecords.latest(project).id == two.id
    end
  end
end
