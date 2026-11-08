defmodule Forge.ReferencesTest do
  @moduledoc """
  What a name in Markdown means (`docs/design/ui.md` § Documents → References). The cut at the
  referring text, the same-job exception, the conversation's narrowing, and the forms a reference
  may take. Versions are inserted as rows, because a version is immutable and its clock cannot be
  moved after the fact.
  """

  use Forge.DataCase, async: false

  import Forge.GitFixtures

  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Conversations
  alias Forge.Events.Event
  alias Forge.Projects
  alias Forge.References
  alias Forge.Repo
  alias Forge.Tickets

  @t ~U[2026-01-01 12:00:00Z]

  setup do
    user = Forge.AccountsFixtures.user_fixture()

    {:ok, project} =
      Projects.register(
        %{name: "ref-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, one} = Tickets.admit(project, %{title: "one"}, {:user, user.id})
    {:ok, two} = Tickets.admit(project, %{title: "two"}, {:user, user.id})
    {:ok, chat} = Conversations.open(project, "talk")

    %{
      project: project,
      one: one,
      two: two,
      chat: chat,
      scope: References.ticket_scope(project.name, two)
    }
  end

  defp artifact(owner, name, kind \\ :blob) do
    attrs =
      case owner do
        {:ticket, id} -> %{ticket_id: id}
        {:job, id} -> %{job_id: id}
      end

    Repo.insert!(struct!(Artifact, Map.merge(attrs, %{name: name, kind: kind})))
  end

  defp version(artifact, number, at, author \\ %{"kind" => "user", "id" => Ecto.UUID.generate()}) do
    document? = artifact.kind == :document

    Repo.insert!(%Version{
      artifact_id: artifact.id,
      version: number,
      author: author,
      content: if(document?, do: "# doc\n"),
      blob_uri: unless(document?, do: "store:job/x/out-a/#{number}"),
      content_hash: "h#{number}",
      inserted_at: at
    })
  end

  defp job(id), do: %{"kind" => "job", "id" => id}
  defp at(seconds), do: DateTime.add(@t, seconds, :second)

  defp moment(seconds, extra \\ []),
    do: Map.merge(%{at: at(seconds), job: nil, turn_seq: nil}, Map.new(extra))

  defp ask(scope, moment, ref) do
    %{0 => answers} = References.resolve(scope, [{0, moment, [ref]}])
    answers[ref]
  end

  defp found(result) do
    assert {:ok, %{version: version}} = result
    version
  end

  describe "a bare name is pinned to the referring text" do
    test "sees what existed then, the same second included, and not what came after", ctx do
      art = artifact({:ticket, ctx.two.id}, "shot.png")
      version(art, 1, at(-10))
      version(art, 2, at(0))
      version(art, 3, at(1))

      assert found(ask(ctx.scope, moment(0), "shot.png")) == 2
      assert found(ask(ctx.scope, moment(-5), "shot.png")) == 1
      assert {:error, {:missing, :ticket}} = ask(ctx.scope, moment(-11), "shot.png")
      assert found(ask(ctx.scope, %{at: :now, job: nil, turn_seq: nil}, "shot.png")) == 3
    end

    test "the version a text's own job wrote is seen whenever the clock says; a person's or another job's is not",
         ctx do
      art = artifact({:ticket, ctx.two.id}, "shot.png")
      version(art, 1, at(-10))
      version(art, 2, at(30), job("job-a"))
      version(art, 3, at(60), job("job-b"))
      version(art, 4, at(90))

      assert found(ask(ctx.scope, moment(0, job: "job-a"), "shot.png")) == 2
      assert found(ask(ctx.scope, moment(0, job: "job-b"), "shot.png")) == 3
      # A text no job wrote has no exception.
      assert found(ask(ctx.scope, moment(0), "shot.png")) == 1
    end

    test "a conversation's later turns are cut by event order, not by the clock", ctx do
      art = artifact({:ticket, ctx.two.id}, "shot.png")
      chat = ctx.chat.id
      first = version(art, 1, at(0), job(chat))
      second = version(art, 2, at(0), job(chat))
      event(first, chat, 10)
      event(second, chat, 20)

      assert found(ask(ctx.scope, moment(0, job: chat, turn_seq: 15), "shot.png")) == 1
      assert found(ask(ctx.scope, moment(0, job: chat, turn_seq: 25), "shot.png")) == 2
      # Streaming: nothing is recorded yet, so what exists is seen.
      assert found(ask(ctx.scope, %{at: :now, job: nil, turn_seq: nil}, "shot.png")) == 2
    end

    test "the moment of a version a conversation wrote is its own turn's record", ctx do
      art = artifact({:ticket, ctx.two.id}, "plan.md", :document)
      chat = ctx.chat.id
      v1 = version(art, 1, at(0), job(chat))
      v2 = version(art, 2, at(5), job(chat))
      event(v1, chat, 100)
      event(v2, chat, 300)
      log(chat, "chat.turn", 200)
      log(chat, "chat.turn", 400)

      assert %{job: ^chat, turn_seq: 200, at: _} = References.moment(v1)
      assert %{job: ^chat, turn_seq: 400} = References.moment(v2)
      assert %{job: nil, turn_seq: nil} = References.moment(%{v1 | author: %{"kind" => "user"}})
    end
  end

  describe "a text given as a version" do
    # The conversation's own documents are cut by event order whichever way the moment arrives:
    # as a map from a message, or as the `Version` a document is.
    test "stands for its turn: a later turn's screenshot is not seen, though the clock allows it",
         ctx do
      chat = ctx.chat.id
      shot = artifact({:ticket, ctx.two.id}, "shot.png")
      s1 = version(shot, 1, at(0), job(chat))
      s2 = version(shot, 2, at(0), job(chat))
      doc = version(artifact({:ticket, ctx.two.id}, "plan.md", :document), 1, at(0), job(chat))
      event(s1, chat, 50)
      event(doc, chat, 100)
      log(chat, "chat.turn", 200)
      event(s2, chat, 250)

      %{0 => %{"shot.png" => answer}} = References.resolve(ctx.scope, [{0, doc, ["shot.png"]}])
      assert found(answer) == 1
    end
  end

  describe "the moment a version stands for" do
    test "is its own clock, whoever wrote it", ctx do
      art = artifact({:ticket, ctx.two.id}, "plan.md", :document)
      by_user = version(art, 1, at(-3600))
      by_job = version(art, 2, at(-1800), job(Ecto.UUID.generate()))

      assert References.moment(by_user) == %{at: at(-3600), job: nil, turn_seq: nil}
      assert %{at: at, job: job, turn_seq: nil} = References.moment(by_job)
      assert at == by_job.inserted_at
      assert is_binary(job)
    end
  end

  describe "numbered and latest" do
    test "@N is that version whenever it was written, and a missing one does not resolve", ctx do
      art = artifact({:ticket, ctx.two.id}, "shot.png")
      version(art, 1, at(0))
      version(art, 2, at(500))

      assert found(ask(ctx.scope, moment(0), "shot.png@2")) == 2
      assert found(ask(ctx.scope, moment(0), "shot.png@1")) == 1
      assert {:error, {:no_version, 3}} = ask(ctx.scope, moment(0), "shot.png@3")
    end

    test "@latest follows new versions and a bare name does not", ctx do
      art = artifact({:ticket, ctx.two.id}, "shot.png")
      version(art, 1, at(0))
      assert found(ask(ctx.scope, moment(0), "shot.png@latest")) == 1
      version(art, 2, at(50))
      assert found(ask(ctx.scope, moment(0), "shot.png@latest")) == 2
      assert found(ask(ctx.scope, moment(0), "shot.png")) == 1
    end
  end

  describe "the forms" do
    test "anything that is not exactly a name, with an optional @ and prefix, does not resolve",
         ctx do
      art = artifact({:ticket, ctx.two.id}, "screenshots/queue.png")
      version(art, 1, at(0))
      ok = ask(ctx.scope, moment(0), "screenshots/queue.png")
      assert {:ok, %{version: 1, raster?: true}} = ok

      for ref <- [
            "./screenshots/queue.png",
            "Screenshots/queue.png",
            "screenshots/queue.png@Latest",
            "screenshots/queue.png@002",
            "screenshots/queue.png@01",
            "screenshots/queue.png@0",
            "screenshots/queue.png@",
            "screenshots%2Fqueue.png",
            "screenshots/queue.v001.png",
            "archive/002/screenshots/queue.png",
            "archive/0/screenshots/queue.png"
          ] do
        assert {:error, _} = ask(ctx.scope, moment(0), ref), ref
      end

      assert found(ask(ctx.scope, moment(0), "archive/2/screenshots/queue.png@1")) == 1
    end

    # The number is bounded at nine digits: a longer one would be a bigint the database refuses,
    # which raised and took the page down. It is read as part of a name instead, and is not found.
    test "a number too long for a ticket or a version does not reach the database", ctx do
      version(artifact({:ticket, ctx.two.id}, "a.png"), 1, at(0))

      for ref <- [
            "archive/99999999999999999999/a.png",
            "archive/1234567890/a.png",
            "a.png@99999999999999999999",
            "a.png@1234567890"
          ] do
        assert {:error, _} = ask(ctx.scope, moment(0), ref), ref
      end
    end

    test "a URL, a data: URI, a protocol-relative URL and a path into the app are outside", ctx do
      for ref <- [
            "https://x.test/a.png",
            "http://x.test/a.png",
            "data:image/png;base64,AAAA",
            "//x.test/a.png",
            "/tickets/p/1/artifacts/x/1",
            "javascript:alert(1)",
            "mailto:a@b.c"
          ] do
        assert {:error, :outside} = ask(ctx.scope, moment(0), ref), ref
      end
    end

    test "an exact name that holds an @ wins over the reading with a version", ctx do
      plain = artifact({:ticket, ctx.two.id}, "a")
      version(plain, 1, at(0))
      version(plain, 2, at(0))
      odd = artifact({:ticket, ctx.two.id}, "a@2")
      version(odd, 1, at(0))

      assert {:ok, %{name: "a@2", version: 1}} = ask(ctx.scope, moment(0), "a@2")
      assert {:ok, %{name: "a", version: 2}} = ask(ctx.scope, moment(0), "a@latest")
    end

    test "no references costs no query", _ctx do
      # Ids that are not UUIDs would raise at the first query.
      scope = %{project_id: "nope", project: "p", ticket: {"nope", 1}, chat: nil}
      assert References.resolve(scope, [{:a, moment(0), []}]) == %{a: %{}}
    end

    test "the raster test is the name's, and an SVG or a document is not an image", ctx do
      for {name, kind, raster?} <- [
            {"a.png", :blob, true},
            {"b.PNG", :blob, true},
            {"c.avif", :blob, true},
            {"d.svg", :blob, false},
            {"e.png", :document, false},
            {"f.txt", :blob, false}
          ] do
        version(artifact({:ticket, ctx.two.id}, name, kind), 1, at(0))
        assert {:ok, %{raster?: ^raster?}} = ask(ctx.scope, moment(0), name), name
      end
    end
  end

  describe "scopes" do
    test "a bare name is looked up in the text's own ticket and nowhere else", ctx do
      version(artifact({:ticket, ctx.one.id}, "only-one.png"), 1, at(0))

      assert {:error, {:missing, :ticket}} = ask(ctx.scope, moment(0), "only-one.png")
      assert found(ask(ctx.scope, moment(0), "archive/1/only-one.png")) == 1
    end

    test "archive/<n>/ reaches that ticket of the same project only", ctx do
      %{project: project, one: one} = ctx
      version(artifact({:ticket, one.id}, "x.png"), 1, at(0))
      assert {:ok, %{where: {:ticket, name, 1}}} = ask(ctx.scope, moment(0), "archive/1/x.png")
      assert name == project.name

      # Another project's ticket 1 holds a different `x.png`; the other project's is not reachable.
      user = Forge.AccountsFixtures.user_fixture()

      {:ok, other} =
        Projects.register(
          %{name: "other-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, foreign} = Tickets.admit(other, %{title: "f"}, {:user, user.id})
      version(artifact({:ticket, foreign.id}, "secret.png"), 1, at(0))

      # Ticket 3 exists only in the other project, so a lookup that ignored the project would find
      # it; the answer must not depend on which row a map keeps.
      {:ok, _} = Tickets.admit(other, %{title: "g"}, {:user, user.id})
      {:ok, third} = Tickets.admit(other, %{title: "h"}, {:user, user.id})
      version(artifact({:ticket, third.id}, "secret.png"), 1, at(0))
      assert third.number == 3
      assert {:error, {:no_ticket, 3}} = ask(ctx.scope, moment(0), "archive/3/secret.png")
      assert {:error, {:missing, 1}} = ask(ctx.scope, moment(0), "archive/1/secret.png")
      assert {:error, {:no_ticket, 99}} = ask(ctx.scope, moment(0), "archive/99/x.png")
    end

    test "another ticket's bare name is cut by the clock alone, the same-job rule not applying",
         ctx do
      art = artifact({:ticket, ctx.one.id}, "x.png")
      version(art, 1, at(-5))
      version(art, 2, at(60), job("job-a"))

      assert found(ask(ctx.scope, moment(0, job: "job-a"), "archive/1/x.png")) == 1
      # ...while the text's own number is the same as no prefix, same-job included.
      own = artifact({:ticket, ctx.two.id}, "y.png")
      version(own, 1, at(-5))
      version(own, 2, at(60), job("job-a"))
      assert found(ask(ctx.scope, moment(0, job: "job-a"), "archive/2/y.png")) == 2
      assert found(ask(ctx.scope, moment(0, job: "job-a"), "y.png")) == 2
    end

    test "a project chat searches its own documents, not a ticket's of the same name", ctx do
      chat_scope = References.chat_scope(ctx.project, ctx.chat.id)
      version(artifact({:ticket, ctx.two.id}, "notes.md", :document), 1, at(0))
      assert {:error, {:missing, :chat}} = ask(chat_scope, moment(0), "notes.md")

      mine = artifact({:job, ctx.chat.id}, "notes.md", :document)
      version(mine, 1, at(0))

      assert {:ok, %{where: {:chat, id}, version: 1, raster?: false}} =
               ask(chat_scope, moment(0), "notes.md")

      assert id == ctx.chat.id
      # A ticket's file is still reachable by its number.
      version(artifact({:ticket, ctx.one.id}, "t.png"), 1, at(0))
      assert found(ask(chat_scope, moment(0), "archive/1/t.png")) == 1
    end
  end

  defp event(version, chat, seq) do
    Repo.insert!(%Event{
      seq: seq,
      actor: %{"kind" => "job", "id" => chat},
      type: "artifact.version_written",
      job_id: chat,
      payload: %{"version_id" => version.id}
    })
  end

  defp log(chat, type, seq) do
    Repo.insert!(%Event{
      seq: seq,
      actor: %{"kind" => "job", "id" => chat},
      type: type,
      job_id: chat,
      payload: %{}
    })
  end
end
