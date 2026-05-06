-- Obsidian Inbox Capture
-- Hyper+I: foregrounds Obsidian and runs the QuickAdd "Inbox Capture" macro,
-- which appends a fresh timestamp header to inbox.md and positions the cursor
-- ready to type. Activate Wispr Flow yourself (mouse button or keyboard) to
-- dictate into the prepared cursor location.

local hyper = {"ctrl", "shift", "alt", "cmd"}

local QUICKADD_URL = "obsidian://quickadd?choice=Inbox%20Capture"

hs.hotkey.bind(hyper, "i", function()
    print("[inbox-capture] hyper+i pressed, opening Obsidian inbox")
    hs.urlevent.openURL(QUICKADD_URL)
end)
