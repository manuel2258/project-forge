defmodule ForgeWorker.Job.SessionTest do
  @moduledoc """
  A Codex session leaving the machine (`docs/design/codex.md` § Sessions): found by the driver's
  layout, masked — including a login Codex rewrote, which the sealed credential does not hold —
  and never carrying `auth.json`.
  """

  use ExUnit.Case, async: false

  alias ForgeCore.Job.Credential
  alias ForgeWorker.Harness.Codex
  alias ForgeWorker.Job.{Dir, Session}

  @thread "0199-aaaa-bbbb"

  setup do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    previous =
      for key <- [:token, :platform_url, :req_options],
          do: {key, Application.get_env(:forge_worker, key)}

    Application.put_env(:forge_worker, :token, token)
    Application.put_env(:forge_worker, :platform_url, "http://platform.test")

    test = self()

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        send(test, {:uploaded, conn.request_path, body})
        Req.Test.json(conn, %{"key" => conn.request_path, "size" => byte_size(body)})
      end
    )

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:forge_worker, key, value),
          else: Application.delete_env(:forge_worker, key)
      end
    end)

    job_dir = Path.join(System.tmp_dir!(), "session-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(job_dir) end)
    codex = Path.join([Dir.home_dir(job_dir), ".codex"])
    day = Path.join([codex, "sessions", "2026", "11", "12"])
    File.mkdir_p!(day)

    rollout =
      ~s({"type":"session_meta","payload":{"id":"#{@thread}"}}\n) <>
        ~s({"type":"event_msg","text":"printed rt-REFRESHED and rt-DELIVERED"}\n)

    File.write!(Path.join(day, "rollout-2026-11-12T08-00-00-#{@thread}.jsonl"), rollout)

    # Codex refreshed the login: `auth.json` holds a token the sealed credential does not.
    File.write!(
      Path.join(codex, "auth.json"),
      Jason.encode!(%{"tokens" => %{"refresh_token" => "rt-REFRESHED"}})
    )

    {:ok, hash} = Credential.token_hash(token)

    delivered = Jason.encode!(%{"tokens" => %{"refresh_token" => "rt-DELIVERED"}})

    assignment = %{
      "job_id" => "job-1",
      "store" => %{"session_prefix" => "job/job-1/session/", "session_token" => "t"},
      "credential" => %{"sealed" => Credential.seal(delivered, hash, "job-1")}
    }

    %{job_dir: job_dir, assignment: assignment}
  end

  test "a Codex rollout is found by its layout, uploaded masked, and the login is not in it",
       %{job_dir: job_dir, assignment: assignment} do
    assert "job/job-1/session/1.jsonl" = Session.upload(job_dir, @thread, assignment, 1, Codex)

    assert_received {:uploaded, "/store/job/job-1/session/1.jsonl", body}
    assert body =~ "printed [secret credential] and [secret credential]"
    refute body =~ "rt-REFRESHED"
    refute body =~ "rt-DELIVERED"
    # Only the one upload: `auth.json` was never a candidate.
    refute_received {:uploaded, _path, _body}
  end

  test "Claude Code's layout does not find a Codex rollout", %{
    job_dir: job_dir,
    assignment: assignment
  } do
    assert Session.upload(job_dir, @thread, assignment, 1) == nil
    refute_received {:uploaded, _path, _body}
  end
end
