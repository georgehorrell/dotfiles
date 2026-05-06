-- audio.lua
-- Microphone recorder for the Hammerspoon dictation pipeline. Talks to
-- the local stt-server's /record endpoint over HTTP: ~80ms record-ready
-- and the orange mic indicator only lights up during an actual recording.
--
-- Wire format: server returns the response body as raw 16kHz mono
-- signed-16-bit-LE PCM, streamed until the client closes the connection.
--
-- We pipe curl's output to a temp file (curl -sN -o file) and poll the
-- file size for first-byte detection. We don't use hs.task's streaming
-- callback because curl's stdout pipe is full-buffered (~64 KB) and
-- our 32 KB/s stream takes 2+ seconds to first-flush, leaving the
-- overlay frozen at "Preparing..." even though the server is shipping
-- audio. Curl's `-N` switches its file output to unbuffered, so bytes
-- hit disk immediately.
--
-- API (note: stop is ASYNC):
--   audio.start()           → boolean
--   audio.stop(callback)    → callback(audioBytes)
--   audio.isRecording()     → boolean
--
-- Optional callbacks:
--   audio.onCaptureStart    — fired once when the file size first
--                             goes non-zero.
--   audio.onUnexpectedExit  — curl died on its own (server gone, etc.).

local M = {}

local CURL = "/usr/bin/curl"
local TOKEN_FILE = os.getenv("HOME") .. "/.local/state/stt-server/auth.token"
local DEFAULT_URL = "http://127.0.0.1:47821/record"
local FIRST_BYTE_POLL_HZ = 50  -- ms between size polls

M.debug            = true
M.recordURL        = DEFAULT_URL
M.onCaptureStart   = nil
M.onUnexpectedExit = nil

local task          = nil
local active        = false
local recordingPath = nil
local stopCallback  = nil
local capturedFirst = false
local poller        = nil

local function log(...)
  if M.debug then hs.printf("[audio] " .. string.format(...)) end
end

local function readToken()
  local f = io.open(TOKEN_FILE, "r")
  if not f then return nil end
  local t = f:read("*l")
  f:close()
  if t and #t > 0 then return t end
  return nil
end

local function makeRecordingPath()
  return string.format("/tmp/stt-mic-%d-%d.pcm",
    math.floor(hs.timer.secondsSinceEpoch() * 1000),
    math.random(0, 0xffffff))
end

--- Begin streaming audio from the stt-server. Returns true on success.
function M.start()
  if active then
    log("start ignored — already recording")
    return false
  end
  local token = readToken()
  if not token then
    log("no auth token at %s; is stt-server running?", TOKEN_FILE)
    return false
  end

  local url = string.format("%s?token=%s", M.recordURL, token)
  recordingPath = makeRecordingPath()
  capturedFirst = false
  active = true
  local t0 = hs.timer.secondsSinceEpoch()

  -- Poll the file size every ~20ms. As soon as it goes non-zero we
  -- know the server has shipped at least one resampler chunk; flip
  -- the overlay from "Preparing..." to "Recording".
  poller = hs.timer.doEvery(FIRST_BYTE_POLL_HZ / 1000, function()
    if not active or capturedFirst then
      if poller then poller:stop(); poller = nil end
      return
    end
    local attrs = hs.fs.attributes(recordingPath)
    if attrs and (attrs.size or 0) > 0 then
      capturedFirst = true
      log("first audio bytes hit disk after %.2fs",
          hs.timer.secondsSinceEpoch() - t0)
      if poller then poller:stop(); poller = nil end
      if M.onCaptureStart then M.onCaptureStart() end
    end
  end)

  local doneFn = function(exitCode, _, stdErr)
    log("curl done: code=%d", exitCode)
    if stdErr and #stdErr > 0 then
      log("curl stderr: %s", stdErr:gsub("%s+$", ""):sub(1, 400))
    end
    if poller then poller:stop(); poller = nil end

    -- Read the file. Curl with -N disables stdio buffering on the
    -- output stream, so on SIGTERM the file is fully flushed.
    local path = recordingPath
    recordingPath = nil
    local bytes = ""
    if path then
      local f = io.open(path, "rb")
      if f then
        bytes = f:read("*all") or ""
        f:close()
      else
        log("could not open recording file %s", path)
      end
      os.remove(path)
    end
    log("recording yielded %d bytes (%.2fs of 16kHz mono s16le)",
        #bytes, #bytes / 32000)

    local unexpected = active and stopCallback == nil
    active = false
    task = nil

    local cb = stopCallback
    stopCallback = nil
    if cb then
      cb(bytes)
    elseif unexpected then
      log("curl exited unexpectedly")
      if M.onUnexpectedExit then M.onUnexpectedExit(bytes) end
    end
  end

  -- We don't actually use the streaming callback (curl writes the
  -- body to a file, we poll the file). hs.task.new still requires a
  -- callback — pass a no-op that drains and returns true.
  local noopStream = function() return true end

  task = hs.task.new(CURL, doneFn, noopStream, {
    "-sN",
    "-X", "POST",
    "-H", "Accept: application/octet-stream",
    "-o", recordingPath,           -- write body to file (-N → unbuffered)
    "--max-time", "300",
    url,
  })

  if not task:start() then
    log("hs.task:start() returned false")
    if poller then poller:stop(); poller = nil end
    active = false
    recordingPath = nil
    task = nil
    return false
  end
  log("recording started → %s", recordingPath)
  return true
end

--- Stop recording. ASYNC: `callback(audioBytes)` fires once curl has
--- exited and the file has been read.
function M.stop(callback)
  if not active then
    log("stop ignored — not recording")
    if callback then callback("") end
    return false
  end
  stopCallback = callback or function() end
  if task then
    -- SIGTERM curl; it'll close the TCP connection, the server's
    -- SessionGuard drops, AudioOutputUnitStop runs, mic indicator off.
    task:terminate()
  end
  return true
end

function M.isRecording()
  return active
end

return M
