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

    -- Ensure session exists (with optional start directory)
    local startDir = slot.startDir or os.getenv("HOME")
    local qd = shellquote(startDir)
    os.execute(tmux .. " has-session -t " .. qs .. " 2>/dev/null || " ..
               tmux .. " new-session -d -s " .. qs .. " -c " .. qd)

    -- Check if this session's window already has an iTerm2 tab (via CC mode)
    -- Get the tmux window ID for the target
    local windowIdRaw = hs.execute(tmux .. " display-message -t " .. qt .. " -p '#{window_id}' 2>/dev/null")
    local windowId = windowIdRaw and windowIdRaw:match("@(%d+)")

    if windowId then
        -- Get the control client TTY for this session (if CC attached)
        local clientTty = hs.execute(tmux .. " list-clients -t " .. qs .. " -F '#{client_tty}' 2>/dev/null")
        clientTty = clientTty and clientTty:match("/dev/ttys%d+")

        if clientTty then
            -- Find the iTerm2 window with the control pane on this TTY
            -- Then find the matching content window (same [tmux (N)] suffix)
            local success, result = hs.osascript.applescript(string.format([[
                tell application "iTerm2"
                    -- Find the window name pattern for our control pane
                    set targetPattern to ""
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    if tty of s is "%s" then
                                        -- Found control pane, extract [tmux...] pattern from window name
                                        set winName to name of w
                                        -- Pattern is like "[↣ tmux tmux (3)]" - we want "tmux (3)" or just "tmux"
                                        if winName contains "[" then
                                            set targetPattern to winName
                                        end if
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat

                    if targetPattern is "" then
                        return "no control pane found"
                    end if

                    -- Now find content window with similar pattern (without the brackets)
                    -- Control: "[↣ tmux tmux (3)]" -> Content: "↣ zsh [tmux (3)]"
                    repeat with w in windows
                        set winName to name of w
                        -- Content windows have pattern like "↣ ... [tmux (N)]" without leading bracket
                        if winName does not start with "[" and winName contains "tmux" then
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s is missing value then
                                        -- This is a CC content session
                                        -- Check if the tmux pattern matches
                                        if targetPattern contains "tmux]" and winName contains "tmux]" then
                                            activate
                                            select t
                                            set index of w to 1
                                            return "found"
                                        else if targetPattern contains "tmux (" then
                                            -- Extract the number
                                            set tid to text ((offset of "tmux (" in targetPattern) + 6) thru ((offset of ")]" in targetPattern) - 1) of targetPattern
                                            if winName contains ("tmux (" & tid & ")") then
                                                activate
                                                select t
                                                set index of w to 1
                                                return "found"
                                            end if
                                        end if
                                    end if
                                end repeat
                            end repeat
                        end if
                    end repeat
                    return "no content window: " & targetPattern
                end tell
            ]], clientTty))

            if success and result == "found" then
                return
            end
        end
    end

    -- No existing iTerm2 tab for this window — create new CC connection
    -- Use -d to detach any existing clients
    hs.execute(
        "osascript -e 'tell application \"iTerm2\" to activate'" ..
        " -e 'tell application \"iTerm2\" to create window with default profile command \"" ..
        tmux .. " -CC attach-session -d -t " .. qt .. "\"'"
    )

    -- After CC connects, minimize control pane and fullscreen content windows
    hs.timer.doAfter(0.8, function()
            hs.osascript.applescript([[
                tell application "iTerm2"
                    set contentWindows to {}
                    set controlWindows to {}

                    repeat with w in windows
                        set hasTmuxContent to false
                        set isControlPane to false

                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    -- Sessions with tmux integration have a tmux window id
                                    set twid to tmux window id of s
                                    if twid is not missing value and twid is not "" then
                                        set hasTmuxContent to true
                                    end if
                                end try
                                -- Control pane has no tmux window id but runs tmux -CC
                                if name of s contains "tmux" then
                                    set isControlPane to true
                                end if
                            end repeat
                        end repeat

                        if hasTmuxContent then
                            set end of contentWindows to w
                        else if isControlPane then
                            set end of controlWindows to w
                        end if
                    end repeat

                    -- Minimize control windows
                    repeat with cw in controlWindows
                        set miniaturized of cw to true
                    end repeat

                    -- Fullscreen content windows
                    repeat with tw in contentWindows
                        if (zoomed of tw) is false then
                            set zoomed of tw to true
                        end if
                        set index of tw to 1
                    end repeat
                end tell
            ]])
    end)
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

local function getClaudeStatus(tmuxPane)
    -- Check for Claude Code status file for this pane
    local statusDir = os.getenv("HOME") .. "/.claude-status"
    local statusFile = statusDir .. "/" .. tmuxPane:gsub("[:%.]", "-") .. ".json"
    local f = io.open(statusFile, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local ok, status = pcall(hs.json.decode, content)
    if ok and status then
        return status
    end
    return nil
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

    -- Check for Claude Code status
    local claudeStatus = getClaudeStatus(target)

    return { cmd = cmd, path = path, claude = claudeStatus }
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
                claude = info.claude,
            })
        else
            table.insert(lines, {
                key = string.upper(key),
                session = slot.session,
                cmd = "not running",
                path = "",
                claude = nil,
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
        local badgeBg = { red = 0.3, green = 0.3, blue = 0.35, alpha = alpha }
        -- If Claude is waiting, highlight the badge
        if line.claude and line.claude.waiting then
            badgeBg = { red = 0.8, green = 0.5, blue = 0.1, alpha = 0.9 }
        elseif line.claude then
            badgeBg = { red = 0.2, green = 0.5, blue = 0.3, alpha = 0.9 }
        end
        overlay:appendElements({
            type = "rectangle",
            action = "fill",
            frame = { x = padding, y = rowY + 6, w = 32, h = 28 },
            roundedRectRadii = { xRadius = 6, yRadius = 6 },
            fillColor = badgeBg,
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

        -- Session name + command (with Claude indicator)
        local detail = line.session .. "  ·  " .. line.cmd
        if line.claude then
            if line.claude.waiting then
                detail = detail .. "  [WAITING]"
            else
                detail = detail .. "  [claude]"
            end
        end
        overlay:appendElements({
            type = "text",
            text = hs.styledtext.new(detail, {
                font = { name = "Menlo", size = 13 },
                color = { red = 1, green = 1, blue = 1, alpha = alpha },
            }),
            frame = { x = padding + 44, y = rowY + 4, w = width - padding * 2 - 44, h = 20 },
        })

        -- Path (use Claude cwd if available, otherwise tmux path)
        local displayPath = line.path
        if line.claude and line.claude.cwd then
            local home = os.getenv("HOME")
            displayPath = line.claude.cwd
            if home and displayPath:sub(1, #home) == home then
                displayPath = "~" .. displayPath:sub(#home + 1)
            end
        end
        if displayPath ~= "" then
            overlay:appendElements({
                type = "text",
                text = hs.styledtext.new(displayPath, {
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
