# RadialMenu.spoon

A Hammerspoon Spoon that turns a held mouse button into a radial (pie) menu.

Hold a configurable mouse button to open a circular menu at the cursor, drag
to a wedge, and release to fire its action. Quick clicks (released before
the hold threshold) pass through as a normal button click, so the underlying
button keeps working.

- App-aware menus: different items per frontmost-app bundle ID, with a
  `default` fallback
- Sub-menus that open on dwell
- Esc, right-click, or a dwell at the center cancels / navigates back
- Action types: keystroke, shell, AppleScript, Lua function, app launch,
  URL, file open

## Requirements

- Hammerspoon 1.0 or later (tested on 1.1.0)
- macOS with the Accessibility permission granted to Hammerspoon (see below)
- A mouse with at least one extra button you can rebind (any button number
  is configurable; the default is "Mouse4" / the back side-button)

## Installation

```sh
mkdir -p ~/.hammerspoon/Spoons/RadialMenu.spoon
cp init.lua README.md ~/.hammerspoon/Spoons/RadialMenu.spoon/
```

Then in `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("RadialMenu")
spoon.RadialMenu:bindToButton(3, {
  default = {
    { label = "Reload HS",  action = { type = "func", fn = hs.reload } },
    { label = "Lock",       action = { type = "applescript",
        script = 'tell application "System Events" to keystroke "q" using {control down, command down}' } },
    { label = "Terminal",   action = { type = "launch", app = "Terminal" } },
  },
})
```

Reload your config (`Cmd+Shift+R` in the Hammerspoon menubar, or
`hs.reload()` in the console) and hold your side button. A pie menu should
appear at the cursor.

## Identifying your button number

`bindToButton` takes the **raw 0-indexed macOS button number** — the value
returned by `event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)`.
Common defaults:

| Mouse button   | Raw number |
|----------------|------------|
| Left           | 0          |
| Right          | 1          |
| Middle / wheel | 2          |
| Mouse4 (back)  | 3          |
| Mouse5 (fwd)   | 4          |

If you're unsure, RadialMenu logs any `otherMouseDown` whose button doesn't
match your configured value. After loading the Spoon, watch the Hammerspoon
console while pressing your desired button — you'll see something like:

```
[RadialMenu] saw otherMouseDown on button 4 (configured: 3). If this is the
button you want, call bindToButton(4, ...).
```

## Full configuration example

```lua
hs.loadSpoon("RadialMenu")

-- Optional: override visual / timing defaults before binding
spoon.RadialMenu.holdThreshold = 0.18
spoon.RadialMenu.dwellTime     = 0.25
spoon.RadialMenu.radius        = 110
spoon.RadialMenu.deadZoneRadius = 28

spoon.RadialMenu:bindToButton(3, {
  ["com.apple.Safari"] = {
    { label = "Reload",  action = { type = "keystroke", mods = {"cmd"}, key = "r" } },
    { label = "New Tab", action = { type = "keystroke", mods = {"cmd"}, key = "t" } },
    { label = "Tabs", children = {
        { label = "Next", action = { type = "keystroke", mods = {"ctrl"},          key = "tab" } },
        { label = "Prev", action = { type = "keystroke", mods = {"ctrl","shift"}, key = "tab" } },
    }},
    { label = "History", children = {
        { label = "Back",    action = { type = "keystroke", mods = {"cmd"}, key = "[" } },
        { label = "Forward", action = { type = "keystroke", mods = {"cmd"}, key = "]" } },
    }},
  },

  default = {
    { label = "Mission Control", action = { type = "func",
        fn = function() hs.spaces.toggleMissionControl() end } },
    { label = "Lock Screen",     action = { type = "applescript",
        script = 'tell application "System Events" to keystroke "q" using {control down, command down}' } },
    { label = "Terminal",        action = { type = "launch", app = "Terminal" } },
    { label = "Reload HS",       action = { type = "func", fn = hs.reload } },
  },
})
```

## Action types

| `type`        | Required fields                   | Notes |
|---------------|-----------------------------------|-------|
| `keystroke`   | `mods` (table), `key` (string)    | Forwarded to `hs.eventtap.keyStroke`. Optional `delay`. |
| `shell`       | `cmd` (string)                    | Run async via `/bin/sh -c`. |
| `applescript` | `script` (string)                 | Run via `hs.osascript.applescript`. |
| `func`        | `fn` (function)                   | Called with no args. |
| `launch`      | `app` (string)                    | App name or bundle ID. |
| `url`         | `url` (string)                    | Passed to `hs.urlevent.openURL`. |
| `open`        | `path` (string)                   | File or directory; passed to `/usr/bin/open`. |

## Sub-menus

A wedge with a `children` array opens a sub-menu instead of firing an action.

- **Open**: hover over the wedge for `dwellTime` seconds (default 0.25). The
  sub-menu re-centers at the current cursor position.
- **Go back**: right-click, or hover in the central dead zone for the same
  dwell duration. The breadcrumb arrow `←` appears in the dead zone when you
  can go back.
- **Close completely**: release the button anywhere in the dead zone, or
  press Esc.

Sub-menu wedges are tinted green and marked with `▸` after the label.

> Releasing the button on a `▸` wedge does **not** open the sub-menu — the
> press-and-hold model means the interaction ends on release. Use dwell to
> drill in, then release on a leaf to commit.

## Configuration reference

All variables are top-level on the Spoon and may be set before or after
`bindToButton`:

| Variable               | Default                                | Description                                     |
|------------------------|----------------------------------------|-------------------------------------------------|
| `buttonNumber`         | `3`                                    | Raw 0-indexed macOS button number               |
| `holdThreshold`        | `0.18`                                 | Seconds to hold before menu opens               |
| `dwellTime`            | `0.25`                                 | Seconds to dwell over a sub-menu wedge          |
| `radius`               | `110`                                  | Outer menu radius in points                     |
| `deadZoneRadius`       | `28`                                   | Center dead-zone radius                         |
| `labelFont`            | `"Helvetica Neue"`                     | Wedge label font                                |
| `labelSize`            | `13`                                   | Wedge label font size                           |
| `wedgeColor`           | dark blue-grey, ɑ 0.88                 | Inactive wedge fill                             |
| `activeWedgeColor`     | accent blue, ɑ 0.92                    | Highlighted wedge fill                          |
| `subMenuWedgeColor`    | green, ɑ 0.88                          | Wedge with `children`                           |
| `deadZoneColor`        | near-black, ɑ 0.90                     | Center dead-zone disc                           |
| `separatorColor`       | translucent blue                       | Stroke between wedges                           |
| `labelColor`           | near-white                             | Label text                                      |

## Accessibility permission

RadialMenu uses `hs.eventtap`, which **requires** the macOS Accessibility
permission. Without it, mouse button presses are not intercepted and the
menu will never open.

To grant it:

1. **System Settings → Privacy & Security → Accessibility**
2. Make sure **Hammerspoon** is in the list and toggled on.
3. Restart Hammerspoon (or reload your config).

If you've recently updated Hammerspoon, macOS may silently revoke the
permission — re-tick the box.

## Troubleshooting

| Symptom                                       | Likely cause                              | Fix                                                        |
|-----------------------------------------------|-------------------------------------------|------------------------------------------------------------|
| Menu never appears                            | Wrong `buttonNumber`                      | Watch the console log; use the button reported there       |
| Menu never appears, no log output             | Accessibility permission revoked          | Re-grant in System Settings                                |
| Side button still does back/forward in browser | Quick-click pass-through is working — that's expected for short presses | Hold longer than `holdThreshold` (default 180 ms)          |
| Sub-menu doesn't open                         | Hovering too briefly                      | Increase `dwellTime` or hover longer                       |
| Menu flickers while moving                    | Normal — canvas is rebuilt on each wedge change | Cosmetic only                                            |
| Action types print "unknown action type: …"   | Typo in `action.type`                     | Check the action types table above                         |

## Known limitations (v0.1.0)

- **20 ms re-injection blackout**: while a quick-click is being replayed,
  another genuine click in the same window passes through unprocessed
  (no menu). Imperceptible in normal use.
- **Multi-screen edges**: the menu always opens at the cursor position. Near
  a screen edge, part of the canvas may be clipped. No clamping in v1.
- **Sub-menus open on dwell only** — releasing the button on a `▸` wedge
  closes the menu silently. This is intentional for the press-and-hold
  interaction model.
- **Lost-click recovery**: if the frontmost app has no entry and there is
  no `default`, the swallowed press is replayed so the app receives a
  normal click. Configure a `default` menu to avoid relying on this.
- Text-only labels (no icons / SF Symbols). Planned for a future version.

## API

| Method                                    | Description                                            |
|-------------------------------------------|--------------------------------------------------------|
| `RadialMenu:bindToButton(button, menuMap)` | Set the trigger button and menus, then start. `button` may be omitted to use the current `buttonNumber`. |
| `RadialMenu:start()`                       | (Re)create and start the event taps. Idempotent.       |
| `RadialMenu:stop()`                        | Stop all taps and close any open menu.                 |

## Examples

### Minimal — one item, default menu

```lua
hs.loadSpoon("RadialMenu")
spoon.RadialMenu:bindToButton(3, {
  default = {
    { label = "Hello", action = { type = "func", fn = function() hs.alert("hi") end } },
  },
})
```

### Safari-specific menu with sub-menu

```lua
spoon.RadialMenu:bindToButton(3, {
  ["com.apple.Safari"] = {
    { label = "Reload",  action = { type = "keystroke", mods = {"cmd"}, key = "r" } },
    { label = "Tabs", children = {
        { label = "Next", action = { type = "keystroke", mods = {"ctrl"},          key = "tab" } },
        { label = "Prev", action = { type = "keystroke", mods = {"ctrl","shift"}, key = "tab" } },
        { label = "Close",action = { type = "keystroke", mods = {"cmd"}, key = "w" } },
    }},
    { label = "Bookmarks", action = { type = "url", url = "x-safari-https://" } },
  },
  default = {
    { label = "Reload HS", action = { type = "func", fn = hs.reload } },
  },
})
```

## License

MIT
