-- dictation_overlay.lua
-- A pipeline-progress overlay for the dictation → Ollama flow. Shown
-- bottom-right of the active screen. Pipeline stages:
--
--   start()        →  "🎙  Preparing..."  (ffmpeg opening the device)
--   listening()    →  blinking red dot + mm:ss timer (audio is flowing)
--   transcribing() →  "💭  Transcribing..."
--   heard(text)    →  shows the raw transcription in the HEARD panel
--   rewriting()    →  status flips to "✨  Rewriting..." + WROTE panel opens
--   appendRewrite(token) — append a token to the WROTE panel
--   done()         →  "✓  Done"; auto-hides after a short delay
--   cancel()       →  hide immediately
--
-- We deliberately don't render a waveform. Cheap mics with AGC compress
-- the dynamic range so far that it stays pegged or stays flat — and the
-- only signal the user actually needs is "is audio being captured right
-- now?", which a blinking dot + timer answers unambiguously.

local M = {}

-- ── layout ───────────────────────────────────────────────────────────────
local WIDTH         = 520
local PADDING       = 16
local STATUS_HEIGHT = 28
local SECTION_GAP   = 10
local LINE_HEIGHT   = 18
local MARGIN        = 24
local AUTO_HIDE     = 1.2
-- Extra canvas padding around the card to leave room for the drop shadow.
local SHADOW_PAD    = 18

local DOT_RADIUS    = 5
local DOT_FPS       = 4   -- blink rate (twice per second on/off)

-- ── themes ───────────────────────────────────────────────────────────────
-- Each theme provides the same color slots; `style` toggles a few visual
-- choices (e.g. whether the status row sits inside a colored pill).
local THEMES = {
  vampire = {
    style    = "classic",
    cornerR  = 12,
    shadow   = false,
    bg       = { red = 0.07, green = 0.08, blue = 0.10, alpha = 0.92 },
    border   = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.10 },
    status   = { red = 0.85, green = 0.95, blue = 0.78, alpha = 1.00 },
    label    = { red = 0.55, green = 0.60, blue = 0.62, alpha = 1.00 },
    heard    = { red = 0.90, green = 0.92, blue = 0.95, alpha = 1.00 },
    wrote    = { red = 0.80, green = 0.95, blue = 1.00, alpha = 1.00 },
    done     = { red = 0.60, green = 0.95, blue = 0.70, alpha = 1.00 },
    dot      = { red = 0.95, green = 0.25, blue = 0.25, alpha = 1.00 },
    -- pill colors are unused in classic style
    pillBg   = nil,
    pillText = nil,
    doneBg   = nil,
  },
  pokemon = {
    style    = "card",
    cornerR  = 18,
    shadow   = true,
    bg       = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.98 },
    border   = { red = 0.00, green = 0.00, blue = 0.00, alpha = 0.12 },
    -- Status text color when not wrapped in a pill.
    status   = { red = 0.18, green = 0.18, blue = 0.20, alpha = 1.00 },
    label    = { red = 0.50, green = 0.52, blue = 0.56, alpha = 1.00 },
    heard    = { red = 0.13, green = 0.13, blue = 0.16, alpha = 1.00 },
    wrote    = { red = 0.20, green = 0.45, blue = 0.85, alpha = 1.00 },
    done     = { red = 0.18, green = 0.62, blue = 0.36, alpha = 1.00 },
    dot      = { red = 0.95, green = 0.30, blue = 0.30, alpha = 1.00 },
    -- The status row is wrapped in a sky-blue pill (matches the radial
    -- menu's active-label pill).
    pillBg   = { red = 0.30, green = 0.62, blue = 0.95, alpha = 1.00 },
    pillText = { red = 1.00, green = 1.00, blue = 1.00, alpha = 1.00 },
    -- Done state uses a green pill for the same reason.
    doneBg   = { red = 0.27, green = 0.72, blue = 0.45, alpha = 1.00 },
  },
}

local activeTheme = "vampire"
local T           = THEMES[activeTheme]

-- ── state ────────────────────────────────────────────────────────────────
local canvas       = nil
local statusText   = ""
local statusColor  = T.status
local statusKind   = "neutral"   -- "neutral" | "live" | "done" — drives pill color
local heardText    = ""
local rewriteText  = ""
local hideTimer    = nil
local showRewrite  = false
local listening    = false       -- true once audio is actually flowing
local listenStart  = nil         -- secondsSinceEpoch when listening began
local blinkTimer   = nil

-- ── helpers ──────────────────────────────────────────────────────────────
local function styled(text, color, size, bold)
  return hs.styledtext.new(text or "", {
    font  = { name = bold and ".AppleSystemUIFontBold" or ".AppleSystemUIFont", size = size or 13 },
    color = color,
  })
end

local function estimateLines(text, charsPerLine)
  if not text or text == "" then return 0 end
  local lines = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines = lines + math.max(1, math.ceil(math.max(1, #line) / charsPerLine))
  end
  return math.max(1, lines)
end

local function ensureCanvas()
  if canvas then return end
  canvas = hs.canvas.new({ x = 0, y = 0, w = WIDTH + 2 * SHADOW_PAD, h = 100 + 2 * SHADOW_PAD })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
end

local function fmtTimer(t)
  local s = math.floor(t)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function rebuild()
  ensureCanvas()

  local charsPerLine = math.floor((WIDTH - 2 * PADDING) / 7.2)
  local heardLines   = estimateLines(heardText, charsPerLine)
  local rewriteLines = estimateLines(rewriteText, charsPerLine)

  local heardBlockH   = heardText ~= "" and (LINE_HEIGHT + heardLines * LINE_HEIGHT) or 0
  local rewriteBlockH = (showRewrite and (LINE_HEIGHT + rewriteLines * LINE_HEIGHT)) or 0

  local height = PADDING + STATUS_HEIGHT
              + (heardBlockH   > 0 and (SECTION_GAP + heardBlockH)   or 0)
              + (rewriteBlockH > 0 and (SECTION_GAP + rewriteBlockH) or 0)
              + PADDING

  -- Card sits inset from the canvas edge by SHADOW_PAD so the drop shadow
  -- has room to render outside the card boundary.
  local SX, SY = SHADOW_PAD, SHADOW_PAD
  local canvasW = WIDTH + 2 * SHADOW_PAD
  local canvasH = height + 2 * SHADOW_PAD

  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = screen:frame()
  canvas:frame({
    x = f.x + f.w - WIDTH - MARGIN - SHADOW_PAD,
    y = f.y + f.h - height - MARGIN - SHADOW_PAD,
    w = canvasW,
    h = canvasH,
  })

  local cardFrame = { x = SX, y = SY, w = WIDTH, h = height }

  local elements = {}

  -- Drop shadow: 4 stacked rounded rects, each larger and lower-alpha.
  -- Cheap fake blur — softer than a single shadow rect, no GPU shader.
  if T.shadow then
    for i = 4, 1, -1 do
      local extra = i * 3
      table.insert(elements, {
        type             = "rectangle",
        action           = "fill",
        fillColor        = { red = 0, green = 0, blue = 0, alpha = 0.04 + (5 - i) * 0.025 },
        roundedRectRadii = { xRadius = T.cornerR + extra, yRadius = T.cornerR + extra },
        frame            = {
          x = SX - extra,
          y = SY - extra + 2,           -- bias shadow downward
          w = WIDTH + 2 * extra,
          h = height + 2 * extra,
        },
      })
    end
  end

  table.insert(elements, {
    type = "rectangle", action = "fill", fillColor = T.bg,
    roundedRectRadii = { xRadius = T.cornerR, yRadius = T.cornerR },
    frame = cardFrame,
  })
  table.insert(elements, {
    type = "rectangle", action = "stroke", strokeColor = T.border, strokeWidth = 1,
    roundedRectRadii = { xRadius = T.cornerR, yRadius = T.cornerR },
    frame = cardFrame,
  })

  -- Whether to wrap the status row in a colored pill (pokemon style).
  local usePill = (T.style == "card")

  -- Status row. When listening, draw a blinking dot + timer on the left
  -- and the elapsed-time string in place of the static "Recording" label.
  local statusY = PADDING
  if usePill then
    local pillBg
    if statusKind == "done" and T.doneBg then
      pillBg = T.doneBg
    else
      pillBg = T.pillBg
    end
    if pillBg then
      table.insert(elements, {
        type = "rectangle", action = "fill", fillColor = pillBg,
        roundedRectRadii = { xRadius = STATUS_HEIGHT / 2, yRadius = STATUS_HEIGHT / 2 },
        frame = { x = SX + PADDING, y = SY + statusY,
                  w = WIDTH - 2 * PADDING, h = STATUS_HEIGHT },
      })
    end
  end

  local pillTextColor = (usePill and T.pillText) or statusColor

  -- Vertical-center text inside a STATUS_HEIGHT-tall row. SF text at 14pt
  -- has its visual center ~7pt down from the frame top; with H = 28 we
  -- want a top inset of (28 - 14) / 2 ≈ 7, then nudge by 1 for cap height.
  local statusTextY = statusY + math.floor((STATUS_HEIGHT - 14) / 2) - 1
  local statusTextH = 14 + 6

  if listening then
    local elapsed = hs.timer.secondsSinceEpoch() - (listenStart or 0)
    local on = (math.floor(elapsed * DOT_FPS) % 2) == 0
    -- In pokemon mode the dot reads better as white-on-blue; classic stays red.
    local dotColor = (usePill and T.pillText) or T.dot
    local dotInsetX = usePill and (PADDING + 14) or PADDING
    if on then
      table.insert(elements, {
        type = "circle", action = "fill", fillColor = dotColor,
        center = { x = SX + dotInsetX + DOT_RADIUS, y = SY + statusY + STATUS_HEIGHT / 2 },
        radius = DOT_RADIUS,
      })
    end
    table.insert(elements, {
      type = "text",
      text = styled("Recording   " .. fmtTimer(elapsed), pillTextColor, 14, true),
      frame = { x = SX + dotInsetX + 2 * DOT_RADIUS + 10, y = SY + statusTextY,
                w = WIDTH - 2 * PADDING - 2 * DOT_RADIUS - 10, h = statusTextH },
    })
  else
    -- Status text inside (or in place of) the pill. Center-align in pill mode.
    local txt = styled(statusText, pillTextColor, 14, true)
    if usePill then
      txt = hs.styledtext.new(statusText or "", {
        font           = { name = ".AppleSystemUIFontBold", size = 14 },
        color          = pillTextColor,
        paragraphStyle = { alignment = "center" },
      })
    end
    table.insert(elements, {
      type = "text",
      text = txt,
      frame = { x = SX + PADDING, y = SY + statusTextY,
                w = WIDTH - 2 * PADDING, h = statusTextH },
    })
  end

  local y = PADDING + STATUS_HEIGHT + SECTION_GAP

  if heardText ~= "" then
    table.insert(elements, { type = "text",
      text = styled("HEARD", T.label, 10, true),
      frame = { x = SX + PADDING, y = SY + y, w = WIDTH - 2 * PADDING, h = LINE_HEIGHT } })
    table.insert(elements, { type = "text",
      text = styled(heardText, T.heard, 13, false),
      frame = { x = SX + PADDING, y = SY + y + LINE_HEIGHT,
                w = WIDTH - 2 * PADDING, h = heardBlockH - LINE_HEIGHT } })
    y = y + heardBlockH + SECTION_GAP
  end

  if showRewrite then
    table.insert(elements, { type = "text",
      text = styled("WROTE", T.label, 10, true),
      frame = { x = SX + PADDING, y = SY + y, w = WIDTH - 2 * PADDING, h = LINE_HEIGHT } })
    table.insert(elements, { type = "text",
      text = styled(rewriteText, T.wrote, 13, false),
      frame = { x = SX + PADDING, y = SY + y + LINE_HEIGHT,
                w = WIDTH - 2 * PADDING, h = rewriteBlockH - LINE_HEIGHT } })
  end

  canvas:replaceElements(elements)
end

-- kind: "neutral" (default) | "live" (recording/processing) | "done"
local function setStatus(emoji, label, color, kind)
  statusText  = emoji .. "  " .. label
  statusColor = color or T.status
  statusKind  = kind or "neutral"
  rebuild()
  if canvas and not canvas:isShowing() then canvas:show() end
end

local function clearHideTimer()
  if hideTimer then hideTimer:stop(); hideTimer = nil end
end

local function startBlinkTimer()
  if blinkTimer then return end
  blinkTimer = hs.timer.doEvery(1 / (DOT_FPS * 2), rebuild)
end

local function stopBlinkTimer()
  if blinkTimer then blinkTimer:stop(); blinkTimer = nil end
end

-- ── public API ───────────────────────────────────────────────────────────

function M.start()
  clearHideTimer()
  heardText, rewriteText = "", ""
  showRewrite = false
  listening = false
  listenStart = nil
  setStatus("🎙", "Preparing...")
end

--- Audio is now actually flowing. Switch to the recording-dot indicator.
function M.listening()
  clearHideTimer()
  listening = true
  listenStart = hs.timer.secondsSinceEpoch()
  rebuild()
  if canvas and not canvas:isShowing() then canvas:show() end
  startBlinkTimer()
end

function M.transcribing()
  clearHideTimer()
  listening = false
  stopBlinkTimer()
  setStatus("💭", "Transcribing", nil, "live")
end

function M.heard(text)
  clearHideTimer()
  heardText = text or ""
  rebuild()
end

function M.appendHeard(token)
  if not token or token == "" then return end
  clearHideTimer()
  heardText = heardText .. token
  rebuild()
end

function M.rewriting()
  clearHideTimer()
  showRewrite = true
  setStatus("✨", "Rewriting", nil, "live")
end

function M.appendRewrite(token)
  if not token or token == "" then return end
  rewriteText = rewriteText .. token
  rebuild()
end

function M.done()
  listening = false
  stopBlinkTimer()
  setStatus("✓", "Done", T.done, "done")
  clearHideTimer()
  hideTimer = hs.timer.doAfter(AUTO_HIDE, M.cancel)
end

--- Switch the visual theme. Accepts "vampire" or "pokemon" (or any other
--- key registered in the THEMES table). If the overlay is currently
--- visible, it re-renders with the new theme on the next rebuild().
function M.setTheme(name)
  local t = THEMES[name]
  if not t then
    hs.printf("[dictation_overlay] unknown theme: %s", tostring(name))
    return
  end
  activeTheme = name
  T = t
  if canvas and canvas:isShowing() then rebuild() end
end

function M.cancel()
  clearHideTimer()
  stopBlinkTimer()
  if canvas then
    canvas:hide()
    canvas:delete()
    canvas = nil
  end
  statusText, heardText, rewriteText = "", "", ""
  showRewrite = false
  listening = false
  listenStart = nil
end

return M
