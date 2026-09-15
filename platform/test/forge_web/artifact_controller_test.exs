defmodule ForgeWeb.ArtifactControllerTest do
  @moduledoc """
  The bytes behind every artifact name in the product.

  `docs/design/ui.md` § Addressable artifact versions. What is tested here is what the links on
  the ticket and job pages depend on: an exact version, never "latest" standing in for one; a
  changeset going to the review page because a commit is not a file; and a `file://` row — the
  milestone 1 form, still on old rows — confined to the platform's own data directory.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.GitFixtures

  alias Forge.{Artifacts, Projects, Storage, Tickets}

  setup :register_and_log_in_user

  setup do
    {:ok, project} =
      Projects.register(%{
        name: "art-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    %{project: project, data_dir: data_dir}
  end

  defp admitted(project, user) do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    ticket
  end

  defp write(ticket, name, content, user) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :document, {:user, user.id}, %{content: content})

    version
  end

  defp write_blob(ticket, name, uri, user) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :blob, {:user, user.id}, %{blob_uri: uri})

    version
  end

  test "requires a logged-in operator", %{project: project, user: user} do
    ticket = admitted(project, user)

    conn = get(build_conn(), ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/ticket")

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "serves a document as plain text, front matter and all", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)
    write(ticket, "plan.md", "---\noutcome: done\n---\n# Plan\n\nDo the thing.\n", user)

    conn = get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/plan.md")

    assert response(conn, 200) == "---\noutcome: done\n---\n# Plan\n\nDo the thing.\n"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    # Agents wrote this, so it must never be served as something a browser will lay out.
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="plan-v1.md")
  end

  test "an exact version is served, not whatever is latest", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)
    write(ticket, "plan.md", "# first\n", user)
    write(ticket, "plan.md", "# second\n", user)

    assert get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/plan.md")
           |> response(200) == "# first\n"

    assert get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/2/plan.md")
           |> response(200) == "# second\n"

    # There is no versionless form: it would have to mean "latest", and the product never
    # resolves that for you. See docs/design/ui.md § Addressable artifact versions.
    assert get(conn, "/tickets/#{project.name}/#{ticket.number}/artifacts/plan.md").status == 404
  end

  # The version goes before the name so the address ends in the artifact's own file name. With
  # the name first the last segment was the version — `…/artifacts/index.html/1` — and everything
  # that decides by extension saw a file called `1`: the browser rendering it, the name a `Save
  # as` offers, anything following the link.
  test "the address ends in the artifact's file name, extension and all", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)
    write(ticket, "index.html", "<h1>built</h1>\n", user)

    path = ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/index.html"

    assert String.ends_with?(path, "/index.html")
    assert response(get(conn, path), 200) == "<h1>built</h1>\n"

    # And still never served as something the browser will lay out, whatever the name says.
    conn = get(conn, path)
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "a blob comes out of the store", %{conn: conn, project: project, user: user} do
    ticket = admitted(project, user)
    key = "job/#{Ecto.UUID.generate()}/transcript-1.jsonl"
    {:ok, _info} = Storage.put(key, ~s({"type":"result"}\n))

    write_blob(ticket, "transcript-planning-1.jsonl", Storage.uri(key), user)

    conn =
      get(
        conn,
        ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/transcript-planning-1.jsonl"
      )

    assert response(conn, 200) == ~s({"type":"result"}\n)
  end

  test "a changeset is a commit, so it goes to the diff instead", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)

    write_blob(ticket, "changeset", "git:" <> String.duplicate("a", 40), user)

    conn = get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/changeset")

    assert redirected_to(conn) == ~p"/tickets/#{project.name}/#{ticket.number}/review"
  end

  test "a milestone 1 file:// row is served from inside the data directory", %{
    conn: conn,
    project: project,
    user: user,
    data_dir: data_dir
  } do
    ticket = admitted(project, user)
    path = Path.join(data_dir, "old-transcript.jsonl")
    File.write!(path, "from before the store existed\n")

    write_blob(ticket, "transcript-old.jsonl", "file://" <> path, user)

    conn =
      get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/transcript-old.jsonl")

    assert response(conn, 200) == "from before the store existed\n"
  end

  test "a file:// row pointing outside the data directory is refused", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)
    outside = Path.join(tmp_dir("elsewhere"), "secrets.env")
    File.write!(outside, "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-nope\n")

    write_blob(ticket, "sneaky.txt", "file://" <> outside, user)

    conn = get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/sneaky.txt")

    assert conn.status == 404
    refute conn.resp_body =~ "sk-ant-nope"
  end

  test "a crafted artifact name cannot shape the Content-Disposition header", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)
    write(ticket, ~s(plan";filename="evil.html), "# crafted\n", user)

    conn =
      get(
        conn,
        "/tickets/#{project.name}/#{ticket.number}/artifacts/1/" <>
          URI.encode(~s(plan";filename="evil.html), &URI.char_unreserved?/1)
      )

    assert [disposition] = get_resp_header(conn, "content-disposition")
    refute disposition =~ "evil.html"
    refute disposition =~ ~s(";filename=)
  end

  test "an artifact name with a newline does not take the route down", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admitted(project, user)
    write(ticket, "plan\nX-Injected: 1", "# crafted\n", user)

    conn =
      get(
        conn,
        "/tickets/#{project.name}/#{ticket.number}/artifacts/1/" <>
          URI.encode("plan\nX-Injected: 1", &URI.char_unreserved?/1)
      )

    assert conn.status == 200
    assert get_resp_header(conn, "x-injected") == []
  end

  test "an unknown artifact or version is a 404", %{conn: conn, project: project, user: user} do
    ticket = admitted(project, user)
    write(ticket, "plan.md", "# only one\n", user)

    assert get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/1/ghost.md").status ==
             404

    assert get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/9/plan.md").status ==
             404

    assert get(conn, ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/nope/plan.md").status ==
             404
  end
end
