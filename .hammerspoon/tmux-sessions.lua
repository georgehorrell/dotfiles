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
local overlay = nil
local overlayTap = nil
local overlayTimer = nil

local function dismissOverlay()
    if overlay then overlay:delete(); overlay = nil end
    if overlayTap then overlayTap:stop(); overlayTap = nil end
    if overlayTimer then overlayTimer:stop(); overlayTimer = nil end
end

local function getPaneInfo(slot)
    local target = slot.session
    if slot.window then target = target .. ":" .. slot.window end
    if slot.pane then target = target .. "." .. slot.pane end
    local qt = shellquote(target)

    -- Check if session exists
    local _, ok = hs.execute(tmux .. " has-session -t " .. shellquote(slot.session) .. " 2>/dev/null")
    if not ok then return nil end

    local cmd = hs.execute(tmux .. " display-message -t " .. qt .. " -p '#{pane_current_command}' 2>/dev/null")
    local path = hs.execute(tmux .. " display-message -t " .. qt .. " -p '#{pane_current_path}' 2>/dev/null")
    cmd = cmd and cmd:match("^%S+") or "—"
    path = path and path:match("^(.-)%s*$") or ""
    -- Shorten home dir
    local home = os.getenv("HOME")
    if home and path:sub(1, #home) == home then
        path = "~" .. path:sub(#home + 1)
    end
    return { cmd = cmd, path = path }
end

local function showOverlay()
    dismissOverlay()
    local config = loadConfig()
    if not config then return end
    local activeConfig = config

    -- Gather info for each slot, sorted by qwerty keyboard order
    local qwertyOrder = "1234567890qwertyuiopasdfghjklzxcvbnm"
    local keyRank = {}
    for i = 1, #qwertyOrder do keyRank[qwertyOrder:sub(i, i)] = i end
    local keys = {}
    for key in pairs(config) do table.insert(keys, key) end
    table.sort(keys, function(a, b)
        return (keyRank[a] or 999) < (keyRank[b] or 999)
    end)

    local lines = {}
    for _, key in ipairs(keys) do
        local slot = config[key]
        local info = getPaneInfo(slot)
        if info then
            table.insert(lines, {
                key = string.upper(key),
                session = slot.session,
                cmd = info.cmd,
                path = info.path,
            })
        else
            table.insert(lines, {
                key = string.upper(key),
                session = slot.session,
                cmd = "not running",
                path = "",
            })
        end
    end

    -- Layout constants
    local rowHeight = 44
    local padding = 20
    local width = 480
    local headerHeight = 48
    local height = headerHeight + (#lines * rowHeight) + padding

    local screen = hs.screen.mainScreen():frame()
    local x = screen.x + (screen.w - width) / 2
    local y = screen.y + (screen.h - height) / 2

    overlay = hs.canvas.new({ x = x, y = y, w = width, h = height })

    -- Background
    overlay:appendElements({
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 12, yRadius = 12 },
        fillColor = { red = 0.1, green = 0.1, blue = 0.12, alpha = 0.92 },
    })

    -- Title
    overlay:appendElements({
        type = "text",
        text = hs.styledtext.new("tmux slots", {
            font = { name = "Helvetica Neue", size = 18 },
            color = { red = 1, green = 1, blue = 1, alpha = 0.9 },
            paragraphStyle = { alignment = "center" },
        }),
        frame = { x = 0, y = padding * 0.6, w = width, h = 30 },
    })

    -- Rows
    for i, line in ipairs(lines) do
        local rowY = headerHeight + (i - 1) * rowHeight
        local dimmed = line.cmd == "not running"
        local alpha = dimmed and 0.4 or 0.9

        -- Key badge
        overlay:appendElements({
            type = "rectangle",
            action = "fill",
            frame = { x = padding, y = rowY + 6, w = 32, h = 28 },
            roundedRectRadii = { xRadius = 6, yRadius = 6 },
            fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = alpha },
        })
        overlay:appendElements({
            type = "text",
            text = hs.styledtext.new(line.key, {
                font = { name = "Menlo", size = 14 },
                color = { red = 1, green = 1, blue = 1, alpha = alpha },
                paragraphStyle = { alignment = "center" },
            }),
            frame = { x = padding, y = rowY + 9, w = 32, h = 22 },
        })

        -- Session name + command
        local detail = line.session .. "  ·  " .. line.cmd
        overlay:appendElements({
            type = "text",
            text = hs.styledtext.new(detail, {
                font = { name = "Menlo", size = 13 },
                color = { red = 1, green = 1, blue = 1, alpha = alpha },
            }),
            frame = { x = padding + 44, y = rowY + 4, w = width - padding * 2 - 44, h = 20 },
        })

        -- Path
        if line.path ~= "" then
            overlay:appendElements({
                type = "text",
                text = hs.styledtext.new(line.path, {
                    font = { name = "Menlo", size = 11 },
                    color = { red = 0.6, green = 0.6, blue = 0.65, alpha = alpha },
                }),
                frame = { x = padding + 44, y = rowY + 23, w = width - padding * 2 - 44, h = 18 },
            })
        end
    end

    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    overlay:show()

    -- Dismiss on any keypress; if it matches a slot, switch to it
    overlayTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
        local key = event:getCharacters():lower()
        local slot = activeConfig[key]
        dismissOverlay()
        if slot then
            switchTmuxSession(slot)
            return true
        end
        return false
    end)
    overlayTap:start()

    -- Auto-dismiss after 5 seconds
    overlayTimer = hs.timer.doAfter(5, dismissOverlay)
end

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

    -- Hyper+L to show slot overview
    local listHk = hs.hotkey.bind(hyper, "l", function()
        showOverlay()
    end)
    table.insert(bindings, listHk)

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
