# Roadmap

## Near Term

- Add an in-app diagnostics panel for recent close/minimize attempts.
- Make swipe threshold and cooldown configurable.
- Persist a small ring buffer of recent action reports.
- Reduce console logging further for non-debug builds.

## Later

- Improve same-app, same-title window matching.
- Add signed and notarized releases.
- Add automatic update support.
- Explore a visible Mission Control overlay only if public APIs can keep it safe.

## Smart Fit future optimizations

These are the B-path "smarter packing" ideas captured from product brainstorms.
Keep them in mind when Smart Fit feels too aggressive at minimizing windows
that could have been laid out cleverly.

- **Per-app minimum size learning.** Each arrange measures each app's actual
  refused-to-shrink size. Persist a small `App bundle id -> min size` table in
  preferences. Next arrange uses those numbers up-front instead of trying to
  squeeze them and bouncing back. Cheap diff, no risky APIs.
- **2D guillotine / bin-packing layouts.** Replace the greedy row-packer in the
  adaptive second pass with a real 2D packer that can produce L- and T-shaped
  arrangements (e.g., Codex column on the left + three stacked on the right).
  Lifts the ceiling on how many real-size windows can coexist on one screen
  before Smart Fit has to fall back to an overflow strategy.
- **Window merging into tabs.** Drive macOS's native window-merge for apps
  that support it (Finder, Safari, many native apps) so N windows become K
  tabbed containers, lowering the count Smart Fit has to satisfy. Skip apps
  like Chrome that don't honor the merge action.

## Product Boundary

MissionSwipe should stay Mission Control only. Normal desktop window closing is out of scope unless it becomes an explicit separate mode.
