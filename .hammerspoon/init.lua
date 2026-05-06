-- Global Hammerspoon config (tracked by yadm)
require("tmux-sessions")
require("ergodox-overlay")
require("inbox-capture")
require("radial")
require("claude-approve")

-- Hyper key definition
local hyper = {"ctrl", "shift", "alt", "cmd"}

-- Hyper+C: Clear Claude Code session (works in vim normal or insert mode)
hs.hotkey.bind(hyper, "c", function()
    -- Escape to ensure normal mode, then 'dd' to delete line, 'i' to insert
    -- Using longer delays for Claude Code's high latency
    hs.eventtap.keyStroke({}, "escape")
    hs.timer.usleep(200000) -- 200ms
    hs.eventtap.keyStroke({}, "d")
    hs.eventtap.keyStroke({}, "d")
    hs.timer.usleep(200000) -- 200ms
    hs.eventtap.keyStroke({}, "i")
    hs.timer.usleep(200000) -- 200ms
    hs.eventtap.keyStrokes("/clear")
    hs.timer.usleep(200000) -- 200ms
    hs.eventtap.keyStroke({}, "return")
end)

-- Register hyper keys with ergodox overlay
local overlay = require("ergodox-overlay")
overlay.registerHyperKey("c", "clr cc", "fn")
overlay.registerHyperKey("y", "cc yes", "fn")
overlay.registerHyperKey("n", "cc no", "fn")

-- Load custom config if present (not tracked by yadm)
local ok, err = pcall(require, "custom")
if not ok then
    -- Only warn if file exists but failed to load (syntax error, etc.)
    local customPath = hs.configdir .. "/custom.lua"
    if hs.fs.attributes(customPath) then
        hs.notify.new({
            title = "Hammerspoon",
            informativeText = "Error loading custom.lua: " .. tostring(err),
            withdrawAfter = 5
        }):send()
    end
end
