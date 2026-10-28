defmodule ForgeWorker.Archive.P9Test do
  @moduledoc """
  The wire format of the archive's 9P server (`docs/design/archive.md` § The worker's side): what
  the kernel's client sends is cut and read as it is, and what a write would be is told apart from
  what a read is.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Archive.P9

  defp message(type, tag, body),
    do: <<byte_size(body) + 7::32-little, type, tag::16-little>> <> body

  test "frame cuts one message at a time and says when more is needed" do
    one = message(120, 1, <<5::32-little>>)
    two = message(120, 2, <<6::32-little>>)

    assert {:ok, ^one, ^two} = P9.frame(one <> two)
    assert P9.frame(binary_part(one, 0, 6)) == :more
    assert P9.frame(<<1, 0>>) == :more
  end

  test "frame refuses a size that cannot be a message" do
    assert P9.frame(<<3::32-little, 0, 0, 0>>) == :error
    assert P9.frame(<<2_000_000::32-little, 0, 0, 0>>) == :error
  end

  test "decode reads what the kernel sends" do
    assert {1, {:version, 65_536, "9P2000.L"}} =
             P9.decode(message(100, 1, <<65_536::32-little, 8::16-little, "9P2000.L">>))

    attach =
      <<7::32-little, 0xFFFFFFFF::32-little, 4::16-little, "root", 0::16-little, 0::32-little>>

    assert {2, {:attach, 7}} = P9.decode(message(104, 2, attach))

    walk = <<1::32-little, 2::32-little, 2::16-little, 1::16-little, "a", 2::16-little, "bc">>
    assert {3, {:walk, 1, 2, ["a", "bc"]}} = P9.decode(message(110, 3, walk))

    assert {4, {:read, 9, 10, 20}} =
             P9.decode(message(116, 4, <<9::32-little, 10::64-little, 20::32-little>>))

    assert {5, {:clunk, 9}} = P9.decode(message(120, 5, <<9::32-little>>))
    assert {6, {:flush, 4}} = P9.decode(message(108, 6, <<4::16-little>>))
  end

  test "decode refuses a message that is cut short or has more than it says" do
    assert P9.decode(
             message(110, 3, <<1::32-little, 2::32-little, 2::16-little, 1::16-little, "a">>)
           ) ==
             :error

    walk = <<1::32-little, 2::32-little, 1::16-little, 1::16-little, "a", "extra">>
    assert P9.decode(message(110, 3, walk)) == :error
    assert P9.decode(message(104, 3, <<1::32-little>>)) == :error
  end

  test "every message that would change anything is told apart from a read" do
    for type <- [14, 16, 18, 20, 26, 32, 50, 70, 72, 74, 76, 118, 122, 102] do
      assert {0, {:mutating, ^type}} = P9.decode(message(type, 0, <<0::32>>)), "type #{type}"
    end

    assert {0, {:readlink}} = P9.decode(message(22, 0, <<0::32>>))
    assert {0, {:unsupported, 52}} = P9.decode(message(52, 0, <<0::32>>))
    assert {0, {:unknown, 200}} = P9.decode(message(200, 0, <<0::32>>))
  end

  test "writes? is true for anything but a plain read" do
    refute P9.writes?(0)
    # O_LARGEFILE, which the kernel adds to a read.
    refute P9.writes?(0o100000)
    assert P9.writes?(1)
    assert P9.writes?(2)
    assert P9.writes?(0o100)
    assert P9.writes?(0o1000)
    assert P9.writes?(0o2000)
  end

  test "replies carry their size, type and tag" do
    assert IO.iodata_to_binary(P9.error(9, :erofs)) ==
             <<11::32-little, 7, 9::16-little, 30::32-little>>

    assert IO.iodata_to_binary(P9.clunk(3)) == <<7::32-little, 121, 3::16-little>>

    read = IO.iodata_to_binary(P9.read(4, "abc"))
    assert read == <<14::32-little, 117, 4::16-little, 3::32-little, "abc">>

    qid = P9.qid(:dir, 5)
    assert byte_size(qid) == 13
    assert <<0x80, 0::32, 5::64-little>> == qid
    assert <<0, 0::32, 5::64-little>> == P9.qid(:file, 5)

    # 13 for the qid, 4 mode, 4 uid, 4 gid, 8 nlink, 8 rdev, 8 size, 8 blksize, 8 blocks, 4 * 16
    # times, 16 for generation and data version, 8 for the valid mask.
    attr = IO.iodata_to_binary(P9.getattr(1, qid, :file, 100, 0))
    assert byte_size(attr) == 7 + 8 + 13 + 12 + 8 + 8 + 8 * 3 + 64 + 16
  end
end
