-- dictate.lua
-- WebSocket client for the stt-server's /dictate streaming dictation
-- endpoint. Replaces the old record-then-transcribe pipeline with a
-- live-chunked one driven by server-side Silero VAD: each utterance is
-- finalized when the user pauses (default 750ms hangover) and streamed
-- back as soon as Parakeet finishes transcribing it.
--
-- API:
--   M.start(cb) → handle    cb is { on_ready, on_speech_start,
--                                   on_speech_end, on_partial,
--                                   on_final, on_complete, on_error,
--                                   on_warning, on_close }
--   handle:stop()           tells server to flush + finalize, then close
--   handle:cancel()         hard-close the WS without finalizing
--
-- Wire protocol mirrors src/dictate.rs ServerMsg / ClientMsg.

local M = {}

M.host  = "127.0.0.1"
M.port  = 47821
M.debug = true

local function log(...)
  if M.debug then hs.printf("[dictate] " .. string.format(...)) end
end

local function readToken()
  local f = io.open(os.getenv("HOME") .. "/.local/state/stt-server/auth.token", "r")
  if not f then return nil end
  local t = f:read("*l")
  f:close()
  if t and #t > 0 then return t end
  return nil
end

--- Open a streaming dictation session.
--- cb fields are all optional. cb.on_complete(fullText) is the
--- canonical "the user's transcript is ready" callback.
function M.start(cb)
  cb = cb or {}
  local token = readToken()
  if not token then
    if cb.on_error then cb.on_error("no auth token; is the server running?") end
    return nil
  end

  local url = string.format("ws://%s:%d/dictate?token=%s", M.host, M.port, token)
  local closed = false
  local stoppedByUser = false
  local fullText = nil

  -- We forward-declare so the callback can reference the handle.
  local handle = {}

  local ws = hs.websocket.new(url, function(event, payload)
    if event == "open" then
      log("ws opened")
      -- The server starts recording on connect; an explicit `start`
      -- message is also accepted (treated as a no-op).
      -- (Skipping it keeps the wire smaller.)
    elseif event == "received" then
      local ok, msg = pcall(hs.json.decode, payload or "")
      if not ok or type(msg) ~= "table" or not msg.type then
        log("ws: malformed payload: %s", tostring(payload):sub(1, 200))
        return
      end
      local t = msg.type
      if t == "ready" then
        if cb.on_ready then cb.on_ready(msg.session_id) end
      elseif t == "speech_start" then
        if cb.on_speech_start then cb.on_speech_start(msg.t_ms) end
      elseif t == "speech_end" then
        if cb.on_speech_end then cb.on_speech_end(msg.t_ms, msg.segment_id) end
      elseif t == "partial" then
        if cb.on_partial then cb.on_partial(msg.segment_id, msg.text or "") end
      elseif t == "final" then
        if cb.on_final then cb.on_final(msg.segment_id, msg.text or "") end
      elseif t == "warning" then
        log("warning: %s", tostring(msg.reason))
        if cb.on_warning then cb.on_warning(msg.reason) end
      elseif t == "transcript_complete" then
        fullText = msg.text or ""
        if cb.on_complete then cb.on_complete(fullText) end
      elseif t == "error" then
        log("server error: %s", tostring(msg.reason))
        if cb.on_error then cb.on_error(msg.reason) end
      elseif t == "pong" then
        -- ignore
      else
        log("unknown event: %s", t)
      end
    elseif event == "closed" then
      if closed then return end
      closed = true
      log("ws closed")
      if cb.on_close then cb.on_close(stoppedByUser, fullText) end
    elseif event == "fail" then
      log("ws fail: %s", tostring(payload))
      if cb.on_error then cb.on_error("websocket failed: " .. tostring(payload)) end
    end
  end)

  function handle:stop()
    if closed then return end
    stoppedByUser = true
    -- Server flushes pending speech buffer, transcribes, sends
    -- transcript_complete, then closes the socket.
    pcall(function() ws:send(hs.json.encode({ type = "stop" }), false) end)
  end

  function handle:cancel()
    if closed then return end
    closed = true
    pcall(function() ws:close() end)
  end

  function handle:isClosed()
    return closed
  end

  handle._ws = ws
  return handle
end

return M
