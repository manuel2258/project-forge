defmodule ForgeWeb.UsagePanelTest do
  @moduledoc """
  The usage panel's reset line (`docs/design/capacity.md` § Two objects): when a window resets, as
  a clock time and a countdown a sentence carries.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeWeb.UsagePanel

  # A reset under a minute off is "in under a minute", never "in now" (r3 L3).
  test "a reset under a minute off is said in words" do
    now = ~U[2026-11-10 13:59:30Z]
    window = %{type: "five_hour", resets_at: ~U[2026-11-10 14:00:00Z], pace: nil}

    text =
      render_component(&UsagePanel.reset_line/1, window: window, now: now)
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> String.replace(~r/\s+/, " ")

    assert text =~ "resets 14:00 · in under a minute"

    later = %{window | resets_at: ~U[2026-11-10 15:12:30Z]}
    html = render_component(&UsagePanel.reset_line/1, window: later, now: now)
    assert html =~ "resets 15:12 · in 1h 13m"
  end

  # The panel and `/usage` draw different sets — a project's pool, your own credentials — and each
  # says which, so their figures are not read as one moving (UX pass, D7).
  test "names the set its figures are of" do
    one = %{own: [%{}], others: %{count: 0}}
    pool = %{own: [%{}], others: %{count: 2}}

    assert UsagePanel.set_label(nil, one) == "your 1 credential"
    assert UsagePanel.set_label(nil, %{own: [], others: %{count: 0}}) == "your 0 credentials"
    assert UsagePanel.set_label(%{name: "game"}, pool) == "game's pool · 3 credentials"
  end

  # A figure with a line that has no share — an estimate with no window cost configured — is not
  # handed out: there is nothing to multiply (review fixes 7, L2).
  test "a line with no share is drawn as none, beside a figure" do
    assert [%{shown: "—"}, %{shown: "20%"}] =
             UsagePanel.shown([%{share: nil}, %{share: 0.2}], 0.5)
  end

  # A share is drawn against the whole track; an estimate past one window fills it and no more.
  test "a bar is its share of the track, at most all of it" do
    assert ForgeWeb.UsagePanel.bar(0.303) == 30.3
    assert ForgeWeb.UsagePanel.bar(1.7) == 100.0
    assert ForgeWeb.UsagePanel.bar(nil) == 0
  end
end
