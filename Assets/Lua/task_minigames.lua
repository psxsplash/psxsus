-- PSXSUS — task minigames.
--
-- Attach to its OWN GameObject in the GAME scene (one Lua file per object). It
-- defines only globals and deliberately has NO onUpdate: player_control.lua is
-- the scene's single per-frame owner, and it drives this module. Two scripts
-- polling the pad in the same frame would both see the same press and act on it
-- twice.
--
-- A task used to be one button press, which meant a crewmate could clear their
-- whole list by walking a lap. These are the actual jobs: a panel opens, the
-- player is locked out of walking, killing and using until they finish or back
-- out, and only a genuine success sends TaskComplete.
--
-- The server is unchanged and stays the authority on what a completion MEANS:
-- it counts TaskComplete messages and decides the crew win. Nothing here can be
-- trusted (a patched client can always send the message), which is the same
-- accepted tradeoff as client-authoritative movement — see ROOM_PROTOCOL.md.
--
-- === THE PANELS ARE AUTHORED, NOT BUILT ==================================
--
-- Every piece of every panel — backdrop, bezel, wires, sockets, keys, chevrons,
-- lamps, digits, the gauge and its needle — is a UI element in the `task`
-- canvas, laid out in Unity by `PSXSUS/Art/make_scenes.py`'s `build_task_panel`.
-- This file no longer creates ANYTHING. It shows, hides, tints, re-frames and
-- moves what is already there.
--
-- That is not a refactor for its own sake. What it deletes is:
--
--   * sixty-odd `Sprite.Create` calls whose positions were arithmetic
--     (`PANEL_X + 28`, `WIRE_Y0 + (i - 1) * WIRE_DY`) that nobody could see
--     without building a disc;
--   * a hand transcription of make_art.py's `TU` cell table, which could drift
--     from the art with no error — only wrong furniture;
--   * a widget pool that competed with the avatars for the 128 sprite slots;
--   * a dependence on sprite-layer ordering, whose rule is the reverse of how
--     it reads and which had already produced two invisible-panel bugs.
--
-- What geometry is still needed at run time (how wide the bar is, where the
-- gauge track starts) is READ BACK from the authored elements with
-- `UI.GetPosition` / `UI.GetSize`, so the scene file stays the single copy.
-- Those two return values in the element's own ANCHOR-RELATIVE space, which is
-- also what `UI.SetPosition` takes — so every calculation below is a relative
-- offset from something authored, and none of it is a screen coordinate.
--
-- A scene missing the `task` canvas still PLAYS every minigame: every handle is
-- -1, every setter no-ops, and the games run blind rather than refusing to open.
--
-- Console Lua has no `math`. See psxsus_protocol.lua.

local P = nil

local function ready()
    if P then return true end
    P = PSXSUS
    return P ~= nil
end

local function get(k, d)
    local v = SUS[k]
    if v == nil then return d end
    return v
end

local function set(k, v) SUS[k] = v end

-- === deterministic randomness ===========================================

-- No `math.random` on the console. A 16-bit LCG is plenty for shuffling four
-- wires and is chosen to stay small on purpose: lua_Number is a `long`, which is
-- 32-bit on the MIPS target, so the usual 1103515245 multiplier would overflow
-- there while looking perfectly fine in the 64-bit desktop Lua the tests run on.
-- 75 * 65537 fits with room to spare.
local seed = 1

local function seedFrom(n)
    seed = (n * 2654 + 12345) % 65537
    if seed <= 0 then seed = 1 end
end

--- 1..n
local function rnd(n)
    seed = (seed * 75 + 74) % 65537
    return seed % n + 1
end

-- === the authored canvas =================================================

local canvas = -1
local ui = {}          -- element name -> handle (-1 when absent)

--- The ONLY cell indices left in this file.
---
--- Everything else about the art lives in the scene, authored from make_art.py's
--- `TU` table directly. These five are here because they are the cells the game
--- SWITCHES BETWEEN at run time — a digit becomes another digit, a chevron
--- points somewhere else — which is exactly what `UI.SetFrame` is for.
--- They must agree with `TU` in PSXSUS/Art/make_art.py.
local CELL_DIGIT0 = 20
--- Indexed by the pad direction order `seqStep` uses: up, down, left, right.
local CELL_CHEV = { 16, 17, 18, 19 }

-- Shared colours, so the panels agree with the rest of the game: green is
-- "done/yours" everywhere, amber is "do this now", dim blue is "not yet".
-- These are TINTS: the PS1 computes texel * colour / 128.
local C_DONE = { 90, 230, 120 }
local C_NOW = { 250, 220, 70 }
local C_IDLE = { 62, 68, 88 }
local C_BAD = { 224, 76, 76 }
--- Unlit, but READABLE. C_IDLE is (62, 68, 88) against a (18, 21, 32) panel,
--- which is an unlit lamp — correct for a lamp and catastrophic for a chevron,
--- because the whole ENTER SEQUENCE game is reading four directions before
--- pressing them. Drawn in C_IDLE the three steps you have not reached yet are
--- effectively invisible, and the panel looks like it is showing nothing at all.
local C_DIM = { 168, 178, 205 }

local function h(name)
    local e = ui[name]
    if e == nil then return -1 end
    return e
end

local function show(name, on)
    local e = h(name)
    if e >= 0 then UI.SetVisible(e, on and true or false) end
end

local function paint(name, c)
    local e = h(name)
    if e >= 0 then UI.SetColor(e, c[1], c[2], c[3]) end
end

local function frame(name, cell)
    local e = h(name)
    if e >= 0 then UI.SetFrame(e, cell) end
end

local function moveTo(name, x, y)
    local e = h(name)
    if e >= 0 then UI.SetPosition(e, x, y) end
end

local function resize(name, w, hh)
    local e = h(name)
    if e >= 0 then UI.SetSize(e, w, hh) end
end

local function text(name, s)
    local e = h(name)
    if e >= 0 then UI.SetText(e, s) end
end

--- Every element the panel owns, grouped by the game that uses it.
---
--- The group table is what `open`/`close` show and hide, and it is also the
--- authoring contract: a name here that the scene does not carry resolves to -1
--- and silently does nothing, which is why `GameTaskUiInit` reports the misses
--- once, by name, at scene load rather than leaving you to notice a missing lamp.
local GROUP = {
    chrome = { "panelbg", "titlebar",
               "bezel_top", "bezel_bottom", "bezel_left", "bezel_right",
               "bezel_tl", "bezel_tr", "bezel_bl", "bezel_br" },
    hold = { "hold_frame", "hold_bar" },
    wires = { "wire1", "wire2", "wire3", "wire4",
              "socket1", "socket2", "socket3", "socket4",
              "wire_markl", "wire_markr" },
    seq = { "seq_lamp1", "seq_lamp2", "seq_lamp3", "seq_lamp4",
            "seq_key1", "seq_key2", "seq_key3", "seq_key4",
            "seq_chev1", "seq_chev2", "seq_chev3", "seq_chev4" },
    align = { "align_track", "align_band", "align_needle",
              "align_lamp1", "align_lamp2", "align_lamp3" },
    code = { "code_dial",
             "code_tbg1", "code_tbg2", "code_tbg3", "code_tbg4",
             "code_t1", "code_t2", "code_t3", "code_t4",
             "code_ebg1", "code_ebg2", "code_ebg3", "code_ebg4",
             "code_e1", "code_e2", "code_e3", "code_e4",
             "code_lamp1", "code_lamp2", "code_lamp3", "code_lamp4" },
    captions = { "tasktitle", "taskvalue" },
}

local TYPE = { HOLD = 1, WIRES = 2, SEQUENCE = 3, ALIGN = 4, CODE = 5 }
_G.GameTaskTypes = TYPE

local GROUP_FOR = {
    [TYPE.HOLD] = "hold", [TYPE.WIRES] = "wires", [TYPE.SEQUENCE] = "seq",
    [TYPE.ALIGN] = "align", [TYPE.CODE] = "code",
}

local function showGroup(key, on)
    local g = GROUP[key]
    if not g then return end
    for i = 1, #g do show(g[i], on) end
end

--- The authored geometry, read back once so this file holds no copy of it.
---
--- `UI.GetPosition` / `UI.GetSize` answer in the element's anchor-relative
--- space, which is the same space `UI.SetPosition` / `UI.SetSize` write, so
--- every offset computed from these round-trips exactly. A missing element
--- answers 0, and the arithmetic below then moves things to nowhere in
--- particular — which is the right failure for a panel that is not on screen.
local geom = {}

local function readGeometry()
    local function pos(name)
        local e = h(name)
        if e < 0 then return 0, 0 end
        return UI.GetPosition(e)
    end
    local function size(name)
        local e = h(name)
        if e < 0 then return 0, 0 end
        return UI.GetSize(e)
    end

    geom.holdX, geom.holdY = pos("hold_bar")
    -- The bar is AUTHORED FULL WIDTH — it reads as a finished gauge in the
    -- editor, and its authored width is the only place the full length is
    -- written down. `holdBegin` empties it.
    geom.holdW, geom.holdH = size("hold_bar")
    if geom.holdW < 1 then geom.holdW = 1 end
    if geom.holdH < 1 then geom.holdH = 1 end

    geom.trackX, geom.trackY = pos("align_track")
    geom.trackW, geom.trackH = size("align_track")
    if geom.trackW < 1 then geom.trackW = 1 end
    if geom.trackH < 1 then geom.trackH = 1 end
    local _, bandH = size("align_band")
    geom.bandH = bandH > 0 and bandH or geom.trackH
    local nx, ny = pos("align_needle")
    geom.needleX, geom.needleY = nx, ny

    local mlx = pos("wire_markl")
    local mrx = pos("wire_markr")
    geom.markLX, geom.markRX = mlx, mrx
    geom.wireY = {}
    for i = 1, 4 do
        local _, wy = pos("wire" .. i)
        geom.wireY[i] = wy
    end
end

--- Called once from game.lua's scene setup.
_G.GameTaskUiInit = function()
    canvas = UI.FindCanvas("task")
    ui = {}
    if canvas < 0 then
        Debug.Log("PSXSUS tasks: no canvas named 'task' - the minigames will run blind")
        return
    end

    local missing = 0
    for _, names in pairs(GROUP) do
        for i = 1, #names do
            local name = names[i]
            local e = UI.FindElement(canvas, name)
            ui[name] = e
            if e < 0 then
                missing = missing + 1
                Debug.Log("PSXSUS tasks: the 'task' canvas has no element '" .. name .. "'")
            end
        end
    end
    if missing > 0 then
        Debug.Log("PSXSUS tasks: " .. missing ..
                  " authored elements are missing - re-run PSXSUS/Art/make_scenes.py")
    end

    readGeometry()

    -- Everything off, chrome included: the canvas itself is hidden at load, and
    -- a group left visible would appear the instant some other panel opened.
    for key in pairs(GROUP) do showGroup(key, false) end
    UI.SetCanvasVisible(canvas, false)
end

-- === the five games ======================================================

-- Which of the twelve authored stations plays which game. A fixed cycle rather
-- than a random draw so a given station is ALWAYS the same job: players learn
-- "the one in electrical is wires", and two players sent to the same station see
-- the same panel.
local TASK_TYPES = {
    TYPE.WIRES, TYPE.HOLD, TYPE.SEQUENCE, TYPE.ALIGN,
    TYPE.CODE, TYPE.WIRES, TYPE.HOLD, TYPE.SEQUENCE,
    TYPE.ALIGN, TYPE.CODE, TYPE.WIRES, TYPE.HOLD,
}

_G.GameTaskTypeFor = function(id)
    local t = TASK_TYPES[id]
    if t then return t end
    -- Unknown station (a scene authored with more than twelve): fall back to the
    -- game that needs no setup rather than refusing to open.
    return TYPE.HOLD
end

-- The panel currently open, or nil. `done` is set the frame it is won so the
-- caller can finish it exactly once.
local active = nil

local WIRE_COUNT = 4
local SEQ_LEN = 4
local CODE_DIGITS = 4

-- === HOLD ================================================================
-- Fill a bar by holding X. Letting go drains it, so it is a steady-hands job
-- rather than a button you can leave taped down for free.

-- The bar is counted in FRAMES held, not in percent, because percent cannot
-- express ten seconds in integers: at 60fps a full bar is 600 steps, and a gain
-- of 100/600 rounds to zero. holdStep runs once per frame, so HOLD_FULL is
-- literally the number of frames the button must be held.
--
-- It used to be 100 with a gain of 3 — thirty-four frames, just over half a
-- second. That is not a task, it is a keypress with a progress bar on it.
local HOLD_FULL = 600            -- 10 seconds at 60fps
local HOLD_GAIN, HOLD_DRAIN = 1, 2

local function holdBegin(a)
    a.value = 0
    resize("hold_bar", 1, geom.holdH)
    paint("hold_bar", C_DONE)
    text("tasktitle", "CALIBRATE")
end

local function holdStep(a, input)
    if input.held.cross then
        a.value = a.value + HOLD_GAIN
    else
        -- Letting go drains at twice the fill rate, so a ten-second hold that is
        -- interrupted costs real time. That is the point of the job: it pins a
        -- crewmate in one place, in the open, for long enough to matter.
        a.value = a.value - HOLD_DRAIN
    end
    if a.value < 0 then a.value = 0 end
    if a.value >= HOLD_FULL then a.value = HOLD_FULL end

    local w = (a.value * geom.holdW - (a.value * geom.holdW) % HOLD_FULL) / HOLD_FULL
    if w < 1 then w = 1 end
    resize("hold_bar", w, geom.holdH)
    -- Green while filling, amber once it is nearly there: the colour tells you
    -- to keep holding without needing to read the number.
    local pct = (a.value * 100 - (a.value * 100) % HOLD_FULL) / HOLD_FULL
    paint("hold_bar", pct >= 90 and C_NOW or C_DONE)
    text("taskvalue", string.format("%d%%", pct))
    return a.value >= HOLD_FULL
end

-- === WIRES ===============================================================
-- Four coloured wires on the left, the same four shuffled on the right. Pick a
-- left wire, then a right one; a match locks, a miss just deselects.

local WIRE_COLORS = {
    { 240, 60, 60 }, { 80, 200, 255 }, { 250, 220, 70 }, { 130, 240, 130 },
}

local function shuffled(n)
    local t = {}
    for i = 1, n do t[i] = i end
    -- Fisher-Yates. Walking DOWN means rnd() is only ever asked for a range that
    -- exists, so no rejection loop is needed.
    for i = n, 2, -1 do
        local j = rnd(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function wiresBegin(a)
    a.right = shuffled(WIRE_COUNT)
    a.linked = {}
    a.cursor = 1
    a.picked = nil
    for i = 1, WIRE_COUNT do
        -- The left column is authored in its own colours; only the RIGHT column
        -- is dealt, because the shuffle is the puzzle.
        paint("wire" .. i, WIRE_COLORS[i])
        paint("socket" .. i, WIRE_COLORS[a.right[i]])
    end
    -- Two markers, not one, and this is the fix for the confusing part of this
    -- game: with a single marker that jumped columns there was no way to see
    -- WHICH left wire you were holding while choosing a socket for it. The left
    -- lamp stays lit on the wire in hand; the right lamp is the cursor.
    paint("wire_markl", C_IDLE)
    paint("wire_markr", C_IDLE)
    text("tasktitle", "FIX WIRING")
end

local function wiresDraw(a)
    local y = geom.wireY[a.cursor] or 0
    if a.picked then
        -- Choosing a socket: the left lamp stays on the wire in hand.
        moveTo("wire_markl", geom.markLX, geom.wireY[a.picked] or 0)
        paint("wire_markl", C_NOW)
        moveTo("wire_markr", geom.markRX, y)
        paint("wire_markr", C_NOW)
    else
        moveTo("wire_markl", geom.markLX, y)
        paint("wire_markl", C_NOW)
        paint("wire_markr", C_IDLE)
        moveTo("wire_markr", geom.markRX, geom.wireY[WIRE_COUNT] or 0)
    end
    local n = 0
    for i = 1, WIRE_COUNT do
        if a.linked[i] then n = n + 1 end
    end
    text("taskvalue", string.format("%d/%d JOINED", n, WIRE_COUNT))
    return n >= WIRE_COUNT
end

local function wiresStep(a, input)
    if input.pressed.up and a.cursor > 1 then
        a.cursor = a.cursor - 1
        if _G.Sfx then _G.Sfx("ui_move") end
    end
    if input.pressed.down and a.cursor < WIRE_COUNT then
        a.cursor = a.cursor + 1
        if _G.Sfx then _G.Sfx("ui_move") end
    end

    if input.pressed.cross then
        if not a.picked then
            if not a.linked[a.cursor] then
                a.picked = a.cursor
                if _G.Sfx then _G.Sfx("ui_select") end
            end
        else
            if a.right[a.cursor] == a.picked then
                a.linked[a.picked] = true
                if _G.Sfx then _G.Sfx("task_step") end
                -- Dim a joined pair so the remaining work is obvious at a glance.
                paint("wire" .. a.picked, C_IDLE)
                paint("socket" .. a.cursor, C_IDLE)
            elseif _G.Sfx then
                -- A mismatched pair just dropped the held wire and said
                -- nothing, which is indistinguishable from the press being
                -- missed entirely.
                _G.Sfx("task_fail")
            end
            a.picked = nil
        end
    end

    return wiresDraw(a)
end

-- === SEQUENCE ============================================================
-- Repeat the run of directions shown. One wrong press starts it over, so it is
-- the job that actually costs you time when a body drops nearby.
--
-- The run is DRAWN, as four chevrons. It used to be spelled out one word at a
-- time in the caption — "UP", then "LEFT" — which is not a sequence at all: it
-- is four separate one-button prompts, with nothing to remember and nothing to
-- read ahead. Showing the whole run is the difference between a task and a
-- prompt.

local function seqBegin(a)
    a.want = {}
    a.at = 1
    for i = 1, SEQ_LEN do
        a.want[i] = rnd(4)
        frame("seq_chev" .. i, CELL_CHEV[a.want[i]])
        paint("seq_chev" .. i, C_DIM)
        paint("seq_lamp" .. i, C_IDLE)
    end
    text("tasktitle", "ENTER SEQUENCE")
end

local function seqDraw(a)
    for i = 1, SEQ_LEN do
        local c
        if i < a.at then c = C_DONE
        elseif i == a.at then c = C_NOW
        else c = C_IDLE end
        paint("seq_lamp" .. i, c)
        -- The chevron itself lights too, so the thing you are looking AT is the
        -- thing that tells you where you are. Steps you have not reached stay
        -- LEGIBLE rather than going dark: you have to be able to read the whole
        -- sequence, which is the entire game.
        paint("seq_chev" .. i, i <= a.at and c or C_DIM)
    end
    text("taskvalue", string.format("%d/%d", a.at - 1, SEQ_LEN))
end

local function seqStep(a, input)
    local pressed = nil
    if input.pressed.up then pressed = 1
    elseif input.pressed.down then pressed = 2
    elseif input.pressed.left then pressed = 3
    elseif input.pressed.right then pressed = 4 end

    if pressed then
        if pressed == a.want[a.at] then
            a.at = a.at + 1
            -- A right answer was the only input in the whole panel that made no
            -- sound: getting it wrong buzzed, getting it right was silent, so
            -- the panel only ever talked to you when you failed. The final step
            -- says nothing here because task_done is about to fire.
            if a.at <= SEQ_LEN and _G.Sfx then _G.Sfx("task_step") end
            if a.at > SEQ_LEN then
                for i = 1, SEQ_LEN do
                    paint("seq_lamp" .. i, C_DONE)
                    paint("seq_chev" .. i, C_DONE)
                end
                return true
            end
        else
            -- One mistake, start again — and say so, or a reset from step four
            -- back to step one looks like the panel simply stopped responding.
            a.at = 1
            if _G.Sfx then _G.Sfx("task_fail") end
            for i = 1, SEQ_LEN do paint("seq_lamp" .. i, C_BAD) end
        end
    end

    seqDraw(a)
    return false
end

-- === ALIGN ===============================================================
-- A cursor sweeps back and forth; press X while it is inside the target band.
-- Three hits, and the band narrows each time.

local ALIGN_HITS = 3

--- Where the difficulty STARTS, and therefore where a miss puts it back to.
---
--- These used to be written inline in alignBegin only, which is how the panel
--- came to be unwinnable. Each hit narrows the band and speeds the needle up;
--- a miss reset the hit COUNT but left both of those where the last run had
--- ratcheted them. Miss three times and you were back to zero hits against a
--- 40-wide band with a needle moving at 16 — a difficulty nobody had earned and
--- nobody could beat, and it never came back down for the rest of the round.
local ALIGN_BAND0, ALIGN_DIR0 = 120, 7

local function alignBegin(a)
    a.hits = 0
    a.pos = 0                 -- 0..1000 along the track
    a.dir = ALIGN_DIR0
    a.band = ALIGN_BAND0      -- half-width of the target, in the same units
    paint("align_band", C_DONE)
    for i = 1, ALIGN_HITS do paint("align_lamp" .. i, C_IDLE) end
    text("tasktitle", "ALIGN OUTPUT")
end

local function alignPx(v)
    -- v (0..1000) -> pixels along the track, integer-divided by hand, in the
    -- authored element's own coordinate space.
    local n = v * geom.trackW
    return geom.trackX + (n - n % 1000) / 1000
end

local function alignStep(a, input)
    a.pos = a.pos + a.dir
    if a.pos >= 1000 then a.pos, a.dir = 1000, -a.dir end
    if a.pos <= 0 then a.pos, a.dir = 0, -a.dir end

    local lo, hi = 500 - a.band, 500 + a.band
    local left = alignPx(lo)
    moveTo("align_band", left, geom.trackY)
    resize("align_band", alignPx(hi) - left, geom.bandH)
    -- The needle keeps its authored size: stretching a shape with a point on it
    -- just smears the point. Only its X moves.
    moveTo("align_needle", alignPx(a.pos) - 8, geom.needleY)

    if input.pressed.cross then
        if a.pos >= lo and a.pos <= hi then
            a.hits = a.hits + 1
            if a.hits < ALIGN_HITS and _G.Sfx then _G.Sfx("task_step") end
            -- Narrower and faster each time: three lucky taps should not do it.
            a.band = a.band - 30
            if a.band < 40 then a.band = 40 end
            if a.dir > 0 then a.dir = a.dir + 3 else a.dir = a.dir - 3 end
        else
            -- Miss and you start over — ALL of the way over. Resetting the hit
            -- count while leaving the band narrowed and the needle sped up is
            -- what made this panel get permanently harder every time you failed
            -- it, until it could not be finished at all.
            a.hits = 0
            a.band = ALIGN_BAND0
            a.dir = a.dir > 0 and ALIGN_DIR0 or -ALIGN_DIR0
            -- Losing three hits in silence is the harshest thing in the panel
            -- to not be told about.
            if _G.Sfx then _G.Sfx("task_fail") end
        end
    end

    for i = 1, ALIGN_HITS do
        paint("align_lamp" .. i, i <= a.hits and C_DONE or C_IDLE)
    end
    text("taskvalue", string.format("%d/%d", a.hits, ALIGN_HITS))
    return a.hits >= ALIGN_HITS
end

-- === CODE ================================================================
-- A four-digit code is displayed; dial it in underneath.
--
-- Both numbers used to share one caption — "3714  0000" — which is unreadable
-- at a glance, gives no indication of which column the d-pad is on, and puts a
-- number you must copy and a number you are editing in the same typeface a few
-- pixels apart. They are two rows of drawn digits now, with the target above
-- and a lamp under the column being edited.

local function setDigits(prefix, values)
    for i = 1, #values do
        frame(prefix .. i, CELL_DIGIT0 + (values[i] % 10))
    end
end

local function codeBegin(a)
    a.want = {}
    for i = 1, CODE_DIGITS do a.want[i] = rnd(10) - 1 end
    a.dial = { 0, 0, 0, 0 }
    a.col = 1

    setDigits("code_t", a.want)
    setDigits("code_e", a.dial)
    for i = 1, CODE_DIGITS do paint("code_lamp" .. i, C_IDLE) end

    text("tasktitle", a.title or "ENTER CODE")
end

local function codeDraw(a)
    setDigits("code_e", a.dial)
    for i = 1, CODE_DIGITS do
        -- Amber on the column being edited, green on the ones that already
        -- match. Matching is shown per digit because a four-digit code entered
        -- wrongly by one column should not read as entirely wrong.
        local c = C_IDLE
        if a.dial[i] == a.want[i] then c = C_DONE end
        if i == a.col then c = C_NOW end
        paint("code_lamp" .. i, c)
    end
    text("taskvalue", "")
end

local function codeStep(a, input)
    -- Every dial movement clicks. This panel is four columns of digits with no
    -- other feedback, so without it a press that changed nothing (already at
    -- the last column) is indistinguishable from one that did.
    local moved = false
    if input.pressed.left and a.col > 1 then a.col = a.col - 1; moved = true end
    if input.pressed.right and a.col < CODE_DIGITS then a.col = a.col + 1; moved = true end
    if input.pressed.up then a.dial[a.col] = (a.dial[a.col] + 1) % 10; moved = true end
    if input.pressed.down then a.dial[a.col] = (a.dial[a.col] + 9) % 10; moved = true end
    if moved and _G.Sfx then _G.Sfx("ui_move") end

    local ok = false
    if input.pressed.cross then
        ok = true
        for i = 1, CODE_DIGITS do
            if a.dial[i] ~= a.want[i] then ok = false end
        end
        -- Submitting a wrong code used to do nothing whatsoever.
        if not ok and _G.Sfx then _G.Sfx("task_fail") end
    end

    codeDraw(a)
    return ok
end

-- === panel lifecycle =====================================================

local BEGIN = { holdBegin, wiresBegin, seqBegin, alignBegin, codeBegin }
local STEP = { holdStep, wiresStep, seqStep, alignStep, codeStep }

local opens = 0

--- Open a panel. `onDone` is { kind = "task"|"fix", id = n } — what to send when
--- the player actually finishes. Returns true if a panel opened.
local function open(gameType, onDone, title)
    if active then return false end
    if not ready() then return false end

    -- Vary the puzzle between visits (the code is not the same four digits every
    -- time) while staying deterministic within one open, which is what lets the
    -- tests drive a panel to completion.
    opens = opens + 1
    seedFrom((onDone.id or 0) * 31 + opens * 7)

    active = { type = gameType, done = onDone, title = title }

    -- Chrome and this game's widgets on, every other game's off. Hiding the
    -- others EVERY time rather than tracking what was last shown is what makes
    -- an aborted panel (a meeting, a death) impossible to leave a lamp behind.
    showGroup("chrome", true)
    showGroup("captions", true)
    for _, g in pairs(GROUP_FOR) do showGroup(g, false) end
    showGroup(GROUP_FOR[gameType], true)

    text("taskvalue", "")
    BEGIN[gameType](active)
    if canvas >= 0 then UI.SetCanvasVisible(canvas, true) end
    if _G.Sfx then _G.Sfx("task_open") end
    set("in_task", true)
    -- The arrows and the interact ring are world guidance; none of it means
    -- anything while a full-screen panel is up.
    GameHideIndicators()
    return true
end

_G.GameTaskOpen = function(taskId)
    return open(GameTaskTypeFor(taskId), { kind = "task", id = taskId })
end

--- The O2 sabotage: the only fix in the game that is not a single press. Same
--- CODE panel, but success clears the sabotage instead of completing a task.
_G.GameTaskOpenOxygen = function()
    return open(TYPE.CODE, { kind = "fix", id = P and P.SABOTAGE_KIND.OXYGEN or 3 },
                "O2 - ENTER CODE")
end

_G.GameTaskActive = function() return active ~= nil end

-- What the pad does in each panel, for the shared prompt bar.
--
-- This is where the `taskinstr` caption line went. That line lived INSIDE the
-- panel and said the same kind of thing the rest of the game says on the bottom
-- of the screen — so the player had to learn two places to look for "what does X
-- do", and the panel gave up a whole row of its 152px height to say it. Now it
-- is one convention everywhere, and the minigame got the row back.
--
-- Three at most, in priority order; BACK is last because it is the one prompt
-- that is identical in every panel and therefore the one a player stops needing
-- first.
-- Built on first use rather than at load time: `P` is nil until `ready()` runs
-- (the protocol module publishes itself when ITS chunk executes, which is a
-- different file), so a table written with `P.BTN.CROSS` at the top level would
-- be a table of nils and every prompt would draw glyph zero.
local TASK_PROMPTS = nil

local function taskPrompts()
    if TASK_PROMPTS then return TASK_PROMPTS end
    if not ready() then return nil end
    local B = P.BTN
    TASK_PROMPTS = {
        [TYPE.HOLD] = { { B.CROSS, "HOLD" }, { B.CIRCLE, "BACK" } },
        [TYPE.WIRES] = { { B.DPAD, "PICK" }, { B.CROSS, "CONNECT" }, { B.CIRCLE, "BACK" } },
        [TYPE.SEQUENCE] = { { B.DPAD, "REPEAT" }, { B.CIRCLE, "BACK" } },
        [TYPE.ALIGN] = { { B.CROSS, "LOCK IN" }, { B.CIRCLE, "BACK" } },
        [TYPE.CODE] = { { B.DPAD, "DIAL" }, { B.CROSS, "SUBMIT" }, { B.CIRCLE, "BACK" } },
    }
    return TASK_PROMPTS
end

_G.GameTaskPrompts = function()
    if not active then return nil end
    local t = taskPrompts()
    return t and t[active.type] or nil
end

--- Hand a payload to player_control's retrying sender if it is available.
--- A finished task that vanished because the link was momentarily full is a
--- player doing the work twice.
local function sendRequest(payload)
    if GameSendRequest then return GameSendRequest(payload) end
    return Net.SendData(payload)
end

--- The open panel's state, or nil. Exposed for the tests, which have to know the
--- code to dial and the run to press in order to drive a panel to a win — the
--- same reason GameOctant is exposed in game.lua. Nothing in the game reads it.
_G.GameTaskState = function() return active end

_G.GameTaskClose = function()
    if not active then return end
    active = nil
    -- Hide the canvas first, then the groups. One call blanks the panel; the
    -- rest is bookkeeping so nothing is left visible for the next open to
    -- inherit.
    if canvas >= 0 then UI.SetCanvasVisible(canvas, false) end
    for key in pairs(GROUP) do showGroup(key, false) end
    set("in_task", false)
end

--- One frame of the open panel. Returns true while a panel is up, so the caller
--- knows it must not also walk the player around.
---
--- Input is read here rather than passed in because this is the only place that
--- consumes it while a panel is open — player_control hands over the whole frame.
_G.GameTaskUpdate = function()
    if not active then return false end

    local input = {
        pressed = {
            cross = Input.IsPressedPlayer1(Input.CROSS),
            up = Input.IsPressedPlayer1(Input.UP),
            down = Input.IsPressedPlayer1(Input.DOWN),
            left = Input.IsPressedPlayer1(Input.LEFT),
            right = Input.IsPressedPlayer1(Input.RIGHT),
        },
        held = { cross = Input.IsHeldPlayer1(Input.CROSS) },
    }

    -- Backing out is always allowed and is checked FIRST, so a panel can never
    -- trap a player: a crewmate stuck in a wiring puzzle while an impostor walks
    -- up is a bug that ends rounds.
    if Input.IsPressedPlayer1(Input.CIRCLE) then
        if _G.Sfx then _G.Sfx("ui_back") end
        GameTaskClose()
        return true    -- still swallow this frame; the walk resumes next one
    end

    local finished = STEP[active.type](active, input)
    if finished then
        if _G.Sfx then _G.Sfx("task_done") end
        local d = active.done
        if d.kind == "task" then
            -- Marked locally so the station stops offering itself; the COUNT on
            -- the HUD only moves when the server says so.
            set("task_done_" .. d.id, true)
            sendRequest(P.taskComplete(d.id))
            -- The marker standing on that station has to go, or the player is
            -- told to go back and do it again.
            if GameRefreshTaskMarkers then GameRefreshTaskMarkers() end
        else
            sendRequest(P.fixSabotage(d.id))
        end
        GameTaskClose()
    end
    return true
end

--- Force the panel shut. A meeting, a death or the round ending all outrank
--- whatever the player was doing, and none of them should leave a panel on
--- screen over the vote.
_G.GameTaskAbort = function()
    if active then GameTaskClose() end
end
