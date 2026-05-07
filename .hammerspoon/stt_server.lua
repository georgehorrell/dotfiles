-- stt_server.lua
-- Lifecycle manager and HTTP client for the local Parakeet transcription
-- server (github.com/georgehorrell/stt-hammerspoon-server).
--
-- API:
--   server.ensureRunning(callback)     — async; callback(ok, err)
--   server.transcribe(audioBytes, cb)  — POST audio, stream SSE events
--                                        cb is a table of:
--                                          on_started(id)
--                                          on_token(delta)
--                                          on_done(fullText)
--                                          on_error(message)
--   server.kill()                      — kill the server we launched
--
-- Configuration (override before first call):
--   server.host     — default "127.0.0.1"
--   server.port     — default 47821
--   server.binary   — default "~/.cargo/bin/stt-server" or
--                     "~/github.com/georgehorrell/stt-hammerspoon-server/target/release/stt-server"
--   server.tokenFile — default "~/.local/state/stt-server/auth.token"

local M = {}

M.host       = "127.0.0.1"
M.port       = 47821
M.binary     = nil   -- resolved at first use
M.tokenFile  = os.getenv("HOME") .. "/.local/state/stt-server/auth.token"
M.debug      = true

local launched     = nil   -- hs.task we spawned (nil means no live task: not yet started, or exited)
local cachedToken  = nil
-- Coalesce concurrent ensureRunning callers so a slow spawn is only ever
-- launched once. While `polling = true`, additional callers append their
-- callbacks to `pending` instead of triggering a fresh spawn.
local polling      = false
local pending      = {}

local function log(...)
  if M.debug then hs.printf("[stt-server] " .. string.format(...)) end
end

local function resolveBinary()
  if M.binary then return M.binary end
  local home = os.getenv("HOME")
  local candidates = {
    home .. "/.cargo/bin/stt-server",
    home .. "/github.com/georgehorrell/stt-hammerspoon-server/target/release/stt-server",
  }
  for _, p in ipairs(candidates) do
    local f = io.open(p, "r")
    if f then f:close(); M.binary = p; return p end
  end
  return nil
end

local function readToken()
  -- Re-read each call — token is regenerated on every server start.
  local f = io.open(M.tokenFile, "r")
  if not f then return nil end
  local t = f:read("*l")
  f:close()
  if t and #t > 0 then
    cachedToken = t
    return t
  end
  return nil
end

local function baseURL()
  return string.format("http://%s:%d", M.host, M.port)
end

--- Async health check. callback(ok: boolean).
local function healthCheck(callback)
  hs.http.asyncGet(baseURL() .. "/health", nil, function(status)
    callback(status == 200)
  end)
end

--- Spawn the server binary. Returns true if spawned, false if no binary.
local function spawn()
  local bin = resolveBinary()
  if not bin then
    log("no server binary found; build it first")
    return false
  end
  log("spawning %s", bin)
  launched = hs.task.new(bin, function(exitCode, _, stdErr)
    log("server exited code=%d stderr=%s", exitCode, (stdErr or ""):sub(1, 200))
    launched = nil
  end, function(_, stdOut, stdErr)
    -- Pipe server logs through (truncated) for visibility.
    if M.debug then
      if stdOut and #stdOut > 0 then hs.printf("[stt-server][stdout] %s", stdOut:sub(1, 400)) end
      if stdErr and #stdErr > 0 then hs.printf("[stt-server][stderr] %s", stdErr:sub(1, 400)) end
    end
    return true
  end, {})
  return launched:start()
end

--- Wait for /health to come back ok. Polls every 250ms for up to 60s
--- (the Parakeet ONNX session init can take 10–20s on a slow machine).
local function waitForHealth(callback, attempts)
  attempts = attempts or 0
  if attempts > 240 then  -- 240 * 0.25s = 60s
    log("waitForHealth: gave up after 60s")
    callback(false, "server did not become healthy within 60s")
    return
  end
  healthCheck(function(ok)
    if ok then
      log("waitForHealth: /health 200 after %d attempts (~%.1fs)",
          attempts, attempts * 0.25)
      callback(true)
    else
      -- Log occasionally so a stalled spawn is visible without spamming.
      if attempts % 20 == 0 then
        log("waitForHealth: still waiting (attempt %d)", attempts)
      end
      hs.timer.doAfter(0.25, function() waitForHealth(callback, attempts + 1) end)
    end
  end)
end

--- Ensure the server is running. callback(ok, err).
---
--- Each call independently polls for health. We track `hasSpawned` so we
--- don't try to launch a second binary when the first one is just slow to
--- come up — but we don't try to coalesce concurrent callers, because a
--- broken queue is far worse than a few duplicate health pings.
local function fireAndClear(ok, err)
  local cbs = pending
  pending = {}
  polling = false
  for _, cb in ipairs(cbs) do
    local okPcall, errPcall = pcall(cb, ok, err)
    if not okPcall then log("ensureRunning callback raised: %s", tostring(errPcall)) end
  end
end

function M.ensureRunning(callback)
  callback = callback or function() end

  healthCheck(function(ok)
    if ok then
      log("ensureRunning: /health 200 (server already up)")
      callback(true)
      return
    end

    -- Server isn't responding. Coalesce concurrent callers — at most
    -- one spawn + one waitForHealth at a time. This avoids the
    -- catastrophic race where M.prewarmServer() (run at HS load) and
    -- the user's first M.start() each kick off a spawn: the second
    -- spawn dies on EADDRINUSE *after* overwriting the auth token,
    -- bricking the live server's auth.
    table.insert(pending, callback)
    if polling then
      log("ensureRunning: piggybacking on in-flight poll (%d queued)", #pending)
      return
    end
    polling = true

    if launched then
      -- A previously-spawned task is still alive (its completion
      -- callback would have nil'd `launched` if it had exited). It's
      -- just slow to bind — wait for it.
      log("ensureRunning: spawn in flight; waiting for /health")
    else
      log("ensureRunning: no live server task; spawning")
      if not spawn() then
        fireAndClear(false, "no server binary found")
        return
      end
    end

    waitForHealth(function(ok2, err2) fireAndClear(ok2, err2) end)
  end)
end

--- Stream-parse SSE output. `on_event(name, dataString)` for each event.
local function makeSSEParser(on_event)
  local buffer = ""
  return function(chunk)
    buffer = buffer .. (chunk or "")
    while true do
      local sep = buffer:find("\n\n", 1, true) or buffer:find("\r\n\r\n", 1, true)
      if not sep then return end
      local block = buffer:sub(1, sep - 1)
      -- skip past either "\n\n" (2) or "\r\n\r\n" (4)
      local skip = (buffer:sub(sep, sep + 3) == "\r\n\r\n") and 4 or 2
      buffer = buffer:sub(sep + skip)

      local event, data = "message", {}
      for line in block:gmatch("[^\r\n]+") do
        local field, value = line:match("^([%w%-]+):%s?(.*)$")
        if field == "event" then
          event = value
        elseif field == "data" then
          table.insert(data, value)
        end
      end
      on_event(event, table.concat(data, "\n"))
    end
  end
end

--- POST audio to the server and stream SSE events to the callbacks.
--- audioBytes: raw s16le PCM at 16kHz mono.
--- cb: { on_started, on_token, on_done, on_error }
function M.transcribe(audioBytes, cb)
  cb = cb or {}
  local token = readToken()
  if not token then
    if cb.on_error then cb.on_error("no auth token; is the server running?") end
    return
  end
  if not audioBytes or #audioBytes == 0 then
    if cb.on_error then cb.on_error("no audio to transcribe") end
    return
  end

  local url = string.format("%s/transcribe?token=%s", baseURL(), token)

  -- Use curl via hs.task so we can read the SSE response chunk-by-chunk
  -- (hs.http.asyncPost buffers the whole body).
  local parse = makeSSEParser(function(event, data)
    if event == "started" then
      if cb.on_started then cb.on_started(data) end
    elseif event == "token" then
      if cb.on_token then cb.on_token(data) end
    elseif event == "done" then
      if cb.on_done then
        local ok, parsed = pcall(hs.json.decode, data)
        local text = ok and parsed and parsed.text or ""
        cb.on_done(text)
      end
    elseif event == "error" then
      if cb.on_error then
        local ok, parsed = pcall(hs.json.decode, data)
        local msg = ok and parsed and parsed.message or data
        cb.on_error(msg)
      end
    end
  end)

  -- Write audio to a temp file so we don't have to embed binary in argv.
  local tmpPath = os.tmpname() .. ".pcm"
  local f = io.open(tmpPath, "wb")
  if not f then
    if cb.on_error then cb.on_error("failed to open temp audio file") end
    return
  end
  f:write(audioBytes)
  f:close()

  local doneFn = function(exitCode, _, stdErr)
    os.remove(tmpPath)
    -- With --fail-with-body, curl exits 22 on any HTTP >= 400 (and other
    -- non-zero codes for connection failures / timeouts). On a healthy
    -- 200 response, exit is 0 — we trust the SSE parser's `done` event
    -- to fire `cb.on_done`. Don't try to second-guess that here: hs.task
    -- can deliver the final stdout chunk AFTER this completion callback,
    -- which would falsely look like "no done event was seen yet."
    if exitCode ~= 0 then
      log("curl exited %d: %s", exitCode, (stdErr or ""):sub(1, 200))
      if cb.on_error then
        cb.on_error(string.format("transcribe failed (curl exit %d)", exitCode))
      end
    end
  end
  local streamFn = function(_, stdOut, _)
    if stdOut and #stdOut > 0 then
      parse(stdOut)
    end
    return true
  end

  local task = hs.task.new("/usr/bin/curl", doneFn, streamFn, {
    "-sN",                          -- silent, no buffering
    "--fail-with-body",             -- non-zero exit on HTTP >= 400
    "-X", "POST",
    "-H", "Content-Type: application/octet-stream",
    "-H", "Accept: text/event-stream",
    "--data-binary", "@" .. tmpPath,
    url,
  })
  task:setStreamingCallback(streamFn)
  task:start()
end

function M.kill()
  if launched then
    launched:terminate()
    launched = nil
  end
end

return M
