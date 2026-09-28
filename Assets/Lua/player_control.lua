-- PSXSUS — the local player.
--
-- Attach to ANY one object in the GAME scene, after game.lua. It is the only
-- per-frame code in the scene, because scene scripts get no onUpdate: movement,
-- the camera, the action buttons, and the clocks all run from here.
--
-- NOTE it does not move `self`. The thing that must move is the actor bound to
-- OUR slot (`player_<slot>`, the one game.lua handed to Net.SetLocalAvatar), and
-- that is almost certainly not the object this script happens to hang off. So
-- `self` is ignored and the avatar is looked up. Attaching this to a second
-- object would run everything twice — attach it once.
--
-- It moves OUR avatar and nothing else. Avatar transforms are
-- client-authoritative by design (ROOM_PROTOCOL.md): we report where we are, the
-- server relays it, and every other player's sprite follows an actor the engine
-- fills in for us. So there is no code here that moves anybody else.
--
-- Every action below is a REQUEST. Pressing kill does not kill: it asks, and the
-- server answers with PlayerDied or with silence. Never pre-empt it — a client
-- that draws the outcome it hopes for is a client that lies to its player.
--
-- Console Lua has no `math` and no `require`. See psxsus_protocol.lua.

local P = nil

-- World units are screen pixels for a screen-plane sprite, so these are pixels
-- per frame in 12.12 fixed point terms the engine understands.
local SPEED = 2
local USE_RANGE = 24        -- how close to a station/vent/body to interact
local KILL_RANGE = 20

-- Movement is accumulated in SUB-PIXELS and spent in whole ones.
--
-- Two things force this. `Tile.MoveActor` takes INTEGER pixel deltas (it is a
-- `static_cast<int32_t>` on the way in), and SPEED is 2 — so the obvious way to
-- fix diagonal speed, scaling each axis by 0.707, truncates 2 to 1. That is a
-- 50% cut where 29% was wanted, and it would have made diagonals SLOWER than
-- the cardinals they were meant to match.
--
-- Carrying the remainder between frames is what makes the average come out
-- right: a diagonal spends 1.41 pixels per frame as an alternating 1,2,1,1,2...
local SUB = 256
local SPEED_SUB = SPEED * SUB
--- SPEED_SUB / sqrt(2), rounded. Written as a literal because there is no
--- `math` on the console to compute it with.
local SPEED_DIAG_SUB = 362
local moveSubX, moveSubZ = 0, 0

--- Deflection past which the analog stick counts as pushed.
---
--- Full deflection reads as 4096 (luaapi scales the pad's ±127 by 4096/127), so
--- this is about a quarter of the way over — past the slop a worn DualShock
--- rests at, and short of where a player thinks they are pushing it.
local STICK_DEADZONE = 1024

--- Length of (x, z), within about 4%, using only integer arithmetic.
---
--- alpha-max-plus-beta-min: |v| ~= max + 7/16*min. There is no `math.sqrt` on
--- the console, and an exact root is not worth a Newton loop here — 4% of a
--- 2px step is a fortieth of a pixel, far below what the accumulator above can
--- even express.
local function magnitude(x, z)
    if x < 0 then x = -x end
    if z < 0 then z = -z end
    if z > x then x, z = z, x end
    local t = x * 16 + z * 7
    return (t - t % 16) / 16
end

-- === wall-clock time =====================================================
--
-- `dt` (onUpdate's second argument) is MEASURED elapsed time in 4.12 fixed
-- point where 4096 == one 30Hz frame — see SceneManager::GameTick, which derives
-- it from gpu().now() in microseconds. It is the only real clock the console
-- exposes to Lua.
--
-- Every timer here accumulates `dt` in those RAW units and compares against a
-- threshold in the same units. Two traps this avoids:
--
--   * Counting frames instead. Frames are not a duration — the whole reason
--     this pass exists is that the frame rate is not constant, so a "half
--     second" counted in frames becomes two seconds when the console is busy,
--     which is exactly when the timer usually matters most.
--   * Converting dt to seconds first. On the console `/` is INTEGER division
--     (lua_Number is a long), so at 60fps `dt` is 2048 and `dt / 4096` is
--     **zero** — every such timer would simply stop. Staying in raw units is
--     exact and needs no floats, which the console does not have either.
local DT_SECOND = 30 * 4096   -- raw dt units in one real second

local FACING_ANIMS = 4      -- walk_0..walk_3: down, left, up, right

-- How often to redraw the HUD independently of server traffic. See onUpdate:
-- drawHud is event-driven, so without this every time-varying thing on it — the
-- link counters AND the sabotage countdown — is frozen at the last message.
local HUD_REFRESH_DT = DT_SECOND / 2   -- ~2Hz
local hudTimer = HUD_REFRESH_DT

-- Shared state lives in _G.SUS (game.lua owns it). NOT Persist: that stores one
-- `long` per key across sixteen keys and drops the rest silently, and this scene
-- needs more keys than that plus booleans and a task list.
local function get(k, d)
    local v = SUS[k]
    if v == nil then return d end
    return v
end

local function set(k, v) SUS[k] = v end

local function ready()
    if P then return true end
    P = PSXSUS
    return P ~= nil
end

local function pressed(b) return Input.IsPressedPlayer1(b) end

--- Play a sound effect by name, if the disc has one under that name.
---
--- `Audio.Play` already answers -1 for a clip it cannot find, so this is only a
--- guard against an engine build with no Audio table at all. Every name here is
--- a `ClipName` on the PFB_GameAudio prefab — that string IS the contract, and a
--- typo is a sound that silently never plays.
local function Sfx(name)
    if Audio and Audio.Play then Audio.Play(name) end
end
_G.Sfx = Sfx

-- Footsteps are on a clock rather than one per frame: a sound retriggered sixty
-- times a second is a buzz, not a footstep, and it would hold every SPU voice
-- the game has.
local STEP_PERIOD = DT_SECOND / 4
local stepWait = 0
local function held(b) return Input.IsHeldPlayer1(b) end

-- === sending =============================================================

--- Send a request, retrying it if the link refuses.
---
--- `Net.SendData` returns FALSE when the engine's reliable queue is full (it
--- holds 16), and every call site here used to ignore that — including kill and
--- vote. The binding's own comment says "CHECK IT: a dropped payload is
--- otherwise silent", and it is exactly right: a burst (a meeting starting while
--- several people finish tasks) would quietly discard someone's kill or
--- someone's vote, and the only symptom was the server appearing to disagree
--- with what the player did.
---
--- Retries are capped and ordered. Dropping the oldest on overflow is
--- deliberate: if the link is that congested, the newest intent is the one worth
--- keeping, and a stale kill request arriving ten seconds late would be worse
--- than none.
local OUTBOX_MAX = 8
local outbox = {}

local function send(payload)
    if #outbox == 0 and Net.SendData(payload) then return true end
    -- Something is already queued, or this failed: get in line. Sending out of
    -- order would let a vote overtake the meeting it belongs to.
    outbox[#outbox + 1] = payload
    if #outbox > OUTBOX_MAX then table.remove(outbox, 1) end
    return false
end

--- Exposed so task_minigames.lua's completions get the same retry treatment.
_G.GameSendRequest = function(payload) return send(payload) end

local function flushOutbox()
    while #outbox > 0 do
        if not Net.SendData(outbox[1]) then return end
        table.remove(outbox, 1)
    end
end

-- === movement ============================================================

-- Actor.GetPosition returns a Vec3 whose components are FixedPoint objects
-- (tables carrying _raw with +/- metamethods) — NOT plain numbers. They have no
-- __mul, so a distance `dx*dx` errors, and the number-only engine calls
-- (Sprite.SetViewOffset / Sprite.SetPos) reject them outright. Bound sprites sit
-- at boundActor->position.x.integer() — integer screen pixels — so read
-- positions as integer pixels here and do every calculation in plain numbers.
-- SetPosition still takes a Vec3; readFP scales a plain number by 4096, and
-- passes a FixedPoint (the y axis) through unchanged.
-- FixedPoint components carry the raw fp12 value in ._raw. Their :toNumber() /
-- :raw() METHODS exist on the metatable but are UNREACHABLE — psyqo-lua never
-- sets the metatable's __index — so `fp:toNumber()` is "call a nil value". Read
-- ._raw directly and floor to integer pixels by hand: no bit32 (the desktop test
-- runtime is Lua 5.5 without it) and on the console `/` is integer division, so
-- (r - r % 4096) / 4096 is an exact shift-right-12.
local function toPx(fp) local r = fp._raw; return (r - r % 4096) / 4096 end

--- Integer pixel X, Z of an actor, or nil.
---
--- Prefers Actor.GetPositionXZ, which returns two plain numbers and allocates
--- NOTHING. GetPosition builds four Lua tables per call (the vector plus a
--- metatable-carrying FixedPoint per component), and this is called for every
--- remote avatar every update — over a thousand short-lived tables a second,
--- collected by psyqo-lua's untuned GC on a 33MHz CPU. That was real frames.
---
--- The GetPosition path stays as a fallback so the scene still runs on an engine
--- built before the accessor existed.
local function apos(actor)
    if not actor then return nil end
    if Actor.GetPositionXZ then return Actor.GetPositionXZ(actor) end
    local p = Actor.GetPosition(actor)
    if not p then return nil end
    return toPx(p.x), toPx(p.z)
end

--- Wanted velocity this frame, in sub-pixels, from whichever control is in use.
---
--- NORMALIZED, which is the whole point: holding two directions used to add a
--- full SPEED on each axis, so every diagonal was sqrt(2) — about 41% — faster
--- than any cardinal. Players found it immediately and it made walking in
--- straight lines the wrong way to play.
local function wantedVelocity()
    -- The stick first, when there is one and it is actually pushed. On a
    -- digital pad GetAnalogPlayer1 answers 0,0 and this costs nothing.
    if Input.GetAnalogPlayer1 then
        local ax, az = Input.GetAnalogPlayer1()
        ax = ax or 0
        az = az or 0
        local m = magnitude(ax, az)
        if m >= STICK_DEADZONE then
            -- Scale to SPEED_SUB along the direction pushed. Clamped rather
            -- than proportional: this game has no walk/run, and a stick resting
            -- just past the deadzone should not creep.
            local sx = ax * SPEED_SUB
            local sz = az * SPEED_SUB
            return (sx - sx % m) / m, (sz - sz % m) / m
        end
    end

    local dx, dz = 0, 0
    if held(Input.LEFT) then dx = dx - 1 end
    if held(Input.RIGHT) then dx = dx + 1 end
    if held(Input.UP) then dz = dz - 1 end
    if held(Input.DOWN) then dz = dz + 1 end
    if dx ~= 0 and dz ~= 0 then
        -- Eight directions only, so the diagonal case is one constant rather
        -- than a division.
        return dx * SPEED_DIAG_SUB, dz * SPEED_DIAG_SUB
    end
    return dx * SPEED_SUB, dz * SPEED_SUB
end

local function move(me)
    local vx, vz = wantedVelocity()

    -- Spend the accumulator down to whole pixels, keeping the remainder for
    -- next frame. Truncation toward zero on both signs, so a player walking
    -- left and a player walking right drift at the same rate: `%` on a negative
    -- operand answers a POSITIVE remainder in Lua, which would otherwise bias
    -- every leftward step by one sub-pixel per frame.
    local dx, dz = 0, 0
    if vx ~= 0 or vz ~= 0 then
        moveSubX = moveSubX + vx
        moveSubZ = moveSubZ + vz
        dx = (moveSubX - moveSubX % SUB) / SUB
        dz = (moveSubZ - moveSubZ % SUB) / SUB
        moveSubX = moveSubX - dx * SUB
        moveSubZ = moveSubZ - dz * SUB
    else
        -- Standing still: drop the fractions so the next step off the mark is
        -- not a stored half-pixel jump in whatever direction was last held.
        moveSubX, moveSubZ = 0, 0
    end

    local slot = get("my_slot", -1)
    local id = GameSpriteFor(slot)

    -- Idle is decided by the INPUT, not by whether this particular frame spent a
    -- whole pixel. A normalized diagonal only moves on about seven frames in
    -- ten, and testing `dx == 0` here would drop the walk cycle back to standing
    -- on the other three — a player walking smoothly would flicker idle.
    if vx == 0 and vz == 0 then
        -- GameAnimFor swaps in the ghost silhouette when this slot is dead.
        if id and id >= 0 then Sprite.PlayAnim(id, GameAnimFor(slot, nil)) end
        return
    end

    if dx ~= 0 or dz ~= 0 then
        -- Collision is the ENGINE's job: Tile.MoveActor clamps the move against
        -- the tilemap's walls in native code (and applies the full move when the
        -- scene has no map). We only supply intent — there is deliberately no
        -- walkability logic in Lua.
        --
        -- A GHOST passes through them. Being dead in this game means watching
        -- and finishing your tasks, and a ghost that has to walk the corridors
        -- like the living is just a player serving a sentence.
        Tile.MoveActor(me, dx, dz, not get("alive", true))
        if stepWait <= 0 then
            stepWait = STEP_PERIOD
            Sfx("step")
        end
    end

    if id and id >= 0 then
        -- Pick the facing from the direction actually travelled. Four frames,
        -- so this is a plain quadrant test rather than SetFacingFromYaw — the
        -- player has no yaw in a top-down game, only a heading.
        local anim = "walk_down"
        if vz < 0 then anim = "walk_up" end
        if vx < 0 then anim = "walk_left" end
        if vx > 0 then anim = "walk_right" end
        -- PlayAnim does not restart an animation that is already playing, which
        -- is exactly why this can be called every frame.
        Sprite.PlayAnim(id, GameAnimFor(slot, anim))
    end
end

-- === remote players ======================================================

local MAX_SLOTS = 10

--- Everyone else's avatar is moved FOR us by the engine as snapshots land, and
--- nothing was playing their animation — so every other player slid around the
--- map in a permanent idle pose. Watch each remote avatar's position and drive
--- its walk cycle from the direction it actually moved.
---
--- The hold matters: snapshots arrive at half the frame rate (and with gaps on a
--- lossy link), so on the frames between them the delta is zero. Without holding
--- the walk for a few frames, every remote player strobes between walking and
--- standing still.
--- How long a remote keeps its walk cycle after the last movement seen, in
--- animateRemotes updates. Snapshots arrive at 30Hz with gaps on a lossy link,
--- so without a hold every remote player strobes between walking and standing.
local WALK_HOLD_UPDATES = 4
local remote = {}   -- slot -> { x, z, dir, hold }

-- How often the arrows, the interact ring and the remote walk cycles are
-- recomputed. In real time (see DT_SECOND), so they run at the same rate however
-- the frame rate wanders — a throttle counted in frames silently becomes a
-- different refresh rate on a busy console.
local GUIDANCE_PERIOD = DT_SECOND / 8    -- 8 Hz
local guidanceWait = 0
local ANIM_PERIOD = DT_SECOND / 30       -- 30 Hz, matching the snapshot rate
local animWait = 0

-- Line of sight, faster than the guidance clock and slower than the frame rate.
--
-- 15Hz because this one is GAMEPLAY, not decoration: at 8Hz a player stepping
-- out from behind a wall appears up to an eighth of a second late, which at
-- walking speed is a whole body-width of somebody standing in the open and
-- invisible. Every update reads ten positions and casts up to nine native rays,
-- which is cheap; doing it every frame would double that for no visible gain,
-- since nobody can cross a doorway in 33ms.
local SIGHT_PERIOD = DT_SECOND / 15
local sightWait = 0

--- Reads ten avatars' positions, so it is throttled too. Snapshots only arrive
--- at 30Hz anyway — polling them faster asks twice per update and learns nothing
--- the second time.
local function animateRemotes(mySlot, dt)
    animWait = animWait - dt
    if animWait > 0 then return end
    animWait = ANIM_PERIOD

    for slot = 1, MAX_SLOTS do
        if slot ~= mySlot then
            local actor = GameAvatarFor(slot)
            local id = GameSpriteFor(slot)
            if actor and id and id >= 0 then
                local x, z = apos(actor)
                if x then
                    local r = remote[slot]
                    if not r then
                        remote[slot] = { x = x, z = z, dir = "walk_down", hold = 0 }
                    else
                        local dx, dz = x - r.x, z - r.z
                        r.x, r.z = x, z
                        if dx ~= 0 or dz ~= 0 then
                            -- Dominant axis wins, same quadrant test the local
                            -- player uses; there is no yaw in a top-down game.
                            if dx < 0 then r.dir = "walk_left"
                            elseif dx > 0 then r.dir = "walk_right"
                            elseif dz < 0 then r.dir = "walk_up"
                            else r.dir = "walk_down" end
                            r.hold = WALK_HOLD_UPDATES
                        elseif r.hold > 0 then
                            r.hold = r.hold - 1
                        end
                        -- PlayAnim does not restart an animation already playing,
                        -- so this is safe to call every frame.
                        if r.hold > 0 then
                            Sprite.PlayAnim(id, GameAnimFor(slot, r.dir))
                        else
                            Sprite.PlayAnim(id, GameAnimFor(slot, nil))
                        end
                    end
                end
            end
        end
    end
end

-- The 2D camera is one global offset: every screen-plane sprite moves with it,
-- so centring on the player costs nothing per sprite.
local function camera(me)
    local px, pz = apos(me)
    if px then Sprite.SetViewOffset(px - 160, pz - 120) end
end

-- === actions =============================================================

local function nearestTask(x, z)
    -- Task stations come from the tilemap (or authored task_N actors); a station
    -- is "yours" only if the server put it on your list. GameObjectPos hides which
    -- of the two authoring styles the scene used.
    local count = get("task_count", 0)
    for i = 1, count do
        local id = get("task_" .. i, 0)
        if id > 0 and not get("task_done_" .. id, false) then
            local ax, az = GameObjectPos("task", id)
            if ax then
                local dx, dz = ax - x, az - z
                if dx * dx + dz * dz < USE_RANGE * USE_RANGE then return id end
            end
        end
    end
    return nil
end

--- What the player would interact with if they pressed X right now.
---
--- Returns `x, z, label` — the world point to ring, and what to call it on the
--- prompt bar — or nil.
---
--- Deliberately mirrors doUse's priority order: whatever this rings is what that
--- would act on. If the two ever disagree, the ring is a lie and the player will
--- press X on the wrong thing. The LABEL comes from the same walk for exactly
--- the same reason — a bar that says "TASK" while X reports a body is worse than
--- a bar that says nothing.
---
--- Labels are kept inside the ~9 characters a prompt slot holds. "EMERGENCY" is
--- ten and would be clipped, so the button is called what it does.
local function usableTarget(px, pz)
    local body = GameNearestBody(px, pz, USE_RANGE)
    if body then
        local bx, bz = GameBodyPos(body)
        if bx then return bx, bz, "REPORT" end
    end

    if get("role", P.ROLE.CREW) == P.ROLE.CREW or not get("alive", true) then
        local task = nearestTask(px, pz)
        if task then
            local tx, tz = GameObjectPos("task", task)
            return tx, tz, "TASK"
        end
    end

    if get("sabotage_active", false) then
        local kind = get("sabotage_kind", 0)
        local fx, fz = GameObjectPos("fix", kind)
        if fx then
            local dx, dz = fx - px, fz - pz
            if dx * dx + dz * dz < USE_RANGE * USE_RANGE then return fx, fz, "FIX" end
        end
    end

    local bx, bz = GameEmergencyPos()
    if bx then
        local dx, dz = bx - px, bz - pz
        if dx * dx + dz * dz < USE_RANGE * USE_RANGE then
            -- Standing AT the button is the only moment its cooldown matters,
            -- and the only moment there is room on the bar to say so. The
            -- server refuses an early press without a word, so before this the
            -- button was simply dead with no indication of why or for how long.
            local cd = get("meeting_cd", 0)
            if get("meetings_left", 1) <= 0 then
                return bx, bz, "NO MEETINGS LEFT"
            elseif cd > 0 then
                return bx, bz, "MEETING " .. cd .. "s"
            end
            return bx, bz, "MEETING"
        end
    end

    -- An impostor's vent is a usable thing too, and it is the only one of these
    -- that a crewmate must never see ringed.
    if get("role", P.ROLE.CREW) == P.ROLE.IMPOSTOR and get("alive", true) then
        local vent = GameNearestVent(px, pz, USE_RANGE)
        if vent then
            local vx, vz = GameObjectPos("vent", vent)
            -- Triangle, not X — but it still rings, because the ring means "there
            -- is something here" and the prompt bar says which button.
            return vx, vz, nil
        end
    end

    return nil
end

-- === the prompt bar ======================================================
--
-- Up to three `{ button, label }` pairs, rebuilt from what the player can
-- actually do at the position they are actually standing in. See the longer note
-- in psxsus_protocol.lua on why a prompt for an unavailable action is worse than
-- no prompt at all.
--
-- The ORDER is the priority order, because only the first three survive: the
-- thing you are standing on beats the thing you could always do. An impostor on
-- a vent next to a body sees REPORT / KILL / VENT and not the sabotage prompt,
-- which is correct — sabotage is available from anywhere and those three are not.

local promptList = {}

local function currentPrompts(px, pz, useLabel)
    -- Rebuilt in place. This runs eight times a second forever, and allocating a
    -- fresh table each time is exactly the kind of steady garbage that buried
    -- psyqo-lua's collector when the guidance clock was unthrottled.
    local n = 0
    local function add(button, label)
        if n >= 3 then return end
        n = n + 1
        local slot = promptList[n]
        if slot then
            slot[1], slot[2] = button, label
        else
            promptList[n] = { button, label }
        end
    end

    local alive = get("alive", true)
    local impostor = get("role", P.ROLE.CREW) == P.ROLE.IMPOSTOR

    if alive and get("in_vent", false) then
        add(P.BTN.DPAD, "TRAVEL")
        add(P.BTN.TRIANGLE, "CLIMB OUT")
    else
        if useLabel then add(P.BTN.CROSS, useLabel) end
        if alive and impostor then
            if px and GameNearestPlayer(px, pz, get("my_slot", -1), KILL_RANGE) then
                -- COUNT IT DOWN on the button rather than refusing in silence.
                -- The server owns the cooldown and simply ignores an early
                -- request, so pressing too soon used to be indistinguishable
                -- from pressing out of range, or from a lost packet — the one
                -- thing an impostor most needs to time, with no clock on it.
                local cd = get("kill_cd", 0)
                add(P.BTN.SQUARE, cd > 0 and ("KILL " .. cd .. "s") or "KILL")
            end
            if px and GameNearestVent(px, pz, USE_RANGE) then
                add(P.BTN.TRIANGLE, "VENT")
            end
            -- Last, and only if there is room: it is available everywhere, so it
            -- must never push out a prompt that is only available here.
            if not get("sabotage_active", false) then
                add(P.BTN.L2, "LIGHTS")
                add(P.BTN.R2, "REACTOR")
            end
        end
    end

    for i = n + 1, 3 do promptList[i] = nil end
    return n > 0 and promptList or nil
end

local function doUse(me)
    local px, pz = apos(me)
    if not px then return end

    -- A body under your feet is more urgent than a task at the same spot.
    local body = GameNearestBody(px, pz, USE_RANGE)
    if body then
        Sfx("report")
        send(P.reportBody(body))
        return
    end

    if get("role", P.ROLE.CREW) == P.ROLE.CREW or not get("alive", true) then
        local task = nearestTask(px, pz)
        if task then
            -- Opens the station's minigame; nothing is sent until it is actually
            -- finished (task_minigames.lua sends TaskComplete on success). A task
            -- that completed on one button press was the whole reason the list
            -- could be cleared by walking a lap.
            if GameTaskOpen then
                -- Note the unconditional return: if opening FAILED (a panel is
                -- somehow already up) the answer is to do nothing, not to fall
                -- through and complete the task for free. The fallback below is
                -- only for a scene with no minigame script attached at all.
                GameTaskOpen(task)
                return
            end
            set("task_done_" .. task, true)
            send(P.taskComplete(task))
            return
        end
    end

    if get("sabotage_active", false) then
        local kind = get("sabotage_kind", 0)
        -- A fix station's object id IS the sabotage kind it clears (fix_0..fix_3
        -- as actors, or a Fix tile whose Object Id is that kind).
        local fx, fz = GameObjectPos("fix", kind)
        if fx then
            local dx, dz = fx - px, fz - pz
            if dx * dx + dz * dz < USE_RANGE * USE_RANGE then
                -- O2 is the one sabotage with a puzzle on it: a code has to be
                -- entered, so it costs a crewmate real time to clear. The rest
                -- are a single press (and the REACTOR is neither — see below).
                if kind == P.SABOTAGE_KIND.OXYGEN and GameTaskOpenOxygen then
                    GameTaskOpenOxygen()
                    return    -- see the note on tasks above: never fall through
                end
                -- One press is enough for the nuisance sabotages. The REACTOR is
                -- deliberately not one of them: it needs two people at once, so a
                -- press there only registers this player as holding a panel and
                -- the server waits for a second one (see reactorHold below).
                -- Acknowledge the PRESS, not the repair. `fix` is now the
                -- ship-wide all-clear on SABOTAGE_END, so playing it here as
                -- well would double it up for whoever pressed — and on the
                -- reactor, which needs a second pair of hands before anything
                -- is fixed at all, it would be an outright lie.
                Sfx("ui_select")
                send(P.fixSabotage(kind))
                return
            end
        end
    end

    -- The emergency button is a station like any other.
    local bx, bz = GameEmergencyPos()
    if bx then
        local dx, dz = bx - px, bz - pz
        if dx * dx + dz * dz < USE_RANGE * USE_RANGE then
            Sfx("report")
            send(P.callMeeting())
        end
    end
end

local function doKill(me)
    if get("role", P.ROLE.CREW) ~= P.ROLE.IMPOSTOR then return end
    if not get("alive", true) then return end
    local px, pz = apos(me)
    if not px then return end
    local target = GameNearestPlayer(px, pz, get("my_slot", -1), KILL_RANGE)
    if target then
        -- No sound on the press: see doSabotage. The server may well say no,
        -- and PLAYER_DIED plays `kill` for the impostor when it says yes.
        -- Ask. The server checks the cooldown, the role, and whether the target
        -- is even killable; we find out via PlayerDied, or not at all.
        send(P.kill(target))
    end
end

local function doVent(me)
    if get("role", P.ROLE.CREW) ~= P.ROLE.IMPOSTOR then return end
    if not get("alive", true) then return end
    -- Leaving is always allowed, and is checked first so a player can never get
    -- stuck inside a vent (e.g. if the vent they are in stops being found).
    if get("in_vent", false) then
        send(P.ventState(false))
        set("in_vent", false)
        return
    end

    local px, pz = apos(me)
    if not px then return end
    local id = GameNearestVent(px, pz, USE_RANGE)
    if not id then return end

    -- Entering is announced, unlike the hop: everyone else has to stop drawing
    -- us. Being inside a vent is the impostor's whole escape, and a sprite that
    -- stayed on screen would defeat it.
    Sfx("vent")
    send(P.ventState(true))
    set("in_vent", true)
    set("vent_id", id)

    -- Sit exactly on the vent so leaving does not drop us a few pixels away.
    local vx, vz = GameObjectPos("vent", id)
    if vx then
        local pos = Actor.GetPosition(me)
        Actor.SetPosition(me, Vec3.new(vx, pos and pos.y or 0, vz))
    end
end

--- Travelling between vents while inside one. Left/Right walk the vent ring.
---
--- The hop itself is NOT broadcast (the server only rules on whether it was
--- allowed): a vent the whole room could watch is a vent no impostor would use.
local function ventTravel(me)
    local id = get("vent_id", 0)
    if id <= 0 then return end
    if not (pressed(Input.LEFT) or pressed(Input.RIGHT)) then return end

    send(P.useVent(id))
    local dx, dz = GameVentDest(id)
    if not dx then return end

    set("vent_id", GameVentNext(id))
    local pos = Actor.GetPosition(me)
    Actor.SetPosition(me, Vec3.new(dx, pos and pos.y or 0, dz))
end

--- The reactor is the one sabotage a single player cannot clear. Standing at a
--- panel with X held sends a "still holding" ping; the server clears the reactor
--- only while TWO different players are holding at the same time. Pinging every
--- few frames (rather than every frame) keeps a two-player hold well inside the
--- server's hold window without flooding a stop-and-wait link.
--- Ping well inside the server's reactor hold window (0.5s), so a frame-rate dip
--- or one dropped packet cannot make a legitimate two-player hold fail to
--- register. Counted in real time: at 20fps the old 10-FRAME period stretched to
--- half a second and sat exactly on the expiry boundary.
local REACTOR_PING_PERIOD = DT_SECOND / 6
local reactorPing = 0

local function reactorHold(px, pz, dt)
    if not get("sabotage_active", false) then return end
    if get("sabotage_kind", 0) ~= P.SABOTAGE_KIND.REACTOR then return end
    if not held(Input.CROSS) then
        reactorPing = 0
        return
    end

    local fx, fz = GameObjectPos("fix", P.SABOTAGE_KIND.REACTOR)
    if not fx then return end
    local dx, dz = fx - px, fz - pz
    if dx * dx + dz * dz >= USE_RANGE * USE_RANGE then
        reactorPing = 0
        return
    end

    if reactorPing > 0 then
        reactorPing = reactorPing - dt
        return
    end
    reactorPing = REACTOR_PING_PERIOD
    send(P.fixSabotage(P.SABOTAGE_KIND.REACTOR))
end

local function doSabotage(me)
    if get("role", P.ROLE.CREW) ~= P.ROLE.IMPOSTOR then return end
    if not get("alive", true) then return end
    if get("sabotage_active", false) then return end
    -- L2/R2 pick the flavour; the server refuses anything it does not like.
    --
    -- No sound here on purpose. This is a REQUEST, and the server turns plenty
    -- of them down — wrong role, already sabotaged, still on cooldown. The
    -- sting belongs to SABOTAGE_START, which only arrives if it really
    -- happened, and which the impostor receives along with everybody else.
    if pressed(Input.L2) then
        send(P.sabotage(P.SABOTAGE_KIND.LIGHTS))
    elseif pressed(Input.R2) then
        send(P.sabotage(P.SABOTAGE_KIND.REACTOR))
    end
end

-- === voting ==============================================================

local function voting()
    -- THE RESULTS ARE UP: the list of candidates has been replaced by who voted
    -- for whom, so there is no cursor to move and nothing left to vote on.
    --
    -- VOTE_TALLY and EJECTED are two messages, and only the second one takes the
    -- phase out of MEETING. They leave the server together, but on a serial link
    -- "together" can be seconds apart - and in that gap a press on UP used to
    -- repaint the candidate list straight over the result everybody was reading.
    if get("vote_results", false) then return end

    local options = get("vote_options", 1)
    local cursor = get("vote_cursor", 1)

    -- A GHOST DOES NOT VOTE, and the screen has to behave as if the button is
    -- not there rather than swallowing the press: the server refuses a dead
    -- player's vote (psxsus_match.vote), so a console that let one through would
    -- mark itself as having voted and then wait forever for a tally that
    -- already counted everyone.
    local canVote = get("alive", true)
        and get("voting_open", false)
        and not get("has_voted", false)

    -- The cursor clicks. Note the sound is inside the bounds check, not on the
    -- press: at the top of the list UP does nothing, and a blip there says the
    -- cursor moved when it did not.
    if pressed(Input.UP) and cursor > 1 then
        Sfx("ui_move")
        set("vote_cursor", cursor - 1)
        GameDrawVote()
    elseif pressed(Input.DOWN) and cursor < options then
        Sfx("ui_move")
        set("vote_cursor", cursor + 1)
        GameDrawVote()
    elseif pressed(Input.CROSS) and canVote then
        Sfx("vote")
        send(P.vote(GameVoteTargetAt(cursor)))
        -- Recorded locally only so the UI stops offering to vote again; the
        -- server is what actually refuses a second vote.
        set("has_voted", true)
        GameDrawVote()
    end
end

-- === per-frame ===========================================================

--- Ask the server who else is here.
---
--- `Scene.Load` wipes the console's Lua state, so the game scene comes up
--- knowing nobody — and the roster is only broadcast when it CHANGES, which
--- starting a round does not (the same people are in the same room). Without
--- this the vote screen offers only SKIP and names nobody, and an impostor can
--- never kill: the kill lookup skips every slot it does not know to be alive.
---
--- It cannot be sent from onSceneCreationEnd, because `Net.Connect()` has only
--- just been called there and `Net.SendData` returns false until the handshake
--- lands. So it is retried from the first frames of the round until it goes.
---
--- Crucially the retry stops when the ROSTER ARRIVES, not when the request is
--- accepted. Those are different events, and conflating them was a real bug: the
--- link accepting a request says nothing about the answer coming back, so a
--- single lost reply left the console with an empty player table for the entire
--- round — nobody named on the vote screen, and an impostor who could not kill
--- because the kill lookup skips every slot it cannot confirm is alive.
---
--- Timed in SECONDS of real elapsed time, not frames. This runs during scene
--- load, which is the worst frame-rate moment in the game, so a frame-counted
--- retry stretches out exactly when it most needs to be prompt.
local ROSTER_RETRY = 2 * DT_SECOND
local rosterWait = 0

local function askForRoster(dt)
    if get("roster_ok", false) then return end
    if rosterWait > 0 then
        rosterWait = rosterWait - dt
        return
    end
    rosterWait = ROSTER_RETRY
    Net.SendData(P.requestState())
end

function onUpdate(self, dt)
    if not ready() then return end
    if not Net.IsConnected() then return end

    -- REDRAW THE HUD ON A CLOCK, not only when the server says something.
    --
    -- drawHud is called from message handlers, so with no traffic it never runs
    -- again. Everything on it that changes with TIME was therefore frozen at the
    -- last event: the link counters, and — a real gameplay bug, not just a
    -- diagnostic one — the sabotage countdown, which sat at whatever second it
    -- was announced at while the reactor actually ticked down underneath it.
    --
    -- This was measured, not guessed: the console reported "H6" after a minute of
    -- play, i.e. the whole line was a photograph of logic frame six. Every number
    -- read off it, on hardware and on the emulator both, described the first
    -- fraction of a second in game and nothing since.
    --
    -- Throttled to ~2Hz because drawHud formats several strings and a PlayStation
    -- should not pay that every frame. Fast enough to read, cheap enough to ignore.
    -- Counted even while standing still, so the first step after stopping is
    -- immediate rather than up to a quarter of a second late.
    if stepWait > 0 then stepWait = stepWait - dt end

    hudTimer = hudTimer - dt
    if hudTimer <= 0 then
        hudTimer = HUD_REFRESH_DT
        -- Only while actually playing: during a meeting the vote canvas owns the
        -- screen, and redrawing the HUD under it would fight for the same rows.
        if get("phase", PHASE.PLAYING) == PHASE.PLAYING and _G.GameDrawHud then
            _G.GameDrawHud()
        end
    end

    askForRoster(dt)
    flushOutbox()

    -- Deliberately NOT `self`. What has to move is the actor bound to our slot —
    -- the one game.lua gave to Net.SetLocalAvatar — and this script hangs off
    -- whatever object the scene happened to attach it to. Moving `self` would
    -- shuffle some prop around the map while our avatar stood perfectly still.
    local me = GameAvatarFor(get("my_slot", -1))
    if not me then return end

    -- Everyone else animates in every phase (they are still being replicated
    -- during a meeting), and this must run before any early return below.
    animateRemotes(get("my_slot", -1), dt)

    -- ...and so must line of sight. It runs before the phase branches for the
    -- same reason: a task panel and a vote screen both sit over a world that is
    -- still moving underneath them, and coming back to a map where everybody is
    -- visible because the clock stopped would hand out free information.
    sightWait = sightWait - dt
    if sightWait <= 0 then
        sightWait = SIGHT_PERIOD
        if _G.GameApplyVisibility then _G.GameApplyVisibility() end
    end

    local phase = get("phase", PHASE.PLAYING)

    if phase == PHASE.MEETING then
        -- None of the arrows or the ring mean anything at the table, and a task
        -- panel left up would sit on top of the vote.
        GameHideIndicators()
        if GameTaskAbort then GameTaskAbort() end
        -- The clock has to move between the server's once-a-second resyncs, or
        -- it is correct and visibly frozen — which reads as a stopped game.
        if GameTickMeeting then GameTickMeeting(dt) end
        if get("has_voted", false) or not get("alive", true)
                or not get("voting_open", false) then
            -- A ghost has no vote, a player who has cast theirs cannot cast
            -- another, and during the debate nobody can yet. Offering the button
            -- in any of those states is offering nothing.
            P.setPrompts({ { P.BTN.DPAD, "READ" } })
        else
            P.setPrompts({ { P.BTN.DPAD, "CHOOSE" }, { P.BTN.CROSS, "VOTE" } })
        end
        voting()
        return
    end

    if phase == PHASE.OVER then
        GameHideIndicators()
        if GameTaskAbort then GameTaskAbort() end
        P.setPrompts(GameOverPrompts())

        -- START takes the WHOLE ROOM back to the lobby, and only the owner may
        -- press it. Asking the server rather than loading the lobby ourselves is
        -- the difference between a rematch and ten players wandering back at
        -- their own pace: the host cannot start the next round until everyone has
        -- arrived, so "everyone leaves when one person says so" is the feature.
        --
        -- We do NOT load the lobby here. The server answers with RETURN_LOBBY,
        -- and this console obeys it exactly like every other console does — so
        -- the owner is not a special case on arrival, only on departure.
        -- Sent UNCONDITIONALLY, not gated on `is_owner`.
        --
        -- The server is the authority on who owns the room and refuses anyone
        -- else, so the client-side test bought nothing — and it could be WRONG,
        -- because `is_owner` comes from a roster that may never have arrived in
        -- this scene (Scene.Load wipes the Lua state, and the re-request can be
        -- lost). A stale `false` there left the actual host pressing a button
        -- that did nothing, with no way to tell that apart from a dead pad.
        if pressed(Input.START) then
            Sfx("ui_select")
            send(P.returnToLobby())
        end

        -- CIRCLE leaves the ROOM and goes back to the LOBBY. This one IS local:
        -- we are giving up our slot, so there is nothing left for the room to
        -- tell us and nothing to keep the session alive for.
        --
        -- It used to go to the TITLE SCREEN, and that was the wrong end of the
        -- game to be thrown to. Someone who has just finished a round wants
        -- another one, and the title screen makes them walk back in through the
        -- whole front door -- and, until the name started living in Persist, made
        -- them retype their name to do it, because the lobby's first-time naming
        -- gate fires for anyone who arrives without a room.
        --
        -- Still SetPersistent(false), because leaving the room really is the end
        -- of this session: the lobby reconnects and comes up on the room browser
        -- rather than trying to reclaim a slot it has given away. The NAME is
        -- what survives now, and it survives in Persist rather than in the
        -- session -- see the naming block in scene_lobby.lua.
        if pressed(Input.CIRCLE) then
            Sfx("ui_back")
            Net.SendData(P.leaveRoom())
            Net.SetPersistent(false)
            Scene.Load(P.SCENE.LOBBY)
        end
        return
    end

    -- A vote result is left on screen until the player moves on; a scene script
    -- has no timer of its own to clear it.
    if get("vote_result_shown", false) then
        P.setPrompts({ { P.BTN.CROSS, "CONTINUE" } })
        if pressed(Input.CROSS) or pressed(Input.CIRCLE) then GameCloseVote() end
        return
    end

    -- Smooth the DISPLAYED sabotage countdown between the server's resyncs.
    -- The server owns the real timer and says so once a second; this only fills
    -- the gaps. See GameTickSabotage for why the console must not run its own.
    GameTickSabotage(dt)

    -- A task panel owns the whole frame: no walking, no killing, no using, no
    -- venting. It still had to come AFTER the sabotage clock, because a reactor
    -- must keep counting down while somebody is heads-down in a puzzle — that
    -- tension is the point of a sabotage.
    if GameTaskActive and GameTaskActive() then
        GameTaskUpdate()
        -- The open panel says what its own controls are. This is what replaced
        -- the `taskinstr` caption that used to live inside the panel: the same
        -- information, in the place the player has already learned to look for
        -- it, instead of a second convention that only existed here.
        P.setPrompts(GameTaskPrompts and GameTaskPrompts() or nil)
        camera(me)
        return
    end

    if get("alive", true) then
        -- Inside a vent there is no walking, no killing and no using: you are in
        -- the walls. Left/Right travel the ring, Triangle climbs out.
        if get("in_vent", false) then
            ventTravel(me)
            if pressed(Input.TRIANGLE) then doVent(me) end
            GameHideIndicators()
            camera(me)
            return
        end
        move(me)
        if pressed(Input.CROSS) then doUse(me) end
        if pressed(Input.SQUARE) then doKill(me) end
        if pressed(Input.TRIANGLE) then doVent(me) end
        doSabotage(me)
    else
        -- Ghosts still walk and still finish tasks. It is what a murdered
        -- crewmate has left to do, and their work still counts toward the win.
        move(me)
        if pressed(Input.CROSS) then doUse(me) end
    end

    -- Guidance last, so it reflects where the player ended up this frame rather
    -- than where they started it.
    --
    -- Throttled, and it has to be. Every one of these walks the task list doing
    -- position lookups, and Actor.GetPosition allocates a Vec3 plus three
    -- FixedPoint tables PER CALL — running the whole set at 60Hz buried
    -- psyqo-lua's collector and dragged the frame rate down with it. None of it
    -- is gameplay: an arrow that updates eight times a second is
    -- indistinguishable from one that updates sixty, because the player cannot
    -- walk far enough in 8 frames for it to point anywhere else.
    --
    -- reactorHold is NOT throttled with them: it is an action, not guidance, and
    -- it already rate-limits itself.
    local px, pz = apos(me)
    if px then
        reactorHold(px, pz, dt)
        guidanceWait = guidanceWait - dt
        if guidanceWait <= 0 then
            guidanceWait = GUIDANCE_PERIOD
            GameUpdateIndicators(px, pz)
            local ux, uz, label = usableTarget(px, pz)
            GameSetHighlight(ux, uz)
            -- On the SAME clock and from the SAME lookup as the ring, so the two
            -- can never disagree about what is under the player's feet.
            P.setPrompts(currentPrompts(px, pz, label))
        end
    end

    camera(me)
end
