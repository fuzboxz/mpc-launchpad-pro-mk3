-----------------------------------------------------------------------------------------------
-- LaunchpadProMK3.lua
-- Novation Launchpad Pro MK3 as a controller surface for Akai MPC 3.10.1 (Gen2, MPC Live III).
--
-- Programmer mode. The LPP3 sends grid pads as notes 11-88 (bottom-left first) and the edge
-- buttons as CCs. LEDs are driven by MPC state (property listeners + a 250 ms timer), never by
-- the button press alone.
--
-- Mapping (user-supplied, authoritative):
--   grid notes 11-88     8x8 clip window: launch (TriggerClip); Shift+pad = select (SelectClip)
--   bottom row CC 1-8    scene launch (TriggerRow 0-7)
--   track buttons CC 101-108
--                        101 record arm / Shift undo
--                        102 mute       / Shift redo
--                        103 solo       / Shift click (metronome)
--                        104 volume     (stub)
--                        105 pan        (stub)
--                        106 sends      / Shift tap tempo
--                        107 device (Q-Link page) / Shift tempo
--                        108 stop clip  / Shift swing
--   right column CC 19-89 + 99
--                        99 novation logo (status/home; Shift = probe mode)
--                        89 patterns, 79 steps, 69 pattern settings,
--                        59 velocity, 49 probability, 39 mutation, 29 micro step, 19 print to clip
--   top row CC 90-98     90 shift, 91 < (Shift = track prev), 92 > (Shift = track next),
--                        93 session (clip grid), 94 note = MPC pads mode (Shift = preset prev),
--                        95 chord = MPC Pad Perform page (Shift = preset next),
--                        96 custom = stub,
--                        97 sequencer, 98 projects/save
--   left column CC 10-80 10 record (Shift = capture MIDI), 20 play (Shift = loop toggle),
--                        30 fixed length (Shift = automation filter cycle),
--                        40 quantize (Shift = quantiser toggle), 50 duplicate/double, 60 clear,
--                        70 down, 80 up
--
-- LED protocol: F0 00 20 29 02 0E 03 <spec>... F7; spec = <type> <index> <data>.
--   type 0 = static palette (1 byte), 1 = flashing (2 bytes), 2 = pulsing (1 byte),
--   type 3 = RGB (3 bytes, 0-127). SendMIDISysex takes the payload without F0/F7.
--
-- Degrade, never break: every optional API is guarded; a missing feature disables its surface.
-----------------------------------------------------------------------------------------------

local deviceName = "LaunchpadProMK3" -- must match the file name
local port = 0 -- the one LPP3 output (order of output= lines in the .ini)
local dev = LaunchpadProMK3

-- LPP3 Programmer-mode layout
local GRID_NOTE0 = 11 -- notes 11-88, bottom-left first
local GRID_COLS, GRID_ROWS = 8, 8
local TOP = {
	shift = 90,
	left = 91,
	right = 92,
	session = 93,
	note = 94,
	chord = 95,
	custom = 96,
	sequencer = 97,
	save = 98,
}
local RIGHT = {
	logo = 99,
	patterns = 89,
	steps = 79,
	patternSettings = 69,
	velocity = 59,
	probability = 49,
	mutation = 39,
	microStep = 29,
	printToClip = 19,
}
local LEFT = { record = 10, play = 20, fixedLength = 30, quantize = 40, duplicate = 50, clear = 60, down = 70, up = 80 }
local TRACK = {
	recArm = 1,
	mute = 2,
	solo = 3,
	volume = 4,
	pan = 5,
	sends = 6,
	device = 7,
	stopClip = 8,
}
local TRACK_FN = {
	[TRACK.recArm] = "recArm",
	[TRACK.mute] = "mute",
	[TRACK.solo] = "solo",
	[TRACK.volume] = "volume",
	[TRACK.pan] = "pan",
	[TRACK.sends] = "sends",
	[TRACK.device] = "device",
	[TRACK.stopClip] = "stopClip",
}
local SCENE = { 89, 79, 69, 59, 49, 39, 29, 19 }

-- Reference data for the generated manual (docs/MANUAL.md, tools/gen-manual.lua).
-- Every CC that the dispatch tables handle must have an entry here; a test
-- enforces that both directions stay complete.
local ACTIONS = {
	[90] = { label = "Shift", plain = "hold for the shift functions", shift = "-" },
	[91] = { label = "Left", plain = "move the clip window left", shift = "previous track" },
	[92] = { label = "Right", plain = "move the clip window right", shift = "next track" },
	[93] = { label = "Session", plain = "clip grid (leaves every page)", shift = "toggle follow-current-track" },
	[94] = { label = "Note", plain = "MPC pads mode (layout from the track type)", shift = "previous plugin preset" },
	[95] = { label = "Chord", plain = "play the track's pads from the grid — kits plainly, melodic tracks with Pad Perform chords (repeat: leave)", shift = "next plugin preset" },
	[96] = { label = "Custom", plain = "unmapped stub", shift = "unmapped stub" },
	[97] = { label = "Sequencer", plain = "open the MPC step sequencer view", shift = "step sequencer: next bar" },
	[98] = { label = "Projects", plain = "unmapped stub", shift = "save" },
	[99] = { label = "Logo", plain = "log the current mode", shift = "probe mode (log every incoming message)" },
	[89] = { label = "Patterns", plain = "launch scene 1", shift = "scene 1 label function" },
	[79] = { label = "Steps", plain = "launch scene 2", shift = "scene 2 label function" },
	[69] = { label = "Pattern settings", plain = "launch scene 3", shift = "scene 3 label function" },
	[59] = { label = "Velocity", plain = "launch scene 4", shift = "scene 4 label function" },
	[49] = { label = "Probability", plain = "launch scene 5", shift = "scene 5 label function" },
	[39] = { label = "Mutation", plain = "launch scene 6", shift = "scene 6 label function" },
	[29] = { label = "Micro step", plain = "launch scene 7", shift = "scene 7 label function" },
	[19] = { label = "Print to clip", plain = "launch scene 8", shift = "scene 8 label function" },
	[10] = { label = "Record", plain = "arm / disarm recording", shift = "overdub" },
	[20] = { label = "Play", plain = "play / stop", shift = "loop on / off" },
	[30] = { label = "Fixed length", plain = "unmapped stub", shift = "cycle the automation filter" },
	[40] = { label = "Quantize", plain = "apply quantize", shift = "apply quantize" },
	[50] = { label = "Duplicate", plain = "hold: duplicate clip (origin, then target)", shift = "hold: duplicate clip" },
	[60] = { label = "Clear", plain = "hold: clear clip", shift = "hold: clear clip" },
	[70] = { label = "Down", plain = "window down / page value down", shift = "window down by 8" },
	[80] = { label = "Up", plain = "window up / page value up", shift = "window up by 8" },
	[1] = { label = "Rec arm", plain = "hold + track: record arm", shift = "undo" },
	[2] = { label = "Mute", plain = "hold + track: mute", shift = "redo" },
	[3] = { label = "Solo", plain = "hold + track: solo", shift = "-" },
	[4] = { label = "Volume", plain = "volume menu", shift = "-" },
	[5] = { label = "Pan", plain = "pan menu", shift = "-" },
	[6] = { label = "Sends", plain = "sends menu (repeat: next send)", shift = "tap tempo" },
	[7] = { label = "Device", plain = "Q-Link page (repeat: page 2, then exit)", shift = "tempo page" },
	[8] = { label = "Stop clip", plain = "hold + track: stop the track's clips", shift = "swing page" },
}

-- Clip state enum (order confirmed by the stock MPK script and mpc-3-ce Gen1 enum)
local S = {
	NoSlot = 0,
	Empty = 1,
	Ready = 2,
	WillPlay = 3,
	Playing = 4,
	WillStopPlaying = 5,
	WillRecord = 6,
	Recording = 7,
	WillStopRecording = 8,
	WillOverdub = 9,
	Overdubbing = 10,
	WillStopOverdubbing = 11,
}

-- LED colours (RGB 0-127)
local C = {
	off = { 0, 0, 0 },
	dim = { 12, 12, 12 },
	available = { 60, 60, 60 },
	white = { 127, 127, 127 },
	green = { 0, 127, 0 },
	red = { 127, 0, 0 },
	orange = { 127, 60, 0 },
	blue = { 0, 60, 127 },
	cyan = { 0, 127, 127 },
	magenta = { 127, 0, 127 },
	yellow = { 127, 127, 0 },
}

-- Volume fader steps, bottom (row 7) to top (row 0), in dB.
-- -inf is sent as a very low dB so the MPC shows -inf.
local VOLUME_DB = { [7] = -100, [6] = -30, [5] = -20, [4] = -9, [3] = -3, [2] = 0, [1] = 3, [0] = 6 }

-- One colour per send so Send 1-4 are distinguishable.
local SEND_COLOURS = { C.yellow, C.green, C.blue, C.orange }

-- State
local aperture, clipProps
local shift = false
local mode = "clip" -- clip / transport / track / probe
local originCol, originRow = 0, 0
local padCache = {} -- LED index -> "r,g,b" last sent
local ledSpecs = {} -- accumulated specs for the current flush
local ticks = 0
local blinkOn = false
local probeMode = false
local heldFunction = nil
local adjustMode = nil -- nil / "volume" / "pan" / "sends" (menu mode)
local adjustSend = 1 -- 1..4, the active send in sends mode
local adjustCol = 0 -- last grid column touched in the menu (for up/down nudges)
local lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
local clipOp = nil -- nil / "duplicate" / "clear"
local clipOrigin = nil -- {col, row} for duplicate
local tempoMode = false -- Shift+CC7 tempo page: up/down change BPM
local tempoHold = nil -- LEFT.up / LEFT.down while held (auto-repeat)
local tempoHoldTicks = 0 -- ticks since the tempo button was pressed
local swingMode = false -- Shift+CC8 swing page: up/down change swing
local swingHold = nil -- LEFT.up / LEFT.down while held (auto-repeat)
local swingHoldTicks = 0 -- ticks since the swing button was pressed
local qlinkMode = false -- CC7 device page: Q-Link faders (Twist-driven)
local qlinkPage = 0 -- 0 = Q-Links 0-7, 1 = Q-Links 8-15
local qlinkCol = 0 -- last grid column touched (for Shift+up/down nudges)
local followMode = false -- optional grid-follows-current-track; Shift+CC 93 toggles
local padsMode = false -- CC94 MPC pads mode: the grid quadrant mirrors mpc.controlSurface.pads
local padsColourCache = {} -- pad index -> ARGB int last sent (diff-only mirror)
local tapTicks = {} -- recent tap-tempo tick timestamps (50 ms per tick)
local padsLayout = "drum" -- CC 94 mode layout: drum (4x4 bank A) or pads64 (all four banks)
local boundPadNotes = {} -- grid notes currently routed away from the script
local keysPage = false -- Chord (CC 95) opened the keys page with pads mode
local keysPP = false -- we engaged the MPC's Pad Perform mode (melodic tracks only)
local trackIsMelodicFn = function()
	return false
end -- forward declaration; redefined next to firstLayoutForTrack

-- The Pad Perform page may stay open ONLY while the keys page owns the surface
-- AND the current track is melodic (device rule). Anything else sweeps it.
local function padPerformPageOurs()
	return keysPage and keysPP and trackIsMelodicFn()
end
local chromaticVirtualPad -- forward declaration (defined with the pad-mode helpers)
local nativeTap = false -- Shift held + CC 6 routed to the MPC's Tap Tempo control
local priorLayout, priorPage = nil, nil
local programmerEntered = false
local layoutQuerySent = false
local lastLog = {}

-----------------------------------------------------------------------------------------------
-- Utilities
-----------------------------------------------------------------------------------------------

local H = {}

function H.log(msg)
	pcall(function()
		print(deviceName .. ": " .. tostring(msg))
	end)
end

function H.logOnce(key, msg)
	if lastLog[key] then
		return
	end
	lastLog[key] = true
	H.log(msg)
end

function H.call(f, ...)
	if type(f) ~= "function" then
		return nil
	end
	local ok, r = pcall(f, ...)
	if ok then
		return r
	end
	return nil
end

function H.propValue(obj, name)
	local p = obj and obj[name]
	if p == nil then
		return nil
	end
	local ok, v = pcall(function()
		return p.value
	end)
	if ok then
		return v
	end
	return nil
end

-- Boolean view of a property value. MPC state properties such as RecordState
-- are numbers (0 = off), and Lua treats 0 as true — never test them directly.
function H.truthy(v)
	return v ~= nil and v ~= false and v ~= 0
end

-- Safe accessor: the member when it exists with the expected type, else nil.
-- mpc.* objects are sol2 tables/userdata; a missing build field must never raise.
function H.member(obj, key, kind)
	if obj == nil then
		return nil
	end
	local v = obj[key]
	if v ~= nil and (kind == nil or type(v) == kind) then
		return v
	end
	return nil
end

-- Shorthand for H.member(obj, key, "function"): the callable, or nil.
function H.callable(obj, key)
	return H.member(obj, key, "function")
end

-- Call currentTrack.<field>() with a one-time log when the build lacks it.
-- Returns true when the action ran.
function H.trackAction(field, logKey, label)
	local ct = mpc.tracks and mpc.tracks.currentTrack
	local f = H.callable(ct, field)
	if not f then
		H.logOnce(logKey, label .. " unavailable: currentTrack." .. field .. " missing")
		return false
	end
	H.call(f)
	return true
end

-- Is a project loaded? Several independent indicators, because no single one is
-- reliable: an empty project legitimately has 0 tracks, so the track count is
-- NOT an indicator. The MPC's native side dereferences project state and can
-- crash hard (a native abort that pcall cannot catch), so this guard is
-- preventive. Any one positive indicator counts as "loaded" — a false positive
-- only re-enables an action, a false negative would disable a working one.
-- Name of the current popup: "No Popup" (or empty) when none is open — the MPC
-- binary documents the property as "The name of the current popup, or empty if
-- there is no popup". Project-scoped native actions crash while a dialog owns
-- the UI (e.g. the New Project page), so an open popup blocks them.
function H.currentPopup()
	local em = mpc.engineMode
	local p = H.propValue(em, "CurrentPopup")
	if p == nil then
		p = H.call(H.callable(em, "GetCurrentPopup"))
	end
	return tostring(p or "")
end

function H.popupOpen()
	local p = H.currentPopup()
	if p == "" or p == "No Popup" then
		return false
	end
	-- The keys page's own Pad Perform page is not a blocking dialog while the
	-- keys page owns the surface AND the track is melodic: leaving it open is
	-- the feature (chord settings on screen). Any other state sweeps it away.
	if padPerformPageOurs() and p == "Pad Perform" then
		return false
	end
	return true
end

function H.projectLoaded()
	if H.popupOpen() then
		return false
	end
	if mpc.currentSequence ~= nil then
		return true
	end
	local tracks = mpc.tracks
	if tracks ~= nil and tracks.currentTrack ~= nil then
		return true
	end
	local bpm = H.call(H.callable(mpc.sequencer, "GetBPM"))
	if type(bpm) == "number" and bpm > 0 then
		return true
	end
	return false
end

-- Guard for project-scoped actions: true when safe to run, else a one-time log.
function H.requireProject(label)
	if H.projectLoaded() then
		return true
	end
	if H.popupOpen() then
		H.logOnce(label .. "-popup", label .. ": dialog open (" .. H.currentPopup() .. ")")
	else
		H.logOnce(label .. "-noproject", label .. ": no project loaded")
	end
	return false
end

function H.clamp01(v)
	v = tonumber(v) or 0
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

-- Nearest volume-fader row (0 = top, 7 = bottom) for a dB value.
function H.dbToRow(db)
	db = tonumber(db)
	if db == nil or db <= -60 then
		return 7
	elseif db <= -25 then
		return 6
	elseif db <= -14.5 then
		return 5
	elseif db <= -6 then
		return 4
	elseif db <= -1.5 then
		return 3
	elseif db <= 1.5 then
		return 2
	elseif db <= 4.5 then
		return 1
	end
	return 0
end

-- MPC volume fader curve, measured on 3.10.1: dB = 40*log10(gain) + 6.
-- Inverse: gain = 10^((dB - 6) / 40); -inf is gain 0.
function H.dbToGain(db)
	db = tonumber(db)
	if db == nil or db <= -60 then
		return 0
	end
	return 10 ^ ((db - 6) / 40)
end

function H.gainToDb(gain)
	gain = tonumber(gain)
	if gain == nil or gain <= 0 then
		return -100
	end
	return 40 * math.log(gain, 10) + 6
end

function H.trackAt(idx)
	return mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[idx]
end

function H.adjustPropName()
	if adjustMode == "volume" then
		return "Volume"
	elseif adjustMode == "pan" then
		return "Pan"
	elseif adjustMode == "sends" then
		return "Send" .. adjustSend
	end
	return nil
end

-- Page colour for the active fader menu (also used by the up/down arrows).
function H.adjustColour()
	if adjustMode == "pan" then
		return C.magenta
	elseif adjustMode == "sends" then
		return SEND_COLOURS[adjustSend] or C.yellow
	end
	return C.cyan
end

-- Pad mode availability: the mode button lights only when its mappings exist;
-- otherwise it stays off and the surface keeps today's behaviour.

function H.argb(c)
	c = tonumber(c) or 0
	return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

function H.scale7(v)
	v = tonumber(v) or 0
	if v < 0 then
		v = 0
	elseif v > 255 then
		v = 255
	end
	return math.floor(v * 127 / 255)
end

function H.rgbKey(r, g, b)
	return r .. "," .. g .. "," .. b
end

-- Global matrix position of a window cell
function H.globalPos(col, row)
	if aperture then
		local gc = H.call(aperture.ToGlobalColumn, col)
		local gr = H.call(aperture.ToGlobalRow, row)
		if type(gc) == "number" and type(gr) == "number" then
			return gc, gr
		end
	end
	return col + (originCol or 0), row + (originRow or 0)
end

-- Clip status: 0 = no clip, 1 = stopped, 2 = playing/recording, 3 = queued
local function clipStatus(col, row)
	local m = mpc.clipMatrix
	if not (m and m.HasClip) then
		return 0
	end
	local gc, gr = H.globalPos(col, row)
	local has = H.call(m.HasClip, gc, gr)
	if not has then
		return 0, gc, gr
	end
	if H.call(m.ClipIsPlaying, gc, gr) or H.call(m.ClipIsRecording, gc, gr) then
		return 2, gc, gr
	end
	if H.call(m.ClipIsStopped, gc, gr) then
		return 1, gc, gr
	end
	return 3, gc, gr
end

local function clipColour(col, row)
	local p = clipProps and clipProps[col] and clipProps[col][row]
	local c = H.propValue(p, "Colour")
	if type(c) == "number" and c ~= 0 then
		return c
	end
	local m = mpc.clipMatrix
	if m and m.GetClipColour then
		local gc, gr = H.globalPos(col, row)
		local v = H.call(m.GetClipColour, gc, gr)
		if type(v) == "number" then
			return v
		end
	end
	return 0x808080
end

-----------------------------------------------------------------------------------------------
-- LED output
-----------------------------------------------------------------------------------------------

local function addSpec(spec)
	ledSpecs[#ledSpecs + 1] = spec
end

local function ledRGB(index, r, g, b)
	index = tonumber(index)
	if not index then
		return
	end
	r, g, b = math.floor(tonumber(r) or 0), math.floor(tonumber(g) or 0), math.floor(tonumber(b) or 0)
	if r < 0 then
		r = 0
	elseif r > 127 then
		r = 127
	end
	if g < 0 then
		g = 0
	elseif g > 127 then
		g = 127
	end
	if b < 0 then
		b = 0
	elseif b > 127 then
		b = 127
	end
	local key = H.rgbKey(r, g, b)
	if padCache[index] == key then
		return
	end
	padCache[index] = key
	addSpec(string.char(3, index % 128, r, g, b))
end

-- Paint one button with a {r,g,b} colour table from C (the palette above).
local function ledCol(index, colour)
	ledRGB(index, colour[1], colour[2], colour[3])
end

local function ledOff(index)
	ledRGB(index, 0, 0, 0)
end

local function flushLEDs()
	if #ledSpecs == 0 then
		return
	end
	local header = string.char(0x00, 0x20, 0x29, 0x02, 0x0E, 0x03)
	-- one message per flush; the LPP3 accepts up to 106 specs
	local ok = pcall(function()
		dev.midiOut.SendMIDISysex(header .. table.concat(ledSpecs), port)
	end)
	if not ok then
		H.logOnce("sysex", "SendMIDISysex failed")
	end
	ledSpecs = {}
end

-- LPP3 layout control: enter Programmer mode (0x11) and restore the prior layout.
local function sendLayout(layout, page)
	local ok = pcall(function()
		dev.midiOut.SendMIDISysex(string.char(0x00, 0x20, 0x29, 0x02, 0x0E, 0x00, layout, page, 0x00), port)
	end)
	if not ok then
		H.logOnce("layout", "layout sysex failed")
	end
end

local function queryLayout()
	local ok = pcall(function()
		dev.midiOut.SendMIDISysex(string.char(0x00, 0x20, 0x29, 0x02, 0x0E, 0x00), port)
	end)
	if not ok then
		H.logOnce("layoutq", "layout query failed")
	end
end

-----------------------------------------------------------------------------------------------
-- Painting
-----------------------------------------------------------------------------------------------

-- Tempo page: a 7-segment display scaled to the grid. A 3-digit BPM uses
-- 2-column digits with 1-column gaps; a 2-digit BPM uses 4-column digits with
-- no gaps, so the number is as large as the grid allows.
local SEGMENTS = {
	["0"] = { a = true, b = true, c = true, d = true, e = true, f = true, g = false },
	["1"] = { a = false, b = true, c = true, d = false, e = false, f = false, g = false },
	["2"] = { a = true, b = true, c = false, d = true, e = true, f = false, g = true },
	["3"] = { a = true, b = true, c = true, d = true, e = false, f = false, g = true },
	["4"] = { a = false, b = true, c = true, d = false, e = false, f = true, g = true },
	["5"] = { a = true, b = false, c = true, d = true, e = false, f = true, g = true },
	["6"] = { a = true, b = false, c = true, d = true, e = true, f = true, g = true },
	["7"] = { a = true, b = true, c = true, d = false, e = false, f = false, g = false },
	["8"] = { a = true, b = true, c = true, d = true, e = true, f = true, g = true },
	["9"] = { a = true, b = true, c = true, d = true, e = false, f = true, g = true },
}

local function tempoPad(col, row, colour)
	if col >= 0 and col < GRID_COLS and row >= 0 and row < GRID_ROWS then
		ledRGB(10 * (8 - row) + col + 1, colour[1], colour[2], colour[3])
	end
end

-- Draw one 7-segment digit in the box (x0, y0) .. (x0+w-1, y0+h-1).
local function drawDigit(ch, x0, y0, w, h, colour)
	local seg = SEGMENTS[ch]
	if not seg then
		return
	end
	local mid = math.floor(h / 2)
	if seg.a then
		for c = 0, w - 1 do
			tempoPad(x0 + c, y0, colour)
		end
	end
	if seg.d then
		for c = 0, w - 1 do
			tempoPad(x0 + c, y0 + h - 1, colour)
		end
	end
	if seg.g then
		for c = 0, w - 1 do
			tempoPad(x0 + c, y0 + mid, colour)
		end
	end
	if seg.f then
		for r = 0, mid do
			tempoPad(x0, y0 + r, colour)
		end
	end
	if seg.b then
		for r = 0, mid do
			tempoPad(x0 + w - 1, y0 + r, colour)
		end
	end
	if seg.e then
		for r = mid, h - 1 do
			tempoPad(x0, y0 + r, colour)
		end
	end
	if seg.c then
		for r = mid, h - 1 do
			tempoPad(x0 + w - 1, y0 + r, colour)
		end
	end
end

local function paintNumberGrid(value)
	value = math.max(0, math.min(999, math.floor(value)))
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			ledOff(10 * (8 - row) + col + 1)
		end
	end
	-- Left-aligned, no gaps. The hundreds digit is narrow (1 column for a
	-- leading 1, 2 columns otherwise) so the tens and ones digits get the rest
	-- of the width and show more detail.
	local text
	local widths = {}
	if value >= 100 then
		text = string.format("%3d", value)
		widths[1] = (text:sub(1, 1) == "1") and 1 or 2
		local remaining = GRID_COLS - widths[1]
		widths[2] = math.floor(remaining / 2)
		widths[3] = remaining - widths[2]
	else
		text = string.format("%2d", value)
		widths[1] = 4
		widths[2] = 4
	end
	-- colour by position from the right: ones white (brightest), tens orange,
	-- hundreds blue. Blue/orange/white differ in both hue and luminance, so the
	-- digits stay distinct for red-green colourblindness (the common type).
	local colours = { C.white, C.orange, C.blue }
	local x0 = 0
	for i = 1, #text do
		drawDigit(text:sub(i, i), x0, 0, widths[i], GRID_ROWS, colours[#text - i + 1])
		x0 = x0 + widths[i]
	end
end

local function paintTempoGrid()
	local bpm = math.floor(H.call(mpc.sequencer and mpc.sequencer.GetBPM) or 120)
	paintNumberGrid(bpm)
end

local function paintSwingGrid()
	local q = mpc.sequencer and mpc.sequencer.quantiser
	-- MPC swing: 50% = straight, 75% = max; clamp the display into the range
	local swing = math.floor(H.call(q and q.GetSwing) or 50)
	paintNumberGrid(math.max(50, math.min(75, swing)))
end

local function paintAdjustGrid()
	local colour = C.cyan
	if adjustMode == "pan" then
		colour = C.magenta
	elseif adjustMode == "sends" then
		colour = SEND_COLOURS[adjustSend] or C.yellow
	end
	local name = H.adjustPropName()
	local trackCount = H.call(mpc.tracks and mpc.tracks.SizeNormalTracks) or GRID_COLS
	for col = 0, GRID_COLS - 1 do
		local gc = H.globalPos(col, 0)
		local t = H.trackAt(gc)
		if t and gc < trackCount then
			local litCount
			if adjustMode == "volume" then
				-- dB fader: -inf = no pads, +6 dB = all 8 pads
				local gain = H.propValue(t, "Volume")
				local db = H.gainToDb(gain)
				local row = H.dbToRow(db)
				litCount = (db <= -60) and 0 or (GRID_ROWS - row)
			else
				local value = H.propValue(t, name) or 0
				if type(value) ~= "number" then
					value = 0
				end
				litCount = math.floor(value * GRID_ROWS + 0.5)
			end
			for row = 0, GRID_ROWS - 1 do
				local idx = 10 * (8 - row) + col + 1
				local fromBottom = 7 - row
				if fromBottom < litCount then
					ledCol(idx, colour)
				else
					ledCol(idx, C.dim)
				end
			end
		else
			for row = 0, GRID_ROWS - 1 do
				ledOff(10 * (8 - row) + col + 1)
			end
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Q-Link page (CC 7 device). SetPosition updates the ValueString but does not reach the
-- MPC edit-mode value on 3.10.1, so changes are driven with Twist (rotate by delta) instead.
-----------------------------------------------------------------------------------------------

local paintAll -- forward declaration (defined below)

local function qlinkAt(i)
	local cs = mpc.controlSurface
	local ql = cs and cs.qlinks
	if not ql then
		return nil
	end
	return ql[i]
end

local function qlinkCount()
	local cs = mpc.controlSurface
	local ql = cs and cs.qlinks
	if not ql then
		return 0
	end
	return H.call(ql.GetNumQLinks) or 0
end

local function qlinkPosition(i)
	local q = qlinkAt(i)
	if not q then
		return 0
	end
	return H.call(q.GetPosition) or 0
end

-- Touch() signature is unknown on 3.10.1: try it with no args, ignore any error.
local function touchQlink(q)
	if q and type(q.Touch) == "function" then
		pcall(q.Touch)
	end
end

-- Drive qlink i to pos: Twist(target - GetPosition()), clamped to +-127, repeated at most
-- twice to absorb the GetPosition lag; falls back to SetPosition when Twist is missing.
local qlinkTargetLogged = {} -- page-open diagnosis: one line per qlink
-- The 16 Q-Links are the MPC's four Q-Link banks (4 knobs each); each bank gets its
-- own fader colour so the groups are visually distinct on the grid.
local QLINK_BANK_COLOURS = { C.cyan, C.magenta, C.yellow, C.blue }
-- Flip/binary params (e.g. Kill EQ Thru/Kill) show the same value string for many
-- positions and only two strings overall; once learned, presses round to 0/127 and
-- the column shows a single lit extreme pad instead of a fill.
local qlinkFlip = {}
local qlinkSeenStrings = {} -- i -> set of distinct value strings observed
local qlinkSeenPos = {} -- i -> { min = , max = }

local function qlinkTargetName(i)
	local q = qlinkAt(i)
	local name = H.call(q and q.GetTargetName)
	if type(name) ~= "string" then
		name = H.propValue(q, "TargetName")
	end
	return type(name) == "string" and name or ""
end

-- Drive qlink i to pos. Twist is primary (a real knob rotation); SetValue (the target's
-- un-normalised value) is the second attempt when Twist does not move the target;
-- SetPosition only syncs the knob position display and is the last resort.
local function setQlinkPosition(i, pos)
	local q = qlinkAt(i)
	if not q then
		return
	end
	if not qlinkTargetLogged[i] then
		qlinkTargetLogged[i] = true
		H.log(string.format("qlink %d target '%s'", i, qlinkTargetName(i)))
	end
	local before = H.call(q.GetValueString)
	local posBefore = H.call(q.GetPosition) or 0
	touchQlink(q)
	if type(q.Twist) == "function" then
		for _ = 1, 2 do
			local delta = pos - (H.call(q.GetPosition) or 0)
			if delta == 0 then
				break
			end
			if delta > 127 then
				delta = 127
			elseif delta < -127 then
				delta = -127
			end
			H.call(q.Twist, delta)
		end
	end
	local afterTwist = H.call(q.GetValueString)
	if afterTwist == before and type(q.SetValue) == "function" then
		-- Twist did not change the target value: try the target value directly.
		-- GetValue() is the current un-normalised value; scale by the position change.
		local v = H.call(q.GetValue)
		if type(v) == "number" and posBefore ~= 0 then
			H.call(q.SetValue, v * pos / posBefore)
		end
		H.call(q.SetPosition, pos)
	elseif type(q.SetPosition) == "function" then
		H.call(q.SetPosition, pos) -- keep the knob position in sync with the target
	end
	touchQlink(q)
	local str = tostring(H.call(q.GetValueString) or "")
	H.log(string.format("qlink %d = %d (%s)", i, pos, str))
	-- flip learning: remember distinct value strings and the position span; two distinct
	-- strings across a wide span means the parameter is binary (round to extremes)
	if str ~= "" then
		local seen = qlinkSeenStrings[i]
		if not seen then
			seen = {}
			qlinkSeenStrings[i] = seen
		end
		seen[str] = true
		local span = qlinkSeenPos[i]
		if not span then
			span = { min = pos, max = pos }
			qlinkSeenPos[i] = span
		else
			if pos < span.min then
				span.min = pos
			end
			if pos > span.max then
				span.max = pos
			end
		end
		local n = 0
		for _ in pairs(seen) do
			n = n + 1
		end
		if n == 2 and span.max - span.min >= 48 and not qlinkFlip[i] then
			qlinkFlip[i] = true
			H.log(string.format("qlink %d flip parameter", i))
		end
	end
end

-- A qlink with an empty target name is unassigned in the current Q-Link mode: its
-- column stays fully dark so the grid only shows faders that control something.
local function qlinkAssigned(i)
	return qlinkTargetName(i) ~= ""
end

local function qlinkColour(i)
	return QLINK_BANK_COLOURS[math.floor(i / 4) + 1] or C.cyan
end

-- Columns show only the ASSIGNED Q-Links, compacted left-to-right with no gaps
-- (unassigned slots would leave dark columns in between). The order follows the
-- MPC's Q-Link screen, which lists the 16 slots column-major with each bank/page
-- running in reverse index order: its page 1 is Q-Links 12,8,4,0, page 2 is 13,9,5,1,
-- page 3 is 14,10,6,2, page 4 is 15,11,7,3 (device-verified twice over: the Kill EQ
-- page lives at 0,4,8,12 and the Beat Repeat page at 1,5,9,13, each reading newest
-- slot first on the screen). Page 1 of the Launchpad grid shows
-- the first 8 assigned Q-Links in this order, page 2 the rest.
local QLINK_PAGE_GROUPS = {
	[0] = { { 12, 8, 4, 0 }, { 13, 9, 5, 1 } }, -- MPC pages 1+2
	[1] = { { 14, 10, 6, 2 }, { 15, 11, 7, 3 } }, -- MPC pages 3+4
}
local qlinkColumnMap = {}

-- Fixed slot positions: columns 1-4 are ALWAYS the MPC's page 1 slots (12,8,4,0) and
-- columns 5-8 its page 2 slots (13,9,5,1), one column per slot — no compaction, no
-- sliding. An unassigned slot keeps its column as a dark gap exactly where the MPC
-- screen shows it (device-verified: the user's page 1 reads unmapped, High, Mid, Low).
local function buildQlinkColumnMap(page)
	qlinkColumnMap = {}
	local count = qlinkCount()
	local groups = QLINK_PAGE_GROUPS[page or qlinkPage] or QLINK_PAGE_GROUPS[0]
	for g = 1, 2 do
		for rank, i in ipairs(groups[g]) do
			if i < count and qlinkAssigned(i) then
				qlinkColumnMap[4 * (g - 1) + rank - 1] = i
			end
		end
	end
end

local function qlinkForColumn(col)
	return qlinkColumnMap[col]
end

local function qlinkPageHasContent(page)
	local count = qlinkCount()
	for _, group in ipairs(QLINK_PAGE_GROUPS[page]) do
		for _, i in ipairs(group) do
			if i < count and qlinkAssigned(i) then
				return true
			end
		end
	end
	return false
end

local function paintQlinkGrid()
	buildQlinkColumnMap()
	for col = 0, GRID_COLS - 1 do
		local i = qlinkForColumn(col)
		local assigned = i ~= nil
		local pos = assigned and qlinkPosition(i) or 0
		local colour = qlinkColour(i or 0)
		local litCount = math.floor(pos / 127 * GRID_ROWS + 0.5)
		for row = 0, GRID_ROWS - 1 do
			local idx = 10 * (8 - row) + col + 1
			local fromBottom = 7 - row
			if not assigned then
				ledOff(idx)
			elseif qlinkFlip[i] then
				-- binary parameter: only the matching extreme pad is lit (top = max)
				if (pos >= 64 and row == 0) or (pos < 64 and row == GRID_ROWS - 1) then
					ledCol(idx, colour)
				else
					ledCol(idx, C.dim)
				end
			elseif fromBottom < litCount then
				ledCol(idx, colour)
			else
				ledCol(idx, C.dim)
			end
		end
	end
end

local function handleQlinkPad(col, row)
	buildQlinkColumnMap()
	local i = qlinkForColumn(col)
	if i == nil then
		return
	end
	local target
	if qlinkFlip[i] then
		-- binary parameter: bottom half of the column = min extreme, top half = max
		target = (row < GRID_ROWS / 2) and 127 or 0
	else
		target = math.floor((GRID_ROWS - row) / GRID_ROWS * 127 + 0.5)
	end
	setQlinkPosition(i, target)
	qlinkCol = col
	paintAll()
end

local function nudgeQlink(delta)
	buildQlinkColumnMap()
	local i = qlinkForColumn(qlinkCol)
	local q = qlinkAt(i)
	if not q or type(q.Twist) ~= "function" or i >= qlinkCount() then
		return
	end
	local pos = qlinkPosition(i)
	if pos + delta < 0 or pos + delta > 127 then
		return
	end
	H.call(q.Twist, delta)
	H.log(string.format("qlink %d = %d (%s)", i, pos + delta, tostring(H.call(q.GetValueString) or "")))
	paintAll()
end

local exitPadsMode -- forward declaration (defined with the pad-mode helpers)

local function enterQlink()
	if not H.requireProject("qlink page") then
		return
	end
	local cs = mpc.controlSurface
	if not (cs and cs.qlinks) then
		H.logOnce("noqlinks", "qlink page unavailable: controlSurface.qlinks missing")
		return
	end
	exitPadsMode() -- the Q-Link page needs the whole grid: any pads-mode note
	-- bindings (quadrant/64 pads) are handed back, or the bound notes keep
	-- PLAYING the MPC pads through the page (device-reported on the Mini port)
	adjustMode = nil
	tempoMode = false
	swingMode = false
	qlinkMode = true
	qlinkPage = 0
	qlinkCol = 0
	qlinkTargetLogged = {}
	qlinkFlip = {}
	qlinkSeenStrings = {}
	qlinkSeenPos = {}
	buildQlinkColumnMap(0)
	local map = {}
	local assignedCount = 0
	for c = 0, GRID_COLS - 1 do
		local i = qlinkColumnMap[c]
		if i then
			assignedCount = assignedCount + 1
			map[#map + 1] = (c + 1) .. "=" .. qlinkTargetName(i)
		else
			map[#map + 1] = (c + 1) .. "=-"
		end
	end
	H.log("qlink page (" .. assignedCount .. " assigned): " .. table.concat(map, ", "))
	paintAll()
end
local function exitQlink()
	qlinkMode = false
	H.log("qlink page off")
	paintAll()
end

-- Clip states that blink: the MPK's fast set (transitions); other states > 3
-- (playing/recording/overdubbing) blink slowly. RGB pads have no blink channel
-- in the sysex we use, so blinking repaints the pad dim on the timer phase:
-- fast = the 2 Hz blinkOn, slow = 1 Hz via ticks.
local CLIP_BLINK_FAST = { [3] = true, [5] = true, [6] = true, [8] = true, [9] = true, [11] = true }

local function blinkPhase(fast)
	if fast then
		return blinkOn
	end
	return ticks % 10 < 5
end

-- muted track is dimmed
local MUTED_DIM = 0.1 -- brightness factor for muted tracks (1.0 = unchanged)
local function trackMuted(col)
	local gc = H.globalPos(col, 0)
	local t = mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[gc]
	return H.propValue(t, "Mute") == true
end

-- One clip slot from its live property State (MPK semantics, device-verified):
-- < 2 empty, 2 = stopped (the clip's Colour, alpha ignored), 3-5 = playing or
-- queued (green), >= 6 = recording (red). Selected empty slots light dim white
-- (ring substitute). Returns false when the slot has no State property, so the
-- caller falls back to polling clipMatrix for that pad.
local function paintClipSlot(col, row)
	local p = clipProps and clipProps[col] and clipProps[col][row]
	local state = tonumber(H.propValue(p, "State"))
	if state == nil then
		return false
	end
	local idx = 10 * (8 - row) + col + 1
	if state < 2 then
		if H.propValue(p, "Selected") == true then
			ledCol(idx, C.available)
		else
			ledOff(idx)
		end
		return true
	end
	local r, g, b
	if state >= 6 then
		r, g, b = C.red[1], C.red[2], C.red[3]
	elseif state >= 3 then
		r, g, b = C.green[1], C.green[2], C.green[3]
	else
		r, g, b = H.argb(clipColour(col, row))
	end
	if state >= 3 and not blinkPhase(CLIP_BLINK_FAST[state]) then
		r, g, b = H.scale7(r * 0.18), H.scale7(g * 0.18), H.scale7(b * 0.18)
	end
	if trackMuted(col) then
		r, g, b = math.min(r, 127) * MUTED_DIM, math.min(g, 127) * MUTED_DIM, math.min(b, 127) * MUTED_DIM
	end
	ledRGB(idx, r, g, b)
	return true
end

-- Pads mode grid: the bottom-left 4x4 quadrant mirrors mpc.controlSurface.pads[i].Colour
-- (ARGB int, alpha ignored); the rest of the grid is dark. poll=true re-reads the pad
-- colours; padsColourCache keeps the last ARGB per pad so only diffs are sent.
-- 64-pads layout LEDs: every pad mirrors its MPC colour from controlSurface.pads.virtual
-- (128 virtual pads; they read 0 until a program is loaded). Pads with no colour keep
-- a dim blue tint so the grid shape stays visible.
local function paintChromaticGrid()
	local cs = mpc.controlSurface
	local pads = cs and cs.pads
	local virt = pads and pads.virtual
	for padRow = 0, 7 do
		for col = 0, 7 do
			local idx = 10 * (padRow + 1) + col + 1
			local i = padRow * 8 + col
			local p = (virt and virt[i]) or (pads and pads[i])
			local v = H.call(p and p.GetColour)
			if type(v) ~= "number" then
				v = H.propValue(p, "Colour")
			end
			if type(v) == "number" and v ~= 0 and v ~= -16777216 then
				local r, g, b = H.argb(v)
				ledRGB(idx, H.scale7(r), H.scale7(g), H.scale7(b))
			else
				ledRGB(idx, 0, 15, 30)
			end
		end
	end
end

local function paintPadsGrid(poll)
	if padsLayout == "pads64" then
		paintChromaticGrid()
		return
	end
	local quadrant = {}
	for i = 0, 15 do
		quadrant[10 * (math.floor(i / 4) + 1) + (i % 4) + 1] = true
	end
	-- the rest of the grid stays dark; the quadrant pads are painted below
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			local idx = 10 * (8 - row) + col + 1
			if not quadrant[idx] then
				ledOff(idx)
			end
		end
	end
	local pads = mpc.controlSurface and mpc.controlSurface.pads
	for i = 0, 15 do
		local idx = 10 * (math.floor(i / 4) + 1) + (i % 4) + 1
		if poll then
			local p = pads and pads[i]
			local v = H.call(p and p.GetColour)
			if type(v) ~= "number" then
				v = H.propValue(p, "Colour")
			end
			if v ~= padsColourCache[i] then
				padsColourCache[i] = v
				local r, g, b = H.argb(v)
				ledRGB(idx, H.scale7(r), H.scale7(g), H.scale7(b))
			end
		elseif type(padsColourCache[i]) == "number" then
			local r, g, b = H.argb(padsColourCache[i])
			ledRGB(idx, H.scale7(r), H.scale7(g), H.scale7(b))
		end
	end
end

local function paintGrid()
	if padsMode then
		-- mirror refresh every 2 ticks (100 ms); between refreshes repaint from the cache
		paintPadsGrid(ticks % 2 == 0)
		return
	end
	if tempoMode then
		paintTempoGrid()
		return
	end
	if swingMode then
		paintSwingGrid()
		return
	end
	if qlinkMode then
		paintQlinkGrid()
		return
	end
	if adjustMode then
		paintAdjustGrid()
		return
	end
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			local idx = 10 * (8 - row) + col + 1
			if not (clipProps and paintClipSlot(col, row)) then
				-- polling fallback: clipProperties missing or a slot without State
				local status = clipStatus(col, row)
				if status == 0 then
					ledOff(idx)
				else
					local c = clipColour(col, row)
					local r, g, b = H.argb(c)
					local k = 1.0
					if status == 1 then
						k = 0.18
					elseif status == 3 then
						k = blinkOn and 0.9 or 0.18
					elseif status == 2 then
						k = 0.95
					end
					if trackMuted(col) then
						k = k * MUTED_DIM
					end
					ledRGB(idx, H.scale7(r * k), H.scale7(g * k), H.scale7(b * k))
				end
			end
		end
	end
end

local function paintScene()
	for row = 0, 7 do
		local idx = SCENE[row + 1]
		local state = nil
		if aperture and aperture.sceneProperties and aperture.sceneProperties[row] then
			state = H.propValue(aperture.sceneProperties[row], "State")
		end
		if state == S.Playing or state == S.Recording then
			ledCol(idx, C.green)
		elseif state == S.WillPlay or state == S.WillRecord then
			ledRGB(
				idx,
				blinkOn and C.green[1] or C.dim[1],
				blinkOn and C.green[2] or C.dim[2],
				blinkOn and C.green[3] or C.dim[3]
			)
		else
			ledCol(idx, C.dim)
		end
	end
end

local function paintTrack()
	-- CC 1-8: function buttons; the held or adjusted one bright, others dim.
	local function fnAvailable(fn)
		if not H.projectLoaded() then
			return false -- no project / dialog open: project-scoped menus are unavailable
		end
		if fn == "device" then
			local cs = mpc.controlSurface
			return (cs and cs.qlinks ~= nil) or (mpc.sequencer ~= nil and mpc.sequencer.SetBPM ~= nil)
		elseif fn == "stopClip" then
			return aperture ~= nil and aperture.StopClipsOnTrack ~= nil
		end
		return mpc.tracks ~= nil
	end
	local function fnColour(fn)
		if
			heldFunction == fn
			or adjustMode == fn
			or (fn == "device" and (tempoMode or qlinkMode))
			or (fn == "stopClip" and swingMode)
		then
			return C.white
		elseif fnAvailable(fn) then
			return C.available
		else
			return C.off
		end
	end
	local arm = fnColour("recArm")
	local mute = fnColour("mute")
	local solo = fnColour("solo")
	local volume = fnColour("volume")
	local pan = fnColour("pan")
	local sends = fnColour("sends")
	local device = fnColour("device")
	local stopClip = fnColour("stopClip")
	ledCol(TRACK.recArm, arm)
	ledCol(TRACK.mute, mute)
	ledCol(TRACK.solo, solo)
	ledCol(TRACK.volume, volume)
	ledCol(TRACK.pan, pan)
	ledCol(TRACK.sends, sends)
	ledCol(TRACK.device, device)
	ledCol(TRACK.stopClip, stopClip)
	-- CC 101-108: track buttons. Show the held function's state per track, or the track colour.
	for col = 0, 7 do
		local gc = H.globalPos(col, 0)
		local t = mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[gc]
		local r, g, b = C.dim[1], C.dim[2], C.dim[3]
		if t then
			if heldFunction == "mute" then
				if H.propValue(t, "Mute") then
					r, g, b = C.orange[1], C.orange[2], C.orange[3]
				end
			elseif heldFunction == "solo" then
				if H.propValue(t, "Solo") then
					r, g, b = C.yellow[1], C.yellow[2], C.yellow[3]
				end
			elseif heldFunction == "recArm" then
				if H.propValue(t, "RecArm") then
					r, g, b = C.red[1], C.red[2], C.red[3]
				end
			else
				local c = H.propValue(t, "Colour")
				if type(c) == "number" then
					local cr, cg, cb = H.argb(c)
					local k = H.propValue(t, "Mute") == true and 0.3 * MUTED_DIM or 0.3
					r, g, b = H.scale7(cr * k), H.scale7(cg * k), H.scale7(cb * k)
				end
			end
		end
		if t then
			ledRGB(101 + col, r, g, b)
		else
			ledOff(101 + col)
		end
	end
end

local padsLayoutAvailable -- forward declaration (defined with the pad-mode helpers)

local function paintTop()
	local function modeColour(m)
		if mode == m then
			return C.white
		else
			return C.dim
		end
	end
	local projectOn = H.projectLoaded()
	-- session shows cyan while grid-follow is enabled so the toggle state is visible
	local session = (not projectOn and C.off) or (followMode and C.cyan) or modeColour("clip")
	local sequencer = modeColour("step")
	local note = C.off
	if padsMode then
		note = (padsLayout == "pads64") and C.cyan or C.white
	elseif padsLayoutAvailable() and H.projectLoaded() then
		note = C.available
	end
	local chord = (keysPage and C.white) or (projectOn and C.available or C.off) -- keys page owns the grid
	local custom = C.off -- stub
	ledCol(TOP.session, session)
	ledCol(TOP.sequencer, sequencer)
	ledCol(TOP.note, note)
	ledCol(TOP.chord, chord)
	ledCol(TOP.custom, custom)
	-- left/right match the up/down arrows: white while available, off without a
	-- project (the arrows are window/track navigation, not page controls)
	local arrows = projectOn and C.white or C.off
	ledCol(TOP.left, arrows)
	ledCol(TOP.right, arrows)
	local saveAvailable = mpc.controlSurface ~= nil and mpc.controlSurface.save ~= nil
	if not projectOn then
		ledCol(TOP.save, C.off)
	else
		ledCol(TOP.save, saveAvailable and C.available or C.dim)
	end
	ledRGB(
		TOP.shift,
		shift and C.white[1] or C.dim[1],
		shift and C.white[2] or C.dim[2],
		shift and C.white[3] or C.dim[3]
	)
end

-- Quantiser on/off is a project setting (sequencer.quantiser.Enabled).
local function quantiserEnabled()
	return H.truthy(H.propValue(mpc.sequencer and mpc.sequencer.quantiser, "Enabled"))
end

local function paintLeft()
	local sq = mpc.sequencer
	local playing = H.truthy(sq and H.call(sq.IsPlaying) or H.propValue(sq, "Playing"))
	local recording = H.truthy(H.propValue(sq, "RecordState"))
	local overdub = H.truthy(H.propValue(sq, "OverdubState"))
	local loop = H.truthy(H.propValue(sq, "Loop"))
	-- play: green while playing, orange while loop is enabled, dim otherwise
	if playing then
		ledCol(LEFT.play, C.green)
	elseif loop then
		ledCol(LEFT.play, C.orange)
	else
		ledCol(LEFT.play, C.dim)
	end
	-- record: red while recording, orange while overdubbing, dim otherwise
	if recording then
		ledCol(LEFT.record, C.red)
	elseif overdub then
		ledCol(LEFT.record, C.orange)
	else
		ledCol(LEFT.record, C.dim)
	end
	ledOff(LEFT.fixedLength)
	local quantizeAvailable = mpc.controlSurface ~= nil and mpc.controlSurface.quantizeApply ~= nil
	if not quantizeAvailable then
		ledCol(LEFT.quantize, C.off)
	elseif quantiserEnabled() then
		ledCol(LEFT.quantize, C.cyan) -- quantiser is on
	else
		ledCol(LEFT.quantize, C.white) -- available, quantiser off
	end
	local projectOn = H.projectLoaded()
	local nudgeOn = adjustMode ~= nil or tempoMode or swingMode or qlinkMode
	local pageColour = tempoMode and C.white
		or (swingMode and C.yellow or (qlinkMode and qlinkColour(qlinkForColumn(0) or 0) or H.adjustColour()))
	ledCol(LEFT.duplicate, projectOn and C.white or C.off)
	ledCol(LEFT.clear, projectOn and C.white or C.off)
	ledCol(LEFT.down, (not projectOn and C.off) or (nudgeOn and pageColour or C.white))
	ledCol(LEFT.up, (not projectOn and C.off) or (nudgeOn and pageColour or C.white))
end

local function paintRight()
	-- the right column CC 19-89 is the scene row (painted by paintScene);
	-- only the Novation logo (CC 99) is painted here.
	ledRGB(
		RIGHT.logo,
		probeMode and C.cyan[1] or C.dim[1],
		probeMode and C.cyan[2] or C.dim[2],
		probeMode and C.cyan[3] or C.dim[3]
	)
end

paintAll = function()
	paintGrid()
	paintScene()
	paintTrack()
	paintTop()
	paintLeft()
	paintRight()
	flushLEDs()
end

-----------------------------------------------------------------------------------------------
-- Listeners
-----------------------------------------------------------------------------------------------

local listeners = {} -- every property listened to; stopped by removeListeners
local gridListeners = {} -- the current window's clip slots; rebound on window moves

local function listen(prop, fn, store)
	if prop and type(prop.listen) == "function" then
		local ok = pcall(function()
			prop:listen(fn, deviceName)
		end)
		if ok then
			local target = store or listeners
			target[#target + 1] = prop
		end
	end
end

-- Wrap a repaint so a failing listener callback can never break MPC's dispatch.
local function repaintFn(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			H.logOnce("listenererror", "listener error: " .. tostring(err))
		end
	end
end

local function stopProps(props)
	for _, prop in ipairs(props) do
		if prop and type(prop.stopListening) == "function" then
			pcall(function()
				prop:stopListening(deviceName)
			end)
		end
	end
end

-- (Re-)register the 8x8 slot listeners: Colour/State/Selected -> full grid
-- repaint (MPK-style, so blink phases stay in sync). The aperture's
-- clipProperties follow the window, so every window move rebinds.
local function listenGrid()
	stopProps(gridListeners)
	gridListeners = {}
	if not clipProps then
		return
	end
	for col = 0, GRID_COLS - 1 do
		for row = 0, GRID_ROWS - 1 do
			local p = clipProps[col] and clipProps[col][row]
			if p then
				local repaint = repaintFn(function()
					paintGrid()
					flushLEDs()
				end)
				listen(p.Colour, repaint, gridListeners)
				listen(p.State, repaint, gridListeners)
				listen(p.Selected, repaint, gridListeners)
			end
		end
	end
end

-- Follow MPC's current track: move the aperture window to that track's column
-- (Master matrix for the master track), then rebind the slot listeners for the
-- new window and repaint. The track row (CC 101-108) selects MPC's current
-- track, so the grid follows track selection too.
local function followCurrentTrack(index)
	if followMode and aperture and type(index) == "number" then
		local normalCount = H.call(mpc.tracks and mpc.tracks.SizeNormalTracks) or 0
		if index >= normalCount then
			H.call(aperture.SetActiveMatrix, "Master")
			H.call(aperture.MoveToColumn, index - normalCount)
		else
			H.call(aperture.SetActiveMatrix, "Normal")
			H.call(aperture.MoveToColumn, index)
		end
		H.log("follow current track " .. tostring(index))
	end
	listenGrid()
	padCache = {}
	paintAll()
end

local function listenAll()
	if aperture and aperture.sceneProperties then
		for row = 0, 7 do
			local p = aperture.sceneProperties[row]
			if p then
				listen(
					p.State,
					repaintFn(function()
						paintScene()
						flushLEDs()
					end)
				)
			end
		end
	end
	local tracks = mpc.tracks and mpc.tracks.normalTracks
	if tracks then
		for i = 0, 7 do
			local t = tracks[i]
			if t then
				local repaint = repaintFn(function()
					paintTrack()
					flushLEDs()
				end)
				listen(t.Mute, repaint)
				listen(t.Solo, repaint)
				listen(t.RecArm, repaint)
			end
		end
	end
	local sq = mpc.sequencer
	if sq then
		local repaint = repaintFn(function()
			paintLeft()
			flushLEDs()
		end)
		listen(sq.Playing, repaint)
		listen(sq.RecordState, repaint)
		listen(sq.OverdubState, repaint)
		listen(sq.Loop, repaint)
		listen(sq.quantiser and sq.quantiser.Enabled, repaint)
	end
	local ct = mpc.tracks and mpc.tracks.currentTrack
	if ct then
		listen(
			ct.Index,
			repaintFn(function(newIndex)
				followCurrentTrack(newIndex)
			end)
		)
	end
	-- align the window with the current track (also registers the slot listeners)
	followCurrentTrack(H.propValue(ct, "Index"))
end

local function removeListeners()
	stopProps(gridListeners)
	gridListeners = {}
	stopProps(listeners)
	listeners = {}
end

-----------------------------------------------------------------------------------------------
-- Actions
-----------------------------------------------------------------------------------------------

-----------------------------------------------------------------------------------------------
-- Pad modes (CC 94 MPC pads / CC 96 track mute)
-----------------------------------------------------------------------------------------------

-- The pad modes own the grid, so the grid-hungry states (fader menus, tempo/swing pages,
-- armed clip ops) close when one opens.
local function closeGridStates()
	adjustMode = nil
	tempoMode = false
	swingMode = false
	tempoHold = nil
	swingHold = nil
	clipOp = nil
	clipOrigin = nil
	lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
end

-- Grid note of a pads-mode pad: padIndex 0-15 -> the bottom-left 4x4 quadrant.
local function padsModeNote(i)
	return 10 * (math.floor(i / 4) + 1) + (i % 4) + 1
end

-- Exit pads mode: hand the 16 notes back to the script (the caller repaints the clip grid).
-- pressSurfaceButton drives the MPC's own control-surface buttons. CC 95 (chord)
-- opens the MPC's Pad Perform page — the on-screen page with the pad chord/scale
-- performance modes and their key/scale settings — via controlSurface.padPerform.

-- The virtual padPerform press opens the Pad Perform DIALOG on 3.10.1, not
-- just the mode. While any dialog is open the popup guard blocks every other
-- button on the surface. Close it — but ONLY the one we opened; a user's own
-- dialog (New Project, save prompts, ...) is never dismissed.
local function closePadPerformPopup()
	if H.currentPopup() ~= "Pad Perform" then
		return false
	end
	local popups = mpc.ui and mpc.ui.popups
	local close = H.callable(popups, "CloseCurrentPopup")
	if not close then
		H.logOnce("nopopupclose", "Pad Perform dialog cannot be closed: ui.popups.CloseCurrentPopup missing")
		return false
	end
	H.call(close)
	H.log("pad perform dialog closed")
	return true
end

local ppWatchUntil = 0 -- close the Pad Perform dialog for this many ticks after a press
local pressSurfaceButtonFwd -- forward declaration (defined below)

local function watchPadPerformPopup()
	-- The dialog opens ASYNCHRONOUSLY on the device (a beat after the press),
	-- so an immediate close races and loses. For 2 s after each of our presses,
	-- any "Pad Perform" popup is ours and gets closed; afterwards a dialog YOU
	-- opened by hand is left alone.
	if padPerformPageOurs() then
		return -- our page stays open while keys owns the surface on a melodic track
	end
	if ticks < ppWatchUntil and H.currentPopup() == "Pad Perform" then
		closePadPerformPopup()
	end
end

-- padPerform presses must NEVER run right after a screen transition (the
-- Main press inside enterPadsMode/exit): the host swallows the second press
-- while the UI settles — Pad Perform then only engaged on the first use
-- (device report). Every padPerform press is deferred two ticks (~100 ms)
-- through the timer instead.
local ppPressAt = nil -- tick deadline for a deferred padPerform toggle

local function deferPadPerformPress()
	ppPressAt = ticks + 2
end

local function runDeferredPadPerform()
	if not ppPressAt or ticks < ppPressAt then
		return
	end
	ppPressAt = nil
	if pressSurfaceButtonFwd("padPerform") then
		ppWatchUntil = ticks + 40 -- a dialog arriving AFTER we left gets closed
		H.log("pad perform toggled (deferred)")
	else
		H.logOnce("padperform", "pad perform unavailable: controlSurface.padPerform missing")
	end
	if not padPerformPageOurs() then
		closePadPerformPopup() -- only a page we own stays open
	end
end

-- Proactive fault tolerance: entering session, note, chord, user, the mixer or
-- leaving keys SWEEPS Pad Perform away, even when our bookkeeping desynced.
-- Evidence-based — the popup name or our keysPP flag — so the clean path
-- presses nothing.
local function dismissPadPerform()
	local popup = H.currentPopup() == "Pad Perform"
	if not popup and not keysPP then
		return -- a pending deferred press (if any) still handles the toggle
	end
	ppPressAt = nil -- we take over: never toggle twice
	keysPP = false
	if pressSurfaceButtonFwd then
		pressSurfaceButtonFwd("padPerform")
		H.log("pad perform off (sweep)")
		ppWatchUntil = ticks + 40 -- the press may reopen the dialog late
	end
	closePadPerformPopup()
end

local function pressSurfaceButton(name)
	local press = H.callable(mpc.controlSurface and mpc.controlSurface[name], "Press")
	if press then
		H.call(press)
		H.call(H.callable(mpc.controlSurface[name], "Release"))
		return true
	end
	return false
end
pressSurfaceButtonFwd = pressSurfaceButton

padsLayoutAvailable = function()
	local pads = dev.mappings and dev.mappings.pads
	if not pads then
		return false
	end
	local field = (padsLayout == "pads64") and "AddNoteToVirtualPad" or "AddNoteToMpcPad"
	return H.callable(pads, field) ~= nil
end

local firstLayoutForTrack -- forward declarations (defined with the pad-mode helpers)
local enterPadsMode

-- Chord (CC 95): play the current track's pads from the grid, track-type aware
-- (ported from the Mini, where three device reports shaped it):
--   drum track    -> the 4x4 quadrant plays the kit plainly. Pad Perform is NOT
--                    engaged: its chord/scale transform remaps the kit's pads
--                    and most of them go silent — a drum kit is not a chord
--                    instrument.
--   melodic track -> the quadrant + the MPC's Pad Perform mode: the 16 pads
--                    play chords/scales. The dialog the virtual press opens is
--                    closed immediately (it would block every other button).
-- Pressing Chord again leaves: Pad Perform toggled off (only if we engaged it),
-- pads mode off, MPC back on its Main screen.
local function toggleKeysPage()
	if keysPage then
		exitPadsMode() -- also leaves the Pad Perform page (MPC back on Main)
		paintAll()
		return
	end
	if not H.requireProject("keys page") then
		return
	end
	local layout, trackType = firstLayoutForTrack()
	exitPadsMode()
	closeGridStates()
	padsLayout = "drum" -- Pad Perform and plain kit play both drive the 16 pads
	enterPadsMode()
	if not padsMode then
		H.logOnce("padperform", "keys page unavailable: pads mapping missing")
		paintAll()
		return
	end
	if layout == "pads64" then
		-- melodic: engage the Pad Perform mode for chords/scales. The press is
		-- DEFERRED past enterPadsMode's Main press (immediate presses get
		-- swallowed by the screen transition). The Pad Perform page STAYS OPEN
		-- (it is the feature's UI) and is swept on the way out.
		keysPage, keysPP = true, true
		deferPadPerformPress()
		H.log("keys page: pad perform chords (" .. tostring(trackType) .. ")")
	else
		-- drum kit: play it plainly, no mode toggle, no screen change
		keysPage, keysPP = true, false
		H.log("keys page: kit play (drum track)")
	end
	paintAll()
end

exitPadsMode = function()
	-- The keys page must never outlive the pads mode it was opened with: every
	-- exit path funnels through here (Main first so the padPerform toggle lands
	-- in a pads context; the dialog the toggle reopens is closed right after).
	if keysPage then
		keysPage = false
		-- Main first; the padPerform OFF toggle is deferred past the transition
		if pressSurfaceButton("main") then
			H.log("keys: back to main")
		end
		if keysPP then
			keysPP = false
			deferPadPerformPress()
		end
	end
	dismissPadPerform() -- evidence-based immediate sweep (cancels the deferral)
	if not padsMode then
		return
	end
	padsMode = false
	local pads = dev.mappings and dev.mappings.pads
	for _, b in ipairs(boundPadNotes) do
		if b.pad then
			H.call(pads and pads.RemoveNoteToMpcPad, 0, b.note, b.pad)
		else
			H.call(pads and pads.RemoveNoteToVirtualPad, 0, b.note)
		end
		-- NOTE: no AddNoteToScript here — the script binding is never removed
		-- (see enterPadsMode); it is only ever added once at OnLoad.
	end
	boundPadNotes = {}
	padsColourCache = {}
	if padsLayout == "pads64" then
		-- virtual pads live beyond the physical 16; using them can leave the MPC's pad
		-- engine on an out-of-range bank where every track's pads are dark and silent
		-- (they still show MIDI activity). Return the pad bank to A on the way out.
		if pressSurfaceButton("bank1") then
			H.log("pad bank reset (bank 1)")
		else
			H.logOnce("bankreset", "pad bank reset unavailable: controlSurface.bank1 missing")
		end
	end
	H.log("pads mode off")
end

-- Enter pads mode: route the 16 quadrant notes to the MPC pads (hardware-routed; they no
-- longer reach HandleMIDINoteOn). Missing mappings degrade: the mode stays off.
-- Chromatic layout: the whole grid, rows a perfect 4th apart (5 semitones), driven
-- through virtual pads (AddNoteToVirtualPad) because AddNoteToMpcPad only reaches
-- bank A (16 pads, device-verified). The root note shifts by octaves with the
-- up/down arrows while the mode is open.
-- 64-pads layout (MPC 3.10.1 "8x8: 64 Pads Mode"): the grid maps 1:1 to the
-- program's 64 pads, row-major — each grid row is one pad bank (bottom row = bank A,
-- eight banks A-H of eight pads). Virtual pad N is program pad N+1, so virtual pads
-- 0-63 cover the whole program.
chromaticVirtualPad = function(padRow, col)
	return padRow * 8 + col
end

enterPadsMode = function()
	local m = dev.mappings and dev.mappings.script
	local pads = dev.mappings and dev.mappings.pads
	if not (m and pads and m.AddNoteToScript) then
		H.logOnce("padsmode", "pads mode unavailable: mappings.pads missing")
		return
	end
	if padsLayout == "pads64" and type(pads.AddNoteToVirtualPad) ~= "function" then
		H.logOnce("padschromatic", "chromatic layout unavailable: AddNoteToVirtualPad missing")
		return
	end
	if padsLayout == "drum" and type(pads.AddNoteToMpcPad) ~= "function" then
		H.logOnce("padsmode", "pads mode unavailable: AddNoteToMpcPad missing")
		return
	end
	padsMode = true
	padsColourCache = {}
	boundPadNotes = {}
	if padsLayout == "drum" then
		-- The MPC only lights its pad grid on pad-capable screens (Main, program
		-- editors); on other pages (Keyboard settings, Q-Link, step seq, browser) the
		-- pads report black and the mirror would go dark. Return the MPC to its Main
		-- screen so the grid lights up (guarded; logged once if unavailable).
		if pressSurfaceButton("main") then
			H.log("pad view: main screen")
		else
			H.logOnce("padview", "pad view reset unavailable: controlSurface.main missing")
		end
	end
	-- The notes STAY script-bound: AddNoteToScript consumes them from the host's
	-- MIDI-input feed (device-verified: script-bound notes never reach track
	-- inputs), while the pad binding fires the program pad in parallel. Removing
	-- the script binding let the raw channel-0 notes through to any track
	-- listening on our port — the "playing track 2 also triggers track 1" report.
	-- The stock MPK hides this with pads on channel 9; the Launchpad cannot
	-- change its programmer-mode channel, so we consume instead.
	if padsLayout == "pads64" then
		for padRow = 0, 7 do
			for col = 0, 7 do
				local note = 10 * (padRow + 1) + col + 1
				H.call(pads.AddNoteToVirtualPad, 0, note, chromaticVirtualPad(padRow, col))
				boundPadNotes[#boundPadNotes + 1] = { note = note }
			end
		end
	else
		for i = 0, 15 do
			local note = padsModeNote(i)
			H.call(pads.AddNoteToMpcPad, 0, note, i)
			boundPadNotes[#boundPadNotes + 1] = { note = note, pad = i }
		end
	end
	H.log("pads mode on (" .. padsLayout .. ")")
	if padsLayout == "pads64" then
		-- the 8x8 view itself is a screen-side setting with no script API; without it
		-- the MPC stays in the 16-pad view and the upper pad colours/banks do not
		-- populate (there is no 8x8 mode for drum kits at all)
		H.logOnce("tip8x8", "tip: switch the MPC's pad view to 8x8 64 Pads for full colours")
	end
end

-- Pick the first layout from the current track's Type: pad-based programs (Drum)
-- get the drum layout, melodic programs (Plugin/Keygroup/MIDI) get chromatic.
firstLayoutForTrack = function()
	local t = mpc.tracks and mpc.tracks.currentTrack
	local trackType = H.propValue(t, "Type")
	if type(trackType) == "string" and trackType ~= "" and trackType ~= "Drum" then
		return "pads64", trackType
	end
	return "drum", trackType
end

trackIsMelodicFn = function()
	return firstLayoutForTrack() == "pads64"
end

-- Tapping Note toggles the pads mode with the layout fixed by the track type:
-- drum tracks get the drum layout, melodic tracks get chromatic. The unsuitable
-- layout is never offered (chromatic on a drum program is silent, and the drum
-- grid is meaningless on a synth track).
local function togglePadsMode()
	if not padsMode and not H.requireProject("pads mode") then
		return
	end
	if not padsMode then
		local layout, trackType = firstLayoutForTrack()
		padsLayout = layout
		H.log("track type " .. tostring(trackType or "?") .. " -> " .. layout)
		exitPadsMode() -- clears a stray keysPage (degraded padPerform entry)
		closeGridStates()
		enterPadsMode()
		if padsMode then
			paintPadsGrid(true) -- immediate mirror, independent of the tick parity
		end
		return
	end
	exitPadsMode()
	paintAll()
end

local function setMode(m)
	exitPadsMode() -- another mode (CC 93 session, CC 97, ...) always returns to the clip grid
	mode = m
	H.log("mode -> " .. m)
	paintAll()
end

local function doClip(col, row)
	if not aperture then
		return
	end
	if shift then
		H.call(aperture.SelectClip, col, row)
		H.log(string.format("SelectClip(%d,%d)", col, row))
	else
		H.call(aperture.SelectClip, col, row)
		H.call(aperture.TriggerClip, col, row)
		H.log(string.format("TriggerClip(%d,%d)", col, row))
	end
end

local function doScene(row)
	if not aperture then
		return
	end
	H.call(aperture.TriggerRow, row)
	H.log("TriggerRow(" .. row .. ")")
end

-- Shift + right-column button: the label functions (patterns/steps/...).
local function handleRightLabel(row)
	if row == 0 then
		setMode("clip")
	elseif row == 1 then
		setMode("step")
	elseif row == 2 then
		setMode("track")
	else
		H.log("page " .. row .. ": TODO")
	end
end

-- Apply a held function (mute/solo/recArm/...) to a specific track index.
local function applyFunction(fn, idx)
	local t = mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[idx]
	if not t then
		H.logOnce("track", "no track " .. tostring(idx))
		return
	end
	if fn == "recArm" then
		local v = H.propValue(t, "RecArm")
		H.call(t.SetRecArm, not v)
		H.log("SetRecArm(" .. tostring(not v) .. ") track " .. idx)
	elseif fn == "mute" then
		local v = H.propValue(t, "Mute")
		H.call(t.SetMute, not v)
		H.log("SetMute(" .. tostring(not v) .. ") track " .. idx)
	elseif fn == "solo" then
		local v = H.propValue(t, "Solo")
		H.call(t.SetSolo, not v)
		H.log("SetSolo(" .. tostring(not v) .. ") track " .. idx)
	elseif fn == "stopClip" then
		H.call(aperture and aperture.StopClipsOnTrack, idx)
		H.log("StopClipsOnTrack(" .. idx .. ")")
	else
		H.log(fn .. ": unsupported track function " .. idx)
	end
end

-- Select a track (bottom-row CC 101-108 without a held function). Two coordinates:
-- the aperture takes a window-LOCAL column (same convention as SelectClip), while
-- mpc.tracks.SetCurrentTrack takes the GLOBAL index and is what currentTrack — and
-- everything reading it (note mode's track type, track nav, plugin presets) —
-- follows. Call both so the column highlight and the real selection agree.
local function selectTrack(col, gc)
	local setCurrent = H.callable(mpc.tracks, "SetCurrentTrack")
	if setCurrent then
		H.call(setCurrent, gc)
		H.log("SetCurrentTrack(" .. gc .. ")")
	end
	if aperture then
		H.call(aperture.SelectTrack, col)
	end
end

-- Write a track property (Volume/Pan/Send1-4) through its .value, guarded.
local function setTrackValue(idx, name, v)
	local t = H.trackAt(idx)
	if not t then
		H.logOnce("track", "no track " .. tostring(idx))
		return
	end
	local p = t[name]
	if p == nil then
		H.logOnce("prop" .. name, name .. " MISSING on track " .. tostring(idx))
		return
	end
	local value = H.clamp01(v)
	local ok = pcall(function()
		p.value = value
	end)
	if not ok then
		H.logOnce("set" .. name, "set " .. name .. " failed on track " .. tostring(idx))
		return
	end
	H.log(string.format("%s track %d = %.3f", name, idx, value))
end

-- Write a track's VolumeDB directly (dB), falling back to the linear Volume
-- property if VolumeDB is read-only on this firmware.
local function setTrackVolumeDB(idx, db)
	local t = H.trackAt(idx)
	if not t then
		H.logOnce("track", "no track " .. tostring(idx))
		return
	end
	local p = t.VolumeDB
	if p ~= nil then
		local ok = pcall(function()
			p.value = db
		end)
		if ok then
			H.log(string.format("VolumeDB track %d = %s", idx, tostring(db)))
			return
		end
	end
	-- fallback: invert the MPC fader curve (dB = 40*log10(gain) + 6)
	setTrackValue(idx, "Volume", H.dbToGain(db))
end

local function changeTempo(delta)
	if not H.requireProject("tempo") then
		return
	end
	local sq = mpc.sequencer
	local bpm = H.call(sq and sq.GetBPM) or 120
	bpm = math.max(20, math.min(300, math.floor(bpm + delta + 0.5)))
	H.call(sq and sq.SetBPM, bpm)
	H.log("tempo: " .. bpm .. " BPM")
	paintGrid()
	paintLeft()
	flushLEDs()
end

local function changeSwing(delta)
	if not H.requireProject("swing") then
		return
	end
	local q = mpc.sequencer and mpc.sequencer.quantiser
	-- MPC swing: 50% = straight, > 50 delays every other step; 75% is the max
	local swing = H.call(q and q.GetSwing) or 50
	swing = math.max(50, math.min(75, math.floor(swing + delta + 0.5)))
	H.call(q and q.SetSwing, swing)
	H.log("swing: " .. swing .. "%")
	paintGrid()
	paintLeft()
	flushLEDs()
end

local function doQuantize()
	if not H.requireProject("quantize") then
		return
	end
	local press = H.callable(mpc.controlSurface and mpc.controlSurface.quantizeApply, "Press")
	if press then
		H.call(press)
		H.call(H.callable(mpc.controlSurface.quantizeApply, "Release"))
		H.log("quantize applied")
	else
		H.logOnce("quantize", "quantize unavailable: controlSurface.quantizeApply missing")
	end
end

local function nudgeAdjust(delta)
	if not adjustMode then
		return
	end
	local gc = H.globalPos(adjustCol, 0)
	local name = H.adjustPropName()
	if not name then
		return
	end
	if adjustMode == "volume" then
		local db = H.gainToDb(H.propValue(H.trackAt(gc), "Volume"))
		local row = H.dbToRow(db)
		if delta > 0 then
			row = math.max(0, row - 1)
		else
			row = math.min(GRID_ROWS - 1, row + 1)
		end
		setTrackVolumeDB(gc, VOLUME_DB[row])
		paintAll()
		return
	end
	local cur = H.propValue(H.trackAt(gc), name)
	if type(cur) ~= "number" then
		cur = 0
	end
	setTrackValue(gc, name, cur + delta)
	paintAll()
end

local function enterAdjust(newMode)
	if not H.requireProject(newMode .. " menu") then
		return
	end
	exitPadsMode() -- the fader menus need the whole grid
	tempoMode = false
	swingMode = false
	qlinkMode = false
	adjustMode = newMode
	adjustCol = 0
	lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
	if newMode == "sends" then
		adjustSend = 1
	end
	H.log("menu " .. newMode)
	paintAll()
end

local function exitAdjust()
	if adjustMode then
		adjustMode = nil
		lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
		H.log("menu off")
		paintAll()
	end
end

local function handleAdjustPad(col, row)
	if not adjustMode then
		return
	end
	local gc = H.globalPos(col, 0)
	if adjustMode == "volume" then
		setTrackVolumeDB(gc, VOLUME_DB[row])
		lastPadCol, lastPadRow, lastPadTick = col, row, ticks
		adjustCol = col
		paintAll()
		return
	end
	local value = (GRID_ROWS - row) / GRID_ROWS
	-- double-tapping the bottom pad reaches the true minimum (0.0)
	if col == lastPadCol and row == lastPadRow and ticks - lastPadTick <= 2 then
		if row == GRID_ROWS - 1 then
			value = 0
		end
	end
	lastPadCol, lastPadRow, lastPadTick = col, row, ticks
	adjustCol = col
	local name = H.adjustPropName()
	if name then
		setTrackValue(gc, name, value)
		paintAll()
	end
end

-- Shift + a function button: the shift function (undo/redo/click/tap/tempo/swing).
-- Shift is checked before the held-function state, so these run even while another
-- function button is held; the held function is left untouched.
-- Tap tempo: use dev.timer.Now() (ms, high resolution) and average the last
-- few tap intervals. Falls back to the 50 ms timer tick if Now() is missing.
local function doTapTempo()
	local now = H.call(dev.timer and dev.timer.Now)
	local useMs = type(now) == "number"
	if not useMs then
		now = ticks
	end
	local function diff(a, b)
		local d = a - b
		if useMs and d < 0 then
			d = d + 4294967296 -- 32-bit wrap
		end
		return d
	end
	-- a gap longer than 2 s starts a new tap sequence
	if #tapTicks > 0 and diff(now, tapTicks[#tapTicks]) > (useMs and 2000 or 40) then
		tapTicks = {}
	end
	tapTicks[#tapTicks + 1] = now
	if #tapTicks > 5 then
		table.remove(tapTicks, 1)
	end
	if #tapTicks < 2 then
		H.log("tap tempo: first tap")
		return
	end
	local total = 0
	for i = 2, #tapTicks do
		total = total + diff(tapTicks[i], tapTicks[i - 1])
	end
	local avg = total / (#tapTicks - 1)
	local bpm = (useMs and 60000 or 1200) / avg
	bpm = math.max(20, math.min(300, bpm))
	bpm = math.floor(bpm + 0.5) -- MPC BPM is an integer
	local setBPM = H.callable(mpc.sequencer, "SetBPM")
	if setBPM then
		H.call(setBPM, bpm)
		H.log(string.format("tap tempo: %d BPM (%.1f ms)", bpm, avg))
	else
		H.logOnce("tapbpm", "tap tempo unavailable: sequencer.SetBPM missing")
	end
end

-- While Shift is held, CC 6 is handed to the MPC's own Tap Tempo control
-- (RemoveCCToScript + AddCCToControl, the stock MPK mini IV pattern); on Shift
-- release it is routed back to the script for the sends menu. Without the
-- controlSurface mapping the doTapTempo() averager stays the fallback.
local function updateTapTempoRouting(held)
	local m = dev.mappings and dev.mappings.script
	local cs = dev.mappings and dev.mappings.controlSurface
	if held and cs and type(cs.AddCCToControl) == "function" and type(cs.RemoveCCToControl) == "function" then
		local ok = pcall(function()
			m.RemoveCCToScript(0, TRACK.sends)
			cs.AddCCToControl(0, TRACK.sends, "Tap Tempo")
		end)
		if ok then
			nativeTap = true
			H.logOnce("tapnative", "tap tempo: native")
			return
		end
	end
	if nativeTap then
		H.call(cs and cs.RemoveCCToControl, 0, TRACK.sends)
		H.call(m and m.AddCCToScript, 0, TRACK.sends)
		nativeTap = false
	elseif held then
		-- a failed bind may have left CC 6 unregistered: keep it on the script
		H.call(m and m.AddCCToScript, 0, TRACK.sends)
	end
	if held then
		H.logOnce("tapmanual", "tap tempo: manual fallback")
	end
end

local function doShiftFunction(fn)
	if fn == "recArm" then
		local cm = mpc.commandManager
		if cm and type(cm.Undo) == "function" then
			H.call(cm.Undo)
			H.log("Undo")
		else
			H.logOnce("undo", "Undo unavailable: commandManager.Undo missing")
		end
	elseif fn == "mute" then
		local cm = mpc.commandManager
		if cm and type(cm.Redo) == "function" then
			H.call(cm.Redo)
			H.log("Redo")
		else
			H.logOnce("redo", "Redo unavailable: commandManager.Redo missing")
		end
	elseif fn == "solo" then
		local sq = mpc.sequencer
		local me = H.propValue(sq, "MetronomeEnabled")
		if sq and type(sq.SetMetronomeEnabled) == "function" then
			H.call(sq.SetMetronomeEnabled, not me)
			H.log("Metronome " .. tostring(not me))
		else
			H.logOnce("metronome", "metronome unavailable: sequencer.SetMetronomeEnabled missing")
		end
	elseif fn == "sends" then
		-- CC 6 is routed to the MPC's native Tap Tempo while Shift is held;
		-- this manual averager only runs when that binding is unavailable
		if not nativeTap then
			doTapTempo()
		end
	elseif fn == "device" then
		if not tempoMode and not H.requireProject("tempo page") then
			return
		end
		exitPadsMode() -- the tempo page needs the whole grid
		adjustMode = nil
		swingMode = false
		qlinkMode = false
		tempoMode = not tempoMode
		tempoHold = nil
		if tempoMode then
			H.log("tempo page: " .. tostring(H.call(mpc.sequencer and mpc.sequencer.GetBPM)) .. " BPM")
		else
			H.log("tempo page off")
		end
		paintAll()
		flushLEDs()
	elseif fn == "stopClip" then
		if not swingMode and not H.requireProject("swing page") then
			return
		end
		exitPadsMode() -- the swing page needs the whole grid
		adjustMode = nil
		tempoMode = false
		qlinkMode = false
		tempoHold = nil
		swingMode = not swingMode
		swingHold = nil
		if swingMode then
			H.log(
				"swing page: "
					.. tostring(H.call(mpc.sequencer and mpc.sequencer.quantiser and mpc.sequencer.quantiser.GetSwing))
					.. "%"
			)
		else
			H.log("swing page off")
		end
		paintAll()
		flushLEDs()
	else
		H.log(fn .. " shift: TODO")
	end
end

local function doTransport(fn)
	if not H.requireProject("transport") then
		return
	end
	local sq = mpc.sequencer
	if fn == "play" then
		local playing = sq and H.call(sq.IsPlaying) or H.propValue(sq, "Playing")
		if playing then
			H.call(sq and sq.Stop)
			H.log("Stop")
		else
			H.call(sq and sq.Play)
			H.log("Play")
		end
	elseif fn == "record" then
		H.call(sq and sq.Record)
		H.log("Record")
	end
end

-- Record (CC 10): arm/disarm, matching the MPC's own REC button — the first
-- press arms recording (recording starts when the transport runs or a clip is
-- triggered), the next press disarms. Delegates to controlSurface.record so the
-- MPC's record state machine does the work; falls back to Record/RecordOff.
local function recordArmed()
	return H.truthy(H.propValue(mpc.sequencer, "RecordState"))
end

local function doRecordToggle()
	if not H.requireProject("record") then
		return
	end
	local armed = recordArmed()
	if pressSurfaceButton("record") then
		H.log("record: " .. (armed and "disarmed" or "armed"))
		return
	end
	local name = armed and "RecordOff" or "Record"
	local f = H.callable(mpc.sequencer, name)
	if not f then
		H.logOnce("record", "record unavailable: sequencer." .. name .. " missing")
		return
	end
	H.call(f)
	H.log("record: " .. (armed and "disarmed" or "armed"))
end

-- Shift + play (CC 20): loop on/off (Loop is a userdata property with .value).
local function doLoopToggle()
	if not H.requireProject("loop") then
		return
	end
	local sq = mpc.sequencer
	local loop = H.propValue(sq, "Loop")
	if not sq or sq.Loop == nil then
		H.logOnce("loop", "loop unavailable: sequencer.Loop missing")
		return
	end
	local ok = pcall(function()
		sq.Loop.value = not loop
	end)
	if not ok then
		H.logOnce("loopwrite", "loop unavailable: sequencer.Loop.value not writable")
		return
	end
	H.log("loop: " .. (loop and "off" or "on"))
end

-- Shift + record (CC 10): overdub — the MPC's second record control (replace vs
-- layer while recording over existing material).
local function doOverdub()
	local f = H.callable(mpc.sequencer, "Overdub")
	if not f then
		H.logOnce("overdub", "overdub unavailable: sequencer.Overdub missing")
		return
	end
	H.call(f)
	H.log("overdub")
end

-- Shift + fixed length (CC 30): cycle the global automation filter type.
local function doAutomationFilterCycle()
	if not H.requireProject("automation filter") then
		return
	end
	local f = H.callable(mpc.project, "AdvanceGlobalAutomationFilterType")
	if not f then
		H.logOnce("autofilter", "automation filter unavailable: project.AdvanceGlobalAutomationFilterType missing")
		return
	end
	H.call(f)
	H.log("automation filter: cycled")
end

-- Shift + < / > (CC 91/92): MPC's current track previous/next.
local function doTrackNav(forward)
	local field = forward and "Next" or "Previous"
	if H.trackAction(field, "tracknav", "track nav") then
		H.log("track: " .. (forward and "next" or "prev"))
	end
end

-- Shift + note/chord (CC 94/95): previous/next plugin preset on the current
-- track (present on track objects in 3.10.1).
local function doPluginPreset(forward)
	local field = forward and "NextPluginPreset" or "PrevPluginPreset"
	if H.trackAction(field, "preset", "preset") then
		H.log("preset: " .. (forward and "next" or "prev"))
	end
end

local function moveWindow(dir, n)
	if not aperture then
		return
	end
	local fn = ({ left = "MoveLeft", right = "MoveRight", up = "MoveUp", down = "MoveDown" })[dir]
	if fn then
		H.call(aperture[fn], n)
		H.log(fn .. "(" .. n .. ")")
		padCache = {}
		listenGrid() -- the slot properties follow the window: rebind, then repaint
		paintAll()
	end
end

local function probe(note, cc, value)
	H.log(string.format("PROBE note=%s cc=%s value=%s", tostring(note), tostring(cc), tostring(value)))
	if note then
		ledCol(note, C.white)
	end
	if cc then
		ledCol(cc, C.white)
	end
	flushLEDs()
end

-----------------------------------------------------------------------------------------------
-- Input handlers
-----------------------------------------------------------------------------------------------

local function noteIndex(note)
	if note >= GRID_NOTE0 and note <= GRID_NOTE0 + 77 then
		local i = note - GRID_NOTE0
		local padRow = math.floor(i / 10)
		local col = i % 10
		if col < 8 and padRow < 8 then
			return col, 7 - padRow -- col, MPC row (0 = top)
		end
	end
	return nil
end

function LaunchpadProMK3.HandleMIDINoteOn(channel, note, velocity)
	if channel ~= 0 then
		return
	end
	if probeMode then
		probe(note, nil, velocity)
		return
	end
	local col, row = noteIndex(note)
	if col then
		if padsMode then
			-- a pad mode owns the grid. The pad binding fired the MPC pad; the
			-- script binding consumed the note so it cannot reach track inputs.
			-- This line firing is the on-device proof of that consumption.
			H.logOnce("padnote-consumed", "pad note consumed by script binding (not forwarded)")
			return
		end
		if velocity > 0 then
			if heldFunction == "stopClip" then
				local gc = H.globalPos(col, 0)
				H.call(aperture and aperture.StopClipsOnTrack, gc)
				H.log("StopClipsOnTrack(" .. gc .. ")")
				paintAll()
			elseif clipOp == "clear" then
				local gc, gr = H.globalPos(col, row)
				H.call(mpc.clipMatrix and mpc.clipMatrix.DeleteClip, gc, gr)
				H.log(string.format("DeleteClip(%d,%d)", gc, gr))
				paintAll()
			elseif clipOp == "duplicate" then
				local gc, gr = H.globalPos(col, row)
				if clipOrigin == nil then
					clipOrigin = { gc, gr }
					H.log(string.format("duplicate origin (%d,%d)", gc, gr))
				else
					H.call(mpc.clipMatrix and mpc.clipMatrix.CopyClip, clipOrigin[1], clipOrigin[2], gc, gr)
					H.log(string.format("CopyClip(%d,%d -> %d,%d)", clipOrigin[1], clipOrigin[2], gc, gr))
					-- keep the origin so one source can be copied to many targets
					-- while the duplicate button is held
					paintAll()
				end
			elseif adjustMode then
				handleAdjustPad(col, row)
			elseif qlinkMode then
				handleQlinkPad(col, row)
			elseif not tempoMode and not swingMode then
				doClip(col, row)
			end
		end
		return
	end
end

function LaunchpadProMK3.HandleMIDINoteOff(_channel, _note, _velocity)
	-- LPP3 sends Note On with velocity 0 for Note Off; nothing to do here
end

-- ==== CC dispatch ==========================================================
-- Two action maps: PRESS runs on a plain press, SHIFT_PRESS when Shift is held.
-- A control with no SHIFT_PRESS entry keeps its plain action while Shift is
-- held. Context-sensitive controls (up/down pages, function buttons, scenes,
-- track row) branch inside small named handlers.

local function ccShiftDown()
	shift = false
	updateTapTempoRouting(false)
	paintTop()
	flushLEDs()
end

local function ccRelease(cc)
	if cc == TOP.shift then
		ccShiftDown()
	end
	-- clip ops are hold-to-arm: releasing clear/duplicate disarms them
	if cc == LEFT.clear or cc == LEFT.duplicate then
		clipOp = nil
		clipOrigin = nil
		paintAll()
		flushLEDs()
	end
	-- releasing the tempo up/down button stops the auto-repeat
	if cc == LEFT.up or cc == LEFT.down then
		tempoHold = nil
		swingHold = nil
	end
	-- only the button that is actually held clears the hold; releasing a
	-- shift-function button must not drop a function held from before Shift
	local held = TRACK_FN[cc]
	if held and held == heldFunction then
		heldFunction = nil
		paintTrack()
		flushLEDs()
	end
end

-- Up/down arrows: the active page decides what they nudge.
local function ccUpDown(delta)
	if tempoMode then
		tempoHold = (delta > 0) and LEFT.up or LEFT.down
		tempoHoldTicks = 0
		changeTempo(delta)
	elseif swingMode then
		swingHold = (delta > 0) and LEFT.up or LEFT.down
		swingHoldTicks = 0
		changeSwing(delta)
	elseif adjustMode then
		nudgeAdjust(delta / 8)
	elseif qlinkMode then
		if shift then
			nudgeQlink(delta)
		elseif qlinkPage == 0 and qlinkPageHasContent(1) then
			qlinkPage = 1
			H.log("qlink page 2")
			paintAll()
		elseif qlinkPage == 1 then
			qlinkPage = 0
			H.log("qlink page 1")
			paintAll()
		end
	else
		moveWindow((delta > 0) and "up" or "down", shift and 8 or 1)
	end
end

local function armClipOp(kind)
	clipOp = kind
	clipOrigin = nil
	H.log(
		"clip op "
			.. kind
			.. " armed: "
			.. (kind == "clear" and "press the clip pad" or "press origin pad, then target pad")
	)
	paintAll()
end

local function ccFunctionButton(fn)
	if shift then
		doShiftFunction(fn)
		paintTrack()
		flushLEDs()
	elseif fn == "sends" then
		if adjustMode == "sends" then
			adjustSend = (adjustSend % 4) + 1
			H.log("send " .. adjustSend)
			paintAll()
		else
			enterAdjust("sends")
		end
	elseif fn == "volume" or fn == "pan" then
		if adjustMode == fn then
			exitAdjust()
		else
			enterAdjust(fn)
		end
	elseif fn == "device" then
		if qlinkMode then
			if qlinkPage == 0 and qlinkPageHasContent(1) then
				qlinkPage = 1
				H.log("qlink page 2")
				paintAll()
			else
				exitQlink()
			end
		else
			enterQlink()
		end
	else
		heldFunction = fn
		adjustMode = nil
		H.log("hold " .. fn)
		paintAll()
	end
end

local function toggleFollow()
	followMode = not followMode
	H.log("follow: " .. (followMode and "on" or "off"))
	if followMode then
		followCurrentTrack(H.propValue(mpc.tracks and mpc.tracks.currentTrack, "Index"))
	else
		paintTop()
		flushLEDs()
	end
end

local function logStatus()
	H.log("status: mode=" .. mode .. " shift=" .. tostring(shift))
end

local function toggleProbe()
	probeMode = not probeMode
	H.log("probe mode " .. tostring(probeMode))
	paintRight()
	flushLEDs()
end

local function stepSeqNext()
	if pressSurfaceButton("stepSeqNext") then
		H.log("step seq: next")
	else
		H.logOnce("stepseqnext", "step seq next unavailable: controlSurface.stepSeqNext missing")
	end
end

local function openStepSeq()
	if not H.requireProject("step seq") then
		return
	end
	if pressSurfaceButton("stepSeq") then
		setMode("step")
		H.log("step seq view")
	else
		H.logOnce("stepseq", "step seq unavailable: controlSurface.stepSeq missing")
	end
end

local function doSave()
	if not H.requireProject("save") then
		return
	end
	if pressSurfaceButton("save") then
		H.log("save")
	else
		H.logOnce("save", "save unavailable: controlSurface.save missing")
	end
end

local function shiftPress()
	shift = true
	updateTapTempoRouting(true)
	paintTop()
	flushLEDs()
end

-- Plain press actions (Shift held: SHIFT_PRESS wins when it has an entry).
local PRESS = {
	[TOP.shift] = shiftPress,
	[TOP.session] = function()
		dismissPadPerform() -- a stuck Pad Perform must never block the escape
		setMode("clip")
	end,
	[TOP.sequencer] = function()
		if probeMode then
			dumpSequenceProbe()
			return
		end
		openStepSeq()
	end,
	[TOP.note] = function()
		dismissPadPerform() -- a chord-mangled surface must not leak into pads mode
		togglePadsMode()
		paintAll()
	end,
	[TOP.chord] = toggleKeysPage,
	[TOP.custom] = function()
		H.logOnce("custom", "custom button: unmapped")
	end,
	[TOP.left] = function()
		moveWindow("left", 1)
	end,
	[TOP.right] = function()
		moveWindow("right", 1)
	end,
	[TOP.save] = function()
		H.log("projects: TODO")
	end,
	[RIGHT.logo] = logStatus,
	[LEFT.up] = function()
		ccUpDown(1)
	end,
	[LEFT.down] = function()
		ccUpDown(-1)
	end,
	[LEFT.play] = function()
		doTransport("play")
	end,
	[LEFT.record] = doRecordToggle,
	[LEFT.quantize] = doQuantize,
	[LEFT.duplicate] = function()
		armClipOp("duplicate")
	end,
	[LEFT.clear] = function()
		armClipOp("clear")
	end,
}

-- Shift-held actions.
local SHIFT_PRESS = {
	[TOP.session] = toggleFollow,
	[TOP.sequencer] = stepSeqNext,
	[TOP.note] = function()
		doPluginPreset(false)
	end,
	[TOP.chord] = function()
		doPluginPreset(true)
	end,
	[TOP.left] = function()
		doTrackNav(false)
	end,
	[TOP.right] = function()
		doTrackNav(true)
	end,
	[TOP.save] = doSave,
	[RIGHT.logo] = toggleProbe,
	[LEFT.play] = doLoopToggle,
	[LEFT.record] = doOverdub,
	[LEFT.fixedLength] = doAutomationFilterCycle,
}

-- Scene buttons: launch the row, or its Shift label function.
for row = 0, 7 do
	local sceneRow = row
	PRESS[SCENE[sceneRow + 1]] = function()
		doScene(sceneRow)
	end
	SHIFT_PRESS[SCENE[sceneRow + 1]] = function()
		handleRightLabel(sceneRow)
	end
end

-- Function buttons CC 1-8 and the track row CC 101-108.
for cc, fnName in pairs(TRACK_FN) do
	local name = fnName
	PRESS[cc] = function()
		ccFunctionButton(name)
	end
end

for cc = 101, 108 do
	local col = cc - 101
	PRESS[cc] = function()
		local gc = H.globalPos(col, 0)
		if heldFunction then
			applyFunction(heldFunction, gc)
		else
			selectTrack(col, gc)
		end
	end
end

-- Reference data for the generated manual (docs/MANUAL.md).
LaunchpadProMK3.ACTIONS = ACTIONS
LaunchpadProMK3.PALETTE = C

-- State-machine snapshot for the tests and for on-device diagnosis.
LaunchpadProMK3.STATE = function()
	return {
		padsMode = padsMode,
		padsLayout = padsLayout,
		keysPage = keysPage,
		keysPP = keysPP,
		adjustMode = adjustMode,
		tempoMode = tempoMode,
		swingMode = swingMode,
		qlinkMode = qlinkMode,
		qlinkPage = qlinkPage,
		boundPadNotes = #boundPadNotes,
	}
end

function LaunchpadProMK3.HandleMIDICC(channel, cc, value)
	if channel ~= 0 then
		return
	end
	if probeMode then
		probe(nil, cc, value)
		return
	end
	if value == 0 then
		ccRelease(cc)
		return
	end
	local action = (shift and SHIFT_PRESS[cc]) or PRESS[cc]
	if action then
		action()
		return
	end
	H.log("unmapped CC " .. cc .. " value " .. value)
end

function LaunchpadProMK3.HandleMIDISysex(bytes)
	if type(bytes) ~= "string" then
		return
	end
	-- strip F0/F7 if the host passes them
	if bytes:byte(1) == 0xF0 then
		bytes = bytes:sub(2)
	end
	if bytes:byte(-1) == 0xF7 then
		bytes = bytes:sub(1, -2)
	end
	-- device identity reply: 7E <dev> 06 02 <00 20 29 Novation> <family> <model> <version...>
	if
		bytes:byte(1) == 0x7E
		and bytes:byte(3) == 0x06
		and bytes:byte(4) == 0x02
		and bytes:sub(5, 7) == string.char(0x00, 0x20, 0x29)
	then
		local ver = {}
		for i = 12, math.min(14, #bytes) do
			ver[#ver + 1] = tostring(bytes:byte(i))
		end
		H.logOnce("firmware", "firmware: " .. (#ver > 0 and table.concat(ver, ".") or "unknown"))
	end
	-- select layout: 00 20 29 02 0E 00 <layout> <page> 00
	if bytes:sub(1, 6) == string.char(0x00, 0x20, 0x29, 0x02, 0x0E, 0x00) and #bytes >= 9 then
		local layout = bytes:byte(7)
		local page = bytes:byte(8)
		if priorLayout == nil and layout ~= 0x11 then
			priorLayout, priorPage = layout, page
			H.log(string.format("prior layout 0x%02x page %d", layout, page))
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Timer
-----------------------------------------------------------------------------------------------

function LaunchpadProMK3.HandleTimer()
	ticks = ticks + 1
	-- the page may stay open only while keys owns AND the track is melodic:
	-- a track switch to drums drops the chords (kit play remains)
	if keysPage and keysPP and not trackIsMelodicFn() then
		H.log("keys page: track is not melodic anymore - chords off, kit play")
		dismissPadPerform()
	end
	runDeferredPadPerform()
	watchPadPerformPopup()
	-- timer runs at 50 ms; blink at 2 Hz (every 5 ticks) and full repaint every 2 s
	if ticks % 5 == 0 then
		blinkOn = not blinkOn
	end
	-- tempo page: holding up/down repeats, accelerating after a short delay
	if tempoMode and tempoHold then
		tempoHoldTicks = tempoHoldTicks + 1
		local interval = tempoHoldTicks < 10 and 6 or (tempoHoldTicks < 20 and 3 or 1)
		if tempoHoldTicks % interval == 0 then
			changeTempo(tempoHold == LEFT.up and 1 or -1)
		end
	end
	-- swing page: holding up/down repeats, accelerating after a short delay
	if swingMode and swingHold then
		swingHoldTicks = swingHoldTicks + 1
		local interval = swingHoldTicks < 10 and 6 or (swingHoldTicks < 20 and 3 or 1)
		if swingHoldTicks % interval == 0 then
			changeSwing(swingHold == LEFT.up and 1 or -1)
		end
	end
	if layoutQuerySent and not programmerEntered and ticks >= 1 then
		sendLayout(0x11, 0)
		programmerEntered = true
		H.log("programmer mode")
	end
	if aperture and not clipProps then
		-- window position fallback, whichever getter this firmware has
		for _, n in ipairs({ "GetOriginX", "GetColumn", "GetX" }) do
			local v = H.call(aperture[n])
			if type(v) == "number" then
				originCol = v
				break
			end
		end
		for _, n in ipairs({ "GetOriginY", "GetRow", "GetY" }) do
			local v = H.call(aperture[n])
			if type(v) == "number" then
				originRow = v
				break
			end
		end
	end
	if ticks % 40 == 0 then
		padCache = {}
		if padsMode then
			padsColourCache = {} -- force a full quadrant resend every 2 s
		end
	end -- resend everything every 2 s
	paintAll()
end

-----------------------------------------------------------------------------------------------
-- Load / unload
-----------------------------------------------------------------------------------------------

function LaunchpadProMK3.OnLoad()
	adjustMode = nil
	adjustSend = 1
	tempoMode = false
	swingMode = false
	qlinkMode = false
	qlinkPage = 0
	qlinkCol = 0
	followMode = false
	padsMode = false
	padsLayout = "drum"
	keysPage = false
	keysPP = false
	padsColourCache = {}
	clipOp = nil
	clipOrigin = nil
	aperture = dev.clipMatrixAperture or (mpc.clipMatrix and mpc.clipMatrix.clipMatrixAperture)
	clipProps = (aperture and aperture.clipProperties)
		or dev.clipProperties
		or (mpc.clipMatrix and mpc.clipMatrix.clipProperties)
	if aperture then
		H.call(aperture.SetColumns, 8)
		H.call(aperture.SetRows, 8)
		H.call(aperture.SetLabel, "LPP3")
		H.call(aperture.SetFollowsTUI, false)
		H.call(aperture.Show)
		H.log("aperture ok")
	else
		H.logOnce("noaperture", "aperture MISSING: clip surface disabled")
	end
	if clipProps then
		H.log("clipProperties ok")
	else
		H.logOnce("noclips", "clipProperties MISSING")
	end

	-- register the LPP3 controls with the script
	local m = dev.mappings and dev.mappings.script
	if m then
		for padRow = 0, 7 do
			for col = 0, 7 do
				H.call(m.AddNoteToScript, 0, 10 * (padRow + 1) + col + 1)
			end
		end
		local ccs = {
			1,
			2,
			3,
			4,
			5,
			6,
			7,
			8,
			10,
			19,
			20,
			29,
			30,
			39,
			40,
			49,
			50,
			59,
			60,
			69,
			70,
			79,
			80,
			89,
			90,
			91,
			92,
			93,
			94,
			95,
			96,
			97,
			98,
			99,
			101,
			102,
			103,
			104,
			105,
			106,
			107,
			108,
		}
		for _, cc in ipairs(ccs) do
			H.call(m.AddCCToScript, 0, cc)
		end
		H.call(m.SetHandleSysex, true)
	end

	queryLayout()
	layoutQuerySent = true

	-- device inquiry (universal sysex F0 7E 7F 06 01 F7): ask the LPP3 for its
	-- firmware version; log-only, the reply is parsed in HandleMIDISysex
	local okProbe = pcall(function()
		dev.midiOut.SendMIDISysex(string.char(0x7E, 0x7F, 0x06, 0x01), port)
	end)
	if not okProbe then
		H.logOnce("fwprobe", "firmware probe failed")
	end

	listenAll()
	paintAll()
	H.call(dev.timer and dev.timer.Start, 50)
	H.log("loaded")
	H.log(
		"engine mode: "
			.. tostring(
				H.propValue(mpc.engineMode, "CurrentMode") or H.call(H.callable(mpc.engineMode, "GetCurrentMode"))
			)
			.. " popup: "
			.. H.currentPopup()
	)
end
function LaunchpadProMK3.OnUnload()
	H.call(dev.timer and dev.timer.Stop)
	removeListeners()
	exitPadsMode() -- hand the pad-mode notes back to the script before unmapping
	padsMode = false
	padsColourCache = {}
	adjustMode = nil
	adjustSend = 1
	tempoMode = false
	swingMode = false
	qlinkMode = false
	qlinkPage = 0
	qlinkCol = 0
	keysPage = false
	keysPP = false
	clipOp = nil
	clipOrigin = nil
	if programmerEntered then
		sendLayout(priorLayout or 0x04, priorPage or 0x00)
		H.log("restored layout")
	end
	if nativeTap then
		-- Shift was held: hand CC 6 back so the removal below unregisters the
		-- routing OnLoad registered
		local cs = dev.mappings and dev.mappings.controlSurface
		H.call(cs and cs.RemoveCCToControl, 0, TRACK.sends)
		nativeTap = false
	end
	local m = dev.mappings and dev.mappings.script
	if m then
		for padRow = 0, 7 do
			for col = 0, 7 do
				H.call(m.RemoveNoteToScript, 0, 10 * (padRow + 1) + col + 1)
			end
		end
		local ccs = {
			1,
			2,
			3,
			4,
			5,
			6,
			7,
			8,
			10,
			19,
			20,
			29,
			30,
			39,
			40,
			49,
			50,
			59,
			60,
			69,
			70,
			79,
			80,
			89,
			90,
			91,
			92,
			93,
			94,
			95,
			96,
			97,
			98,
			99,
			101,
			102,
			103,
			104,
			105,
			106,
			107,
			108,
		}
		for _, cc in ipairs(ccs) do
			H.call(m.RemoveCCToScript, 0, cc)
		end
	end
	-- dark the surface
	for padRow = 0, 7 do
		for col = 0, 7 do
			ledOff(10 * (padRow + 1) + col + 1)
		end
	end
	for _, cc in ipairs({
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		10,
		19,
		20,
		29,
		30,
		39,
		40,
		49,
		50,
		59,
		60,
		69,
		70,
		79,
		80,
		89,
		90,
		91,
		92,
		93,
		94,
		95,
		96,
		97,
		98,
		99,
		101,
		102,
		103,
		104,
		105,
		106,
		107,
		108,
	}) do
		ledOff(cc)
	end
	flushLEDs()
	if aperture then
		H.call(aperture.Hide)
	end
	H.log("unloaded")
end
