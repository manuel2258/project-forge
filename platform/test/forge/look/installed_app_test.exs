defmodule Forge.Look.InstalledAppTest do
  @moduledoc """
  What a phone's installed forge does, in a real Chromium (`docs/design/ui.md` § The installed
  app, `docs/design/look.md` § What a look cannot show, and the browser test does): the service
  worker's functions with fakes, a real service worker keeping the offline page and showing it when
  the server goes away, the badge, the tidying of notifications, the colour of the bar and the
  iPhone's message.

  **Not here, because only a phone has them:** an iPhone's `getNotifications` and `close`, whether
  iOS paints `theme-color` behind the status bar, installing and signing in from the home screen.
  The note's *Not verified here* lists them.
  """
  use Forge.DataCase, async: false

  import ExUnit.CaptureIO
  import Forge.Look.Device

  @moduletag :browser
  @moduletag timeout: 120_000

  alias Forge.Look
  alias Forge.Look.{Guard, Setups, Steps}

  setup do
    token = Guard.generate()
    Guard.put_token(token)
    on_exit(fn -> Guard.put_token(nil) end)
    on_exit(&remove_pages/0)

    built = Setups.Ticket.build()
    {login, _} = Forge.AccountsFixtures.generate_user_magic_link_token(built.users["member"])

    %{
      opts: [
        base_url: Forge.TestEndpoint.base_url("localhost"),
        token: token,
        login_token: login,
        paths: built.paths,
        wait: 1_500
      ],
      user: built.users["member"],
      ticket: Forge.Repo.one!(Ecto.Query.from(t in Forge.Tickets.Ticket, limit: 1))
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

  defp quiet(fun), do: capture_io(fun)

  defp visit(session, opts, path) do
    Wallaby.Browser.visit(session, opts[:base_url] <> path)

    until(
      session,
      "return !!document.querySelector('#frame, #offline, #sign-in')",
      "#{path} to draw"
    )
  end

  # The recorder is installed on every document before its own script runs, and keeps what it was
  # told in `sessionStorage`, which survives a navigation of the tab (a badge call is lost with its
  # page otherwise). Chromium has the Badging API on the desktop, so the real calls are replaced.
  @recorder """
  const record = (v) => {
    const log = JSON.parse(sessionStorage.getItem('__badge') || '[]');
    log.push(v);
    sessionStorage.setItem('__badge', JSON.stringify(log));
  };
  navigator.setAppBadge = (n) => { record(n); return Promise.resolve() };
  navigator.clearAppBadge = () => { record(0); return Promise.resolve() };
  """

  defp last_badge(session, want, what),
    do:
      until(
        session,
        "const l = JSON.parse(sessionStorage.getItem('__badge') || '[]'); return l.length > 0 && l[l.length - 1] === #{want}",
        what
      )

  defp stuck!(ticket) do
    Forge.Tickets.get!(ticket.id) |> Ecto.Changeset.change(status: :stuck) |> Forge.Repo.update!()
    Forge.Events.notify(ticket.id)
  end

  defp resolve!(ticket) do
    Forge.Tickets.get!(ticket.id)
    |> Ecto.Changeset.change(status: :active)
    |> Forge.Repo.update!()

    Forge.Events.notify(ticket.id)
  end

  # -- the worker's functions, called with fakes ------------------------------------------------

  # `/sw.js` loaded as a script into a page, which hands its functions to `self.forgeWorker`
  # instead of listening (it is not a worker). Each case builds a scope that records what the
  # function did to it.
  @fakes """
  const origin = location.origin;
  const mk = (opts = {}) => {
    const log = {badge: [], shown: [], closed: [], opened: [], fetched: [], calls: [], order: [],
                 added: [], deleted: [], matched: [], focused: []};
    const notes = (opts.notes || []).map((n) => ({...n, close() { log.closed.push(n.tag) }}));
    const key = (r) => (typeof r === 'string' ? r : r.url);
    const scope = {
      location: {origin},
      navigator: {
        setAppBadge: (n) => { log.badge.push(['set', n]); return Promise.resolve() },
        clearAppBadge: () => { log.badge.push(['clear']); return Promise.resolve() },
      },
      registration: {
        showNotification: (title, o) => {
          log.shown.push({title, ...o});
          // what is shown is among what is held, as on a phone: a tidy that runs after it sees it
          notes.push({tag: o.tag, data: o.data, close() { log.closed.push(o.tag) }});
          // a phone takes a moment to show it: whatever reads the list must have waited for this
          return new Promise((resolve) => setTimeout(() => { log.order.push('shown'); resolve() }, 10));
        },
        getNotifications: () => { log.order.push('listed'); return Promise.resolve(notes) },
        navigationPreload: {enable: () => { log.calls.push('preload'); return Promise.resolve() }},
      },
      fetch: (r) => {
        log.fetched.push(key(r));
        return opts.fetch ? opts.fetch(r) : Promise.reject(new TypeError('offline'));
      },
      clients: {
        matchAll: () => Promise.resolve((opts.clients || []).map((c) => ({...c, focus: () => { log.focused.push(c.url); return Promise.resolve() }}))),
        openWindow: (u) => { log.opened.push(u); return Promise.resolve() },
        claim: () => { log.calls.push('claim'); return Promise.resolve() },
      },
      skipWaiting: () => { log.calls.push('skip') },
      caches: {
        open: (name) => Promise.resolve({addAll: (list) => { log.added.push([name, list]); return Promise.resolve() }}),
        keys: () => Promise.resolve(opts.cacheNames || []),
        delete: (name) => { log.deleted.push(name); return Promise.resolve(true) },
        match: (r, o) => { log.matched.push([key(r), o && o.cacheName]); return Promise.resolve(opts.cached ? opts.cached(r) : undefined) },
      },
    };
    return {scope, log};
  };
  const event = (extra = {}) => { const waits = []; return {waits, waitUntil: (p) => waits.push(p), ...extra} };
  const state = (body, status = 200) => () => Promise.resolve(new Response(typeof body === 'string' ? body : JSON.stringify(body), {status}));
  const push = (payload) => ({json: () => payload});
  const W = self.forgeWorker;
  const results = {};
  """

  @received """
  {
    const {scope, log} = mk({fetch: state({count: 3, tags: ['a']})});
    const e = event({data: push({title: 'T', body: 'B', url: '/tickets/p/1', tag: 'stuck-1', item: true, badge: 5})});
    W.received(scope, e); await Promise.all(e.waits);
    results.received = {shown: log.shown, badge: log.badge, fetched: log.fetched, closed: log.closed, order: log.order};
  }
  {
    // the read fails: the notification is shown and the payload's own figure is the badge
    const {scope, log} = mk();
    const e = event({data: push({title: 'T', tag: 'stuck-1', item: true, badge: 5})});
    W.received(scope, e); await Promise.all(e.waits);
    results.read_fails = {shown: log.shown.length, badge: log.badge, closed: log.closed};
  }
  {
    // a figure of zero clears; the digest is not an item; a payload that cannot be read still shows
    const {scope, log} = mk({fetch: state('', 401)});
    const e = event({data: push({title: 'D', tag: 'digest', badge: 0})});
    W.received(scope, e); await Promise.all(e.waits);
    const bad = mk(); const e2 = event({data: {json: () => { throw new Error('x') }}});
    W.received(bad.scope, e2); await Promise.all(e2.waits);
    results.zero = {shown: log.shown, badge: log.badge, bare: bad.log.shown};
  }
  {
    // a push closes stale items on the way in, but never the one it has just shown
    const {scope, log} = mk({
      notes: [{tag: 'stuck-gone', data: {item: true, shown: Date.now() - 60000}}],
      fetch: state({count: 0, tags: []}),
    });
    const e = event({data: push({title: 'T', tag: 'stuck-gone-2', item: true, badge: 1})});
    W.received(scope, e); await Promise.all(e.waits);
    results.on_push = {closed: log.closed};
  }
  """

  @tidy """
  {
    const now = Date.now();
    const notes = [
      {tag: 'stale', data: {item: true, shown: now - 5000}},
      {tag: 'waiting', data: {item: true, shown: now - 5000}},
      {tag: 'digest', data: {url: '/', shown: now - 5000}},
      {tag: 'unmarked', data: {url: '/'}},
      {tag: 'bare'},
      {tag: 'fresh', data: {item: true, shown: now + 5000}},
    ];
    const {scope, log} = mk({notes, fetch: state({count: 7, tags: ['waiting']})});
    await W.tidy(scope, now);
    results.tidy = {closed: log.closed, badge: log.badge, fetched: log.fetched};

    for (const [name, fetch] of [['refused', state('', 401)], ['refused_json', state({count: 5, tags: []}, 401)], ['broken', state('{nope')], ['down', undefined],
                                 ['shape', state({count: 1})]]) {
      const m = mk({notes, fetch});
      await W.tidy(m.scope, now);
      results['tidy_' + name] = {closed: m.log.closed, badge: m.log.badge};
    }

    // a message asks for one; any other does not
    const asked = mk({notes, fetch: state({count: 1, tags: []})});
    const e1 = event({data: {type: 'tidy'}}); W.asked(asked.scope, e1); await Promise.all(e1.waits);
    const none = mk({notes, fetch: state({count: 1, tags: []})});
    const e2 = event({data: {type: 'other'}}); W.asked(none.scope, e2); await Promise.all(e2.waits);
    results.asked = {closed: asked.log.closed.length, other: none.log.fetched.length};

    // the badge: a number, drawn as it is; nothing else is
    const b = mk();
    for (const v of [4, 0, 1234567890, '5', NaN, -1, null, undefined]) await W.badge(b.scope, v);
    results.badge = b.log.badge;
  }
  """

  @opened """
  {
    const urls = ['/tickets/p/1?x=1#y', origin + '/chats/c', 'https://evil.example/x', '//evil.example/x',
                  'javascript:alert(1)', 'http://localhost.evil.example/', origin + '.evil.example/', '', undefined, 'http://[::1'];
    results.opened = [];
    for (const url of urls) {
      const {scope, log} = mk();
      let closed = false;
      const e = event({notification: {data: url === undefined ? undefined : {url}, close: () => { closed = true }}});
      W.opened(scope, e); await Promise.all(e.waits);
      results.opened.push({url: String(url), opened: log.opened, closed});
    }
    // a window already on the page is focused and nothing is opened
    const {scope, log} = mk({clients: [{url: origin + '/chats/c'}]});
    const e = event({notification: {data: {url: '/chats/c'}, close() {}}});
    W.opened(scope, e); await Promise.all(e.waits);
    results.focus = {opened: log.opened, focused: log.focused};
  }
  """

  @pages """
  {
    const offline = () => new Response('OFFLINE');
    const run = async (request, opts = {}) => {
      const {scope, log} = mk({cached: offline, ...opts});
      let responded = null;
      const e = {request, preloadResponse: Promise.resolve(opts.preload), respondWith: (p) => { responded = p }};
      W.page(scope, e);
      const res = responded ? await responded : null;
      return {responded: !!responded, status: res && res.status, text: res && await res.text(), fetched: log.fetched, matched: log.matched};
    };
    const nav = (url = origin + '/projects', method = 'GET') => ({method, url, mode: 'navigate'});
    const answer = (status, text = 'page') => () => Promise.resolve(new Response(text, {status}));

    results.pass = {};
    for (const status of [200, 404, 500, 401]) results.pass[status] = await run(nav(), {fetch: answer(status)});
    results.gateway = {};
    for (const status of [502, 503, 504]) results.gateway[status] = await run(nav(), {fetch: answer(status)});
    results.nothing_kept = await run(nav(), {fetch: answer(502, 'proxy'), cached: () => undefined});
    results.offline = await run(nav());
    results.preloaded = await run(nav(), {preload: new Response('pre'), fetch: answer(200, 'late')});
    results.preload_fails = await run(nav(), {preload: undefined});

    // nothing but a GET page load, and the exact precached files, is answered
    results.post = await run(nav(origin + '/users/log-in', 'POST'));
    results.put = await run({method: 'PUT', url: origin + '/x', mode: 'cors'});
    results.live = await run({method: 'GET', url: origin + '/live/longpoll', mode: 'cors'}, {fetch: answer(200)});
    results.api = await run({method: 'GET', url: origin + '/api/v1/me', mode: 'cors'}, {fetch: answer(200)});
    results.file = await run({method: 'GET', url: origin + '/tickets/p/1/artifacts/a/1', mode: 'same-origin'}, {fetch: answer(200)});
    results.elsewhere = await run({method: 'GET', url: 'https://other.example/', mode: 'navigate'}, {fetch: answer(200)});
    results.image = await run({method: 'GET', url: origin + '/images/icon-192.png', mode: 'no-cors'}, {fetch: answer(200)});

    const css = FORGE.precache[1];
    results.precache_net = await run({method: 'GET', url: origin + css, mode: 'no-cors'}, {fetch: answer(200, 'net'), cached: () => new Response('CACHED')});
    results.precache_cache = await run({method: 'GET', url: origin + css, mode: 'no-cors'}, {cached: () => new Response('CACHED')});
    results.precache_gone = await run({method: 'GET', url: origin + css, mode: 'no-cors'}, {cached: () => undefined}).catch((e) => ({threw: true}));
  }
  """

  @lifecycle """
  {
    const names = ['forge-offline-old', 'forge-offline-' + FORGE.version, 'forge-offline-older', 'workbox-other', 'app'];
    const i = mk({cacheNames: names}); const e1 = event();
    W.install(i.scope, e1); await Promise.all(e1.waits);
    results.install = {calls: i.log.calls, added: i.log.added, deleted: i.log.deleted};
    const a = mk({cacheNames: names}); const e2 = event();
    W.activate(a.scope, e2); await Promise.all(e2.waits);
    results.activate = {calls: a.log.calls, deleted: a.log.deleted};
  }
  """

  test "the worker's functions do what the note says, called with fakes", %{opts: opts} do
    path =
      page!(
        "sw.html",
        ~s|<!doctype html><html><body><script src="/sw.js"></script></body></html>|
      )

    script =
      "const FORGE_RESULTS = (async () => { #{@fakes} #{@received} #{@tidy} #{@opened} #{@pages} #{@lifecycle} return results })(); " <>
        "return FORGE_RESULTS"

    quiet(fn ->
      assert :ok ==
               run_with(
                 "visit #{path}",
                 [
                   fn session ->
                     r = async(session, script)
                     assert is_map(r), inspect(r)
                     results = r

                     version = Look.script(session, "return FORGE.version")
                     precache = Look.script(session, "return FORGE.precache")
                     cache = "forge-offline-" <> version

                     # -- a push shows first, sets the badge, and tidies on the way in
                     assert %{
                              "shown" => [shown],
                              "badge" => badge,
                              "fetched" => ["/push/waiting"]
                            } =
                              results["received"]

                     assert %{
                              "title" => "T",
                              "body" => "B",
                              "tag" => "stuck-1",
                              "renotify" => true
                            } = shown

                     assert %{"url" => "/tickets/p/1", "item" => true, "shown" => at} =
                              shown["data"]

                     assert is_number(at)
                     # the payload's figure first, then the read's own
                     assert badge == [["set", 5], ["set", 3]]

                     # It tidies only once the notification is shown: the read of the list is after it.
                     assert results["received"]["order"] == ["shown", "listed"]

                     assert %{"shown" => 1, "badge" => [["set", 5]], "closed" => []} =
                              results["read_fails"]

                     assert %{"badge" => [["clear"]], "shown" => [digest], "bare" => [bare]} =
                              results["zero"]

                     assert digest["data"]["item"] == false
                     assert bare["title"] == "forge"

                     assert bare["data"] == %{
                              "url" => "/",
                              "item" => false,
                              "shown" => bare["data"]["shown"]
                            }

                     assert results["on_push"] == %{"closed" => ["stuck-gone"]}

                     # -- tidying closes stale items, and only those
                     assert %{"closed" => ["stale"], "badge" => [["set", 7]]} = results["tidy"]
                     assert results["tidy_refused"] == %{"closed" => [], "badge" => []}
                     assert results["tidy_refused_json"] == %{"closed" => [], "badge" => []}
                     assert results["tidy_broken"] == %{"closed" => [], "badge" => []}
                     assert results["tidy_down"] == %{"closed" => [], "badge" => []}
                     assert results["tidy_shape"] == %{"closed" => [], "badge" => []}

                     # an empty list makes both marked notifications of the two shown before it stale
                     assert results["asked"] == %{"closed" => 2, "other" => 0}

                     # -- the badge is a number as it is, and zero clears; nothing else is drawn
                     assert results["badge"] == [["set", 4], ["clear"], ["set", 1_234_567_890]]

                     # -- a tap opens forge's own pages, and the queue for anything else
                     home = Look.script(session, "return location.origin") <> "/"
                     opened = Map.new(results["opened"], &{&1["url"], &1})
                     origin = String.trim_trailing(home, "/")

                     assert opened["/tickets/p/1?x=1#y"]["opened"] == [
                              origin <> "/tickets/p/1?x=1#y"
                            ]

                     assert opened[origin <> "/chats/c"]["opened"] == [origin <> "/chats/c"]

                     for hostile <- [
                           "https://evil.example/x",
                           "//evil.example/x",
                           "javascript:alert(1)",
                           "http://localhost.evil.example/",
                           origin <> ".evil.example/",
                           "http://[::1"
                         ] do
                       assert opened[hostile]["opened"] == [home], hostile
                     end

                     assert opened[""]["opened"] == [home]
                     assert opened["undefined"]["opened"] == [home]
                     assert Enum.all?(results["opened"], & &1["closed"])

                     assert results["focus"] == %{
                              "opened" => [],
                              "focused" => [origin <> "/chats/c"]
                            }

                     # -- a failed page load is the offline page; everything else is left alone
                     for status <- ~w(200 404 500 401) do
                       assert %{"responded" => true, "status" => s, "text" => "page"} =
                                results["pass"][status]

                       assert s == String.to_integer(status)
                     end

                     for status <- ~w(502 503 504) do
                       assert %{"responded" => true, "text" => "OFFLINE", "fetched" => [_]} =
                                results["gateway"][status]
                     end

                     assert %{"text" => "OFFLINE", "matched" => [["/offline", ^cache]]} =
                              results["offline"]

                     # nothing kept: the proxy's own answer, not an error page of the browser's
                     assert %{"status" => 502, "text" => "proxy"} = results["nothing_kept"]
                     assert %{"text" => "pre", "fetched" => []} = results["preloaded"]
                     assert %{"text" => "OFFLINE"} = results["preload_fails"]

                     for name <- ~w(post put live api file elsewhere image) do
                       assert %{"responded" => false, "fetched" => []} = results[name], name
                     end

                     assert %{"text" => "net", "matched" => []} = results["precache_net"]

                     assert %{"text" => "CACHED", "matched" => [[css, ^cache]]} =
                              results["precache_cache"]

                     assert css =~ Enum.at(precache, 1)

                     assert results["precache_gone"]["threw"] == true or
                              results["precache_gone"]["responded"] == true

                     # -- a new release's worker takes over, and sweeps only older forge caches
                     assert %{
                              "calls" => ["skip"],
                              "added" => [[^cache, ^precache]],
                              "deleted" => []
                            } =
                              results["install"]

                     assert %{"calls" => ["preload", "claim"], "deleted" => deleted} =
                              results["activate"]

                     assert Enum.sort(deleted) == ["forge-offline-old", "forge-offline-older"]
                   end
                 ],
                 opts
               )
    end)
  end

  # -- a real service worker ---------------------------------------------------------------------

  @precached "const out = []; for (const k of await caches.keys()) { const c = await caches.open(k); " <>
               "for (const r of await c.keys()) out.push([k, new URL(r.url).pathname]) } return out.sort()"

  defp precached(session), do: async(session, @precached)

  defp on_offline_page(session, what) do
    until(
      session,
      "return !!document.querySelector('#offline') && !document.querySelector('#frame')",
      what
    )
  end

  defp holding(fun) do
    {:ok, holder} = Agent.start_link(fn -> nil end)

    try do
      fun.(holder)
    after
      pid = Agent.get(holder, & &1)
      if pid && Process.alive?(pid), do: stop(pid)
    end
  end

  test "a real worker takes over the first page, keeps only the offline page, and shows it", %{
    opts: opts
  } do
    holding(fn holder ->
      {listener, port, _down} = listen()
      Agent.update(holder, fn _ -> listener end)
      opts = Keyword.put(opts, :base_url, "http://localhost:#{port}")

      precache = ForgeWeb.DeviceController.precache()
      version = Forge.Changelog.running()
      kept = for path <- precache, do: ["forge-offline-" <> version, path]

      quiet(fn ->
        assert :ok ==
                 run_with(
                   "width phone\nvisit :queue\nwait \"#frame\"",
                   [
                     fn session ->
                       # It controls the page that registered it, with no reload in between, and has
                       # kept exactly what the page needs to draw itself offline.
                       until(
                         session,
                         "return !!navigator.serviceWorker.controller",
                         "the worker to take over the first page"
                       )

                       assert Look.script(
                                session,
                                "return navigator.serviceWorker.controller.scriptURL"
                              ) ==
                                opts[:base_url] <> "/sw.js"

                       until(
                         session,
                         "return !!navigator.serviceWorker.controller",
                         "a controller"
                       )

                       assert Enum.sort(precached(session)) == Enum.sort(kept)

                       # A release's worker is found by asking for its script every time.
                       assert async(
                                session,
                                "return (await navigator.serviceWorker.getRegistration()).updateViaCache"
                              ) == "none"

                       # The person's own theme is the offline page's.
                       Look.script(
                         session,
                         "localStorage.setItem('phx:theme', 'light'); return 1"
                       )

                       # -- the network goes away: a page load shows forge's own page
                       stop(listener)
                       Wallaby.Browser.visit(session, opts[:base_url] <> "/projects")
                       on_offline_page(session, "the offline page for a load that failed")

                       assert Look.script(session, "return location.pathname") == "/projects"

                       assert Look.script(session, "return document.title") ==
                                "forge can't be reached · forge"

                       text = Look.script(session, "return document.body.innerText")
                       assert text =~ "forge can't be reached"

                       assert text =~
                                "This device is offline, or the server isn't answering. The page will load as soon as it can."

                       assert text =~ "Try again"

                       assert Look.script(
                                session,
                                "return document.documentElement.dataset.theme"
                              ) == "light"

                       assert Look.script(
                                session,
                                "return document.querySelector('meta[name=theme-color]').content"
                              ) == ForgeWeb.Layouts.bar_colors().light

                       # no frame, queue or usage lines; laid out for the phone
                       assert Look.script(
                                session,
                                "return document.querySelectorAll('#top-bar, #usage-5h, #usage-week, .frame-queue, form').length"
                              ) == 0

                       assert Look.script(
                                session,
                                "return document.documentElement.scrollWidth <= document.documentElement.clientWidth"
                              )

                       # Try again with no way back stays where it is, and submits nothing
                       Wallaby.Browser.click(session, Wallaby.Query.css("#try-again"))
                       Process.sleep(500)
                       on_offline_page(session, "the offline page again while still offline")

                       # -- back: Try again reloads the page that was asked for
                       {listener, ^port, _} = listen(port)
                       Agent.update(holder, fn _ -> listener end)
                       Wallaby.Browser.click(session, Wallaby.Query.css("#try-again"))

                       until(
                         session,
                         "return !!document.querySelector('#frame')",
                         "the page asked for"
                       )

                       assert Look.script(session, "return location.pathname") == "/projects"

                       # -- the same, with no tap: coming back online reloads it
                       stop(listener)
                       Wallaby.Browser.visit(session, opts[:base_url] <> "/chats")
                       on_offline_page(session, "the offline page for /chats")
                       {listener, ^port, down} = listen(port)
                       Agent.update(holder, fn _ -> listener end)
                       Look.script(session, "window.dispatchEvent(new Event('online')); return 1")

                       until(
                         session,
                         "return !!document.querySelector('#frame')",
                         "the page asked for, unprompted"
                       )

                       assert Look.script(session, "return location.pathname") == "/chats"

                       # -- a proxy that cannot reach the platform answers 502: the same page
                       gateway_down(down, true)
                       Wallaby.Browser.visit(session, opts[:base_url] <> "/projects")
                       on_offline_page(session, "the offline page for a 502")
                       gateway_down(down, false)
                       Wallaby.Browser.click(session, Wallaby.Query.css("#try-again"))

                       until(
                         session,
                         "return !!document.querySelector('#frame')",
                         "the page after the 502"
                       )

                       # Everything browsed since was left to the network: still only the precache.
                       assert Enum.sort(precached(session)) == Enum.sort(kept)
                     end
                   ],
                   opts
                 )
      end)
    end)
  end

  # -- the badge, the tidying and the bar ---------------------------------------------------------

  defp tags(session),
    do:
      async(
        session,
        "const r = await navigator.serviceWorker.ready; return (await r.getNotifications()).map((n) => n.tag).sort()"
      )

  test "the badge follows the queue, notifications are tidied on opening, and signing out clears",
       %{opts: opts, ticket: ticket} do
    quiet(fn ->
      assert :ok ==
               run_with(
                 "width phone",
                 [
                   fn session ->
                     origin = opts[:base_url]
                     grant_notifications(session, origin)
                     cdp(session, "Page.addScriptToEvaluateOnNewDocument", %{source: @recorder})

                     visit(session, opts, "/")
                     until(session, "return !!navigator.serviceWorker.controller", "a worker")

                     # On load the badge is the queue button's figure: nothing waits.
                     last_badge(session, 0, "a cleared badge on load")

                     assert Look.script(
                              session,
                              "return document.querySelector('#device').dataset.count"
                            ) == "0"

                     # An item that starts waiting moves it while forge is open.
                     stuck!(ticket)

                     until(
                       session,
                       "return document.querySelector('#device').dataset.count === '1'",
                       "the count to follow"
                     )

                     last_badge(session, 1, "the badge to follow the queue")

                     # -- tidying: one notification still waiting, one stale, the digest, one the
                     # old worker showed (no mark), and one shown after the read would begin.
                     waiting = "stuck-" <> ticket.id

                     async(session, """
                     const r = await navigator.serviceWorker.ready;
                     const old = Date.now() - 60000;
                     await r.showNotification('w', {tag: '#{waiting}', data: {item: true, shown: old}});
                     await r.showNotification('s', {tag: 'question-gone', data: {item: true, shown: old}});
                     await r.showNotification('d', {tag: 'digest', data: {url: '/', item: false, shown: old}});
                     await r.showNotification('u', {tag: 'unmarked', data: {url: '/'}});
                     await r.showNotification('f', {tag: 'fresh', data: {item: true, shown: Date.now() + 600000}});
                     return 1
                     """)

                     # Opening forge tidies: the stale one goes and nothing else does. (The count
                     # moving asked as well, which is why this says only where it ends.)
                     visit(session, opts, "/")

                     until_tags(session, ["digest", "fresh", "stuck-" <> ticket.id, "unmarked"])

                     # Now nothing is pending and the count does not move: another stale one is
                     # closed by opening forge and by nothing else. The asks of the page above are
                     # let finish first: one is debounced 300 ms after it mounts, and a tidy still
                     # on its way would read the list after this one is shown and close it; what
                     # gets past that is shown again by `show_stale!/2`.
                     settle()
                     show_stale!(session, "approval-gone")
                     visit(session, opts, "/")
                     until_tags(session, ["digest", "fresh", "stuck-" <> ticket.id, "unmarked"])

                     # Answered elsewhere while forge is open: the count falls to zero, the badge is
                     # cleared, and the notification about it goes — with no reload, so it is the
                     # count moving that asked. A stale one shown meanwhile goes with it.
                     async(session, """
                     const r = await navigator.serviceWorker.ready;
                     await r.showNotification('s', {tag: 'stuck-answered', data: {item: true, shown: Date.now() - 60000}});
                     return 1
                     """)

                     resolve!(ticket)
                     last_badge(session, 0, "a cleared badge at zero")
                     until_tags(session, ["digest", "fresh", "unmarked"])

                     assert Look.script(
                              session,
                              "return document.querySelector('#device').dataset.count"
                            ) == "0"

                     # -- signing out clears it, and what the device holds is nothing of the person's
                     stuck!(ticket)
                     last_badge(session, 1, "the badge back at one")
                     visit(session, opts, "/users/settings")
                     Wallaby.Browser.click(session, Wallaby.Query.css("#you-sign-out"))

                     until(
                       session,
                       "return location.pathname === '/users/log-in' && !!document.querySelector('#sign-in')",
                       "the sign-in page"
                     )

                     last_badge(session, 0, "a cleared badge on signing out")

                     assert async(session, "return (await fetch('/push/waiting')).status") == 401

                     assert Enum.all?(precached(session), fn [_, path] ->
                              path in ForgeWeb.DeviceController.precache()
                            end)
                   end
                 ],
                 opts
               )
    end)
  end

  # Shows a stale item notification and returns once it is held. The failure that made this: the
  # assertion that it was held failed once in a gate run, on code that had passed the run before.
  # The likely cause, not reproduced: the page's last ask to tidy (the load's, or the count moving)
  # was still in flight, and it closed this notification as well, since it reads the queue before
  # it closes anything. Such an ask is answered once, so showing it again is not met by it, and what
  # the test goes on to assert (opening forge closes it) is unchanged. Four showings are a bound: a
  # notification closed four times running is something closing it, and the test says so.
  defp show_stale!(session, tag, left \\ 4) do
    async(session, """
    const r = await navigator.serviceWorker.ready;
    await r.showNotification('s', {tag: '#{tag}', data: {item: true, shown: Date.now() - 60000}});
    return 1
    """)

    cond do
      tag in tags(session) -> :ok
      left > 1 -> show_stale!(session, tag, left - 1)
      true -> flunk("#{tag} was closed each of four times it was shown")
    end
  end

  defp until_tags(session, want) do
    deadline = System.monotonic_time(:millisecond) + 8_000
    do_until_tags(session, want, deadline)
  end

  defp do_until_tags(session, want, deadline) do
    cond do
      tags(session) == want ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("notifications are #{inspect(tags(session))}, not #{inspect(want)}")

      true ->
        Process.sleep(100) && do_until_tags(session, want, deadline)
    end
  end

  # The page only asks; what it asks and when is the `.Device` hook's. Each ask is a message to the
  # worker, recorded on its way (`ServiceWorker.postMessage`), and kept in `sessionStorage` so that a
  # full load does not lose it.
  @asks """
  const post = ServiceWorker.prototype.postMessage;
  ServiceWorker.prototype.postMessage = function (message, ...rest) {
    const log = JSON.parse(sessionStorage.getItem('__posts') || '[]');
    log.push(message && message.type);
    sessionStorage.setItem('__posts', JSON.stringify(log));
    return post.call(this, message, ...rest);
  };
  if (sessionStorage.getItem('__hidden')) {
    Object.defineProperty(document, 'visibilityState', {get: () => 'hidden', configurable: true});
  }
  """

  defp posts(session),
    do:
      Look.script(session, "return JSON.parse(sessionStorage.getItem('__posts') || '[]').length")

  defp until_posts(session, n),
    do:
      until(
        session,
        "return JSON.parse(sessionStorage.getItem('__posts') || '[]').length === #{n}",
        "#{n} asks"
      )

  # The debounce is 300 ms, so what must not have been asked is looked for after a longer wait.
  defp settle, do: Process.sleep(700)

  defp badge_calls(session),
    do:
      Look.script(session, "return JSON.parse(sessionStorage.getItem('__badge') || '[]').length")

  defp visibility(session, state),
    do:
      Look.script(
        session,
        "Object.defineProperty(document, 'visibilityState', {get: () => '#{state}', configurable: true}); " <>
          "document.dispatchEvent(new Event('visibilitychange')); return 1"
      )

  test "the page asks for a tidy once per load, on coming into view, and when the count moves", %{
    opts: opts,
    ticket: ticket
  } do
    quiet(fn ->
      assert :ok ==
               run_with(
                 "width phone",
                 [
                   fn session ->
                     cdp(session, "Page.addScriptToEvaluateOnNewDocument", %{
                       source: @recorder <> @asks
                     })

                     # -- opening forge asks, once
                     visit(session, opts, "/")
                     until(session, "return !!navigator.serviceWorker.controller", "a worker")
                     until_posts(session, 1)

                     # A live navigation mounts the hook again and asks for nothing: it is the same
                     # opening. The badge call is what says the new page's hook has run.
                     before = badge_calls(session)

                     Look.script(
                       session,
                       ~s|liveSocket.execJS(document.getElementById("frame"), '[["navigate",{"href":"/projects","replace":false}]]'); return 1|
                     )

                     until(
                       session,
                       "return location.pathname === '/projects'",
                       "the live navigation"
                     )

                     until(
                       session,
                       "return JSON.parse(sessionStorage.getItem('__badge') || '[]').length > #{before}",
                       "the new page's hook"
                     )

                     settle()
                     assert posts(session) == 1

                     # -- coming back into view asks; going out of view does not
                     visibility(session, "hidden")
                     settle()
                     assert posts(session) == 1

                     visibility(session, "visible")
                     until_posts(session, 2)

                     # Two in a row are one ask.
                     visibility(session, "hidden")
                     visibility(session, "visible")
                     visibility(session, "visible")
                     until_posts(session, 3)
                     settle()
                     assert posts(session) == 3

                     # -- the count moving asks, while the page is in view
                     stuck!(ticket)

                     until(
                       session,
                       "return document.querySelector('#device').dataset.count === '1'",
                       "the count"
                     )

                     until_posts(session, 4)

                     # A patch that leaves the count alone asks for nothing: the element is touched
                     # (so LiveView patches it back) and the title menu re-renders the frame.
                     Look.script(
                       session,
                       "document.querySelector('#device').dataset.touched = '1'; return 1"
                     )

                     Wallaby.Browser.click(
                       session,
                       Wallaby.Query.css("#top-bar button.ui-top-title")
                     )

                     until(
                       session,
                       "return !document.querySelector('#device').dataset.touched",
                       "the element patched back"
                     )

                     settle()
                     assert posts(session) == 4

                     # -- and none of it while the page is out of view: not on loading, not on the count
                     Look.script(session, "sessionStorage.setItem('__hidden', '1'); return 1")
                     visit(session, opts, "/projects")

                     until(
                       session,
                       "return document.visibilityState === 'hidden'",
                       "a page that is out of view"
                     )

                     settle()
                     assert posts(session) == 4

                     resolve!(ticket)

                     until(
                       session,
                       "return document.querySelector('#device').dataset.count === '0'",
                       "the count"
                     )

                     settle()
                     assert posts(session) == 4
                   end
                 ],
                 opts
               )
    end)
  end

  # What the phone's bar is painted: the top bar's own colour, in each theme, and following a
  # switch inside forge. `ForgeWeb.Layouts` holds the two values as hex, once.
  @bar """
  const probe = document.createElement('canvas'); probe.width = probe.height = 1;
  const ctx = probe.getContext('2d', {willReadFrequently: true});
  const paint = (css) => { ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = '#000'; ctx.fillStyle = css;
    ctx.fillRect(0, 0, 1, 1); return Array.from(ctx.getImageData(0, 0, 1, 1).data).slice(0, 3) };
  const meta = document.querySelector('meta[name=theme-color]').content;
  return {meta, bar: paint(getComputedStyle(document.querySelector('#top-bar .ui-top-bar')).backgroundColor),
          hex: paint(meta), theme: document.documentElement.dataset.theme}
  """

  defp bar(session), do: Look.script(session, @bar)

  defp switch_theme(session, theme) do
    Look.script(
      session,
      "const el = document.createElement('div'); el.dataset.phxTheme = '#{theme}'; document.body.appendChild(el); " <>
        "el.dispatchEvent(new CustomEvent('phx:set-theme', {bubbles: true})); return 1"
    )
  end

  test "the bar's colour is the top bar's, in either theme, and follows a switch", %{opts: opts} do
    colors = ForgeWeb.Layouts.bar_colors()
    dark_bar = colors.dark

    quiet(fn ->
      assert :ok ==
               run_with(
                 "width phone\nvisit :queue\nwait \"#top-bar\"",
                 [
                   fn session ->
                     for theme <- ["dark", "light", "dark"] do
                       switch_theme(session, theme)

                       until(
                         session,
                         "return document.documentElement.dataset.theme === '#{theme}'",
                         "the theme"
                       )

                       %{"meta" => meta, "bar" => bar, "hex" => hex, "theme" => ^theme} =
                         bar(session)

                       assert meta == Map.fetch!(colors, String.to_existing_atom(theme))

                       # The meta's hex is what the top bar is, within a rounding of the colour space.
                       assert Enum.zip(bar, hex) |> Enum.all?(fn {a, b} -> abs(a - b) <= 2 end),
                              "#{theme}: top bar #{inspect(bar)}, meta #{meta} = #{inspect(hex)}"
                     end

                     # Following the phone's own light or dark, while the person has chosen neither.
                     switch_theme(session, "system")

                     until(
                       session,
                       "return document.documentElement.dataset.themeSource === 'system'",
                       "system theme"
                     )

                     for {scheme, theme} <- [{"light", "light"}, {"dark", "dark"}] do
                       cdp(session, "Emulation.setEmulatedMedia", %{
                         features: [%{name: "prefers-color-scheme", value: scheme}]
                       })

                       until(
                         session,
                         "return document.documentElement.dataset.theme === '#{theme}'",
                         "the phone's #{scheme}"
                       )

                       assert %{"meta" => meta, "bar" => bar, "hex" => hex} = bar(session)
                       assert meta == Map.fetch!(colors, String.to_existing_atom(theme))
                       assert Enum.zip(bar, hex) |> Enum.all?(fn {a, b} -> abs(a - b) <= 2 end)
                     end

                     # A choice the page does not know (a stale or hand-written one) paints the dark bar,
                     # never the string "undefined".
                     Look.script(session, "localStorage.setItem('phx:theme', 'sepia'); return 1")
                     visit(session, opts, "/")

                     until(
                       session,
                       "return document.documentElement.dataset.theme === 'sepia'",
                       "the unknown theme"
                     )

                     assert %{"meta" => ^dark_bar} = bar(session)

                     # A reload keeps the person's choice, and the bar with it.
                     switch_theme(session, "light")
                     visit(session, opts, "/")
                     until(session, "return !!document.querySelector('#top-bar')", "the page")
                     assert %{"meta" => meta, "theme" => "light"} = bar(session)
                     assert meta == colors.light
                   end
                 ],
                 opts
               )
    end)
  end

  # The page's `<head>` as far as installing goes: the manifest at the address a release links, and
  # the worker the app registers. What Chromium asks for is the endpoint's own answer, so a
  # manifest the endpoint 404s fails here with `manifest-parsing-or-network-error`, as it did on
  # every production node until ticket 70.
  test "Chromium finds forge installable at the manifest address a release links", %{opts: opts} do
    # The same JSON with a newline after it, which is another name: `digested_static_test.exs` puts
    # the file itself, and two modules putting one name remove it from under each other.
    manifest =
      File.read!(Path.join(Application.app_dir(:forge, "priv/static"), "manifest.webmanifest"))

    put = Forge.DigestedStatic.put!(%{"manifest.webmanifest" => manifest <> "\n"})
    on_exit(fn -> Forge.DigestedStatic.remove!(put) end)
    digested = put.latest["manifest.webmanifest"]
    assert digested =~ ~r/^manifest-[0-9a-f]{32}\.webmanifest$/

    # `crossorigin="use-credentials"` is for the look's guard, which refuses a request without its
    # cookie, and a manifest is fetched without cookies unless the link says so; a node has no guard.
    page =
      page!("installable.html", """
      <!DOCTYPE html>
      <html lang="en"><head><meta charset="utf-8" /><title>installable</title>
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <link rel="manifest" href="/#{digested}?vsn=d" crossorigin="use-credentials" /></head>
      <body><p id="installable">forge</p>
      <script>navigator.serviceWorker.register('/sw.js')</script></body></html>
      """)

    quiet(fn ->
      assert :ok ==
               run_with(
                 "width phone",
                 [
                   fn session ->
                     Wallaby.Browser.visit(session, opts[:base_url] <> page)
                     until(session, "return !!document.querySelector('#installable')", "the page")

                     assert async(session, "await navigator.serviceWorker.ready; return 'ready'") ==
                              "ready"

                     cdp(session, "Page.enable")

                     # Chromium re-evaluates after the worker is active; ask until it says nothing
                     # or the time is up, and then say what it said.
                     errors = fn ->
                       cdp(session, "Page.getInstallabilityErrors")["installabilityErrors"]
                     end

                     final =
                       Enum.reduce_while(1..40, nil, fn _, _ ->
                         case errors.() do
                           [] ->
                             {:halt, []}

                           found ->
                             Process.sleep(150)
                             {:cont, found}
                         end
                       end)

                     assert final == [],
                            "Chromium cannot install #{page} linking #{digested}: #{inspect(final)}"
                   end
                 ],
                 opts
               )
    end)
  end

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 " <>
            "(KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

  @ipad "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " <>
          "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

  test "an iPhone not on the Home Screen is told to add forge there; elsewhere keeps its words",
       %{
         opts: opts
       } do
    home = "On an iPhone, notifications need forge on the Home Screen."

    quiet(fn ->
      assert :ok ==
               run_with(
                 "width phone",
                 [
                   fn session ->
                     plain = Look.script(session, "return navigator.userAgent")
                     # No push at all, as in Safari: the manager is missing.
                     cdp(session, "Page.addScriptToEvaluateOnNewDocument", %{
                       source: "delete window.PushManager;"
                     })

                     press = fn ->
                       visit(session, opts, "/users/settings")

                       until(
                         session,
                         "return !!document.querySelector('#push-switch')",
                         "the push switch"
                       )

                       Wallaby.Browser.click(session, Wallaby.Query.css("#push-switch"))

                       until(
                         session,
                         "return !!document.querySelector('#push-error')",
                         "its refusal"
                       )

                       Look.script(
                         session,
                         "return document.querySelector('#push-error').innerText"
                       )
                     end

                     # Another browser without push keeps today's words, and does not mention installing.
                     message = press.()

                     assert message =~
                              "Notifications unavailable: this browser has no push support"

                     refute message =~ "Home Screen"

                     cdp(session, "Emulation.setUserAgentOverride", %{userAgent: @iphone})
                     message = press.()
                     assert message =~ home

                     assert message =~
                              "Add it from Safari's Share menu, then turn notifications on there."

                     refute message =~ "Notifications unavailable"

                     # An iPad says it is a Mac, and has a touch screen: only that is told to add forge.
                     cdp(session, "Emulation.setUserAgentOverride", %{
                       userAgent: @ipad,
                       platform: "MacIntel"
                     })

                     cdp(session, "Emulation.setTouchEmulationEnabled", %{enabled: false})
                     message = press.()
                     assert message =~ "Notifications unavailable"
                     refute message =~ "Home Screen"

                     cdp(session, "Emulation.setTouchEmulationEnabled", %{
                       enabled: true,
                       maxTouchPoints: 5
                     })

                     message = press.()
                     assert message =~ home
                     cdp(session, "Emulation.setTouchEmulationEnabled", %{enabled: false})

                     cdp(session, "Emulation.setUserAgentOverride", %{
                       userAgent: @iphone,
                       platform: "iPhone"
                     })

                     # On the Home Screen (`navigator.standalone`) the refusal is the plain one again.
                     cdp(session, "Page.addScriptToEvaluateOnNewDocument", %{
                       source: "Object.defineProperty(navigator, 'standalone', {value: true});"
                     })

                     message = press.()
                     assert message =~ "Notifications unavailable"
                     refute message =~ "Home Screen"

                     assert plain =~ "Chrome"
                   end
                 ],
                 opts
               )
    end)
  end
end
