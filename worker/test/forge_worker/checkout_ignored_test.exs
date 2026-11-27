defmodule ForgeWorker.CheckoutIgnoredTest do
  @moduledoc """
  What git ignores in a kept build, at the topmost level (`ForgeWorker.Checkout.ignored/2`,
  `docs/design/worker-tier.md` § Looking into a copy): listed the way the folder sizes need it, not
  the traditional way, which would name the folder that holds an ignored one.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures, only: [tmp_dir: 1]

  alias ForgeWorker.Checkout

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  setup do
    dir = tmp_dir("ignored")
    git!(dir, ["init", "--quiet"])
    File.write!(Path.join(dir, ".gitignore"), "target/\n_build/\ndeps/\n*.o\n")
    File.mkdir_p!(Path.join(dir, "platform/_build/dev"))
    File.mkdir_p!(Path.join(dir, "platform/lib"))
    File.mkdir_p!(Path.join(dir, "sub/target"))
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "platform/lib/a.ex"), "tracked")
    File.write!(Path.join(dir, "platform/_build/dev/x"), "built")
    File.write!(Path.join(dir, "sub/target/y"), "built")
    File.write!(Path.join(dir, "src/m.o"), "object")
    File.write!(Path.join(dir, "src/untracked.txt"), "not ignored")
    git!(dir, ["add", ".gitignore", "platform/lib/a.ex"])
    %{dir: dir}
  end

  test "lists the topmost ignored folders, a loose file and nothing that is merely untracked",
       %{dir: dir} do
    assert {:ok, ignored} = Checkout.ignored(dir, &{&1, &2})

    assert Enum.sort(ignored) ==
             Enum.sort([
               {"platform/_build", :dir},
               {"sub/target", :dir},
               {"src/m.o", :file}
             ])
  end

  test "is an error where there is no repository" do
    assert {:error, {code, _out}} = Checkout.ignored(tmp_dir("not-a-repo"), &{&1, &2})
    assert code != 0
  end

  test "is run as the user it is given", %{dir: dir} do
    test = self()

    as = fn executable, args ->
      send(test, {:ran_as, executable})
      {executable, args}
    end

    {:ok, _ignored} = Checkout.ignored(dir, as)
    assert_received {:ran_as, "git"}
  end
end
