-- PSXSUS title screen — pad handling and the per-frame clock.
--
-- Attach to an object in the MENU scene (any object; it draws nothing). This
-- file exists because scene scripts get no per-frame callback — they receive
-- only methodIds 1/2/3/4 — and something has to poll the pad and drive the
-- starfield.
--
-- Attach order: psxsus_protocol.lua, then menu.lua on the scene; this on an
-- object.
--
-- It holds no state of its own: everything is in `_G.SUS` (see scene_menu.lua
-- for why that is a table and not Persist). Button constants are fields of the
-- Input table (`Input.CROSS`), not a separate Button global.

local P = nil

local function ready()
    if P then return true end
    P = PSXSUS
    return P ~= nil
end

-- A menu responds to a press, not a hold: IsPressed (edge) rather than IsHeld
-- (level), or one tap scrolls the whole list in a third of a second.
local function pressed(b) return Input.IsPressedPlayer1(b) end

--- Any button at all. The splash accepts all of them, because a player who has
--- just switched the console on does not yet know which one this game wants,
--- and "I pressed something and nothing happened" is the worst first second a
--- game can have.
local function anyPressed()
    return pressed(Input.START) or pressed(Input.CROSS) or pressed(Input.CIRCLE)
        or pressed(Input.SQUARE) or pressed(Input.TRIANGLE) or pressed(Input.SELECT)
end

local VIEW = _G.MENUVIEW

local function onSplash(dt)
    local S = SUS
    S.splashAge = S.splashAge + dt
    -- Skippable, but it also ends on its own. A splash you cannot skip wastes
    -- the time of everybody who has seen it; a splash that needs a press strands
    -- anyone who put the pad down.
    if anyPressed() or S.splashAge >= _G.MENU_SPLASH_HOLD then
        S.view = VIEW.MAIN
        S.cursor = 1
        MenuRedraw()
    end
end

local function onMain()
    local S = SUS
    local n = MenuOptionCount()

    if pressed(Input.UP) then
        -- Wrapping, not clamping. Four options on a screen with nothing else to
        -- do: stopping at the ends only makes the player press again.
        S.cursor = ((S.cursor + n - 2) % n) + 1
        MenuRedraw()
    elseif pressed(Input.DOWN) then
        S.cursor = (S.cursor % n) + 1
        MenuRedraw()
    elseif pressed(Input.CROSS) or pressed(Input.START) then
        local action = MenuActionAt(S.cursor)
        if action == "play" then
            -- The lobby opens the session; this scene never touched the link.
            -- Persistence stays OFF so the lobby starts a fresh one — carrying a
            -- stale slot in from a previous round is how a player ends up
            -- invisible in a room they think they joined.
            Net.SetPersistent(false)
            Scene.Load(P.SCENE.LOBBY)
        elseif action == "howto" then
            S.view = VIEW.HOWTO
            MenuRedraw()
        elseif action == "controls" then
            S.view = VIEW.CONTROLS
            MenuRedraw()
        elseif action == "credits" then
            S.view = VIEW.CREDITS
            MenuRedraw()
        end
    end
end

local function onTextPage()
    local S = SUS
    if pressed(Input.CIRCLE) or pressed(Input.CROSS) or pressed(Input.START) then
        S.view = VIEW.MAIN
        MenuRedraw()
    end
end

-- The logo's bob, counted in real time so it is the same speed whatever the
-- frame rate does.
local DT_SECOND = 30 * 4096
local BOB_PERIOD = DT_SECOND / 2
local bobWait = 0
local bobPhase = 0

function onUpdate(self, dt)
    if not ready() then return end
    dt = dt or 0

    MenuTickStars(dt)

    bobWait = bobWait - dt
    if bobWait <= 0 then
        bobWait = BOB_PERIOD
        bobPhase = bobPhase + 1
        MenuBobLogo(bobPhase)
    end

    local view = SUS.view
    if view == VIEW.SPLASH then
        onSplash(dt)
    elseif view == VIEW.MAIN then
        onMain()
    else
        onTextPage()
    end
end
