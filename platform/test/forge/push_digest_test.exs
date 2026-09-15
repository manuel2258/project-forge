defmodule Forge.Push.DigestTest do
  @moduledoc """
  The once-a-day queue digest: that it is once a day, and that "a day" begins at the configured
  UTC hour.

  Neither is visible from anywhere else. The process had no test at all, and both of the things
  it does wrong are silent in the direction an operator can look: a digest sent twice is two
  notifications on a phone that nobody reports as a bug, and a digest scheduled at the wrong
  moment simply arrives at the wrong time of day, which reads as the configuration being wrong.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Push
  alias Forge.Push.{Digest, TestSender}

  setup do
    TestSender.watch()
    user = user_fixture()

    {:ok, _subscription} =
      Push.subscribe(user, %{
        "endpoint" => "https://push.example/phone",
        "keys" => %{
          "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      })

    # Something in the queue, or the digest is `:empty` and sends nothing whatever the guard does.
    ticket = ticket_fixture()

    {:ok, _ticket} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    :ok
  end

  # The guard is `if today != last`, and the comment above it says why it is there: "Once per day,
  # however the clock behaves around the tick." A timer that fires twice — a clock stepped
  # backwards, a machine resumed from sleep, a supervisor restart re-arming it — is the ordinary
  # case, not the exotic one, and without the guard every one of them is a second notification on
  # someone's phone for the same day's queue.
  test "a second tick on the same day sends nothing" do
    pid = start_supervised!({Digest, hour_utc: 9})

    assert tick(pid) == :sent
    assert tick(pid) == :silent
  end

  # `schedule/1` is the whole of "at the configured UTC hour", and a GenServer's state says
  # nothing about the timer it armed, so the delay is read off the call that arms it. Waiting for
  # it is not an option: the wait is up to a day.
  #
  # Both sides of the hour, because they take different branches: an hour still to come today is
  # later today, and one that has already gone by is tomorrow. Getting the second wrong is a
  # digest that arrives immediately and then every time the process restarts.
  test "the next tick is the coming hour:00 UTC, whether that is today or tomorrow" do
    later = rem(DateTime.utc_now().hour + 1, 24)
    {now, delay} = arm(later)

    assert delay in 1..3_600_000
    assert_lands_on(now, delay, later)

    earlier = DateTime.utc_now().hour
    {now, delay} = arm(earlier)

    # Already past this hour today, so tomorrow's: a whole day less however much of the hour has
    # gone by.
    assert delay in 82_800_000..86_400_000
    assert_lands_on(now, delay, earlier)
  end

  # One `:digest`, handled, with whatever it sent collected. `:sys.get_state/1` is the wait for
  # the process to have handled it; `Push.flush/0` is the wait for the deliveries it spawned.
  defp tick(pid) do
    send(pid, :digest)
    _state = :sys.get_state(pid)
    Push.flush()

    receive do
      {:push, "https://push.example/phone", %{"tag" => "digest"}, _opts} -> :sent
    after
      0 -> :silent
    end
  end

  # The delay `Digest.init/1` arms its timer with, and the instant it was measured from.
  #
  # Traced rather than inspected because there is nothing to inspect: `Process.send_after/3`
  # returns a reference the process drops, and a BIF timer cannot be read without it. The process
  # reports its own `utc_now/0` first so the reference instant is the one the arithmetic used,
  # give or take a few microseconds, rather than this process's clock some scheduling later.
  defp arm(hour) do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go ->
            send(parent, {:now, DateTime.utc_now()})
            {:ok, _state} = Digest.init(hour_utc: hour)
        end
      end)

    :erlang.trace(pid, true, [:call])
    :erlang.trace_pattern({:erlang, :send_after, 3}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({:erlang, :send_after, 3}, false, [:local]) end)

    send(pid, :go)

    assert_receive {:now, now}
    assert_receive {:trace, ^pid, :call, {:erlang, :send_after, [delay, _dest, :digest]}}

    {now, delay}
  end

  # How far the armed delay may fall short of the distance from `now`. It is scheduling, not
  # arithmetic: `now` is read before `init/1` reads its own clock, and on a loaded machine the
  # gap between two clock readings in the same process is not bounded by anything worth pinning.
  #
  # This used to be two milliseconds — one for `DateTime.diff/3`'s truncation, one for the gap —
  # and reconstructing the firing instant from it asserted `second == 0`. A gap over 2 ms put the
  # reconstruction a hair *before* the hour, so `second` was 59 and the test failed: 2 failures
  # in 18 runs under load, and reproducible every time with a 5 ms sleep between the readings.
  @scheduling_slack 30_000

  # The property, said without recomputing the implementation: the timer is aimed at the top of
  # that hour. Stated as a window on the delay rather than as a reconstructed instant, because
  # the direction of the error is known — `init/1` reads its clock *after* `now`, so the delay it
  # arms can only be shorter than the distance from `now`, never longer.
  #
  # Still tight enough to be the test it claims to be: the two branches are twenty-three hours
  # apart and a wrong hour is out by 3,600,000 ms, so thirty seconds of slack cannot hide either.
  defp assert_lands_on(now, delay, hour) do
    today = %{now | hour: hour, minute: 0, second: 0, microsecond: {0, 0}}
    target = if DateTime.compare(today, now) == :gt, do: today, else: DateTime.add(today, 1, :day)
    from_now = DateTime.diff(target, now, :millisecond)

    assert delay <= from_now,
           "armed #{delay}ms, which is past #{inspect(target)} — later than the clock allows"

    assert delay >= from_now - @scheduling_slack,
           "armed #{delay}ms, but #{inspect(target)} is #{from_now}ms away"
  end
end
