defmodule ForgeWorker.Archive.TreeTest do
  @moduledoc """
  The archive's shape (`docs/design/archive.md` § Layout): what a path is, what it needs fetched
  first, and that a name finds a file by exact key or nothing.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Archive.Tree

  @ref "11111111-1111-1111-1111-111111111111"

  defp file(path, extra \\ %{}),
    do: Map.merge(%{"path" => path, "ref" => @ref, "size" => 3, "sha256" => nil}, extra)

  defp listings do
    root =
      Tree.root(%{
        "tickets" => [1, 2],
        "files" => [file("index.md", %{"ref" => nil, "inline" => "x"})]
      })

    ticket =
      Tree.ticket(%{
        "files" => [file("plan.md"), file("plan.v001.md"), file("reports/out.txt")]
      })

    %{:root => %{data: root, at: 0}, {:ticket, "1"} => %{data: ticket, at: 0}}
  end

  test "the root needs nothing, and a ticket's folder needs only the root" do
    assert {:ok, {:dir, []}} = Tree.resolve(%{}, [])
    assert Tree.resolve(%{}, ["1"]) == {:need, :root}
    assert {:ok, {:dir, ["1"]}} = Tree.resolve(listings(), ["1"])
    assert Tree.resolve(listings(), ["3"]) == :enoent
  end

  test "what is inside a ticket needs that ticket's listing, and only when the ticket exists" do
    assert Tree.resolve(Map.delete(listings(), {:ticket, "1"}), ["1", "plan.md"]) ==
             {:need, {:ticket, "1"}}

    # Ticket 3 is not in the root, so nothing is fetched for it.
    assert Tree.resolve(listings(), ["3", "plan.md"]) == :enoent
  end

  test "files, group folders and what is not there" do
    assert {:ok, {:file, ["1", "plan.md"], %{"size" => 3}}} =
             Tree.resolve(listings(), ["1", "plan.md"])

    assert {:ok, {:dir, ["1", "reports"]}} = Tree.resolve(listings(), ["1", "reports"])
    assert {:ok, {:file, _, _}} = Tree.resolve(listings(), ["1", "reports", "out.txt"])
    assert Tree.resolve(listings(), ["1", "nothing"]) == :enoent
    assert Tree.resolve(listings(), ["1", "plan.md", "below"]) == :enoent
    assert {:ok, {:file, ["index.md"], _}} = Tree.resolve(listings(), ["index.md"])
  end

  test "children are the names directly inside, sorted, with folders for groups" do
    assert Tree.children(listings(), ["1"]) ==
             {:ok, [{"plan.md", :file}, {"plan.v001.md", :file}, {"reports", :dir}]}

    assert Tree.children(listings(), ["1", "reports"]) == {:ok, [{"out.txt", :file}]}
    assert Tree.children(listings(), []) == {:ok, [{"1", :dir}, {"2", :dir}, {"index.md", :file}]}
    assert Tree.children(%{}, []) == {:need, :root}
    assert Tree.children(listings(), ["1", "plan.md"]) == :enoent
  end

  test "a name that is not one is dropped from a listing, whatever the platform sent" do
    ticket =
      Tree.ticket(%{
        "files" =>
          [
            "..",
            ".",
            "a/b/c",
            "",
            "ok.md",
            String.duplicate("x", 256),
            "nul" <> <<0>>
          ]
          |> Enum.map(&file/1)
      })

    assert Map.keys(ticket.files) == ["ok.md"]
  end

  test "an entry that names its bytes by anything but a version id is dropped" do
    ticket =
      Tree.ticket(%{
        "files" => [file("a", %{"ref" => "../../etc/passwd"}), file("b", %{"size" => -1})]
      })

    assert ticket.files == %{}
  end

  test "name? is the whole rule" do
    assert Tree.name?("plan.v001.md")
    refute Tree.name?("a/b")
    refute Tree.name?("..")
    refute Tree.name?("")
    refute Tree.name?(<<0>>)
    refute Tree.name?(nil)
  end

  test "parent of the root is the root, and a path number is stable" do
    assert Tree.parent([]) == []
    assert Tree.parent(["1", "a"]) == ["1"]
    assert Tree.number(["1", "a"]) == Tree.number(["1", "a"])
    assert Tree.number(["1", "a"]) != Tree.number(["1", "b"])
  end
end
