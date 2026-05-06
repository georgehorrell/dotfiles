-- audio.lua
-- Microphone recorder for the Hammerspoon dictation pipeline.
-- Spawns ffmpeg with avfoundation, recording 16kHz mono s16le PCM into a
-- temp file. We use a file (not a stdout pipe) because ffmpeg full-buffers
-- non-TTY stdout, which means short recordings (a few seconds) often emit
-- *zero* bytes through hs.task's streaming callback. Files don't have that
-- failure mode — ffmpeg flushes on close, which happens reliably on SIGTERM.
--
-- API (note: stop is ASYNC — accepts a callback because we have to wait
-- for ffmpeg to finish flushing the file before we can read it):
--
--   recorder.listInputs()        → { {index=N, name="..."}, ... }
--   recorder.start(deviceIdx)    → boolean
--   recorder.stop(callback)      → callback(audioBytes), nil if idle
--   recorder.isRecording()       → boolean

local M = {}

local FFMPEG = "/opt/homebrew/bin/ffmpeg"

local task          = nil
local active        = false
local recordingPath = nil
local stopCallback  = nil

local function log(...)
  if M.debug then hs.printf("[audio] " .. string.format(...)) end
end

M.debug = true

--- Optional callback fired with normalized audio levels (0..1) while
--- recording. Set this from the consumer (e.g. dictation.lua) to drive
--- a waveform UI.
M.onLevel = nil

--- Optional callback fired if ffmpeg exits on its own without a
--- corresponding stop() call (e.g. failed to open the audio device).
--- Receives `(bytes)` — typically empty in the failure case. Lets the
--- consumer tear down state instead of staying stuck thinking it's
--- still recording.
M.onUnexpectedExit = nil

-- Audio-meter ballistics following standard practice (cf. PPM, OBS, iOS
-- AVAudioRecorder, WebRTC AudioLevel):
--
--   1. Use RMS_level (in dB), not Peak. Peak spikes on every syllable
--      transient and pegs near the top; RMS gives the natural per-syllable
--      bobble.
--   2. Smooth in dB-space with an asymmetric one-pole EMA — fast attack
--      (~20ms) so onsets snap, slow release (~250ms) so the bar decays
--      gracefully between syllables and looks alive.
--   3. Track the noise floor adaptively (snap-down on quieter samples;
--      no drift, since a single recording session shouldn't move much).
--      Gate at floor + 6 dB so silence reads as exactly zero regardless
--      of the mic's self-noise.
--   4. Map [floor+6 dB .. -10 dB] linearly to [0..1] for bar height.
--      Linear-in-dB matches perceived loudness; linear-in-amplitude would
--      hide everything below loud speech.
-- Audio-meter ballistics following standard practice:
--   Asymmetric EMA in dB: fast attack (~20ms), slow release (~250ms).
--   Fixed dB gate: anything below GATE_DB → 0; ramps to 1 at TOP_DB.
--
-- We tried a windowed-percentile auto-calibrating floor — it has a real
-- failure mode where sustained speech rolls all "quiet" samples out of
-- the window and the gate drifts up to cover speech itself. Fixed
-- thresholds are what Discord, iOS Voice Memos, and OBS actually use;
-- adaptive floors only really matter for broadcast-grade meters.
local TAU_ATTACK     = 0.020   -- seconds (20ms) — snappy on syllable onsets
local TAU_RELEASE    = 0.250   -- seconds (250ms) — graceful decay between
-- Tuned tightly to actual observed speech RMS. Cheap mics with AGC
-- (webcam mics, AirPods) compress dynamic range to 3-5 dB during
-- sustained speech, so a wide GATE..TOP window leaves the bar visually
-- pegged. The right window is 1-2 dB *below* your softest speech to
-- a couple dB *above* your loudest. Watch [audio] level: lines and
-- adjust until the range is comfortable.
local GATE_DB        = -23   -- ~3 dB above ambient/silence on this mic
local TOP_DB         = -16   -- just above sustained-speech peaks

-- Periodically log the observed RMS so you can pick the right thresholds.
-- Logs the min/max raw dB seen since last report, every LOG_INTERVAL secs.
local LOG_INTERVAL   = 2.0

local levelDbSmoothed = -90
local lastSampleAt    = nil    -- wall-clock timestamp of the last sample
local logMinDb        = math.huge
local logMaxDb        = -math.huge
local lastLogAt       = 0

local function resetLevelAdaptation()
  levelDbSmoothed = -90
  lastSampleAt    = nil
  logMinDb        = math.huge
  logMaxDb        = -math.huge
  lastLogAt       = 0
end

--- Enumerate avfoundation audio input devices.
function M.listInputs()
  local out, _ = hs.execute(
    FFMPEG .. " -hide_banner -f avfoundation -list_devices true -i '' 2>&1", false)
  local devices = {}
  local in_audio = false
  for line in (out or ""):gmatch("[^\r\n]+") do
    if line:find("AVFoundation audio devices") then
      in_audio = true
    elseif in_audio then
      local idx, name = line:match("%[AVFoundation indev @[^%]]+%]%s*%[(%d+)%]%s*(.+)")
      if idx and name then
        table.insert(devices, { index = tonumber(idx), name = name })
      else
        if line:match("^%s*$") or line:find("video devices") then
          break
        end
      end
    end
  end
  return devices
end

local function makeRecordingPath()
  -- Just need uniqueness across concurrent recordings; ms timestamp + a
  -- random suffix is plenty. (hs.processInfo.pid doesn't exist.)
  return string.format("/tmp/stt-recording-%d-%d.pcm",
    math.floor(hs.timer.secondsSinceEpoch() * 1000),
    math.random(0, 0xffffff))
end

--- Start recording from `deviceIndex`. Returns true on success.
function M.start(deviceIndex)
  if active then
    log("start ignored — already recording")
    return false
  end
  if not deviceIndex then
    log("start: no device index supplied")
    return false
  end

  recordingPath = makeRecordingPath()
  active = true
  resetLevelAdaptation()
  local sampleSpec = string.format(":%d", deviceIndex)

  log("starting ffmpeg with -i %s -> %s", sampleSpec, recordingPath)

  -- Parse incoming stderr chunks for two purposes:
  --  1. Surface unexpected warnings/errors via log().
  --  2. Pick out the periodic `lavfi.astats.Overall.RMS_level=<dB>` lines
  --     emitted by our astats+ametadata filter chain, and forward them
  --     to M.onLevel as a normalized 0..1 audio level for the waveform UI.
  local stderrBuf = ""
  local streamFn = function(_, _, stdErr)
    if not stdErr or #stdErr == 0 then return true end
    stderrBuf = stderrBuf .. stdErr
    while true do
      local nl = stderrBuf:find("\n", 1, true)
      if not nl then break end
      local line = stderrBuf:sub(1, nl - 1)
      stderrBuf = stderrBuf:sub(nl + 1)

      -- Each metadata line looks like:
      --   [Parsed_ametadata_1 @ 0x...] lavfi.astats.Overall.Peak_level=-22.99
      -- We use Peak_level (max sample in the window) rather than RMS,
      -- because RMS smooths over the 50ms window and barely moves once
      -- you're consistently talking. Peak captures the syllable transients
      -- that make the waveform actually bounce.
      local rms = line:match("lavfi%.astats%.Overall%.RMS_level=(%S+)")
      if rms then
        local dbRaw
        if rms == "-inf" then
          dbRaw = -90
        else
          dbRaw = tonumber(rms)
        end
        if dbRaw and M.onLevel then
          -- Asymmetric one-pole EMA in dB-space. Fast attack (rising) so
          -- syllable onsets feel snappy; slow release (falling) so the bar
          -- decays gracefully through pauses.
          local now = hs.timer.secondsSinceEpoch()
          local dt = lastSampleAt and (now - lastSampleAt) or 0.05
          lastSampleAt = now
          local tau = (dbRaw > levelDbSmoothed) and TAU_ATTACK or TAU_RELEASE
          local alpha = 1 - math.exp(-dt / tau)
          levelDbSmoothed = levelDbSmoothed + alpha * (dbRaw - levelDbSmoothed)

          -- Fixed dB gate; map [GATE_DB..TOP_DB] linearly to [0..1].
          local lvl = (levelDbSmoothed - GATE_DB) / (TOP_DB - GATE_DB)
          if lvl < 0 then lvl = 0 elseif lvl > 1 then lvl = 1 end
          M.onLevel(lvl)

          -- Calibration aid: log min/max raw dB every LOG_INTERVAL secs.
          if M.debug then
            if dbRaw < logMinDb then logMinDb = dbRaw end
            if dbRaw > logMaxDb then logMaxDb = dbRaw end
            if lastLogAt == 0 then lastLogAt = now end
            if now - lastLogAt >= LOG_INTERVAL then
              log("level: raw min=%.1f max=%.1f dB (gate=%d top=%d)",
                logMinDb, logMaxDb, GATE_DB, TOP_DB)
              logMinDb = math.huge
              logMaxDb = -math.huge
              lastLogAt = now
            end
          end
        end
      elseif #line > 0
         -- Filter out ffmpeg's INFO-level chatter so the console stays clean.
         -- Anything that's not one of these patterns gets logged so we can
         -- still see real warnings/errors.
         and not line:find("^%[")          -- "[Parsed_…]", "[avfoundation…]", etc.
         and not line:find("^frame:")
         and not line:find("^lavfi%.astats")
         and not line:find("^Input #")
         and not line:find("^Output #")
         and not line:find("^Stream #")
         and not line:find("^Press %[q%]")
         and not line:find("^Stream mapping")
         and not line:find("^%s+Stream")
         and not line:find("^%s+Metadata")
         and not line:find("^%s+Duration")
         and not line:find("^%s+encoder")
         and not line:find("^size=")
      then
        log("ffmpeg: %s", line:sub(1, 400))
      end
    end
    return true
  end

  local doneFn = function(exitCode, stdOut, stdErr)
    log("ffmpeg done: code=%d", exitCode)
    -- Always surface ffmpeg's final stderr — invaluable for diagnosing
    -- capture issues even on "expected" SIGTERM exits.
    if stdErr and #stdErr > 0 then
      log("ffmpeg stderr (final): %s", stdErr:gsub("%s+$", ""):sub(1, 800))
    end
    if exitCode ~= 0 and exitCode ~= 15 and exitCode ~= 255 and stdOut and #stdOut > 0 then
      log("ffmpeg stdout (final): %s", stdOut:gsub("%s+$", ""):sub(1, 200))
    end

    -- Read the recording file (may not exist if ffmpeg failed at start).
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
    log("recording yielded %d bytes", #bytes)

    -- "Unexpected" = ffmpeg died on its own (e.g. couldn't open the audio
    -- device) without us calling stop(). In that case `active` is still
    -- true here. We have to clear it AND notify the consumer; otherwise
    -- the consumer's state machine is stranded thinking we're recording.
    local unexpected = active
    active = false
    task = nil

    local cb = stopCallback
    stopCallback = nil
    if cb then
      cb(bytes)
    elseif unexpected then
      log("ffmpeg exited unexpectedly")
      if M.onUnexpectedExit then M.onUnexpectedExit(bytes) end
    end
  end

  task = hs.task.new(FFMPEG, doneFn, streamFn, {
    "-hide_banner",
    -- INFO is required because ametadata writes at AV_LOG_INFO; "warning"
    -- silently suppresses the per-frame level output. The parser below
    -- discards all the unrelated INFO chatter so the console stays clean.
    "-loglevel", "info",
    "-f", "avfoundation",
    "-i", sampleSpec,
    "-ar", "16000",
    "-ac", "1",
    -- Periodic loudness metadata for the waveform UI. astats computes RMS
    -- over short windows; ametadata prints lavfi.astats.* lines to stderr,
    -- which the streaming callback parses above.
    "-af", "astats=metadata=1:reset=0.05,ametadata=mode=print:direct=1",
    "-f", "s16le",
    "-y",
    recordingPath,
  })

  local ok = task:start()
  if not ok then
    log("hs.task:start() returned false")
    active = false
    task = nil
    recordingPath = nil
    return false
  end
  log("recording started (device %d)", deviceIndex)
  return true
end

--- Stop recording. ASYNC: `callback(audioBytes)` fires once ffmpeg has
--- exited and the file has been read.
---
--- If the recorder isn't actually active (e.g. ffmpeg already died), the
--- callback is still invoked — with empty bytes — so the consumer's state
--- machine doesn't get stranded.
function M.stop(callback)
  if not active then
    log("stop ignored — not recording")
    if callback then callback("") end
    return false
  end
  -- Set the callback BEFORE clearing active, so doneFn sees both fields
  -- in a consistent state regardless of when it fires.
  stopCallback = callback or function() end
  active = false
  if task then
    task:terminate()
    -- The doneFn (set up in start()) will read the file and call back.
  end
  return true
end

function M.isRecording()
  return active
end

return M
