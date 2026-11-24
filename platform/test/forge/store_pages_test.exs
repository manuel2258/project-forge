defmodule Forge.StorePagesTest do
  @moduledoc """
  The store behind a page (`docs/design/pages.md`): the counter, the conditional write, the limits,
  read only, who a job reaches, the audit burst, and recording a version from a publish.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures, only: [tmp_dir: 1]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Operator, Pages, Repo, Storage}
  alias Forge.Jobs.Blobs
  alias Forge.Pages.{Bursts, Page}

  setup do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    limits = Application.get_env(:forge, Forge.Pages, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, store)
      Application.put_env(:forge, Forge.Pages, limits)
    end)

    project = project_fixture()
    ticket = ticket_fixture(%{project: project})
    user = member_fixture(project, :member)
    job = job_fixture(%{ticket: ticket})
    {:ok, page} = Pages.ensure({:ticket, ticket.id}, "form")

    %{project: project, ticket: ticket, user: user, job: job, page: page, me: {:user, user.id}}
  end

  defp limits!(limits), do: Application.put_env(:forge, Forge.Pages, limits)

  defp set_status!(ticket, status) do
    Repo.update_all(from(t in Forge.Tickets.Ticket, where: t.id == ^ticket.id),
      set: [status: status]
    )
  end

  describe "the counter" do
    test "rises with every write and is the page's, not the key's", %{page: page, me: me} do
      assert {:ok, %{counter: 1}} = Pages.put(page, "a", "x", me)
      assert {:ok, %{counter: 2}} = Pages.put(page, "b", "y", me)
      assert {:ok, %{counter: 3, value: "z"}} = Pages.put(page, "a", "z", me)
      assert Pages.data_map(page) == %{"a" => "z", "b" => "y"}
    end

    test "a deleted and recreated key never gets an old counter back", %{page: page, me: me} do
      assert {:ok, %{counter: 1}} = Pages.put(page, "a", 1, me)
      assert {:ok, %{counter: 1}} = Pages.delete(page, "a", me)
      assert {:ok, %{counter: 3}} = Pages.put(page, "a", 1, me)
    end

    test "deleting an absent key writes nothing and takes no counter", %{page: page, me: me} do
      assert {:ok, nil} = Pages.delete(page, "never", me)
      assert Repo.get!(Page, page.id).seq == 0
    end

    test "holds any JSON value, null included", %{page: page, me: me} do
      for value <- [nil, true, 3.5, "text", [1, "two"], %{"k" => [nil]}] do
        assert {:ok, _entry} = Pages.put(page, "v", value, me)
        assert Pages.entry(page, "v").value == value
      end
    end
  end

  describe "a conditional write" do
    test "names the counter it expects and is refused, told the current value, when it moved",
         %{page: page, me: me, job: job} do
      {:ok, %{counter: first}} = Pages.put(page, "a", "mine", me)
      {:ok, _} = Pages.put(page, "a", "theirs", me)

      assert {:error, {:changed, %{value: "theirs", counter: 2}}} =
               Pages.put(page, "a", "late", {:job, job.id}, counter: first)

      assert Pages.entry(page, "a").value == "theirs"
      assert {:ok, %{value: "now"}} = Pages.put(page, "a", "now", {:job, job.id}, counter: 2)
    end

    test "nil is a key expected to be absent", %{page: page, me: me, job: job} do
      assert {:ok, _} = Pages.put(page, "a", 1, {:job, job.id}, counter: nil)
      assert {:error, {:changed, %{value: 1}}} = Pages.put(page, "a", 2, me, counter: nil)
      assert {:error, {:changed, nil}} = Pages.put(page, "b", 2, me, counter: 5)
    end

    test "a delete names it too", %{page: page, me: me, job: job} do
      {:ok, %{counter: counter}} = Pages.put(page, "a", 1, me)
      {:ok, _} = Pages.put(page, "a", 2, me)

      assert {:error, {:changed, %{value: 2}}} =
               Pages.delete(page, "a", {:job, job.id}, counter: counter)

      assert Pages.entry(page, "a")
    end

    test "a person's write is unconditional and wins", %{page: page, me: me, job: job} do
      {:ok, _} = Pages.put(page, "a", "job's", {:job, job.id}, counter: nil)
      assert {:ok, %{value: "person's"}} = Pages.put(page, "a", "person's", me)
    end
  end

  describe "the limits" do
    test "each names itself and its number", %{page: page, me: me} do
      limits!(value_bytes: 10, key_bytes: 4, keys: 2, data_bytes: 40)

      assert {:error, {:limit, "value", 10}} = Pages.put(page, "a", String.duplicate("x", 20), me)
      assert {:error, {:limit, "key", 4}} = Pages.put(page, "abcde", 1, me)
      assert {:ok, _} = Pages.put(page, "a", 1, me)
      assert {:ok, _} = Pages.put(page, "b", 1, me)
      assert {:error, {:limit, "keys", 2}} = Pages.put(page, "c", 1, me)
      # An overwrite is not a new key.
      assert {:ok, _} = Pages.put(page, "b", 2, me)
    end

    test "the total counts keys and values and is given back by an overwrite and a delete",
         %{page: page, me: me} do
      limits!(data_bytes: 30)

      assert {:ok, _} = Pages.put(page, "a", String.duplicate("x", 10), me)
      assert {:error, {:limit, "data", 30}} = Pages.put(page, "b", String.duplicate("y", 20), me)
      assert {:ok, _} = Pages.put(page, "a", 1, me)
      assert {:ok, _} = Pages.put(page, "b", String.duplicate("y", 20), me)
      assert {:ok, _} = Pages.delete(page, "b", me)
      assert {:ok, _} = Pages.put(page, "c", String.duplicate("y", 20), me)
    end

    test "a key is text without control characters", %{page: page, me: me} do
      assert {:error, {:invalid_key, _}} = Pages.put(page, "", 1, me)
      assert {:error, {:invalid_key, _}} = Pages.put(page, "a\nb", 1, me)
      assert {:error, {:invalid_key, _}} = Pages.put(page, <<255>>, 1, me)
      assert {:ok, _} = Pages.put(page, "naïve <b>key</b>", 1, me)
    end

    test "a value that is not JSON is refused", %{page: page, me: me} do
      assert {:error, :invalid_value} = Pages.put(page, "a", self(), me)
    end
  end

  describe "the limits at their edges" do
    test "a value of exactly the limit is kept and one byte more is refused",
         %{page: page, me: me} do
      limits!(value_bytes: 10)

      # `"xxxxxxxx"` is ten bytes of JSON with its quotes.
      assert {:ok, _} = Pages.put(page, "a", String.duplicate("x", 8), me)
      assert {:error, {:limit, "value", 10}} = Pages.put(page, "a", String.duplicate("x", 9), me)
    end

    test "a key of exactly the limit is kept and one byte more is refused", %{page: page, me: me} do
      limits!(key_bytes: 4)

      assert {:ok, _} = Pages.put(page, "abcd", 1, me)
      assert {:error, {:limit, "key", 4}} = Pages.put(page, "abcde", 1, me)
      # Bytes, not characters: two of these are four bytes.
      assert {:ok, _} = Pages.put(page, "éé", 1, me)
      assert {:error, {:limit, "key", 4}} = Pages.put(page, "ééé", 1, me)
    end

    test "the keys limit is reached at exactly its number and a delete gives one back",
         %{page: page, me: me} do
      limits!(keys: 2)

      assert {:ok, _} = Pages.put(page, "a", 1, me)
      assert {:ok, _} = Pages.put(page, "b", 1, me)
      assert {:error, {:limit, "keys", 2}} = Pages.put(page, "c", 1, me)
      assert {:ok, _} = Pages.delete(page, "a", me)
      assert {:ok, _} = Pages.put(page, "c", 1, me)
      assert {:error, {:limit, "keys", 2}} = Pages.put(page, "d", 1, me)
    end

    test "the total is reached at exactly its number", %{page: page, me: me} do
      limits!(data_bytes: 4)

      # The key `a` and the value `123`: four bytes.
      assert {:ok, _} = Pages.put(page, "a", 123, me)
      assert {:error, {:limit, "data", 4}} = Pages.put(page, "b", 1, me)
    end

    test "the total counts a key's own bytes as well as its value's", %{page: page, me: me} do
      limits!(data_bytes: 10)

      assert {:ok, _} = Pages.put(page, "aaaaaaaa", 1, me)
      # Three bytes more is twelve with the key, and only four without it.
      assert {:error, {:limit, "data", 10}} = Pages.put(page, "b", 12, me)
    end

    test "a key is at most 255 bytes however the limit is set, and so is a page's name",
         %{page: page, me: me, ticket: ticket} do
      limits!(key_bytes: 1000)

      assert {:ok, _} = Pages.put(page, String.duplicate("k", 255), 1, me)
      assert {:error, {:limit, "key", 255}} = Pages.put(page, String.duplicate("k", 256), 1, me)

      assert {:ok, _} = Pages.ensure({:ticket, ticket.id}, String.duplicate("n", 255))

      assert {:error, {:limit, "name", 255}} =
               Pages.ensure({:ticket, ticket.id}, String.duplicate("n", 256))
    end
  end

  describe "a value Postgres cannot hold" do
    test "a string with a NUL, at any depth, is refused and not raised", %{page: page, me: me} do
      assert {:error, :invalid_value} = Pages.put(page, "a", "x\u0000y", me)
      assert {:error, :invalid_value} = Pages.put(page, "a", ["ok", %{"k" => ["\u0000"]}], me)
      assert {:error, :invalid_value} = Pages.put(page, "a", %{"k\u0000" => 1}, me)
      assert Pages.entry(page, "a") == nil
    end

    test "the text backslash u0000 is only text, and comes back as it went in",
         %{page: page, me: me} do
      for text <- ["\\u0000", "\\\\u0000", "a\\u0000b"] do
        assert {:ok, _} = Pages.put(page, "a", text, me)
        assert Pages.entry(page, "a").value == text
      end

      # An odd run of backslashes before it is a real NUL again.
      assert {:error, :invalid_value} = Pages.put(page, "a", "\\\u0000", me)
    end
  end

  describe "listing" do
    test "a page with two versions is listed once, with its latest", %{
      page: page,
      ticket: ticket,
      job: job
    } do
      for version <- [1, 2] do
        Repo.insert!(%Pages.Version{
          page_id: page.id,
          version: version,
          job_id: job.id,
          files: %{}
        })
      end

      assert [%{page: %{id: id}, version: %{version: 2}}] = Pages.list({:ticket, ticket.id})
      assert id == page.id
    end
  end

  describe "the batches a page's view has applied" do
    alias Forge.Pages.Batches

    test "a batch at or below the last applied is applied already, a later one is not",
         %{page: page} do
      refute Batches.applied?(page.id, "client", 1)

      :ok = Batches.applied(page.id, "client", 5)
      assert Batches.applied?(page.id, "client", 5)
      assert Batches.applied?(page.id, "client", 4)
      refute Batches.applied?(page.id, "client", 6)

      # An older batch recorded late does not move the mark back.
      :ok = Batches.applied(page.id, "client", 3)
      assert Batches.applied?(page.id, "client", 5)
      refute Batches.applied?(page.id, "client", 6)

      # Another client, or another page, has its own.
      refute Batches.applied?(page.id, "other", 1)
      refute Batches.applied?(Ecto.UUID.generate(), "client", 1)
    end
  end

  describe "read only" do
    test "a done or cancelled ticket refuses every writer and a jump reopens it",
         %{page: page, me: me, job: job, ticket: ticket} do
      {:ok, _} = Pages.put(page, "a", 1, me)

      for status <- [:done, :cancelled] do
        set_status!(ticket, status)
        assert Pages.read_only({:ticket, ticket.id}) == {true, status}
        assert {:error, {:read_only, ^status}} = Pages.put(page, "a", 2, me)
        assert {:error, {:read_only, ^status}} = Pages.delete(page, "a", me)

        assert {:error, {:read_only, ^status}} =
                 Pages.put(page, "a", 2, {:job, job.id}, counter: 1)
      end

      # Still readable.
      assert Pages.data_map(page) == %{"a" => 1}

      set_status!(ticket, :active)
      assert Pages.read_only({:ticket, ticket.id}) == false
      assert {:ok, _} = Pages.put(page, "a", 2, me)
    end

    test "an ended project chat's pages are read only", %{project: project, me: me} do
      chat = chat_fixture(%{project: project})
      {:ok, page} = Pages.ensure({:chat, chat.id}, "scratch")
      assert {:ok, _} = Pages.put(page, "a", 1, me)

      {:ok, _} =
        Events.append("chat.ended", {:user, elem(me, 1)}, %{
          job_id: chat.id,
          payload: %{"reason" => "closed"}
        })

      assert Pages.read_only({:chat, chat.id}) == {true, :chat_ended}
      assert {:error, {:read_only, :chat_ended}} = Pages.put(page, "a", 2, me)
    end
  end

  describe "a job's door" do
    test "needs the counter", %{job: job} do
      assert {:error, :counter_required} = Pages.job_write(job, "form", {:set, "a", 1}, [])
      assert {:ok, _} = Pages.job_write(job, "form", {:set, "a", 1}, counter: nil)
    end

    test "reaches its own ticket's pages and no other ticket's", %{project: project, job: job} do
      other = ticket_fixture(%{project: project})
      {:ok, _} = Pages.ensure({:ticket, other.id}, "theirs")

      assert {:error, :not_found} = Pages.job_page(job, "theirs")
      assert {:error, :not_found} = Pages.job_write(job, "theirs", {:set, "a", 1}, counter: nil)
      assert {:ok, %Page{name: "form"}} = Pages.job_page(job, "form")
    end

    test "may start the store of a page its state declares and no other", %{ticket: ticket} do
      declaring =
        job_fixture(%{ticket: ticket, attempt: 2, spec: %{"produces" => ["seed@", "x.md"]}})

      plain = job_fixture(%{ticket: ticket, attempt: 3})

      assert {:ok, _} = Pages.job_write(declaring, "seed", {:set, "a", 1}, counter: nil)

      assert {:error, :not_found} =
               Pages.job_write(declaring, "undeclared", {:set, "a", 1}, counter: nil)

      assert {:error, :not_found} = Pages.job_write(plain, "fresh", {:set, "a", 1}, counter: nil)
    end

    test "a command reaches nothing", %{ticket: ticket} do
      command = job_fixture(%{ticket: ticket, kind: :command, attempt: 4, spec: %{}})
      assert {:error, :forbidden} = Pages.job_write(command, "form", {:set, "a", 1}, counter: nil)
      assert {:error, :forbidden} = Pages.job_page(command, "form")
    end

    test "a project chat reaches its own pages and may start any valid name", %{project: project} do
      chat = chat_fixture(%{project: project})
      other = chat_fixture(%{project: project})
      {:ok, _} = Pages.ensure({:chat, other.id}, "theirs")

      assert {:ok, _} = Pages.job_write(chat, "mine", {:set, "a", 1}, counter: nil)

      # Another chat's page of the same name is none of this chat's: it starts a page of its own.
      assert {:ok, _} = Pages.job_write(chat, "theirs", {:set, "a", 1}, counter: nil)
      assert Pages.entries(Pages.get({:chat, other.id}, "theirs")) == []
      assert {:error, :not_found} = Pages.job_write(chat, "../x", {:set, "a", 1}, counter: nil)
      assert Pages.scope_of_job(chat) == {:chat, chat.id}
    end
  end

  describe "a person's or a token's write" do
    test "a non-member reaches nothing, and the page does not say it exists", %{page: page} do
      stranger = Forge.AccountsFixtures.user_fixture()
      assert {:error, :not_found} = Operator.write_page(page, stranger, "a", {:set, 1})
      assert {:error, :not_found} = Operator.set_page_outside(page, stranger, true)
      assert Pages.entries(page) == []
    end

    test "a member's write is unconditional", %{page: page} = context do
      user = Repo.get!(Forge.Accounts.User, elem(context.me, 1))
      assert {:ok, _} = Operator.write_page(page, user, "a", {:set, 1})
      assert {:ok, _} = Operator.write_page(page, user, "a", {:set, 2})
      assert {:ok, nil} = Operator.write_page(page, user, "never", :delete)
      assert Pages.entry(page, "a").user_id == user.id
    end

    test "a token needs write access and names a counter", %{project: project, page: page} do
      {:ok, _secret, reader} = Forge.Git.Tokens.issue(project, name: "ro", api: :read)
      {:ok, _secret, writer} = Forge.Git.Tokens.issue(project, name: "rw", api: :write)

      assert {:error, :not_found} =
               Operator.write_page(page, reader, "a", {:set, 1}, counter: nil)

      assert {:error, :counter_required} = Operator.write_page(page, writer, "a", {:set, 1})

      assert {:error, :counter_required} =
               Operator.write_page(page, writer, "a", {:set, 1}, counter: :any)

      assert {:ok, %{token_id: id}} =
               Operator.write_page(page, writer, "a", {:set, 1}, counter: nil)

      assert id == writer.id

      assert {:error, {:changed, _}} =
               Operator.write_page(page, writer, "a", {:set, 2}, counter: nil)
    end

    test "a token of another project reaches nothing", %{page: page} do
      {:ok, _secret, other} =
        Forge.Git.Tokens.issue(project_fixture(), name: "elsewhere", api: :write)

      assert {:error, :not_found} = Operator.write_page(page, other, "a", {:set, 1}, counter: nil)
    end
  end

  describe "the toggle" do
    test "is the viewer's own, and is recorded when it changes", %{page: page, user: user} do
      other = member_fixture(Forge.Projects.get!(page.project_id), :member)

      assert {:ok, true} = Operator.set_page_outside(page, user, true)
      assert Pages.outside?(user.id, page.id)
      refute Pages.outside?(other.id, page.id)

      # Already on: nothing is recorded twice.
      assert {:ok, true} = Operator.set_page_outside(page, user, true)
      assert {:ok, false} = Operator.set_page_outside(page, user, false)
      refute Pages.outside?(user.id, page.id)

      events =
        Repo.all(from e in Events.Event, where: e.type == "page.outside_access", order_by: e.seq)

      assert Enum.map(events, & &1.payload["on"]) == [true, false]
      assert Enum.all?(events, &(&1.actor == %{"kind" => "user", "id" => user.id}))
      assert Enum.all?(events, &(&1.payload["page"] == "form" and &1.ticket_id == page.ticket_id))
    end

    test "a token has none", %{project: project, page: page} do
      {:ok, _secret, writer} = Forge.Git.Tokens.issue(project, name: "rw", api: :write)
      assert {:error, :forbidden} = Operator.set_page_outside(page, writer, true)
    end
  end

  describe "telling everyone with the page open" do
    test "a set and a delete are broadcast with the writer and the counter", %{page: page, me: me} do
      :ok = Pages.subscribe(page.id)
      id = page.id

      {:ok, _} = Pages.put(page, "a", "v", me)

      assert_receive {:page_changed, ^id,
                      %{key: "a", op: :set, value: "v", counter: 1, writer: ^me}}

      {:ok, _} = Pages.delete(page, "a", me)
      assert_receive {:page_changed, ^id, %{key: "a", op: :delete, counter: 2}}

      # A refused write is not told to anyone.
      {:error, _} = Pages.put(page, "a", "v", me, counter: 9)
      refute_receive {:page_changed, _, _}, 50
    end
  end

  describe "the audit burst" do
    test "one event per writer per page, naming keys and never values", %{
      page: page,
      me: me,
      job: job
    } do
      {:ok, _} = Pages.put(page, "name", "SECRET-VALUE-1", me)
      {:ok, _} = Pages.put(page, "name", "SECRET-VALUE-2", me)
      {:ok, _} = Pages.put(page, "other", "SECRET-VALUE-3", me)
      {:ok, _} = Pages.put(page, "job-key", "x", {:job, job.id}, counter: nil)

      # Nothing is closed while the writers are still writing.
      assert Bursts.sweep() == 0
      assert Repo.all(from e in Events.Event, where: e.type == "page.data_changed") == []

      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 61, :second)) == 2
      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 61, :second)) == 0

      events =
        Repo.all(from e in Events.Event, where: e.type == "page.data_changed", order_by: e.seq)

      {person, agent} = Enum.split_with(events, &(&1.actor["kind"] == "user"))

      assert [
               %{
                 payload: %{
                   "changes" => 3,
                   "keys" => ["name", "other"],
                   "key_count" => 2,
                   "page" => "form"
                 }
               }
             ] = person

      assert [
               %{
                 actor: %{"kind" => "job", "id" => id},
                 payload: %{"changes" => 1, "writer" => %{"state" => "refining"}}
               }
             ] = agent

      assert id == job.id

      refute inspect(events) =~ "SECRET-VALUE"
    end

    test "is closed ten minutes after it opened however busy the writer is", %{page: page, me: me} do
      {:ok, _} = Pages.put(page, "a", 1, me)
      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 30, :second)) == 0
      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 601, :second)) == 1
    end

    test "names at most fifty keys and counts the rest", %{page: page, me: me} do
      for n <- 1..55, do: {:ok, _} = Pages.put(page, "k#{n}", n, me)
      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 61, :second)) == 1

      event = Repo.one!(from e in Events.Event, where: e.type == "page.data_changed")
      assert length(event.payload["keys"]) == 50
      assert event.payload["key_count"] == 55
      assert event.payload["changes"] == 55
    end

    test "a key repeated past the fifty names is counted again: key_count is an upper bound",
         %{page: page, me: me} do
      for n <- 1..51, do: {:ok, _} = Pages.put(page, "k#{n}", n, me)
      {:ok, _} = Pages.put(page, "k51", 0, me)
      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 61, :second)) == 1

      event = Repo.one!(from e in Events.Event, where: e.type == "page.data_changed")
      assert event.payload["changes"] == 52
      assert event.payload["key_count"] == 52
      assert Events.summary(event) =~ "made 52 changes to page form"
    end

    test "a refused write leaves no audit", %{page: page, me: me, ticket: ticket} do
      set_status!(ticket, :done)
      {:error, _} = Pages.put(page, "a", 1, me)
      assert Bursts.sweep(DateTime.add(DateTime.utc_now(), 700, :second)) == 0
    end
  end

  describe "recording a publish" do
    defp upload!(job, name, bytes) do
      key = Storage.Key.job(job.id, "out-t/#{name}-#{System.unique_integer([:positive])}")
      {:ok, info} = Storage.put(key, bytes)
      %{"key" => key, "size" => info.size, "hash" => info.hash}
    end

    defp publish!(job, scope, blobs, opts \\ [always?: true]) do
      Multi.new()
      |> Blobs.put_pages(scope, job, ["form"], blobs, opts)
      |> Repo.transaction()
    end

    test "makes a version whose files are blob versions of <page>/<file>", %{
      job: job,
      ticket: ticket
    } do
      blobs = %{
        "form/index.html" => upload!(job, "i", "<html></html>"),
        "form/app.js" => upload!(job, "a", "1")
      }

      assert {:ok, changes} = publish!(job, {:ticket, ticket.id}, blobs)
      version = changes[{{:page, "form"}, :version}]
      assert version.version == 1
      assert version.job_id == job.id
      assert Map.keys(version.files) |> Enum.sort() == ["app.js", "index.html"]
      assert Artifacts.latest(ticket.id, "form/index.html").id == version.files["index.html"]
      assert [%{page: %{name: "form"}, version: %{version: 1}}] = Pages.list({:ticket, ticket.id})

      assert Repo.one!(from e in Events.Event, where: e.type == "page.published").payload ==
               %{
                 "page" => "form",
                 "page_id" => changes[{{:page, "form"}, :page}].id,
                 "version" => 1,
                 "files" => 2,
                 "job_id" => job.id
               }
    end

    test "a republish is a new version and keeps the store", %{
      job: job,
      ticket: ticket,
      page: page,
      me: me
    } do
      {:ok, _} = Pages.put(page, "typed", "by a person", me)
      blobs = %{"form/index.html" => upload!(job, "i", "v1")}
      {:ok, _} = publish!(job, {:ticket, ticket.id}, blobs)

      blobs = %{"form/index.html" => upload!(job, "i", "v2")}
      assert {:ok, changes} = publish!(job, {:ticket, ticket.id}, blobs)
      assert changes[{{:page, "form"}, :version}].version == 2
      assert Pages.data_map(page) == %{"typed" => "by a person"}
      assert [_new, _old] = Pages.versions(page)
    end

    test "a file reported by its hash is the latest version's, and writes nothing new",
         %{job: job, ticket: ticket} do
      index = upload!(job, "i", "same")
      {:ok, first} = publish!(job, {:ticket, ticket.id}, %{"form/index.html" => index})
      old_id = first[{{:page, "form"}, :version}].files["index.html"]

      blobs = %{
        "form/index.html" => %{
          "hash" => String.replace_prefix(index["hash"], "sha256:", ""),
          "size" => 4
        }
      }

      assert {:ok, second} = publish!(job, {:ticket, ticket.id}, blobs)
      assert second[{{:page, "form"}, :version}].files["index.html"] == old_id
      assert length(Artifacts.versions({:ticket, ticket.id}, "form/index.html")) == 1
    end

    test "a hash that is not what the latest version holds is not recorded", %{
      job: job,
      ticket: ticket
    } do
      blobs = %{"form/index.html" => %{"hash" => String.duplicate("0", 64), "size" => 4}}
      assert {:ok, changes} = publish!(job, {:ticket, ticket.id}, blobs)
      refute Map.has_key?(changes, {{:page, "form"}, :version})
      assert Pages.list({:ticket, ticket.id}) == []
    end

    test "a hash that an earlier version holds is that version's, though a later one replaced it",
         %{job: job, ticket: ticket} do
      scope = {:ticket, ticket.id}
      app = upload!(job, "a", "one")
      index = upload!(job, "i", "i")
      {:ok, first} = publish!(job, scope, %{"form/index.html" => index, "form/app.js" => app})
      old_id = first[{{:page, "form"}, :version}].files["app.js"]

      # The page was republished with another app.js while the job ran, which skipped its upload
      # because the spec it started with said the platform held these bytes.
      second = %{"form/index.html" => index, "form/app.js" => upload!(job, "b", "two")}
      {:ok, _} = publish!(job, scope, second)

      held = %{"hash" => String.replace_prefix(app["hash"], "sha256:", ""), "size" => 3}
      blobs = %{"form/index.html" => upload!(job, "i", "i3"), "form/app.js" => held}

      assert {:ok, third} = publish!(job, scope, blobs)
      version = third[{{:page, "form"}, :version}]
      assert version.version == 3
      assert version.files["app.js"] == old_id
      assert length(Artifacts.versions(scope, "form/app.js")) == 2
    end

    test "a page's files are not also offered to the groups, which would log them undeclared", %{
      job: job,
      ticket: ticket
    } do
      spec = %ForgeCore.Job.Spec{job_id: job.id, branch: "b", produces: ["form@"]}
      blobs = %{"form/index.html" => upload!(job, "i", "x")}
      result = %ForgeCore.Job.Result{status: :finished, blobs: blobs}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, changes} =
                   Multi.new() |> Blobs.put(ticket.id, job, spec, result) |> Repo.transaction()

          assert changes[{{:page, "form"}, :version}].version == 1
        end)

      refute log =~ "undeclared"
    end

    test "a page whose index.html cannot be kept leaves none of its files behind", %{
      job: job,
      ticket: ticket
    } do
      {:ok, _} = Storage.put("job/someone-else/out-y/1", "theirs")

      blobs = %{
        "form/index.html" => %{"key" => "job/someone-else/out-y/1", "size" => 6},
        "form/app.js" => upload!(job, "a", "1")
      }

      assert {:ok, changes} = publish!(job, {:ticket, ticket.id}, blobs)
      refute Map.has_key?(changes, {{:page, "form"}, :version})
      assert Artifacts.find({:ticket, ticket.id}, "form/app.js") == nil
    end

    test "is recorded only with an index.html and only for a declared page", %{
      job: job,
      ticket: ticket
    } do
      blobs = %{
        "form/app.js" => upload!(job, "a", "1"),
        "undeclared/index.html" => upload!(job, "u", "2")
      }

      assert {:ok, changes} = publish!(job, {:ticket, ticket.id}, blobs)
      refute Map.has_key?(changes, {{:page, "form"}, :version})
      assert Artifacts.find({:ticket, ticket.id}, "undeclared/index.html") == nil
      assert Artifacts.find({:ticket, ticket.id}, "form/app.js") == nil
    end

    test "refuses the library's name, a key that is not the job's and a name that is not a file",
         %{job: job, ticket: ticket} do
      {:ok, _} = Storage.put("job/someone-else/out-x/1", "theirs")

      blobs = %{
        "form/index.html" => upload!(job, "i", "ok"),
        "form/forge-page.js" => upload!(job, "f", "evil"),
        "form/stolen.html" => %{"key" => "job/someone-else/out-x/1", "size" => 6},
        "form/../x" => upload!(job, "x", "x")
      }

      assert {:ok, changes} = publish!(job, {:ticket, ticket.id}, blobs)
      assert changes[{{:page, "form"}, :version}].files |> Map.keys() == ["index.html"]
    end

    test "a chat's turn makes a version only when a file changed", %{project: project} do
      chat = chat_fixture(%{project: project})
      scope = {:job, chat.id}

      first = %{"form/index.html" => upload!(chat, "i", "one")}
      assert {:ok, changes} = publish!(chat, scope, first, always?: false)
      assert changes[{{:page, "form"}, :version}].version == 1

      same = %{"form/index.html" => %{"hash" => first["form/index.html"]["hash"]}}
      assert {:ok, changes} = publish!(chat, scope, same, always?: false)
      assert changes[{{:page, "form"}, :version}] == nil
      assert [%{version: %{version: 1}}] = Pages.list({:chat, chat.id})

      changed = %{"form/index.html" => upload!(chat, "i", "two")}
      assert {:ok, changes} = publish!(chat, scope, changed, always?: false)
      assert changes[{{:page, "form"}, :version}].version == 2
    end

    test "is announced after the commit", %{job: job, ticket: ticket} do
      {:ok, page} = Pages.ensure({:ticket, ticket.id}, "form")
      :ok = Pages.subscribe(page.id)

      {:ok, changes} =
        publish!(job, {:ticket, ticket.id}, %{"form/index.html" => upload!(job, "i", "x")})

      refute_receive {:page_published, _, _}, 20

      Blobs.announce(changes)
      id = page.id
      assert_receive {:page_published, ^id, 1}
    end

    test "the spec's view of a ticket's pages", %{job: job, ticket: ticket, page: page, me: me} do
      {:ok, _} = Pages.put(page, "a", 1, me)

      {:ok, _} =
        publish!(job, {:ticket, ticket.id}, %{"form/index.html" => upload!(job, "i", "hello")})

      assert [
               %{
                 "name" => "form",
                 "version" => 1,
                 "keys" => 1,
                 "read_only" => nil,
                 "by" => "an agent in refining",
                 "files" => files
               }
             ] =
               Pages.manifest({:ticket, ticket.id})

      assert %{"index.html" => %{"size" => 5, "hash" => hash}} = files
      assert hash == Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower)

      set_status!(ticket, :done)
      assert [%{"read_only" => "done"}] = Pages.manifest({:ticket, ticket.id})
      assert Pages.manifest(nil) == []
    end
  end

  describe "a declared page that was not kept" do
    defp converged(blobs) do
      %ForgeCore.Job.Result{
        status: :finished,
        outcome: :converged,
        declared_outcome: "done",
        blobs: blobs
      }
    end

    defp spec_for(attrs),
      do: struct!(ForgeCore.Job.Spec, Map.merge(%{job_id: "j", branch: "b"}, attrs))

    test "is an error, though the run said it converged" do
      spec = spec_for(%{produces: ["form@", "notes.md"]})

      assert %{outcome: :error, declared_outcome: nil, reason: reason} =
               Blobs.require_pages(spec, converged(%{"form/app.js" => %{"hash" => "ab"}}))

      assert reason =~ "form"
      assert reason =~ "index.html"
    end

    test "is not one when it is reported, optional, or the run did not converge" do
      spec = spec_for(%{produces: ["form@"]})
      kept = converged(%{"form/index.html" => %{"hash" => "ab"}})
      assert Blobs.require_pages(spec, kept) == kept

      optional = spec_for(%{produces: ["form@"], optional: ["form"]})
      assert Blobs.require_pages(optional, converged(%{})).outcome == :converged

      failed = %{converged(%{}) | outcome: :error, reason: "x"}
      assert Blobs.require_pages(spec, failed) == failed
    end

    test "is nothing to a state that declares no page" do
      assert Blobs.require_pages(spec_for(%{produces: ["a.md"]}), converged(%{})).outcome ==
               :converged
    end
  end

  describe "the outputs an assignment carries" do
    test "a job that declares a page, and a chat always, are given a prefix; one that declares none is not",
         %{ticket: ticket} do
      plain = job_fixture(%{ticket: ticket, attempt: 5})
      spec = %ForgeCore.Job.Spec{job_id: plain.id, branch: "b", produces: ["form@"]}

      assert Blobs.outputs(
               plain,
               %ForgeCore.Job.Spec{job_id: plain.id, branch: "b", produces: ["x.md"]},
               1000
             ) == %{}

      assert %{"outputs" => %{"prefix" => _, "token" => _}} = Blobs.outputs(plain, spec, 1000)

      chat = chat_fixture(%{project: Forge.Projects.get!(ticket.project_id)})

      assert %{"outputs" => %{"prefix" => prefix}} =
               Blobs.outputs(
                 chat,
                 %ForgeCore.Job.Spec{job_id: chat.id, branch: "b", produces: []},
                 1000
               )

      assert String.starts_with?(prefix, "job/#{chat.id}/out-")
    end
  end
end
