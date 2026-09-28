-- PSXSUS title screen — the scene script.
--
-- Attach to the MENU scene's PSXSceneExporter (it is scene index 0, the one the
-- disc boots into). `menu_input.lua` drives it from the pad, because scene
-- scripts get no per-frame callback — only methodIds 1/2/3/4.
--
-- This scene touches the network deliberately NOT AT ALL. The lobby is where a
-- session begins, and a title screen that opens a serial link is a title screen
-- that can sit on "connecting" before the player has asked for anything. If the
-- server is down, that should be discovered after pressing PLAY, with a message,
-- rather than as a game that appears not to boot.
--
-- Everything here is drawn with SPRITES rather than UI elements wherever it
-- moves, because the engine has no runtime UI creation: UI elements must be
-- authored in Unity and can only be shown, hidden and re-texted. Sprites can be
-- created, tinted, moved and resized at will, which is what the starfield and
-- the logo need.
--
-- Console Lua has no `math` and no `require`. See psxsus_protocol.lua.

local P = nil

-- Views. SPLASH is what the disc boots into; MAIN is the menu proper; the last
-- three are text pages reached from it.
_G.MENUVIEW = { SPLASH = 0, MAIN = 1, HOWTO = 2, CONTROLS = 3, CREDITS = 4 }
local VIEW = _G.MENUVIEW

-- Nine rows, which is what a 240px screen holds once the title, the status line
-- and the button prompt bar have been paid for: 24 + 9*19 = 195, status at 200,
-- prompts at 220. make_scenes.py derives the same number from the same
-- constants and refuses to write a scene that does not fit.
local ROW_COUNT = 9

local ui = {}
local canvas = -1

--- Shared with menu_input.lua. A table, not Persist: Persist holds sixteen
--- numbers and nothing else, and this needs strings and booleans.
_G.SUS = {
    view = VIEW.SPLASH,
    cursor = 1,
    optionCount = 1,
    -- How long the splash has been up, in raw dt units. The splash is skippable
    -- but not required: a player who walks away still reaches the menu.
    splashAge = 0,
    starPhase = 0,
}
local S = _G.SUS

-- dt is 4.12 fixed point where 4096 == one 30Hz frame, so a real second is
-- 30*4096. Timers accumulate raw units and never convert to seconds first:
-- LUA_NUMBER is a long, so `dt / 4096` is 0 at anything above 30fps.
local DT_SECOND = 30 * 4096
_G.MENU_SPLASH_HOLD = 3 * DT_SECOND

local function text(name, s)
    local h = ui[name]
    if h and h >= 0 then UI.SetText(h, s) end
end

local function show(name, visible)
    local h = ui[name]
    if h and h >= 0 then UI.SetVisible(h, visible) end
end

local function rowName(i) return "row" .. i end

local function clearRows()
    for i = 1, ROW_COUNT do show(rowName(i), false) end
end

-- === the starfield =======================================================
--
-- Twelve sprites drifting downward. It costs almost nothing and it is the
-- difference between a title screen and a text file: the eye needs something
-- moving to read a still image as a running program.

local STAR_COUNT = 12
local stars = {}

-- Fixed start positions and speeds. No `math.random` on the console, and a
-- fixed layout is better anyway — it looks composed rather than sprinkled.
local STAR_X = { 12, 47, 88, 131, 176, 210, 248, 289, 30, 152, 268, 196 }
local STAR_Y = { 8, 92, 44, 168, 20, 128, 76, 200, 148, 232, 104, 60 }
local STAR_SPEED = { 3, 5, 2, 6, 4, 3, 7, 2, 5, 4, 6, 3 }

local function createStars()
    if Sprite.SheetIndex("ui") < 0 then return end
    for i = 1, STAR_COUNT do
        local id = Sprite.Create("ui")
        if id < 0 then break end
        Sprite.SetFrame(id, 12)               -- the speck cell
        Sprite.SetIgnoreViewOffset(id, true)
        Sprite.SetLayer(id, 9)                -- behind everything else
        Sprite.SetPos(id, STAR_X[i], STAR_Y[i])
        -- Dim, and dimmer the slower it moves: parallax by brightness, which is
        -- the only depth cue available when every star is the same one pixel.
        local b = 40 + STAR_SPEED[i] * 16
        Sprite.SetColor(id, b, b, b + 30)
        Sprite.SetVisible(id, true)
        stars[i] = { id = id, y = STAR_Y[i], speed = STAR_SPEED[i] }
    end
end

--- Drift the starfield. Called from menu_input.lua's onUpdate with raw dt.
_G.MenuTickStars = function(dt)
    -- Advance in whole pixels only. A sub-pixel accumulator would need floats,
    -- which the console does not have, so the phase counts dt and releases a
    -- pixel of movement when enough has passed.
    S.starPhase = S.starPhase + dt
    local steps = (S.starPhase - S.starPhase % 2048) / 2048   -- 60Hz ticks
    if steps <= 0 then return end
    S.starPhase = S.starPhase % 2048

    for i = 1, #stars do
        local st = stars[i]
        st.y = st.y + st.speed * steps
        if st.y > 240 then st.y = st.y - 248 end
        Sprite.SetPos(st.id, STAR_X[i], st.y)
    end
end

-- === the logo ============================================================
--
-- One 256x64 banner drawn as four 64x64 sprite cells side by side. Sprite cells
-- are a uniform grid, so anything wider than a cell has to be assembled.

local LOGO_CELLS = 4
-- y=24 puts the banner at 24..88, and the one-pixel bob takes it to 89. The
-- first menu option is drawn into row5 at y=90, so they clear each other by a
-- pixel. At the original y=34 the banner ended at 98 and sat eight pixels over
-- "PLAY ONLINE" — which `check_layout` cannot catch, because the logo is a
-- SPRITE and the menu row is a UI element. Two different systems, one screen.
local LOGO_X, LOGO_Y = 32, 24
local logo = {}

local function createLogo()
    if Sprite.SheetIndex("logo") < 0 then
        Debug.Log("PSXSUS menu: no sprite sheet named 'logo' - the title will not appear")
        return
    end
    for i = 1, LOGO_CELLS do
        local id = Sprite.Create("logo")
        if id < 0 then break end
        Sprite.SetFrame(id, i - 1)
        Sprite.SetIgnoreViewOffset(id, true)
        Sprite.SetLayer(id, 2)
        Sprite.SetPos(id, LOGO_X + (i - 1) * 64, LOGO_Y)
        Sprite.SetVisible(id, true)
        logo[i] = id
    end
end

local function setLogoY(y)
    for i = 1, #logo do
        Sprite.SetPos(logo[i], LOGO_X + (i - 1) * 64, y)
    end
end

_G.MenuSetLogoVisible = function(on)
    for i = 1, #logo do Sprite.SetVisible(logo[i], on) end
end

--- A one-pixel bob, on a slow cycle. Same reasoning as the starfield.
_G.MenuBobLogo = function(phase)
    setLogoY(LOGO_Y + (phase % 2))
end

-- === chrome ==============================================================

-- One plate, behind the text pages.
--
-- The menu used to be white text on pure black, which on a CRT reads as a
-- debug console rather than as a title screen. The prompt bar gets no plate of
-- its own — a permanent bar across the bottom is furniture, not information.
local pagePlate = nil

local function createChrome()
    -- Behind the nine text rows and the title, not the whole screen: a page of
    -- prose wants a slab under it, and the starfield is the point of everything
    -- outside that slab. Authored in the menu canvas, hidden at start - the
    -- splash and the main menu show no plate at all.
    pagePlate = P and P.findPlate("menu", "chrome") or nil
    P.showPlate(pagePlate, false)
end

-- === the menu ============================================================

-- Each entry is { label, action }. The action is read by menu_input.lua, which
-- is where anything that changes state belongs — this file draws.
local MAIN_MENU = {
    { "PLAY ONLINE", "play" },
    { "HOW TO PLAY", "howto" },
    { "CONTROLS", "controls" },
    { "CREDITS", "credits" },
}

_G.MenuOptionCount = function() return #MAIN_MENU end
_G.MenuActionAt = function(i)
    local e = MAIN_MENU[i]
    return e and e[2] or nil
end

-- The impostor count SCALES with the lobby, and saying "one of them" was simply
-- a lie: psxsus_match.impostor_count gives 1 at 4-6 players, 2 at 7-8 and 3 at
-- 9-10. A crewmate who thinks there is one impostor stops looking after the
-- first ejection, which is the most expensive wrong belief in the game.
local HOWTO = {
    "CREWMATES BOARD A SHIP.",
    "SOME OF THEM ARE NOT CREWMATES.",
    "4-6 PLAYERS: 1 IMPOSTOR",
    "7-8 PLAYERS: 2 IMPOSTORS",
    "9-10 PLAYERS: 3 IMPOSTORS",
    "",
    "CREW: DO EVERY TASK, OR VOTE",
    "IMPOSTOR: KILL, SABOTAGE, VENT",
    "YOU ONLY SEE WHAT IS IN SIGHT",
}

-- Sized to the ~32 characters a full-width row of the authored (proportional,
-- 16x19) font actually holds. The first version was laid out for a 40-column
-- fixed font and every line ran off the right of the screen.
--
-- Short, because the game itself now says what the buttons do: the prompt bar
-- along the bottom names whatever is available where you are standing. This page
-- is the reference, not the teacher.
local CONTROLS = {
    "MOVE        D-PAD",
    "USE / TASK  CROSS",
    "REPORT      CROSS",
    "VOTE        CROSS",
    "",
    "IMPOSTOR ONLY:",
    "KILL        SQUARE",
    "VENT        TRIANGLE",
    "SABOTAGE    L2 / R2"
}

local CREDITS = {
    "PSXSUS",
    "A GAME BY BANDWIDTH",
    "BUILT ON PSXSPLASH",
    "BY BANDWIDTH",
    "MUSIC BY MINISTUMPY.",
    "SFX BY BANDWIDTH AND",
    "NICOLAS NOBLE",
    ""
}

local function drawList(lines, title, hint)
    clearRows()
    text("title", title)
    for i = 1, ROW_COUNT do
        local s = lines[i]
        if s and s ~= "" then
            show(rowName(i), true)
            text(rowName(i), s)
        end
    end
    text("status", hint)
end

local function drawSplash()
    clearRows()
    MenuSetLogoVisible(true)
    text("title", "")
    -- Row 7 sits under the logo. The prompt bar says PRESS START; this row is
    -- deliberately empty, because a title screen that explains itself is a title
    -- screen nobody looks at.
    text("status", "")
end

local function drawMain()
    clearRows()
    MenuSetLogoVisible(true)
    text("title", "")
    -- Rows 5..8, at y = 100, 119, 138, 157. NOT row 4: the logo occupies
    -- y=24..88 and bobs to 89, and row 4 starts at 81 — the first option would
    -- be drawn straight through the title. `check_layout` cannot catch this
    -- (the logo is a sprite and the row is a UI element, two different systems
    -- on one screen), so the clearance is arithmetic that has to be written
    -- down.
    for i = 1, #MAIN_MENU do
        show(rowName(i + 4), true)
        -- The cursor is drawn as text rather than as the sprite arrow: it must
        -- line up with the row's baseline exactly, and only the font knows
        -- where that is.
        local mark = (S.cursor == i) and "  > " or "    "
        text(rowName(i + 4), mark .. MAIN_MENU[i][1])
    end
    S.optionCount = #MAIN_MENU
    text("status", "")
end

--- What the pad does on the screen currently up.
---
--- Rebuilt on every redraw rather than set once per view change, because the
--- views are entered from three different places and one of them would be
--- forgotten — leaving a prompt bar describing the previous screen, which is
--- exactly the failure the bar exists to prevent.
local function drawPrompts()
    if not P then return end
    if S.view == VIEW.SPLASH then
        P.setPrompts({ { P.BTN.START, "START" } })
    elseif S.view == VIEW.MAIN then
        P.setPrompts({ { P.BTN.DPAD, "CHOOSE" }, { P.BTN.CROSS, "SELECT" } })
    else
        P.setPrompts({ { P.BTN.CIRCLE, "BACK" } })
    end
end

local function draw()
    if S.view == VIEW.SPLASH then
        drawSplash()
    elseif S.view == VIEW.MAIN then
        drawMain()
    else
        MenuSetLogoVisible(false)
        if S.view == VIEW.HOWTO then
            drawList(HOWTO, "HOW TO PLAY", "")
        elseif S.view == VIEW.CONTROLS then
            drawList(CONTROLS, "CONTROLS", "")
        else
            drawList(CREDITS, "CREDITS", "")
        end
    end
    drawPrompts()
    -- The panel behind the text pages, but not behind the title screen: the
    -- splash and the main menu are a logo on a starfield and a plate under them
    -- would be a box around nothing.
    if P then
        P.showPlate(pagePlate, S.view ~= VIEW.SPLASH and S.view ~= VIEW.MAIN)
    end
end

_G.MenuRedraw = draw

-- === scene lifecycle =====================================================

function onSceneCreationStart()
    S.view = VIEW.SPLASH
    S.cursor = 1
    S.splashAge = 0
    S.starPhase = 0
    -- Nothing here consumes or produces a position, and the lobby is what opens
    -- the session. Turning replication off is the console's half of the same
    -- decision the server makes by not replicating a room that is not playing.
    if Net.SetReplicationEnabled then Net.SetReplicationEnabled(false) end
    Net.SetPersistent(false)
end

function onSceneCreationEnd()
    P = PSXSUS
    if not P then
        Debug.Log("PSXSUS menu: psxsus_protocol.lua is missing or attached AFTER menu.lua")
    end

    canvas = UI.FindCanvas("menu")
    if canvas < 0 then
        Debug.Log("PSXSUS menu: no canvas named 'menu' in this scene")
        return
    end
    ui["title"] = UI.FindElement(canvas, "title")
    ui["status"] = UI.FindElement(canvas, "status")
    for i = 1, ROW_COUNT do
        ui[rowName(i)] = UI.FindElement(canvas, rowName(i))
    end
    UI.SetCanvasVisible(canvas, true)

    createStars()
    createLogo()
    -- Chrome first, prompt glyphs second: both are screen-pinned sprites on the
    -- same layer, and creation order settles ties within a layer.
    createChrome()
    if P then P.initPrompts("menu") end

    -- The menu theme, from the scene's own SPU pack.
    --
    -- It used to be CD-DA track 2, and the swap is worth more than a change of
    -- source. CD-DA had to be issued at the moment the CD-ROM was LEAST
    -- available — LoadScene has just pulled the splashpack, the VRAM blob and
    -- the SPU blob off the disc — and it did not loop, because the drive has no
    -- hardware repeat and the engine-side loop that re-issued the track from
    -- psyqo's completion callback misbehaved on hardware and was reverted. A
    -- clip already resident in SPU RAM has neither problem.
    Audio.Play("menu_music")

    draw()
end

-- The title screen never talks to the server, so these exist only so the engine
-- has something to call if a stray packet arrives on a session that outlived a
-- scene load. Doing nothing is the correct response.
function onNetData(payload) end
