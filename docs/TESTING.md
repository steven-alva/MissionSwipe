# Testing MissionSwipe

## Desktop Safety

1. Launch MissionSwipe.
2. Open Xcode, Chrome, Finder, and at least one chat app.
3. Scroll normally in each app.
4. Press `Control + Option + W` on the desktop.
5. Confirm no normal desktop window closes.

Expected logs:

- `Mission Control detection: isLikelyActive=false`
- `Trackpad swipe preflight rejected`
- `Mission Control not active; ignoring close request`

## Mission Control Close

1. Open several windows.
2. Open Mission Control.
3. Hover a window thumbnail.
4. Swipe up on the trackpad.
5. Confirm only the hovered thumbnail closes.
6. Use `Copy Last Close Report` from the menu.

Expected logs:

- `Swipe-up preflight accepted`
- `Trackpad swipe-up detected`
- `Mission Control close succeeded`

## Debug Logs

Keep `Debug Logging` off for normal use. Turn it on only when collecting raw scroll or window matching diagnostics.
