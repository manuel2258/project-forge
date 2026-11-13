defmodule ForgeWeb.SourceGuardTest do
  @moduledoc """
  Three rules the redesign finished on, kept by reading the source, because each is the absence of
  something and no page test can see an absence everywhere.

  - **A failure is never the frame's** (`docs/design/ui.md` § Errors stay where you acted): the
    frame draws no `:error` flash — not as a toast, not as a line — so a `put_flash` with
    `:error` would be a failure drawn nowhere. Read from the parsed source, not by a pattern.
    Each is drawn where it was made, and a refusal that comes back to the sign-in page carries `:sign_in_error`, which only that page reads.
  - **A refusal in place has one look** (`ui.md` § Errors stay where you acted): every one is
    `ForgeWeb.UI.Feedback.error_note/1`, so no page draws an alert of its own. Read from the
    templates as LiveView's tokenizer reads them: a plain element that declares itself an alert,
    or is coloured danger and shows an error assign, is one drawn by hand. The sign-in page's
    titled refusal (`21n`) is the one other, and is named here.
  - **No component library's names** (`ui.md` § Tokens): the temporary daisyUI aliases are gone,
    so a class that names one draws nothing.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp sources(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.map(&{Path.relative_to(&1, @root), File.read!(&1)})
  end

  # Every `put_flash` the source makes, read as Elixir reads it rather than matched as text: by
  # its key, whatever the receiver — `socket`, `assigns.socket`, a pipe — and whether it is
  # called locally, as `Phoenix.LiveView.put_flash/3`, or captured. A key that is not a literal
  # atom or string (a variable, a call) cannot be checked here, so it is an offender too: the
  # rule is that every flash's key can be read off the source.
  defp flash_keys(text) do
    {:ok, ast} = Code.string_to_quoted(text)

    ast
    |> Macro.prewalk([], fn node, acc -> {node, flash_key(node) ++ acc} end)
    |> elem(1)
  end

  defp flash_key({:put_flash, _meta, args}) when is_list(args), do: key_of(args)
  defp flash_key({{:., _, [_module, :put_flash]}, _meta, args}), do: key_of(args)
  # A capture with an arity hands the key over at run time: `&put_flash/3`.
  defp flash_key({:/, _, [{:put_flash, _, ctx}, _arity]}) when is_atom(ctx), do: [:unknown]
  defp flash_key({:/, _, [{{:., _, [_module, :put_flash]}, _, _}, _arity]}), do: [:unknown]
  defp flash_key(_node), do: []

  # Piped, the receiver is not among the arguments: the key is first of two, else second of three.
  defp key_of([key, _message]), do: [literal(key)]
  defp key_of([_receiver, key, _message]), do: [literal(key)]
  defp key_of(_other), do: []

  defp literal(key) when is_atom(key), do: to_string(key)
  defp literal(key) when is_binary(key), do: key
  defp literal(_expression), do: :unknown

  defp offending?(key), do: key in ["error", :unknown]

  test "no page puts an :error flash" do
    offenders =
      for {path, text} <- sources(["lib/forge_web/**/*.ex"]),
          key <- flash_keys(text),
          offending?(key),
          do: {path, key}

    assert offenders == []

    # Markup is not Elixir to parse; a flash is not put from it, and none names the call.
    for {path, text} <- sources(["lib/forge_web/**/*.heex"]),
        do: refute(text =~ "put_flash", path)
  end

  test "the reading finds each way of putting one" do
    for source <- [
          ~s|put_flash(socket, :error, "x")|,
          ~s{socket |> put_flash(:error, "x")},
          ~s|Phoenix.LiveView.put_flash(\n  socket,\n  :error,\n  "x")|,
          ~s|put_flash(socket, "error", "x")|,
          ~s|put_flash(assigns.socket, :error, "x")|,
          ~s|put_flash(socket2, :error, "x")|,
          ~s|put_flash(socket, kind, "x")|,
          ~s{conn |> Phoenix.Controller.put_flash(kind, "x")},
          ~s|Enum.reduce(xs, socket, &put_flash(&2, :error, &1))|,
          ~s|apply_each(socket, &put_flash/3)|
        ] do
      assert Enum.any?(flash_keys(source), &offending?/1), source
    end

    for source <- [
          ~s|put_flash(conn, :sign_in_error, "x")|,
          ~s{socket |> put_flash(:info, "x")},
          ~s|put_flash(socket, "info", "x")|
        ] do
      refute Enum.any?(flash_keys(source), &offending?/1), source
    end
  end

  # Every template the web layer holds, as HEEx reads it: each `~H` in a module, found in the
  # parsed source, and each `.heex` file whole; then tokenized by LiveView's own HEEx tokenizer,
  # so that an element is an element and not a run of text that looks like one.
  defp templates(path, text) do
    if String.ends_with?(path, ".heex") do
      [text]
    else
      {:ok, ast} = Code.string_to_quoted(text)

      ast
      |> Macro.prewalk([], fn
        {:sigil_H, _meta, [{:<<>>, _, [template]}, _mods]} = node, acc when is_binary(template) ->
          {node, [template | acc]}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)
    end
  end

  defp tokens(template) do
    Phoenix.LiveView.TagEngine.Parser.tokenize(template,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      file: "nofile"
    )
  end

  # A refusal drawn by hand: a plain element — not a component, so not `error_note/1` — that
  # either declares itself an alert, or is coloured as a danger and shows an error, an assign or
  # field whose name ends in `error` (`@error`, `@chat_error`, `assigns.decision_error`), in its
  # `:if` or in what it holds. A danger colour on anything else is a state — a failed job, a
  # conflict, an error line of a log — and not an answer to the person's press.
  defp hand_drawn(template) do
    tokens = tokens(template)

    for {{:tag, name, attrs, meta}, i} <- Enum.with_index(tokens),
        alert?(attrs) or (danger?(attrs) and shows_error?(attrs, body(tokens, i, name))),
        do: "<#{name}#{id(attrs)}> at the template's line #{meta.line}"
  end

  defp alert?(attrs),
    do: Enum.any?(attrs, fn {key, value, _} -> key == "role" and text(value) =~ "alert" end)

  defp danger?(attrs),
    do:
      Enum.any?(attrs, fn {key, value, _} -> key == "class" and text(value) =~ "text-danger" end)

  @error ~r/(?:@|assigns\.)\w*error\b/

  defp shows_error?(attrs, body) do
    Enum.any?(attrs, fn {key, value, _} -> key == ":if" and text(value) =~ @error end) or
      Enum.any?(body, &(&1 =~ @error))
  end

  defp id(attrs) do
    case Enum.find(attrs, &match?({"id", _value, _meta}, &1)) do
      {"id", value, _meta} -> " id=" <> text(value)
      nil -> ""
    end
  end

  defp text({:string, value, _meta}), do: value
  defp text({:expr, value, _meta}), do: value
  defp text(_none), do: ""

  # What an element holds, as the expressions in it, up to the close that matches it.
  defp body(tokens, i, name) do
    tokens
    |> Enum.drop(i + 1)
    |> Enum.reduce_while({0, []}, fn
      {:tag, ^name, _attrs, %{closing: _}}, acc ->
        {:cont, acc}

      {:tag, ^name, _attrs, _meta}, {depth, exprs} ->
        {:cont, {depth + 1, exprs}}

      {:close, :tag, ^name, _meta}, {0, exprs} ->
        {:halt, {0, exprs}}

      {:close, :tag, ^name, _meta}, {depth, exprs} ->
        {:cont, {depth - 1, exprs}}

      {:body_expr, expr, _meta}, {depth, exprs} ->
        {:cont, {depth, [expr | exprs]}}

      {:eex, _kind, expr, _meta}, {depth, exprs} ->
        {:cont, {depth, [expr | exprs]}}

      {_kind, _name, attrs, _meta}, {depth, exprs} when is_list(attrs) ->
        {:cont, {depth, Enum.map(attrs, fn {_key, value, _} -> text(value) end) ++ exprs}}

      _other, acc ->
        {:cont, acc}
    end)
    |> elem(1)
  end

  @alerts_of_their_own [
    "lib/forge_web/components/ui/feedback.ex",
    "lib/forge_web/live/user_live/login.ex"
  ]

  # States drawn red that carry an error by name, and are no answer to a press: what the machine
  # reported of updating its own Claude Code, which nobody on this page asked for.
  @states_with_an_error [
    {"lib/forge_web/live/workers_live.ex", ~s|<div id="claude-update-|}
  ]

  defp state?(path, element),
    do:
      Enum.any?(@states_with_an_error, fn {p, s} ->
        p == path and String.starts_with?(element, s)
      end)

  test "every refusal in place is an error_note" do
    offenders =
      for {path, text} <- sources(["lib/forge_web/**/*.ex", "lib/forge_web/**/*.heex"]),
          path not in @alerts_of_their_own,
          template <- templates(path, text),
          element <- hand_drawn(template),
          not state?(path, element),
          do: {path, element}

    assert offenders == []
  end

  test "the reading finds each way of drawing one by hand" do
    for template <- [
          ~s|<p :if={@error} role="alert" class="x-error">{@error}</p>|,
          ~s|<div role={"alert"}>x</div>|,
          ~s|<p :if={@error} class="text-sm text-danger">{@error}</p>|,
          ~s|<p class="text-danger">{@chat_error}</p>|,
          ~s|<p class={["mt-2", @x && "text-danger"]}>Refused: <span>{@save_error}</span></p>|,
          ~s|<p class="text-danger"><%= assigns.decision_error %></p>|,
          ~s|<p :if={@refusal_error} class="machine-line text-danger">The machine refused.</p>|
        ] do
      assert hand_drawn(template) != [], template
    end

    # And not on a state drawn red, nor on the one look itself.
    for template <- [
          ~s|<span :if={@decision.conflict} class="text-danger">conflict</span>|,
          ~s|<li class={["x", @failed && "text-danger"]}>{@line}</li>|,
          ~s|<.error_note :if={@error}>{@error}</.error_note>|,
          ~s|<p class="text-danger">x</p><p>{@error}</p>|
        ] do
      assert hand_drawn(template) == [], template
    end

    # It finds the templates in a module, not only in a `.heex` file.
    assert [_one] = templates("x.ex", ~s|defmodule X do\n  def f(assigns), do: ~H"<p>x</p>"\nend|)
  end

  @library ~r/\b(?:base-100|base-200|base-300|base-content|daisy|hero-)/

  test "nothing names a daisyUI or Heroicons class" do
    offenders =
      for {path, text} <-
            sources([
              "lib/forge_web/**/*.ex",
              "lib/forge_web/**/*.heex",
              "assets/css/**/*.css",
              "assets/js/**/*.js"
            ]),
          Regex.match?(@library, text),
          do: path

    assert offenders == []
  end

  # The browser's `window.confirm` behind `data-confirm` says *OK / Cancel*, ignores the theme,
  # floats free of the row it is about and can be switched off for the page by the browser: every
  # second look is `ForgeWeb.UI.Decisions.confirm/1`, asked in place (`ui.md` § The confirm). Read
  # as attributes in the templates' source, so a `data-confirm=` drawn anywhere is found.
  test "nothing asks through the browser's confirm" do
    offenders =
      for {path, text} <- sources(["lib/forge_web/**/*.ex", "lib/forge_web/**/*.heex"]),
          Regex.match?(~r/\bdata-confirm\s*=|\bwindow\.confirm\b/, text),
          do: path

    assert offenders == []
  end
end
