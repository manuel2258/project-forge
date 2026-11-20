defmodule Forge.AttachmentsActsTest do
  @moduledoc """
  Files ride on the act they came with (`docs/design/attachments.md` § Staging, claiming and the
  sweep): in its transaction, anchored to what it wrote, behind its guard, and handed to the next
  job as the assignment and the manifest say.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Attachments, FakeWorker, Jobs, Operator, Repo, Tickets}
  alias Forge.Attachments.{Attachment, Batch}
  alias Forge.Jobs.Job

  @workflow "../../../core/test/fixtures/workflow_example.yml"
            |> Path.expand(__DIR__)
            |> File.read!()
            |> String.replace(
              "    produces: [plan.md]\n",
              "    produces: [plan.md]\n    outcomes: [done, redo]\n"
            )
            |> String.replace(
              "  - { from: planning,      to: implementing }\n",
              "  - { from: planning,      to: implementing }\n" <>
                "  - { from: planning,      to: refining,      when: redo }\n"
            )

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "acts-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
      })

    user = member_fixture(project)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    limits = Application.get_env(:forge, Forge.Attachments, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
      Application.put_env(:forge, Forge.Attachments, limits)
    end)

    %{project: project, user: user, worker: FakeWorker.connect()}
  end

  defp staged!(project, actor, original, bytes \\ "bytes") do
    path = Path.join(tmp_dir("src"), "#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    {:ok, upload} = Attachments.stage(project, actor, {:file, path}, original)
    %{id: upload.id, name: original}
  end

  defp batch(uploads, opts \\ []),
    do: %Batch{
      uploads: uploads,
      not_received: opts[:failed] || [],
      whole?: opts[:whole?] || false
    }

  defp admitted(project, user, files \\ []) do
    attrs = %{title: "Scores", body: "See the picture.", on_hold: false}
    attrs = if files == [], do: attrs, else: Map.put(attrs, :attachments, batch(files))
    Operator.admit(project, user, attrs)
  end

  defp pending(ticket) do
    assert [%Job{status: :pending} = job] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

    job
  end

  defp described(pool), do: pool |> Attachments.all() |> Attachments.describe() |> Map.values()

  describe "admitting a ticket" do
    test "attaches the files to the ticket's text, in the ticket's pool", %{
      project: project,
      user: user
    } do
      {:ok, ticket} = admitted(project, user, [staged!(project, user, "bug.png")])

      assert [%{file: "bug.png", attachment: attachment}] = Attachments.pool({:ticket, ticket.id})
      version = Artifacts.latest(ticket.id, "ticket")
      assert attachment.to_kind == :ticket
      assert attachment.to_version_id == version.id
      assert [%{to: "the ticket"}] = described({:ticket, ticket.id})
      assert %{"files" => [%{"file" => "bug.png"}]} = Attachments.manifest({:ticket, ticket.id})
    end

    test "a ticket with no files is as it was", %{project: project, user: user} do
      {:ok, ticket} = admitted(project, user)
      assert Repo.aggregate(Attachment, :count) == 0
      assert Attachments.pool({:ticket, ticket.id}) == []
    end

    test "a refusal is whole: no ticket, no file, and the staged file is still there",
         %{project: project, user: user} do
      Application.put_env(:forge, Forge.Attachments, per_act: 1)
      files = [staged!(project, user, "a.png"), staged!(project, user, "b.png")]
      before = Repo.aggregate(Forge.Tickets.Ticket, :count)

      assert {:error, {:attachments_refused, [{"b.png", :per_act}]}} =
               Operator.admit(project, user, %{
                 title: "x",
                 on_hold: false,
                 attachments: batch(files, whole?: true)
               })

      assert Repo.aggregate(Forge.Tickets.Ticket, :count) == before
      assert Repo.aggregate(Attachment, :count) == 0
      assert Repo.get(Attachments.Upload, hd(files).id)
    end

    test "a non-member is refused before anything is written", %{project: project, user: user} do
      stranger = Forge.AccountsFixtures.user_fixture()
      file = staged!(project, stranger, "x.png")

      assert {:error, :forbidden} =
               Operator.admit(project, stranger, %{
                 title: "x",
                 on_hold: false,
                 attachments: batch([file])
               })

      assert Repo.aggregate(Attachment, :count) == 0
      assert Repo.get(Attachments.Upload, file.id)
      refute user.id == stranger.id
    end
  end

  describe "the acts of a ticket in flight" do
    setup %{project: project, user: user, worker: worker} do
      {:ok, ticket} = admitted(project, user)
      {:ok, _} = FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")
      %{ticket: Tickets.get!(ticket.id)}
    end

    test "a rejection's note carries them to the next job, in its assignment and its manifest",
         %{project: project, user: user, ticket: ticket, worker: worker} do
      file = staged!(project, user, "wrong.png", "pixels")

      assert {:ok, _} =
               Operator.decide(ticket, user, :rejected, "Look at this.", nil,
                 attachments: batch([file])
               )

      assert [%{to: "a rejection note"}] = described({:ticket, ticket.id})

      {:ok, _} = Operator.retry(Tickets.get!(ticket.id), user)
      assignment = FakeWorker.assign(pending(ticket), worker)

      assert [%{"file" => "wrong.png", "size" => 6, "token" => token, "key" => "upload/" <> _}] =
               assignment["attachments"]

      assert is_binary(token)

      assert %{"files" => [%{"file" => "wrong.png", "to" => "a rejection note"}]} =
               assignment["spec"]["attachments"]
    end

    test "a note to run the state again", %{project: project, user: user, ticket: ticket} do
      {:ok, _} =
        Operator.retry(ticket, user,
          note: "again",
          attachments: batch([staged!(project, user, "a.png")])
        )

      assert [%{to: "a note to run the state again"}] = described({:ticket, ticket.id})
    end

    test "a transition's comment", %{project: project, user: user, ticket: ticket} do
      {:ok, rejected} = Operator.decide(ticket, user, :rejected, "No.")

      {:ok, _} =
        Operator.transition(rejected, user, "planning",
          comment: "go",
          attachments: batch([staged!(project, user, "b.png")])
        )

      assert [%{to: "a transition's comment"}] = described({:ticket, ticket.id})
    end

    test "a document may not take the name files are kept under", %{
      user: user,
      ticket: ticket,
      project: project
    } do
      assert {:error, {:invalid_document, [%{message: message}]}} =
               Operator.edit(ticket, user, "attachments/x.png", "text", "0")

      assert message =~ "reserved for attached files"

      assert {:error, {:invalid_document, _}} =
               Operator.edit(ticket, user, "attachments", "t", "0")

      # So attaching `x.png` still works afterwards.
      assert {:ok, _} =
               Operator.retry(ticket, user, attachments: batch([staged!(project, user, "x.png")]))
    end

    test "a document's new version", %{project: project, user: user, ticket: ticket} do
      assert {:ok, _} =
               Operator.edit(ticket, user, "feedback.md", "Please see it.", "0",
                 attachments: batch([staged!(project, user, "a.png")])
               )

      version = Artifacts.latest(ticket.id, "feedback.md")
      assert %{to: "`feedback.md` version 1"} = hd(described({:ticket, ticket.id}))
      assert [%{to_version_id: id}] = Attachments.all({:ticket, ticket.id})
      assert id == version.id
    end

    test "an answer", %{project: project, user: user, ticket: ticket} do
      doc = """
      Which?

      ```question
      key: naming
      anchor: "Which?"
      text: "Which?"
      options:
        - label: "a"
          detail: "one"
        - label: "b"
          detail: "two"
      blocking: false
      assumption: "a"
      ```
      """

      {:ok, _} = Operator.edit(ticket, user, "notes.md", doc, "0")

      assert {:ok, _} =
               Operator.answer(Tickets.get!(ticket.id), user, "naming", %{choice: "b"},
                 attachments: batch([staged!(project, user, "a.png")])
               )

      assert [%{to: "an answer"}] = described({:ticket, ticket.id})
    end

    test "another member's staged file cannot ride on a member's act", %{
      project: project,
      user: user,
      ticket: ticket
    } do
      other = member_fixture(project)
      theirs = staged!(project, other, "theirs.png")

      assert {:ok, _} = Operator.retry(ticket, user, attachments: batch([theirs]))
      # The act went through, and the file is the other member's still: it is not received.
      assert Attachments.pool({:ticket, ticket.id}) == []
      assert [%{original_name: "theirs.png"}] = Attachments.not_received({:ticket, ticket.id})
      assert Repo.get(Attachments.Upload, theirs.id)
    end

    # The job an act makes must not be assignable before the files it came with are in the pool
    # (`docs/design/attachments.md` § Delivery): the ticket's assignment lock is taken before the act
    # makes it and let go after the claim. Read off the queries, in the order they were run.
    test "an act on a ticket holds its assignment lock from before the job it makes until the claim",
         %{project: project, user: user, ticket: ticket} do
      parent = self()
      id = "queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:forge, :repo, :query],
        fn _event, _measurements, %{query: query, params: params}, _config ->
          send(parent, {:query, query, params, Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, _} =
               Operator.retry(ticket, user, attachments: batch([staged!(project, user, "a.png")]))

      queries =
        Stream.repeatedly(fn ->
          receive do
            {:query, q, params, in_txn} -> {q, params, in_txn}
          after
            0 -> nil
          end
        end)

      queries = queries |> Enum.take_while(& &1) |> Enum.with_index()

      at = fn text ->
        Enum.find_value(queries, fn {{q, _params, _in_txn}, i} ->
          if String.contains?(q, text), do: i
        end)
      end

      lock = at.("pg_advisory_lock")
      new_job = at.(~s(INSERT INTO "jobs"))
      claim = at.(~s(INSERT INTO "attachments"))
      unlock = at.("pg_advisory_unlock")

      assert lock < new_job and new_job < claim and claim < unlock

      # **This ticket's** lock, taken and let go: another's would let this act's job be assigned
      # before its files.
      params = fn index -> queries |> Enum.at(index) |> elem(0) |> elem(1) end
      assert params.(lock) == [Forge.Attachments.lock_class(), ticket.id]
      assert params.(unlock) == [Forge.Attachments.lock_class(), ticket.id]
    end

    # `docs/design/attachments.md` § Staging, claiming and the sweep: the ticket does not exist until
    # its files do, so its first job cannot be assigned without them. Read off the queries: the
    # admission's own transaction has not committed when the claim writes.
    test "admitting a ticket with files claims them before the admission commits", %{
      project: project,
      user: user
    } do
      parent = self()
      id = "admit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:forge, :repo, :query],
        fn _event, _measurements, %{query: query}, _config -> send(parent, {:query, query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, _} = admitted(project, user, [staged!(project, user, "a.png")])

      queries =
        Stream.repeatedly(fn ->
          receive do
            {:query, q} -> q
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> Enum.with_index()

      at = fn matches, from ->
        Enum.find_value(queries, fn {q, i} -> if i >= from and matches.(q), do: i end)
      end

      ticket_row = at.(&String.contains?(&1, ~s(INSERT INTO "tickets")), 0)
      claim = at.(&String.contains?(&1, ~s(INSERT INTO "attachments")), 0)
      commit = at.(&(&1 == "commit"), ticket_row)

      assert ticket_row < claim and claim < commit
    end

    test "a claim that fails takes the admission with it: no ticket", %{
      project: project,
      user: user
    } do
      file = staged!(project, user, "a.png")
      # A staged row the claim cannot make a version of.
      Repo.update_all(Attachments.Upload, set: [content_hash: ""])
      before = Repo.aggregate(Forge.Tickets.Ticket, :count)

      assert {:error, _} = admitted(project, user, [file])
      assert Repo.aggregate(Forge.Tickets.Ticket, :count) == before
    end

    test "a page's act stands when a file cannot be had: the file is not received", %{
      project: project,
      user: user,
      ticket: ticket
    } do
      Application.put_env(:forge, Forge.Attachments, per_act: 1)
      files = [staged!(project, user, "a.png"), staged!(project, user, "b.png")]

      assert {:ok, _} = Operator.retry(ticket, user, attachments: batch(files))

      assert [%{file: "a.png"}] = Attachments.pool({:ticket, ticket.id})
      assert [%{original_name: "b.png"}] = Attachments.not_received({:ticket, ticket.id})
      assert Enum.any?(Forge.Events.for_ticket(ticket.id), &(&1.type == "ticket.retried"))
    end

    test "a whole request that cannot be had is refused before the act is done", %{
      project: project,
      user: user,
      ticket: ticket
    } do
      Application.put_env(:forge, Forge.Attachments, per_act: 0)
      before = length(Forge.Events.for_ticket(ticket.id))

      assert {:error, {:attachments_refused, _}} =
               Operator.retry(ticket, user,
                 attachments: batch([staged!(project, user, "a.png")], whole?: true)
               )

      assert length(Forge.Events.for_ticket(ticket.id)) == before
      assert Tickets.get!(ticket.id).status == ticket.status
    end
  end
end
