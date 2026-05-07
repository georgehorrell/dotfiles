-- radial.lua
-- The pie/radial menu and its bindings. Self-contained: requiring this
-- module loads the RadialMenu spoon, defines the menu, binds the hotkey
-- and middle-click trigger, and wires the dictation sub-pipeline into it.
--
-- To add a wedge: extend `radialMenu.default` below.
-- To change dictation prompts: edit ./dictation_prompts.lua.

local dictation = require("dictation")
local prompts   = require("dictation_prompts")

hs.loadSpoon("RadialMenu")
spoon.RadialMenu.labelFont = ".AppleSystemUIFont"  -- "SF Pro Text" is unregistered on macOS 13+

-- ── Per-user theme preference ─────────────────────────────────────────
-- "vampire"  — original dark-wedge look
-- "pokemon"  — bright scalloped flower wheel modeled on Pokémon S/V
-- Future: hoist into a settings file when more than one user uses this.
local THEME = "pokemon"
spoon.RadialMenu:setTheme(THEME)
require("dictation_overlay").setTheme(THEME)

local hyper = { "ctrl", "shift", "alt", "cmd" }

-- Icons render as glyphs in flower mode; the classic theme ignores them.
-- iconColor is the tinted disc behind the icon (omit for transparent).
local radialMenu = {
  default = {
    { label = "Dictate",
      icon = "🎙",  iconColor = { red = 0.30, green = 0.62, blue = 0.95, alpha = 1.00 },
      children = {
        { label = "Plain",      icon = "📝", iconColor = { red = 0.30, green = 0.62, blue = 0.95, alpha = 1.00 },
          action = { type = "func", fn = function() dictation.toggle() end } },
        { label = "Casual",     icon = "💬", iconColor = { red = 0.55, green = 0.40, blue = 0.85, alpha = 1.00 },
          action = { type = "func", fn = function() dictation.toggle(prompts.casual) end } },
        { label = "Microphone", icon = "🎚",  iconColor = { red = 0.40, green = 0.65, blue = 0.45, alpha = 1.00 },
          action = { type = "func", fn = function() dictation.pickMicrophone() end } },
      } },
    { label = "Lock Screen",
      icon = "🔒", iconColor = { red = 0.92, green = 0.45, blue = 0.40, alpha = 1.00 },
      action = { type = "applescript",
        script = 'tell application "System Events" to keystroke "q" using {control down, command down}' } },
    { label = "Mission Control",
      icon = "🪟", iconColor = { red = 0.55, green = 0.40, blue = 0.85, alpha = 1.00 },
      action = { type = "func", fn = function() hs.spaces.toggleMissionControl() end } },
    { label = "Terminal",
      icon = "⌨", iconColor = { red = 0.32, green = 0.34, blue = 0.40, alpha = 1.00 },
      action = { type = "launch", app = "Terminal" } },
    { label = "Inbox",
      icon = "📥", iconColor = { red = 0.40, green = 0.70, blue = 0.45, alpha = 1.00 },
      action = { type = "url", url = "obsidian://quickadd?choice=Inbox%20Capture" } },
    { label = "Reload HS",
      icon = "🔄", iconColor = { red = 0.95, green = 0.62, blue = 0.30, alpha = 1.00 },
      action = { type = "func", fn = hs.reload } },
    { label = "Sleep Display",
      icon = "🌙", iconColor = { red = 0.38, green = 0.42, blue = 0.70, alpha = 1.00 },
      action = { type = "shell", cmd = "pmset displaysleepnow" } },
  },
}

spoon.RadialMenu:bindToHotkey(hyper, "space", radialMenu)
spoon.RadialMenu:bindToButton(2, radialMenu)  -- middle-click hold

-- Hook short-click stop, pre-warm STT server + Ollama for prompts we use.
dictation.attachToRadial(spoon.RadialMenu, {
  prewarmPrompts = { prompts.casual },
})
