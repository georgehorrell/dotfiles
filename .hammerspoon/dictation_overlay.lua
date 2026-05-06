-- dictation_overlay.lua
-- A pipeline-progress overlay for the dictation → Ollama flow. Shown
-- bottom-right of the active screen. Updates in stages:
--
--   start()        →  "🎙  Listening..."
--   transcribing() →  "💭  Transcribing..."
--   heard(text)    →  shows the raw transcription
--   rewriting()    →  status flips to "✨  Rewriting..." and a second
--                     panel opens for the streaming rewrite output
--   appendRewrite(token) — append a token to the rewrite panel
--   done()         →  "✓  Done"; auto-hides after a short delay
--   cancel()       →  hide immediately

local M = {}

-- ── layout constants ──────────────────────────────────────────────────────
local WIDTH         = 520
local PADDING       = 16
local STATUS_HEIGHT = 26
local SECTION_GAP   = 10
local LINE_HEIGHT   = 18  -- approx; used for height estimation
local MARGIN        = 24  -- distance from screen edge
local AUTO_HIDE     = 1.2 -- seconds the "Done" state lingers

-- waveform layout
local WAVE_HEIGHT   = 36   -- height of the waveform strip
local WAVE_BARS     = 48   -- number of bars across the strip
local WAVE_BAR_GAP  = 2    -- px between bars
local WAVE_FPS      = 30   -- animation frame rate while listening
local WAVE_MIN_PX   = 2    -- minimum bar height so silent bars stay visible

-- Per-bar fixed weights — gives the strip a "natural" non-uniform look
-- regardless of audio level. Each bar's apparent height is this weight
-- times the current audio level, with a subtle time-varying overlay so
-- the whole thing breathes even when level is steady.
local barWeights = nil
local function ensureBarWeights()
  if barWeights then return end
  barWeights = {}
  for i = 1, WAVE_BARS do
    -- Two summed sines with mismatched periods → looks pseudo-random but
    -- is continuous and reproducible (no rng state).
    local v = 0.5
        + 0.30 * math.sin(i * 0.73)
        + 0.20 * math.sin(i * 1.91 + 1.4)
    -- Clamp to [0.35, 1.0] so the smallest bars are still meaningfully tall
    -- when the user is talking.
    if v < 0.35 then v = 0.35 elseif v > 1.0 then v = 1.0 end
    barWeights[i] = v
  end
end

-- ── colors ────────────────────────────────────────────────────────────────
local C_BG       = { red = 0.07, green = 0.08, blue = 0.10, alpha = 0.92 }
local C_BORDER   = { red = 1.00, green = 1.00, blue = 1.00, alpha = 0.10 }
local C_STATUS   = { red = 0.85, green = 0.95, blue = 0.78, alpha = 1.00 }
local C_LABEL    = { red = 0.55, green = 0.60, blue = 0.62, alpha = 1.00 }
local C_HEARD    = { red = 0.90, green = 0.92, blue = 0.95, alpha = 1.00 }
local C_WROTE    = { red = 0.80, green = 0.95, blue = 1.00, alpha = 1.00 }
local C_DONE     = { red = 0.60, green = 0.95, blue = 0.70, alpha = 1.00 }
local C_WAVE     = { red = 0.85, green = 0.55, blue = 0.20, alpha = 0.95 }

-- ── state ────────────────────────────────────────────────────────────────
local canvas      = nil
local statusText  = ""
local statusColor = C_STATUS
local heardText   = ""
local rewriteText = ""
local hideTimer   = nil
local showRewriteSection = false
local showWave    = false
local audioLevel  = 0     -- current normalized level [0..1]; pushed by audio.lua
local waveSmoothed = 0    -- additional EMA so the visual is buttery smooth
local waveAnimTimer = nil
local waveStartedAt = nil

-- ── helpers ──────────────────────────────────────────────────────────────
local function styled(text, color, size, bold)
  return hs.styledtext.new(text or "", {
    font  = { name = bold and ".AppleSystemUIFontBold" or ".AppleSystemUIFont", size = size or 13 },
    color = color,
  })
end

-- Rough text-wrap line estimate at ~7.2 px/char for size 13.
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

local function rebuild()
  ensureCanvas()

  local charsPerLine = math.floor((WIDTH - 2 * PADDING) / 7.2)
  local heardLines   = estimateLines(heardText, charsPerLine)
  local rewriteLines = estimateLines(rewriteText, charsPerLine)

  local heardBlockH   = heardText ~= "" and (LINE_HEIGHT + heardLines * LINE_HEIGHT) or 0
  local rewriteBlockH = (showRewriteSection and (LINE_HEIGHT + rewriteLines * LINE_HEIGHT)) or 0
  local waveBlockH    = showWave and WAVE_HEIGHT or 0

  local height = PADDING + STATUS_HEIGHT
              + (waveBlockH    > 0 and (SECTION_GAP + waveBlockH)    or 0)
              + (heardBlockH   > 0 and (SECTION_GAP + heardBlockH)   or 0)
              + (rewriteBlockH > 0 and (SECTION_GAP + rewriteBlockH) or 0)
              + PADDING

  -- Position bottom-right of the active screen.
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = screen:frame()
  canvas:frame({
    x = f.x + f.w - WIDTH - MARGIN,
    y = f.y + f.h - height - MARGIN,
    w = WIDTH,
    h = height,
  })

  -- Build the element list, then assign all at once via `:elements()`.
  local elements = {
    -- Background.
    {
      type = "rectangle", action = "fill",
      fillColor = C_BG,
      roundedRectRadii = { xRadius = 12, yRadius = 12 },
    },
    -- Soft border.
    {
      type = "rectangle", action = "stroke",
      strokeColor = C_BORDER, strokeWidth = 1,
      roundedRectRadii = { xRadius = 12, yRadius = 12 },
    },
    -- Status line.
    {
      type = "text",
      text = styled(statusText, statusColor, 14, true),
      frame = { x = PADDING, y = PADDING, w = WIDTH - 2 * PADDING, h = STATUS_HEIGHT },
    },
  }

  local y = PADDING + STATUS_HEIGHT + SECTION_GAP

  if showWave then
    ensureBarWeights()
    local stripW = WIDTH - 2 * PADDING
    local stripX = PADDING
    local stripY = y
    local barW   = (stripW + WAVE_BAR_GAP) / WAVE_BARS - WAVE_BAR_GAP
    local cy     = stripY + waveBlockH / 2

    -- Time-based phase so the wave subtly moves even at steady level.
    local now = hs.timer.secondsSinceEpoch()
    local t   = waveStartedAt and (now - waveStartedAt) or 0
    -- Visual smoothing on top of audio.lua's EMA — the wave never jumps.
    local target = audioLevel
    waveSmoothed = waveSmoothed + (target - waveSmoothed) * 0.25

    for i = 1, WAVE_BARS do
      -- Subtle per-bar oscillation (10-15% modulation) — keeps the strip
      -- feeling alive when you're holding a steady note.
      local osc = 0.88 + 0.12 * math.sin(t * 6.0 + i * 0.5)
      local weight = barWeights[i] * osc
      local h = waveSmoothed * waveBlockH * weight
      if h < WAVE_MIN_PX then h = WAVE_MIN_PX end
      local x = stripX + (i - 1) * (barW + WAVE_BAR_GAP)
      table.insert(elements, {
        type = "rectangle",
        action = "fill",
        fillColor = C_WAVE,
        frame = { x = x, y = cy - h / 2, w = barW, h = h },
        roundedRectRadii = { xRadius = 1, yRadius = 1 },
      })
    end
    y = y + waveBlockH + SECTION_GAP
  end

  if heardText ~= "" then
    table.insert(elements, {
      type = "text",
      text = styled("HEARD", C_LABEL, 10, true),
      frame = { x = PADDING, y = y, w = WIDTH - 2 * PADDING, h = LINE_HEIGHT },
    })
    table.insert(elements, {
      type = "text",
      text = styled(heardText, C_HEARD, 13, false),
      frame = { x = PADDING, y = y + LINE_HEIGHT, w = WIDTH - 2 * PADDING, h = heardBlockH - LINE_HEIGHT },
    })
    y = y + heardBlockH + SECTION_GAP
  end

  if showRewriteSection then
    table.insert(elements, {
      type = "text",
      text = styled("WROTE", C_LABEL, 10, true),
      frame = { x = PADDING, y = y, w = WIDTH - 2 * PADDING, h = LINE_HEIGHT },
    })
    table.insert(elements, {
      type = "text",
      text = styled(rewriteText, C_WROTE, 13, false),
      frame = { x = PADDING, y = y + LINE_HEIGHT, w = WIDTH - 2 * PADDING, h = rewriteBlockH - LINE_HEIGHT },
    })
  end

  -- Replace the entire element list. This is the robust idiom.
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

local function startWaveAnimation()
  if waveAnimTimer then return end
  waveStartedAt = hs.timer.secondsSinceEpoch()
  waveAnimTimer = hs.timer.doEvery(1 / WAVE_FPS, rebuild)
end

local function stopWaveAnimation()
  if waveAnimTimer then waveAnimTimer:stop(); waveAnimTimer = nil end
  waveStartedAt = nil
  waveSmoothed = 0
  audioLevel   = 0
end

-- ── public API ────────────────────────────────────────────────────────────

function M.start()
  clearHideTimer()
  heardText = ""
  rewriteText = ""
  showRewriteSection = false
  showWave = true
  audioLevel = 0
  waveSmoothed = 0
  setStatus("🎙", "Listening")
  startWaveAnimation()
end

function M.transcribing()
  clearHideTimer()
  showWave = false
  stopWaveAnimation()
  setStatus("💭", "Transcribing")
end

--- Push a new audio level (0..1). Just updates the current target;
--- the animation timer drives the actual repainting.
function M.pushLevel(level)
  if not showWave then return end
  if level == nil then return end
  if level < 0 then level = 0 elseif level > 1 then level = 1 end
  audioLevel = level
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
  showRewriteSection = true
  setStatus("✨", "Rewriting")
end

function M.appendRewrite(token)
  if not token or token == "" then return end
  rewriteText = rewriteText .. token
  rebuild()
end

function M.done()
  setStatus("✓", "Done", C_DONE)
  clearHideTimer()
  hideTimer = hs.timer.doAfter(AUTO_HIDE, function()
    M.cancel()
  end)
end

function M.cancel()
  clearHideTimer()
  stopWaveAnimation()
  if canvas then
    canvas:hide()
    canvas:delete()
    canvas = nil
  end
  statusText = ""
  heardText = ""
  rewriteText = ""
  showRewriteSection = false
  showWave = false
end

return M
