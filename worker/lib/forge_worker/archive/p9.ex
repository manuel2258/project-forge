defmodule ForgeWorker.Archive.P9 do
  @moduledoc """
  The parts of 9P2000.L the Linux client sends to a read-only server, as pure functions: cut a
  byte stream into messages, decode the ones it sends, encode the replies
  (`docs/design/archive.md` § The worker's side).

  Everything is little-endian. A request is decoded to `{tag, message}`; a message that would
  change something is `{:mutating, type}` and one this server does not know is `{:unknown, type}`,
  so that the server answers every well-formed request, and answers a write with `EROFS`. A
  message of a kind it answers with a body that is not that kind's is `:error`: the client is not
  speaking the protocol, and the connection is closed.
  """

  import Bitwise

  # errno values, as the Linux client reads them in an `Rlerror`.
  @errno %{
    eperm: 1,
    enoent: 2,
    eio: 5,
    ebadf: 9,
    eacces: 13,
    enotdir: 20,
    eisdir: 21,
    einval: 22,
    erofs: 30,
    enosys: 38,
    enodata: 61,
    eopnotsupp: 95,
    etimedout: 110
  }

  # Message types. Odd numbers are replies.
  @rlerror 7
  @tstatfs 8
  @tlopen 12
  @tlcreate 14
  @tsymlink 16
  @tmknod 18
  @trename 20
  @treadlink 22
  @tgetattr 24
  @tsetattr 26
  @txattrwalk 30
  @txattrcreate 32
  @treaddir 40
  @tfsync 50
  @tlock 52
  @tgetlock 54
  @tlink 70
  @tmkdir 72
  @trenameat 74
  @tunlinkat 76
  @tversion 100
  @tauth 102
  @tattach 104
  @tflush 108
  @twalk 110
  @tread 116
  @twrite 118
  @tclunk 120
  @tremove 122

  @mutating [
    @tlcreate,
    @tsymlink,
    @tmknod,
    @trename,
    @tsetattr,
    @txattrcreate,
    @tfsync,
    @tlink,
    @tmkdir,
    @trenameat,
    @tunlinkat,
    @twrite,
    @tremove,
    @tauth
  ]

  @answered [
    @tversion,
    @tattach,
    @twalk,
    @tlopen,
    @tread,
    @treaddir,
    @tgetattr,
    @tclunk,
    @tstatfs,
    @tflush,
    @txattrwalk
  ]

  @qtdir 0x80
  @max_message 1_048_576 + 4096

  @doc "The errno number for `name`."
  @spec errno(atom()) :: pos_integer()
  def errno(name), do: Map.fetch!(@errno, name)

  # -- framing ----------------------------------------------------------------------------------

  @doc """
  The first whole message in `buffer`: `{:ok, message, rest}`, `:more` when it is not all here
  yet, or `:error` for a size that cannot be a message (smaller than a header, or past what this
  server ever negotiates). The caller closes the connection on an error.
  """
  @spec frame(binary()) :: {:ok, binary(), binary()} | :more | :error
  def frame(<<size::32-little, _rest::binary>>) when size < 7 or size > @max_message, do: :error

  def frame(<<size::32-little, _rest::binary>> = buffer) when byte_size(buffer) >= size do
    <<message::binary-size(size), rest::binary>> = buffer
    {:ok, message, rest}
  end

  def frame(_buffer), do: :more

  # -- requests ---------------------------------------------------------------------------------

  @doc "Decodes one whole message (as `frame/1` returns it) to `{tag, message}`, or `:error`."
  @spec decode(binary()) :: {non_neg_integer(), tuple()} | :error
  def decode(<<_size::32-little, type, tag::16-little, body::binary>>) do
    case body(type, body) do
      :error -> :error
      message -> {tag, message}
    end
  end

  def decode(_other), do: :error

  defp body(@tversion, <<msize::32-little, len::16-little, version::binary-size(len)>>),
    do: {:version, msize, version}

  defp body(@tattach, <<fid::32-little, _afid::32-little, rest::binary>>) do
    with {:ok, _uname, rest} <- string(rest),
         {:ok, _aname, <<_n_uname::32-little>>} <- string(rest) do
      {:attach, fid}
    else
      _other -> :error
    end
  end

  defp body(@twalk, <<fid::32-little, newfid::32-little, count::16-little, rest::binary>>) do
    case strings(rest, count, []) do
      {:ok, names} -> {:walk, fid, newfid, names}
      :error -> :error
    end
  end

  defp body(@tlopen, <<fid::32-little, flags::32-little>>), do: {:lopen, fid, flags}

  defp body(@tread, <<fid::32-little, offset::64-little, count::32-little>>),
    do: {:read, fid, offset, count}

  defp body(@treaddir, <<fid::32-little, offset::64-little, count::32-little>>),
    do: {:readdir, fid, offset, count}

  defp body(@tgetattr, <<fid::32-little, mask::64-little>>), do: {:getattr, fid, mask}
  defp body(@tclunk, <<fid::32-little>>), do: {:clunk, fid}
  defp body(@tstatfs, <<fid::32-little>>), do: {:statfs, fid}
  defp body(@tflush, <<oldtag::16-little>>), do: {:flush, oldtag}

  defp body(@txattrwalk, <<fid::32-little, newfid::32-little, _name::binary>>),
    do: {:xattrwalk, fid, newfid}

  # A message of a kind this server answers, with a body that is not that kind's: the client is
  # not speaking the protocol, and the connection is closed (`decode/1` returns `:error`).
  defp body(type, _body) when type in @answered, do: :error

  defp body(@treadlink, _body), do: {:readlink}
  defp body(type, _body) when type in [@tlock, @tgetlock], do: {:unsupported, type}
  defp body(type, _body) when type in @mutating, do: {:mutating, type}
  defp body(type, _body) when is_integer(type), do: {:unknown, type}

  defp string(<<len::16-little, text::binary-size(len), rest::binary>>), do: {:ok, text, rest}
  defp string(_other), do: :error

  defp strings(rest, 0, acc), do: if(rest == "", do: {:ok, Enum.reverse(acc)}, else: :error)

  defp strings(rest, count, acc) do
    case string(rest) do
      {:ok, text, rest} -> strings(rest, count - 1, [text | acc])
      :error -> :error
    end
  end

  @doc """
  Whether a `lopen` for `flags` would write: any access mode but read-only, or truncate, create,
  or append. A server that opened it would be a server that could be written to.
  """
  @spec writes?(non_neg_integer()) :: boolean()
  def writes?(flags),
    do: (flags &&& 3) != 0 or (flags &&& (0o100 ||| 0o1000 ||| 0o2000)) != 0

  # -- replies ----------------------------------------------------------------------------------

  @doc "A qid: its kind (`:dir` or `:file`), a version and a path number."
  @spec qid(:dir | :file, non_neg_integer()) :: binary()
  def qid(kind, path),
    do: <<if(kind == :dir, do: @qtdir, else: 0), 0::32-little, path::64-little>>

  @spec error(non_neg_integer(), atom()) :: iodata()
  def error(tag, name), do: reply(@rlerror, tag, <<errno(name)::32-little>>)

  @spec version(non_neg_integer(), non_neg_integer(), String.t()) :: iodata()
  def version(tag, msize, version),
    do: reply(101, tag, <<msize::32-little, byte_size(version)::16-little, version::binary>>)

  @spec attach(non_neg_integer(), binary()) :: iodata()
  def attach(tag, qid), do: reply(105, tag, qid)

  @spec walk(non_neg_integer(), [binary()]) :: iodata()
  def walk(tag, qids), do: reply(111, tag, [<<length(qids)::16-little>> | qids])

  @spec lopen(non_neg_integer(), binary()) :: iodata()
  def lopen(tag, qid), do: reply(13, tag, [qid, <<0::32-little>>])

  @spec read(non_neg_integer(), binary()) :: iodata()
  def read(tag, data), do: reply(117, tag, [<<byte_size(data)::32-little>>, data])

  @spec readdir(non_neg_integer(), binary()) :: iodata()
  def readdir(tag, data), do: reply(41, tag, [<<byte_size(data)::32-little>>, data])

  @spec clunk(non_neg_integer()) :: iodata()
  def clunk(tag), do: reply(121, tag, "")

  @spec flush(non_neg_integer()) :: iodata()
  def flush(tag), do: reply(109, tag, "")

  @doc "One entry of a `readdir` reply: `offset` is where the client resumes after it."
  @spec dirent(binary(), non_neg_integer(), :dir | :file, String.t()) :: binary()
  def dirent(qid, offset, kind, name) do
    type = if kind == :dir, do: 4, else: 8
    <<qid::binary, offset::64-little, type, byte_size(name)::16-little, name::binary>>
  end

  @doc "A `getattr` reply: mode, size and a fixed time, owned by root."
  @spec getattr(non_neg_integer(), binary(), :dir | :file, non_neg_integer(), integer()) ::
          iodata()
  def getattr(tag, qid, kind, size, time) do
    {mode, nlink} = if kind == :dir, do: {0o040555, 2}, else: {0o100444, 1}
    blocks = div(size + 511, 512)

    reply(25, tag, [
      <<0x7FF::64-little>>,
      qid,
      <<mode::32-little, 0::32-little, 0::32-little, nlink::64-little, 0::64-little,
        size::64-little, 4096::64-little, blocks::64-little>>,
      # atime, mtime, ctime, btime: seconds and nanoseconds, all the same instant.
      for(_ <- 1..4, into: <<>>, do: <<time::64-little, 0::64-little>>),
      <<0::64-little, 0::64-little>>
    ])
  end

  @doc "A `statfs` reply for a read-only filesystem with nothing free."
  @spec statfs(non_neg_integer()) :: iodata()
  def statfs(tag) do
    reply(
      9,
      tag,
      <<0x01021997::32-little, 4096::32-little, 0::64-little, 0::64-little, 0::64-little,
        0::64-little, 0::64-little, 0::64-little, 255::32-little>>
    )
  end

  defp reply(type, tag, body) do
    body = IO.iodata_to_binary(body)
    <<byte_size(body) + 7::32-little, type, tag::16-little, body::binary>>
  end
end
