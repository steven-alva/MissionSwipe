# Contributing

MissionSwipe is intentionally narrow: it should act on hovered Mission Control thumbnails and avoid touching normal desktop windows.

Before opening a pull request:

1. Run `scripts/build_app.sh`.
2. Test normal desktop scrolling and confirm no windows close.
3. Test Mission Control swipe-up and confirm one swipe closes at most one thumbnail.
4. Test experimental Mission Control swipe-down if the change touches gestures or AX actions.
5. Include the `Copy Last Action Report` output when reporting selection bugs.

Useful issue details:

- macOS version
- Mac model and chip
- External display layout
- Natural scrolling setting
- App/window type that failed
- Whether `Debug Logging` was enabled
