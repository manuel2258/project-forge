defmodule ForgeWorker.Job.SecretsTest do
  @moduledoc """
  A job's secrets on the worker (`docs/design/secrets.md` § Delivery, § Masking): opened only for
  the job, purpose and machine they were sealed for; refused by name when the name is reserved;
  and masked, value and JSON-escaped form, in what leaves the machine.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForgeCore.Job.Credential
  alias ForgeWorker.Job.Secrets

  setup do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    previous = Application.get_env(:forge_worker, :token)
    Application.put_env(:forge_worker, :token, token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:forge_worker, :token, previous),
        else: Application.delete_env(:forge_worker, :token)
    end)

    {:ok, hash} = Credential.token_hash(token)
    %{hash: hash}
  end

  defp sealed(map, hash, job_id \\ "job-1", purpose \\ :secrets),
    do: %Secrets{
      job_id: "job-1",
      sealed: Credential.seal(Jason.encode!(map), hash, job_id, purpose)
    }

  test "an assignment carries them sealed, or not at all" do
    assert %Secrets{job_id: "j", sealed: "x"} =
             Secrets.from_assignment(%{"job_id" => "j", "secrets" => "x"})

    assert Secrets.from_assignment(%{"job_id" => "j"}) == nil
    assert Secrets.from_assignment(%{"job_id" => "j", "secrets" => nil}) == nil
  end

  test "they open only for this job, this purpose and this machine", %{hash: hash} do
    assert Secrets.open(sealed(%{"KEY_A" => "value-a1"}, hash)) == {:ok, %{"KEY_A" => "value-a1"}}
    assert Secrets.open(nil) == {:ok, %{}}

    assert Secrets.open(sealed(%{"KEY_A" => "value-a1"}, hash, "job-2")) == :error
    assert Secrets.open(sealed(%{"KEY_A" => "value-a1"}, hash, "job-1", :credential)) == :error
    assert Secrets.open(sealed(%{"KEY_A" => "value-a1"}, String.duplicate("0", 64))) == :error

    # Only a map of strings is a job's secrets.
    assert Secrets.open(sealed(%{"KEY_A" => 1}, hash)) == :error
    assert Secrets.open(sealed(["KEY_A"], hash)) == :error

    assert Secrets.check(sealed(%{"KEY_A" => "value-a1"}, hash)) == :ok
    assert Secrets.check(nil) == :ok
    assert Secrets.check(sealed(%{}, hash, "job-2")) == {:error, :secrets_unopened}
  end

  # A name the platform should never have sent is refused here too, and said; the rest are set.
  test "the environment holds every allowed name, as a secret, and no reserved one", %{hash: hash} do
    secrets =
      sealed(
        %{"STRIPE_TEST_KEY" => "sk_test_value", "ANTHROPIC_BASE_URL" => "https://evil"},
        hash
      )

    log =
      capture_log(fn ->
        assert Secrets.env(secrets) == [{"STRIPE_TEST_KEY", {:secret, "sk_test_value"}}]
      end)

    assert log =~ "ANTHROPIC_BASE_URL may not be a secret's name and was not set"
    refute log =~ "evil"

    # Nothing refused is nothing said.
    log =
      capture_log(fn ->
        assert Secrets.env(sealed(%{"STRIPE_TEST_KEY" => "sk_test_value"}, hash)) ==
                 [{"STRIPE_TEST_KEY", {:secret, "sk_test_value"}}]
      end)

    refute log =~ "may not be a secret's name"

    assert Secrets.env(nil) == []

    log = capture_log(fn -> assert Secrets.env(sealed(%{}, hash, "job-2")) == [] end)
    assert log =~ "the job's secrets would not open"
  end

  describe "masking" do
    test "the exact value and its JSON-escaped form, wherever a string holds them", %{hash: hash} do
      value = ~s(sk_"quoted"\\path\nline)
      secrets = sealed(%{"KEY_A" => value}, hash)
      line = Jason.encode!(%{"text" => "it is #{value} here"})

      assert Secrets.mask(secrets, "it is #{value} here") == "it is [secret KEY_A] here"
      assert Secrets.mask(secrets, line) == ~s({"text":"it is [secret KEY_A] here"})

      assert Secrets.mask(secrets, %{a: [value, %{"b" => "x #{value}"}], n: 1}) ==
               %{a: ["[secret KEY_A]", %{"b" => "x [secret KEY_A]"}], n: 1}
    end

    # The longer match is taken where two start at the same place, so a value containing another
    # is masked whole rather than leaving its tail.
    test "a value that contains another is masked whole", %{hash: hash} do
      secrets = sealed(%{"SHORT_KEY" => "abcdefgh", "LONG_KEY" => "abcdefgh-and-more"}, hash)

      assert Secrets.mask(secrets, "x abcdefgh-and-more y abcdefgh") ==
               "x [secret LONG_KEY] y [secret SHORT_KEY]"
    end

    # A control character is escaped upper case by Jason and lower case by the harness's own JSON
    # (Node's and Bun's), and a transcript line is the harness's.
    test "a control character's escape in either case", %{hash: hash} do
      secrets = sealed(%{"KEY_A" => "abc\edefgh"}, hash)

      assert Secrets.mask(secrets, ~S({"t":"abc\u001bdefgh"})) == ~S({"t":"[secret KEY_A]"})
      assert Secrets.mask(secrets, ~S({"t":"abc\u001Bdefgh"})) == ~S({"t":"[secret KEY_A]"})
    end

    # Two values that overlap without one holding the other: neither's tail is left in the clear.
    test "values that overlap are masked across the both of them", %{hash: hash} do
      secrets =
        sealed(%{"KEY_A" => "abcdefgh12", "KEY_B" => "gh12XYZW99", "KEY_C" => "same-value"}, hash)

      assert Secrets.mask(secrets, "<abcdefgh12XYZW99>") == "<[secret KEY_A][secret KEY_B]>"

      both = sealed(%{"KEY_A" => "same-value", "KEY_B" => "same-value"}, hash)
      assert Secrets.mask(both, "is same-value.") == "is [secret KEY_A][secret KEY_B]."
    end

    test "a map's keys and a tuple's elements too", %{hash: hash} do
      secrets = sealed(%{"KEY_A" => "value-a1"}, hash)

      assert Secrets.mask(secrets, %{"value-a1" => {"x value-a1", 1}}) ==
               %{"[secret KEY_A]" => {"x [secret KEY_A]", 1}}
    end

    test "a struct is left as it is, and nothing is masked without secrets", %{hash: hash} do
      secrets = sealed(%{"KEY_A" => "value-a1"}, hash)
      at = ~U[2026-10-09 10:00:00Z]

      assert Secrets.mask(secrets, at) == at
      assert Secrets.mask(nil, "value-a1") == "value-a1"
      assert Secrets.mask(sealed(%{}, hash), "value-a1") == "value-a1"

      assert Secrets.mask_event(secrets, %{type: "t", payload: %{text: "value-a1"}}) ==
               %{type: "t", payload: %{text: "[secret KEY_A]"}}
    end

    test "a file is masked in place, and one with nothing to mask is not rewritten", %{hash: hash} do
      secrets = sealed(%{"KEY_A" => "value-a1"}, hash)
      dir = Path.join(System.tmp_dir!(), "secrets-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      leaking = Path.join(dir, "transcript.jsonl")
      File.write!(leaking, ~s({"text":"value-a1"}\n))
      assert Secrets.mask_file(secrets, leaking) == :ok
      assert File.read!(leaking) == ~s({"text":"[secret KEY_A]"}\n)

      clean = Path.join(dir, "clean.txt")
      File.write!(clean, "nothing\n")
      File.touch!(clean, 0)
      assert Secrets.mask_file(secrets, clean) == :ok
      assert File.stat!(clean, time: :posix).mtime == 0

      assert Secrets.mask_file(secrets, Path.join(dir, "absent")) == :ok
      assert Secrets.mask_file(secrets, nil) == :ok
      assert Secrets.mask_file(nil, leaking) == :ok
    end
  end
end
