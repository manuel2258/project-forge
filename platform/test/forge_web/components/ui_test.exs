defmodule ForgeWeb.UITest do
  @moduledoc """
  The primitives (`docs/design/ui.md` § Components): each one's contract, and the rules that
  must not be lost when a page draws through it — usage never amber, a disabled button never
  hidden, a count amber only when asked, a toast that cannot be tapped, a choice that never
  submits, an error under its own field.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  import ForgeWeb.CoreComponents, only: [button: 1, input: 1]
  import ForgeWeb.UI.Navigation
  import ForgeWeb.UI.Decisions
  import ForgeWeb.UI.Forms
  import ForgeWeb.UI.Data
  import ForgeWeb.UI.Feedback

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp all(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> all(selector) |> Enum.count()
  defp attrs(html, selector, name), do: html |> all(selector) |> LazyHTML.attribute(name)
  defp text(html, selector), do: html |> all(selector) |> LazyHTML.text() |> String.trim()

  defp classes(html, selector) do
    html |> attrs(selector, "class") |> Enum.flat_map(&String.split/1)
  end

  describe "usage_line/1" do
    defp fill(percent, window \\ "5h") do
      render_component(&usage_line/1, percent: percent, window: window)
      |> classes(".ui-usage-fill")
    end

    test "is quiet under 80, the warning colour from 80, danger from 95" do
      assert "ui-usage-fill--quiet" in fill(0)
      assert "ui-usage-fill--quiet" in fill(79)
      assert "ui-usage-fill--warning" in fill(80)
      assert "ui-usage-fill--warning" in fill(94)
      assert "ui-usage-fill--danger" in fill(95)
      assert "ui-usage-fill--danger" in fill(100)
      assert "ui-usage-fill--warning" in fill(80, "week")
    end

    test "is never drawn in the accent, which means waits on you" do
      for percent <- [0, 50, 79, 80, 94, 95, 120], window <- ~w(5h week) do
        html = render_component(&usage_line/1, percent: percent, window: window)
        refute html =~ "accent"
      end
    end

    test "fills to its figure and no further" do
      assert attrs(render_component(&usage_line/1, percent: 42), ".ui-usage-fill", "style") ==
               ["width: 42%"]

      assert attrs(render_component(&usage_line/1, percent: 130), ".ui-usage-fill", "style") ==
               ["width: 100%"]
    end

    test "a set in which nothing reported keeps the band and draws no meter" do
      html = render_component(&usage_line/1, percent: nil, window: "week")
      assert count(html, ".ui-usage.ui-usage--empty.ui-usage--week") == 1
      assert count(html, "[role=meter]") == 0
      assert count(html, ".ui-usage-fill") == 0
    end

    test "is a meter naming its window" do
      html = render_component(&usage_line/1, percent: 18, window: "week")
      assert attrs(html, "[role=meter]", "aria-label") == ["Weekly usage"]
      assert attrs(html, "[role=meter]", "aria-valuenow") == ["18"]
    end
  end

  describe "button/1" do
    test "disabled keeps the element, its size and its place" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="primary" size="xl" disabled>Send 0 of 2</.button>
        """)

      assert count(html, "button[disabled]") == 1
      assert "ui-btn--xl" in classes(html, "button")
      refute html =~ "hidden"
      refute html =~ "display: none"
    end

    test "a decision leads with ◆ unless told not to; nothing else does" do
      assigns = %{}

      lead = fn html -> html |> all("button > span") |> Enum.at(0) |> LazyHTML.text() end

      assert lead.(rendered_to_string(~H|<.button variant="decision">Approve</.button>|)) == "◆"

      assert lead.(rendered_to_string(~H|<.button variant="decision-open">Accept</.button>|)) ==
               "◆"

      for html <- [
            rendered_to_string(
              ~H|<.button variant="decision" diamond={false}>Approve v1</.button>|
            ),
            rendered_to_string(~H|<.button variant="primary">Send</.button>|),
            rendered_to_string(~H|<.button variant="neutral">Merge</.button>|)
          ] do
        refute html =~ "◆"
      end
    end

    test "a variant and a size are classes; no variant is the bordered secondary" do
      assigns = %{}
      html = rendered_to_string(~H|<.button>Later</.button>|)
      assert ["ui-btn", "ui-btn--secondary", "ui-btn--lg"] -- classes(html, "button") == []

      html = rendered_to_string(~H|<.button variant="danger" size="desk" fill>Revoke</.button>|)
      assert ["ui-btn--danger", "ui-btn--desk", "ui-btn--fill"] -- classes(html, "button") == []
    end

    test "a chevron trails, and a destination makes it a link" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="outline" chevron navigate="/tickets/game/39">Review the changeset</.button>
        """)

      assert count(html, "a[href='/tickets/game/39'].ui-btn--chevron") == 1
      assert count(html, "button") == 0
      assert html |> all("a > span") |> Enum.at(-1) |> LazyHTML.text() == "›"
    end

    # `›` navigates (`ui.md` § Marks): a Send, a submit or a click that commits in place promised a
    # page change that never came, so the mark is drawn on a link and nowhere else.
    test "a chevron on a button that does not go anywhere is not drawn" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button type="submit" variant="primary" chevron>Send 1 answer</.button>
        <.button phx-click="go" chevron>Pick</.button>
        """)

      refute html =~ "›"
      assert count(html, ".ui-btn--chevron") == 0
    end
  end

  describe "count_bubble/1" do
    test "is grey unless it counts what waits on the reader" do
      refute render_component(&count_bubble/1, value: 12) =~ "accent"

      assert "ui-count--accent" in classes(
               render_component(&count_bubble/1, value: 4, tone: "accent"),
               "span"
             )
    end
  end

  describe "workflow_track/1" do
    @steps ~w(triage shaping planning impl. review merging done)

    test "the steps before current are done, current is current, next is next, the rest rest" do
      html = render_component(&workflow_track/1, steps: @steps, current: 3, next: 4)

      positions =
        html
        |> all(".ui-track-step")
        |> Enum.map(fn step ->
          step
          |> LazyHTML.attribute("class")
          |> hd()
          |> String.split()
          |> Enum.find(&String.starts_with?(&1, "ui-track-step--"))
        end)

      assert positions ==
               Enum.map(~w(done done done current next rest rest), &"ui-track-step--#{&1}")

      assert attrs(html, "[aria-current=step]", "class") |> length() == 1
      assert text(html, "[aria-current=step] .ui-track-label") == "impl."
    end

    test "without a next, the step after current is the rest" do
      html = render_component(&workflow_track/1, steps: @steps, current: 0)
      assert count(html, ".ui-track-step--next") == 0
      assert count(html, ".ui-track-step--rest") == 6
    end

    test "compact draws one tick per step and no labels" do
      html = render_component(&workflow_track/1, steps: @steps, current: 1, compact: true)
      assert count(html, ".ui-track-tick") == 7
      assert count(html, ".ui-track-tick--done") == 1
      assert count(html, ".ui-track-tick--current") == 1
      assert count(html, ".ui-track-label") == 0
    end

    # Amber is a person being waited on (`ui.md` § Colour): a running or queued ticket's current
    # step is ink, and only a ticket that waits on someone draws it amber.
    test "the current step is amber only on a ticket that waits on a person" do
      quiet = render_component(&workflow_track/1, steps: @steps, current: 1)
      waiting = render_component(&workflow_track/1, steps: @steps, current: 1, waiting: true)
      ticks = render_component(&workflow_track/1, steps: @steps, current: 1, compact: true)

      waiting_ticks =
        render_component(&workflow_track/1,
          steps: @steps,
          current: 1,
          compact: true,
          waiting: true
        )

      assert count(quiet, ".ui-track--waiting") == 0
      assert count(ticks, ".ui-track--waiting") == 0
      assert count(waiting, ".ui-track.ui-track--waiting") == 1
      assert count(waiting_ticks, ".ui-track--compact.ui-track--waiting") == 1
    end

    test "every step names itself in a title, for the phone, where no label is drawn" do
      html = render_component(&workflow_track/1, steps: @steps, current: 1)
      assert attrs(html, ".ui-track-step", "title") == @steps
    end
  end

  describe "state_label/1" do
    test "each state draws its own mark in its own colour" do
      expected = %{
        "running" => "▸",
        "waiting" => "●",
        "step" => "●",
        "stuck" => "●",
        "idle" => "○"
      }

      for {state, mark} <- expected do
        assigns = %{state: state}
        html = rendered_to_string(~H|<.state_label state={@state}>implementing</.state_label>|)
        assert "ui-state--#{state}" in classes(html, ".ui-state"), state
        assert text(html, ".ui-state-mark") == mark, state
        assert text(html, ".ui-state") == "#{mark} implementing"
      end
    end
  end

  describe "TicketViews.allowance/1" do
    # A spent allowance waits on nobody, so its meter takes a usage line's tones and never the
    # accent: quiet below 80 %, warning from 80, danger from 95 (`ui.md` § Colour).
    test "takes the usage line's tone for how much is spent, never amber" do
      workflow = %{limits: %{ticket_tokens: 1_000}}

      for {spent, tone, width} <- [
            {500, "quiet", "50"},
            {800, "warning", "80"},
            {950, "danger", "95"},
            {3_000, "danger", "100"}
          ] do
        html =
          render_component(&ForgeWeb.TicketViews.allowance/1,
            ticket: %{usage: spent},
            workflow: workflow,
            class: "track"
          )

        assert "ui-usage-fill--#{tone}" in classes(html, ".track > .ui-usage-fill"), "#{spent}"
        assert html =~ "width: #{width}%"
        refute html =~ "accent"
      end
    end

    test "a workflow with no allowance draws an empty meter" do
      html =
        render_component(&ForgeWeb.TicketViews.allowance/1,
          ticket: %{usage: 300},
          workflow: %{limits: %{ticket_tokens: nil}},
          class: "track"
        )

      assert html =~ "width: 0%"
    end
  end

  describe "toast/1" do
    test "is announced, cannot be tapped, and has no button" do
      html = render_component(&toast/1, title: "Approved changeset v1", detail: "merging started")

      assert attrs(html, "[role=status]", "class") |> length() == 1
      assert "pointer-events-none" in classes(html, "[role=status]")
      assert count(html, "button") == 0
      assert count(html, "a") == 0
      assert text(html, ".ui-toast-title") == "Approved changeset v1"
      assert text(html, ".ui-toast-detail") == "merging started"
    end

    # Only a success is ever a toast: a failure stays where it was made (`ui.md` § Errors stay
    # where you acted), so the toast has no other tone to draw.
    test "is marked as a success" do
      assert text(render_component(&toast/1, title: "t"), ".ui-toast-mark") == "✓"
    end
  end

  describe "choice_row/1" do
    test "is a radio, or a checkbox with multi, and never a submit" do
      radio = render_component(&choice_row/1, name: "a", value: "1", label: "Only your score")
      check = render_component(&choice_row/1, name: "s[]", value: "X", label: "X", multi: true)

      assert attrs(radio, "input", "type") == ["radio"]
      assert attrs(check, "input", "type") == ["checkbox"]

      for html <- [radio, check] do
        assert count(html, "button") == 0
        refute html =~ "submit"
      end
    end

    test "selected is the input's own checked, and the badge is drawn when recommended" do
      html =
        render_component(&choice_row/1,
          name: "a",
          value: "1",
          label: "Your rank and score",
          selected: true,
          recommended: true,
          detail: "Shown under the table."
        )

      assert count(html, "input[checked]") == 1
      assert text(html, ".ui-badge") == "recommended"
      assert "ui-choice--detail" in classes(html, "label")
      refute render_component(&choice_row/1, name: "a", value: "1", label: "x") =~ "checked"
    end
  end

  describe "input/1, the Field" do
    test "an error is drawn under its own input, which is marked invalid and points at it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="email"
          name="email"
          value="sam@example.com"
          label="Add someone"
          errors={["No approved account for that address."]}
          hint="An address."
        />
        <.input id="name" name="name" value="" label="Name" />
        """)

      assert attrs(html, "#email", "aria-invalid") == ["true"]
      assert attrs(html, "#email", "aria-describedby") == ["email-error"]
      assert text(html, "#email-error") == "No approved account for that address."
      # The hint is the error's place while there is one.
      assert count(html, ".ui-field-hint") == 0
      assert attrs(html, "#name", "aria-invalid") == []

      # Under the input it belongs to: the same field, after the input.
      [email_field] = html |> all(".ui-field") |> Enum.take(1)
      assert email_field |> LazyHTML.query("#email + #email-error") |> Enum.count() == 1
    end

    test "a hint is said under the field while it has no error" do
      html =
        render_component(&input/1,
          id: "slug",
          name: "slug",
          value: "leaderboard-api",
          label: "Name",
          mono: true,
          hint: "Lowercase, digits and hyphens."
        )

      assert text(html, "#slug-hint") == "Lowercase, digits and hyphens."
      assert attrs(html, "#slug", "aria-describedby") == ["slug-hint"]
      assert "ui-field--mono" in classes(html, ".ui-field")
    end

    test "multiline is a textarea, and desk the desktop size" do
      html =
        render_component(&input/1, id: "n", name: "n", value: "x", multiline: true, desk: true)

      assert count(html, "textarea#n") == 1
      assert "ui-field--desk" in classes(html, ".ui-field")
    end
  end

  describe "top_bar/1 and queue_button/1" do
    test "the queue button is amber only while something waits" do
      assert "ui-queue-btn--waiting" in classes(render_component(&queue_button/1, count: 4), "a")
      refute "ui-queue-btn--waiting" in classes(render_component(&queue_button/1, count: 0), "a")

      assert attrs(render_component(&queue_button/1, count: 4), "a", "aria-label") ==
               ["Queue, 4 waiting"]
    end

    test "draws both usage lines around the bar, or a rule without them" do
      html = render_component(&top_bar/1, title: "Queue", usage: %{five_h: 42, week: 18})
      assert attrs(html, "[role=meter]", "aria-label") == ["5-hour usage", "Weekly usage"]
      assert count(html, ".ui-top-rule") == 0

      html = render_component(&top_bar/1, title: "Sign in", usage: nil)
      assert count(html, "[role=meter]") == 0
      assert count(html, ".ui-top-rule") == 1
    end

    test "disconnected says so in place of the title, with its countdown, and no usage" do
      html =
        render_component(&top_bar/1,
          title: "Persist the high score table",
          usage: %{five_h: 42, week: 18},
          menu: true,
          disconnected: "retrying in 4s"
        )

      assert "ui-top--disconnected" in classes(html, ".ui-top")
      assert text(html, ".ui-top-name") == "Not connected"
      assert text(html, ".ui-top-sub") == "retrying in 4s"
      assert count(html, "[role=meter]") == 0
      refute html =~ "▾"
    end

    # The right end goes to the parent, `game ›`; an action there — `+ New` — opens in place, so
    # it draws no navigation mark.
    test "the context leads to the parent with ›, and an action with none" do
      parent = render_component(&top_bar/1, title: "T", context: "game", context_path: "/p/game")
      action = render_component(&top_bar/1, title: "T", context: "+ New", context_path: "/p?new")

      assert text(parent, ".ui-top-context") == "game ›"
      assert text(action, ".ui-top-context") == "+ New"
    end

    test "a top-level title is a switch: ▾ closed, ▴ open" do
      assigns = %{}

      closed =
        rendered_to_string(~H|<.top_bar title="Queue" menu queue={false} on_title="menu" />|)

      open =
        rendered_to_string(
          ~H|<.top_bar title="Queue" menu menu_open queue={false} on_title="menu" />|
        )

      assert text(closed, ".ui-top-menu") == "▾"
      assert text(open, ".ui-top-menu") == "▴"
      assert attrs(closed, "button.ui-top-title", "phx-click") == ["menu"]
      # The queue page draws no queue button.
      assert count(closed, ".ui-queue-btn") == 0
    end

    test "the context leads to its object" do
      html =
        render_component(&top_bar/1, title: "x", context: "game", context_path: "/projects/game")

      assert attrs(html, "a.ui-top-context", "href") == ["/projects/game"]
      assert text(html, ".ui-top-context") == "game ›"
    end
  end

  describe "bottom_strip/1 and view_tabs/1" do
    test "marks the active view, counts in grey, and holds nothing but links" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.bottom_strip active="Changes">
          <:tab label="Steps" patch="?view=steps" />
          <:tab label="Changes" count={3} patch="?view=changes" />
          <:tab label="Docs" count={0} patch="?view=docs" />
        </.bottom_strip>
        """)

      assert attrs(html, "[aria-current=page]", "href") == ["?view=changes"]
      # A zero is drawn muted, never hidden, so the tabs never move; a tab with no count has none.
      assert count(html, ".ui-count") == 2
      assert text(html, ".ui-count--muted") == "0"
      refute html =~ "accent"
      assert count(html, "button") == 0
      assert count(html, "a") == 3
    end

    test "the desktop tabs mark the same view" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.view_tabs active="Docs">
          <:tab label="Talk" patch="?view=talk" />
          <:tab label="Docs" count={1} patch="?view=docs" />
        </.view_tabs>
        """)

      assert attrs(html, "[aria-current=page]", "href") == ["?view=docs"]

      html =
        rendered_to_string(~H"""
        <.view_tabs active="Docs">
          <:tab label="Docs" count={0} patch="?view=docs" />
        </.view_tabs>
        """)

      assert text(html, ".ui-tab-zero") == "0"
    end
  end

  describe "decision_row/1 and drop_panel/1" do
    test "amber when it waits on you, its panel drawn only while open" do
      assigns = %{open: false}

      row = fn assigns ->
        rendered_to_string(~H"""
        <.decision_row kind="doc" action="Accept" open={@open} on_toggle="toggle">
          <:title>brief.md v2</:title>
          <:meta>written 3m ago</:meta>
          <.drop_panel title="Accept step shaping" secondary="Answer first" primary="Accept anyway" />
        </.decision_row>
        """)
      end

      closed = row.(assigns)
      assert "ui-btn--decision" in classes(closed, ".ui-decision-bar button")
      assert attrs(closed, ".ui-decision-bar button", "aria-expanded") == ["false"]
      assert text(closed, ".ui-decision-bar button") =~ "◆"
      assert count(closed, ".ui-drop") == 0

      open = row.(%{assigns | open: true})
      assert "ui-btn--decision-open" in classes(open, ".ui-decision-bar button")
      assert text(open, ".ui-decision-bar button") =~ "Accept ▴"
      assert count(open, ".ui-drop") == 1
      # The confirming button is the trigger's colour, without the diamond.
      assert "ui-btn--decision" in classes(open, ".ui-drop-actions button.ui-btn--fill")
      refute text(open, ".ui-drop-actions") =~ "◆"
    end

    test "neutral when it does not wait on you" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.decision_row kind="branch" tone="neutral" action="Merge">
          <:title>chat/3f9a21c0</:title>
        </.decision_row>
        """)

      assert "ui-decision--neutral" in classes(html, ".ui-decision")
      assert "ui-btn--neutral" in classes(html, "button")
      refute html =~ "◆"
    end

    test "a panel warns in a warning notice, not amber, and its primary may submit a form" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drop_panel
          title="Approve changeset v1"
          primary="Approve v1"
          form="approve"
          on_primary="approve"
          on_close="close"
        >
          <:warning title="1 open question will stay unanswered">Planning starts as written.</:warning>
        </.drop_panel>
        """)

      assert text(html, ".ui-notice-title") == "1 open question will stay unanswered"
      # A consequence nobody waits on: no ◆, no amber (`ui.md` § Colour).
      assert count(html, ".ui-notice.ui-notice--warning") == 1
      assert count(html, ".ui-notice-diamond") == 0
      assert attrs(html, ".ui-drop-actions button", "type") == ["submit"]
      assert attrs(html, ".ui-drop-actions button", "form") == ["approve"]
      assert attrs(html, ".ui-drop-actions button", "phx-click") == []
      assert attrs(html, ".ui-drop-scrim", "phx-click") == ["close"]
    end
  end

  describe "confirm/1" do
    # The second look before a destructive act, asked in place (`ui.md` § The confirm): the
    # trigger only opens it, in the browser; the sentence and the two named buttons start folded;
    # and the button that acts is the one carrying the event.
    test "the trigger opens it, and only the act's button sends anything" do
      html =
        render_component(&confirm/1,
          id: "revoke-1",
          label: "Revoke",
          act: "Revoke it",
          sentence: "Revoke this token? Anything using it stops working.",
          "phx-click": "revoke",
          "phx-value-id": "1"
        )

      assert text(html, "#revoke-1-ask") == "Revoke"
      assert "ui-btn--danger" in classes(html, "#revoke-1-ask")
      [opens] = attrs(html, "#revoke-1-ask", "phx-click")
      assert opens =~ "revoke-1-confirm" and not (opens =~ ~s("push"))

      assert attrs(html, "#revoke-1-confirm", "style") == ["display: none"]
      assert text(html, "#revoke-1-confirm .ui-confirm-sentence") =~ "Anything using it stops"
      assert text(html, "#revoke-1-keep") == "Keep it"
      refute attrs(html, "#revoke-1-keep", "phx-click") |> hd() =~ ~s("push")

      assert attrs(html, "#revoke-1", "phx-click") == ["revoke"]
      assert attrs(html, "#revoke-1", "phx-value-id") == ["1"]
      assert text(html, "#revoke-1") == "Revoke it"
      assert "ui-btn--danger" in classes(html, "#revoke-1")
      # Never the browser's own dialog.
      assert count(html, "[data-confirm]") == 0
    end

    test "neutral asks without red; quiet is a mark; fill takes the row" do
      html =
        render_component(&confirm/1,
          id: "repin",
          label: "Re-pin",
          act: "Re-pin it",
          sentence: "Re-pin?",
          tone: "neutral"
        )

      assert "ui-btn--secondary" in classes(html, "#repin-ask")
      assert "ui-btn--outline" in classes(html, "#repin")
      assert count(html, ".ui-confirm--neutral") == 1

      quiet =
        render_component(&confirm/1,
          id: "x",
          label: "×",
          act: "Remove them",
          sentence: "Remove?",
          trigger: "quiet",
          aria_label: "Remove ana",
          fill: true
        )

      assert "ui-btn--quiet" in classes(quiet, "#x-ask")
      assert attrs(quiet, "#x-ask", "aria-label") == ["Remove ana"]
      assert count(quiet, ".ui-confirm--fill") == 1
    end
  end

  describe "segmented/1" do
    test "in a form, each option is a radio, the value's checked" do
      html =
        render_component(&segmented/1,
          name: "access",
          options: ["none", "read", {"read and write", "write"}],
          value: "read"
        )

      assert attrs(html, "input[type=radio]", "value") == ["none", "read", "write"]
      assert attrs(html, "input[checked]", "value") == ["read"]
    end

    test "outside a form, each option is a button that says whether it is the one" do
      html =
        render_component(&segmented/1, options: ~w(low high), value: "high", on_select: "effort")

      assert attrs(html, "button[role=radio]", "aria-checked") == ["false", "true"]
      assert attrs(html, "button", "phx-value-value") == ["low", "high"]
      # A browser sends the clicked button's own `value` over `phx-value-value`; without it the
      # handler was sent "" whichever option was pressed.
      assert attrs(html, "button", "value") == ["low", "high"]
      assert attrs(html, "button", "type") == ["button", "button"]
    end

    test "a count is a bubble beside its label, and a zero a muted one" do
      html =
        render_component(&segmented/1,
          options: [{"Open", "open", 8}, {"Declined", "declined", 0}, {"All", "all"}],
          value: "open",
          on_select: "list"
        )

      assert html |> all("button .ui-count") |> Enum.map(&LazyHTML.text/1) == ["8", "0"]
      assert count(html, "button:nth-child(2) .ui-count--muted") == 1
      assert count(html, "button:nth-child(1) .ui-count--muted") == 0
      assert attrs(html, "button", "value") == ["open", "declined", "all"]
    end
  end

  describe "stepper/1" do
    test "a bounded number whose buttons step it in the browser" do
      html = render_component(&stepper/1, id: "days", name: "days", value: 7, min: 1, max: 30)

      assert attrs(html, "input#days", "type") == ["number"]
      assert attrs(html, "input#days", "min") == ["1"]
      assert attrs(html, "input#days", "max") == ["30"]
      assert attrs(html, "button", "type") == ["button", "button"]

      [less, more] = attrs(html, "button", "phx-click")
      assert less =~ ~s("forge:step") and less =~ ~s("#days") and less =~ ~s("by":-1)
      assert more =~ ~s("by":1)
    end
  end

  describe "composer/1" do
    test "sends with an icon inside the field, never a filled button" do
      html = render_component(&composer/1, id: "reply", name: "body")
      assert attrs(html, "button", "aria-label") == ["Send"]
      assert attrs(html, "button", "type") == ["submit"]
      refute html =~ "ui-btn--primary"
      assert attrs(html, "textarea", "phx-hook") == ["ForgeWeb.UI.Forms.Composer"]
    end

    test "Enter sends on a keyboard and ends a line on a phone, or always ends one" do
      send = render_component(&composer/1, id: "r", name: "b")
      newline = render_component(&composer/1, id: "r", name: "b", enter: :newline)
      assert attrs(send, "textarea", "data-newline-on") == ["(pointer: coarse)"]
      assert attrs(newline, "textarea", "data-newline-on") == ["all"]
    end

    test "names the cost while the agent is responding" do
      html = render_component(&composer/1, id: "r", name: "b", interrupt: true)
      assert text(html, "button") =~ "Interrupt and send"
    end
  end

  describe "the data primitives" do
    test "diff_stat counts in green and red, with files and a bar on request" do
      html = render_component(&diff_stat/1, added: 48, removed: 6, files: 3, bar: true)
      assert text(html, ".ui-diffstat > .ui-diffstat-add") == "+48"
      assert text(html, ".ui-diffstat > .ui-diffstat-del") == "−6"
      assert text(html, ".ui-diffstat-files") == "· 3 files"

      assert attrs(html, ".ui-diffstat-bar > .ui-diffstat-add", "style") == [
               "width: 88.88888888888889%"
             ]

      assert text(render_component(&diff_stat/1, files: 1), ".ui-diffstat-files") == "· 1 file"
      assert count(render_component(&diff_stat/1, []), ".ui-diffstat-bar") == 0
    end

    test "type_icon names each kind, smaller when the glyph is a word" do
      for {kind, glyph} <- [
            {"doc", "md"},
            {"changeset", "±"},
            {"branch", "⑂"},
            {"release", "⇡"}
          ] do
        html = render_component(&type_icon/1, kind: kind)
        assert text(html, ".ui-kind--#{kind}") == glyph
        assert "ui-kind--word" in classes(html, ".ui-kind") == String.length(glyph) > 1
      end

      assert text(render_component(&type_icon/1, kind: "doc", label: "{}"), ".ui-kind") == "{}"
    end

    test "list_row is the link when it goes somewhere, and marks its edge" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.list_row
          title="Replace the font atlas"
          kicker="stuck · 25m"
          latest="3 tests failing"
          latest_tone="warning"
          edge="accent"
          navigate="/tickets/game/44"
        >
          <:meta>
            <.state_label state="stuck">implementing</.state_label>
          </:meta>
        </.list_row>
        """)

      assert count(html, "a.ui-row.ui-row--accent[href='/tickets/game/44']") == 1
      assert text(html, ".ui-row-latest--warning") == "3 tests failing"
      assert text(html, ".ui-row-chevron") == "›"

      plain = rendered_to_string(~H|<.list_row title="x" selected chevron={false} />|)
      assert count(plain, "div.ui-row.ui-row--selected") == 1
      assert count(plain, ".ui-row-chevron") == 0
    end

    test "context_card carries the ticket, its track and its facts" do
      html =
        render_component(&context_card/1,
          ref: "game#39",
          title: "Sound toggle in settings",
          type: "feature",
          steps: ~w(triage review done),
          current: 1,
          facts: ["review · visit 1", "3 jobs"]
        )

      assert text(html, ".ui-context-id") == "game#39"
      assert text(html, ".ui-type-badge") == "feature"
      assert count(html, ".ui-track-step--current") == 1
      assert html |> all(".ui-context-facts span") |> Enum.count() == 2
      # Without a page to go to it is no link, and draws no ›.
      assert count(html, "a") == 0
      refute html =~ "›"
    end

    # A bordered card that did nothing, over a small link that did (`ui.md` § The affordance
    # rule): with `navigate` the card itself is the ticket's link, whole.
    test "context_card with navigate is one link, whole, with its ›" do
      html =
        render_component(&context_card/1,
          ref: "game#39",
          title: "Sound toggle in settings",
          navigate: "/tickets/game/39"
        )

      assert attrs(html, "a.ui-context.ui-context--link", "href") == ["/tickets/game/39"]
      assert count(html, "a.ui-context > .ui-context-head .ui-context-go") == 1
    end

    test "eyebrow, fact_list and notice take their tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.eyebrow tone="success">End of queue</.eyebrow>
        <.fact_list dense>
          <:fact label="turns">14 of 30</:fact>
          <:fact label="check" tone="danger">failed</:fact>
        </.fact_list>
        <.notice tone="danger" title="Does not merge cleanly">main moved.</.notice>
        <.notice title="1 open question">x</.notice>
        """)

      assert count(html, ".ui-eyebrow--success") == 1
      assert text(html, "dd.ui-fact-value--danger") == "failed"
      assert count(html, ".ui-facts--dense dt") == 2
      assert count(html, ".ui-notice--danger .ui-notice-diamond") == 0
      assert count(html, ".ui-notice:not(.ui-notice--danger) .ui-notice-diamond") == 1
    end
  end

  describe "sheet/1" do
    test "is a dialog named for assistive technology, with its title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sheet id="new" label="New in game" title="New in game">rows</.sheet>
        """)

      assert attrs(html, "dialog#new", "aria-label") == ["New in game"]
      assert text(html, ".ui-sheet-title") == "New in game"
      assert attrs(html, "dialog#new", "phx-hook") == ["ForgeWeb.UI.Feedback.Sheet"]
    end

    # `showModal()` focuses the dialog's autofocus descendant: the sheet itself, focusable but out
    # of the tab order, so no row opens wearing the focus ring as if chosen (UX pass, A22).
    test "opens with the focus on the sheet, not its first row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sheet id="new" label="New"><a href="/x">first</a></.sheet>
        """)

      assert attrs(html, "dialog#new .ui-sheet", "tabindex") == ["-1"]
      assert attrs(html, "dialog#new .ui-sheet", "autofocus") != []
      assert attrs(html, "dialog#new a[autofocus]", "href") == []
      assert attrs(html, "dialog#new", "data-focus") == []
    end

    # A sheet whose first act is typing names its field, which the hook focuses with a fine
    # pointer once the sheet is open (UX re-check #10).
    test "names the field that takes the focus, when it has one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.sheet id="branches" label="Branches" focus="#search input"><input /></.sheet>
        """)

      assert attrs(html, "dialog#branches", "data-focus") == ["#search input"]
    end
  end

  describe "Operator.Components.breakable/1" do
    # A clone URL broke as `atlas.gi` / `t` in a narrow column (UX pass, C3, D10), and then after
    # the hyphen of `game-21698` (UX re-check #8): it may break after a `/` or a `:` only, each
    # part between is one unbroken block, it stays escaped, and its text is the value, unchanged.
    test "breaks only after a slash or a colon, escaped, with no text added" do
      html =
        "http://h:0/git/<a>-1.git"
        |> ForgeWeb.Operator.Components.breakable()
        |> Phoenix.HTML.safe_to_string()

      parts =
        html |> String.split("<wbr>") |> Enum.map(&String.replace(&1, ~r{</?span[^>]*>}, ""))

      assert parts == ["http:", "/", "/", "h:", "0/", "git/", "&lt;a&gt;-1.git"]
      assert html =~ ~s(<span class="ui-unbroken">&lt;a&gt;-1.git</span>)
      assert length(String.split(html, ~s(<span class="ui-unbroken">))) == length(parts) + 1
      assert html |> LazyHTML.from_fragment() |> LazyHTML.text() == "http://h:0/git/<a>-1.git"
    end

    test "leaves a value with spaces to break at its spaces" do
      line = "Authorization: Bearer x/y"
      assert ForgeWeb.Operator.Components.breakable(line) == line
    end
  end
end
