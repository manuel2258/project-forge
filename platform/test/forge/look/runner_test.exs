defmodule Forge.Look.RunnerTest do
  # No browser here: what the runner decides before one exists, and its pure checks.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Forge.Look
  alias Forge.Look.Steps

  defp steps!(text) do
    {:ok, steps} = Steps.parse(text)
    steps
  end

  test "a named path the setup does not have fails its step before any browser starts" do
    output =
      capture_io(fn ->
        assert {:failed, 2, "visit :nope", reason} =
                 Look.run(steps!("width phone\nvisit :nope"),
                   base_url: "http://127.0.0.1:1",
                   token: "s3cret-token",
                   paths: %{"home" => "/"},
                   chromium: "/does/not/exist"
                 )

        assert reason =~ "no path named nope"
      end)

    assert output =~ "FAILED step 2: visit :nope"
    assert output =~ "no path named nope"
    refute output =~ "s3cret-token"
  end

  test "a named path that is not a path is refused as a typed one is" do
    assert {:failed, 1, "visit :x", reason} =
             Look.resolve(steps!("visit :x"), %{"x" => "http://evil.test/"}) |> elem_failed()

    assert reason =~ "path on the app"
  end

  defp elem_failed({:failed, _, _, _} = failed), do: failed

  test "a browser or driver that is missing is could-not-run, not a failed step" do
    steps = steps!("visit /")
    base = [base_url: "http://127.0.0.1:1", paths: %{}]

    assert {:could_not_run, reason} = Look.run(steps, [chromium: "/does/not/exist"] ++ base)
    assert reason =~ "no chromium"

    assert {:could_not_run, reason} =
             Look.run(
               steps,
               [chromium: System.find_executable("true"), chromedriver: "/does/not/exist"] ++ base
             )

    assert reason =~ "no chromedriver"
  end

  test "origin: only the app's scheme, host and port pass" do
    base = "http://127.0.0.1:4000"
    assert :ok == Look.origin("http://127.0.0.1:4000/tickets/x", base)

    assert {:error, "navigated outside the app: " <> _} =
             Look.origin("http://127.0.0.1:4001/", base)

    assert {:error, _} = Look.origin("http://localhost:4000/", base)
    assert {:error, _} = Look.origin("https://127.0.0.1:4000/", base)
    assert {:error, _} = Look.origin("chrome-error://chromewebdata/", base)
    assert {:error, _} = Look.origin("data:text/html,x", base)
  end

  test "a page is too wide only when it scrolls past the viewport" do
    refute Look.overflow?(390, 390)
    assert Look.overflow?(391, 390)
  end

  test "redaction removes every secret from a reason" do
    assert Look.redact("a=tok1 b=tok2 a=tok1", ["tok1", "tok2"]) ==
             "a=[redacted] b=[redacted] a=[redacted]"

    assert Look.redact("nothing here", []) == "nothing here"
  end
end
