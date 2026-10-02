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
end
