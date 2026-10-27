defmodule ForgeWorker.ClaudeUpdateTest do
  @moduledoc """
  Reading what `claude-code-update.service` left behind (`docs/design/worker-tier.md` § Updating a
  worker). Every case here is a file this test wrote, not a unit that ran: the shell script's own
  behaviour is the flake check's to prove, and what this module owes is that a file nothing can
  make sense of reads as *no report* rather than as a crash at `ready`.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.ClaudeUpdate

  setup do
    root = Path.join(System.tmp_dir!(), "claude-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, body), do: File.write!(Path.join(root, "claude-code-update.json"), body)

  test "a well-formed file is passed through as it was written", %{root: root} do
    write(root, ~s|{"outcome":"succeeded","version":"2.1.270 (Claude Code)"}|)

    assert ClaudeUpdate.status(root) == %{
             "outcome" => "succeeded",
             "version" => "2.1.270 (Claude Code)"
           }
  end

  test "the error the attempt recorded comes through with it", %{root: root} do
    write(root, ~s|{"outcome":"failed","error":"curl: (6) could not resolve host"}|)

    assert %{"outcome" => "failed", "error" => "curl: (6) could not resolve host"} =
             ClaudeUpdate.status(root)
  end

  # An image older than the unit. Not an error, and not a worker that refuses to start: it simply
  # has nothing to say about an update it never attempted.
  test "no file at all is no report", %{root: root} do
    assert ClaudeUpdate.status(root) == nil
  end

  # The mutation these three are aimed at is the `with` losing both its shape check and its
  # `else`: `File.read`'s own `{:error, :enoent}` and `Jason.decode`'s error tuple then come back
  # as the status, and so does a list, and `ready_payload/1` puts one of those on the wire. `nil`
  # is the only answer that keeps the payload a map the platform can read.
  test "a half-written file is no report", %{root: root} do
    write(root, ~s|{"outcome":"succ|)

    assert ClaudeUpdate.status(root) == nil
  end

  test "valid JSON that is not an object with an outcome is no report", %{root: root} do
    write(root, ~s|["succeeded"]|)
    assert ClaudeUpdate.status(root) == nil

    write(root, ~s|{"version":"2.1.270"}|)
    assert ClaudeUpdate.status(root) == nil

    write(root, ~s|{"outcome":null,"version":"2.1.270"}|)
    assert ClaudeUpdate.status(root) == nil

    write(root, ~s|{"outcome":3}|)
    assert ClaudeUpdate.status(root) == nil
  end

  # A directory where the file should be: `File.read/1` answers `{:error, :eisdir}`, which is the
  # one unreadable case a test can make without being root.
  test "something that is not a readable file is no report", %{root: root} do
    File.mkdir_p!(Path.join(root, "claude-code-update.json"))

    assert ClaudeUpdate.status(root) == nil
  end
end
