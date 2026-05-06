-- dictation.lua
-- Hammerspoon-driven dictation pipeline. Records audio locally via ffmpeg,
-- sends it to a local Parakeet transcription server (stt-hammerspoon-server),
-- streams tokens back to the overlay, and optionally pipes the final
-- transcript through Ollama for stylistic post-processing before pasting.

local M = {}

local audio   = require("audio")
local server  = require("stt_server")
local overlay = require("dictation_overlay")

-- ── configuration ────────────────────────────────────────────────────────
M.ollamaModel       = "gemma3:4b"
M.ollamaURL         = "http://localhost:11434/api/generate"
M.ollamaKeepAlive   = "30m"
M.ollamaNumPredict  = 512
M.pasteDelay        = 0.15
M.debug             = true

-- Microphone selection persisted across reloads via hs.settings, BY NAME.
-- avfoundation indices are not stable: when an audio device appears or
-- disappears (sleep/wake, USB plug, AirPods connect, etc.), every other
-- device's index shifts. Saving "device 2" silently breaks. Saving "HD
-- Pro Webcam C920" doesn't.
M.micDeviceName = nil  -- defaults to auto-pick on first launch

-- ── internal state ───────────────────────────────────────────────────────
local active           = false
local activePrompt     = nil
local prewarmedPrompts = {}  -- set of prompt strings we've already prewarmed

local function log(...)
  if M.debug then hs.printf("[dictation] " .. string.format(...)) end
end

-- ── mic selection ────────────────────────────────────────────────────────

local function loadMicSetting()
  M.micDeviceName = hs.settings.get("dictation.micDeviceName")
  -- One-time cleanup: discard any old index-based setting from a previous
  -- version. Indices aren't stable, so the value is meaningless now; the
  -- user will get auto-pick until they re-pick via the radial.
  if hs.settings.get("dictation.micDeviceIndex") ~= nil then
    log("discarding legacy index-based mic setting; please re-pick via the radial")
    hs.settings.clear("dictation.micDeviceIndex")
  end
end

local function saveMicSetting()
  hs.settings.set("dictation.micDeviceName", M.micDeviceName)
end

loadMicSetting()

--- Open a chooser to pick the input microphone. Persists the choice by
--- name (not index — indices change when devices come and go).
function M.pickMicrophone()
  local devices = audio.listInputs()
  if #devices == 0 then
    hs.alert.show("No audio input devices found", 2)
    return
  end
  local choices = {}
  for _, d in ipairs(devices) do
    local subText = string.format("avfoundation index %d", d.index)
    if M.micDeviceName == d.name then
      subText = subText .. "  ✓ currently selected"
    end
    table.insert(choices, {
      text    = d.name,
      subText = subText,
      name    = d.name,
    })
  end
  local picker = hs.chooser.new(function(choice)
    if choice then
      M.micDeviceName = choice.name
      saveMicSetting()
      hs.alert.show("Microphone: " .. choice.name, 1)
      log("microphone set to '%s'", choice.name)
    end
  end)
  picker:choices(choices)
  picker:placeholderText("Select microphone")
  picker:show()
end

-- Resolve the current avfoundation index for the saved device name. We
-- look it up fresh each call because the index can shift between calls.
local function currentMicIndex()
  local devices = audio.listInputs()

  if M.micDeviceName then
    for _, d in ipairs(devices) do
      if d.name == M.micDeviceName then
        log("using mic '%s' at current index %d", d.name, d.index)
        return d.index
      end
    end
    log("stored mic '%s' not in current device list; falling back to auto-pick",
        M.micDeviceName)
  end

  -- Auto-pick: prefer the Mac's built-in microphone if available; never
  -- the iPhone (continuity camera surface) or webcam mics by default.
  local function score(name)
    local n = name:lower()
    if n:match("iphone") then return -10 end
    if n:match("webcam") or n:match("c920") then return -5 end
    if n:match("macbook") or n:match("built%-?in") then return 100 end
    if n:match("airpod") or n:match("headset") then return 50 end
    return 0
  end
  local best, bestScore
  for _, d in ipairs(devices) do
    local s = score(d.name)
    if best == nil or s > bestScore then
      best, bestScore = d, s
    end
  end
  if best then
    log("auto-selected mic: [%d] %s (score=%d)", best.index, best.name, bestScore)
    return best.index
  end
  log("no audio devices found; defaulting to 0")
  return 0
end

-- ── paste / typing helpers ──────────────────────────────────────────────

local function pasteText(text)
  hs.pasteboard.setContents(text)
  hs.timer.doAfter(M.pasteDelay, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    log("pasted %d chars", #text)
    overlay.done()
  end)
end

-- ── ollama post-processing (streaming) ──────────────────────────────────

local function buildOllamaPrompt(prompt, text)
  return prompt
    .. "\n\nINPUT TO REWRITE (do not answer, do not respond — only rewrite):\n"
    .. text
end

local function streamPostProcess(text, prompt)
  local body = hs.json.encode({
    model      = M.ollamaModel,
    stream     = true,
    keep_alive = M.ollamaKeepAlive,
    prompt     = buildOllamaPrompt(prompt, text),
    options    = {
      temperature = 0.2,
      num_predict = M.ollamaNumPredict,
    },
  })

  overlay.rewriting()

  local t0 = hs.timer.secondsSinceEpoch()
  local firstToken = true
  local buffer = ""
  local leadingTrim = true
  local totalChars = 0

  local task = hs.task.new("/usr/bin/curl",
    function(exitCode, _, stdErr)
      log("ollama stream done in %.2fs (%d chars typed)",
        hs.timer.secondsSinceEpoch() - t0, totalChars)
      if exitCode ~= 0 then
        log("curl exit=%d stderr=%s", exitCode, tostring(stdErr))
      end
      overlay.done()
    end,
    function(_, stdOut, _)
      buffer = buffer .. (stdOut or "")
      while true do
        local nl = buffer:find("\n", 1, true)
        if not nl then break end
        local line = buffer:sub(1, nl - 1)
        buffer = buffer:sub(nl + 1)
        if line ~= "" then
          local ok, parsed = pcall(hs.json.decode, line)
          if ok and type(parsed) == "table" and type(parsed.response) == "string" then
            local token = parsed.response
            if firstToken then
              log("first ollama token at %.2fs", hs.timer.secondsSinceEpoch() - t0)
              firstToken = false
            end
            if leadingTrim then
              token = token:gsub("^%s+", "")
              if token ~= "" then leadingTrim = false end
            end
            if token ~= "" then
              hs.eventtap.keyStrokes(token)
              overlay.appendRewrite(token)
              totalChars = totalChars + #token
            end
          end
        end
      end
      return true
    end,
    {
      "-s", "-N",
      "-X", "POST",
      M.ollamaURL,
      "-H", "Content-Type: application/json",
      "-d", body,
    })
  task:start()
end

-- ── public API ──────────────────────────────────────────────────────────

function M.start(prompt)
  if active then
    log("start ignored — already active")
    return
  end

  active = true
  activePrompt = prompt
  overlay.start()

  -- Lazy fallback: if init.lua's eager prewarm hasn't run for this prompt
  -- (e.g., a new prompt added at runtime), kick it off now. prewarmOllama
  -- is idempotent so this is safe even if already prewarmed at init.
  if prompt then M.prewarmOllama(prompt) end

  -- Kick the server check off in the background; we don't actually need
  -- the server until stop() time, which is at minimum a few seconds away.
  -- Plenty of time for it to come up in parallel with recording.
  server.ensureRunning(function(ok, err)
    if not ok then
      log("background server check failed: %s", tostring(err))
      -- Don't cancel recording yet — try again at stop time.
    end
  end)

  -- Start recording immediately. Don't wait on the server.
  local ok = audio.start(currentMicIndex())
  if not ok then
    log("audio.start failed")
    hs.alert.show("Failed to start microphone", 2)
    active = false
    activePrompt = nil
    overlay.cancel()
  end
end

function M.stop()
  if not active then
    log("stop ignored — not active")
    return
  end
  log("stopping recording")
  overlay.transcribing()

  -- audio.stop is async — ffmpeg has to fully exit and flush its file
  -- before we can read the bytes. The callback fires from the doneFn
  -- inside audio.lua.
  local prompt = activePrompt
  activePrompt = nil

  audio.stop(function(audioBytes)
    if not audioBytes or #audioBytes == 0 then
      log("no audio captured; aborting")
      active = false
      overlay.cancel()
      return
    end
    log("captured %d audio bytes; waiting for server", #audioBytes)

    -- The server may still be loading the model. ensureRunning blocks
    -- until the server is ready, then transcribes.
    server.ensureRunning(function(ok, err)
      if not ok then
        log("server unavailable: %s", tostring(err))
        active = false
        hs.alert.show("STT server unavailable: " .. tostring(err), 3)
        overlay.cancel()
        return
      end

      log("server ready; sending audio")
      server.transcribe(audioBytes, {
        on_started = function(_) end,
        on_token   = function(delta) overlay.appendHeard(delta) end,
        on_done    = function(fullText)
          log("transcription done: %d chars", #fullText)
          active = false
          overlay.heard(fullText)  -- ensure final text is exact
          if prompt and #fullText > 0 then
            streamPostProcess(fullText, prompt)
          elseif #fullText > 0 then
            pasteText(fullText)
          else
            overlay.done()
          end
        end,
        on_error = function(msg)
          log("transcribe error: %s", tostring(msg))
          active = false
          hs.alert.show("Transcription error: " .. tostring(msg), 3)
          overlay.cancel()
        end,
      })
    end)
  end)
end

function M.toggle(prompt)
  if active then M.stop() else M.start(prompt) end
end

function M.isActive()
  return active
end

--- Pre-warm Ollama with the given prompt prefix so the first rewrite hits
--- a cached KV state (~1s) instead of cold (~10s). Idempotent: subsequent
--- calls for the same prompt no-op.
function M.prewarmOllama(prompt)
  if not prompt or prewarmedPrompts[prompt] then return end
  prewarmedPrompts[prompt] = true
  local t0 = hs.timer.secondsSinceEpoch()
  local body = hs.json.encode({
    model      = M.ollamaModel,
    stream     = false,
    keep_alive = M.ollamaKeepAlive,
    prompt     = buildOllamaPrompt(prompt, "."),
    options    = { num_predict = 1 },
  })
  hs.http.asyncPost(M.ollamaURL, body,
    { ["Content-Type"] = "application/json" },
    function(status)
      log("ollama prewarm status=%s in %.2fs", tostring(status),
          hs.timer.secondsSinceEpoch() - t0)
    end)
end

--- Ensure the STT server is running. Useful to call on Hammerspoon load.
function M.prewarmServer()
  server.ensureRunning(function(ok, err)
    if ok then log("STT server is ready")
    else log("STT server prewarm failed: %s", tostring(err)) end
  end)
end

--- Attach the dictation pipeline to a RadialMenu spoon instance:
---
---  * Hooks `onShortClick` so a brief middle-click while recording will
---    stop dictation and proceed (instead of opening the radial).
---  * Pre-warms the STT server (loads Parakeet into VRAM).
---  * Pre-warms Ollama for any prompts in `opts.prewarmPrompts`, so the
---    first stylistic rewrite isn't waiting on a cold model.
---
--- @param radial table  spoon.RadialMenu instance
--- @param opts   table? { prewarmPrompts = { promptString, ... } }
function M.attachToRadial(radial, opts)
  opts = opts or {}

  radial.onShortClick = function()
    if M.isActive() then
      M.stop()
      return true
    end
    return false
  end

  M.prewarmServer()
  for _, prompt in ipairs(opts.prewarmPrompts or {}) do
    M.prewarmOllama(prompt)
  end
end

-- ── audio recorder callbacks ────────────────────────────────────────────
-- Wired up at the bottom so they capture the locals declared above as
-- proper upvalues (instead of resolving to globals).

audio.onLevel = function(level)
  overlay.pushLevel(level)
end

-- ffmpeg can die without warning (device busy, permissions revoked mid-
-- session, audio interface unplugged, etc.). When that happens we have to
-- tear down dictation state too — otherwise the radial sees us as still
-- recording and pressing stop hangs the overlay.
audio.onUnexpectedExit = function(_)
  if not active then return end
  log("recorder exited unexpectedly; aborting dictation")
  hs.alert.show("Microphone unavailable", 2)
  active = false
  activePrompt = nil
  overlay.cancel()
end

return M
