-- Ergodox Keyboard Layout Overlay (pre-built canvases, instant show/hide)
-- Toggle with Hyper+O

local M = {}

local hyper = {"ctrl", "shift", "alt", "cmd"}
local canvases = {}  -- pre-built canvas per layer
local overlayTap = nil
local currentLayer = 0
local visible = false

-- Colors
local bg        = { red = 0.04, green = 0.06, blue = 0.10, alpha = 0.94 }
local keyBg     = { red = 0.12, green = 0.16, blue = 0.24, alpha = 0.90 }
local keyBorder = { red = 0.30, green = 0.40, blue = 0.55, alpha = 0.30 }
local modBg     = { red = 0.20, green = 0.12, blue = 0.28, alpha = 0.90 }
local modBorder = { red = 0.50, green = 0.30, blue = 0.65, alpha = 0.35 }
local modText   = { red = 0.76, green = 0.63, blue = 1.00, alpha = 1.0 }
local fnBg      = { red = 0.10, green = 0.22, blue = 0.15, alpha = 0.90 }
local fnBorder  = { red = 0.30, green = 0.60, blue = 0.40, alpha = 0.35 }
local fnText    = { red = 0.50, green = 0.88, blue = 0.63, alpha = 1.0 }
local navBg     = { red = 0.22, green = 0.18, blue = 0.08, alpha = 0.90 }
local navBorder = { red = 0.60, green = 0.50, blue = 0.25, alpha = 0.35 }
local navText   = { red = 0.88, green = 0.78, blue = 0.38, alpha = 1.0 }
local specBg    = { red = 0.22, green = 0.10, blue = 0.10, alpha = 0.90 }
local specBorder= { red = 0.65, green = 0.30, blue = 0.30, alpha = 0.35 }
local specText  = { red = 1.00, green = 0.56, blue = 0.56, alpha = 1.0 }
local emptyBg   = { red = 0.08, green = 0.10, blue = 0.14, alpha = 0.40 }
local emptyBdr  = { red = 0.20, green = 0.25, blue = 0.35, alpha = 0.20 }
local white     = { red = 0.78, green = 0.84, blue = 0.90, alpha = 1.0 }
local dimWhite  = { red = 0.40, green = 0.45, blue = 0.55, alpha = 0.6 }
local tabActive = { red = 0.25, green = 0.35, blue = 0.60, alpha = 0.80 }
local tabInact  = { red = 0.12, green = 0.14, blue = 0.20, alpha = 0.60 }

local KW = 48
local KH = 40
local GAP = 3
local THUMB_GAP = 10

local layers = {
    [0] = {
        name = "Default",
        left = {
            { {"=","alpha"},{"1","alpha"},{"2","alpha"},{"3","alpha"},{"4","alpha"},{"5","alpha"},{"","empty"} },
            { {"Esc","nav"},{"Q","alpha"},{"W","alpha"},{"E","alpha"},{"R","alpha"},{"T","alpha"},{"","empty"} },
            { {"Tab","nav"},{"A","alpha"},{"S","alpha"},{"D","alpha"},{"F","alpha"},{"G","alpha"} },
            { {"LShft","mod"},{"Z","alpha"},{"X","alpha"},{"C","alpha"},{"V","alpha"},{"B","alpha"},{"","empty"} },
            { {"GUI","mod"},{"`","alpha"},{"\\","alpha"},{"\u{2190}","nav"},{"\u{2192}","nav"} },
        },
        leftThumb = {
            { {"LCtl","mod"},{"LAlt","mod"} },
            { {"Hyper","fn"} },
            { {"Bksp","spec"},{"Del","alpha"},{"End","nav"} },
        },
        right = {
            { {"","empty"},{"6","alpha"},{"7","alpha"},{"8","alpha"},{"9","alpha"},{"0","alpha"},{"-","alpha"} },
            { {"[","alpha"},{"Y","alpha"},{"U","alpha"},{"I","alpha"},{"O","alpha"},{"P","alpha"},{"]","alpha"} },
            { {"H","alpha"},{"J","alpha"},{"K","alpha"},{"L","alpha"},{";","alpha"},{"'","alpha"} },
            { {"","empty"},{"N","alpha"},{"M","alpha"},{",","alpha"},{".","alpha"},{"/","alpha"},{"RShft","mod"} },
            { {"\u{2190}","nav"},{"\u{2193}","nav"},{"\u{2191}","nav"},{"\u{2192}","nav"},{"GUI","mod"} },
        },
        rightThumb = {
            { {"RAlt","mod"},{"RCtl","mod"} },
            { {"Hyper","fn"} },
            { {"PgDn","nav"},{"Ent","spec"},{"Spc","spec"} },
        },
    },
    [1] = {
        name = "Keyboard Fn",
        left = {
            { {"BTLD","spec"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"L0","fn"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        leftThumb = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        right = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        rightThumb = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
    },
    [2] = {
        name = "Numpad",
        left = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        leftThumb = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        right = {
            { {"\u{00B7}","empty"},{"Num","fn"},{"/","alpha"},{"*","alpha"},{"*","alpha"},{"-","alpha"},{"Bksp","spec"} },
            { {"\u{00B7}","empty"},{"","empty"},{"7","alpha"},{"8","alpha"},{"9","alpha"},{"-","alpha"},{"Bksp","spec"} },
            { {"","empty"},{"4","alpha"},{"5","alpha"},{"6","alpha"},{"+","alpha"},{"Ent","spec"} },
            { {"\u{00B7}","empty"},{"","empty"},{"1","alpha"},{"2","alpha"},{"3","alpha"},{"+","alpha"},{"Ent","spec"} },
            { {"0","alpha"},{".","alpha"},{"/","alpha"},{"Ent","spec"},{"Ent","spec"} },
        },
        rightThumb = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
    },
    [3] = {
        name = "Hyper (\u{2303}\u{21E7}\u{2325}\u{2318})",
        left = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"reload","fn"},{"\u{00B7}","empty"},{"","empty"} },
            { {"\u{00B7}","empty"},{"persnl","fn"},{"p-agnt","fn"},{"work","fn"},{"w-agnt","fn"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        leftThumb = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        right = {
            { {"","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"ergo","fn"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"slots","fn"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
        rightThumb = {
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"} },
            { {"\u{00B7}","empty"},{"\u{00B7}","empty"},{"\u{00B7}","empty"} },
        },
    },
}

local function getKeyStyle(ktype)
    if ktype == "mod"   then return modBg, modBorder, modText end
    if ktype == "fn"    then return fnBg, fnBorder, fnText end
    if ktype == "nav"   then return navBg, navBorder, navText end
    if ktype == "spec"  then return specBg, specBorder, specText end
    if ktype == "empty" then return emptyBg, emptyBdr, dimWhite end
    return keyBg, keyBorder, white
end

local function addKey(canvas, x, y, w, h, label, ktype)
    local bgC, bdC, txC = getKeyStyle(ktype)
    canvas:appendElements({
        type = "rectangle", action = "fill",
        frame = { x = x, y = y, w = w, h = h },
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
        fillColor = bgC,
    })
    canvas:appendElements({
        type = "rectangle", action = "stroke",
        frame = { x = x, y = y, w = w, h = h },
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
        strokeColor = bdC, strokeWidth = 1,
    })
    if label and label ~= "" then
        local fontSize = #label > 4 and 9 or (#label > 2 and 10 or 12)
        canvas:appendElements({
            type = "text",
            text = hs.styledtext.new(label, {
                font = { name = "Menlo", size = fontSize },
                color = txC,
                paragraphStyle = { alignment = "center" },
            }),
            frame = { x = x, y = y + (h - fontSize - 4) / 2, w = w, h = fontSize + 6 },
        })
    end
end

local function addRows(canvas, rows, startX, startY)
    local y = startY
    for _, row in ipairs(rows) do
        local x = startX
        for _, key in ipairs(row) do
            addKey(canvas, x, y, KW, KH, key[1], key[2])
            x = x + KW + GAP
        end
        y = y + KH + GAP
    end
    return y
end

local function addThumb(canvas, rows, startX, startY, align)
    local y = startY + THUMB_GAP
    for _, row in ipairs(rows) do
        local totalW = #row * (KW + GAP) - GAP
        local x
        if align == "right" then
            x = startX + (3 * (KW + GAP) - GAP) - totalW
            x = x + 4 * (KW + GAP)
        else
            x = startX + 4 * (KW + GAP)
        end
        for _, key in ipairs(row) do
            addKey(canvas, x, y, KW, KH, key[1], key[2])
            x = x + KW + GAP
        end
        y = y + KH + GAP
    end
    return y
end

-- Layout constants (computed once)
local leftW = 7 * (KW + GAP) - GAP
local halfGap = 60
local pad = 30
local tabH = 32
local headerH = 28
local totalW = pad + leftW + halfGap + leftW + pad
local mainRowsH = 5 * (KH + GAP) - GAP
local thumbH = 3 * (KH + GAP) - GAP + THUMB_GAP
local totalH = pad + tabH + 8 + headerH + mainRowsH + thumbH + pad

-- Flash overlay for bound keys (hyper layer)
local keysStartY = pad * 0.6 + tabH + 8 + headerH
local leftStartX = pad
local rightStartX = pad + leftW + halfGap

-- keycode -> pixel position for hyper-bound keys
local flashPositions = {
    [0]  = { x = leftStartX + 1 * (KW + GAP), y = keysStartY + 2 * (KH + GAP) },  -- A: personal
    [1]  = { x = leftStartX + 2 * (KW + GAP), y = keysStartY + 2 * (KH + GAP) },  -- S: personal-agent
    [2]  = { x = leftStartX + 3 * (KW + GAP), y = keysStartY + 2 * (KH + GAP) },  -- D: work
    [3]  = { x = leftStartX + 4 * (KW + GAP), y = keysStartY + 2 * (KH + GAP) },  -- F: work-agent
    [15] = { x = leftStartX + 4 * (KW + GAP), y = keysStartY + 1 * (KH + GAP) },  -- R: reload
    [31] = { x = rightStartX + 4 * (KW + GAP), y = keysStartY + 1 * (KH + GAP) }, -- O: ergo overlay
    [37] = { x = rightStartX + 4 * (KW + GAP), y = keysStartY + 2 * (KH + GAP) }, -- L: slots
}

local flashCanvas = nil
local flashTimer = nil

local function flashKey(pos)
    if flashCanvas then flashCanvas:delete(); flashCanvas = nil end
    if flashTimer then flashTimer:stop(); flashTimer = nil end

    local screen = hs.screen.mainScreen():frame()
    local ox = screen.x + (screen.w - totalW) / 2
    local oy = screen.y + (screen.h - totalH) / 2

    flashCanvas = hs.canvas.new({ x = ox + pos.x, y = oy + pos.y, w = KW, h = KH })
    flashCanvas:appendElements({
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
        fillColor = { red = 0.40, green = 0.95, blue = 0.60, alpha = 0.85 },
    })
    flashCanvas:level(hs.canvas.windowLevels.overlay + 1)
    flashCanvas:show()

    flashTimer = hs.timer.doAfter(0.15, function()
        if flashCanvas then flashCanvas:delete(); flashCanvas = nil end
    end)
end

local function buildCanvas(layerIdx)
    local layer = layers[layerIdx]
    if not layer then return nil end

    local screen = hs.screen.mainScreen():frame()
    local ox = screen.x + (screen.w - totalW) / 2
    local oy = screen.y + (screen.h - totalH) / 2

    local c = hs.canvas.new({ x = ox, y = oy, w = totalW, h = totalH })

    -- Background
    c:appendElements({
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 14, yRadius = 14 },
        fillColor = bg,
    })

    -- Tab bar
    local tabNames = { "0: Default", "1: Fn", "2: Numpad", "3: Hyper" }
    local tabW = 110
    local tabGap = 6
    local tabTotalW = #tabNames * (tabW + tabGap) - tabGap
    local tabStartX = (totalW - tabTotalW) / 2
    for i, name in ipairs(tabNames) do
        local tx = tabStartX + (i - 1) * (tabW + tabGap)
        local isActive = (i - 1) == layerIdx
        c:appendElements({
            type = "rectangle", action = "fill",
            frame = { x = tx, y = pad * 0.6, w = tabW, h = tabH },
            roundedRectRadii = { xRadius = 6, yRadius = 6 },
            fillColor = isActive and tabActive or tabInact,
        })
        c:appendElements({
            type = "text",
            text = hs.styledtext.new(name, {
                font = { name = "Menlo", size = 11 },
                color = isActive and { red = 0.63, green = 0.77, blue = 1.0, alpha = 1.0 } or dimWhite,
                paragraphStyle = { alignment = "center" },
            }),
            frame = { x = tx, y = pad * 0.6 + 8, w = tabW, h = 20 },
        })
    end

    -- Layer name
    local nameY = pad * 0.6 + tabH + 8
    c:appendElements({
        type = "text",
        text = hs.styledtext.new(layer.name, {
            font = { name = "Helvetica Neue", size = 14 },
            color = dimWhite,
            paragraphStyle = { alignment = "center" },
        }),
        frame = { x = 0, y = nameY, w = totalW, h = 22 },
    })

    local keysY = nameY + headerH
    local leftX = pad
    local rightX = pad + leftW + halfGap

    -- Left half
    addRows(c, layer.left, leftX, keysY)
    local thumbY = keysY + mainRowsH
    addThumb(c, layer.leftThumb, leftX, thumbY, "left")

    -- Right half (handle 6-key and 5-key rows)
    local ry = keysY
    for ri, row in ipairs(layer.right) do
        local x = rightX
        if #row == 6 then
            x = rightX + KW + GAP
        elseif #row == 5 and ri == 5 then
            x = rightX + KW + GAP
        end
        for _, key in ipairs(row) do
            addKey(c, x, ry, KW, KH, key[1], key[2])
            x = x + KW + GAP
        end
        ry = ry + KH + GAP
    end
    addThumb(c, layer.rightThumb, rightX - 4 * (KW + GAP), thumbY, "right")

    -- Hint
    c:appendElements({
        type = "text",
        text = hs.styledtext.new("Esc to close \u{00B7} 1-4 switch layers \u{00B7} Tab cycle", {
            font = { name = "Menlo", size = 10 },
            color = { red = 0.30, green = 0.35, blue = 0.45, alpha = 0.6 },
            paragraphStyle = { alignment = "center" },
        }),
        frame = { x = 0, y = totalH - pad + 4, w = totalW, h = 18 },
    })

    c:level(hs.canvas.windowLevels.overlay)
    c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    return c
end

-- Pre-build all 4 layer canvases at load time
local function buildAll()
    for _, c in pairs(canvases) do c:delete() end
    canvases = {}
    for i = 0, 3 do
        canvases[i] = buildCanvas(i)
    end
end

local function showLayer(idx)
    for i = 0, 3 do
        if canvases[i] then
            if i == idx then canvases[i]:show() else canvases[i]:hide() end
        end
    end
    currentLayer = idx
end

function M.dismiss()
    for i = 0, 3 do
        if canvases[i] then canvases[i]:hide() end
    end
    if overlayTap then overlayTap:stop(); overlayTap = nil end
    if flashCanvas then flashCanvas:delete(); flashCanvas = nil end
    if flashTimer then flashTimer:stop(); flashTimer = nil end
    visible = false
end

function M.toggle()
    if visible then
        M.dismiss()
    else
        visible = true
        showLayer(3)
        -- eventtap for layer switching / dismiss
        overlayTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
            local key = event:getCharacters()
            local code = event:getKeyCode()
            if code == 53 then -- Escape
                M.dismiss()
                return true
            end
            if key and key >= "1" and key <= "4" then
                showLayer(tonumber(key) - 1)
                return true
            end
            if code == 48 then -- Tab
                showLayer((currentLayer + 1) % 4)
                return true
            end
            -- Flash bound keys on hyper layer (only when hyper mods are held)
            if currentLayer == 3 then
                local flags = event:getFlags()
                if flags.ctrl and flags.shift and flags.alt and flags.cmd then
                    local pos = flashPositions[code]
                    if pos then flashKey(pos) end
                end
            end
            return false
        end)
        overlayTap:start()
    end
end

-- Build canvases now; rebuild on screen change
buildAll()
hs.screen.watcher.new(buildAll):start()

hs.hotkey.bind(hyper, "o", M.toggle)

return M
