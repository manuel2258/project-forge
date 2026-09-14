defmodule ForgeWeb.AssertionProbeTest do
  @moduledoc """
  A test about the tests.

  `assert html =~ "..."` matches against a whole rendered page — the nav, the theme switcher, the
  CSRF token, every Tailwind class name — and not against the feature under test. When the string
  is short and generic it matches something the layout supplies, and the assertion can never fail.

  Three did exactly that on one branch. Each was found by breaking the production code and
  watching the test pass anyway; each is listed below with what it actually matched. This file is
  the cheap net that catches the next one, and the list grows whenever another gets through.

  It is a net and not a proof: it only sees bare string literals, so
  `assert html =~ project.default_branch` — `"main"`, which matches `data-phx-main` — slips past
  it. The rule that catches everything is in `AGENTS.md` § Testing: watch a new test fail before
  trusting it.
  """

  use ExUnit.Case, async: true

  # What each string matches on *every* rendered page, whatever the test thought it was checking.
  @layout_vocabulary %{
    "initial" => ~s(matches `initial-scale=1` in the root layout's viewport meta tag),
    "disabled" => ~s(matches the `disabled:` Tailwind variant in any class list),
    "main" => ~s(matches `data-phx-main` on every LiveView root),
    "error" => ~s(matches flash and form-error markup the layout renders unconditionally),
    "true" => ~s(matches any boolean attribute rendered into the markup),
    "forge" => ~s(matches the product name in the header of every page)
  }

  # Only a bare literal on the right of `=~`. A test asserting on data it created itself —
  # `html =~ ticket.title` — is the shape this is trying to encourage, and is not matched.
  @probe ~r/=~\s+"([^"\\]*)"/

  # Only the tests that render a page. An API test asserting a JSON error detail contains
  # "main" is asserting on a branch name, not fooling itself with the layout.
  #
  # And not a comment: the first thing written here flagged the sentence explaining why
  # `html =~ "disabled"` is wrong, which is the one place it ought to appear.
  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "#")

  test "no page test probes for a string the layout supplies anyway" do
    offenders =
      for path <- Path.wildcard("test/forge_web/live/**/*_test.exs"),
          Path.basename(path) != "assertion_probe_test.exs",
          {line, number} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          not comment?(line),
          [_whole, literal] <- Regex.scan(@probe, line),
          reason = @layout_vocabulary[literal] do
        "  #{path}:#{number}\n      =~ #{inspect(literal)} #{reason}"
      end

    assert offenders == [],
           """
           These assertions cannot fail: the string is on every rendered page.

           #{Enum.join(offenders, "\n")}

           Use `has_element?(view, selector)` and assert on placement, or assert on data the
           test itself created. See AGENTS.md § Testing.
           """
  end

  test "the net catches the assertions that got through before" do
    # The regression this file exists for, as it was actually written.
    assert [[_, "initial"]] = Regex.scan(@probe, ~s|    assert html =~ "initial"|)
    assert [[_, "disabled"]] = Regex.scan(@probe, ~s|      assert html =~ "disabled"|)

    # And what it must not flag: a distinctive literal, and data the test made.
    assert Regex.scan(@probe, ~s|assert html =~ "Not ready for a ticket"|)
           |> Enum.all?(fn [_, literal] -> is_nil(@layout_vocabulary[literal]) end)

    assert Regex.scan(@probe, ~s|assert html =~ ticket.title|) == []

    # And a comment about a bad assertion is not itself one.
    assert comment?(~s|      # so `html =~ "disabled"` would pass however the control behaved.|)
    refute comment?(~s|      assert html =~ "disabled"|)
  end
end
