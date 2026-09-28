-- PSXSUS game scene — the scene script.
--
-- Attach to the GAME scene's PSXSceneExporter, AFTER psxsus_protocol.lua.
--
-- Owns: the network session across the handover, the local view of the round
-- (role, tasks, phase), the avatar<->sprite wiring, and the HUD.
--
-- Does NOT own: any rule. Every one of them lives on the server. This file never
-- decides that a kill happened, that a vote passed, or that the game is over —
-- it asks, and it draws whatever it is told. If you find yourself adding an
-- `if` here that changes the outcome of anything, it belongs in
-- PSXSUS/Server/psxsus_match.py instead.
--
-- Per-frame logic is in player_control.lua: scene scripts get no onUpdate.
--
-- Console Lua has no `math` and no `require`. See psxsus_protocol.lua.

local P = nil
local handlers = nil

local MAX_SLOTS = 10
local ROW_COUNT = 12          -- vote rows: 10 players + skip + spare
--- Mirrors VOTE_FRAMES in psxsus_match.py. The meeting is one countdown and
--- voting opens for its last VOTE_SECONDS, so the debate half is what is
--- left above this.
local VOTE_SECONDS = 25

-- Phases, shared with player_control.lua through _G.
_G.PHASE = { PLAYING = 0, MEETING = 1, OVER = 2 }
local PHASE = _G.PHASE

local ui = {}
local canvas = -1
local voteCanvas = -1

--- The sprite draw order, front to back. A LOWER layer draws in FRONT.
---
--- Written down as one table because it is a single decision and it was
--- previously eight bare numbers spread across four files. Two of them collided
--- on layer 0 — the HUD plates and the button prompt glyphs — and within a layer
--- the order falls to creation order, so the plates (created first) covered the
--- glyphs they were supposed to sit behind.
---
--- The gaps are deliberate: they leave room to slot something in without
--- renumbering the world.
-- Layers 0-3 are FREE, and the gap is left rather than closed.
--
-- They used to be PROMPT, PANEL and PANELBG: the button glyphs, the parts of a
-- task panel drawn ON another part, and the panel's own backdrop. All three
-- are UI ELEMENTS now, authored in the scene, and UI draws in front of every
-- sprite layer — so the sprites that needed them no longer exist.
--
-- What they were solving is worth remembering, because it is the reason this
-- table has explicit layers at all: within ONE layer the draw order is the
-- opposite of how it reads, since the ordering table inserts at the head and
-- the sprite created FIRST is drawn LAST, in front. Relying on creation order
-- cost this game two invisible-panel bugs, in both directions. When one sprite
-- must be behind another, say so with a layer.
_G.LAYER = {
    HUD    = 2,   -- plates and direction arrows
    DARK   = 4,   -- the vision mask and its surround bars
    CREW   = 5,
    BODY   = 6,
    PROP   = 7,
    RING   = 8,   -- the interact highlight, on the floor
    MARKER = 9,   -- your task markers, on the floor
}
local LAYER = _G.LAYER

--- The darkest colour that is still DRAWN. Never use (0, 0, 0).
---
--- On the PlayStation a pixel of 0x0000 is not black, it is TRANSPARENT - the
--- hardware has no alpha channel and spends the all-zero value on see-through
--- instead. So anything painted an exact black is not dark, it is absent, and it
--- fails silently: the sprite is created, positioned, sized and made visible, and
--- simply never appears.
---
--- 8 is one step of the 15-bit colour space (255/31 is about 8.2), i.e. the
--- smallest value that is not zero. It is indistinguishable from black on a CRT
--- and it is drawn.
---
--- The texture pipeline already knows this - `PSXTexture2D.CreateFromTexture2D`
--- bumps any opaque pixel that quantises to 0x0000 up to (1,1,1) and sets bit 15
--- - but that only covers colours baked into an image. A TINT is a vertex colour
--- multiplied in at draw time (`final = texel * colour / 128`), so it never goes
--- through that path and nothing was protecting it.
_G.NEAR_BLACK = { 8, 8, 8 }
local NEAR_BLACK = _G.NEAR_BLACK

-- slot -> actor / sprite id. Rebuilt on scene load; never persisted (actor ids
-- are scene-scoped, which is exactly why clearScene() drops them).
local avatars = {}
local sprites = {}
local bodies = {}             -- slot -> { id, x, z } of the corpse left behind
local props = {}              -- sprite ids for the authored map objects

-- Addressable world objects, sourced from the tilemap (kind/id/pixel-centre) when
-- the scene has one, and from authored actors otherwise. kindName -> id -> {x,z}.
-- The game asks "where is task 3 / a vent / the fix for this sabotage" through the
-- Game*Pos helpers below and never cares which of the two authoring styles a scene
-- used. See TILEMAP.md.
local objects = { task = {}, vent = {}, emergency = {}, fix = {}, spawn = {} }

-- slot -> true while that player is inside a vent. A vented player is invisible
-- to everyone else, which is the entire point of a vent; the server broadcasts
-- the transitions because a console cannot hide a sprite it was never told about.
local vented = {}

local players = {}            -- slot -> { name, alive } from the last RoomState

--- Shared mutable state. A table, NOT Persist.
---
--- Persist stores one `long` per key across SIXTEEN keys and silently drops the
--- seventeenth (luaapi.cpp: `lua_Number value = lua.toNumber(2)` over
--- `PersistEntry s_persistData[16]`). This scene alone needs ~24 keys, and two
--- of them would be booleans — `toNumber(true)` is 0, and 0 is TRUTHY in Lua, so
--- that path only ever worked by accident.
---
--- Lua files each get a private environment whose metatable forwards READS to
--- _G, so an explicit `_G.SUS` is the only way two files share anything. It does
--- not survive a scene load (clearScene -> L.Shutdown -> lua_close), which is
--- fine: everything here comes from the server after we reconnect.
_G.SUS = {}
local S = _G.SUS

local function set(k, v) S[k] = v end
local function get(k, d)
    local v = S[k]
    if v == nil then return d end
    return v
end

-- === UI helpers ==========================================================

local function show(name, visible)
    local h = ui[name]
    if h and h >= 0 then UI.SetVisible(h, visible) end
end

local function text(name, s)
    local h = ui[name]
    if h and h >= 0 then UI.SetText(h, s) end
end

local function rowName(i) return "vote" .. i end

-- === sprites =============================================================

local COLOURS = {
    { 255, 40, 40 }, { 40, 80, 255 }, { 40, 200, 40 }, { 255, 130, 200 },
    { 255, 150, 40 }, { 240, 240, 60 }, { 60, 60, 60 }, { 240, 240, 240 },
    { 140, 60, 220 }, { 60, 220, 220 },
}

local function tint(id, slot)
    local c = COLOURS[((slot - 1) % #COLOURS) + 1]
    Sprite.SetColor(id, c[1], c[2], c[3])
end

-- Actor.GetPosition's Vec3 components are FixedPoint objects (tables with _raw,
-- no __mul, rejected by the number-only Sprite calls). The sprite system places
-- sprites at integer screen pixels, so read positions as plain integer pixels.
-- :toNumber()/:raw() methods are unreachable (psyqo-lua's FixedPoint metatable
-- sets no __index), so read the raw fp12 field ._raw and floor to integer pixels
-- by hand (no bit32; `/` is integer division on the console).
local function toPx(fp) local r = fp._raw; return (r - r % 4096) / 4096 end

--- See the note on the identical helper in player_control.lua: GetPositionXZ
--- returns two plain numbers and allocates nothing, where GetPosition builds
--- four Lua tables every call.
local function apos(actor)
    if not actor then return nil end
    if Actor.GetPositionXZ then return Actor.GetPositionXZ(actor) end
    local p = Actor.GetPosition(actor)
    if not p then return nil end
    return toPx(p.x), toPx(p.z)
end

-- === who you can see =====================================================
--
-- Three rules, applied in order, and they are the whole social half of the game:
--
--   1. Inside a vent you are gone, to everybody but yourself.
--   2. Only the dead see the dead. A killed or ejected player keeps walking
--      (ghosts still do tasks), so without this every living player watches the
--      ghosts wander the map — which gives away who is dead, where they died,
--      and which way the killer went.
--   3. **You only see what you can actually see.** A living player is drawn only
--      if they are within sight range AND there is an unobstructed line to them.
--      This is what makes a wall mean something: without it the whole map is
--      visible at all times, an impostor can never be alone with anybody, and
--      "where was everyone" is answered by looking rather than by asking.
--
-- The dead are exempt from rule 3 entirely. A ghost has nothing left to learn
-- and no way to act on it, and a ghost who cannot see the round play out is a
-- player who has been ejected from the game rather than from the ship.

-- Sight range in world pixels, and the numbers are chosen so that the range is
-- SMALLER THAN THE SCREEN.
--
-- That is the whole point and it is a change from what this used to be. The old
-- value was 150 — just inside the horizontal edge of a 320px window — which
-- meant "you can see it if it is on screen", and a rule that never binds is not
-- a rule. Line of sight only means something when the player can see where their
-- sight ENDS, which is why the dark is now drawn (`applyVision` below) and why
-- the radius has to leave room for it.
--
-- The impostor sees further than the crew, as in Among Us: the extra range is
-- what lets them pick a target that has not yet seen them, and it is the one
-- advantage that costs the crew nothing to have taken from them.
local VISION = 104
local VISION_IMPOSTOR = 132
-- Lights out. The crew's range collapses; the impostor's does not, because an
-- impostor who blinded themselves has sabotaged nothing.
local VISION_DARK = 52

local function visionRange()
    if get("role", P.ROLE.CREW) ~= P.ROLE.CREW then return VISION_IMPOSTOR end
    if not get("sabotage_active", false) then return VISION end
    if get("sabotage_kind", 0) ~= P.SABOTAGE_KIND.LIGHTS then return VISION end
    return VISION_DARK
end

--- Can we see (x, z) from (px, pz)?
---
--- Range first, because it is two multiplies and rejects most of the map before
--- the ray is ever cast. `Tile.RayClear` is native (tilemath::sightClear) — doing
--- this in Lua would be one `Tile.Walkable` call per sample, hundreds a frame.
--- A scene with no tilemap reports clear, so a mapless scene keeps everyone
--- visible rather than hiding the entire cast behind walls that do not exist.
local function canSee(px, pz, x, z, range)
    local dx, dz = x - px, z - pz
    if dx * dx + dz * dz > range * range then return false end
    if not (Tile and Tile.RayClear) then return true end
    return Tile.RayClear(px, pz, x, z)
end

_G.GameCanSee = canSee

-- === telling your partners apart =========================================
--
-- Two impostors who cannot recognise each other play the round afraid of the
-- one person on the ship they are safe with: they avoid each other, refuse to
-- vouch, and now and then walk one another into a vote. So a partner wears a
-- marker — an arrow over the head, in a red no crew colour uses.
--
-- IT CANNOT LEAK, AND NOT BECAUSE OF A CHECK HERE. The server sends
-- IMPOSTOR_LIST *only to impostors* (see match.py `start`), so a crewmate's
-- console is never given the slots at all. `fellowImpostors` on a crewmate is
-- empty because there was nothing to fill it with — not because a flag said to
-- skip the drawing — and that is the difference between a secret and a
-- suggestion. Guarding a broadcast with `if role == IMPOSTOR` would put the
-- whole round one edited byte away from being visible to everybody.
--
-- The arrow sheet's cell 2 is the south arrow (see OCT_DIR), which is the one
-- that points DOWN at the player it belongs to. Existing art; no new cell.
local IMPOSTOR_MARK_CELL = 2
local IMPOSTOR_MARK_RGB = { 230, 60, 60 }
--- Bound above the head: the avatar sprite itself sits at (-8, -12), so this
--- clears it by another twelve pixels.
local IMPOSTOR_MARK_DY = -26
local fellowImpostors = {}      -- slot -> true. NEVER contains our own slot.
local impostorMarks = {}        -- slot -> sprite id

--- (Re)bind a marker over every known partner. Safe to call whenever either
--- half — the roster or the avatars — arrives, because the two race: the list
--- lands on the reliable channel and the avatars are built during scene setup.
local function refreshImpostorMarks()
    if Sprite.SheetIndex("arrow") < 0 then return end
    for slot in pairs(fellowImpostors) do
        if impostorMarks[slot] == nil and avatars[slot] then
            local id = Sprite.Create("arrow")
            if id < 0 then break end          -- pool full; the game still plays
            Sprite.SetFrame(id, IMPOSTOR_MARK_CELL)
            Sprite.SetColor(id, IMPOSTOR_MARK_RGB[1], IMPOSTOR_MARK_RGB[2],
                            IMPOSTOR_MARK_RGB[3])
            Sprite.BindToActor(id, avatars[slot], 0, -8, IMPOSTOR_MARK_DY)
            -- In FRONT of the crew, or a partner standing behind a prop wears a
            -- marker nobody can see. HUD is the layer the other indicators use.
            Sprite.SetLayer(id, LAYER.HUD)
            Sprite.SetVisible(id, false)      -- applyVisibility decides
            impostorMarks[slot] = id
        end
    end
end

_G.GameRefreshImpostorMarks = refreshImpostorMarks

--- Everything a scene teardown has to let go of.
local function clearImpostorMarks()
    for slot, id in pairs(impostorMarks) do
        if id and id >= 0 then Sprite.Destroy(id) end
        impostorMarks[slot] = nil
    end
    fellowImpostors = {}
end

--- Re-evaluate every avatar and every body. Called from player_control on a
--- clock, not every frame: it reads ten positions and casts up to nine rays, and
--- a player cannot walk far enough in a sixteenth of a second for the answer to
--- have changed.
local function applyVisibility()
    local mySlot = get("my_slot", -1)
    local iAmDead = not get("alive", true)
    local me = avatars[mySlot]
    local px, pz = apos(me)
    local range = visionRange()

    for slot = 1, MAX_SLOTS do
        local id = sprites[slot]
        if id and id >= 0 then
            local visible
            if slot == mySlot then
                -- Always. A player who cannot see their own character has no
                -- idea where they are, vent or no vent.
                visible = true
            elseif vented[slot] then
                visible = false
            else
                local p = players[slot]
                -- The roster arrives asynchronously; an unknown slot is assumed
                -- alive rather than hidden on a technicality.
                local slotAlive = (p == nil) or p.alive
                if iAmDead then
                    visible = true                 -- the dead see everything
                elseif not slotAlive then
                    visible = false                -- the living never see ghosts
                elseif px == nil then
                    -- We do not know where WE are yet (the first frames of a
                    -- scene). Show everyone rather than nobody: a blank map
                    -- reads as a broken game, a crowded one only as a hint.
                    visible = true
                else
                    local ax, az = apos(avatars[slot])
                    visible = ax ~= nil and canSee(px, pz, ax, az, range)
                end
            end
            Sprite.SetVisible(id, visible)

            -- A partner's marker lives and dies with the bean it points at:
            -- same sight test, same vent, same everything. Computing it here
            -- rather than separately is what guarantees the two can never
            -- disagree — an arrow hanging over an empty corridor because the
            -- avatar was hidden by a wall would advertise a hidden impostor to
            -- anyone standing next to us.
            local mark = impostorMarks[slot]
            if mark and mark >= 0 then
                local p = players[slot]
                -- Dead partners lose it too. A corpse is not somebody to avoid
                -- killing, and a ghost is nobody's ally any more.
                local stillOurs = (p == nil) or p.alive
                Sprite.SetVisible(mark, visible and stillOurs)
            end
        end
    end

    -- Bodies obey the same sight rules. A corpse is the single most valuable
    -- piece of information in the game, and one visible through a wall would let
    -- a crewmate report a kill they could not possibly have witnessed.
    for slot, b in pairs(bodies) do
        if b.id and b.id >= 0 then
            local visible = iAmDead or px == nil or canSee(px, pz, b.x, b.z, range)
            Sprite.SetVisible(b.id, visible)
        end
    end

    -- The DRAWN dark, from the same call, for the same reason: what a player can
    -- see and what the screen shows them they can see have to be one decision.
    -- Kept here rather than hung off each message handler because the inputs
    -- (role, aliveness, sabotage, phase) change from six different places and
    -- one of them will always be forgotten. It costs a comparison when nothing
    -- has changed — see `visionDrawn`.
    if _G.GameApplySabotageEffect then _G.GameApplySabotageEffect() end
end

_G.GameApplyVisibility = applyVisibility

--- Which animation a slot should be playing, given whether it is walking.
---
--- The dead keep walking — a ghost still does tasks — but they were still being
--- drawn with the living walk cycles, so a ghost looked exactly like a crewmate
--- to the other ghosts who can see them. The crew sheet has a separate
--- legless silhouette for precisely this, and the one thing a player must never
--- misread is whether the thing in front of them is alive.
_G.GameAnimFor = function(slot, walkAnim)
    local p = players[slot]
    if p ~= nil and not p.alive then
        return walkAnim and "ghost" or "ghost_idle"
    end
    return walkAnim or "idle"
end

-- The old name, kept because every message handler below calls it whenever the
-- roster or somebody's aliveness changes. It is the same job — those events
-- change who is visible for reasons that have nothing to do with where anyone is
-- standing, so they must force a re-evaluation too.
local function applyGhostVisibility()
    applyVisibility()
end

_G.GameApplyGhostVisibility = applyGhostVisibility

-- === world objects (tilemap or actors) ===================================

-- Our object-kind byte -> our bucket name. The engine attaches no meaning to a
-- tile's kind, so these values are OURS (P.TILE_KIND in psxsus_protocol.lua) and
-- must match the tilemap's Object Kind Names in Unity.
local KIND_BUCKET = nil
local function kindBuckets()
    if KIND_BUCKET then return KIND_BUCKET end
    KIND_BUCKET = {}
    if P and P.TILE_KIND then
        KIND_BUCKET[P.TILE_KIND.TASK] = "task"
        KIND_BUCKET[P.TILE_KIND.VENT] = "vent"
        KIND_BUCKET[P.TILE_KIND.EMERGENCY] = "emergency"
        KIND_BUCKET[P.TILE_KIND.FIX] = "fix"
        KIND_BUCKET[P.TILE_KIND.SPAWN] = "spawn"
    end
    return KIND_BUCKET
end

-- Read the tilemap's addressable objects once, into id-keyed buckets. A scene
-- with no tilemap (Tile.Active() false, or no Tile table at all in a test host)
-- leaves the buckets empty and every lookup falls back to authored actors.
local function buildObjectIndex()
    objects = { task = {}, vent = {}, emergency = {}, fix = {}, spawn = {} }
    if not (Tile and Tile.Active and Tile.Active()) then return end
    local buckets = kindBuckets()
    local n = Tile.ObjectCount()
    for i = 1, n do
        local kind, id, x, z = Tile.ObjectAt(i)
        if kind then
            local name = buckets[kind]
            if name then objects[name][id] = { x = x, z = z } end
        end
    end
end

-- The authored-actor name a bucket/id maps to, for scenes with no tilemap.
local function actorNameFor(kindName, id)
    if kindName == "emergency" then return "emergency" end
    if kindName == "spawn" then return "player_" .. id end
    return kindName .. "_" .. id       -- task_1, vent_3, fix_0
end

--- Pixel position of an addressable object, from the tilemap if present, else
--- from the authored actor. Returns x, z or nil.
---
--- MEMOISED, and that is a performance fix, not a tidiness one. The indicators
--- and the interact ring call this several times PER FRAME, and the
--- authored-actor fallback path costs a string concatenation ("task_" .. id, so
--- a fresh Lua string every call), an Actor.Find scan through the scene, and an
--- Actor.GetPosition that allocates a Vec3 table plus three FixedPoint tables.
--- Around thirty of those a frame is enough garbage to make psyqo-lua's
--- collector visibly eat the frame rate on a 33MHz console.
---
--- Safe to cache because these are map furniture: tiles and authored props that
--- never move for the life of the scene. Avatars and bodies are NOT looked up
--- through here.
local posCache = {}

_G.GameObjectPos = function(kindName, id)
    local key = kindName .. id           -- built once per object, not per frame
    local c = posCache[key]
    if c then return c.x, c.z end

    local x, z
    local bucket = objects[kindName]
    local o = bucket and bucket[id]
    if o then
        x, z = o.x, o.z
    else
        x, z = apos(Actor.Find(actorNameFor(kindName, id)))
    end

    -- Only HITS are cached. Caching a miss would make it permanent, and things
    -- are looked up before the scene is necessarily finished being populated —
    -- one early lookup of a station that is not there yet would blank it for the
    -- rest of the round. A miss in a correctly authored scene is rare; a miss in
    -- a broken one should stay slow and correct rather than fast and wrong.
    if x ~= nil then posCache[key] = { x = x, z = z } end
    return x, z
end

--- Drop the memo. Only needed if a scene ever moves its map furniture; called on
--- scene setup so a reloaded scene cannot inherit the previous one's positions.
_G.GameInvalidateObjectPos = function() posCache = {} end

_G.GameEmergencyPos = function()
    -- Only ever one, but its auto-numbered id is not fixed, so take whatever is
    -- in the bucket; fall back to the authored "emergency" actor. Memoised for
    -- the same reason GameObjectPos is: the interact ring asks every frame.
    local c = posCache["emergency"]
    if c then return c.x, c.z end
    local x, z
    for _, o in pairs(objects.emergency) do x, z = o.x, o.z; break end
    if x == nil then x, z = apos(Actor.Find("emergency")) end
    if x ~= nil then posCache["emergency"] = { x = x, z = z } end   -- hits only
    return x, z
end

--- Nearest vent id to (x, z) within maxDist, or nil. Vents come from the tilemap
--- if it has any, else from vent_1..8 actors.
_G.GameNearestVent = function(x, z, maxDist)
    local best, bestD = nil, maxDist * maxDist
    if next(objects.vent) then
        for id, o in pairs(objects.vent) do
            local dx, dz = o.x - x, o.z - z
            local d = dx * dx + dz * dz
            if d < bestD then best, bestD = id, d end
        end
        return best
    end
    for i = 1, 8 do
        -- Through GameObjectPos, not Actor.Find directly: this loop runs every
        -- frame for an impostor and the memo is what keeps it from costing eight
        -- string builds and eight scene scans each time.
        local ax, az = GameObjectPos("vent", i)
        if ax then
            local dx, dz = ax - x, az - z
            local d = dx * dx + dz * dz
            if d < bestD then best, bestD = i, d end
        end
    end
    return best
end

--- The vent after `id` in the ring: the smallest id strictly greater, wrapping
--- back to the smallest. Deterministic, so every console agrees on the order.
_G.GameVentNext = function(id)
    if next(objects.vent) then
        local firstId, nextId
        for vid, _ in pairs(objects.vent) do
            if not firstId or vid < firstId then firstId = vid end
            if vid > id and (not nextId or vid < nextId) then nextId = vid end
        end
        return nextId or firstId or id
    end
    return (id % 8) + 1   -- authored vent_1..vent_8 fallback
end

--- Where venting from `id` should drop the player. Returns x, z or nil.
_G.GameVentDest = function(id)
    return GameObjectPos("vent", GameVentNext(id))
end

-- === indicators ==========================================================
--
-- Two screen-pinned arrows (where to go) and one world-anchored ring (what you
-- can use right here). Sprites, not UI elements: sprites can be created, tinted,
-- moved and resized at runtime, and the UI system's elements are authored.

local indicators = { task = -1, sab = -1, ring = -1 }

-- Screen centre and how far out from it the arrows orbit.
local SCREEN_CX, SCREEN_CY = 160, 120
local ARROW_RADIUS = 44
-- Roughly the visible half-extent; an objective closer than this is on screen
-- already and does not need pointing at.
local ON_SCREEN_X, ON_SCREEN_Z = 150, 110

-- Unit direction per arrow cell, in the sheet's order: clockwise from East.
local OCT_DIR = {
    [0] = { 1, 0 }, [1] = { 1, 1 }, [2] = { 0, 1 }, [3] = { -1, 1 },
    [4] = { -1, 0 }, [5] = { -1, -1 }, [6] = { 0, -1 }, [7] = { 1, -1 },
}

--- Direction (dx, dz) -> arrow cell 0..7, clockwise from East.
--- Integer-only: there is no atan (and no `math` at all) on the console. A
--- direction counts as diagonal when neither axis dominates the other by more
--- than ~2.5x, which is the same 22.5-degree split an 8-way arrow wants.
local function octant(dx, dz)
    local adx = dx >= 0 and dx or -dx
    local adz = dz >= 0 and dz or -dz
    if (adx * 5 > adz * 2) and (adz * 5 > adx * 2) then
        if dx >= 0 then return dz >= 0 and 1 or 7 end
        return dz >= 0 and 3 or 5
    end
    if adx >= adz then return dx >= 0 and 0 or 4 end
    return dz >= 0 and 2 or 6
end

_G.GameOctant = octant   -- exposed so the tests can check the math directly

local function createIndicators()
    -- Say so. A missing sheet used to be silent, which meant "no arrows appear"
    -- looked identical to "the arrow logic is broken" — and the answer was
    -- always the boring one: the sheet was never authored in Unity.
    if Sprite.SheetIndex("arrow") < 0 then
        Debug.Log("PSXSUS: no sprite sheet named 'arrow' - the direction arrows " ..
                  "will not appear. Author it per UNITY_SETUP.md step 2.3.")
    end
    if Sprite.SheetIndex("ui") < 0 then
        Debug.Log("PSXSUS: no sprite sheet named 'ui' - no interact ring, no " ..
                  "lights-out darkness, and task panels will draw nothing. " ..
                  "Author it per UNITY_SETUP.md step 2.4.")
    end
    if Sprite.SheetIndex("arrow") >= 0 then
        indicators.task = Sprite.Create("arrow")
        indicators.sab = Sprite.Create("arrow")
        for _, id in ipairs({ indicators.task, indicators.sab }) do
            if id >= 0 then
                -- Pinned to the screen, not the world: an arrow is a HUD element
                -- that happens to be a sprite.
                Sprite.SetIgnoreViewOffset(id, true)
                Sprite.SetLayer(id, LAYER.HUD)
                Sprite.SetVisible(id, false)
            end
        end
        if indicators.task >= 0 then Sprite.SetColor(indicators.task, 90, 230, 120) end
        if indicators.sab >= 0 then Sprite.SetColor(indicators.sab, 255, 70, 70) end
    end
    if Sprite.SheetIndex("ui") >= 0 then
        indicators.ring = Sprite.Create("ui")
        if indicators.ring >= 0 then
            Sprite.SetFrame(indicators.ring, 1)   -- cell 1 of ui.png is the ring
            Sprite.SetColor(indicators.ring, 255, 240, 120)
            Sprite.SetLayer(indicators.ring, LAYER.RING)   -- on the floor, under the crew
            Sprite.SetVisible(indicators.ring, false)
        end
    end
end

local function pointArrow(id, px, pz, tx, tz)
    if not id or id < 0 then return end
    if not tx then
        Sprite.SetVisible(id, false)
        return
    end
    local dx, dz = tx - px, tz - pz
    local adx = dx >= 0 and dx or -dx
    local adz = dz >= 0 and dz or -dz
    if adx <= ON_SCREEN_X and adz <= ON_SCREEN_Z then
        -- You can already see it; an arrow would just be clutter.
        Sprite.SetVisible(id, false)
        return
    end
    local o = octant(dx, dz)
    local d = OCT_DIR[o]
    Sprite.SetFrame(id, o)
    Sprite.SetPos(id, SCREEN_CX + d[1] * ARROW_RADIUS - 8,
                      SCREEN_CY + d[2] * ARROW_RADIUS - 8)
    Sprite.SetVisible(id, true)
end

--- Nearest task the server actually gave us that is not finished yet.
local function nearestOwnTask(x, z)
    local best, bx, bz, bestD = nil, nil, nil, nil
    local count = get("task_count", 0)
    for i = 1, count do
        local id = get("task_" .. i, 0)
        if id > 0 and not get("task_done_" .. id, false) then
            local tx, tz = GameObjectPos("task", id)
            if tx then
                local dx, dz = tx - x, tz - z
                local d = dx * dx + dz * dz
                if not bestD or d < bestD then best, bx, bz, bestD = id, tx, tz, d end
            end
        end
    end
    return best, bx, bz
end

_G.GameNearestOwnTask = nearestOwnTask

--- Per frame: point the arrows at whatever matters right now.
_G.GameUpdateIndicators = function(px, pz)
    if not px then return end
    local sabActive = get("sabotage_active", false)
    local kind = get("sabotage_kind", 0)

    -- A sabotage always wins the player's attention, and its arrow is shown even
    -- during comms — comms is itself fixed at a station you have to find.
    if sabActive then
        local fx, fz = GameObjectPos("fix", kind)
        pointArrow(indicators.sab, px, pz, fx, fz)
    else
        pointArrow(indicators.sab, px, pz, nil)
    end

    -- Comms is exactly the sabotage that takes your task guidance away.
    if sabActive and kind == P.SABOTAGE_KIND.COMMS then
        pointArrow(indicators.task, px, pz, nil)
    else
        local _, tx, tz = nearestOwnTask(px, pz)
        pointArrow(indicators.task, px, pz, tx, tz)
    end
end

--- Ring whatever the player is close enough to interact with, or nothing.
--- World-anchored (it does NOT ignore the view offset), so a world pixel is the
--- right coordinate to hand it.
_G.GameSetHighlight = function(x, z)
    local id = indicators.ring
    if not id or id < 0 then return end
    if x then
        Sprite.SetPos(id, x - 8, z - 8)
        Sprite.SetVisible(id, true)
    else
        Sprite.SetVisible(id, false)
    end
end

-- === your task markers ===================================================
--
-- A ring standing permanently on each of YOUR unfinished stations. Twelve task
-- tiles all look identical on the map, so without this a crewmate has no way to
-- tell which four are theirs — the arrow points at the nearest one, but only
-- when it is off screen, and it says nothing about the other three.
--
-- One sprite per assigned task, created once and then only ever shown or
-- hidden. World-anchored (they move with the camera) and tinted green to match
-- the task arrow, so the colour means "yours" everywhere it appears.

local MAX_OWN_TASKS = 8
local taskMarkers = {}   -- index -> sprite id

local function createTaskMarkers()
    if Sprite.SheetIndex("ui") < 0 then return end
    for i = 1, MAX_OWN_TASKS do
        local id = Sprite.Create("ui")
        if id < 0 then break end          -- pool full; the game still plays
        -- Cell 2, the diamond, NOT the interact ring at cell 1. The two mean
        -- different things and must not look the same: a ring says "you are
        -- close enough to press X on this", a diamond says "this one is yours".
        Sprite.SetFrame(id, 2)
        Sprite.SetColor(id, 90, 230, 120)
        Sprite.SetLayer(id, LAYER.MARKER) -- on the floor, under the crew
        Sprite.SetVisible(id, false)
        taskMarkers[i] = id
    end
end

--- Re-place the markers. Cheap and called rarely — only when the task list
--- arrives or a task is finished — so it is free to do the full walk.
_G.GameRefreshTaskMarkers = function()
    local n = 0
    local count = get("task_count", 0)
    for i = 1, count do
        local id = get("task_" .. i, 0)
        if id > 0 and not get("task_done_" .. id, false) then
            local tx, tz = GameObjectPos("task", id)
            if tx then
                n = n + 1
                local m = taskMarkers[n]
                if m then
                    Sprite.SetPos(m, tx - 8, tz - 8)
                    Sprite.SetVisible(m, true)
                end
            end
        end
    end
    for i = n + 1, MAX_OWN_TASKS do
        local m = taskMarkers[i]
        if m then Sprite.SetVisible(m, false) end
    end
end

--- Hide every indicator at once — used by meetings and game over, where none of
--- them mean anything.
_G.GameHideIndicators = function()
    for _, id in ipairs({ indicators.task, indicators.sab, indicators.ring }) do
        if id and id >= 0 then Sprite.SetVisible(id, false) end
    end
    for i = 1, MAX_OWN_TASKS do
        local m = taskMarkers[i]
        if m then Sprite.SetVisible(m, false) end
    end
end

-- === the dark ============================================================
--
-- What the player can see, DRAWN: a circle of ship around them and black
-- everywhere else. This is the visible half of the line-of-sight rule, and
-- without it the rule is invisible — players walked around a fully lit map
-- wondering why other people kept vanishing.
--
-- Five sprites, and it has to be five:
--
--   * the MASK, one 64x64 authored cell scaled to the current sight diameter.
--     It is black with a transparent disc cut through it, so it paints the
--     corners of the square it covers and leaves the circle alone.
--   * four BARS filling the screen outside that square.
--
-- It cannot be done with one stretched dark sprite over the whole display,
-- which is what the old lights-out effect was: psxsplash's sprite system has no
-- semi-transparency (spritesystem.cpp's `makeTPage` sets a texture depth and
-- nothing else), so a "dim" overlay is not dim — it is opaque. The old code
-- tinted a full-screen block to (26, 26, 34) and commented that the crew could
-- still grope around; in fact a lights-out sabotage painted the entire screen
-- flat near-black and the crew could see nothing whatsoever, including
-- themselves.
--
-- Drawn on LAYER.DARK: over the world and the other players, and under
-- everything the HUD is made of.
--
-- That split is load-bearing. The HUD is what a player reads when they cannot
-- see anything else — the role, the task counter, the sabotage line and the
-- button prompts all still matter during a lights-out sabotage, which is exactly
-- when the darkness covers the most screen.

local SCREEN_W, SCREEN_H = 320, 240
local vision = { mask = -1, bars = {} }
--- The radius currently drawn, so a redraw that changes nothing does nothing.
local visionDrawn = -1

--- A few pixels wider than the sight test, so a player standing exactly at the
--- edge of vision is drawn whole rather than sliced in half by the dark.
local VISION_MARGIN = 10

local function createVision()
    if Sprite.SheetIndex("mask") < 0 then
        Debug.Log("PSXSUS: no sprite sheet named 'mask' - line of sight will " ..
                  "not be drawn, so the map will look fully lit")
        return
    end
    vision.mask = Sprite.Create("mask")
    if vision.mask >= 0 then
        Sprite.SetIgnoreViewOffset(vision.mask, true)
        Sprite.SetLayer(vision.mask, LAYER.DARK)
        Sprite.SetVisible(vision.mask, false)
    end
    if Sprite.SheetIndex("ui") < 0 then return end
    for i = 1, 4 do
        local id = Sprite.Create("ui")
        if id < 0 then break end
        Sprite.SetFrame(id, P.UI_BLOCK)     -- the flat 128 block
        Sprite.SetIgnoreViewOffset(id, true)
        -- NEAR-black, not black: see NEAR_BLACK. This used to be (0, 0, 0) on the
        -- reasoning that "128 grey times zero is zero: an exact black, with no
        -- palette entry spent on one" - which is arithmetically true and puts an
        -- exact 0x0000 on the screen, the one value the hardware reads as
        -- see-through. The bars stopped being drawn at all, so the dark had four
        -- transparent gaps around the vision circle.
        Sprite.SetColor(id, NEAR_BLACK[1], NEAR_BLACK[2], NEAR_BLACK[3])
        Sprite.SetLayer(id, LAYER.DARK)
        Sprite.SetVisible(id, false)
        vision.bars[i] = id
    end
end

local function showVision(on)
    if vision.mask >= 0 then Sprite.SetVisible(vision.mask, on) end
    for i = 1, #vision.bars do Sprite.SetVisible(vision.bars[i], on) end
end

--- Place the dark for a sight radius, or hide it entirely.
---
--- The player is always at the centre of the window (see `camera` in
--- player_control.lua: the view offset is set so the local avatar lands on
--- 160,120), so the circle is always in the same place and only its size
--- changes.
local function applyVision(radius)
    if vision.mask < 0 then return end
    if not radius then
        if visionDrawn ~= -1 then
            visionDrawn = -1
            showVision(false)
        end
        return
    end
    local r = radius + VISION_MARGIN
    if r == visionDrawn then return end
    visionDrawn = r

    local cx, cy = SCREEN_W / 2, SCREEN_H / 2
    local d = r * 2
    Sprite.SetPos(vision.mask, cx - r, cy - r)
    Sprite.SetSize(vision.mask, d, d)

    -- The four bars around the mask's square. Written as explicit rectangles
    -- rather than a loop over a table: each one has a different degenerate case
    -- (a radius past the edge of the screen makes one of them zero-width), and a
    -- clamp is easier to read than to derive.
    local left, right = cx - r, cx + r
    local top, bottom = cy - r, cy + r
    local function bar(i, x, y, w, h)
        local id = vision.bars[i]
        if not id or id < 0 then return end
        if w <= 0 or h <= 0 then
            Sprite.SetVisible(id, false)
            return
        end
        Sprite.SetPos(id, x, y)
        Sprite.SetSize(id, w, h)
        Sprite.SetVisible(id, true)
    end
    bar(1, 0, 0, SCREEN_W, top)                                  -- above
    bar(2, 0, bottom, SCREEN_W, SCREEN_H - bottom)               -- below
    bar(3, 0, top, left, d)                                      -- left
    bar(4, right, top, SCREEN_W - right, d)                      -- right
    Sprite.SetVisible(vision.mask, true)
end

--- Re-evaluate the dark from the current role, sabotage and aliveness.
---
--- The DEAD see everything. A ghost has nothing left to learn and no way to act
--- on it, and a ghost who cannot watch the round play out has been ejected from
--- the game rather than from the ship. Same rule the sprite visibility uses —
--- and it must be the same rule, or a ghost would see players through a wall of
--- black they were being drawn behind.
function applySabotageEffect()
    if not get("alive", true) then
        applyVision(nil)
        return
    end
    if get("phase", PHASE.PLAYING) ~= PHASE.PLAYING then
        -- At the table and at the end of the round there is no map to hide.
        applyVision(nil)
        return
    end
    applyVision(visionRange())
end

_G.GameApplySabotageEffect = applySabotageEffect

-- === the klaxon ==========================================================
--
-- `alarm` is the ONE looping clip on the disc, and a looping SPU voice plays
-- until something keys it off. Nothing stops it on its own: not the end of the
-- sabotage, not the meeting, not the end of the round. The channel number that
-- Audio.Play hands back is the only handle we are ever given on that voice, so
-- dropping it on the floor — which is what the code did — means the siren
-- outlives everything and the round finishes underneath a klaxon.
local alarmVoice = -1

local function stopAlarm()
    if alarmVoice >= 0 then
        if Audio and Audio.Stop then Audio.Stop(alarmVoice) end
        alarmVoice = -1
    end
end
_G.GameStopAlarm = stopAlarm

--- Start the klaxon, but only for a sabotage that deserves one.
---
--- The REACTOR is a countdown to losing the round, so it gets the siren that
--- keeps insisting until somebody deals with it. LIGHTS is a nuisance — it
--- takes nothing away but your vision — and a klaxon looping for the whole
--- blackout is just punishment for the crew. It gets the one-shot sting that
--- SABOTAGE_START already plays, and then silence to be creepy in.
local function startAlarm(kind)
    stopAlarm()
    if kind ~= P.SABOTAGE_KIND.REACTOR then return end
    if not (Audio and Audio.Play) then return end
    local ch = Audio.Play("alarm")
    -- -1 is "no free voice" or "no such clip"; storing it would make stopAlarm
    -- silence channel -1 later.
    if ch and ch >= 0 then alarmVoice = ch end
end

-- === HUD =================================================================

--- A short, plain-language link warning, or nil when the link is well.
---
--- What used to be here was two functions and eighty lines of commentary: a
--- ranked list of eight failure modes, plus an always-on row of raw counters
--- ("H6 S12 R48 O25 M91") that occupied the status line for the whole round.
--- Every one of them was earned — this project lost three sessions to a link
--- that looked healthy by every connection test while carrying 0.7% of its rated
--- throughput — but they are a DEVELOPER'S readout, and they were sitting on top
--- of the sabotage countdown and the ghost prompt during play.
---
--- The counters now live on the lobby's diagnostics page (SELECT while
--- connecting), which is where a link that never comes up leaves you. What
--- survives here is the part a PLAYER can act on, in words rather than numbers,
--- and only when something is actually wrong.
---
--- Every string fits in 22 characters: they share the status line on a 320px
--- screen, and the first thing a real console ever reported was a warning
--- running off the edge of the display.
local function linkTrouble()
    if not Net.Stats then return nil end
    local s = Net.Stats()
    if not s then return nil end
    -- Framing errors mean the two ends disagree about bit timing — a cable, a
    -- baud rate, a bad adapter. A different fault from overruns (our own
    -- latency), with an opposite fix, which is why they are not one number.
    if (s.rxFramingErrors or 0) > 0 then return "CHECK THE CABLE" end
    if (s.irqStorms or 0) > 0 then return "LINK BUSY" end
    if (s.rxOverflows or 0) > 0 then return "LINK OVERLOADED" end
    -- A backlog that is not draining, not a low byte rate. `goodput` counts what
    -- we actually sent, so it is low whenever there is little to say — which
    -- during a meeting, or standing still, is most of the time. See the longer
    -- note on the same test in scene_lobby.lua: it had "SLOW LINK" permanently
    -- on screen in a lobby that was working perfectly.
    local cap = s.txCapacity or 0
    if cap > 0 and (s.txPending or 0) * 4 > cap then return "LINK IS BACKED UP" end
    if (s.rttSamples or 0) > 0 and (s.rttMillis or 0) > 1000 then
        return "SLOW LINK"
    end
    return nil
end

-- What each sabotage actually asks of you.
--
-- "SABOTAGE! 32s" told a player that something was wrong and nothing about what
-- to do, which on a map they are still learning is the same as telling them
-- nothing. Each line names the station to find; the red arrow already points at
-- it, so the two together are a complete instruction.
--
-- Kept inside the ~32 characters the proportional font gives a full-width row.
local SABOTAGE_TEXT = {
    [0] = "LIGHTS OUT - FIX THE PANEL",   -- LIGHTS
    [1] = "COMMS DOWN - FIX THE RADIO",   -- COMMS
    [2] = "REACTOR! TWO PLAYERS HOLD X",  -- REACTOR: needs two people at once
    [3] = "NO OXYGEN - ENTER THE CODE",   -- OXYGEN: opens a code panel
}

local function sabotageLine()
    local kind = get("sabotage_kind", 0)
    local what = SABOTAGE_TEXT[kind] or "SABOTAGE - FOLLOW THE ARROW"
    local left = get("sabotage_timer", 0)
    if left <= 0 then return what end
    -- No math library, so no floor: integer-divide by hand. The timer is in
    -- 60Hz frames.
    local secs = (left - left % 60) / 60
    -- Only the two sabotages that actually END THE ROUND get a countdown. A
    -- clock on the lights is just pressure with nothing behind it, and it costs
    -- the characters that say what to do.
    if kind == 2 or kind == 3 then
        return string.format("%s %ds", what, secs)
    end
    return what
end

-- The plates the HUD text sits on. Created once; only ever shown and hidden.
--
-- The HUD used to be three strings floating on the map, which over a tilemap of
-- panelled floors is genuinely hard to read — white letters on whatever happens
-- to be underneath them. These give every caption a consistent dark backing with
-- a lit top edge, and text is drawn after all sprites (renderer.cpp), so a plate
-- can never cover the words it is behind.
-- There is deliberately NO plate under the prompt bar. A bar across the
-- bottom of the screen is a bar whether or not it has anything to say, and
-- the prompts read better floating on the map: a glyph plus one word is
-- legible on anything.
local plates = { role = nil, tasks = nil, status = nil }

--- Bind the three plates to the elements the HUD canvas already carries.
---
--- There is no rect table here any more. The plates used to be sprites placed
--- from a copy of the layout kept in THIS file, while the captions on them were
--- UI elements positioned in make_scenes.py — the same numbers, written twice,
--- in two files that cannot see each other. Now `build_hud_plates` authors both
--- and this only looks them up, so "an element at y=2 with its plate at y=20"
--- is not a thing that can happen.
local function createPlates()
    for _, name in ipairs({ "role", "tasks", "status" }) do
        plates[name] = P.findPlate("hud", "plate_" .. name)
        P.showPlate(plates[name], true)
    end
end

--- Show or hide the HUD's backing as a set.
---
--- The prompt bar has no plate to hide, so this is the whole of the chrome.
local function showChrome(on)
    P.showPlate(plates.role, on)
    P.showPlate(plates.tasks, on)
    P.showPlate(plates.status, on)
end

_G.GameShowChrome = showChrome

local function drawHud()
    local role = get("role", P.ROLE.CREW)
    if role == P.ROLE.IMPOSTOR then
        -- How many of you there are. The count scales with the lobby (1 at 4-6
        -- players, 2 at 7-8, 3 at 9-10) and an impostor who does not know
        -- whether they have partners cannot plan around them.
        local n = get("impostor_count", 1)
        if n > 1 then
            text("role", string.format("IMPOSTOR (%d)", n))
        else
            text("role", "IMPOSTOR")
        end
        -- The plate goes red for an impostor. 128 is the tint identity, so these
        -- are a multiplier and not a colour: (190, 96, 96) darkens the greens and
        -- blues of the authored plate and leaves the red, which keeps the bevel
        -- rather than flooding the whole bar one flat colour.
        P.tintPlate(plates.role, 190, 96, 96)
    else
        text("role", "CREWMATE")
        -- Put it back. 128 is the tint identity (`final = texel * colour / 128`),
        -- so this is the plate's own colours and not a colour of its own. Without
        -- it a player who was the impostor last round keeps a red plate through
        -- the next one, having been told they are a crewmate.
        P.tintPlate(plates.role, 128, 128, 128)
    end

    -- Whether the game itself has something to say on the status line. The link
    -- numbers fill it only when it does not — see the end of this function.
    local gameplayStatus = true
    if not get("alive", true) then
        text("status", "GHOST - FINISH YOUR TASKS")
    elseif get("sabotage_active", false) then
        text("status", sabotageLine())
    else
        text("status", "")
        gameplayStatus = false
    end

    -- Comms is the sabotage that takes information away, so the shared task
    -- counter goes dark with it (the arrows do too — see GameUpdateIndicators).
    if get("sabotage_active", false) and get("sabotage_kind", 0) == P.SABOTAGE_KIND.COMMS then
        text("tasks", "TASKS  ??/??")
    else
        text("tasks", "TASKS " .. get("tasks_done", 0) .. "/" .. get("tasks_total", 0))
    end

    -- One shared status line, and the order matters:
    --
    --   1. Whatever the GAME is saying — a sabotage countdown, being dead. That
    --      is the player's business and must not be buried under diagnostics.
    --   2. Otherwise, a link fault if there is one, in words.
    --   3. Otherwise nothing. A blank line is the correct thing to show a player
    --      when nothing is wrong; it used to be a row of counters.
    --
    -- This is the reverse of the old priority, which put the link first and
    -- silently ate the sabotage countdown and the ghost prompt whenever any
    -- counter was non-zero. A diagnostic that costs the player information they
    -- need is not worth what it tells the developer.
    local shown = true
    if not gameplayStatus then
        local trouble = linkTrouble()
        if trouble then
            text("status", trouble)
        else
            -- Whatever selfCheck found, for as long as it is true. An authoring
            -- fault does not go away on its own and there is nothing else
            -- competing for this line, so it stays up rather than flashing once
            -- at scene load and vanishing.
            local miss = get("selfcheck", "")
            if miss ~= "" then
                text("status", miss)
            else
                shown = false
            end
        end
    end
    -- An empty plate is a black bar across the bottom of the map for no reason,
    -- so the backing follows the caption rather than being permanent furniture.
    P.showPlate(plates.status, shown)
end

_G.GameDrawHud = drawHud

-- === the end of the round ================================================
--
-- Its own screen, and it earns one. A round used to end by rewriting the role
-- caption to "IMPOSTORS WIN" and the status line to "START RETURNS TO THE
-- LOBBY", which told a losing crew nothing about WHY they lost and left the
-- dead body count, the task counter and the map sitting behind it.
--
-- What this has to answer, in order:
--
--   1. Who won.
--   2. Why — see P.OVER_TEXT. "The reactor was never fixed" and "there was
--      nobody left to stop them" are completely different rounds, and a player
--      who cannot tell them apart cannot get better at the game.
--   3. Whether YOU won, which is not the same question as (1) and is the one
--      the player actually cares about.
--   4. What the two ways out of here are.

local overCanvas = -1

--- A banner behind the result and a frame around the explanation.
local overPlates = { banner = nil, body = nil }

-- GEOMETRY IS SHARED WITH make_scenes.py (OVER_BANNER / OVER_BODY / OVER_PAD).
-- The plates are SPRITES and the words on them are UI ELEMENTS: two systems
-- that cannot see each other and are laid out in two different files, so the
-- numbers have to be kept in agreement by hand. They were not, which is why the
-- text sat six pixels off the left edge of the panel it was supposed to be
-- inside, and why the indents were being faked with leading spaces.
local OVER_BANNER_X, OVER_BANNER_Y, OVER_BANNER_W, OVER_BANNER_H = 8, 36, 304, 28
local OVER_BODY_X, OVER_BODY_Y, OVER_BODY_W, OVER_BODY_H = 20, 76, 280, 96

local function createOverPlates()
    -- A pill for the one-line banner, which is what the capped art is for, and
    -- a plain rectangle for the block of prose, which it is not. Both are
    -- authored in the `over` canvas by make_scenes.py's build_over_plates,
    -- against the very same OVER_BANNER_*/OVER_BODY_* rectangle these captions
    -- are laid out in — one copy of the geometry instead of two.
    overPlates.banner = P.findPlate("over", "plate_over")
    overPlates.body = P.findPlate("over", "plate_overbody")
    P.showPlate(overPlates.banner, false)
    P.showPlate(overPlates.body, false)
end

local function drawOver()
    if overCanvas < 0 then return end
    UI.SetCanvasVisible(overCanvas, true)
    P.showPlate(overPlates.banner, true)
    P.showPlate(overPlates.body, true)

    local winner = get("winner", P.WINNER.CREW)
    local reason = get("over_reason", P.OVER_REASON.KILLED)
    local iAmImpostor = get("role", P.ROLE.CREW) == P.ROLE.IMPOSTOR
    local iWon = (winner == P.WINNER.IMPOSTORS) == iAmImpostor
    local crewWon = winner == P.WINNER.CREW

    -- No leading spaces anywhere on this screen. Every element here is now
    -- positioned inside its plate by make_scenes.py; padding a proportional
    -- font with spaces only ever approximated that, and it approximated it
    -- differently for each line.
    text("overtitle", crewWon and "CREWMATES WIN" or "IMPOSTORS WIN")
    -- Green for the crew, red for the impostors, on the banner behind the words.
    -- The colour is read before any of them.
    if overPlates.banner then
        if crewWon then P.tintPlate(overPlates.banner, 96, 176, 120)
        else P.tintPlate(overPlates.banner, 190, 96, 96) end
    end

    -- The winner and the reason MUST agree.
    --
    -- Two of the five reasons are things only impostors win by and three are
    -- things only the crew win by, so a mismatch is a wire or version fault
    -- rather than a legitimate ending — and "CREWMATES WIN / THE IMPOSTORS
    -- OUTNUMBER YOU" on one screen is worse than saying nothing at all. Rather
    -- than print a contradiction, fall back to the line that is true of any
    -- ending on that side.
    local IMPOSTOR_ONLY = { [P.OVER_REASON.KILLED] = true,
                            [P.OVER_REASON.SABOTAGE] = true }
    local CREW_ONLY = { [P.OVER_REASON.TASKS] = true,
                        [P.OVER_REASON.EJECTED] = true,
                        [P.OVER_REASON.LEFT] = true }
    local lines
    if crewWon and not CREW_ONLY[reason] then
        lines = { "THE IMPOSTORS ARE FINISHED", "THE SHIP IS SAFE" }
    elseif (not crewWon) and not IMPOSTOR_ONLY[reason] then
        lines = { "THE CREW NEVER FOUND THEM", "THE SHIP IS LOST" }
    else
        lines = P.OVER_TEXT[reason] or { "", "" }
    end
    text("over1", lines[1])
    text("over2", lines[2])
    -- Deliberately blank: it is the gap that separates what happened to the
    -- ship from what happened to YOU, which are different questions.
    text("over3", "")
    text("over4", iWon and "YOU WON" or "YOU LOST")

    -- Only tell someone to wait for the host when we actually KNOW they are not
    -- it. On a console that never received a roster this line was telling the
    -- host to wait for themselves.
    if get("is_owner", false) or not get("roster_ok", false) then
        text("overwait", "")
    else
        text("overwait", "WAITING FOR THE HOST")
    end
end

_G.GameDrawOver = drawOver

--- The prompts for the game-over screen, so player_control does not have to know
--- the ownership rule twice.
_G.GameOverPrompts = function()
    local list = {}
    -- Offered when we are the owner, AND when we do not yet know who is.
    --
    -- `is_owner` is read off a roster, and `Scene.Load` wiped the Lua state on
    -- the way into this scene — so a console whose re-request was lost has
    -- `is_owner = false` not because it is a guest but because it has never been
    -- told anything. Hiding the prompt on that default is what left actual hosts
    -- looking at a results screen with no way off it, concluding the room had to
    -- be torn down and remade.
    --
    -- Showing it when unsure is safe: the button is already sent
    -- unconditionally, and the SERVER refuses anyone who does not own the room.
    -- The worst case is a guest pressing it once and nothing happening; the case
    -- it replaces is a host who cannot start the next round at all.
    if get("is_owner", false) or not get("roster_ok", false) then
        list[#list + 1] = { P.BTN.START, "PLAY AGAIN" }
    end
    list[#list + 1] = { P.BTN.CIRCLE, "LEAVE" }
    return list
end

-- === voting UI ===========================================================

--- The per-slot colour, which is also the avatar tint.
---
--- Reading a name off a list and matching it to the bean you actually saw is the
--- whole job of a meeting, and the list used to be ten identical white strings.
local function voteColour(slot)
    local c = COLOURS[((slot - 1) % #COLOURS) + 1]
    return c[1], c[2], c[3]
end

local function colourRow(name, r, g, b)
    local h = ui[name]
    if h and h >= 0 and UI.SetColor then UI.SetColor(h, r, g, b) end
end

-- One crew sprite per vote row, standing at the head of it in that player's
-- colour.
--
-- The colour of the text alone was not enough: on a CRT a row of coloured words
-- reads as decoration, and the thing a player is actually trying to do is match
-- a name to the BEAN they saw walk into electrical. So it is the bean.
--
-- Created once and then only moved, re-tinted and shown or hidden — the pool is
-- 128, and creating twelve sprites every time a meeting starts would churn it
-- once per round for no gain.
local VOTE_ROWS = 12
--- 20px left of the row text, which `make_scenes.py` puts at 32 and
--- 32 + row_w(122) + column_gap(12) = 166.
---
--- The second column used to say 164, from a layout where the text was at 184.
--- The text moved and this did not, so every name in the right-hand column was
--- drawn UNDER its own bean — 14px of it, which is most of a first letter.
--- Nothing catches that but a television, so `test_assets.py` now derives both
--- numbers from the generator and asserts they still agree.
local VOTE_COL_X = { 12, 146 }
local VOTE_FIRST_Y = 45
local VOTE_ROW_H = 19
local VOTE_PER_COL = 6
local voteFaces = {}

--- The two beans at the head of the vote screen: who this meeting is ABOUT on
--- line 1, and who called it on line 2. `header.subject` is the corpse for a
--- body report and the caller for an emergency; `header.caller` is the reporter,
--- and is hidden for an emergency because line 1 is already them.
local HEADER_X = 8
local HEADER_Y = { 6, 25 }          -- matches votetitle / votewho in make_scenes
local headerFaces = { subject = -1, caller = -1 }

--- Voter beans for the results screen: one per player who voted, re-positioned
--- beside whichever candidate they chose.
---
--- Ten is the whole population, so this pool can never run short however the
--- votes fall — each player votes exactly once.
local VOTER_MAX = 10
local VOTER_X = 156                 -- just right of a column-1 row (32 + 122)
local VOTER_PITCH = 16
local voterFaces = {}

--- One idle crew bean, parked off to the side and hidden. Every face on the vote
--- screen is one of these; they are only ever moved, re-tinted and shown.
local function createFace()
    local id = Sprite.Create("crew")
    if id < 0 then return -1 end
    Sprite.PlayAnim(id, "idle")
    Sprite.SetIgnoreViewOffset(id, true)         -- these are UI, not world
    Sprite.SetLayer(id, LAYER.HUD)
    Sprite.SetVisible(id, false)
    return id
end

local function createVoteFaces()
    if Sprite.SheetIndex("crew") < 0 then return end
    for i = 1, VOTE_ROWS do
        local id = createFace()
        if id < 0 then break end
        local col = (i - 1) >= VOTE_PER_COL and 2 or 1
        local slot = (i - 1) % VOTE_PER_COL
        Sprite.SetPos(id, VOTE_COL_X[col], VOTE_FIRST_Y + slot * VOTE_ROW_H)
        voteFaces[i] = id
    end

    headerFaces.subject = createFace()
    if headerFaces.subject >= 0 then
        Sprite.SetPos(headerFaces.subject, HEADER_X, HEADER_Y[1])
    end
    headerFaces.caller = createFace()
    if headerFaces.caller >= 0 then
        Sprite.SetPos(headerFaces.caller, HEADER_X, HEADER_Y[2])
    end

    for i = 1, VOTER_MAX do
        local id = createFace()
        if id < 0 then break end
        voterFaces[i] = id
    end
end

local function showVoteFace(i, slot)
    local id = voteFaces[i]
    if not id or id < 0 then return end
    if slot then
        tint(id, slot)
        Sprite.SetVisible(id, true)
    else
        Sprite.SetVisible(id, false)
    end
end

--- Show or hide one of the two header beans. `slot` nil hides it.
local function showHeaderFace(which, slot)
    local id = headerFaces[which]
    if not id or id < 0 then return end
    if slot and players[slot] then
        tint(id, slot)
        Sprite.SetVisible(id, true)
    else
        Sprite.SetVisible(id, false)
    end
end

local function hideVoterFaces()
    for i = 1, VOTER_MAX do
        local id = voterFaces[i]
        if id and id >= 0 then Sprite.SetVisible(id, false) end
    end
end

_G.GameHideVoteFaces = function()
    for i = 1, VOTE_ROWS do showVoteFace(i, nil) end
    showHeaderFace("subject", nil)
    showHeaderFace("caller", nil)
    hideVoterFaces()
end

--- The meeting clock, as words.
---
--- Always on screen, and in two named halves: you ARGUE and then you VOTE.
--- Rolling them into one window let the four fastest players end the round
--- before anybody had said anything, which is the opposite of the game.
local function meetingClock()
    local frames = get("meeting_timer", 0)
    local secs = (frames - frames % 60) / 60
    if get("voting_open", false) then
        return string.format("VOTING %2ds", secs)
    end
    -- The debate counts down to the START of voting, not to the end of the
    -- meeting, or the number on screen is not the one the player is waiting on.
    local left = secs - VOTE_SECONDS
    if left < 0 then left = 0 end
    return string.format("DEBATE %2ds", left)
end

--- The two header lines, and the bean beside each of them.
---
--- ALWAYS says who brought everyone to the table, whichever way it happened.
--- The button case named the caller and the body case named only the corpse, so
--- "who found it" — the single most argued-about fact in the game — was the one
--- thing the screen would not tell you. Both cases now name a person per line
--- and draw that person's bean at the head of the line, because a name is not an
--- identity to a table that has spent four minutes watching coloured beans.
local function drawMeetingHeader(reason, bySlot, bodySlot)
    local caller = players[bySlot]
    local callerName = caller and caller.name or "?"

    if reason == P.MEETING_BUTTON then
        text("votetitle", "EMERGENCY MEETING")
        text("votewho", "CALLED BY " .. callerName)
        -- Line 1 is the meeting itself and line 2 is the person, so the bean
        -- goes on line 2 with the name it belongs to.
        showHeaderFace("subject", nil)
        showHeaderFace("caller", bySlot)
    else
        local dead = players[bodySlot]
        text("votetitle", (dead and dead.name or "?") .. " FOUND DEAD")
        text("votewho", "REPORTED BY " .. callerName)
        showHeaderFace("subject", bodySlot)
        showHeaderFace("caller", bySlot)
    end
end

--- The results screen: every candidate who got a vote, with the beans of the
--- people who voted for them, and SKIP with its own.
---
--- Only six rows, because only column one is used — a voter strip needs the
--- right-hand half of the screen, so the two-column list the vote itself uses
--- cannot survive here. Five candidates plus SKIP covers every round anyone
--- will actually play: with ten voters, a sixth distinct candidate means at most
--- one vote each and a tie that ejects nobody. Sorted by votes so the ones that
--- decided the round are the ones that fit.
local RESULT_ROWS = 6
local function drawVoteResults(tally, votes)
    local ranked = {}
    for slot = 1, MAX_SLOTS do
        local n = tally[slot]
        if n and n > 0 then ranked[#ranked + 1] = { slot = slot, votes = n } end
    end
    -- Insertion sort, descending. There are at most ten of these and no
    -- `table.sort` comparator is worth the closure on a PlayStation.
    for a = 2, #ranked do
        local item = ranked[a]
        local b = a - 1
        while b >= 1 and ranked[b].votes < item.votes do
            ranked[b + 1] = ranked[b]
            b = b - 1
        end
        ranked[b + 1] = item
    end

    -- Who skipped. SKIP is always shown, even when nobody chose it: it is a
    -- real option and its emptiness is information.
    local skippers = {}
    for voter, target in pairs(votes) do
        if target == P.VOTE_SKIP then skippers[#skippers + 1] = voter end
    end

    hideVoterFaces()
    local face = 0
    local row = 0

    local function drawRow(label, r, g, b, candidateSlot, voters)
        row = row + 1
        if row > RESULT_ROWS then return end
        show(rowName(row), true)
        text(rowName(row), " " .. label)
        colourRow(rowName(row), r, g, b)
        showVoteFace(row, candidateSlot)
        local y = VOTE_FIRST_Y + (row - 1) * VOTE_ROW_H
        for i = 1, #voters do
            face = face + 1
            local id = voterFaces[face]
            if not id or id < 0 then break end
            local x = VOTER_X + (i - 1) * VOTER_PITCH
            -- Never off the right edge, however the votes piled up.
            if x + 16 > 320 then break end
            tint(id, voters[i])
            Sprite.SetPos(id, x, y)
            Sprite.SetVisible(id, true)
        end
    end

    for i = 1, #ranked do
        if row >= RESULT_ROWS - 1 then break end   -- keep the last row for SKIP
        local slot = ranked[i].slot
        local p = players[slot]
        local voters = {}
        for voter, target in pairs(votes) do
            if target == slot then voters[#voters + 1] = voter end
        end
        -- Unpacked into three locals FIRST. `voteColour` returns r, g, b, and a
        -- multi-value call anywhere but the last argument is truncated to one -
        -- so passing it inline would have handed `g` the slot and `b` the voter
        -- table, and every result row would have been drawn a shade of red.
        local r, g, b = voteColour(slot)
        drawRow(p and p.name or ("SLOT " .. slot), r, g, b, slot, voters)
    end
    drawRow("SKIP", 210, 210, 220, nil, skippers)

    for j = row + 1, ROW_COUNT do
        show(rowName(j), false)
        showVoteFace(j, nil)
    end

    if #ranked == 0 and #skippers == 0 then
        text("votehint", "NOBODY VOTED")
    else
        text("votehint", "THE VOTE")
    end
end

local function drawVote()
    -- Once the result is on screen the candidate list is gone for good; see the
    -- note in player_control.voting().
    if get("vote_results", false) then return end
    local i = 1
    for slot = 1, MAX_SLOTS do
        local p = players[slot]
        if p and p.alive then
            local mark = (get("vote_cursor", 1) == i) and ">" or " "
            show(rowName(i), true)
            text(rowName(i), mark .. p.name)
            colourRow(rowName(i), voteColour(slot))
            showVoteFace(i, slot)
            i = i + 1
        end
    end
    -- Skip is always last and always available: a meeting with no evidence must
    -- not force an ejection. It gets no face, because it is not a person.
    local mark = (get("vote_cursor", 1) == i) and ">" or " "
    show(rowName(i), true)
    text(rowName(i), mark .. "SKIP")
    colourRow(rowName(i), 210, 210, 220)
    showVoteFace(i, nil)
    set("vote_options", i)
    for j = i + 1, ROW_COUNT do
        show(rowName(j), false)
        showVoteFace(j, nil)
    end

    -- One line carrying the clock and whatever else is true right now, in
    -- descending order of what the player needs to know.
    if not get("alive", true) then
        text("votehint", meetingClock() .. "   GHOSTS DO NOT VOTE")
    elseif get("has_voted", false) then
        text("votehint", meetingClock() .. "   VOTE CAST")
    elseif get("voting_open", false) then
        text("votehint", meetingClock() .. "   X TO VOTE")
    else
        text("votehint", meetingClock() .. "   TALK IT OVER")
    end
end

_G.GameDrawVote = drawVote

--- Which slot the vote cursor is on (or VOTE_SKIP). Rebuilt from the same walk
--- as drawVote, so the list the player sees and the slot that gets sent cannot
--- drift apart.
_G.GameVoteTargetAt = function(index)
    local i = 1
    for slot = 1, MAX_SLOTS do
        local p = players[slot]
        if p and p.alive then
            if i == index then return slot end
            i = i + 1
        end
    end
    return P.VOTE_SKIP
end

-- === server messages =====================================================

local function buildHandlers()
    local h = {}

    h[P.S2C.IMPOSTOR_LIST] = function(body)
        -- Receiving this AT ALL means we are an impostor - the server sends it
        -- to nobody else. There is deliberately no role check here; see the note
        -- on `fellowImpostors`.
        local slots = P.parseImpostorList(body)
        local mySlot = get("my_slot", -1)
        -- Rebuilt from nothing every time, because this is re-sent after a scene
        -- reload (REQUEST_STATE) and a marker still bound to an actor from
        -- before that reload points at whoever now occupies the handle.
        clearImpostorMarks()
        for i = 1, #slots do
            -- Our own slot is in the list (it makes the message identical for
            -- every impostor, so the server serialises it once). We do not need
            -- an arrow pointing at ourselves.
            if slots[i] ~= mySlot then fellowImpostors[slots[i]] = true end
        end
        refreshImpostorMarks()
        applyVisibility()
    end

    h[P.S2C.ROLE_ASSIGNED] = function(body)
        local role, impostors = P.parseRoleAssigned(body)
        set("role", role)
        set("impostor_count", impostors)
        set("alive", true)
        set("phase", PHASE.PLAYING)
        -- A new round starts with everyone alive and visible again.
        for slot = 1, MAX_SLOTS do
            if players[slot] then players[slot].alive = true end
        end
        applyGhostVisibility()
        -- Learning our role can change whether the lights blind us.
        applySabotageEffect()
        drawHud()
    end

    h[P.S2C.TASK_LIST] = function(body)
        local ids = P.parseTaskList(body)
        -- Persist cannot hold a table, so the task list is flattened into keyed
        -- entries that player_control.lua reads back one at a time.
        set("task_count", #ids)
        for i = 1, #ids do set("task_" .. i, ids[i]) end
        GameRefreshTaskMarkers()
        drawHud()
    end

    h[P.S2C.TASK_PROGRESS] = function(body)
        local done, total = P.parseTaskProgress(body)
        set("tasks_done", done)
        set("tasks_total", total)
        drawHud()
    end

    h[P.S2C.PLAYER_DIED] = function(body)
        local slot = P.u8(body, 1)
        -- A murder, confirmed by the server — so this is where `kill` belongs,
        -- not on the impostor's button press, which the server turns down for
        -- cooldown or range and which used to make the sound anyway.
        --
        -- But NOT for everyone. There is no positional audio here, so a kill
        -- sting heard ship-wide would tell every crewmate the instant a murder
        -- happened, which is most of what they are supposed to be working out
        -- for themselves. Only the two people who already know get to hear it:
        -- the victim, and the impostor who did it.
        if Sfx and (slot == get("my_slot", -1)
                    or get("role", P.ROLE.CREW) == P.ROLE.IMPOSTOR) then
            Sfx("kill")
        end
        -- Create the roster entry if ROOM_STATE has not arrived yet: otherwise the
        -- death is forgotten and the ghost stays visible to everyone.
        players[slot] = players[slot] or { name = "?", alive = true }
        players[slot].alive = false
        if slot == get("my_slot", -1) then
            set("alive", false)
            -- Being murdered mid-task ends the task. A ghost can come back and
            -- redo it; finishing one from beyond the grave because the panel
            -- happened to still be open would not be a fair completion.
            if GameTaskAbort then GameTaskAbort() end
        end
        -- Leave a body where they fell. The corpse is a separate sprite AND a
        -- remembered position: a ghost keeps walking, so reading the position
        -- back off the player's actor would drag the body around after them —
        -- and a ghost would forever be standing on their own corpse.
        local actor = avatars[slot]
        if actor and not bodies[slot] then
            local bx, bz = apos(actor)
            if bx then
                local id = Sprite.Create("crew")
                if id >= 0 then
                    Sprite.PlayAnim(id, "dead")
                    tint(id, slot)
                    Sprite.SetPos(id, bx, bz)      -- SetPos wants plain numbers
                    Sprite.SetLayer(id, LAYER.BODY) -- under the living
                    bodies[slot] = { id = id, x = bx, z = bz }
                end
            end
        end
        applyGhostVisibility()
        drawHud()
    end

    h[P.S2C.PLAYER_VENT] = function(body)
        local slot, isVented = P.parsePlayerVent(body)
        vented[slot] = isVented or nil
        applyGhostVisibility()
    end

    h[P.S2C.MEETING_START] = function(body)
        local reason, bySlot, bodySlot = P.parseMeetingStart(body)
        -- The table is its own moment and the bell has to be audible over it.
        -- If the sabotage somehow outlives the meeting, SABOTAGE_TICK re-arms
        -- the klaxon on the way back to PLAYING.
        stopAlarm()
        -- Two ways to reach the table, and they deserve different sounds: a
        -- corpse was found, or somebody hit the button. `body` finally means
        -- what its description says here — it was previously firing on every
        -- death, which is neither a discovery nor something the room knows
        -- about yet. One sound, not both: two stings at once on the SPU is mud.
        if Sfx then
            Sfx(reason == P.MEETING_REPORT and "body" or "meeting")
        end
        set("phase", PHASE.MEETING)
        set("has_voted", false)
        set("vote_cursor", 1)
        -- Assume the debate has just begun rather than showing a stale clock for
        -- the second before the server's first tick lands.
        set("voting_open", false)
        set("meeting_timer", 50 * 60)

        -- Whatever anyone was doing, the table outranks it. Closed here rather
        -- than only in player_control so a panel is gone the instant the meeting
        -- lands, not one frame later underneath the vote screen.
        if GameTaskAbort then GameTaskAbort() end

        -- The server pulls everyone out of their vents for a meeting and
        -- broadcasts each one, but clear locally too: a single dropped broadcast
        -- would otherwise leave somebody invisible for the rest of the round.
        vented = {}
        set("in_vent", false)

        -- EVERYONE GOES BACK TO SPAWN. A meeting is the whole table gathering,
        -- and without this the round resumes with every player standing exactly
        -- where the vote found them — which hands out free information (who was
        -- next to the body) and lets an impostor resume a kill they had already
        -- lined up. Only our OWN avatar is ours to move; avatars are
        -- client-authoritative, so each console does its own and the moves
        -- replicate outward like any other.
        do
            local mySlot = get("my_slot", -1)
            local me = avatars[mySlot]
            local sx, sz = GameObjectPos("spawn", mySlot)
            if me and sx then
                local pos = Actor.GetPosition(me)
                Actor.SetPosition(me, Vec3.new(sx, pos and pos.y or 0, sz))
            end
        end

        applyGhostVisibility()

        -- Bodies are cleared by a meeting: they have been reported, and leaving
        -- them lying around would let the same corpse be reported forever.
        for slot, b in pairs(bodies) do
            Sprite.Destroy(b.id)
            bodies[slot] = nil
        end

        if canvas >= 0 then UI.SetCanvasVisible(canvas, false) end
        showChrome(false)
        if voteCanvas >= 0 then UI.SetCanvasVisible(voteCanvas, true) end

        -- A fresh meeting: the previous round's result is gone and the candidate
        -- list is live again.
        set("vote_results", false)
        hideVoterFaces()
        drawMeetingHeader(reason, bySlot, bodySlot)
        drawVote()
    end

    h[P.S2C.VOTE_TALLY] = function(body)
        local tally, votes = P.parseVoteTally(body)
        -- The candidate list becomes the RESULT: each candidate with the beans
        -- of everyone who voted for them, SKIP included. It used to be one line
        -- of "name:2 name:1" under the list, which said what the counts were and
        -- never who cast them - and who voted with whom is what the next body is
        -- argued over.
        set("vote_results", true)
        drawVoteResults(tally, votes)
    end

    h[P.S2C.EJECTED] = function(body)
        local slot, wasImpostor = P.parseEjected(body)
        if Sfx then Sfx("eject") end
        set("phase", PHASE.PLAYING)

        if slot == P.NOBODY then
            text("votetitle", "NOBODY WAS EJECTED")
            text("votewho", "")
            showHeaderFace("subject", nil)
            showHeaderFace("caller", nil)
        else
            players[slot] = players[slot] or { name = "?", alive = true }
            players[slot].alive = false
            if slot == get("my_slot", -1) then set("alive", false) end
            applyGhostVisibility()
            local name = players[slot] and players[slot].name or "?"
            -- Announcing whether they were right is the information the whole
            -- game runs on, and the server is the only thing that knows it.
            --
            -- Across TWO lines, and that is a width constraint rather than a
            -- preference: "<12 chars> WAS NOT THE IMPOSTOR" is 33 characters
            -- against a header that now holds about 28, so as one string the
            -- verdict ran off the side of the television.
            text("votetitle", name .. " WAS EJECTED")
            text("votewho", wasImpostor and "THEY WERE THE IMPOSTOR"
                                         or "THEY WERE NOT THE IMPOSTOR")
            -- The bean moves to whoever just went out of the airlock; line 2 is
            -- a verdict now, not a person, so its bean goes.
            showHeaderFace("subject", slot)
            showHeaderFace("caller", nil)
        end

        -- Leave the result up for a moment; player_control.lua closes the vote
        -- canvas once the player presses on, since a scene script has no timer.
        set("vote_result_shown", true)
        drawHud()
    end

    h[P.S2C.SABOTAGE_START] = function(body)
        local kind, frames = P.parseSabotageStart(body)
        -- One sting for everyone, whatever the kind: this is the moment the
        -- ship learns something is wrong. The looping klaxon on top of it is
        -- reactor-only, and startAlarm decides that.
        if Sfx then Sfx("sabotage") end
        startAlarm(kind)
        set("sabotage_active", true)
        set("sabotage_kind", kind)
        set("sabotage_timer", frames)
        applySabotageEffect()
        drawHud()
    end

    h[P.S2C.SABOTAGE_END] = function(body)
        stopAlarm()
        -- The all-clear, for EVERYONE. Until now `fix` was played locally by
        -- whoever pressed the fix station, so to the rest of the ship a
        -- sabotage simply stopped mattering at some unannounced moment — and
        -- with the reactor that is the difference between losing and not.
        if Sfx then Sfx("fix") end
        set("sabotage_active", false)
        set("sabotage_timer", 0)
        applySabotageEffect()
        drawHud()
    end

    h[P.S2C.GAME_OVER] = function(body)
        local winner, reason = P.parseGameOver(body)
        -- Before the win/lose sting, not after: a reactor that ran out is the
        -- most likely way for the round to end WITH the klaxon still going, and
        -- that is exactly the case where it must not sing over the result.
        stopAlarm()
        set("phase", PHASE.OVER)
        set("winner", winner)
        set("over_reason", reason)
        if Sfx then
            local mine = (winner == P.WINNER.IMPOSTORS)
                == (get("role", P.ROLE.CREW) == P.ROLE.IMPOSTOR)
            Sfx(mine and "win" or "lose")
        end
        if GameTaskAbort then GameTaskAbort() end
        GameHideIndicators()
        -- Everything else off. The end of a round is the one moment the game
        -- should be saying exactly one thing, and a HUD showing a task counter
        -- for a round that is finished is noise on top of it.
        if voteCanvas >= 0 then UI.SetCanvasVisible(voteCanvas, false) end
        if canvas >= 0 then UI.SetCanvasVisible(canvas, false) end
        showChrome(false)
        GameHideVoteFaces()
        drawOver()
    end

    -- The room roster still arrives in-game: players leave mid-round, and the
    -- vote screen has to name them.
    h[P.S2C.COOLDOWN_TICK] = function(body)
        -- Straight to state; player_control reads it when it builds the prompt
        -- bar, which is where a player is already looking to find out what the
        -- buttons do.
        local kill, meeting, left = P.parseCooldownTick(body)
        set("kill_cd", kill)
        set("meeting_cd", meeting)
        set("meetings_left", left)
    end

    h[P.S2C.SABOTAGE_TICK] = function(body)
        -- The server's authoritative countdown. The console only ever displays
        -- this; GameTickSabotage smooths between resyncs so the number does not
        -- visibly step once a second.
        set("sabotage_timer", P.parseSabotageTick(body))
        -- Re-arm the klaxon if it is missing but ought to be sounding. It is a
        -- resync message, so let it resync the siren too: the voice can be lost
        -- to a meeting (stopped above) or simply stolen, because play() takes
        -- the next FREE SPU channel and a busy moment will recycle the oldest
        -- one out from under a loop that was meant to be permanent.
        if get("sabotage_active", false)
            and get("phase", PHASE.PLAYING) == PHASE.PLAYING
            and alarmVoice < 0 then
            startAlarm(get("sabotage_kind", 0))
        end
        drawHud()
    end

    h[P.S2C.RETURN_LOBBY] = function(body)
        -- The owner pressed on. Everyone goes back to the SAME room, together.
        --
        -- Persistence stays on: it is what carries the session (and therefore
        -- the slot, and therefore the room membership) across `Scene.Load`,
        -- which tears the whole Lua state down. Turning it off here would take
        -- the room down with it and land ten players in an empty lobby.
        Net.SetPersistent(true)
        Scene.Load(P.SCENE.LOBBY)
    end

    h[P.S2C.MEETING_TICK] = function(body)
        local open, frames = P.parseMeetingTick(body)
        set("voting_open", open)
        set("meeting_timer", frames)
        if get("phase", PHASE.PLAYING) == PHASE.MEETING then drawVote() end
    end

    h[P.S2C.MEETING_END] = function(body)
        -- The meeting is over for EVERYONE at the same moment. This used to be a
        -- button press per console, which meant players rejoined the round at
        -- different times and anyone who pressed nothing sat at the table for the
        -- rest of the game.
        set("phase", PHASE.PLAYING)
        GameCloseVote()
    end

    h[P.S2C.ROOM_STATE] = function(body)
        local owner, list = P.parseRoomState(body)
        -- Who owns the room follows us into the round, because the game-over
        -- screen needs it: only the owner can start the next one. The server
        -- hands ownership on when an owner leaves, so this is re-read from every
        -- roster rather than remembered from the lobby.
        set("is_owner", owner == get("my_slot", -1))
        local seen = {}
        for i = 1, #list do
            local p = list[i]
            seen[p.slot] = true
            local known = players[p.slot]
            if known then
                known.name = p.name
            else
                -- A slot we have never heard of takes the roster's word for
                -- whether it is alive. Assuming `true` here (as this used to)
                -- resurrected the dead: a roster arriving mid-round listed
                -- corpses as living, so they became votable and killable again.
                -- The server sources the flag from the match precisely so this
                -- can be trusted.
                players[p.slot] = { name = p.name, alive = p.alive }
            end
        end
        for slot = 1, MAX_SLOTS do
            if not seen[slot] then players[slot] = nil end
        end
        -- We asked for this (see askForRoster) and it arrived, so stop asking.
        -- The latch is cleared HERE rather than where the request is sent: the
        -- request being accepted by the link says nothing about the answer ever
        -- coming back, and one lost reply used to mean no roster for the whole
        -- round — no names in the vote, and no killable targets for an impostor.
        set("roster_ok", true)
        -- The roster just changed who exists, so re-apply who we can see.
        applyGhostVisibility()
        drawHud()
    end

    return h
end

local function ready()
    if handlers then return true end
    P = PSXSUS
    if not P then
        Debug.Log("PSXSUS game: psxsus_protocol.lua is missing or attached AFTER game.lua")
        return false
    end
    handlers = buildHandlers()
    return true
end

-- === authoring self-check ================================================
--
-- Every asset this scene needs is looked up BY NAME, and a name that is not
-- there returns -1 and then silently does nothing. That failure mode has cost
-- more time on this project than any actual bug: arrows, interact rings, task
-- panels and the lights-out overlay were all simply absent for two sessions
-- because the sheets had never been created in Unity, and nothing anywhere said
-- so.
--
-- `Debug.Log` is not a fix. On a retail PlayStation it writes to the BIOS TTY,
-- which does not exist — so the log a developer would check is only visible in
-- the emulator, and the console shows nothing at all. This puts the answer ON
-- SCREEN, where the person holding the pad can read it.

local missing = {}

--- Is there actually a clip on the disc under this name?
---
--- `Audio.Play` answers -1 for a name it cannot find and then does nothing —
--- silently, like every other by-name lookup in this engine. That is why a disc
--- with the sounds sitting in SPU RAM can still be completely silent: the ADPCM
--- uploads by INDEX (SceneManager::uploadSpuData) while Lua asks by NAME
--- (findAudioClipByName over m_audioClipNames), and those are two different
--- tables. If the name table did not survive the splashpack, every clip is
--- present, addressable by index, and unreachable from here.
---
--- So this is checked and REPORTED rather than assumed, on the same status line
--- as the missing sheets. "No sound" and "no clip called `step`" need completely
--- different fixes, and nothing on a retail console could tell them apart.
local function needAudio(name)
    if not (Audio and Audio.Find) then
        missing[#missing + 1] = "audio:api"
        return
    end
    local id = Audio.Find(name)
    if id == nil or id < 0 then missing[#missing + 1] = "clip:" .. name end
end

local function needSheet(name)
    if Sprite.SheetIndex(name) < 0 then missing[#missing + 1] = "sheet:" .. name end
end

local function needElement(name)
    local h = ui[name]
    if not h or h < 0 then missing[#missing + 1] = "text:" .. name end
end

local function selfCheck()
    missing = {}
    -- `crew` is the only genuinely fatal one: without it nobody is drawn at all.
    for _, s in ipairs({ "crew", "arrow", "ui", "taskui", "mask" }) do needSheet(s) end
    -- One clip, not all twenty-one. If the name table made it onto the disc at
    -- all then every name did; if it did not, one report says so and twenty
    -- would push everything else off the line.
    needAudio("step")
    if canvas < 0 then missing[#missing + 1] = "canvas:hud" end
    if voteCanvas < 0 then missing[#missing + 1] = "canvas:vote" end
    if overCanvas < 0 then missing[#missing + 1] = "canvas:over" end
    if UI.FindCanvas("prompt") < 0 then missing[#missing + 1] = "canvas:prompt" end
    -- The task canvas carries EVERY piece of all five minigame panels now, not
    -- just two captions. Without it the games still play - every handle is -1
    -- and every setter no-ops - but they play completely blind, which is worth
    -- saying on the one channel a retail console has.
    if UI.FindCanvas("task") < 0 then missing[#missing + 1] = "canvas:task" end
    for _, n in ipairs({ "role", "status", "tasks", "overtitle" }) do needElement(n) end

    -- No tilemap means no level: no walls, no collision, no task stations, and a
    -- black screen with a working HUD floating on it. That reads as "the game is
    -- broken" when it is actually "the map was never painted", and the two need
    -- completely different responses. See UPGRADING.md.
    if not (Tile and Tile.Active and Tile.Active()) then
        missing[#missing + 1] = "tilemap"
    end

    if #missing == 0 then return end

    -- Log every one (useful under Redux), then show as many as fit on the status
    -- line (the only channel a real console has).
    for i = 1, #missing do
        Debug.Log("PSXSUS: MISSING " .. missing[i] .. " - see UNITY_SETUP.md")
    end
    local s = "MISSING: " .. missing[1]
    for i = 2, #missing do
        local next_ = s .. " " .. missing[i]
        if #next_ > 38 then s = s .. " +" .. (#missing - i + 1); break end
        s = next_
    end
    -- LATCHED, not printed once.
    --
    -- This used to be a bare `text("status", ...)` at the end of scene setup —
    -- and `drawHud` runs on a 2Hz clock and blanks that same line whenever the
    -- game has nothing to say. So the one message that names every missing asset
    -- was on screen for under half a second, before a player could possibly be
    -- looking, and then gone for the rest of the round.
    --
    -- Which made every missing-asset failure look identical to a working game
    -- that simply had no sound, or no arrows, or no map. The report is the whole
    -- point of the check; it has to outlive the next redraw.
    set("selfcheck", s)
    text("status", s)
end

-- === scene lifecycle =====================================================

function onSceneCreationStart()
    -- The lobby set persistence before loading us, so the session survived
    -- clearScene(). Re-Hello to reclaim the SAME slot and tell the server which
    -- scene we are now in — the server groups snapshots per scene, so this is
    -- what makes us visible to the players who have already arrived.
    Net.Connect()

    -- This scene DOES have an avatar, so turn replication back on explicitly. The
    -- flag survives the scene change (it is session state, not scene state), and
    -- the lobby turned it off — without this the game would silently never
    -- broadcast a position and every player would look frozen to everyone else.
    if Net.SetReplicationEnabled then Net.SetReplicationEnabled(true) end
end

function onSceneCreationEnd()
    if not ready() then return end

    canvas = UI.FindCanvas("hud")
    voteCanvas = UI.FindCanvas("vote")
    overCanvas = UI.FindCanvas("over")
    if canvas < 0 then Debug.Log("PSXSUS game: no canvas named 'hud' - the whole HUD will be blank") end
    if voteCanvas < 0 then Debug.Log("PSXSUS game: no canvas named 'vote' - the vote screen will be blank") end
    if overCanvas < 0 then Debug.Log("PSXSUS game: no canvas named 'over' - the round will end with no explanation") end
    if overCanvas >= 0 then UI.SetCanvasVisible(overCanvas, false) end

    -- Name each element that could not be found, in either canvas, so a blank HUD
    -- reads as an actionable list in the logs instead of silence. drawHud/drawVote
    -- no-op on a missing element, so without this an unnamed element looks exactly
    -- like a working one that happens to have no text yet.
    for _, name in ipairs({ "role", "status", "tasks", "votetitle", "votewho",
                            "votehint", "overtitle", "over1", "over2", "over3",
                            "over4", "overwait" }) do
        ui[name] = canvas >= 0 and UI.FindElement(canvas, name) or -1
        for _, c in ipairs({ voteCanvas, overCanvas }) do
            if ui[name] < 0 and c >= 0 then ui[name] = UI.FindElement(c, name) end
        end
        if not ui[name] or ui[name] < 0 then
            Debug.Log("PSXSUS game: no text element named '" .. name .. "' in the 'hud', 'vote' or 'over' canvas")
        end
    end
    for i = 1, ROW_COUNT do
        ui[rowName(i)] = voteCanvas >= 0 and UI.FindElement(voteCanvas, rowName(i)) or -1
    end
    if canvas >= 0 then UI.SetCanvasVisible(canvas, true) end
    if voteCanvas >= 0 then UI.SetCanvasVisible(voteCanvas, false) end

    local mySlot = Net.LocalSlot()
    set("my_slot", mySlot)
    set("phase", PHASE.PLAYING)
    set("alive", true)

    -- One authored actor per slot. Slot 0 is the server and has no avatar, which
    -- is why these are player_1..player_10 and why c_maxSlots is 11.
    for slot = 1, MAX_SLOTS do
        local actor = Actor.Find("player_" .. slot)
        avatars[slot] = actor
        if actor then
            if slot == mySlot then
                -- Our transform is ours to report; the engine replicates it.
                Net.SetLocalAvatar(actor)
            else
                -- ...and everyone else's is applied for us.
                Net.SetRemoteAvatar(slot, actor)
            end

            local id = Sprite.Create("crew")
            if id >= 0 then
                -- Screen plane: the actor's X/Z is the 2D ground plane, so a
                -- bound sprite follows a replicated actor for free. This is why
                -- the sprite system needed no networking of its own.
                Sprite.BindToActor(id, actor, 0, -8, -12)
                Sprite.PlayAnim(id, "idle")
                Sprite.SetLayer(id, LAYER.CREW)
                tint(id, slot)
                sprites[slot] = id
            end
        end
    end

    -- The avatars exist now. If IMPOSTOR_LIST already landed (it rides the
    -- reliable channel and this runs during scene setup, so either order is
    -- possible) its markers had nothing to bind to; bind them.
    refreshImpostorMarks()

    -- Index the tilemap's task/vent/fix/emergency/spawn tiles (empty if the scene
    -- uses authored actors instead).
    buildObjectIndex()
    GameInvalidateObjectPos()

    -- If the map has a spawn tile for our slot, start there. Only our own avatar
    -- is ours to move (client-authoritative), so each client places itself — which
    -- is exactly what stops everyone piling up on one authored point.
    do
        local sx, sz = GameObjectPos("spawn", mySlot)
        local me = avatars[mySlot]
        if sx and me then Actor.SetPosition(me, Vec3.new(sx, Actor.GetPosition(me).y, sz)) end
    end

    -- With a tilemap the task/vent/etc. graphics are drawn as tiles, so the actor
    -- prop sprites would be duplicates. Only spawn them for the old actor-authored
    -- scenes.
    if not (Tile and Tile.Active and Tile.Active()) then spawnProps() end
    -- Created after the avatars so the arrows land on later pool slots and end up
    -- drawn over them; layer decides the real order, but this keeps it obvious.
    createIndicators()
    createTaskMarkers()
    createVision()
    createOverPlates()
    createVoteFaces()
    -- Chrome BEFORE the prompt bar's glyphs, so the plate ends up on a lower
    -- sprite id than the icons that sit on it. Layer decides the real order, but
    -- keeping the creation order and the draw order agreeing is one less thing
    -- to be surprised by.
    createPlates()
    P.initPrompts("prompt")
    -- Optional: a scene without task_minigames.lua attached still plays, with
    -- stations falling back to the old single-press completion.
    if GameTaskUiInit then GameTaskUiInit() end
    applyGhostVisibility()
    drawHud()
    -- Last, so it has the final word on the status line: if anything is missing,
    -- saying so beats whatever drawHud just wrote there.
    selfCheck()
end

--- One sprite per authored map object, bound to its actor.
---
--- The props sheet is NOT tinted (no SetColor), so it keeps its own colours —
--- unlike the crew, which is drawn grey precisely so it can be.
---
--- Missing props are skipped silently: a scene without vents is a legitimate
--- scene, and this must not be the thing that stops it loading.
function spawnProps()
    local sheet = Sprite.SheetIndex("props")
    if sheet < 0 then return end   -- no props sheet authored; crew still works

    local function place(name, anim, layer)
        local actor = Actor.Find(name)
        if not actor then return end
        local id = Sprite.Create("props")
        if id < 0 then return end  -- pool full; the game is still playable
        Sprite.BindToActor(id, actor, 0, -8, -8)
        Sprite.PlayAnim(id, anim)
        Sprite.SetLayer(id, layer)
        props[#props + 1] = id
    end

    -- Layer 4 is behind the crew (layer 2) and the bodies (layer 3): a player
    -- must never disappear behind the console they are standing at.
    for i = 1, 12 do place("task_" .. i, "task", LAYER.PROP) end
    for i = 1, 8 do place("vent_" .. i, "vent", LAYER.PROP) end
    for kind = 0, 3 do place("fix_" .. kind, "fix", LAYER.PROP) end
    place("emergency", "emergency", LAYER.PROP)
end

function onNetData(payload)
    if not ready() then return end
    local subtype, body = P.decode(payload)
    if not subtype then return end
    local h = handlers[subtype]
    if h then h(body) end
end

-- === exposed to player_control.lua =======================================

_G.GameSpriteFor = function(slot) return sprites[slot] end
_G.GameAvatarFor = function(slot) return avatars[slot] end
_G.GamePlayerName = function(slot)
    local p = players[slot]
    return p and p.name or "?"
end
_G.GamePlayerAlive = function(slot)
    local p = players[slot]
    return p ~= nil and p.alive
end

--- Nearest living player to (x, z), excluding `exclude`, within `maxDist`.
--- Returns slot or nil. Distances are squared to avoid a square root — there is
--- no math library on the console anyway.
_G.GameNearestPlayer = function(x, z, exclude, maxDist)
    local best, bestD = nil, maxDist * maxDist
    for slot = 1, MAX_SLOTS do
        local actor = avatars[slot]
        if actor and slot ~= exclude and _G.GamePlayerAlive(slot) then
            local ax, az = apos(actor)
            if ax then
                local dx, dz = ax - x, az - z
                local d = dx * dx + dz * dz
                if d < bestD then best, bestD = slot, d end
            end
        end
    end
    return best
end

--- Nearest body, same rules. Bodies are what a meeting is started from.
--- Uses the position the body was LEFT at, not the dead player's actor: a ghost
--- walks, and a corpse does not follow them.
_G.GameNearestBody = function(x, z, maxDist)
    local best, bestD = nil, maxDist * maxDist
    for slot, b in pairs(bodies) do
        local dx, dz = b.x - x, b.z - z
        local d = dx * dx + dz * dz
        if d < bestD then best, bestD = slot, d end
    end
    return best
end

--- Where a corpse is lying. The position it was LEFT at, not the dead player's
--- actor — a ghost walks away from their own body.
_G.GameBodyPos = function(slot)
    local b = bodies[slot]
    if b then return b.x, b.z end
    return nil
end

_G.GameCloseVote = function()
    GameHideVoteFaces()
    if voteCanvas >= 0 then UI.SetCanvasVisible(voteCanvas, false) end
    if canvas >= 0 then UI.SetCanvasVisible(canvas, true) end
    showChrome(true)
    set("vote_result_shown", false)
    -- The meeting hid them along with every other indicator; back to the map
    -- means back to being shown which stations are still yours.
    GameRefreshTaskMarkers()
    drawHud()
end

--- Advance the DISPLAYED sabotage countdown by `dt` raw dt units.
---
--- This is a display smoother, not a clock. The server owns the real doomsday
--- timer (ROOM_PROTOCOL.md: "the server owns sabotage timers, a client never
--- decides") and resyncs this value with SabotageTick roughly once a second; all
--- this does is fill in the gaps so the number counts down smoothly instead of
--- stepping once per second.
---
--- It used to be the console's own independent countdown, and it could not be
--- made correct. Two clocks started equal and drifted apart in OPPOSITE
--- directions: the console's `dt` is deliberately clamped after a hitch
--- (SceneManager::GameTick) so it permanently loses real time, while the server
--- used to drop whole ticks under load. The HUD would read 20s as the reactor
--- blew, or sit at 0 while nothing happened. It was also simply wrong by a
--- factor of two — `dt / 4096` counts 30Hz frames while this timer is in 60Hz
--- frames, so 45 seconds took 90.
---
--- 4096 raw units == one 30Hz frame == TWO 60Hz frames, hence dt / 2048.
--- Advance the DISPLAYED meeting countdown between the server's resyncs.
---
--- Exactly the same job, and the same caveats, as GameTickSabotage: the server
--- owns the real clock and says so once a second, and this only fills the gaps
--- so the number counts down instead of stepping once per second. It must never
--- be the console's own timer — see the long note below.
---
--- 4096 raw dt units == one 30Hz frame == TWO 60Hz frames, and the meeting timer
--- is in 60Hz frames, hence dt / 2048.
_G.GameTickMeeting = function(dt)
    if get("phase", PHASE.PLAYING) ~= PHASE.MEETING then return end
    local t = get("meeting_timer", 0)
    if t <= 0 then return end
    local elapsed = (dt - dt % 2048) / 2048
    if elapsed <= 0 then return end
    t = t - elapsed
    if t < 0 then t = 0 end
    set("meeting_timer", t)
    drawVote()
end

_G.GameTickSabotage = function(dt)
    if not get("sabotage_active", false) then return end
    local t = get("sabotage_timer", 0)
    if t <= 0 then return end
    local elapsed = (dt - dt % 2048) / 2048     -- integer division; no floats
    if elapsed <= 0 then return end
    t = t - elapsed
    if t < 0 then t = 0 end
    set("sabotage_timer", t)
    drawHud()
end
