defmodule ForgeWeb.ApiAuthorTest do
  @moduledoc """
  Everywhere an author is drawn, `API` reads as itself: with the token's name, after the token is
  revoked, and without any page looking up a user that does not exist. `docs/design/api-and-ui.md`
  § JSON API.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Operator, Projects}
  alias Forge.Git.Tokens

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "au-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, _secret, token} =
      Tokens.issue(project, name: "release-bot", git: :reader, api: :write, issued_by_id: user.id)

    %{project: project, token: token}
  end

  defp written_through_the_api(project, token) do
    {:ok, ticket} = Operator.admit(project, token, %{title: "By API"})

    {:ok, _} =
      Operator.edit(ticket, token, "plan.md", """
      # Plan

      ```question
      key: naming
      text: What is the table called?
      options: [{label: scores, detail: About scores}]
      blocking: false
      assumption: scores
      ```
      """)

    {:ok, _} = Operator.answer(ticket, token, "naming", %{choice: "scores"})

    changeset!(
      ticket,
      commit_over_http(project, ticket.branch, "score.ex", "def persist, do: :ok")
    )

    ticket
  end

  test "the ticket page and the review page draw an API author, revoked or not, and the queue still loads",
       ctx do
    %{conn: conn, project: project, token: token} = ctx
    ticket = written_through_the_api(project, token)

    for _revoked <- [false, true] do
      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert html =~ "API · release-bot"

      {:ok, _view, review} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
      assert review =~ "API · release-bot"

      assert {:ok, _view, _queue} = live(conn, ~p"/")

      {:ok, _} = Tokens.revoke(token.id)
    end
  end

  test "an answer and a version written through the API say API in the API's own payload", ctx do
    %{conn: conn, project: project, token: token} = ctx
    ticket = written_through_the_api(project, token)

    assert %{author: %{"kind" => "api", "name" => "release-bot"}} =
             Artifacts.latest(ticket.id, "plan.md")

    secret = Forge.Accounts.create_api_token(ctx.user, "test")

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> secret)
      |> get("/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert [%{"author" => %{"kind" => "api", "id" => id, "name" => "release-bot"}}] =
             body["answers"]

    assert id == token.id
  end
end
