-- RLS Siren Controller
-- Vehicle extension that plays siren sounds via SFXSource using FMOD event paths.
-- Loaded automatically for all vehicles; only active when config is pushed from GE.

local M = {}

local sources = {}       -- { toneName = { id = sfxSourceId, volume = number } }
local toneOrder = {}     -- ordered list of tone names, e.g. {"wail", "yelp", "piercer"}
local currentTone = 0    -- 0 = off, 1..#toneOrder = active tone index
local idCounter = 0
local configured = false

-- Safety: stop all active sounds
local function stopAll()
  for _, src in pairs(sources) do
    if src and src.id then
      obj:stopSFX(src.id)
    end
  end
  currentTone = 0
  electrics.values.rlsSirenActive = 0
  electrics.values.rlsSirenTone = ""
end

local function playTone(toneName)
  local src = sources[toneName]
  if not src then return end
  obj:cutSFX(src.id)
  obj:setVolume(src.id, src.volume)
  obj:playSFX(src.id)
  electrics.values.rlsSirenActive = 1
  electrics.values.rlsSirenTone = toneName
end

-- Cycle through configured tones: Off -> tone1 -> tone2 -> ... -> Off
local function cycleSiren()
  if not configured or #toneOrder == 0 then return end

  -- Require lights to be on (lightbar_signal >= 1)
  local lightbar = electrics.values.lightbar_signal or 0
  if lightbar < 1 then return end

  -- Stop current tone
  if currentTone > 0 and toneOrder[currentTone] then
    local src = sources[toneOrder[currentTone]]
    if src then obj:stopSFX(src.id) end
  end

  -- Advance
  currentTone = currentTone + 1
  if currentTone > #toneOrder then
    currentTone = 0
  end

  -- Play next tone (or silence if wrapped to 0)
  if currentTone > 0 then
    playTone(toneOrder[currentTone])
  else
    electrics.values.rlsSirenActive = 0
    electrics.values.rlsSirenTone = ""
  end
end

-- Receive configuration from GE side (called via queueLuaCommand once at spawn)
-- cfg = { tones = { {name="wail", event="event:>..."}, {name="yelp", event="event:>..."}, ... } }
local function setConfig(cfg)
  stopAll()

  -- Clean up old sources
  for _, src in pairs(sources) do
    if src and src.id then obj:deleteSFXSource(src.id) end
  end
  sources = {}
  toneOrder = {}
  configured = false

  if not cfg or not cfg.tones or #cfg.tones == 0 then return end

  for _, tone in ipairs(cfg.tones) do
    if tone.event and tone.event ~= "" and tone.name and tone.name ~= "" then
      idCounter = idCounter + 1
      local uniqueName = "rlsSiren_" .. tone.name .. "_" .. obj:getID() .. "_" .. idCounter
      local srcId = obj:createSFXSource2(tone.event, "AudioDefaultLoop3D", uniqueName, v.data.refNodes[0].ref, 0)
      if srcId then
        sources[tone.name] = { id = srcId, volume = tone.volume or 1.5 }
        table.insert(toneOrder, tone.name)
      end
    end
  end

  configured = #toneOrder > 0
end

local function isActive()
  return currentTone > 0
end

local function getCurrentToneName()
  if currentTone > 0 and toneOrder[currentTone] then
    return toneOrder[currentTone]
  end
  return nil
end

-- Called every frame
local function updateGFX(dt)
  if not configured then return end

  -- Auto-stop siren if lights turned off
  local lightbar = electrics.values.lightbar_signal or 0
  if lightbar < 1 and currentTone > 0 then
    stopAll()
  end
end

local function onReset()
  stopAll()
end

local function onExtensionLoaded()
  electrics.values.rlsSirenActive = 0
  electrics.values.rlsSirenTone = ""
end

local function onExtensionUnloaded()
  stopAll()
  for _, src in pairs(sources) do
    if src and src.id then obj:deleteSFXSource(src.id) end
  end
  sources = {}
  toneOrder = {}
  configured = false
end

M.cycleSiren = cycleSiren
M.stopAll = stopAll
M.setConfig = setConfig
M.isActive = isActive
M.getCurrentToneName = getCurrentToneName
M.updateGFX = updateGFX
M.onReset = onReset
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
