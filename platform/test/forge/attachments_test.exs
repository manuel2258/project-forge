defmodule Forge.AttachmentsTest do
  @moduledoc """
  Files people attach (`docs/design/attachments.md`): the names made from what is uploaded, the
  staging, the claim under limits, the pool as a run is handed it, and withdrawing.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures, only: [tmp_dir: 1]

  alias Forge.{Artifacts, Attachments, Events, Repo, Storage}
  alias Forge.Attachments.{Attachment, Batch, Upload}

  setup do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    limits = Application.get_env(:forge, Forge.Attachments, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, store)
      Application.put_env(:forge, Forge.Attachments, limits)
    end)

    project = project_fixture()
    ticket = ticket_fixture(%{project: project})
    user = member_fixture(project, :member)
    admin = member_fixture(project, :admin)

    %{project: project, ticket: ticket, pool: {:ticket, ticket.id}, user: user, admin: admin}
  end

  defp limits!(overrides), do: Application.put_env(:forge, Forge.Attachments, overrides)

  # A staged file with these bytes, as the upload route would leave it.
  defp staged!(project, actor, original, bytes \\ "bytes") do
    path = Path.join(tmp_dir("src"), "#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    {:ok, upload} = Attachments.stage(project, actor, {:file, path}, original)
    %{id: upload.id, name: original}
  end

  defp claim!(pool, actor, uploads, opts \\ []) do
    batch = %Batch{
      uploads: uploads,
      not_received: Keyword.get(opts, :failed, []),
      whole?: Keyword.get(opts, :whole?, false)
    }

    Attachments.claim(pool, actor, batch, Keyword.get(opts, :kind, :note), :added)
  end

  describe "name/1" do
    test "is never a path" do
      assert Attachments.name("../x") == "x"
      assert Attachments.name("/etc/x") == "x"
      assert Attachments.name("C:\\Users\\me\\shot.png") == "shot.png"
      assert Attachments.name("a/b/..") == "file"
    end

    test "keeps the extension and turns what is not a name into dashes" do
      assert Attachments.name("Screen Shot 2026.png") == "Screen-Shot-2026.png"
      assert Attachments.name("<script>alert(1)</script>.svg") == "script-.svg"
      assert Attachments.name("ünï.JPG") == "n-.JPG"
      assert Attachments.name("---.png") == "png"
    end

    test "a leading dot or dash is stripped and an empty name is a file" do
      assert Attachments.name(".env") == "env"
      assert Attachments.name("") == "file"
      assert Attachments.name("///") == "file"
    end

    test "is cut to 200 bytes with its extension" do
      name = Attachments.name(String.duplicate("a", 300) <> ".png")
      assert byte_size(name) == 200
      assert String.ends_with?(name, ".png")
    end

    test "never reads as the folder's spelling of an earlier version" do
      assert Attachments.name("shot.v001.png") == "shot-v001.png"
    end

    test "an extensionless name never takes another file's versioned spelling" do
      assert Attachments.name("shot.v001") == "shot-v001"
      assert Attachments.name("shot.v2") == "shot-v2"
      assert Attachments.name("shot") == "shot"
      assert Attachments.name("a.v1.png") == "a-v1.png"
    end

    test "always passes the validator's rule" do
      for original <- [
            "",
            "..",
            "a b",
            "\n",
            "é",
            "x" <> String.duplicate("é", 400),
            "a/../../b.png"
          ] do
        assert ForgeCore.Workflow.valid_name?(Attachments.name(original)), inspect(original)
      end
    end
  end

  describe "staging" do
    test "keeps the bytes under an upload key and counts nothing", %{
      project: project,
      user: user,
      pool: pool
    } do
      %{id: id} = staged!(project, user, "a.png", "12345")

      assert %Upload{size: 5, key: "upload/" <> _} = upload = Repo.get!(Upload, id)
      assert {:ok, "12345"} = Storage.get(upload.key)
      assert Attachments.pool(pool) == []
      assert Attachments.room(pool) == %{files: 100, bytes: 5 * 1024 * 1024 * 1024}
    end

    test "a file past the limit is refused and its bytes deleted", %{project: project, user: user} do
      limits!(file_bytes: 4)
      path = Path.join(tmp_dir("src"), "big")
      File.write!(path, "12345")

      assert {:error, {:attachments_refused, [{"big.bin", :file_bytes}]}} =
               Attachments.stage(project, user, {:file, path}, "big.bin")

      assert Repo.aggregate(Upload, :count) == 0

      assert Storage.stat(Storage.Key.upload(Ecto.UUID.generate())) == {:error, :not_found}
      dir = Path.join(Application.get_env(:forge, Forge.Storage)[:dir], "upload")
      assert not File.dir?(dir) or File.ls!(dir) == []
    end

    test "discard leaves another project's staged file alone", %{project: project, user: user} do
      other = project_fixture()
      theirs = staged!(other, user, "x.png")

      assert Attachments.discard(project, user, [theirs.id]) == 0
      assert Repo.get(Upload, theirs.id)
    end

    test "discard removes only the actor's own", %{project: project, user: user, admin: admin} do
      mine = staged!(project, user, "a.png")
      theirs = staged!(project, admin, "b.png")

      assert Attachments.discard(project, user, [mine.id, theirs.id, "not-an-id"]) == 1
      assert Repo.get(Upload, mine.id) == nil
      assert Repo.get(Upload, theirs.id)
    end
  end

  describe "claiming" do
    test "makes a version of attachments/<name>, a row, and an event", %{
      project: project,
      user: user,
      pool: pool,
      ticket: ticket
    } do
      file = staged!(project, user, "Screen Shot.png", "png!")

      assert {:ok, %{added: [row], not_received: []}} = claim!(pool, user, [file])

      assert %Attachment{
               name: "attachments/Screen-Shot.png",
               original_name: "Screen Shot.png",
               size: 4,
               ticket_id: tid
             } = row

      assert tid == ticket.id
      assert row.user_id == user.id
      assert %{"kind" => "user", "id" => _} = row.author

      assert [%{file: "Screen-Shot.png", version: 1, size: 4}] = Attachments.pool(pool)
      assert Repo.get(Upload, file.id) == nil

      assert %{
               type: "attachment.added",
               payload: %{"files" => [%{"original" => "Screen Shot.png"}]}
             } =
               Repo.one(from e in Events.Event, where: e.type == "attachment.added")
    end

    test "the same name twice is two versions, the newest plain and the earlier spelled as the archive does",
         %{project: project, user: user, pool: pool} do
      {:ok, _} = claim!(pool, user, [staged!(project, user, "shot.png", "one")])
      {:ok, _} = claim!(pool, user, [staged!(project, user, "shot.png", "two")])

      assert [%{file: "shot.v001.png", version: 1}, %{file: "shot.png", version: 2}] =
               Attachments.pool(pool)
    end

    test "another actor's staged id is not received, and says nothing of whose it was",
         %{project: project, user: user, admin: admin, pool: pool} do
      theirs = staged!(project, admin, "theirs.png")

      assert {:ok, %{added: [], not_received: [missing]}} = claim!(pool, user, [theirs])
      assert missing.original_name == "theirs.png"
      assert Attachments.pool(pool) == []
      # And it is still the admin's to claim.
      assert {:ok, %{added: [_]}} = claim!(pool, admin, [theirs])
    end

    test "a staged id of another project is not received", %{user: user, pool: pool} do
      other = project_fixture()
      stray = staged!(other, user, "stray.png")

      assert {:ok, %{added: [], not_received: [_]}} = claim!(pool, user, [stray])
    end

    test "files that failed are recorded as attached and not received", %{
      project: project,
      user: user,
      pool: pool
    } do
      ok = staged!(project, user, "ok.png")

      assert {:ok, %{added: [_], not_received: [failed]}} =
               claim!(pool, user, [ok], failed: ["big.mov"])

      assert failed.original_name == "big.mov"
      assert failed.artifact_version_id == nil
      assert [%{original_name: "big.mov"}] = Attachments.not_received(pool)
      assert [%{file: "ok.png"}] = Attachments.pool(pool)
    end

    test "an empty batch writes nothing", %{user: user, pool: pool} do
      assert {:ok, nil} = Attachments.claim(pool, user, %Batch{}, :note, :added)
      assert {:ok, nil} = Attachments.claim(pool, user, nil, :note, :added)
      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "a chat's pool is its own", %{project: project, user: user, pool: ticket_pool} do
      chat = chat_fixture(%{project: project})

      {:ok, _} =
        claim!({:job, chat.id}, user, [staged!(project, user, "chat.png")], kind: :message)

      assert [%{file: "chat.png", attachment: %{job_id: job_id, ticket_id: nil}}] =
               Attachments.pool({:job, chat.id})

      assert job_id == chat.id
      assert Attachments.pool(ticket_pool) == []
    end

    test "a job's own files are not in the pool", %{ticket: ticket, pool: pool} do
      Artifacts.record_version(ticket.id, "screenshots/a.png", :blob, :system, %{
        blob_uri: "store:job/x/a.png",
        content_hash: "sha256:" <> String.duplicate("a", 64)
      })

      assert Attachments.pool(pool) == []
    end
  end

  describe "what a repeated or racing claim does" do
    test "an id a form repeats is one file", %{project: project, user: user, pool: pool} do
      file = staged!(project, user, "a.png")

      assert {:ok, %{added: [_one], not_received: []}} = claim!(pool, user, [file, file])
      assert [%{file: "a.png"}] = Attachments.pool(pool)
    end

    test "the sweep keeps the bytes of a row an act claimed after it was selected", %{
      project: project,
      user: user,
      pool: pool
    } do
      file = staged!(project, user, "a.png", "claimed")
      key = Repo.get!(Upload, file.id).key
      {:ok, _} = claim!(pool, user, [file])

      # What the sweep selected a moment ago: a row that is not there any more.
      assert Attachments.remove_staged([{file.id, key}]) == 0

      assert {:ok, "claimed"} = Storage.get(key)
      assert [%{file: "a.png"}] = Attachments.pool(pool)
    end

    test "bytes that no row names are not left when the row cannot be written", %{
      project: project,
      user: user
    } do
      path = Path.join(tmp_dir("src"), "x")
      File.write!(path, "bytes")

      # A name Postgres refuses as text: the insert raises, and the bytes must not outlive it.
      assert {:ok, upload} = Attachments.stage(project, user, {:file, path}, <<255, 254>>)
      assert upload.original_name == "file"
    end

    test "two people answering at once each anchor to their own answer", %{
      project: project,
      user: user,
      admin: admin,
      pool: pool,
      ticket: ticket
    } do
      mark = Attachments.mark()

      for who <- [admin, user] do
        {:ok, _} =
          Events.append("question.answered", {:user, who.id}, %{
            ticket_id: ticket.id,
            payload: %{}
          })
      end

      [mine, _theirs] =
        Repo.all(from e in Events.Event, where: e.type == "question.answered", order_by: e.seq)

      file = staged!(project, user, "a.png")
      batch = %Batch{uploads: [file]}

      # `user` is the second answerer: the first event by someone else is not theirs.
      assert {:ok, %{added: [row]}} =
               Attachments.claim(
                 pool,
                 user,
                 batch,
                 :answer,
                 {:events_after, mark, ["question.answered"]}
               )

      assert row.to_event_seq != mine.seq
    end
  end

  describe "the check before an act" do
    test "an id a request repeats counts once against the limits", %{
      project: project,
      user: user,
      pool: pool
    } do
      limits!(per_act: 1)
      file = staged!(project, user, "a.png")
      batch = %Batch{uploads: [file, file], whole?: true}

      assert :ok = Attachments.preflight(batch, user, project.id, pool)
    end

    test "refuses what a whole claim would, naming the file and the limit", %{
      project: project,
      user: user,
      pool: pool
    } do
      limits!(pool_files: 1)
      {:ok, _} = claim!(pool, user, [staged!(project, user, "a.png")])
      batch = %Batch{uploads: [staged!(project, user, "b.png")], whole?: true}

      assert {:error, {:attachments_refused, [{"b.png", :pool_files}]}} =
               Attachments.preflight(batch, user, project.id, pool)
    end

    test "a page's request is never refused by it, and a ticket not made yet has an empty pool",
         %{
           project: project,
           user: user
         } do
      limits!(per_act: 0)
      lenient = %Batch{uploads: [staged!(project, user, "a.png")], whole?: false}
      assert :ok = Attachments.preflight(lenient, user, project.id, nil)

      assert {:error, {:attachments_refused, _}} =
               Attachments.preflight(%{lenient | whole?: true}, user, project.id, nil)
    end
  end

  describe "the assignment lock" do
    test "a job of a ticket whose lock is held is not offered, and is when it is let go", %{
      ticket: ticket
    } do
      job = job_fixture(%{ticket: ticket})
      ours = fn -> Enum.any?(Forge.Jobs.pending(100), &(&1.id == job.id)) end

      assert ours.()

      Attachments.hold(ticket.id, fn ->
        refute ours.()
        # Another ticket's jobs are not held back by it.
        other = job_fixture(%{ticket: ticket_fixture(%{project: project_fixture()})})
        assert Enum.any?(Forge.Jobs.pending(100), &(&1.id == other.id))
      end)

      assert ours.()
    end

    # A lock of another kind or in another place that happens to carry the same numbers is not this
    # ticket's: two databases on one cluster (the suite's partitions are that) can hold the same class
    # and key, and a one-number advisory lock is made of the same two halves.
    defp elsewhere(sql, args, database \\ nil) do
      config = Forge.Repo.config()

      opts =
        config
        |> Keyword.take([:hostname, :socket_dir, :username, :password, :database])
        |> Keyword.put(:database, database || config[:database])

      {:ok, conn} = Postgrex.start_link(opts)
      Postgrex.query!(conn, sql, args)
      conn
    end

    test "a lock on the same numbers in another database does not hold the ticket", %{
      ticket: ticket
    } do
      job = job_fixture(%{ticket: ticket})

      elsewhere(
        "SELECT pg_advisory_lock($1::int, hashtext($2::text))",
        [Attachments.lock_class(), ticket.id],
        "postgres"
      )

      assert Enum.any?(Forge.Jobs.pending(100), &(&1.id == job.id))
    end

    test "a one-number advisory lock that spells the same two halves does not hold it", %{
      ticket: ticket
    } do
      job = job_fixture(%{ticket: ticket})

      # `pg_advisory_lock(bigint)` stores its high half as the class and its low half as the object,
      # with a sub-id of 1 where the two-number form has 2.
      elsewhere(
        "SELECT pg_advisory_lock(($1::bigint << 32) | (hashtext($2::text)::bigint & 4294967295))",
        [Attachments.lock_class(), ticket.id]
      )

      assert Enum.any?(Forge.Jobs.pending(100), &(&1.id == job.id))
    end

    test "a lock taken by another connection of this database holds it, and goes with it", %{
      ticket: ticket
    } do
      job = job_fixture(%{ticket: ticket})

      conn =
        elsewhere("SELECT pg_advisory_lock($1::int, hashtext($2::text))", [
          Attachments.lock_class(),
          ticket.id
        ])

      refute Enum.any?(Forge.Jobs.pending(100), &(&1.id == job.id))

      GenServer.stop(conn)
      # The connection's end releases it, which the server notices a moment later.
      assert Enum.any?(1..50, fn _ ->
               Process.sleep(20)
               Enum.any?(Forge.Jobs.pending(100), &(&1.id == job.id))
             end)
    end

    test "is let go when what it holds raises", %{ticket: ticket} do
      job = job_fixture(%{ticket: ticket})

      assert_raise RuntimeError, fn -> Attachments.hold(ticket.id, fn -> raise "boom" end) end

      assert Enum.any?(Forge.Jobs.pending(100), &(&1.id == job.id))
    end

    test "a conversation is not held by it", %{project: project, ticket: ticket} do
      chat = chat_fixture(%{project: project, ticket: ticket})

      Attachments.hold(ticket.id, fn ->
        assert Enum.any?(Forge.Jobs.pending(100), &(&1.id == chat.id))
      end)
    end
  end

  describe "limits" do
    test "a file exactly at the limit is the claim's to take", %{
      project: project,
      user: user,
      pool: pool
    } do
      file = staged!(project, user, "five.bin", "12345")
      limits!(file_bytes: 5)

      assert {:ok, %{added: [_], not_received: []}} = claim!(pool, user, [file])
    end

    test "a limit lowered after the upload is the claim's to keep", %{
      project: project,
      user: user,
      pool: pool
    } do
      file = staged!(project, user, "big.bin", "123456")
      limits!(file_bytes: 5)

      assert {:ok, %{added: [], not_received: [missing]}} = claim!(pool, user, [file])
      assert missing.original_name == "big.bin"

      assert [%{"limit" => "file_bytes"}] =
               Repo.one(
                 from e in Events.Event, where: e.type == "attachment.added", select: e.payload
               )["refused"]
    end

    test "per act: the eleventh goes without stopping the rest", %{
      project: project,
      user: user,
      pool: pool
    } do
      limits!(per_act: 2)
      files = for n <- 1..3, do: staged!(project, user, "f#{n}.txt")

      assert {:ok, %{added: [_, _], not_received: [over]}} = claim!(pool, user, files)
      assert over.original_name == "f3.txt"

      assert [%{"limit" => "per_act", "name" => "f3.txt"}] =
               Repo.one(
                 from e in Events.Event, where: e.type == "attachment.added", select: e.payload
               )["refused"]
    end

    test "a pool's files, counting every version", %{project: project, user: user, pool: pool} do
      limits!(pool_files: 2)

      {:ok, _} =
        claim!(pool, user, [staged!(project, user, "a.txt"), staged!(project, user, "a.txt")])

      assert {:ok, %{added: [], not_received: [_]}} =
               claim!(pool, user, [staged!(project, user, "b.txt")])
    end

    test "a pool's bytes are the bytes received, whatever the file is called", %{
      project: project,
      user: user,
      pool: pool
    } do
      limits!(pool_bytes: 10)
      {:ok, _} = claim!(pool, user, [staged!(project, user, "a.txt", "123456")])

      assert {:ok, %{added: [], not_received: [_]}} =
               claim!(pool, user, [staged!(project, user, "b.txt", "12345")])

      assert {:ok, %{added: [_]}} = claim!(pool, user, [staged!(project, user, "c.txt", "1234")])
      assert Attachments.room(pool) == %{files: 98, bytes: 0}
    end

    test "withdrawn files and files not received count for nothing", %{
      project: project,
      user: user,
      pool: pool
    } do
      limits!(pool_files: 1)
      {:ok, _} = claim!(pool, user, [staged!(project, user, "a.txt")], failed: ["x.mov"])
      assert {:ok, [_]} = Attachments.withdraw(pool, user, "attachments/a.txt", :all, nil)

      assert {:ok, %{added: [_]}} = claim!(pool, user, [staged!(project, user, "b.txt")])
    end

    test "the API's request is refused whole, and rolls back what it wrote", %{
      project: project,
      user: user,
      pool: pool
    } do
      limits!(per_act: 1)
      files = [staged!(project, user, "a.txt"), staged!(project, user, "b.txt")]

      result =
        Repo.transact(fn -> claim!(pool, user, files, whole?: true) end)

      assert {:error, {:attachments_refused, [{"b.txt", :per_act}]}} = result
      assert Attachments.pool(pool) == []
      assert Repo.aggregate(Attachment, :count) == 0
    end
  end

  describe "withdrawing" do
    setup %{project: project, user: user, pool: pool} do
      {:ok, _} = claim!(pool, user, [staged!(project, user, "shot.png", "one")])
      {:ok, _} = claim!(pool, user, [staged!(project, user, "shot.png", "two")])
      :ok
    end

    test "a member may not withdraw every version of a name when one is another's", %{
      project: project,
      user: user,
      pool: pool
    } do
      other = member_fixture(project, :member)
      {:ok, _} = claim!(pool, other, [staged!(project, other, "shot.png", "three")])

      assert {:error, :forbidden} =
               Attachments.withdraw(pool, user, "attachments/shot.png", :all, nil)

      # Nothing was withdrawn, not even what is theirs.
      assert length(Attachments.pool(pool)) == 3

      assert {:ok, [_one]} = Attachments.withdraw(pool, other, "attachments/shot.png", 3, nil)
    end

    test "an attacher who has left the project may not withdraw", %{
      project: project,
      user: user,
      pool: pool
    } do
      Repo.delete_all(
        from m in Forge.Projects.Member,
          where: m.project_id == ^project.id and m.user_id == ^user.id
      )

      assert {:error, :forbidden} =
               Attachments.withdraw(pool, user, "attachments/shot.png", :all, nil)

      assert length(Attachments.pool(pool)) == 2
    end

    test "the attacher may; one version, the other is the plain name now", %{
      user: user,
      pool: pool
    } do
      assert {:ok, [row]} =
               Attachments.withdraw(pool, user, "attachments/shot.png", 2, "wrong one")

      assert row.withdrawn_at && row.withdraw_reason == "wrong one"
      assert %{"kind" => "user", "id" => _} = row.withdrawn_by
      assert [%{file: "shot.png", version: 1}] = Attachments.pool(pool)

      assert %{
               type: "attachment.withdrawn",
               payload: %{"versions" => [2], "reason" => "wrong one"}
             } =
               Repo.one(from e in Events.Event, where: e.type == "attachment.withdrawn")
    end

    test "the bytes leave the store and the record stays", %{user: user, pool: pool} do
      [_, %{key: key}] = Attachments.pool(pool)
      assert {:ok, _} = Storage.stat(key)

      {:ok, _} = Attachments.withdraw(pool, user, "attachments/shot.png", :all, nil)

      assert {:error, :not_found} = Storage.stat(key)
      assert Attachments.pool(pool) == []

      assert [%Attachment{size: 3, withdrawn_at: %DateTime{}}, _] =
               Attachments.all(pool) |> Enum.sort_by(& &1.inserted_at, :desc)

      # The version row is as it was.
      assert Repo.aggregate(Artifacts.Version, :count) == 2
    end

    test "an admin may withdraw another member's", %{admin: admin, pool: pool} do
      assert {:ok, [_, _]} = Attachments.withdraw(pool, admin, "attachments/shot.png", :all, nil)
    end

    test "another member may not, and nothing changes", %{project: project, pool: pool} do
      other = member_fixture(project, :member)

      assert {:error, :forbidden} =
               Attachments.withdraw(pool, other, "attachments/shot.png", :all, nil)

      assert length(Attachments.pool(pool)) == 2
    end

    test "a non-member may not", %{pool: pool} do
      stranger = Forge.AccountsFixtures.user_fixture()

      assert {:error, :forbidden} =
               Attachments.withdraw(pool, stranger, "attachments/shot.png", :all, nil)
    end

    test "a name with nothing live to withdraw is not found", %{user: user, pool: pool} do
      assert {:error, :not_found} =
               Attachments.withdraw(pool, user, "attachments/nope.png", :all, nil)

      {:ok, _} = Attachments.withdraw(pool, user, "attachments/shot.png", :all, nil)

      assert {:error, :not_found} =
               Attachments.withdraw(pool, user, "attachments/shot.png", :all, nil)
    end

    test "a file a token attached is withdrawable by an admin only", %{
      project: project,
      user: user,
      admin: admin,
      pool: pool
    } do
      {:ok, _secret, token} =
        Forge.Git.Tokens.issue(project, name: "ci", git: :reader, api: :write)

      {:ok, _} = claim!(pool, token, [staged!(project, token, "ci.png")])

      assert {:error, :forbidden} =
               Attachments.withdraw(pool, user, "attachments/ci.png", :all, nil)

      assert {:ok, [_]} = Attachments.withdraw(pool, admin, "attachments/ci.png", :all, nil)
    end
  end

  describe "the database" do
    setup %{project: project, user: user, pool: pool} do
      {:ok, %{added: [row]}} = claim!(pool, user, [staged!(project, user, "a.png")])
      %{row: row}
    end

    test "refuses to delete a row", %{row: row} do
      assert_raise Postgrex.Error, ~r/never deleted/, fn -> Repo.delete!(row) end
    end

    test "refuses any change but withdrawing", %{row: row} do
      assert_raise Postgrex.Error, ~r/changed only by withdrawing/, fn ->
        Repo.update_all(from(a in Attachment, where: a.id == ^row.id), set: [original_name: "x"])
      end

      assert_raise Postgrex.Error, ~r/changed only by withdrawing/, fn ->
        Repo.update_all(from(a in Attachment, where: a.id == ^row.id),
          set: [withdraw_reason: "just a reason"]
        )
      end
    end

    test "allows withdrawing once, and nothing after", %{row: row} do
      by = %{"kind" => "system", "id" => nil}

      Repo.update_all(from(a in Attachment, where: a.id == ^row.id),
        set: [withdrawn_at: DateTime.utc_now(), withdrawn_by: by]
      )

      assert_raise Postgrex.Error, ~r/withdrawn attachment is not changed/, fn ->
        Repo.update_all(from(a in Attachment, where: a.id == ^row.id),
          set: [withdraw_reason: "again"]
        )
      end
    end
  end

  describe "the sweep" do
    test "removes staged uploads past their time and their bytes, and keeps the claimed", %{
      project: project,
      user: user,
      pool: pool
    } do
      old = staged!(project, user, "old.png")
      fresh = staged!(project, user, "fresh.png")
      kept = staged!(project, user, "kept.png")
      {:ok, _} = claim!(pool, user, [kept])

      Repo.update_all(from(u in Upload, where: u.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -2 * 86_400)]
      )

      old_key = Storage.Key.upload(old.id)
      assert {:ok, _} = Storage.stat(old_key)

      assert {1, 0} = Attachments.sweep()

      assert Repo.get(Upload, old.id) == nil
      assert Repo.get(Upload, fresh.id)
      assert {:error, :not_found} = Storage.stat(old_key)
      assert [%{file: "kept.png"}] = Attachments.pool(pool)
    end

    test "removes the bytes of a withdrawn version a failed delete left", %{
      project: project,
      user: user,
      pool: pool
    } do
      {:ok, %{added: [row]}} = claim!(pool, user, [staged!(project, user, "a.png")])
      [%{key: key}] = Attachments.pool(pool)
      {:ok, _} = Attachments.withdraw(pool, user, row.name, :all, nil)
      # As if the delete after the commit had failed.
      {:ok, _} = Storage.put(key, "back")

      assert {0, 1} = Attachments.sweep()
      assert {:error, :not_found} = Storage.stat(key)
    end
  end

  describe "describing" do
    test "says what it was attached to and by whom, in one place", %{
      project: project,
      user: user,
      pool: pool,
      ticket: ticket
    } do
      {:ok, v} =
        Artifacts.record_version(ticket.id, "feedback.md", :document, {:user, user.id}, %{
          content: "text"
        })

      {:ok, %{added: [row]}} =
        Attachments.claim(
          pool,
          user,
          %Batch{uploads: [staged!(project, user, "a.png")]},
          :document,
          {:version, v.id}
        )

      {:ok, %{added: [note]}} = claim!(pool, user, [staged!(project, user, "b.png")])

      words = Attachments.describe([row, note])
      assert words[row.id] == %{to: "`feedback.md` version 1", by: user.email}
      assert words[note.id].to == "a note"

      assert %{
               "files" => [
                 %{"file" => "a.png", "to" => "`feedback.md` version 1", "by" => by} | _
               ]
             } = Attachments.manifest(pool)

      assert by == user.email
    end
  end
end
