-- Global Hammerspoon config (tracked by yadm)
require("tmux-sessions")
require("ergodox-overlay")

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
