defmodule Forge.ReleaseTest do
  use Forge.DataCase, async: false

  import ExUnit.CaptureIO

  alias Forge.{Accounts, Release}

  test "generate_vapid_keys prints a usable pair" do
    output = capture_io(fn -> Release.generate_vapid_keys() end)

    assert [public, private] =
             output
             |> String.split("\n", trim: true)
             |> Enum.map(&(&1 |> String.split("=", parts: 2) |> List.last()))

    assert {:ok, <<4, _::binary-size(64)>>} = Base.url_decode64(public, padding: false)
    assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(private, padding: false)
  end

  test "migrate is idempotent on a migrated database" do
    assert :ok = Release.migrate()
  end

  test "create_operator and create_token work against the repo" do
    email = "op#{System.unique_integer([:positive])}@example.com"

    assert capture_io(fn -> Release.create_operator(email, "a sufficiently long password") end) =~
             "created user #{email}"

    assert %{confirmed_at: %DateTime{}} = user = Accounts.get_user_by_email(email)

    assert Accounts.get_user_by_email_and_password(email, "a sufficiently long password").id ==
             user.id

    token = capture_io(fn -> Release.create_token(email, "phone") end) |> String.trim()
    assert Accounts.get_user_by_api_token(token).id == user.id
  end
end
