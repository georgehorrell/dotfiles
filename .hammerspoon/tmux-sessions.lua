local M = {}

local configPath = os.getenv("HOME") .. "/.tmux-slots.json"
local tmux = "/opt/homebrew/bin/tmux"
local hyper = {"ctrl", "shift", "alt", "cmd"}

local function shellquote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function loadConfig()
    local f = io.open(configPath, "r")
    if not f then
        hs.alert.show("tmux-slots: config not found at " .. configPath)
        return nil
    end
    local content = f:read("*a")
    f:close()
    local ok, config = pcall(hs.json.decode, content)
    if not ok or not config then
        hs.alert.show("tmux-slots: invalid JSON in " .. configPath)
        return nil
    end
    return config
end

local function switchTmuxSession(slot)
    local session = slot.session
    local target = session
    if slot.window then
        target = target .. ":" .. slot.window
    end
    if slot.pane then
        target = target .. "." .. slot.pane
    end

    local qs = shellquote(session)
    local qt = shellquote(target)

    -- Ensure session exists
    os.execute(tmux .. " has-session -t " .. qs .. " 2>/dev/null || " ..
               tmux .. " new-session -d -s " .. qs)

    -- Check if a client is already attached to this specific session
    local tty = hs.execute(tmux .. " list-clients -t " .. qs .. " -F '#{client_tty}' 2>/dev/null")
    tty = tty and tty:match("^%S+")

    if tty then
        -- Raise the iTerm window that has this session
        hs.osascript.applescript(string.format(
            'tell application "iTerm2"\n' ..
            '  activate\n' ..
            '  repeat with w in windows\n' ..
            '    repeat with t in tabs of w\n' ..
            '      repeat with s in sessions of t\n' ..
            '        if tty of s is "%s" then\n' ..
            '          select t\n' ..
            '          set index of w to 1\n' ..
            '          return\n' ..
            '        end if\n' ..
            '      end repeat\n' ..
            '    end repeat\n' ..
            '  end repeat\n' ..
            'end tell', tty))
    else
        -- No client on this session — open new iTerm window attached to it
        hs.execute(
            "osascript -e 'tell application \"iTerm2\" to activate'" ..
            " -e 'tell application \"iTerm2\" to create window with default profile command \"" ..
            tmux .. " attach-session -t " .. qt .. "\"'"
        )
    end
end

local bindings = {}

function M.bindKeys()
    -- Unbind previous bindings
    for _, hk in ipairs(bindings) do
        hk:delete()
    end
    bindings = {}

    local config = loadConfig()
    if not config then return end

    for key, slot in pairs(config) do
        local hk = hs.hotkey.bind(hyper, key, function()
            switchTmuxSession(slot)
        end)
        table.insert(bindings, hk)
    end

    -- Hyper+R to reload config
    local reloadHk = hs.hotkey.bind(hyper, "r", function()
        M.bindKeys()
        hs.alert.show("tmux-slots: config reloaded")
    end)
    table.insert(bindings, reloadHk)

    hs.alert.show("tmux-slots: " .. tostring(#bindings - 1) .. " slots loaded")
end

M.bindKeys()

return M
