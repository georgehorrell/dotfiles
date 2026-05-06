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
local STATUS_HEIGHT = 26
local SECTION_GAP   = 10
local LINE_HEIGHT   = 18
local MARGIN        = 24
local AUTO_HIDE     = 1.2

local DOT_RADIUS    = 5
local DOT_FPS       = 4   -- blink rate (twice per second on/off)

-- ── colors ───────────────────────────────────────────────────────────────
local C_BG       = { red = 0.07, green = 0.08, blue = 0.10, alpha = 0.92 }
local C_BORDER   = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.10 }
local C_STATUS   = { red = 0.85, green = 0.95, blue = 0.78, alpha = 1.00 }
local C_LABEL    = { red = 0.55, green = 0.60, blue = 0.62, alpha = 1.00 }
local C_HEARD    = { red = 0.90, green = 0.92, blue = 0.95, alpha = 1.00 }
local C_WROTE    = { red = 0.80, green = 0.95, blue = 1.00, alpha = 1.00 }
local C_DONE     = { red = 0.60, green = 0.95, blue = 0.70, alpha = 1.00 }
local C_DOT      = { red = 0.95, green = 0.25, blue = 0.25, alpha = 1.00 }

-- ── state ────────────────────────────────────────────────────────────────
local canvas       = nil
local statusText   = ""
local statusColor  = C_STATUS
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
  canvas = hs.canvas.new({ x = 0, y = 0, w = WIDTH, h = 100 })
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

  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = screen:frame()
  canvas:frame({
    x = f.x + f.w - WIDTH - MARGIN,
    y = f.y + f.h - height - MARGIN,
    w = WIDTH,
    h = height,
  })

  local elements = {
    { type = "rectangle", action = "fill", fillColor = C_BG,
      roundedRectRadii = { xRadius = 12, yRadius = 12 } },
    { type = "rectangle", action = "stroke", strokeColor = C_BORDER, strokeWidth = 1,
      roundedRectRadii = { xRadius = 12, yRadius = 12 } },
  }

  -- Status row. When listening, draw a blinking dot + timer on the left
  -- and the elapsed-time string in place of the static "Recording" label.
  local statusY = PADDING
  if listening then
    local elapsed = hs.timer.secondsSinceEpoch() - (listenStart or 0)
    local on = (math.floor(elapsed * DOT_FPS) % 2) == 0
    if on then
      table.insert(elements, {
        type = "circle", action = "fill", fillColor = C_DOT,
        center = { x = PADDING + DOT_RADIUS, y = statusY + STATUS_HEIGHT / 2 },
        radius = DOT_RADIUS,
      })
    end
    table.insert(elements, {
      type = "text",
      text = styled("Recording   " .. fmtTimer(elapsed), C_STATUS, 14, true),
      frame = { x = PADDING + 2 * DOT_RADIUS + 10, y = statusY,
                w = WIDTH - 2 * PADDING - 2 * DOT_RADIUS - 10, h = STATUS_HEIGHT },
    })
  else
    table.insert(elements, {
      type = "text",
      text = styled(statusText, statusColor, 14, true),
      frame = { x = PADDING, y = statusY, w = WIDTH - 2 * PADDING, h = STATUS_HEIGHT },
    })
  end

  local y = PADDING + STATUS_HEIGHT + SECTION_GAP

  if heardText ~= "" then
    table.insert(elements, { type = "text",
      text = styled("HEARD", C_LABEL, 10, true),
      frame = { x = PADDING, y = y, w = WIDTH - 2 * PADDING, h = LINE_HEIGHT } })
    table.insert(elements, { type = "text",
      text = styled(heardText, C_HEARD, 13, false),
      frame = { x = PADDING, y = y + LINE_HEIGHT,
                w = WIDTH - 2 * PADDING, h = heardBlockH - LINE_HEIGHT } })
    y = y + heardBlockH + SECTION_GAP
  end

  if showRewrite then
    table.insert(elements, { type = "text",
      text = styled("WROTE", C_LABEL, 10, true),
      frame = { x = PADDING, y = y, w = WIDTH - 2 * PADDING, h = LINE_HEIGHT } })
    table.insert(elements, { type = "text",
      text = styled(rewriteText, C_WROTE, 13, false),
      frame = { x = PADDING, y = y + LINE_HEIGHT,
                w = WIDTH - 2 * PADDING, h = rewriteBlockH - LINE_HEIGHT } })
  end

  canvas:replaceElements(elements)
end

local function setStatus(emoji, label, color)
  statusText  = emoji .. "  " .. label
  statusColor = color or C_STATUS
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
  setStatus("💭", "Transcribing")
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
  setStatus("✨", "Rewriting")
end

function M.appendRewrite(token)
  if not token or token == "" then return end
  rewriteText = rewriteText .. token
  rebuild()
end

function M.done()
  listening = false
  stopBlinkTimer()
  setStatus("✓", "Done", C_DONE)
  clearHideTimer()
  hideTimer = hs.timer.doAfter(AUTO_HIDE, M.cancel)
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
