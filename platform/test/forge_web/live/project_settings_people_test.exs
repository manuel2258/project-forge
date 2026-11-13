defmodule ForgeWeb.ProjectSettingsPeopleTest do
  @moduledoc """
  People on project settings (`docs/design/ui.md` § People, `9f`): a role changed in place on the
  row, a remove behind a confirm, and the last administrator's controls disabled with the reason
  — while `Forge.Projects.put_member/4` and `remove_member/3` refuse whatever the page drew.
  Adding someone is `MembershipScopingTest`'s.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [member_fixture: 2, project_fixture: 0]

  alias Forge.Projects

  setup %{conn: conn} do
    project = project_fixture()
    admin = member_fixture(project, :admin)
    %{conn: log_in_user(conn, admin), admin: admin, project: project}
  end

  defp people(conn, project),
    do: live(conn, ~p"/projects/#{project.name}/settings?section=people")

  test "an admin makes a member an admin and back, in place", ctx do
    %{conn: conn, project: project} = ctx
    jo = member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    assert has_element?(view, ~s(#role-#{jo.id} button[aria-checked="true"]), "member")

    view
    |> element(~s(#role-#{jo.id} button[phx-value-role=admin]))
    |> render_click()

    assert Projects.role(project, jo) == :admin
    assert has_element?(view, ~s(#role-#{jo.id} button[aria-checked="true"]), "admin")

    view
    |> element(~s(#role-#{jo.id} button[phx-value-role=member]))
    |> render_click()

    assert Projects.role(project, jo) == :member
  end

  test "the role a person already has is not offered as a change", ctx do
    %{conn: conn, project: project} = ctx
    jo = member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    assert has_element?(view, ~s(#role-#{jo.id} button[phx-value-role=member][disabled]))
    refute has_element?(view, ~s(#role-#{jo.id} button[phx-value-role=admin][disabled]))
  end

  test "making yourself a member asks first", %{conn: conn, project: project, admin: admin} do
    member_fixture(project, :admin)
    {:ok, view, _html} = people(conn, project)

    assert view |> element("#role-#{admin.id}-member-confirm") |> render() =~ "no longer"

    assert has_element?(
             view,
             ~s(#role-#{admin.id}-member[phx-click="set-role"][phx-value-role=member]),
             "Make me a member"
           )
  end

  # Granting admin is the more dangerous direction (UX pass, D23): asked in place, naming whom;
  # demoting someone else is not.
  test "making someone an admin asks first, and making them a member again does not", ctx do
    %{conn: conn, project: project} = ctx
    jo = member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    assert view |> element("#role-#{jo.id}-admin-confirm") |> render() =~
             "Make #{jo.email} an admin of #{project.name}?"

    view |> element("#role-#{jo.id}-admin", "Make them admin") |> render_click()
    {:ok, view, _html} = people(conn, project)
    refute has_element?(view, "#role-#{jo.id}-member-confirm")
    assert has_element?(view, ~s|#role-#{jo.id} button[phx-value-role=member]:not([disabled])|)
  end

  # The menu and the × are drawn disabled, with today's words, and the event sent anyway is
  # refused by the context: the page's drawing is not the guard.
  test "the last administrator cannot be demoted or removed", ctx do
    %{conn: conn, project: project, admin: admin} = ctx
    member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    # The same member | admin as every row, both options disabled.
    assert has_element?(
             view,
             ~s(#role-#{admin.id} button[aria-checked="true"][disabled]),
             "admin"
           )

    assert has_element?(view, ~s(#role-#{admin.id} button[phx-value-role=member][disabled]))
    refute has_element?(view, ~s|#role-#{admin.id} button:not([disabled])|)
    assert has_element?(view, ~s(#member-#{admin.id} button.settings-x[disabled]))

    assert has_element?(
             view,
             "#member-#{admin.id}",
             "A project keeps at least one administrator."
           )

    html = render_click(view, "set-role", %{"id" => admin.id, "role" => "member"})
    assert html =~ "A project keeps at least one administrator."
    assert Projects.role(project, admin) == :admin

    render_click(view, "remove-member", %{"id" => admin.id})
    assert Projects.role(project, admin) == :admin
  end

  test "with a second administrator, either can be changed", ctx do
    %{conn: conn, project: project, admin: admin} = ctx
    other = member_fixture(project, :admin)
    {:ok, view, _html} = people(conn, project)

    for user <- [admin, other] do
      assert has_element?(view, ~s|#role-#{user.id} button[aria-checked="false"]:not([disabled])|)
      refute has_element?(view, ~s(#member-#{user.id} button.settings-x[disabled]))
    end
  end

  test "an admin removes someone behind a confirm", %{conn: conn, project: project} do
    jo = member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    button = element(view, ~s(#member-#{jo.id} button[phx-click="remove-member"]))

    assert view |> element("#remove-#{jo.id}-confirm") |> render() =~
             "Remove #{jo.email} from #{project.name}?"

    render_click(button)

    refute Projects.member?(project, jo)
    refute has_element?(view, "#member-#{jo.id}")
  end

  # The id is resolved among this project's members, so the event cannot be a way in.
  test "a role cannot be set on someone who is not in the project", ctx do
    %{conn: conn, project: project} = ctx
    outsider = user_fixture()
    {:ok, view, _html} = people(conn, project)

    html = render_click(view, "set-role", %{"id" => outsider.id, "role" => "admin"})

    assert html =~ "That account is not in this project."
    refute Projects.member?(project, outsider)
  end

  test "a role off the wire that is not one is refused, not raised", ctx do
    %{conn: conn, project: project} = ctx
    jo = member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    for params <- [%{"id" => jo.id, "role" => "owner"}, %{"id" => jo.id}, %{}] do
      assert render_click(view, "set-role", params) =~ "Pick a role."
    end

    assert Projects.role(project, jo) == :member
  end

  # A refusal keeps what was typed and the role picked, so the address is corrected rather
  # than typed again (`docs/design/ui.md` § Errors stay where you acted); adding someone empties it.
  test "a refused address stays in the field, and an added one is cleared", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = people(conn, project)

    view
    |> form("#add-member-form", %{
      "member" => %{"email" => "nobdy@example.com", "role" => "admin"}
    })
    |> render_submit()

    assert has_element?(view, "#member-error", "No approved account")

    assert has_element?(
             view,
             ~s(#add-member-form input[name="member[email]"][value="nobdy@example.com"])
           )

    assert has_element?(view, ~s(#member-role input[value="admin"][checked]))

    jo = user_fixture()

    view
    |> form("#add-member-form", %{"member" => %{"email" => jo.email, "role" => "member"}})
    |> render_submit()

    assert Projects.role(project, jo) == :member
    refute has_element?(view, "#member-error")
    assert has_element?(view, ~s(#add-member-form input[name="member[email]"][value=""]))
  end

  describe "a member who is not an admin" do
    test "is refused setting a role by sending the event", %{project: project} do
      plain = member_fixture(project, :member)
      jo = member_fixture(project, :member)

      {:ok, view, _html} = people(log_in_user(build_conn(), plain), project)

      # Not offered: the section is the admin's.
      refute has_element?(view, "#people")

      render_click(view, "set-role", %{"id" => jo.id, "role" => "admin"})
      render_click(view, "set-role", %{"id" => plain.id, "role" => "admin"})

      assert Projects.role(project, jo) == :member
      assert Projects.role(project, plain) == :member
    end
  end

  # You first, then the admins, then everyone else by address: the same order on every load
  # (UX pass, D23).
  test "people are listed you first, then admins, then by address", ctx do
    %{conn: conn, project: project, admin: admin} = ctx
    zed = member_fixture(project, :member)
    other_admin = member_fixture(project, :admin)
    amy = member_fixture(project, :member)
    {:ok, view, _html} = people(conn, project)

    ids =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#members > li")
      |> LazyHTML.attribute("id")

    rest = Enum.sort_by([zed, amy], & &1.email)
    assert ids == Enum.map([admin, other_admin | rest], &"member-#{&1.id}")
  end
end
