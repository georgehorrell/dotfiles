--- === RadialMenu ===
---
--- A pie/radial menu triggered by holding a configurable mouse button.
--- Hold the button to open the menu, drag to a wedge, and release to fire its
--- action. Quick clicks (released before `holdThreshold`) pass through as a
--- normal button click. Sub-menus open on dwell. Esc, right-click, or a dwell
--- in the dead-zone cancels / navigates back.
---
--- Download: https://github.com/yourname/RadialMenu.spoon
--- Version: 0.1.0

local obj = {}
obj.__index = obj

-- ───────────────────────────────────────────────────────────────────────────
-- Spoon metadata
-- ───────────────────────────────────────────────────────────────────────────
obj.name     = "RadialMenu"
obj.version  = "0.1.0"
obj.author   = "George Horrell"
obj.homepage = "https://github.com/yourname/RadialMenu.spoon"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

-- ───────────────────────────────────────────────────────────────────────────
-- Public configuration variables
-- ───────────────────────────────────────────────────────────────────────────

--- RadialMenu.buttonNumber
--- Variable
--- The macOS mouse button number (0-indexed, as reported by
--- `mouseEventButtonNumber`) that triggers the menu. Default `3` corresponds
--- to "Mouse4" / the back side-button on most mice. `4` is typically "Mouse5"
--- / forward. Use the diagnostic log printed by RadialMenu (it logs any
--- `otherMouseDown` whose button doesn't match this value) to identify yours.
obj.buttonNumber = 3

--- RadialMenu.holdThreshold
--- Variable
--- Seconds the button must be held before the menu opens. A release before
--- this threshold is replayed as a normal click pair. Default 0.18.
obj.holdThreshold = 0.18

--- RadialMenu.onShortClick
--- Variable
--- Optional function called when a short click would otherwise be replayed
--- (button released before `holdThreshold`). If the function returns truthy,
--- the click is consumed instead of being replayed. Useful for contextual
--- behavior — e.g. stop a running task instead of letting the click through.
--- Default nil (replay always happens).
obj.onShortClick = nil

--- RadialMenu.onShow
--- Variable
--- Optional function called when the radial menu is shown. Useful for
--- pre-warming work that overlaps with the user's hover-and-pick time
--- (e.g. opening an audio device). Called with no arguments. Default nil.
obj.onShow = nil

--- RadialMenu.onHide
--- Variable
--- Optional function called when the radial menu hides — for ANY reason,
--- including action-fired and cancel. Use it to tear down anything that
--- was set up in `onShow`. Receives one argument: a boolean that is true
--- if a wedge action was fired, false on cancel. Default nil.
obj.onHide = nil

--- RadialMenu.dwellTime
--- Variable
--- Seconds to hover over a sub-menu wedge before it auto-opens; also the
--- delay for "dwell in dead-zone to go back". Default 0.25.
obj.dwellTime = 0.25

--- RadialMenu.radius
--- Variable
--- Outer radius of the menu in screen points. Default 170.
obj.radius = 170

--- RadialMenu.deadZoneRadius
--- Variable
--- Inner dead-zone radius in screen points. Releasing the mouse here cancels
--- (or navigates back if in a sub-menu) without firing an action. Default 42.
obj.deadZoneRadius = 42

--- RadialMenu.labelFont
--- Variable
--- Font name used for wedge labels. Default "SF Pro Text" (the macOS system
--- font; falls back automatically on older systems).
obj.labelFont = "SF Pro Text"

--- RadialMenu.labelSize
--- Variable
--- Font size (points) used for wedge labels. Default 14.
obj.labelSize = 14

--- RadialMenu.wedgeGap
--- Variable
--- Angular gap (degrees) between adjacent wedges. Creates visible separation
--- without needing stroke lines. Default 1.6.
obj.wedgeGap = 1.6

--- RadialMenu.wedgeColor
--- Variable
--- Fill color for inactive wedges. RGBA table.
obj.wedgeColor = { red = 0.10, green = 0.10, blue = 0.12, alpha = 0.86 }

--- RadialMenu.activeWedgeColor
--- Variable
--- Fill color for the currently highlighted wedge. RGBA table.
obj.activeWedgeColor = { red = 0.00, green = 0.48, blue = 1.00, alpha = 0.95 }

--- RadialMenu.subMenuWedgeColor
--- Variable
--- Fill color for wedges that open a sub-menu (have `children`). RGBA table.
obj.subMenuWedgeColor = { red = 0.13, green = 0.18, blue = 0.16, alpha = 0.88 }

--- RadialMenu.deadZoneColor
--- Variable
--- Stroke color for the inner dead-zone ring. RGBA table.
obj.deadZoneColor = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.18 }

--- RadialMenu.rimColor
--- Variable
--- Color of the thin highlight rim around the outside of the menu. RGBA table.
obj.rimColor = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.10 }

--- RadialMenu.labelColor
--- Variable
--- Text color for wedge labels. RGBA table.
obj.labelColor = { red = 0.96, green = 0.96, blue = 0.98, alpha = 1.00 }

--- RadialMenu.activeLabelColor
--- Variable
--- Text color for the active wedge's label. Defaults to the same as labelColor
--- but slightly brighter — override if you want extra contrast on the accent.
obj.activeLabelColor = { red = 1.00, green = 1.00, blue = 1.00, alpha = 1.00 }

--- RadialMenu.cursorRangeFraction
--- Variable
--- Maximum distance the rubber-band cursor can travel from the center, as
--- a fraction of `radius`. The actual mouse can move anywhere on screen,
--- but the cursor disc inside the menu clamps to this distance — which
--- means the menu only ever needs to track *direction* from the center,
--- not a precise mouse position. Default 0.65.
obj.cursorRangeFraction = 0.65

--- RadialMenu.cursorRadius
--- Variable
--- Radius (px) of the rubber-band cursor disc drawn inside the menu.
--- Default 7.
obj.cursorRadius = 7

--- RadialMenu.cursorColor
--- Variable
--- Fill color for the rubber-band cursor disc. RGBA table.
obj.cursorColor = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.95 }

--- RadialMenu.debug
--- Variable
--- Set to `true` to print every event the open-state handler sees, plus the
--- hit-test result. Helpful when a particular trigger isn't highlighting
--- wedges correctly.
obj.debug = false

-- ───────────────────────────────────────────────────────────────────────────
-- Private state
-- ───────────────────────────────────────────────────────────────────────────
local _state          = "idle"  -- "idle" | "pending" | "open"
local _downEvent      = nil     -- copy of swallowed otherMouseDown (for replay)
local _holdTimer      = nil
local _dwellTimer     = nil
local _dwellWedge     = nil
local _deadDwellTimer = nil
local _canvas         = nil
local _center         = nil     -- {x, y} screen anchor
local _cursorDx       = 0       -- rubber-band cursor offset from center
local _cursorDy       = 0

-- Indices into the canvas's element list for the things we update in place
-- on every mouse move. Tracking these lets us avoid a full canvas rebuild
-- (~25 elements destroyed + recreated) when only the cursor or one or two
-- wedges' fill colors change.
local _wedgeIdxs      = {}      -- _wedgeIdxs[i] = canvas index of wedge i
local _backIdx        = nil     -- canvas index of the back-hitbox fill
local _cursorIdx      = nil     -- canvas index of the rubber-band cursor disc
local _canvasLx       = 0       -- canvas-local center x (= radius + pad)
local _canvasLy       = 0       -- canvas-local center y
local _currentItems   = {}
local _activeWedge    = nil     -- 1-based index, nil = dead zone / outside
local _navStack       = {}      -- [{items=, center=}]
local _menuMap        = {}
local _reinjecting    = false
local _tap            = nil
local _keyTap         = nil
local _hotkey         = nil     -- hs.hotkey bound via bindToHotkey
local _loggedButtons  = {}      -- buttons already logged (avoid spam)

-- ───────────────────────────────────────────────────────────────────────────
-- Geometry helpers
-- ───────────────────────────────────────────────────────────────────────────

-- Wedge i is centered at 270° (top) + (i-1)*span, going clockwise.
-- Returns startDeg, endDeg, midDeg (all degrees, 0..360).
local function wedgeAngles(i, count)
  local span = 360 / count
  local mid = (270 + (i - 1) * span) % 360
  local s = (mid - span / 2 + 360) % 360
  local e = (mid + span / 2 + 360) % 360
  return s, e, mid
end

-- Clamp a screen position to a "rubber-band cursor" offset relative to
-- the menu center. The actual mouse can be anywhere; the cursor offset
-- is capped at obj.cursorRangeFraction * obj.radius, so we always track
-- direction without caring how far away the mouse actually is.
local function constrainCursor(pos, center)
  local dx = pos.x - center.x
  local dy = pos.y - center.y
  local maxR = obj.radius * obj.cursorRangeFraction
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist > maxR and dist > 0 then
    dx = dx * maxR / dist
    dy = dy * maxR / dist
  end
  return dx, dy
end

-- Hit-test a clamped cursor offset against the menu. Returns the 1-based
-- wedge index, or nil for dead-zone (cursor centered = no selection).
local function hitTest(dx, dy, count)
  if count == 0 then return nil end
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist < obj.deadZoneRadius then return nil end

  local angleDeg = math.deg(math.atan(dy, dx))
  if angleDeg < 0 then angleDeg = angleDeg + 360 end
  local span = 360 / count
  local rotated = (angleDeg - (270 - span / 2) + 720) % 360
  local idx = math.floor(rotated / span) + 1
  if idx < 1 then idx = 1 end
  if idx > count then idx = count end
  return idx
end

-- Build coordinates for a closed annular wedge polygon (donut sector).
-- Points are in canvas-local coordinates (lx, ly = canvas-local center).
local function wedgePolygon(lx, ly, outerR, innerR, startDeg, endDeg)
  local arc = (endDeg - startDeg + 360) % 360
  if arc == 0 then arc = 360 end
  -- ~1 segment per 1.5° gives a smooth curve at any radius up to ~250pt.
  -- For a 60° wedge that's 40 segments per arc; for 45° it's 30; for 90° it's 60.
  local steps = math.max(8, math.ceil(arc / 1.5))
  local pts = {}

  -- Outer arc clockwise: startDeg → endDeg
  for k = 0, steps do
    local a = math.rad(startDeg + arc * k / steps)
    pts[#pts + 1] = { x = lx + outerR * math.cos(a), y = ly + outerR * math.sin(a) }
  end
  -- Inner arc counter-clockwise: endDeg → startDeg
  for k = steps, 0, -1 do
    local a = math.rad(startDeg + arc * k / steps)
    pts[#pts + 1] = { x = lx + innerR * math.cos(a), y = ly + innerR * math.sin(a) }
  end
  return pts
end

-- ───────────────────────────────────────────────────────────────────────────
-- Canvas rendering
-- ───────────────────────────────────────────────────────────────────────────

local function destroyCanvas()
  if _canvas then
    _canvas:delete()
    _canvas = nil
  end
end

local function refreshCanvas()
  destroyCanvas()
  if _state ~= "open" or not _center then return end
  local items = _currentItems
  local n     = #items
  if n == 0 then return end

  -- Reset element-index trackers; we'll repopulate as we append.
  _wedgeIdxs = {}
  _backIdx   = nil
  _cursorIdx = nil

  local R    = obj.radius
  local DZ   = obj.deadZoneRadius
  local gap  = obj.wedgeGap / 2  -- half-gap on each side of every wedge
  local pad  = 16                -- room for the soft glow
  local sz   = (R + pad) * 2
  local lx   = R + pad
  local ly   = R + pad
  _canvasLx, _canvasLy = lx, ly  -- remember for in-place updates

  local c = hs.canvas.new({
    x = _center.x - R - pad,
    y = _center.y - R - pad,
    w = sz, h = sz,
  })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  -- Explicitly disable mouse capture so the canvas never intercepts events
  -- (matters when a mouse button is physically held while the canvas appears
  -- under the cursor — e.g. middle-click trigger).
  c:canvasMouseEvents(false, false, false, false)

  -- Soft drop-shadow: 4 stacked discs, each larger and more transparent.
  -- Cheap fake blur — looks much softer than a single shadow disc.
  for i = 4, 1, -1 do
    local extra = i * 4
    c:appendElements({
      type      = "oval",
      action    = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = 0.06 + (5 - i) * 0.04 },
      frame     = { x = lx - R - extra, y = ly - R - extra,
                    w = (R + extra) * 2,  h = (R + extra) * 2 },
    })
  end

  -- Wedge polygons (with angular gaps for separation — no stroke needed)
  for i = 1, n do
    local s, e = wedgeAngles(i, n)
    -- Inset the wedge by `gap` degrees on each side
    local s2, e2 = s + gap, e - gap

    local fill
    if i == _activeWedge then
      fill = obj.activeWedgeColor
    elseif items[i].children then
      fill = obj.subMenuWedgeColor
    else
      fill = obj.wedgeColor
    end
    c:appendElements({
      type        = "segments",
      action      = "fill",
      closed      = true,
      coordinates = wedgePolygon(lx, ly, R, DZ + 2, s2, e2),
      fillColor   = fill,
    })
    _wedgeIdxs[i] = c:elementCount()
  end

  -- Outer rim: thin highlight around the entire menu, gives it a glassy edge
  c:appendElements({
    type        = "oval",
    action      = "stroke",
    strokeColor = obj.rimColor,
    strokeWidth = 1,
    frame       = { x = lx - R + 0.5, y = ly - R + 0.5, w = R * 2 - 1, h = R * 2 - 1 },
  })

  -- Back-hitbox fill: the inner dead-zone area, lit up when the cursor
  -- sits in it AND we're in a sub-menu (i.e., releasing here goes back).
  -- Drawn before the dead-zone stroke so the stroke crowns the fill.
  local backFillNow
  if _activeWedge == nil and #_navStack > 0 then
    backFillNow = obj.activeWedgeColor
  else
    backFillNow = { red = 0, green = 0, blue = 0, alpha = 0 }
  end
  c:appendElements({
    type      = "oval",
    action    = "fill",
    fillColor = backFillNow,
    frame     = { x = lx - DZ + 1.5, y = ly - DZ + 1.5,
                  w = (DZ - 1.5) * 2, h = (DZ - 1.5) * 2 },
  })
  _backIdx = c:elementCount()

  -- Dead-zone ring (no fill — desktop shows through). A second, slightly
  -- inner stroke gives a subtle glassy double-ring.
  c:appendElements({
    type        = "oval",
    action      = "stroke",
    strokeColor = obj.deadZoneColor,
    strokeWidth = 1.25,
    frame       = { x = lx - DZ, y = ly - DZ, w = DZ * 2, h = DZ * 2 },
  })

  -- Wedge labels
  for i = 1, n do
    local _, _, mid = wedgeAngles(i, n)
    local labelR = (R + DZ) / 2
    local a  = math.rad(mid)
    local tx = lx + labelR * math.cos(a)
    local ty = ly + labelR * math.sin(a)
    local tw, th = 130, obj.labelSize + 10

    local txt = items[i].label or ""
    if items[i].children then txt = txt .. "  ▸" end

    local color = (i == _activeWedge) and obj.activeLabelColor or obj.labelColor

    c:appendElements({
      type  = "text",
      text  = hs.styledtext.new(txt, {
        font           = { name = obj.labelFont, size = obj.labelSize },
        color          = color,
        paragraphStyle = { alignment = "center", lineBreak = "truncateTail" },
      }),
      frame = { x = tx - tw / 2, y = ty - th / 2, w = tw, h = th },
    })
  end

  -- Depth indicator inside the dead zone (← when in a sub-menu)
  if #_navStack > 0 then
    c:appendElements({
      type  = "text",
      text  = hs.styledtext.new("←", {
        font           = { name = obj.labelFont, size = 18 },
        color          = { red = 1, green = 1, blue = 1, alpha = 0.55 },
        paragraphStyle = { alignment = "center" },
      }),
      frame = { x = lx - 14, y = ly - 13, w = 28, h = 26 },
    })
  end

  -- Rubber-band cursor — the small disc that tracks mouse direction within
  -- the menu. Drawn last so it sits on top of wedges and labels.
  local cr = obj.cursorRadius
  c:appendElements({
    type      = "oval",
    action    = "fill",
    fillColor = obj.cursorColor,
    frame     = { x = lx + _cursorDx - cr, y = ly + _cursorDy - cr,
                  w = cr * 2, h = cr * 2 },
  })
  _cursorIdx = c:elementCount()

  _canvas = c
  _canvas:show()
end

-- ───────────────────────────────────────────────────────────────────────────
-- System cursor hide/show. macOS doesn't let you globally hide the cursor
-- from an arbitrary process call — the hide is reference-counted and
-- decremented when the calling process exits. Fire-and-forget therefore
-- does nothing.
--
-- Workaround: spawn a *persistent* osascript+JXA helper that hides the
-- cursor and then sits idle in a run loop. As long as that process is
-- alive, the cursor stays hidden globally. We terminate it (SIGTERM) when
-- the menu closes; macOS automatically restores the cursor on process
-- exit.
-- ───────────────────────────────────────────────────────────────────────────
local _hideTask = nil

local function hideCursor()
  if _hideTask then return end
  _hideTask = hs.task.new("/usr/bin/osascript", function()
    _hideTask = nil
  end, {
    "-l", "JavaScript", "-e",
    'ObjC.import("CoreGraphics"); ObjC.import("Foundation");'
      .. ' $.CGDisplayHideCursor($.CGMainDisplayID());'
      .. ' $.NSRunLoop.currentRunLoop.run',
  })
  _hideTask:start()
end

local function showCursor()
  if _hideTask then
    _hideTask:terminate()
    _hideTask = nil
  end
end

-- Cheap in-place update of the cursor disc's position. Called on every
-- mouse move while the menu is open. Avoids the full canvas rebuild
-- refreshCanvas does.
local function updateCursorDisc()
  if not _canvas or not _cursorIdx then return end
  local cr = obj.cursorRadius
  _canvas[_cursorIdx].frame = {
    x = _canvasLx + _cursorDx - cr,
    y = _canvasLy + _cursorDy - cr,
    w = cr * 2,
    h = cr * 2,
  }
end

-- Cheap in-place update of two wedges' fill colors when the active wedge
-- changes (one to deactivate, one to activate). Skips labels — their
-- color difference is too subtle to be worth recomputing styledtext.
local function updateActiveWedgeFills(newActive, oldActive)
  if not _canvas then return end
  local items = _currentItems
  if oldActive and _wedgeIdxs[oldActive] then
    local item = items[oldActive]
    local fill = (item and item.children) and obj.subMenuWedgeColor or obj.wedgeColor
    _canvas[_wedgeIdxs[oldActive]].fillColor = fill
  end
  if newActive and _wedgeIdxs[newActive] then
    _canvas[_wedgeIdxs[newActive]].fillColor = obj.activeWedgeColor
  end
end

-- Update the back-hitbox fill: lit when no wedge is active AND we're in
-- a sub-menu. Light = "release here to go back."
local function updateBackHitbox()
  if not _canvas or not _backIdx then return end
  if _activeWedge == nil and #_navStack > 0 then
    _canvas[_backIdx].fillColor = obj.activeWedgeColor
  else
    _canvas[_backIdx].fillColor = { red = 0, green = 0, blue = 0, alpha = 0 }
  end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Action dispatcher
-- ───────────────────────────────────────────────────────────────────────────

local function dispatchAction(action)
  if not action then return end
  local t = action.type
  local ok, err = pcall(function()
    if     t == "keystroke"   then hs.eventtap.keyStroke(action.mods or {}, action.key, action.delay or 0)
    elseif t == "shell"       then hs.task.new("/bin/sh", nil, { "-c", action.cmd }):start()
    elseif t == "applescript" then hs.osascript.applescript(action.script)
    elseif t == "func"        then if type(action.fn) == "function" then action.fn() end
    elseif t == "launch"      then hs.application.launchOrFocus(action.app)
    elseif t == "url"         then hs.urlevent.openURL(action.url)
    elseif t == "open"        then hs.task.new("/usr/bin/open", nil, { action.path }):start()
    else   hs.printf("[RadialMenu] unknown action type: %s", tostring(t))
    end
  end)
  if not ok then
    hs.printf("[RadialMenu] action error: %s", tostring(err))
  end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Menu lifecycle
-- ───────────────────────────────────────────────────────────────────────────

local function cancelDwells()
  if _dwellTimer     then _dwellTimer:stop();     _dwellTimer     = nil end
  if _deadDwellTimer then _deadDwellTimer:stop(); _deadDwellTimer = nil end
  _dwellWedge = nil
end

local function toIdle()
  local wasOpen = (_state == "open")
  if _holdTimer then _holdTimer:stop(); _holdTimer = nil end
  cancelDwells()
  destroyCanvas()
  showCursor()
  if _keyTap then _keyTap:stop() end
  _navStack     = {}
  _currentItems = {}
  _activeWedge  = nil
  _cursorDx     = 0
  _cursorDy     = 0
  _center       = nil
  _downEvent    = nil
  _state        = "idle"

  if wasOpen and type(obj.onHide) == "function" then
    local ok, err = pcall(obj.onHide)
    if not ok then hs.printf("[RadialMenu] onHide error: %s", tostring(err)) end
  end
end

local function replayClick()
  if not _downEvent then return end
  local pos = _downEvent:location()
  local btn = obj.buttonNumber
  local upEv = hs.eventtap.event.newMouseEvent(
    hs.eventtap.event.types.otherMouseUp, pos, btn)
  _reinjecting = true
  _downEvent:post()
  upEv:post()
  hs.timer.doAfter(0.020, function() _reinjecting = false end)
end

-- Forward declaration so onMouseEvent can call into the lifecycle
local toOpen, openSubMenu, goBack

function toOpen()
  if _holdTimer then _holdTimer:stop(); _holdTimer = nil end

  local app = hs.application.frontmostApplication()
  local bid = app and app:bundleID() or nil
  local items = (bid and _menuMap[bid]) or _menuMap["default"] or {}

  if #items == 0 then
    -- No menu defined — give the user their click back
    replayClick()
    toIdle()
    return
  end

  _currentItems = items
  -- For button triggers: use the press-event's location (most accurate, and
  -- hs.mouse.absolutePosition can be stale while a button-down was swallowed).
  -- For hotkey triggers: _downEvent is nil → fall back to the live cursor.
  if _downEvent then
    _center = _downEvent:location()
  else
    _center = hs.mouse.absolutePosition()
  end
  _navStack     = {}
  _activeWedge  = nil
  _cursorDx     = 0
  _cursorDy     = 0
  _state        = "open"
  refreshCanvas()
  hideCursor()
  if _keyTap then _keyTap:start() end

  if type(obj.onShow) == "function" then
    local ok, err = pcall(obj.onShow)
    if not ok then hs.printf("[RadialMenu] onShow error: %s", tostring(err)) end
  end
end

function openSubMenu(item, pos)
  cancelDwells()
  _navStack[#_navStack + 1] = { items = _currentItems, center = _center }
  _currentItems = item.children
  _center       = pos or hs.mouse.absolutePosition()
  _activeWedge  = nil
  _cursorDx     = 0
  _cursorDy     = 0
  refreshCanvas()
end

function goBack()
  cancelDwells()
  if #_navStack == 0 then
    toIdle()
    return
  end
  local prev = table.remove(_navStack)
  _currentItems = prev.items
  _center       = prev.center
  _activeWedge  = nil
  _cursorDx     = 0
  _cursorDy     = 0
  refreshCanvas()
end

-- Commit whatever wedge is currently active. Used by both the mouse-button
-- release handler and the hotkey release handler.
local function commitActive()
  local wedge = _activeWedge
  local item  = wedge and _currentItems[wedge] or nil
  toIdle()
  if item and not item.children then
    -- Brief delay so the canvas vanishes before any keystroke action
    hs.timer.doAfter(0.04, function() dispatchAction(item.action) end)
  end
  -- A wedge with children, or a nil wedge, is a silent close
end

local function startDwellTimer(wedgeIdx)
  cancelDwells()
  _dwellWedge = wedgeIdx
  _dwellTimer = hs.timer.doAfter(obj.dwellTime, function()
    _dwellTimer = nil
    if _state == "open" and _activeWedge == _dwellWedge then
      local item = _currentItems[_dwellWedge]
      if item and item.children then
        openSubMenu(item, hs.mouse.absolutePosition())
      end
    end
  end)
end

local function startDeadDwellTimer()
  cancelDwells()
  _deadDwellTimer = hs.timer.doAfter(obj.dwellTime, function()
    _deadDwellTimer = nil
    if _state == "open" and _activeWedge == nil and #_navStack > 0 then
      goBack()
    end
  end)
end

-- ───────────────────────────────────────────────────────────────────────────
-- State machine — mouse events
-- ───────────────────────────────────────────────────────────────────────────
--
-- The hold-vs-click decision is the trickiest piece. macOS delivers
-- `otherMouseDown` immediately to the focused app unless we swallow it from
-- our event tap. Because we can't un-deliver a passed-through event, we
-- ALWAYS swallow the down for our button and then defer the decision:
--
--   • If `otherMouseUp` arrives before `holdThreshold` expires, this was a
--     quick click. We replay the original down event and a fresh up event so
--     the app sees a normal click pair.
--   • If the hold timer fires first, this was a hold — we open the menu.
--
-- A `_reinjecting` flag is checked at the top of the handler so our own
-- replayed events pass straight through (they would otherwise re-enter the
-- state machine and be re-swallowed). The 20ms guard window is generous;
-- replayed events typically arrive within 1–5ms.
-- ───────────────────────────────────────────────────────────────────────────

local function handleMouseEvent(event)
  if _reinjecting then return false end

  local T = hs.eventtap.event.types
  local P = hs.eventtap.event.properties
  local et = event:getType()
  local btn = event:getProperty(P.mouseEventButtonNumber)
  local isOurs = (btn == obj.buttonNumber)

  -- Diagnostic: log unrecognized button presses (once per button per session)
  if et == T.otherMouseDown and not isOurs and not _loggedButtons[btn] then
    _loggedButtons[btn] = true
    hs.printf("[RadialMenu] saw otherMouseDown on button %d (configured: %d). " ..
              "If this is the button you want, call bindToButton(%d, ...).",
              btn, obj.buttonNumber, btn)
  end

  -- ── IDLE ────────────────────────────────────────────────────────────
  if _state == "idle" then
    if et == T.otherMouseDown and isOurs then
      _downEvent = event:copy()
      _state = "pending"
      _holdTimer = hs.timer.doAfter(obj.holdThreshold, function()
        _holdTimer = nil
        if _state == "pending" then toOpen() end
      end)
      return true
    end
    return false

  -- ── PENDING ─────────────────────────────────────────────────────────
  elseif _state == "pending" then
    if et == T.otherMouseUp and isOurs then
      if _holdTimer then _holdTimer:stop(); _holdTimer = nil end
      _state = "idle"
      local consumed = false
      if type(obj.onShortClick) == "function" then
        local ok, result = pcall(obj.onShortClick)
        if ok and result then
          consumed = true
        elseif not ok then
          hs.printf("[RadialMenu] onShortClick error: %s", tostring(result))
        end
      end
      if not consumed then replayClick() end
      _downEvent = nil
      return true
    end
    return false

  -- ── OPEN ────────────────────────────────────────────────────────────
  elseif _state == "open" then
    -- TEMP DIAGNOSTIC: log every event we see while menu is open
    if obj.debug then
      hs.printf("[RadialMenu] open: et=%d btn=%s isOurs=%s",
        et, tostring(btn), tostring(isOurs))
    end

    -- Right-click → go back one level (or close)
    if et == T.rightMouseDown then
      goBack()
      return true
    end

    -- Esc handled by the key tap, not here
    if et == T.otherMouseDragged or et == T.mouseMoved then
      -- IMPORTANT: use event:location(), not hs.mouse.absolutePosition().
      -- When a mouse button's down-event has been swallowed, macOS keeps
      -- the cached high-level cursor position frozen until the button is
      -- released, even while drag events fire with correct positions.
      local pos = event:location()
      _cursorDx, _cursorDy = constrainCursor(pos, _center)
      local newActive = hitTest(_cursorDx, _cursorDy, #_currentItems)

      if newActive ~= _activeWedge then
        local oldActive = _activeWedge
        _activeWedge = newActive
        cancelDwells()

        if newActive ~= nil then
          local item = _currentItems[newActive]
          if item and item.children then startDwellTimer(newActive) end
        elseif #_navStack > 0 then
          startDeadDwellTimer()
        end

        updateActiveWedgeFills(newActive, oldActive)
        updateBackHitbox()
      end

      -- Cheap in-place cursor update. No canvas rebuild — the cursor
      -- moves at native event-tap rates without lag.
      updateCursorDisc()

      -- Swallow drags of OUR button (otherwise the focused app may interpret
      -- them as a drag gesture). Don't swallow plain mouseMoved — we want
      -- the cursor to keep moving naturally.
      if et == T.otherMouseDragged and isOurs then return true end
      return false
    end

    if et == T.otherMouseUp and isOurs then
      if obj.debug then hs.printf("[RadialMenu]   commit on otherMouseUp btn=%s wedge=%s",
        tostring(btn), tostring(_activeWedge)) end
      commitActive()
      return true
    end

    return false
  end

  return false
end

-- ───────────────────────────────────────────────────────────────────────────
-- Keyboard handler — Esc cancels
-- ───────────────────────────────────────────────────────────────────────────

local function handleKeyEvent(event)
  if _state == "open" and event:getKeyCode() == 53 then -- Esc
    toIdle()
    return true
  end
  return false
end

-- ───────────────────────────────────────────────────────────────────────────
-- Public API
-- ───────────────────────────────────────────────────────────────────────────

--- RadialMenu:start()
--- Method
--- Creates and starts the mouse and keyboard event taps. Idempotent — safe
--- to call multiple times (it stops any prior taps first). The keyboard tap
--- is created here but only started while the menu is visible.
---
--- Returns:
---  * The RadialMenu object
function obj:start()
  if _tap    then _tap:stop();    _tap    = nil end
  if _keyTap then _keyTap:stop(); _keyTap = nil end

  local T = hs.eventtap.event.types
  _tap = hs.eventtap.new({
    T.otherMouseDown,
    T.otherMouseUp,
    T.otherMouseDragged,
    T.mouseMoved,
    T.rightMouseDown,
  }, handleMouseEvent)
  _tap:start()

  _keyTap = hs.eventtap.new({ T.keyDown }, handleKeyEvent)
  -- Started lazily inside toOpen(), stopped inside toIdle()
  return self
end

--- RadialMenu:stop()
--- Method
--- Stops all event taps and closes any open menu. The Spoon can be
--- re-activated with `:start()` or `:bindToButton(...)`.
---
--- Returns:
---  * The RadialMenu object
function obj:stop()
  toIdle()
  if _tap    then _tap:stop();    _tap    = nil end
  if _keyTap then _keyTap:stop(); _keyTap = nil end
  if _hotkey then _hotkey:delete(); _hotkey = nil end
  return self
end

--- RadialMenu:bindToButton(button, menuMap)
--- Method
--- Configure the trigger button and the menu definitions, then start the
--- Spoon. Replaces any previous binding.
---
--- Parameters:
---  * button  - integer: macOS mouse button number (0-indexed). `3` = the
---              standard "Mouse4"/back side-button on most mice. May be
---              omitted if the second arg is a table — current
---              `RadialMenu.buttonNumber` will be used.
---  * menuMap - table mapping bundle ID strings (e.g. "com.apple.Safari")
---              and/or the literal key `"default"` to arrays of item
---              tables. The frontmost app's bundle ID is looked up first;
---              `default` is used as a fallback.
---
--- Each item table has the shape:
---   { label = "Display Name",
---     action = { type = "...", ... },   -- OR
---     children = { item, item, ... } }  -- nested sub-menu
---
--- Action types and their fields:
---  * "keystroke"   — mods (table of modifier strings), key (string)
---  * "shell"       — cmd (string, executed via `/bin/sh -c`)
---  * "applescript" — script (string)
---  * "func"        — fn  (Lua function, called with no args)
---  * "launch"      — app (application name or bundle ID)
---  * "url"         — url (string passed to `hs.urlevent.openURL`)
---  * "open"        — path (string passed to `/usr/bin/open`)
---
--- Returns:
---  * The RadialMenu object
function obj:bindToButton(button, menuMap)
  if type(button) == "table" and menuMap == nil then
    menuMap = button
    button  = self.buttonNumber
  end
  self.buttonNumber = button
  if menuMap then _menuMap = menuMap end
  return self:start()
end

--- RadialMenu:bindToHotkey(mods, key, menuMap)
--- Method
--- Bind the menu to a press-and-hold keyboard shortcut. Useful on laptops
--- without extra mouse buttons (e.g. a MacBook trackpad). The interaction
--- mirrors the mouse-button model exactly:
---
---  * Press and hold the hotkey to open the menu at the current cursor.
---  * Move the cursor to a wedge (no button press needed — pointer position
---    alone updates the highlighted wedge).
---  * Release the hotkey to commit the active wedge's action; release in
---    the dead zone or press Esc to cancel.
---
--- This may be combined with `bindToButton` — the two triggers share the
--- same `menuMap` (whichever is passed last wins).
---
--- Parameters:
---  * mods    - table of modifier strings (e.g. {"ctrl","shift","alt","cmd"})
---  * key     - key string (e.g. "r")
---  * menuMap - same shape as `bindToButton`'s menuMap. Optional if you've
---              already configured one via `bindToButton`.
---
--- Returns:
---  * The RadialMenu object
function obj:bindToHotkey(mods, key, menuMap)
  if menuMap then _menuMap = menuMap end
  -- Make sure the mouse / key taps are running so we can track cursor
  -- movement and Esc while the menu is open.
  if not _tap then self:start() end

  if _hotkey then _hotkey:delete(); _hotkey = nil end

  -- Mirror the mouse-button hold semantics so hotkey behavior is
  -- predictable: press-and-hold opens the menu, but a quick tap (release
  -- before holdThreshold) skips the open and consults onShortClick. That
  -- way `hyper+space` while dictation is running stops dictation, the
  -- same as a short middle-click does.
  local pressedAt = nil
  _hotkey = hs.hotkey.bind(mods, key,
    function() -- pressed
      if _state ~= "idle" then return end
      pressedAt = hs.timer.secondsSinceEpoch()
      if _holdTimer then _holdTimer:stop() end
      _holdTimer = hs.timer.doAfter(obj.holdThreshold, function()
        _holdTimer = nil
        if _state == "idle" and pressedAt then toOpen() end
      end)
    end,
    function() -- released
      if _holdTimer then _holdTimer:stop(); _holdTimer = nil end
      local elapsed = pressedAt and (hs.timer.secondsSinceEpoch() - pressedAt) or 999
      pressedAt = nil

      if _state == "open" then
        commitActive()
        return
      end

      -- Released before the menu opened. If onShortClick claims the tap,
      -- consume it; otherwise just open-and-close the menu silently
      -- (preserves the historic "tap opens momentarily" behavior).
      if elapsed < obj.holdThreshold then
        local consumed = false
        if type(obj.onShortClick) == "function" then
          local ok, result = pcall(obj.onShortClick)
          if ok and result then consumed = true end
          if not ok then
            hs.printf("[RadialMenu] onShortClick error: %s", tostring(result))
          end
        end
        if not consumed then
          toOpen()
          commitActive()  -- immediate silent close
        end
      end
    end)
  return self
end

return obj
