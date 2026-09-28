-- PSXSUS lobby — pad handling.
--
-- Attach to an object in the lobby scene (any object; it draws nothing). This
-- file exists because scene scripts get no per-frame callback — they receive
-- only methodIds 1/2/3/4 — and something has to poll the pad. `onUpdate` on an
-- object is the engine's per-frame hook.
--
-- Attach order: psxsus_protocol.lua, then lobby.lua, then this.
--
-- It holds no state of its own: everything is in `_G.SUS` (see scene_lobby.lua
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

--- Send, and never let a press vanish without a trace.
---
--- `Net.SendData` returns false when the reliable queue is full AND whenever the
--- link is not Connected — and every call site here used to discard that. So
--- pressing X to join a room could do literally nothing: no join, no retry, no
--- message, forever. "I pressed X and waited five minutes" is not a mystery when
--- the press was dropped on the floor in the first frame.
---
--- On refusal the request is held and retried from onUpdate, and the player is
--- told the link is busy rather than left staring at an unchanged screen.
local pendingSend = nil

local function send(payload, what)
    if Net.SendData(payload) then
        pendingSend = nil
        return true
    end
    pendingSend = payload
    if what then SusSetStatus(what .. " - LINK BUSY, RETRYING") end
    return false
end

--- Retry the held request. Called every frame; cheap when there is nothing held.
local function retryPendingSend()
    if pendingSend == nil then return end
    if Net.SendData(pendingSend) then
        pendingSend = nil
        SusSetStatus(nil)
    end
end

--- A card save asked for last frame, carried out this one.
---
--- MemCard.Save BLOCKS for the whole card access, and a string handed to
--- UI.SetText does not reach the television until the engine draws the next
--- frame. Saving in the same frame as the button press would therefore stop the
--- console dead with the PREVIOUS message still on screen, and the player would
--- watch it freeze with no idea why. Asking here and doing it one frame later
--- means "SAVING TO CARD" is genuinely up while the card is being written.
local cardSavePending = false

local function serviceCardSave()
    if not cardSavePending then return end
    cardSavePending = false
    SusNotice(SusSaveNameToCard())
end

-- === views ===============================================================

local function onRoomList()
    local S = SUS
    local count = SusRoomCount()

    if pressed(Input.UP) and S.cursor > 1 then
        S.cursor = S.cursor - 1
        SusRedraw()
    elseif pressed(Input.DOWN) and S.cursor < count then
        S.cursor = S.cursor + 1
        SusRedraw()
    elseif pressed(Input.CROSS) and count > 0 then
        -- Remember which ship this room is on before the reply lands, so the
        -- room screen can name it immediately instead of claiming map 1 for the
        -- half second before the server confirms.
        S.roomMapId = SusRoomMapAt(S.cursor)
        send(P.joinRoom(SusRoomIdAt(S.cursor)), "JOIN")
    elseif pressed(Input.SQUARE) or pressed(Input.L1) then
        -- Hosting now goes through the map picker: which ship a room is on
        -- cannot be changed once it exists, so it has to be chosen first.
        S.private = pressed(Input.L1)
        SusBeginMapPick("host")
        SusRedraw()
    elseif pressed(Input.R1) then
        S.view = VIEW.CODE
        S.codeChars = { 1, 1, 1, 1 }
        S.codePos = 1
        SusRedraw()
    elseif pressed(Input.TRIANGLE) then
        send(P.listRooms(S.page), "REFRESH")
    elseif pressed(Input.L2) and S.page > 0 then
        -- Paging is a server round trip, not a local slice: the list can be
        -- longer than one packet, and only the server knows what is on page 2.
        send(P.listRooms(S.page - 1), "PAGE")
    elseif pressed(Input.R2) and S.page + 1 < S.pageCount then
        send(P.listRooms(S.page + 1), "PAGE")
    elseif pressed(Input.SELECT) then
        SusBeginNameEdit()
        SusRedraw()
    elseif pressed(Input.CIRCLE) then
        -- Back to the title screen. The session is dropped on the way out, which
        -- is what SetPersistent(false) means: coming back in starts a fresh one
        -- rather than reclaiming a slot the server has since given away.
        Net.SetPersistent(false)
        Scene.Load(P.SCENE.MENU)
    end
end

--- Choosing the ship before hosting.
local function onMapPick()
    local S = SUS
    local n = P.MAP_COUNT

    if pressed(Input.UP) then
        S.cursor = ((S.cursor + n - 2) % n) + 1
        SusRedraw()
    elseif pressed(Input.DOWN) then
        S.cursor = (S.cursor % n) + 1
        SusRedraw()
    elseif pressed(Input.CROSS) then
        if S.mapPickMode == "change" then
            -- Moving a room we are already in. Nothing is applied locally: the
            -- server answers with MAP_CHANGED to the whole room, and this
            -- console paints it then, along with everybody else. An owner whose
            -- request is refused (a round started underneath them) simply sees
            -- no change, which is the truth.
            send(P.setMap(S.cursor - 1), "SHIP")
            S.view = VIEW.IN_ROOM
        else
            S.mapId = S.cursor - 1
            -- Show the room screen the map we asked for straight away; the
            -- server's GameStarting is what actually decides it later.
            S.roomMapId = S.mapId
            send(P.createRoom(S.playerName, S.private, S.mapId), "HOST")
            S.view = VIEW.ROOMS
        end
        SusRedraw()
    elseif pressed(Input.CIRCLE) then
        -- Back where we came from. Cancelling a change must not drop the player
        -- into the room browser as though they had left the room.
        S.view = (S.mapPickMode == "change") and VIEW.IN_ROOM or VIEW.ROOMS
        S.cursor = 1
        SusRedraw()
    end
end

--- Dialling a name in one column at a time, exactly like the join code. Up/Down
--- cycles the letter under the caret, Left/Right moves it, X accepts.
local function onNameEntry()
    local S = SUS
    local n = #NAME_ALPHABET

    if pressed(Input.UP) then
        S.nameChars[S.namePos] = (S.nameChars[S.namePos] % n) + 1
        SusRedraw()
    elseif pressed(Input.DOWN) then
        S.nameChars[S.namePos] = ((S.nameChars[S.namePos] + n - 2) % n) + 1
        SusRedraw()
    elseif pressed(Input.RIGHT) and S.namePos < 8 then
        S.namePos = S.namePos + 1
        SusRedraw()
    elseif pressed(Input.LEFT) and S.namePos > 1 then
        S.namePos = S.namePos - 1
        SusRedraw()
    elseif pressed(Input.CROSS) then
        local chosen = SusNameString()
        -- An all-space name would show up as a blank row in every list, so it is
        -- refused by keeping the old one rather than by an error nobody can act on.
        if chosen ~= "" then
            S.playerName = chosen
            -- Into Persist in the same breath as the server. These are the two
            -- places the name has to be for it to still exist after the next
            -- Scene.Load, and splitting them is how one of them gets forgotten.
            SusRememberName(chosen)
            send(P.setName(chosen), "NAME")
        end
        S.view = VIEW.ROOMS
        SusRedraw()
    elseif pressed(Input.TRIANGLE) then
        -- Save to the memory card. Accept the dialled name first: pressing SAVE
        -- on a name you have not confirmed should save the name you are looking
        -- at, not the one you had before you started typing.
        local chosen = SusNameString()
        if chosen ~= "" then
            S.playerName = chosen
            SusRememberName(chosen)
            send(P.setName(chosen), "NAME")
        end
        cardSavePending = true
        SusNotice("SAVING TO CARD...")
    elseif pressed(Input.CIRCLE) then
        -- Cancelling is only allowed once there IS a name to fall back on. The
        -- editor is opened once, unprompted, the first time the room list
        -- arrives, and backing straight out of that would put an unnamed player
        -- into the browser — which is the state the editor exists to prevent.
        if S.playerName ~= "" then
            S.view = VIEW.ROOMS
            SusRedraw()
        end
    end
end

--- Entering a 4-character join code with a d-pad.
---
--- Up/Down cycles the character under the caret, Left/Right moves the caret,
--- X sends it. The alphabet is the protocol's CODE_ALPHABET — the same string
--- the server mints codes from — so every code that exists is reachable and no
--- code that cannot exist can be typed. That is also why there is no O/0 or I/1:
--- these get read aloud across a room.
local function onCodeEntry()
    local S = SUS
    local n = #P.CODE_ALPHABET

    if pressed(Input.UP) then
        -- +1 with wrap. `% n` is C's remainder here (LUA_NUMBER is long), but
        -- both operands are positive so it behaves as expected.
        S.codeChars[S.codePos] = (S.codeChars[S.codePos] % n) + 1
        SusRedraw()
    elseif pressed(Input.DOWN) then
        S.codeChars[S.codePos] = ((S.codeChars[S.codePos] + n - 2) % n) + 1
        SusRedraw()
    elseif pressed(Input.RIGHT) and S.codePos < P.CODE_LEN then
        S.codePos = S.codePos + 1
        SusRedraw()
    elseif pressed(Input.LEFT) and S.codePos > 1 then
        S.codePos = S.codePos - 1
        SusRedraw()
    elseif pressed(Input.CROSS) then
        send(P.joinByCode(SusCodeString()), "JOIN")
    elseif pressed(Input.CIRCLE) then
        S.view = VIEW.ROOMS
        SusRedraw()
    end
end

local function onInRoom()
    local S = SUS
    if pressed(Input.CIRCLE) then
        -- Leaving is best-effort by design: the server drops us when the link
        -- goes quiet anyway, and holding a retry here would fight the list
        -- request queued right behind it.
        Net.SendData(P.leaveRoom())
        -- Forget the room BEFORE asking for the list. This clears `rejoining`,
        -- which is what lets SusAnnounce go back to asking for a room list
        -- instead of asking about a room we just left forever. Without it the
        -- listRooms below was the only one this console would ever send.
        SusLeaveRoomState()
        S.view = VIEW.ROOMS
        send(P.listRooms(0), "REFRESH")
    elseif pressed(Input.START) and S.isOwner then
        -- The server enforces owner-only starting too; this only avoids sending
        -- a request that would be ignored.
        send(P.startGame(), "START")
    elseif pressed(Input.SQUARE) and S.isOwner then
        -- Change the ship without tearing the room down. Owner-gated on the
        -- server as well; this only avoids offering a screen whose outcome
        -- would be discarded.
        SusBeginMapPick("change")
        SusRedraw()
    end
end

local function onConnecting()
    -- The one place the raw link counters are reachable, and the one place they
    -- are worth having: a console that never connects has nothing else to say.
    if pressed(Input.SELECT) then SusToggleDiagnostics() end
end

-- === per-frame ===========================================================

-- Measured frame rate, published for the link warning.
--
-- Worth the handful of lines: a console crawling at 4fps and a console with a
-- broken cable look identical from the outside, and the difference is everything.
-- dt is 4.12 fixed point (4096 == one 30Hz frame), so a real second is 30*4096;
-- counting frames until that much dt has passed gives frames-per-second directly,
-- with no division and no `math`.
local FPS_WINDOW = 30 * 4096
local fpsAccum = 0
local fpsFrames = 0

local function trackFps(dt)
    fpsAccum = fpsAccum + (dt or 0)
    fpsFrames = fpsFrames + 1
    if fpsAccum >= FPS_WINDOW then
        _G.SusFps = fpsFrames
        fpsAccum = 0
        fpsFrames = 0
    end
end

-- How often the screen is refreshed independently of server traffic. In real
-- time, not frames: a frame-counted period silently becomes a different refresh
-- rate on a busy console.
local REDRAW_PERIOD = FPS_WINDOW / 2   -- ~2Hz
local redrawWait = 0

function onUpdate(self, dt)
    if not ready() then return end
    local S = SUS
    dt = dt or 0
    trackFps(dt)
    retryPendingSend()
    -- Before SusTickNotice, so the "SAVING TO CARD" set last frame is still the
    -- live notice when the blocking write starts, and the result replaces it
    -- rather than racing its expiry.
    serviceCardSave()
    SusTickNotice(dt)
    -- Before the connected check below, because one of the clocks it runs paces
    -- the screen you are looking at when you are NOT connected.
    SusTickLobby(dt)

    -- Keep the screen showing the LIVE link state, in EVERY view.
    --
    -- This tick used to live inside the `not IsConnected()` branch below, which
    -- returns — so the periodic redraw stopped the moment the handshake landed,
    -- and from then on the lobby only redrew when the server said something. That
    -- froze every time-varying thing on screen at whatever the last message left
    -- behind, which is why a console reported a stale link warning indefinitely
    -- while the link was in fact fine: it was evaluated once, early, and never
    -- again.
    redrawWait = redrawWait - dt
    if redrawWait <= 0 then
        redrawWait = REDRAW_PERIOD
        -- Not while STARTING: that view has already asked for a scene load, and
        -- redrawing into a scene that is going away buys nothing.
        if S.view ~= VIEW.STARTING then SusRedraw() end
    end

    if not Net.IsConnected() then
        -- Two link states (version/scene mismatch) are terminal and silent in the
        -- engine, so without the redraw above the console would sit on
        -- "connecting to server" forever with no clue which.
        onConnecting()
        return
    end
    SusAnnounce(dt)

    if S.view == VIEW.ROOMS then
        onRoomList()
    elseif S.view == VIEW.CODE then
        onCodeEntry()
    elseif S.view == VIEW.NAME then
        onNameEntry()
    elseif S.view == VIEW.MAP then
        onMapPick()
    elseif S.view == VIEW.IN_ROOM then
        onInRoom()
    end
    -- CONNECTING and STARTING take no gameplay input: one is waiting on the
    -- server, the other has already asked for a scene load.
end
