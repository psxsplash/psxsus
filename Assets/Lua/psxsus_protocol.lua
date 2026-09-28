-- PSXSUS room protocol — the console's half.
--
-- The server's half is PSXSUS/Protocol/psxsus_protocol.py. The two must agree
-- byte-for-byte; PSXSUS/Protocol/ROOM_PROTOCOL.md is the specification.
--
-- Rides the engine's opaque AppData channel (Net.SendData / onNetData), so no
-- part of this appears in the engine. Rooms are this game's business.
--
-- Everything here is little-endian to match the wire and the PS1's byte order.
--
-- === What is actually available on the console ===========================
--
-- Lua 5.2, and psyqo-lua's luaL_openlibs opens ONLY what linit.c lists:
--
--     _G, coroutine, table, string, bit32, debug
--
-- There is NO `math` and NO `package`. So:
--
--   * `math.floor` DOES NOT EXIST here. Every division below is written as
--     integer arithmetic (`(v - v % n) / n`) for that reason — not as a style
--     choice. Reintroducing math.floor compiles fine, passes a desktop Lua
--     test, and then fails on the PlayStation with "attempt to index a nil
--     value (global 'math')".
--   * `require` DOES NOT EXIST here. Files cannot import each other, so this
--     module publishes itself into the real global table at the bottom.
--
-- `string` survives a NOPARSER=1 build: that flag swaps only the parser objects
-- (lcode/ldump/llex/lparser -> lnoparser.o), while LIB_O — which contains
-- lstrlib.o — is unconditional, and linit.c registers luaopen_string regardless.
--
-- server/tests/test_psxsus_protocol.py runs this file in a sandbox holding
-- exactly the libraries listed above, so a stray `math.` fails there instead of
-- on hardware.

local M = {}

-- Mirrors net::c_maxEventPayload. The reliable channel is stop-and-wait, so a
-- reply that does not fit one packet costs an entire extra round trip.
M.MAX_PAYLOAD = 256
M.NAME_LEN = 12
M.CODE_LEN = 4

-- The join-code alphabet. No O/0 and no I/1: codes get read aloud across a room.
-- The code-entry UI cycles through exactly this string, and it must match what
-- the server mints — the conformance suite asserts it does.
M.CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
M.ROOM_RECORD = 16
M.PLAYER_RECORD = 16
M.ROOMS_PER_PAGE = 15  -- 4 + 15*16 = 244 <= 256

-- Client -> server
M.C2S = {
    SET_NAME      = 0x01,
    LIST_ROOMS    = 0x02,
    CREATE_ROOM   = 0x03,
    JOIN_ROOM     = 0x04,
    JOIN_BY_CODE  = 0x05,
    LEAVE_ROOM    = 0x06,
    START_GAME    = 0x07,
    TASK_COMPLETE = 0x10,
    REPORT_BODY   = 0x11,
    VOTE          = 0x12,
    KILL          = 0x13,
    SABOTAGE      = 0x14,
    FIX_SABOTAGE  = 0x15,
    USE_VENT      = 0x16,
    CALL_MEETING  = 0x17,
    -- Entering/leaving a vent, as opposed to USE_VENT's hop between them. This one
    -- IS relayed to the room: a player inside a vent is invisible to everyone, and
    -- the other consoles cannot hide a sprite they were never told about.
    VENT_STATE    = 0x18,
    -- "Tell me the roster." Sent by the GAME scene once its link is up.
    --
    -- The roster is only broadcast when it CHANGES, and it does not change when
    -- a round starts — everyone was already in the room. But loading the game
    -- scene wipes the console's Lua state, so the new scene comes up knowing
    -- nobody: no names for the vote screen, and no living players for the kill
    -- lookup to find. Asking is what refills it.
    REQUEST_STATE = 0x19,
    -- "We are done looking at the results — take the room back to the lobby."
    --
    -- Sent by the ROOM'S OWNER from the game-over screen, and relayed to
    -- everyone as RETURN_LOBBY. Each console leaving on its own press means ten
    -- players trickle back over ten seconds and the host cannot start the next
    -- round until the slowest has noticed the game ended. One person decides and
    -- the room moves together, exactly as MEETING_END works.
    RETURN_TO_LOBBY = 0x1A,
    -- Put this room on a different ship. Owner only, and refused by the server
    -- while a round is running.
    --
    -- The map used to be fixed when the room was created, so getting it wrong
    -- meant tearing the room down and rebuilding it - which costs everyone in it
    -- their slot and burns a join code people have already read out loud.
    SET_MAP = 0x1B,
}

-- Server -> client
M.S2C = {
    ROOM_LIST      = 0x81,
    ROOM_JOINED    = 0x82,
    ROOM_REJECTED  = 0x83,
    ROOM_STATE     = 0x84,
    GAME_STARTING  = 0x85,
    ROLE_ASSIGNED  = 0x86,
    TASK_LIST      = 0x87,
    TASK_PROGRESS  = 0x88,
    MEETING_START  = 0x89,
    VOTE_TALLY     = 0x8A,
    EJECTED        = 0x8B,
    SABOTAGE_START = 0x8C,
    SABOTAGE_END   = 0x8D,
    PLAYER_DIED    = 0x8E,
    GAME_OVER      = 0x8F,
    PLAYER_VENT    = 0x90,
    -- Periodic resync of the running sabotage countdown. The server owns the
    -- timer; the console only ever displays it.
    SABOTAGE_TICK  = 0x91,
    -- The meeting is over and play resumes, decided by the server so every
    -- console leaves the vote screen at the same moment.
    MEETING_END    = 0x92,
    -- Everybody back to the lobby, now. The answer to RETURN_TO_LOBBY.
    RETURN_LOBBY   = 0x93,
    -- The meeting clock, once a second: is voting open yet, and how long left.
    MEETING_TICK   = 0x94,
    -- THIS console's own cooldowns, once a second, in whole seconds.
    --
    -- Addressed to one player rather than broadcast: a kill cooldown is
    -- personal, and a crewmate who could see when the impostor is next able to
    -- kill would know the one thing the impostor is hiding.
    COOLDOWN_TICK  = 0x95,
    -- This room is on a different ship now.
    --
    -- Broadcast when the owner changes it, and also sent to a joining console
    -- right after ROOM_JOINED - which is the only way a console that joined BY
    -- CODE ever learns the map, because private rooms never appear in a room
    -- list and the cached list entry it would otherwise read is not there.
    MAP_CHANGED    = 0x96,
    -- Who your fellow impostors are. ONLY EVER SENT TO AN IMPOSTOR.
    --
    -- That is the whole security model, and it is why there is no "am I an
    -- impostor" check guarding the marker this drives: a crewmate's console is
    -- never given the list, so it has nothing to draw even if somebody rewrote
    -- the Lua. Includes our own slot; filtering it out is one comparison here.
    IMPOSTOR_LIST  = 0x97,
}

M.REJECT = { FULL = 1, NOT_FOUND = 2, IN_PROGRESS = 3, SCENE_MISMATCH = 4,
             TOO_FEW_PLAYERS = 5 }
M.ROLE = { CREW = 0, IMPOSTOR = 1 }

M.ROOM_FLAG_PRIVATE     = 0x01
M.ROOM_FLAG_IN_PROGRESS = 0x02
-- Bits 2-3 of a room's flags byte carry which map it will be played on.
--
-- Packed into the spare bits rather than given a field of its own because a
-- ROOM_RECORD is exactly 16 bytes and fifteen of them fit in one 244-byte
-- packet -- one round trip for a whole page of rooms. Widening the record to 17
-- would drop that to fourteen and cost a second round trip on a link that has
-- already been the bottleneck of this project twice.
M.ROOM_MAP_SHIFT        = 4    -- flags / 4, i.e. bits 2 and 3
M.ROOM_MAP_MASK         = 3
M.PLAYER_FLAG_ALIVE     = 0x01
M.PLAYER_FLAG_OWNER     = 0x02

-- The maps, in disc order. `mapId` indexes this from 0, and the game scene a
-- console loads is SCENE.GAME + mapId, so adding a map means adding a scene at
-- the end of the build list and a name here. The server never needs to know
-- what these are called -- it only relays the id.
M.MAP_NAMES = { "THE HULK", "RIM STATION", "DEEP CORE" }
M.MAP_COUNT = 3

-- Scene indices, which must match the order the scenes are listed in the
-- SplashEdit control panel. Getting these wrong loads the wrong scene with no
-- error at all, so they are named here rather than written as bare numbers at
-- the four call sites that use them.
M.SCENE = { MENU = 0, LOBBY = 1, GAME = 2 }

--- The scene index for a map id, clamped so a server that knows about a map
--- this disc does not have cannot send the console off the end of the list.
function M.gameScene(mapId)
    if not mapId or mapId < 0 or mapId >= M.MAP_COUNT then mapId = 0 end
    return M.SCENE.GAME + mapId
end

--- The display name for a map id. Never nil: an unknown id is still shown as
--- something a player can read out to the person hosting.
function M.mapName(mapId)
    return M.MAP_NAMES[(mapId or 0) + 1] or ("MAP " .. ((mapId or 0) + 1))
end

-- Short forms, for the room list. The font is proportional and a room row has
-- about 32 characters to spend across a name, an occupancy and a map.
M.MAP_SHORT = { "HULK", "RIM", "CORE" }

function M.mapShort(mapId)
    return M.MAP_SHORT[(mapId or 0) + 1] or "?"
end

M.VOTE_SKIP = 0xFF
M.NOBODY    = 0xFF

-- MeetingStart reasons
M.MEETING_REPORT = 0
M.MEETING_BUTTON = 1

M.SABOTAGE_KIND = { LIGHTS = 0, COMMS = 1, REACTOR = 2, OXYGEN = 3 }

M.WINNER = { CREW = 0, IMPOSTORS = 1 }

-- Why a round ended. "IMPOSTORS WIN" is the same two words whether the reactor
-- blew, the last two crewmates were murdered, or the crew ejected their own
-- best player — and a losing crew that cannot tell those apart learns nothing
-- from the round. Must match `OverReason` in PSXSUS/Protocol/psxsus_protocol.py.
M.OVER_REASON = { TASKS = 0, EJECTED = 1, KILLED = 2, SABOTAGE = 3, LEFT = 4 }

--- A full sentence for each ending, in the winner's terms.
---
--- Two lines rather than one: the first says what happened, the second says
--- what it means. Both fit the ~32 characters a full-width row of the authored
--- font holds.
M.OVER_TEXT = {
    [0] = { "THE CREW FINISHED EVERY TASK", "THE SHIP IS SAVED" },          -- TASKS
    [1] = { "THE LAST IMPOSTOR WAS EJECTED", "THE CREW READ IT RIGHT" },    -- EJECTED
    [2] = { "THE IMPOSTORS OUTNUMBER YOU", "NOBODY LEFT TO STOP THEM" },    -- KILLED
    [3] = { "THE SABOTAGE WAS NEVER FIXED", "THE SHIP IS LOST" },           -- SABOTAGE
    [4] = { "THE LAST IMPOSTOR LEFT", "NOT HOW ANYONE WANTED TO WIN" },     -- LEFT
}

-- Tilemap object kinds. The ENGINE does not know these — a tile's kind is an
-- opaque byte to psxsplash. These are OUR meanings, and their values must match
-- the tilemap's "Object Kind Names" list in Unity (element 1 = "task", 2 =
-- "vent", ...). Kind 0 is a plain floor/wall. See PSXSUS/TILEMAP.md.
M.TILE_KIND = { TASK = 1, VENT = 2, EMERGENCY = 3, FIX = 4, SPAWN = 5 }

-- === primitives ==========================================================

local byte, sub, char = string.byte, string.sub, string.char

function M.u8(s, i)
    return byte(s, i) or 0
end

function M.u16(s, i)
    local lo, hi = byte(s, i), byte(s, i + 1)
    if not lo or not hi then return 0 end
    return lo + hi * 256
end

function M.putU8(v)
    return char(v % 256)
end

function M.putU16(v)
    v = v % 65536
    -- (v - v % 256) / 256 is an exact integer divide with no `math` and no
    -- floating-point residue: the numerator is already a multiple of 256.
    return char(v % 256, ((v - v % 256) / 256) % 256)
end

-- Fixed-width NUL-padded field. Truncation is deliberate: the record layout is
-- fixed, so a longer name would shift every byte after it.
function M.putName(name, len)
    len = len or M.NAME_LEN
    name = sub(name or "", 1, len)
    local pad = len - #name
    if pad > 0 then name = name .. string.rep("\0", pad) end
    return name
end

function M.getName(s, i, len)
    len = len or M.NAME_LEN
    local raw = sub(s, i, i + len - 1)
    local z = raw:find("\0", 1, true)
    if z then raw = sub(raw, 1, z - 1) end
    return raw
end

-- Test a flags bitfield with neither `math` (absent on the console) nor bit32
-- (present, but this needs nothing from it).
function M.hasFlag(flags, mask)
    return ((flags - flags % mask) / mask) % 2 == 1
end

-- === client -> server encoders ===========================================

function M.setName(name)      return M.putU8(M.C2S.SET_NAME) .. M.putName(name) end
function M.listRooms(page)    return M.putU8(M.C2S.LIST_ROOMS) .. M.putU8(page or 0) end
function M.createRoom(name, private, mapId)
    return M.putU8(M.C2S.CREATE_ROOM) .. M.putName(name) .. M.putU8(private and 1 or 0)
        .. M.putU8(mapId or 0)
end
function M.joinRoom(roomId)   return M.putU8(M.C2S.JOIN_ROOM) .. M.putU16(roomId) end
function M.joinByCode(code)   return M.putU8(M.C2S.JOIN_BY_CODE) .. M.putName(code, M.CODE_LEN) end
function M.leaveRoom()        return M.putU8(M.C2S.LEAVE_ROOM) end
function M.startGame()        return M.putU8(M.C2S.START_GAME) end
function M.taskComplete(id)   return M.putU8(M.C2S.TASK_COMPLETE) .. M.putU8(id) end
function M.reportBody(slot)   return M.putU8(M.C2S.REPORT_BODY) .. M.putU8(slot) end
function M.vote(slot)         return M.putU8(M.C2S.VOTE) .. M.putU8(slot) end
function M.kill(slot)         return M.putU8(M.C2S.KILL) .. M.putU8(slot) end
function M.sabotage(kind)     return M.putU8(M.C2S.SABOTAGE) .. M.putU8(kind) end
function M.fixSabotage(kind)  return M.putU8(M.C2S.FIX_SABOTAGE) .. M.putU8(kind) end
function M.useVent(id)        return M.putU8(M.C2S.USE_VENT) .. M.putU8(id) end
function M.callMeeting()      return M.putU8(M.C2S.CALL_MEETING) end
function M.ventState(entered) return M.putU8(M.C2S.VENT_STATE) .. M.putU8(entered and 1 or 0) end
function M.requestState()     return M.putU8(M.C2S.REQUEST_STATE) end
function M.returnToLobby()    return M.putU8(M.C2S.RETURN_TO_LOBBY) end
function M.setMap(mapId)      return M.putU8(M.C2S.SET_MAP) .. M.putU8((mapId or 0) % M.MAP_COUNT) end

-- === server -> client decoders ===========================================

-- Returns subtype, body (1-indexed string). nil on an empty payload.
function M.decode(payload)
    if not payload or #payload < 1 then return nil, nil end
    return byte(payload, 1), sub(payload, 2)
end

-- body of ROOM_LIST -> page, pageCount, { {id, playerCount, flags, name}, ... }
function M.parseRoomList(body)
    local page, pageCount, count = M.u8(body, 1), M.u8(body, 2), M.u8(body, 3)
    local rooms = {}
    for i = 1, count do
        local o = 4 + (i - 1) * M.ROOM_RECORD
        if o + M.ROOM_RECORD - 1 > #body then break end  -- truncated: stop, never error
        rooms[i] = {
            id          = M.u16(body, o),
            playerCount = M.u8(body, o + 2),
            flags       = M.u8(body, o + 3),
            name        = M.getName(body, o + 4),
        }
        rooms[i].private    = M.hasFlag(rooms[i].flags, M.ROOM_FLAG_PRIVATE)
        rooms[i].inProgress = M.hasFlag(rooms[i].flags, M.ROOM_FLAG_IN_PROGRESS)
        -- No `math` and no bit32 needed: an exact integer shift-right-2 built
        -- from the remainder, the same way putU16 divides.
        local f = rooms[i].flags
        rooms[i].mapId = ((f - f % M.ROOM_MAP_SHIFT) / M.ROOM_MAP_SHIFT) % (M.ROOM_MAP_MASK + 1)
    end
    return page, pageCount, rooms
end

-- body of GAME_STARTING -> mapId
--
-- Byte 1 is the countdown, which this message has always carried; the map is
-- byte 2. An older server sends only the countdown, and u8 answers 0 for a byte
-- that is not there — which is map 0 — so a console built against this protocol
-- still starts a round against a server that has never heard of maps.
function M.parseGameStarting(body)
    return M.u8(body, 2) % M.MAP_COUNT
end

-- body of MAP_CHANGED -> mapId
--
-- Clamped like every other map id that crosses the wire: an out-of-range value
-- would index past MAP_NAMES and take the whole redraw down with it.
function M.parseMapChanged(body)
    return M.u8(body, 1) % M.MAP_COUNT
end

-- body of ROOM_STATE -> ownerSlot, { {slot, flags, name, colour, alive, owner}, ... }
function M.parseRoomState(body)
    local count, ownerSlot = M.u8(body, 1), M.u8(body, 2)
    local players = {}
    for i = 1, count do
        local o = 3 + (i - 1) * M.PLAYER_RECORD
        if o + M.PLAYER_RECORD - 1 > #body then break end
        local p = {
            slot   = M.u8(body, o),
            flags  = M.u8(body, o + 1),
            name   = M.getName(body, o + 2),
            colour = M.u8(body, o + 14),
        }
        p.alive = M.hasFlag(p.flags, M.PLAYER_FLAG_ALIVE)
        p.owner = M.hasFlag(p.flags, M.PLAYER_FLAG_OWNER)
        players[i] = p
    end
    return ownerSlot, players
end

-- body of ROOM_JOINED -> roomId, yourSlot, joinCode
function M.parseRoomJoined(body)
    return M.u16(body, 1), M.u8(body, 3), M.getName(body, 4, M.CODE_LEN)
end

-- body of ROLE_ASSIGNED -> role, impostorCount
function M.parseRoleAssigned(body)
    return M.u8(body, 1), M.u8(body, 2)
end

-- body of TASK_LIST -> { taskId, ... }
function M.parseTaskList(body)
    local count = M.u8(body, 1)
    local ids = {}
    for i = 1, count do
        if 1 + i > #body then break end
        ids[i] = M.u8(body, 1 + i)
    end
    return ids
end

-- body of TASK_PROGRESS -> done, total
function M.parseTaskProgress(body)
    return M.u8(body, 1), M.u8(body, 2)
end

-- body of MEETING_START -> reason, bySlot, bodySlot
function M.parseMeetingStart(body)
    return M.u8(body, 1), M.u8(body, 2), M.u8(body, 3)
end

-- body of EJECTED -> slot (NOBODY if nobody), wasImpostor
function M.parseEjected(body)
    return M.u8(body, 1), M.u8(body, 2) ~= 0
end

-- body of SABOTAGE_START -> kind, timerFrames
function M.parseSabotageStart(body)
    return M.u8(body, 1), M.u16(body, 2)
end

-- body of SABOTAGE_TICK -> timerFrames
function M.parseSabotageTick(body)
    return M.u16(body, 1)
end

-- body of GAME_OVER -> winner, reason
--
-- The reason byte was added after the fact, so a body that does not carry one
-- reads as KILLED — which is what every ending used to be described as anyway.
function M.parseGameOver(body)
    -- `body` is the payload WITHOUT its subtype byte, so the winner is byte 1
    -- and the reason byte 2 — a two-byte body, not three.
    local reason = #body >= 2 and M.u8(body, 2) or M.OVER_REASON.KILLED
    return M.u8(body, 1), reason
end

-- body of MEETING_TICK -> votingOpen, framesLeft (60Hz frames)
function M.parseMeetingTick(body)
    return M.u8(body, 1) ~= 0, M.u16(body, 2)
end

--- body of COOLDOWN_TICK -> killSeconds, meetingSeconds, meetingsLeft
---
--- Already in SECONDS on the wire: this is display data and nothing else does
--- arithmetic on it, so converting from frames is the server's job.
function M.parseCooldownTick(body)
    return M.u8(body, 1), M.u8(body, 2), M.u8(body, 3)
end

-- body of PLAYER_VENT -> slot, vented
function M.parsePlayerVent(body)
    return M.u8(body, 1), M.u8(body, 2) ~= 0
end

-- body of VOTE_TALLY -> { [slot] = votes }, { [voter] = slotVotedFor }
--
-- Two sections. The counts came first and still do; the per-voter detail is
-- APPENDED after them, so nothing about the old half moved. Reading past the end
-- of a message that has no second section is safe by construction: `u8` answers
-- 0 there, which is a voter count of zero and an empty table.
--
-- The second table is what puts a face beside each candidate on the results
-- screen. "Who voted with whom" is most of what the next meeting argues about,
-- and a bare count could never say it.
function M.parseVoteTally(body)
    local count = M.u8(body, 1)
    local tally = {}
    for i = 1, count do
        local o = 2 + (i - 1) * 2
        if o + 1 > #body then break end
        tally[M.u8(body, o)] = M.u8(body, o + 1)
    end

    local base = 2 + count * 2
    local voters = M.u8(body, base)
    local votes = {}
    for i = 1, voters do
        local o = base + 1 + (i - 1) * 2
        if o + 1 > #body then break end
        votes[M.u8(body, o)] = M.u8(body, o + 1)
    end
    return tally, votes
end

-- body of IMPOSTOR_LIST -> { slot, ... }
--
-- Only an impostor's console ever receives this, so merely HAVING it is what
-- says we are one. See M.S2C.IMPOSTOR_LIST.
function M.parseImpostorList(body)
    local count = M.u8(body, 1)
    local slots = {}
    for i = 1, count do
        if 1 + i > #body then break end
        slots[i] = M.u8(body, 1 + i)
    end
    return slots
end

-- =========================================================================
-- THE BUTTON PROMPT BAR
-- =========================================================================
--
-- Three slots along the bottom of every screen: a pad glyph and a short label
-- saying what that button does RIGHT NOW. Menu, lobby, map and task panel all
-- use the same three slots in the same three places, so a player only ever has
-- to learn where to look once.
--
-- It lives HERE, in the protocol module, and that is not laziness. `sync_lua.py`
-- inlines this file ahead of each scene script, so every scene gets its own
-- private copy of the locals below — one implementation, three independent
-- instances, and no globals shared between scenes that could outlive a
-- `Scene.Load`. Duplicating it into three scene scripts would mean three places
-- to fix a prompt that says the wrong thing.
--
-- === Why the labels are dynamic ========================================
--
-- A prompt for an action you cannot take is worse than no prompt at all: it
-- teaches the player that the bar is decoration, and then they stop reading the
-- one that matters. Everything below is rebuilt from what the player can
-- actually do at the position they are actually standing in.

--- Cell indices into the `ui` sheet. Contract with `UIC` in make_art.py.
M.BTN = {
    CROSS = 3, CIRCLE = 4, SQUARE = 5, TRIANGLE = 6,
    START = 19, SELECT = 20, DPAD = 21, L2 = 22, R2 = 23,
}

-- ...and the flat neutral cell, still used for the few things that genuinely
-- ARE tinted rectangles drawn as world sprites. The plate/cap cells that used to
-- be listed here are gone: the plates are authored elements now, so their cells
-- are chosen in make_scenes.py from make_art.py's `UIC` directly.
M.UI_BLOCK = 0

local PROMPT_SLOTS = 3
local PROMPT_Y = 220
local PROMPT_SLOT_X = { 6, 108, 210 }

local promptText = {}      -- slot -> UI element handle for the label
local promptIcon = {}      -- slot -> UI element handle for the pad glyph
local promptLabel = {}     -- slot -> what is currently written there
local promptCell = {}      -- slot -> which glyph is currently shown

--- Bind the bar to a canvas. Safe to call with a canvas that has no prompt
--- elements: the bar simply never draws, and everything else still works.
---
--- BOTH halves of a slot are authored elements now. The glyphs used to be
--- sprites created here and re-framed with `Sprite.SetFrame`; they are
--- `prompticon1..3` in the same canvas as the labels, laid out by
--- make_scenes.py's `build_prompt_icons`, and re-framed with `UI.SetFrame`.
---
--- Three things came free with that. The bar no longer spends three of the
--- 128 sprite slots the avatars are competing for; it no longer depends on
--- `_G.LAYER` existing (a sprite layer number that the menu and lobby had to
--- guess at, and which decided whether the glyph drew in front of its own
--- plate); and the glyph is where you can see it in the editor, beside the
--- label it belongs to, instead of at coordinates written in this file.
function M.initPrompts(canvasName)
    local canvas = UI.FindCanvas(canvasName)
    for i = 1, PROMPT_SLOTS do
        promptText[i] = canvas >= 0 and UI.FindElement(canvas, "prompt" .. i) or -1
        promptIcon[i] = canvas >= 0 and UI.FindElement(canvas, "prompticon" .. i) or -1
        if promptText[i] >= 0 then UI.SetVisible(promptText[i], false) end
        if promptIcon[i] >= 0 then UI.SetVisible(promptIcon[i], false) end
        promptLabel[i] = nil
        promptCell[i] = nil
    end
end

--- Show a list of `{ button, label }` pairs, or nothing.
---
--- Anything past the third pair is dropped rather than wrapped: there is no
--- fourth slot, and a bar that grew a second row would move the first one.
---
--- Every write is guarded by what is already on screen. This is called from
--- `onUpdate` at several hertz, and `UI.SetText` re-lays a string out on the
--- GPU — repainting three unchanged captions every frame is a cost paid for
--- nothing.
function M.setPrompts(list)
    for i = 1, PROMPT_SLOTS do
        local entry = list and list[i]
        local h = promptText[i]
        local icon = promptIcon[i]
        if entry then
            if promptLabel[i] ~= entry[2] then
                promptLabel[i] = entry[2]
                if h and h >= 0 then
                    UI.SetText(h, entry[2])
                    UI.SetVisible(h, true)
                end
            end
            if icon and icon >= 0 and promptCell[i] ~= entry[1] then
                promptCell[i] = entry[1]
                UI.SetFrame(icon, entry[1])
                UI.SetVisible(icon, true)
            end
        elseif promptLabel[i] ~= nil or promptCell[i] ~= nil then
            promptLabel[i] = nil
            promptCell[i] = nil
            if h and h >= 0 then UI.SetVisible(h, false) end
            if icon and icon >= 0 then UI.SetVisible(icon, false) end
        end
    end
end

function M.hidePrompts() M.setPrompts(nil) end

-- =========================================================================
-- HUD CHROME
-- =========================================================================
--
-- A "plate": a bevelled metal bar with shaped end caps, for text to sit on.
--
-- This exists because a HUD of bare white text floating on the map is not a
-- HUD, it is a debug overlay — and on a busy tilemap it is genuinely hard to
-- read, because the letters have no consistent background.
--
-- THE PLATES ARE AUTHORED. Their rects live in make_scenes.py beside the text
-- rects they back, which is the whole point: they used to be sprites placed
-- from a rect table in scene_game.lua while the words on them were UI elements
-- positioned in the generator — two systems that cannot see each other, laid
-- out in two files, kept in agreement by hand. They were not in agreement, and
-- the game-over prose started six pixels outside the panel it belonged in.
--
-- What is left here is lookup and state.

--- Find a plate authored in a canvas, as a list of element handles.
---
--- `prefix` names either a three-piece pill (`prefix_l`, `prefix_m`,
--- `prefix_r`) or a single-element panel (`prefix`). Both come back as a plain
--- list, so `showPlate` and `tintPlate` work on either without knowing which.
---
--- Returns nil when the canvas or the pieces are not there. Every caller
--- tolerates that: a HUD without its backing is still a readable HUD, which is
--- the right way for a missing asset to fail.
function M.findPlate(canvasName, prefix)
    local c = UI.FindCanvas(canvasName)
    if c < 0 then return nil end

    -- A one-piece panel first: `plate_overbody` is a single stretched cell,
    -- because the caps are 16x16 art with a rounded END drawn for a one-line
    -- pill bar. Stretched to the height of a 96px dialog that corner is not a
    -- rounded box, it is a 16px vertical smear down each side.
    local one = UI.FindElement(c, prefix)
    if one >= 0 then return { one } end

    local p = {}
    local l = UI.FindElement(c, prefix .. "_l")
    local m = UI.FindElement(c, prefix .. "_m")
    local r = UI.FindElement(c, prefix .. "_r")
    if l < 0 or m < 0 or r < 0 then return nil end
    p[1], p[2], p[3] = l, m, r
    return p
end

-- Both shapes are just a list of handles, so show/tint work on either. Counting
-- the table rather than assuming three is what lets a panel share them.
function M.showPlate(p, on)
    if not p then return end
    for i = 1, #p do UI.SetVisible(p[i], on and true or false) end
end

function M.tintPlate(p, r, g, b)
    if not p then return end
    for i = 1, #p do UI.SetColor(p[i], r, g, b) end
end


-- There is no `require` on the console, and each script runs in its own
-- environment table whose metatable only forwards READS to _G — so a plain
-- `PSXSUS = M` would land in this file's private environment, invisible to every
-- other script. Writing through _G explicitly is what publishes it.
--
-- Attach this file to the scene BEFORE the scripts that use it: splashpack Lua
-- files execute in order, and a scene script running first would see nil.
_G.PSXSUS = M

-- Still returned, so desktop tests can load it in the ordinary way.
return M
