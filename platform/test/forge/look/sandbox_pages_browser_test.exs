defmodule Forge.Look.SandboxPagesBrowserTest do
  # Criterion 30 of ticket 66 (`docs/design/pages.md` § What it does not defend): a page an agent
  # wrote runs sandboxed, and the only way to know is to load one whose script tries every way
  # out and see that each fails. Also criterion 39 (the bar is outside the frame), 31 (a nested
  # frame's message is not a frame's) and 23 (saves made while the socket is down arrive once,
  # in order, when it is back). The one place the platform's pages meet a real Chromium; it
  # drives the code `bin/look` runs, as `browser_test.exs` does, and needs `FORGE_CHROMIUM` and
  # `FORGE_CHROMEDRIVER` from the devshell.
  use Forge.DataCase, async: false

  import ExUnit.CaptureIO
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import ForgeWeb.PageDoorFixtures

  @moduletag :browser
  @moduletag timeout: 120_000

  # The page's own script and style are the built assets, an ignored directory: `mix check` builds
  # them first (`check.static`), and a run of this file alone has to as well.
  setup_all do
    unless File.exists?(Path.join(:code.priv_dir(:forge), "static/assets/js/app.js")) do
      Mix.Task.rerun("tailwind", ["forge"])
      Mix.Task.rerun("esbuild", ["forge"])
    end

    :ok
  end

  # The library goes into each fixture page's own markup. A look's guard (`Forge.Look.Guard`) wants
  # its cookie on every request, and a sandboxed document has none to send, so the page's own
  # document loads (a navigation carries it) and a script it asks for by address would be refused:
  # that is the harness, not the product, whose `/page-files` door serves `forge-page.js` with no
  # cookie at all (`page_file_controller_test.exs`).
  # Its own usage comment names a closing script tag, which would end an inline script early.
  @library "../../../priv/page/forge-page.js"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> String.replace("</script>", "<\\/script>")
  @external_resource Path.expand("../../../priv/page/forge-page.js", __DIR__)

  alias Forge.Look
  alias Forge.Look.{Guard, Steps}
  alias Forge.{Pages, Repo}

  # The page's every attempt, each caught, written into its own store as one JSON report when
  # they have all settled. An attempt that SUCCEEDS is recorded as `ESCAPED: …`, so a failing
  # test names the way out. The ones that cannot be seen from inside (a form submitted, the top
  # navigated, a nested frame's message) are left for the test to look at from outside: if the
  # form had been submitted this document would be gone and no report would ever be written.
  @hostile """
  <!doctype html>
  <meta charset="utf-8">
  <title>hostile</title>
  <body>
  <script>#{@library}</script>
  <script>
  (function () {
    forge.set("alive_at_load", "1")
    var report = {}
    var violations = []
    document.addEventListener("securitypolicyviolation", function (e) {
      violations.push(e.effectiveDirective + " " + e.blockedURI)
    })

    function sync(name, fn) {
      try { report[name] = "ESCAPED: " + String(fn()) } catch (e) { report[name] = "blocked" }
    }

    sync("cookie", function () { return document.cookie })
    sync("parent_document", function () { return parent.document.title })
    sync("top_location", function () { return top.location.href })
    sync("local_storage", function () { localStorage.setItem("x", "1"); return "set" })
    sync("window_open", function () {
      var w = window.open("/", "_blank")
      if (!w) throw new Error("no window")
      return "opened"
    })
    try { top.location = "/projects" } catch (e) {}
    try {
      var form = document.createElement("form")
      form.method = "post"
      form.action = "/users/log-out"
      form.target = "_top"
      document.body.appendChild(form)
      form.submit()
    } catch (e) {}

    // Another page, another ticket and the frame's own parent: a message names none of them.
    window.parent.postMessage(
      {forge: 1, id: 900, op: "set", key: "k", value: "v", page: "other", ticket: 1}, "*")

    var nested = document.createElement("iframe")
    nested.srcdoc = "<script>" +
      "top.postMessage({forge: 1, id: 7, op: 'set', key: 'nested', value: 'x'}, '*');" +
      "parent.parent.postMessage({forge: 1, id: 8, op: 'set', key: 'nested', value: 'x'}, '*')" +
      "<" + "/script>"
    document.body.appendChild(nested)

    function reach(url) {
      return fetch(url, {credentials: "include"}).then(function (r) {
        return r.text().then(function (t) { return "ESCAPED: " + r.status + " " + t.slice(0, 40) })
      }, function () { return "blocked" })
    }

    var image = new Promise(function (resolve) {
      var img = new Image()
      img.onload = function () { resolve("ESCAPED: loaded") }
      img.onerror = function () { resolve("blocked") }
      img.src = "http://outside.example.test/pixel.png"
      setTimeout(function () { resolve("blocked") }, 3000)
    })

    Promise.all([reach("/"), reach("/api/v1/me"), image]).then(function (done) {
      report.fetch_root = done[0]
      report.fetch_me = done[1]
      report.image = done[2]
      var seen = violations.some(function (v) { return v.indexOf("outside.example.test") >= 0 })
      report.image_violation = seen ? "blocked" : "NO VIOLATION: " + violations.join(", ")
      // Still here: the form was not submitted, the frame was not navigated away.
      report.alive = "blocked"
      return forge.set("report", JSON.stringify(report))
    })

    // The test asks for the one thing a script cannot report on itself: leaving for an address
    // outside forge, which replaces this document whether it is blocked or not.
    window.addEventListener("message", function (e) {
      if (e.source !== window.parent || !e.data || e.data.go !== "leave") return
      window.location.href = "http://outside.example.test/"
    })
  })()
  </script>
  """

  # Three saves on a command from outside, made while forge's socket is down: the library's
  # `set` is all it does, and it tells its parent when it has loaded so the test knows.
  @typer """
  <!doctype html>
  <meta charset="utf-8">
  <title>typer</title>
  <script>#{@library}</script>
  <script>
  (function () {
    var go = false
    window.addEventListener("message", function (e) {
      if (e.source !== window.parent || !e.data || e.data.go !== "type" || go) return
      go = true
      forge.set("k1", "a")
      forge.set("k2", "b")
      forge.set("k3", "c")
    })
    // Only once forge has answered: a call made before that waits for it (`forge-page.js`), and
    // the test drops the socket on this page's word that it is ready.
    var timer
    forge.ready.then(function () { timer = setInterval(function () {
      if (go) return clearInterval(timer)
      window.parent.postMessage({typer: "ready"}, "*")
    }, 100) })
  })()
  </script>
  """

  @expected ~w(
    cookie parent_document top_location local_storage window_open
    fetch_root fetch_me image image_violation alive
  )

  setup do
    token = Guard.generate()
    Guard.put_token(token)
    on_exit(fn -> Guard.put_token(nil) end)

    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-pages-browser-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      File.rm_rf!(dir)
    end)

    user = user_fixture()
    project = project_fixture() |> join!(user)
    ticket = ticket_fixture(%{project: project, number: 1})
    scope = {:ticket, ticket.id}

    {hostile, _} = published!(scope, "hostile", %{"index.html" => @hostile})
    {typer, _} = published!(scope, "typer", %{"index.html" => @typer})
    {other, _} = published!(scope, "other")
    {:ok, _} = Pages.put(other, "k", "orig", {:user, user.id})

    {login, _} = generate_user_magic_link_token(user)
    base = "/tickets/#{project.name}/#{ticket.number}/pages/"

    %{
      opts: [
        base_url: Forge.TestEndpoint.base_url("localhost"),
        token: token,
        login_token: login,
        paths: %{"hostile" => base <> "hostile", "typer" => base <> "typer"},
        wait: 5_000
      ],
      hostile: hostile,
      typer: typer,
      other: other,
      user: user
    }
  end

  # The steps, then `calls` as `{:call, fun}` steps between which the page is checked as usual.
  defp run_with(source, calls, opts) do
    {:ok, steps} = Steps.parse(source)
    n = length(steps)

    calls =
      calls
      |> Enum.with_index(n + 1)
      |> Enum.map(fn {fun, i} -> %{n: i, text: "call #{i}", op: {:call, fun}} end)

    Look.run(steps ++ calls, opts)
  end

  defp eventually(fun, what, left \\ 15_000) do
    cond do
      value = fun.() -> value
      left <= 0 -> flunk("never became true: " <> what)
      true -> Process.sleep(100) && eventually(fun, what, left - 100)
    end
  end

  defp script(session, source), do: Look.script(session, source)

  # What the outer page can see of its frame when a page says nothing: the frame's address, the
  # bar's state, and the library the frame is to load, fetched the way the frame fetches it.
  # The socket is closed the way a dropped connection closes it, which is what tells the page's hook
  # it is offline (`liveSocket.disconnect()` tears the handlers down first and tells nobody), and
  # kept from coming back until the test says so.
  @go_offline """
  window.__connect = liveSocket.socket.connect
  liveSocket.socket.connect = function () {}
  liveSocket.socket.conn.close()
  return true
  """

  @go_online """
  liveSocket.socket.connect = window.__connect
  liveSocket.socket.connect()
  return true
  """

  @diagnose """
  var f = document.getElementById('page-frame')
  var s = document.querySelector('[data-page-save]')
  var x = new XMLHttpRequest()
  x.open('GET', f.src.replace('index.html', 'forge-page.js'), false)
  x.send()
  var i = new XMLHttpRequest()
  i.open('GET', f.src, false)
  i.send()
  return JSON.stringify({src: f.src, sandbox: f.getAttribute('sandbox'),
    save: s && (s.dataset.state + ' ' + s.textContent),
    lib: [x.status, x.getResponseHeader('content-type'), x.responseText.slice(0, 50)],
    csp: x.getResponseHeader('content-security-policy'),
    index: [i.status, i.responseText.length, i.responseText.slice(0, 80)]})
  """

  test "a page that tries every way out of its sandbox gets none of them", ctx do
    %{opts: opts, hostile: hostile, other: other} = ctx

    capture_io(fn ->
      assert :ok ==
               run_with(
                 "width desktop\nvisit :hostile\nwait \"#page-save\"",
                 [
                   # Every attempt the page can see, as it reported them into its own store.
                   fn session ->
                     Process.sleep(9_000)
                     logs = script(session, @diagnose)

                     entry = Pages.entry(hostile, "report")

                     assert entry,
                            "no report; stored keys: " <>
                              inspect(Enum.map(Pages.entries(hostile), & &1.key)) <>
                              "; the outer page saw: " <> String.slice(logs, 0, 1500)

                     report = Jason.decode!(entry.value)

                     for name <- @expected do
                       assert report[name] == "blocked", "#{name}: #{inspect(report[name])}"
                     end
                   end,
                   # Nothing it sent named another page, and a frame inside it is not the frame.
                   fn _session ->
                     Process.sleep(1_000)
                     assert Pages.entry(hostile, "nested") == nil
                     assert Pages.entry(other, "k").value == "orig"
                     assert Enum.map(Pages.entries(other), & &1.key) == ["k"]
                   end,
                   # The forge bar is outside the frame and is still where it was; the top was
                   # not navigated by the page, nor was the document replaced by a form's answer.
                   fn session ->
                     assert script(session, "return location.pathname") =~ "/pages/hostile"
                     assert script(session, bar_outside_frame())
                   end,
                   # Leaving for an outside address is refused by forge's own policy: the outer
                   # document's `frame-src` (its `default-src 'self'`) reports the violation.
                   fn session ->
                     script(session, ask_to_leave())

                     eventually(
                       fn -> script(session, leave_refused()) end,
                       "the outer page's policy refusing the frame's navigation"
                     )

                     assert script(session, "return location.pathname") =~ "/pages/hostile"
                     assert script(session, "return !!document.getElementById('page-bar')")
                   end
                 ],
                 opts
               )
    end)
  end

  test "three saves made while the socket is down arrive once each when it is back", ctx do
    %{opts: opts, typer: typer} = ctx

    output =
      capture_io(fn ->
        assert :ok ==
                 run_with(
                   "width desktop\nvisit :typer\nwait \"#page-save\"",
                   [
                     fn session ->
                       script(session, listen_for_ready())

                       eventually(fn -> script(session, "return window.__ready") end, "the page")
                       assert script(session, @go_offline)

                       script(
                         session,
                         "document.getElementById('page-frame').contentWindow" <>
                           ".postMessage({go: 'type'}, '*'); return true"
                       )

                       Process.sleep(3_000)
                       text = script(session, save_text())
                       seen = script(session, "return JSON.stringify(window.__seen)")
                       up = script(session, "return String(liveSocket.socket.isConnected())")
                       report = script(session, "return String(window.__typer)")

                       assert text =~ "offline" and text =~ "3",
                              "the bar said #{inspect(text)}; the frame's messages: #{seen}; " <>
                                "socket connected: #{up}; the page's report of itself: #{report}"

                       # Held in the page, not sent: nothing is stored while the socket is down.
                       assert Pages.entries(typer) == []
                     end,
                     fn session ->
                       assert script(session, @go_online)

                       eventually(
                         fn -> length(Pages.entries(typer)) == 3 end,
                         "the three saves stored"
                       )

                       eventually(
                         fn -> script(session, save_text()) =~ "saved" end,
                         "the bar saying saved"
                       )

                       Process.sleep(1_000)
                     end
                   ],
                   opts
                 )
      end)

    refute output =~ "FAILED"

    # Once each: three keys, three counters, and the page took no more than three writes.
    entries = typer |> Pages.entries() |> Enum.sort_by(& &1.key)
    assert Enum.map(entries, &{&1.key, &1.value}) == [{"k1", "a"}, {"k2", "b"}, {"k3", "c"}]
    assert entries |> Enum.map(& &1.counter) |> Enum.sort() == [1, 2, 3]
    assert Repo.reload!(typer).seq == 3
  end

  # What the test runs in the forge page around the frame: it can post to the frame's window and
  # hear the frame's, whatever the frame's origin.
  defp bar_outside_frame do
    Enum.join(
      [
        "var bar = document.getElementById('page-bar');",
        "var frame = document.getElementById('page-frame');",
        "return !!bar && !frame.contains(bar) &&",
        "bar.getBoundingClientRect().bottom <= frame.getBoundingClientRect().top + 1"
      ],
      " "
    )
  end

  defp ask_to_leave do
    Enum.join(
      [
        "window.__violations = [];",
        "document.addEventListener('securitypolicyviolation', function (e) {",
        "window.__violations.push(e.effectiveDirective + ' ' + e.blockedURI) });",
        "document.getElementById('page-frame').contentWindow",
        ".postMessage({go: 'leave'}, '*'); return true"
      ],
      " "
    )
  end

  defp leave_refused do
    "return window.__violations.some(function (v) { " <>
      "return v.indexOf('outside.example.test') >= 0 })"
  end

  defp listen_for_ready do
    Enum.join(
      [
        "window.__ready = false; window.__seen = [];",
        "window.addEventListener('message', function (e) {",
        "if (e.data && e.data.typer === 'ready') {",
        "window.__ready = true; window.__typer = JSON.stringify(e.data) }",
        "else window.__seen.push(JSON.stringify(e.data).slice(0, 100) +",
        "(e.source === document.getElementById('page-frame').contentWindow)) });",
        "return true"
      ],
      " "
    )
  end

  defp save_text, do: "return document.getElementById('page-save').textContent"
end
