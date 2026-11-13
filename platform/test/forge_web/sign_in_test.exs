defmodule ForgeWeb.SignInTest do
  @moduledoc """
  What the device's remembered method means, and which of a provider's refusals are quoted
  (`docs/design/ui.md` § Signing in). The pages that use them are tested in
  `ForgeWeb.UserLive.LoginTest` and `LoginOidcTest`; this is the table each reads.
  """

  # Not `async: true`: the provider list is application config (`Forge.FakeIssuer.install/1`).
  use ExUnit.Case, async: false

  alias Forge.FakeIssuer
  alias ForgeWeb.SignIn

  setup do
    FakeIssuer.install()
  end

  test "reads back exactly what it writes, and nothing else" do
    assert SignIn.remembered("password") == :password
    assert SignIn.remembered("magic") == :magic
    assert SignIn.remembered("oidc:test") == {:oidc, "test"}

    for value <- [nil, "", "Password", "magic ", "oidc:", "oidc:gone", "oidc", "x:password"] do
      assert SignIn.remembered(value) == nil, inspect(value)
    end
  end

  test "a remembered provider counts only while the node has it" do
    assert SignIn.remembered("oidc:test") == {:oidc, "test"}

    Application.put_env(:forge, Forge.Accounts.Oidc, [])

    assert SignIn.remembered("oidc:test") == nil
  end

  test "quotes the registered refusal codes and no others" do
    assert SignIn.refusal_reading("access_denied") =~ "You cancelled"
    assert SignIn.refusal_reading("temporarily_unavailable") =~ "Try again shortly"

    for code <- [nil, "", "ACCESS_DENIED", "access_denied ", "<b>x</b>", "something_else"] do
      assert SignIn.refusal_reading(code) == nil, inspect(code)
      assert SignIn.refusal("test", code) == nil
    end

    assert SignIn.refusal("test", "access_denied") == "access_denied:test"
  end

  test "reads a refusal back only for a registered code and a configured provider" do
    assert %{name: "Test Provider", host: "issuer.example.test", code: "login_required"} =
             SignIn.read_refusal("login_required:test")

    assert SignIn.read_refusal("login_required:other") == nil
    assert SignIn.read_refusal("made_up:test") == nil
    assert SignIn.read_refusal("login_required") == nil
    assert SignIn.read_refusal(nil) == nil
  end

  test "names an issuer by its provider, and by its host once no provider names it" do
    assert SignIn.issuer_label("https://issuer.example.test") == "Test Provider"
    assert SignIn.issuer_label("https://gone.example.test/realms/x") == "gone.example.test"
    assert SignIn.issuer_label("not a url") == "not a url"
  end
end
