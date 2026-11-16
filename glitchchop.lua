-- glitchchop v1.7.6
-- live glitch-beat processor for one sample loop (softcut, no engine)
--
-- two stereo voice pairs read the same buffer:
--   voices 1-2: the loop, played straight ("dry")
--   voices 3-4: the same loop, chopped by a 16th-note decision metro
--   voices 5-6: feedback echo fed from the glitch pair (K1+E3 amount)
-- E1 crossfades dry <-> glitch. at mix = 0 you hear the plain loop.
--
-- E1 mix | E2 glitch amount | E3 reverse amount
--   (reversed fragments are boosted in level so the flip stands out)
-- hold K1: E1 volume | E2 filter cutoff | E3 echo amount
-- K2 play/stop (stop fades out quickly) | K3 hold: wild pitch, glitch pair louder
-- K1+K3 hold: extra-large flanger (voices 5-6 leave echo duty while held)
-- K1+K2: arm a full parameter reset at the next loop wrap (dry only)
-- the effective glitch amount drifts within +/-2% of the set value

local GLITCHCHOP_VERSION = "1.7.6"

local LOOP_DEFS = {
  { file = "loop_01_140.wav", bpm = 140 },
  { file = "loop_02_140.wav", bpm = 140 },
  { file = "loop_03_140.wav", bpm = 140 },
  { file = "loop_04_140.wav", bpm = 140 },
  { file = "loop_05_140.wav", bpm = 140 },
  { file = "loop_06_90.wav", bpm = 90 },
  { file = "loop_07_90.wav", bpm = 90 },
  { file = "loop_08_90.wav", bpm = 90 },
  { file = "loop_09_172.wav", bpm = 172 },
  { file = "loop_10_172.wav", bpm = 172 },
  { file = "drum_01_90.wav", bpm = 90, label = "D1 90 trip hop" },
  { file = "drum_02_120.wav", bpm = 120, label = "D2 120 rock" },
  { file = "drum_03_120.wav", bpm = 120, label = "D3 120 funk disco" },
  { file = "drum_04_130.wav", bpm = 130, label = "D4 130 break" },
  { file = "drum_05_160.wav", bpm = 160, label = "D5 160 dnb" },
}
local SCRIPT_DIR = ""
do
  local srcpath = debug.getinfo(1, "S").source:gsub("^@", "")
  SCRIPT_DIR = srcpath:match("^(.*/)") or ""
end

local SAMPLE_DEFAULT = SCRIPT_DIR .. "data/loop_01_140.wav"

local function data_path(fname)
  local candidates = {
    SCRIPT_DIR .. "data/" .. fname,
    _path.code .. "glitchchop/data/" .. fname,
  }
  if norns and norns.state and norns.state.path then
    candidates[#candidates + 1] = norns.state.path .. "data/" .. fname
  end
  for _, p in ipairs(candidates) do
    if util.file_exists(p) then return p end
  end
  return nil
end

local playing = false
local sample_len = 0 -- buffer-domain seconds (frames / 48000)
local rate_comp = 1 -- sr / 48000: varispeed compensation for non-48kHz files
local sample_loaded = false
local loaded_path = nil
local current_loop = nil
local k1_held = false

local tick_count = 0
local rate_end = -1
local k3_held = false
local rev_active = false -- a reversed fragment (E3) is currently playing
local flange_on = false
local flange_phase = 0

-- K1+K2: a reset back to defaults is armed and fires at the next loop
-- wrap, so the change lands exactly on the loop start (dry only)
local reset_armed = false
local param_defaults = {}
local prev_pos1 = -1
local RESET_IDS = {"gch_mix", "gch_glitch", "gch_reverse", "gch_volume", "gch_filter",
  "gch_echo", "gch_trim_start", "gch_trim_end", "gch_division", "gch_ratevar"}
local display_slice = 0
local glitch_pos = 0

-- glitch amount drift: the effective probability wanders within
-- +/-2% of the set value, so the pattern never repeats exactly
local glitch_drift = 0
local drift_min = 0
local drift_max = 0

-- stop fade-out: K2 stop decays the level over ~0.1s (fade_step)
-- instead of cutting the sound instantly
local fading = false
local fade_gain = 1
local FADE_STEPS = 6

local function win_start()
  if sample_len <= 0 then return 0 end
  return math.min(params:get("gch_trim_start"), math.max(sample_len - 0.05, 0))
end

local function win_end()
  if sample_len <= 0 then return 0 end
  local e = params:get("gch_trim_end")
  if e <= 0 or e > sample_len then e = sample_len end
  return math.max(e, win_start() + 0.05)
end

local function win_len()
  return win_end() - win_start()
end

local tick_metro = nil
local clock_metro = nil
local midi_dev = nil
local screen_metro = nil
local fade_metro = nil
local flanger_metro = nil

-- debug instrumentation (PARAMETERS > debug log, default on in this build).
-- lines are prefixed GCDBG so they can be picked out of the maiden log.
local dbg_wrap_count = 0
local dbg_last_wrap = 0
local dbg_prev_pos = -1
local dbg_last_change_t = 0
local dbg_stall_logged = false
local dbg_over_logged = false
local dbg_poll_last_t = 0
local dbg_poll_count = 0

local function now()
  if util and util.time then return util.time() end
  return os.clock()
end

local function dbg(s)
  if params:get("gch_debug") == 2 then
    print("GCDBG " .. s)
  end
end

local function dbg_phase(pos)
  if not playing or not sample_loaded then return end
  local t = now()
  if dbg_poll_last_t > 0 and dbg_poll_count < 5 then
    dbg(string.format("POLLDT %.3f", t - dbg_poll_last_t))
    dbg_poll_count = dbg_poll_count + 1
  end
  dbg_poll_last_t = t
  local we = win_end()
  -- playhead ran past the loop end into the silent buffer region?
  if pos > we + 0.02 then
    if not dbg_over_logged then
      dbg(string.format("OVER pos=%.3f end=%.3f t=%.3f", pos, we, t))
      dbg_over_logged = true
    end
  elseif pos < we - 0.1 then
    dbg_over_logged = false
  end
  -- wrap: previous poll near the end, this poll back near the start
  if dbg_prev_pos > we - 0.15 and pos < win_start() + 0.15 then
    dbg_wrap_count = dbg_wrap_count + 1
    if dbg_last_wrap > 0 then
      local dt = t - dbg_last_wrap
      if dbg_wrap_count <= 12 or dbg_wrap_count % 8 == 0 then
        dbg(string.format("WRAP n=%d t=%.3f dt=%.3f len=%.3f diff=%+.3f prev=%.3f pos=%.3f",
          dbg_wrap_count, t, dt, win_len(), dt - win_len(), dbg_prev_pos, pos))
      end
    else
      dbg(string.format("WRAP n=%d t=%.3f (first)", dbg_wrap_count, t))
    end
    dbg_last_wrap = t
  end
  -- stall: playhead not moving while playing
  if math.abs(pos - dbg_prev_pos) > 0.001 then
    dbg_last_change_t = t
    dbg_stall_logged = false
  elseif t - dbg_last_change_t > 0.25 and not dbg_stall_logged then
    dbg(string.format("STALL pos=%.3f t=%.3f", pos, t))
    dbg_stall_logged = true
  end
  dbg_prev_pos = pos
end


local function slices_total()
  local d = params:get("gch_division")
  if d == 1 then return 32 elseif d == 2 then return 64 else return 128 end
end

local function slice_len()
  if sample_len <= 0 then return 0 end
  return win_len() / slices_total()
end

local function clock_interval()
  return (60 / params:get("gch_tempo")) / 24
end

local function midi_send(fn)
  if midi_dev == nil then return end
  if params:get("gch_midi_clock") ~= 2 then return end
  pcall(fn, midi_dev)
end

local function clock_tick()
  if playing then midi_send(function(d) d:clock() end) end
end

local function set_echo_level()
  local lv = params:get("gch_echo") * params:get("gch_volume") * fade_gain
  softcut.level(5, lv)
  softcut.level(6, lv)
end

local function set_pair_levels()
  local mix = params:get("gch_mix")
  local vol = params:get("gch_volume")
  local dry = math.cos(mix * math.pi / 2) * vol * fade_gain
  local wet = math.sin(mix * math.pi / 2) * vol * fade_gain
  if k3_held or rev_active then
    -- K3 held, or a reversed fragment playing: only the glitch pair
    -- gets louder, so the effect stands out even at mix = 0;
    -- the dry pair is left untouched
    wet = math.max(wet, dry) * 1.5
    if wet > 2.0 then wet = 2.0 end
  end
  softcut.level(1, dry)
  softcut.level(2, dry)
  softcut.level(3, wet)
  softcut.level(4, wet)
  set_echo_level()
end

local function pair_position(pos)
  softcut.position(3, pos)
  softcut.position(4, pos)
end

local function pair_window(a, b)
  softcut.loop_start(3, a)
  softcut.loop_end(3, b)
  softcut.loop_start(4, a)
  softcut.loop_end(4, b)
end

local function pair_rate(r)
  softcut.rate(3, r * rate_comp)
  softcut.rate(4, r * rate_comp)
end

local function apply_filter()
  -- both pairs: the filter must be audible on the dry loop too
  local fc = params:get("gch_filter")
  for i = 1, 4 do
    softcut.post_filter_lp(i, 1)
    softcut.post_filter_hp(i, 0)
    softcut.post_filter_bp(i, 0)
    softcut.post_filter_br(i, 0)
    softcut.post_filter_fc(i, fc)
    softcut.post_filter_rq(i, 0.45) -- low rq = strong resonance peak at the cutoff
  end
end

local function release_rate()
  pair_rate(1)
  rate_end = -1
  if rev_active then
    rev_active = false
    set_pair_levels()
  end
end

local function set_rev(on)
  if on == rev_active then return end
  rev_active = on
  set_pair_levels()
end

local PITCH_WILD = {-24, -17, -12, -7, -5, 0, 5, 7, 12, 17, 24} -- semitones, K3 wild pitch

local function glitch_tick()
  if not playing or not sample_loaded then return end
  tick_count = tick_count + 1
  local sl = slice_len()
  if sl <= 0 then return end

  -- drift the effective glitch amount within +/-2% of the set value
  glitch_drift = glitch_drift + (math.random() * 2 - 1) * 0.002
  if glitch_drift > 0.02 then glitch_drift = 0.02 end
  if glitch_drift < -0.02 then glitch_drift = -0.02 end
  if glitch_drift < drift_min then drift_min = glitch_drift end
  if glitch_drift > drift_max then drift_max = glitch_drift end

  if k3_held then
    -- K3 held: the glitch pair's pitch jumps wildly every tick,
    -- so it is unmistakable that K3 is being held
    local st = PITCH_WILD[math.random(1, #PITCH_WILD)]
    pair_rate(2 ^ (st / 12))
    rate_end = -1 -- K3 owns the glitch rate while held
  elseif rate_end > 0 and tick_count >= rate_end then
    release_rate()
  end

  local prob = params:get("gch_glitch") * (1 + glitch_drift)
  if prob > 1 then prob = 1 end
  if math.random() >= prob then return end

  local idx = math.random(0, slices_total() - 1)
  display_slice = idx
  local start = win_start() + idx * sl

  if not k3_held and math.random() < params:get("gch_reverse") then
    -- reversed fragment (E3): start at the slice end, play backwards
    -- for one slice. While reversed, set_pair_levels pushes the
    -- glitch pair louder, so the flip is unmistakable.
    pair_position(start + sl)
    pair_rate(-1)
    local ticks = math.floor(sl / ((60 / params:get("gch_tempo")) / 4) + 0.5)
    if ticks < 1 then ticks = 1 end
    rate_end = tick_count + ticks
    set_rev(true)
  else
    pair_position(start)
    if rev_active then
      pair_rate(1)
      rate_end = -1
      set_rev(false)
    end
    if not k3_held and params:get("gch_ratevar") == 1 and math.random() < 0.25 then
      local rates = {0.5, 2, -1}
      pair_rate(rates[math.random(1, 3)])
      rate_end = tick_count + math.random(4, 8)
    end
  end
end

local function echo_len()
  return (60 / params:get("gch_tempo")) * 0.75 -- dotted eighth
end

local function echo_start()
  return sample_len + 1.0 -- empty buffer region just past the sample
end

local echo_ready = false

local function setup_echo()
  local a = echo_start()
  local b = a + echo_len()
  for i = 5, 6 do
    softcut.enable(i, 1)
    softcut.buffer(i, (i % 2 == 1) and 1 or 2)
    softcut.loop(i, 1)
    softcut.loop_start(i, a)
    softcut.loop_end(i, b)
    softcut.position(i, a)
    softcut.rate(i, 1)
    softcut.fade_time(i, 0.001)
    softcut.level_slew_time(i, 0.03)
    softcut.pan(i, (i % 2 == 1) and -1 or 1)
    softcut.rec(i, 1)
    softcut.rec_level(i, 1)
    softcut.pre_level(i, 0.35) -- feedback inside the echo window
    softcut.play(i, playing and 1 or 0)
    softcut.level(i, 0)
  end
  -- feed the echo pair from the glitch pair's output
  softcut.level_cut_cut(1, 5, 0)
  softcut.level_cut_cut(2, 6, 0)
  softcut.level_cut_cut(3, 5, 1)
  softcut.level_cut_cut(4, 6, 1)
  echo_ready = true
  set_echo_level()
end

local function update_echo_window()
  if not echo_ready then return end
  local a = echo_start()
  local b = a + echo_len()
  for i = 5, 6 do
    softcut.loop_start(i, a)
    softcut.loop_end(i, b)
  end
end

-- extra-large flanger on voices 5-6 (borrowed from echo duty):
-- a feedback delay whose length (0.8-14ms) is swept by an LFO.
-- the delay time is the loop window length, same mechanism as the echo.
local FLANGE_MIN = 0.0008
local FLANGE_MAX = 0.014
local FLANGE_RATE = 0.25 -- LFO Hz

local function flange_delay()
  local mid = (FLANGE_MAX + FLANGE_MIN) / 2
  local amp = (FLANGE_MAX - FLANGE_MIN) / 2
  return mid + amp * math.sin(flange_phase)
end

local function flange_apply()
  local a = sample_len + 4.0 -- empty buffer region past the echo's
  local d = flange_delay()
  for i = 5, 6 do
    softcut.loop_start(i, a)
    softcut.loop_end(i, a + d)
  end
end

local function flange_step()
  if not flange_on then return end
  flange_phase = flange_phase + (2 * math.pi * FLANGE_RATE) / 30
  flange_apply()
end

local function set_flanger(on)
  if on == flange_on then return end
  flange_on = on
  if on then
    local a = sample_len + 4.0
    for i = 5, 6 do
      softcut.enable(i, 1)
      softcut.buffer(i, (i % 2 == 1) and 1 or 2)
      softcut.loop(i, 1)
      softcut.loop_start(i, a)
      softcut.loop_end(i, a + flange_delay())
      softcut.position(i, a)
      softcut.rate(i, 1)
      softcut.fade_time(i, 0.0005)
      softcut.level_slew_time(i, 0.03)
      softcut.pan(i, (i % 2 == 1) and -1 or 1)
      softcut.rec(i, 1)
      softcut.rec_level(i, 1)
      softcut.pre_level(i, 0.65) -- strong feedback: extra-large flanger
      softcut.play(i, playing and 1 or 0)
      softcut.level(i, 1.3 * params:get("gch_volume") * fade_gain)
    end
    -- the flanger listens to everything (dry + glitch)
    softcut.level_cut_cut(1, 5, 1)
    softcut.level_cut_cut(2, 6, 1)
    softcut.level_cut_cut(3, 5, 1)
    softcut.level_cut_cut(4, 6, 1)
    if flanger_metro then flanger_metro:start() end
  else
    if flanger_metro then flanger_metro:stop() end
    setup_echo() -- voices 5-6 go back to echo duty
  end
end

local function apply_reset()
  reset_armed = false
  if flange_on then set_flanger(false) end
  k3_held = false
  rev_active = false
  rate_end = -1
  pair_rate(1)
  for _, id in ipairs(RESET_IDS) do
    if param_defaults[id] ~= nil then params:set(id, param_defaults[id]) end
  end
  set_pair_levels()
  dbg("RESET applied at loop wrap")
end

local function setup_voices()
  for i = 1, 4 do
    softcut.enable(i, 1)
    softcut.buffer(i, (i % 2 == 1) and 1 or 2)
    softcut.loop(i, 1)
    softcut.loop_start(i, win_start())
    softcut.loop_end(i, math.max(win_end(), 0.01))
    softcut.position(i, win_start())
    softcut.rate(i, rate_comp)
    softcut.fade_time(i, 0.001) -- near-zero: seamless loop wrap, no dip
    softcut.level_slew_time(i, 0.03)
    softcut.rate_slew_time(i, 0.0)
    softcut.pan(i, (i % 2 == 1) and -1 or 1)
    softcut.play(i, 0)
    softcut.level(i, 0)
  end
  apply_filter()
  set_pair_levels()
  setup_echo()
end

local function load_sample(path)
  if path == nil or not util.file_exists(path) then
    sample_loaded = false
    loaded_path = nil
    return
  end
  local ch, frames, sr = audio.file_info(path)
  if frames == nil or sr == nil or frames <= 0 then
    sample_loaded = false
    loaded_path = nil
    return
  end
  current_loop = nil
  -- softcut's buffer runs at 48kHz and buffer_read does NOT resample:
  -- a 44.1kHz file's frames occupy only frames/48000 seconds of buffer.
  -- Work in buffer seconds and compensate the playback rate by sr/48000,
  -- so any sample rate loops tightly at the correct pitch and speed.
  rate_comp = sr / 48000
  sample_len = frames / 48000
  if sr ~= 48000 then
    print(string.format("GCDBG COMP %s sr=%d: playback rate x%.4f, loop points in buffer time",
      path:match("[^/]+$") or path, sr, rate_comp))
  end
  softcut.buffer_clear()
  softcut.buffer_read_stereo(path, 0, 0, -1)
  sample_loaded = true
  loaded_path = path
  rate_end = -1
  setup_voices()
  dbg(string.format("LOAD %s ch=%s frames=%s sr=%s filelen=%.3f buflen=%.3f comp=%.4f",
    path:match("[^/]+$") or path, tostring(ch), tostring(frames), tostring(sr),
    frames / sr, sample_len, rate_comp))
  if playing then
    for i = 1, 6 do softcut.play(i, 1) end
  end
end

local function load_bundled(idx)
  local def = LOOP_DEFS[idx]
  if def == nil then return end
  local p = data_path(def.file)
  if p then
    load_sample(p)
    if sample_loaded then
      current_loop = idx
      params:set("gch_tempo", def.bpm)
    end
  else
    sample_loaded = false
    loaded_path = nil
  end
end

local function load_selected()
  local sel = params:get("gch_loop")
  if sel and sel >= 1 and sel <= #LOOP_DEFS then
    load_bundled(sel)
  else
    local f = params:get("gch_sample")
    if f and util.file_exists(f) then
      load_sample(f)
    else
      load_bundled(1)
    end
  end
end

local function apply_trim()
  if not sample_loaded then return end
  local a, b = win_start(), win_end()
  for i = 1, 4 do
    softcut.loop_start(i, a)
    softcut.loop_end(i, b)
  end
end

-- stop fade-out: each step lowers the level; at zero the voices stop.
-- the tail of the loop (and the echo) rings out instead of a hard cut.
local function fade_step()
  if not fading then return end
  fade_gain = fade_gain - 1 / FADE_STEPS
  if fade_gain <= 0 then
    fade_gain = 0
    set_pair_levels()
    for i = 1, 6 do softcut.play(i, 0) end
    playing = false
    fading = false
    fade_gain = 1
    if fade_metro then fade_metro:stop() end
  else
    set_pair_levels()
  end
end

local function set_playing(on)
  if on then
    if fading then
      -- K2 during the fade-out: cancel the fade and resume full level
      if fade_metro then fade_metro:stop() end
      fading = false
      fade_gain = 1
      set_pair_levels()
      if tick_metro then tick_metro:start() end
      if clock_metro then clock_metro:start() end
      midi_send(function(d) d:start() end)
      return
    end
    if playing then return end
    playing = true
    fade_gain = 1
    if tick_metro then tick_metro:start() end
    midi_send(function(d) d:start() end)
    if clock_metro then clock_metro:start() end
    for i = 1, 6 do softcut.play(i, 1) end
    for i = 1, 4 do softcut.position(i, win_start()) end
    softcut.position(5, echo_start())
    softcut.position(6, echo_start())
    tick_count = 0
    rate_end = -1
    rev_active = false
    pair_window(win_start(), win_end())
    pair_rate(1)
    set_pair_levels()
    glitch_drift = 0
    drift_min = 0
    drift_max = 0
    dbg_wrap_count = 0
    dbg_last_wrap = 0
    dbg_prev_pos = -1
    dbg_last_change_t = now()
    dbg_stall_logged = false
    dbg_over_logged = false
    dbg_poll_last_t = 0
    dbg_poll_count = 0
    dbg(string.format("PLAY v%s t=%.3f len=%.3f start=%.3f end=%.3f",
      GLITCHCHOP_VERSION, now(), win_len(), win_start(), win_end()))
  else
    if not playing or fading then return end
    -- fade out instead of cutting: metros and midi stop now,
    -- the sound itself decays in fade_step
    fading = true
    if tick_metro then tick_metro:stop() end
    if clock_metro then clock_metro:stop() end
    midi_send(function(d) d:stop() end)
    dbg(string.format("STOP t=%.3f wraps=%d drift=[%.3f,%.3f]",
      now(), dbg_wrap_count, drift_min, drift_max))
    if fade_metro then fade_metro:start() end
  end
end

function init()
  math.randomseed(os.time())
  audio.level_cut(1)
  if audio.rev_off then pcall(audio.rev_off) end -- system reverb off by default
  softcut.reset()

  params:add_group("GLITCHCHOP", 16)
  local loop_names = {}
  for i, def in ipairs(LOOP_DEFS) do
    loop_names[i] = def.label or string.format("G%d %dbpm", i, def.bpm)
  end
  loop_names[#LOOP_DEFS + 1] = "custom file"
  params:add_option("gch_loop", "loop select", loop_names, 1)
  params:set_action("gch_loop", function(v)
    if v >= 1 and v <= #LOOP_DEFS then
      load_bundled(v)
    else
      local f = params:get("gch_sample")
      if f and util.file_exists(f) then
        if loaded_path ~= f then load_sample(f) end
      else
        load_bundled(1)
      end
    end
  end)
  params:add_file("gch_sample", "sample (custom)", SAMPLE_DEFAULT)
  params:set_action("gch_sample", function(f)
    if f and util.file_exists(f) then
      load_sample(f)
      params:set("gch_loop", #LOOP_DEFS + 1)
    end
  end)
  params:add_control("gch_mix", "mix (dry>glitch)", controlspec.new(0, 1, "lin", 0.01, 0))
  params:set_action("gch_mix", function() set_pair_levels() end)
  params:add_control("gch_glitch", "glitch amount", controlspec.new(0, 1, "lin", 0.01, 0.35))
  params:add_control("gch_reverse", "reverse amount (E3)", controlspec.new(0, 1, "lin", 0.01, 0))
  params:add_control("gch_tempo", "tick tempo", controlspec.new(30, 300, "lin", 1, 140))
  params:set_action("gch_tempo", function(v)
    if tick_metro then tick_metro.time = 60 / v / 4 end
    if clock_metro then clock_metro.time = (60 / v) / 24 end
    update_echo_window()
  end)
  params:add_option("gch_division", "slice grid", {"1/32 loop", "1/64 loop", "1/128 loop"}, 2)
  params:add_binary("gch_ratevar", "rate variation", "toggle", 1)
  params:add_control("gch_trim_start", "trim start (s)", controlspec.new(0, 30, "lin", 0.01, 0))
  params:set_action("gch_trim_start", function() apply_trim() end)
  params:add_control("gch_trim_end", "trim end (s, 0=full)", controlspec.new(0, 30, "lin", 0.01, 0))
  params:set_action("gch_trim_end", function() apply_trim() end)
  params:add_control("gch_volume", "volume", controlspec.new(0, 1.5, "lin", 0.01, 1.0))
  params:set_action("gch_volume", function() set_pair_levels() end)
  params:add_control("gch_filter", "filter cutoff (K1+E2)", controlspec.new(60, 18000, "exp", 0, 18000, "Hz"))
  params:set_action("gch_filter", function() apply_filter() end)
  params:add_control("gch_echo", "echo amount (K1+E3)", controlspec.new(0, 1, "lin", 0.01, 0))
  params:set_action("gch_echo", function() set_echo_level() end)
  params:add_option("gch_midi_clock", "midi clock out", { "off", "on" }, 2)
  params:add_number("gch_midi_port", "midi out port", 1, 4, 1)
  params:set_action("gch_midi_port", function(v) midi_dev = midi.connect(v) end)
  params:add_option("gch_debug", "debug log", { "off", "on" }, 2)

  for _, id in ipairs(RESET_IDS) do param_defaults[id] = params:get(id) end
  dbg(string.format("INIT v%s dir=%s", GLITCHCHOP_VERSION, SCRIPT_DIR))
  load_selected()

  tick_metro = metro.init()
  tick_metro.time = 60 / params:get("gch_tempo") / 4
  tick_metro.event = glitch_tick

  clock_metro = metro.init()
  clock_metro.time = clock_interval()
  clock_metro.event = clock_tick
  midi_dev = midi.connect(params:get("gch_midi_port"))

  softcut.event_phase(function(i, pos)
    if i == 3 then glitch_pos = pos end
    if i == 1 then
      if reset_armed and playing and sample_loaded then
        if prev_pos1 > win_end() - 0.15 and pos < win_start() + 0.15 then
          apply_reset()
        end
      end
      prev_pos1 = pos
      dbg_phase(pos)
    end
  end)
  softcut.phase_quant(1, 0.05) -- default quantum is 1s: too coarse to see wraps
  softcut.phase_quant(3, 0.05)
  softcut.poll_start_phase()

  screen_metro = metro.init()
  screen_metro.time = 1 / 15
  screen_metro.event = function() redraw() end
  screen_metro:start()

  fade_metro = metro.init()
  fade_metro.time = 0.02
  fade_metro.event = fade_step

  flanger_metro = metro.init()
  flanger_metro.time = 1 / 30
  flanger_metro.event = flange_step

  redraw()
end

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    redraw()
    return
  end
  if n == 3 then
    if z == 1 then
      if k1_held then
        set_flanger(true) -- K1+K3: extra-large flanger
      else
        k3_held = true
        set_pair_levels() -- pitch-modulated pair steps forward in level
      end
    else
      if flange_on then set_flanger(false) end
      if k3_held then
        k3_held = false
        rate_end = -1
        if playing then pair_rate(1) end -- back to normal pitch on release
        set_pair_levels()
      end
    end
    redraw()
    return
  end
  if z ~= 1 then return end
  if n == 2 then
    if k1_held then
      -- K1+K2: arm the reset; nothing changes until the loop wraps
      if sample_loaded then reset_armed = true end
    elseif fading then
      set_playing(true)
    else
      set_playing(not playing)
    end
  end
  redraw()
end

function enc(n, d)
  if k1_held then
    if n == 1 then
      params:delta("gch_volume", d)
    elseif n == 2 then
      -- filter cutoff, multiplicative steps so a turn is clearly audible
      local fc = params:get("gch_filter")
      local f = (d >= 0) and (1.28 ^ d) or (0.78 ^ (-d))
      params:set("gch_filter", math.max(60, math.min(18000, fc * f)))
    elseif n == 3 then
      params:delta("gch_echo", d * 3)
    end
  else
    if n == 1 then
      params:delta("gch_mix", d)
    elseif n == 2 then
      params:delta("gch_glitch", d)
    elseif n == 3 then
      params:delta("gch_reverse", d * 2)
    end
  end
  redraw()
end

local function draw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  screen.level(15)
  screen.move(0, 8)
  screen.text("GLITCHCHOP " .. GLITCHCHOP_VERSION)

  screen.move(127, 8)
  screen.text_right(fading and "FADE" or (playing and "PLAY" or "STOP"))

  if not sample_loaded then
    screen.level(15)
    screen.move(0, 30)
    screen.text("NO SAMPLE LOADED")
  end

  -- mix bar
  local mix = params:get("gch_mix")
  screen.level(4)
  screen.move(0, 17)
  screen.text("dry")
  screen.move(127, 17)
  screen.text_right("glitch")
  screen.rect(0, 20, 128, 5)
  screen.stroke()
  screen.level(15)
  screen.rect(0, 20, math.floor(128 * mix), 5)
  screen.fill()

  -- slice position blocks (16 blocks across the loop, glitch voice)
  if sample_loaded and sample_len > 0 then
    local cur = math.floor(((glitch_pos - win_start()) / math.max(win_len(), 0.01)) * 16)
    cur = math.max(0, math.min(15, cur))
    for b = 0, 15 do
      screen.level(b == cur and 15 or 3)
      screen.rect(b * 8 + 1, 34, 6, 6)
      screen.fill()
    end
  end

  screen.level(10)
  screen.move(0, 52)
  if k1_held then
    local fc = params:get("gch_filter")
    local fcs = (fc >= 1000) and string.format("%.1fk", fc / 1000) or tostring(math.floor(fc))
    screen.text("filt " .. fcs)
    screen.move(49, 52)
    screen.text("echo " .. math.floor(params:get("gch_echo") * 100) .. "%")
  else
    screen.text("glitch " .. math.floor(params:get("gch_glitch") * 100) .. "%")
    screen.move(49, 52)
    screen.text("rev " .. math.floor(params:get("gch_reverse") * 100) .. "%")
  end
  screen.move(127, 52)
  screen.text_right(math.floor(params:get("gch_tempo")) .. "bpm")
  if reset_armed then
    screen.level(15)
    screen.move(127, 30)
    screen.text_right("RESET ARMED")
  end
  if flange_on then
    screen.level(15)
    screen.move(127, 40)
    screen.text_right("FLANGER")
  elseif k3_held then
    screen.level(15)
    screen.move(127, 40)
    screen.text_right("K3 PITCH")
  end

  screen.level(6)
  screen.move(0, 63)
  if k1_held then
    screen.text("K1: E1 vol  E2 filt  E3 echo")
  else
    screen.text("E1 mix E2 glitch E3 rev K2 play K3 pitch K1+K3 flange K1+K2 reset")
  end
  screen.update()
end

function redraw()
  local ok, err = pcall(draw)
  if not ok then
    screen.clear()
    screen.level(15)
    screen.move(0, 10)
    screen.text("ERR: " .. tostring(err))
    screen.update()
  end
end

function cleanup()
  if clock_metro then
    clock_metro:stop()
    if clock_metro.id then metro.free(clock_metro.id) end
  end
  midi_send(function(d) d:stop() end)
  if tick_metro then
    tick_metro:stop()
    if tick_metro.id then metro.free(tick_metro.id) end
  end
  if screen_metro then
    screen_metro:stop()
    if screen_metro.id then metro.free(screen_metro.id) end
  end
  if fade_metro then
    fade_metro:stop()
    if fade_metro.id then metro.free(fade_metro.id) end
  end
  if flanger_metro then
    flanger_metro:stop()
    if flanger_metro.id then metro.free(flanger_metro.id) end
  end
  for i = 1, 6 do softcut.play(i, 0) end
  softcut.poll_stop_phase()
end
