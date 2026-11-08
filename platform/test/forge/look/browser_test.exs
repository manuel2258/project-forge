defmodule Forge.Look.BrowserTest do
  # The one place the gate drives a real Chromium (`docs/design/look.md` § What a look costs). It goes
  # through the code `bin/look` runs, over the shipped setup, so a broken browser setup fails here
  # and not on the next UI ticket. Needs `FORGE_CHROMIUM` and `FORGE_CHROMEDRIVER`, which the
  # devshell sets; without them it fails and says so, rather than skipping.
  use Forge.DataCase, async: false

  import ExUnit.CaptureIO

  @moduletag :browser
  @moduletag timeout: 120_000

  alias Forge.Look
  alias Forge.Look.{Guard, Setups, Steps}

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>
  # `localhost`, because the test endpoint's configured host is and LiveView refuses a socket whose
  # origin is another.
  @base "http://localhost:4002"

  setup do
    token = Guard.generate()
    Guard.put_token(token)
    on_exit(fn -> Guard.put_token(nil) end)
    dir = Path.join(System.tmp_dir!(), "forge-look-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    built = Setups.Ticket.build()
    {login, _} = Forge.AccountsFixtures.generate_user_magic_link_token(built.users["member"])

    %{
      opts: [base_url: @base, token: token, login_token: login, paths: built.paths, wait: 1_500],
      dir: dir,
      user: built.users["member"]
    }
  end

  defp run(source, opts), do: Look.run(elem(Steps.parse(source), 1), opts)

  test "a logged-in page is shown, acted on, and photographed whole and by element", %{
    opts: opts,
    dir: dir
  } do
    page = Path.join(dir, "ticket-phone.png")
    part = Path.join(dir, "title-phone.png")

    output =
      capture_io(fn ->
        assert :ok ==
                 run(
                   """
                   width phone
                   visit :ticket
                   text h1
                   click text "Docs"
                   wait text "refinement.md"
                   wait text "Docs 1"
                   shot page #{page}
                   shot h1 #{part}
                   """,
                   opts
                 )
      end)

    assert output =~ "= Persist the high score table"
    assert output =~ "ok: 8 steps"
    # The browser's own console stays out of the line per step.
    refute output =~ "received diff"
    refute output =~ opts[:token]
    refute output =~ opts[:login_token]
    assert File.read!(page) |> binary_part(0, 8) == @png
    assert File.read!(part) |> binary_part(0, 8) == @png
    # The page is the whole page and the element only itself.
    assert File.stat!(page).size > File.stat!(part).size
  end

  test "a wait for what never appears fails its step with the reason", %{opts: opts} do
    output =
      capture_io(fn ->
        assert {:failed, 2, "wait .never-there", reason} =
                 run("visit :queue\nwait .never-there", opts)

        assert reason =~ "never-there"
      end)

    assert output =~ "FAILED step 2: wait .never-there"
  end

  test "a page that was not logged in to is not the one asked for", %{opts: opts} do
    # Without the guard's cookie the app answers 403 for every page: nothing of it is drawn.
    assert {:could_not_run, reason} = run("visit :queue", Keyword.put(opts, :token, "wrong"))
    assert reason =~ "could not log in"
    refute reason =~ "wrong\""
  end

  test "a page the server crashes on fails its step, naming what the platform reported", %{
    opts: opts
  } do
    # The table the page reads is gone for this test's transaction, which rolls the rename back:
    # the page cannot be drawn, and the browser alone would show an error page it cannot tell
    # from any other.
    Forge.Repo.query!("ALTER TABLE artifacts RENAME TO artifacts_gone")

    output =
      capture_io(fn ->
        assert {:failed, 2, "visit :ticket", reason} = run("width phone\nvisit :ticket", opts)
        assert reason =~ "the platform reported"
        assert reason =~ "500"
      end)

    assert output =~ "FAILED step 2: visit :ticket"
  end

  test "a reason that quotes the token or the login link is redacted", %{opts: opts} do
    # A library's error message quotes the selector it was given, so a step that happens to name
    # a secret would print it. The runner removes both before anything is printed or returned.
    output =
      capture_io(fn ->
        assert {:failed, 2, _text, reason} =
                 run(
                   "visit :queue\nwait \"[data-x='#{opts[:token]}#{opts[:login_token]}']\"",
                   opts
                 )

        assert reason =~ "[redacted]"
        refute reason =~ opts[:token]
        refute reason =~ opts[:login_token]
      end)

    refute output =~ opts[:token]
    refute output =~ opts[:login_token]
  end

  # Pages the app does not have, written under `priv/static/images/` for the length of a test and
  # served by the endpoint's `Plug.Static`, behind the guard like everything else: the failures a
  # look exists to find need a page that has them, and no page of the platform does.
  defp page!(name, html) do
    dir = Path.join(Application.app_dir(:forge, "priv/static/images"), "look-test")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), html)
    on_exit(fn -> File.rm_rf!(dir) end)
    "/images/look-test/" <> name
  end

  test "a page wider than a phone fails at phone width and is not asked at desktop width", %{
    opts: opts,
    user: user
  } do
    path = page!("wide.html", ~s|<div style="width:2000px">wide</div>|)

    capture_io(fn ->
      assert {:failed, 2, _, reason} = run("width phone\nvisit #{path}", opts)
      assert reason =~ "wider than the phone viewport"
      # The magic link is single-use, so a second run needs its own.
      {again, _} = Forge.AccountsFixtures.generate_user_magic_link_token(user)
      assert :ok == run("width desktop\nvisit #{path}", Keyword.put(opts, :login_token, again))
    end)
  end

  test "a script error in the page fails the step that loaded it", %{opts: opts} do
    path = page!("boom.html", ~s|<script>throw new Error("look-test-boom")</script>|)

    capture_io(fn ->
      assert {:failed, 1, _, reason} = run("visit #{path}", opts)
      assert reason =~ "look-test-boom"
    end)
  end

  test "a live view that never connects fails the visit", %{opts: opts} do
    path = page!("nolive.html", ~s|<div id="main" data-phx-main></div>|)

    capture_io(fn ->
      assert {:failed, 1, _, "LiveView did not connect"} = run("visit #{path}", opts)
    end)
  end

  test "a click on an outside link does not load it and fails the step that caused it", %{
    opts: opts
  } do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)
    path = page!("outside.html", ~s|<a href="http://127.0.0.1:#{port}/hit">outside</a>|)

    capture_io(fn ->
      assert {:failed, 2, ~s|click text "outside"|, reason} =
               run("visit #{path}\nclick text \"outside\"", opts)

      assert reason =~ "navigated outside the app"
    end)

    # Nothing connected: the proxy sent the request to a port nothing listens on.
    assert {:error, :timeout} = :gen_tcp.accept(listen, 300)
  end

  test "a page the platform cannot draw at login fails the run and is not could-not-run", %{
    opts: opts
  } do
    Forge.Repo.query!("ALTER TABLE users_tokens RENAME TO users_tokens_gone")

    output =
      capture_io(fn ->
        assert {:failed, 0, "log in", reason} = run("visit :queue", opts)
        assert reason =~ "the platform reported"
        # The reason quotes the path the browser was on, which holds the login link.
        assert reason =~ "[redacted]"
        refute reason =~ opts[:login_token]
        refute reason =~ opts[:token]
      end)

    assert output =~ "FAILED while logging in"
  end

  test "a login that fails does not print the link it used", %{opts: opts} do
    # An unconfirmed user's link shows a confirmation form and no login form, so the login fails
    # while the browser is still on a path that holds the link.
    {link, _} =
      Forge.AccountsFixtures.generate_user_magic_link_token(
        Forge.AccountsFixtures.unconfirmed_user_fixture()
      )

    assert {:could_not_run, reason} = run("visit :queue", Keyword.put(opts, :login_token, link))
    assert reason =~ "could not log in"
    assert reason =~ "/users/log-in/[redacted]"
    refute reason =~ link
  end

  test "a relative shot path is relative to where bin/look was run", %{opts: opts, dir: dir} do
    # The task itself runs in `platform/`, so `bin/look` says where it was called from.
    System.put_env("FORGE_LOOK_CALLER_DIR", dir)
    on_exit(fn -> System.delete_env("FORGE_LOOK_CALLER_DIR") end)

    capture_io(fn -> assert :ok == run("visit :queue\nshot page nested/queue.png", opts) end)

    assert File.read!(Path.join(dir, "nested/queue.png")) |> binary_part(0, 8) == @png
  end

  test "a script error on the login page fails the run and is not could-not-run", %{opts: opts} do
    # The login page is the first to load the app's script, so one that throws is a script error
    # on every page: the change's, and not the machine's. The built file is put back afterwards.
    script = Application.app_dir(:forge, "priv/static/assets/js/app.js")
    original = File.read!(script)
    on_exit(fn -> File.write!(script, original) end)
    File.write!(script, ~s|throw new Error("look-test-login-boom");|)

    output =
      capture_io(fn ->
        assert {:failed, 0, "log in", reason} = run("visit :queue", opts)
        assert reason =~ "look-test-login-boom"
        refute reason =~ opts[:login_token]
        refute reason =~ opts[:token]
      end)

    assert output =~ "FAILED while logging in"
    refute output =~ opts[:login_token]
  end
end
