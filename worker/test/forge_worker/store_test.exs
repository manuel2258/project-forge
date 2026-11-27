defmodule ForgeWorker.StoreTest do
  @moduledoc """
  The platform's blob store from the worker's side. What is tested here is the one thing the
  callers act on: whether the store said yes.

  A token minted per assignment is short lived, and a key the platform has since forgotten
  answers 404. Every caller of this module branches on the answer — `Link.put_transcript/2`
  records the key on the result only when the upload happened, `Seed.unpack/5` unpacks only
  what arrived, `Conversation.fetch_transcript/3` writes a `.missing` note instead — so a
  module that called every status a success would have each of them record a blob that is
  not there.
  """

  # The Req plug is configured through the application environment, which is global.
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Store

  setup do
    dir = tmp_dir("store")
    path = Path.join(dir, "transcript.jsonl")
    File.write!(path, ~s({"type":"result"}\n))

    on_exit(fn -> Application.delete_env(:forge_worker, :req_options) end)

    %{dir: dir, path: path}
  end

  defp answer(status, body) do
    Application.put_env(:forge_worker, :req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, status, body) end
    )
  end

  # 404 rather than 500: `retry: :transient` retries a 5xx, so the status a test asserts on has
  # to be one the client is meant to take at face value — an expired token or a key the
  # platform no longer has.
  test "an upload the store refused is an error, not a recorded blob", %{path: path} do
    answer(404, "no such key")

    assert Store.put("http://platform.test", "job/j1/transcript-1.jsonl", "tok", path) ==
             {:error, {404, "no such key"}}

    # And the same call against a store that accepted it is not: the two are distinguished,
    # which is the claim this test makes.
    answer(200, ~s({"key":"job/j1/transcript-1.jsonl","size":21}))

    assert {:ok, _recorded} =
             Store.put("http://platform.test", "job/j1/transcript-1.jsonl", "tok", path)
  end

  # `docs/design/worker-channel.md` § A platform restart: a run that ends during a deploy uploads
  # to a platform that is not there for a minute or two, and three retries over seven seconds gave
  # up long before it was back. A transient failure is waited out; the delay is shortened here.
  test "an upload waits out a platform that is restarting", %{path: path} do
    Application.put_env(:forge_worker, :upload_retry_base_ms, 1)
    on_exit(fn -> Application.delete_env(:forge_worker, :upload_retry_base_ms) end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          n when n <= 6 -> Plug.Conn.send_resp(conn, 503, "restarting")
          _back -> Req.Test.json(conn, %{"key" => "k", "size" => 1})
        end
      end
    )

    assert {:ok, _recorded} = Store.put("http://platform.test", "job/j1/t.jsonl", "tok", path)
    assert Agent.get(attempts, & &1) == 7
  end

  test "a download the store refused is an error, not an empty file", %{dir: dir} do
    into = Path.join(dir, "fetched/transcript.jsonl")
    answer(404, "no such key")

    assert {:error, {404, _body}} =
             Store.fetch("http://platform.test", "job/j1/t.jsonl", "t", into)

    answer(200, ~s({"type":"result"}\n))
    assert Store.fetch("http://platform.test", "job/j1/t.jsonl", "t", into) == :ok
    assert File.read!(into) =~ "result"
  end

  # `docs/design/worker-channel.md` § Protocol 18: a download is posted as it is produced, with the
  # stream's secret as a bearer, and what comes back is the status the platform ended with.
  test "a stream is posted chunk by chunk with the secret as a bearer, and its status is returned" do
    test = self()

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

        send(
          test,
          {:streamed, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "x-forge-kind"), body}
        )

        Plug.Conn.send_resp(conn, 200, "")
      end
    )

    body = Stream.map(["one ", "two ", "three"], & &1)

    assert {:ok, 200} =
             Store.stream_post("http://platform.test/worker-streams/abc", "secret", body, [
               {"x-forge-kind", "tar"}
             ])

    assert_received {:streamed, "POST", "/worker-streams/abc", ["Bearer secret"], ["tar"],
                     "one two three"}
  end

  test "a stream the platform refused is the status it refused with, and is not retried" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        Agent.update(attempts, &(&1 + 1))
        Plug.Conn.send_resp(conn, 503, "busy")
      end
    )

    assert {:ok, 503} = Store.stream_post("http://platform.test/worker-streams/abc", "s", ["x"])
    assert Agent.get(attempts, & &1) == 1
  end

  test "a stream that cannot reach the platform is an error, not a status" do
    Application.delete_env(:forge_worker, :req_options)

    assert {:error, _reason} =
             Store.stream_post("http://127.0.0.1:1/worker-streams/abc", "s", ["x"])
  end
end
