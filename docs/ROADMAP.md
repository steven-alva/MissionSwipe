# Roadmap

## Near Term

- Add an in-app diagnostics panel for recent close attempts.
- Make swipe threshold and cooldown configurable.
- Persist a small ring buffer of recent close reports.
- Reduce console logging further for non-debug builds.

## Later

- Improve same-app, same-title window matching.
- Add signed and notarized releases.
- Add automatic update support.
- Explore a visible Mission Control overlay only if public APIs can keep it safe.

## Product Boundary

MissionSwipe should stay Mission Control only. Normal desktop window closing is out of scope unless it becomes an explicit separate mode.
