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

local hyper = { "ctrl", "shift", "alt", "cmd" }

local radialMenu = {
  default = {
    -- Dictation sub-radial. First wedge (top, "up-up") = plain dictate.
    { label = "Dictate", children = {
        { label = "Plain",      action = { type = "func", fn = function() dictation.toggle() end } },
        { label = "Casual",     action = { type = "func", fn = function() dictation.toggle(prompts.casual) end } },
        { label = "Microphone", action = { type = "func", fn = function() dictation.pickMicrophone() end } },
    } },
    { label = "Lock Screen",     action = { type = "applescript",
        script = 'tell application "System Events" to keystroke "q" using {control down, command down}' } },
    { label = "Mission Control", action = { type = "func",
        fn = function() hs.spaces.toggleMissionControl() end } },
    { label = "Terminal",        action = { type = "launch", app = "Terminal" } },
    { label = "Inbox",           action = { type = "url",
        url = "obsidian://quickadd?choice=Inbox%20Capture" } },
    { label = "Reload HS",       action = { type = "func",   fn = hs.reload } },
    { label = "Sleep Display",   action = { type = "shell",  cmd = "pmset displaysleepnow" } },
  },
}

spoon.RadialMenu:bindToHotkey(hyper, "space", radialMenu)
spoon.RadialMenu:bindToButton(2, radialMenu)  -- middle-click hold

-- Hook short-click stop, pre-warm STT server + Ollama for prompts we use.
dictation.attachToRadial(spoon.RadialMenu, {
  prewarmPrompts = { prompts.casual },
})
