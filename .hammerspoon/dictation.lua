-- dictation.lua
-- Hammerspoon-driven dictation pipeline. Streams audio from the local
-- stt-server's /record endpoint, sends it back to the same server's
-- /transcribe endpoint, streams tokens into the overlay, and optionally
-- pipes the final transcript through Ollama for stylistic rewriting
-- before pasting.

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
M.serverBase        = "http://127.0.0.1:47821"
M.debug             = true

-- Read the auth token written by stt-server on startup. Re-read each
-- call since the token regenerates on every server launch.
local function readToken()
  local f = io.open(os.getenv("HOME") .. "/.local/state/stt-server/auth.token", "r")
  if not f then return nil end
  local t = f:read("*l")
  if f then f:close() end
  return t and #t > 0 and t or nil
end

-- ── internal state ───────────────────────────────────────────────────────
local active           = false
local activePrompt     = nil
local prewarmedPrompts = {}  -- set of prompt strings we've already prewarmed
local startT0          = nil -- secondsSinceEpoch at M.start entry; used to
                             -- log per-stage latency until first PCM byte

local function log(...)
  if M.debug then hs.printf("[dictation] " .. string.format(...)) end
end

local function logStage(label)
  if not startT0 then return end
  local ms = (hs.timer.secondsSinceEpoch() - startT0) * 1000
  hs.printf("[dictation] [+%6.1fms] %s", ms, label)
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
  startT0 = hs.timer.secondsSinceEpoch()
  logStage("M.start entered")

  -- Show the overlay synchronously, then yield to the event loop so the
  -- canvas paints before we kick off any HTTP work.
  overlay.start()
  logStage("overlay.start() returned")

  hs.timer.doAfter(0, function()
    if not active then return end
    logStage("deferred tick fired")

    if prompt then M.prewarmOllama(prompt) end

    -- audio.start opens a streaming HTTP connection to the server's
    -- /record endpoint. The server has AUHAL pre-initialized, so the
    -- first sample arrives within ~80ms.
    local ok = audio.start()
    logStage("audio.start() returned")
    if not ok then
      log("audio.start failed — is stt-server running?")
      hs.alert.show("Failed to start microphone (is stt-server up?)", 3)
      active = false
      activePrompt = nil
      startT0 = nil
      overlay.cancel()
    end
  end)
end

function M.stop()
  if not active then
    log("stop ignored — not active")
    return
  end
  log("stopping recording")
  overlay.transcribing()

  local prompt = activePrompt
  activePrompt = nil

  audio.stop(function(audioBytes)
    if not audioBytes or #audioBytes == 0 then
      log("no audio captured; aborting")
      active = false
      overlay.cancel()
      return
    end
    log("captured %d audio bytes; sending to /transcribe", #audioBytes)

    -- The recording came from the same server we're about to send it
    -- to, so it's already up — but be defensive in case it crashed.
    server.ensureRunning(function(ok, err)
      if not ok then
        log("server unavailable: %s", tostring(err))
        active = false
        hs.alert.show("STT server unavailable: " .. tostring(err), 3)
        overlay.cancel()
        return
      end

      server.transcribe(audioBytes, {
        on_started = function(_) end,
        on_token   = function(delta) overlay.appendHeard(delta) end,
        on_done    = function(fullText)
          log("transcription done: %d chars", #fullText)
          active = false
          overlay.heard(fullText)
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

--- Open a chooser to pick the input microphone. Driven by the server's
--- /mics endpoints; the server holds the AudioUnit and the selection.
function M.pickMicrophone()
  local token = readToken()
  if not token then
    hs.alert.show("STT server not running", 2)
    return
  end

  hs.http.asyncGet(M.serverBase .. "/mics?token=" .. token, nil, function(status, body)
    if status ~= 200 then
      hs.alert.show("Failed to list mics: HTTP " .. tostring(status), 2)
      return
    end
    local ok, parsed = pcall(hs.json.decode, body)
    if not ok or type(parsed) ~= "table" or type(parsed.devices) ~= "table" then
      hs.alert.show("Bad response from /mics", 2)
      return
    end
    if #parsed.devices == 0 then
      hs.alert.show("No input devices found", 2)
      return
    end

    local choices = {}
    for _, d in ipairs(parsed.devices) do
      local sub = {}
      if d.is_current then table.insert(sub, "✓ currently selected") end
      if d.is_default then table.insert(sub, "system default") end
      table.insert(sub, "id " .. tostring(d.id))
      table.insert(choices, {
        text    = d.name,
        subText = table.concat(sub, "  ·  "),
        deviceId = d.id,
      })
    end

    local picker = hs.chooser.new(function(choice)
      if not choice then return end
      local url = string.format("%s/mics/select?token=%s&id=%d",
          M.serverBase, token, choice.deviceId)
      hs.http.asyncPost(url, "", nil, function(s, b)
        if s == 200 then
          hs.alert.show("Microphone: " .. choice.text, 1)
          log("microphone set to '%s' (id=%d)", choice.text, choice.deviceId)
        else
          local msg = "Failed to switch mic"
          local pok, pj = pcall(hs.json.decode, b or "")
          if pok and type(pj) == "string" then msg = msg .. ": " .. pj end
          hs.alert.show(msg .. " (HTTP " .. tostring(s) .. ")", 3)
        end
      end)
    end)
    picker:choices(choices)
    picker:placeholderText("Select microphone")
    picker:show()
  end)
end

function M.isActive()
  return active
end

--- Pre-warm Ollama with the given prompt prefix so the first rewrite hits
--- a cached KV state (~1s) instead of cold (~10s). Idempotent.
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

--- Attach the dictation pipeline to a RadialMenu spoon instance.
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
-- Wired at the bottom so they capture the locals above as upvalues.

audio.onCaptureStart = function()
  if not active then return end
  logStage("first PCM byte (audio.onCaptureStart)")
  startT0 = nil
  overlay.listening()
end

audio.onUnexpectedExit = function(_)
  if not active then return end
  log("recorder exited unexpectedly; aborting dictation")
  hs.alert.show("Microphone unavailable", 2)
  active = false
  activePrompt = nil
  startT0 = nil
  overlay.cancel()
end

return M
