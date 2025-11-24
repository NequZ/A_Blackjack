-- pe_blackjack/client.lua
-- 3D-only blackjack experience (no NUI)

local bjDealerPeds = {}
local BJ_SEATS = {}
local isSeated = false
local currentSeat = nil
local currentTableId = nil
local currentSeatIndex = nil
local currentBet = 5
local lastState = nil

local cardEntities = {
    -- [tableId] = { dealer = {}, players = { [seatIndex] = {entities} } }
}

-- Control definitions
local SEAT_KEY   = 0xCEFD9220 -- INPUT_PICKUP (E)
local BET_UP     = 0x6319DB71 -- INPUT_FRONTEND_UP
local BET_DOWN   = 0x05CA7C52 -- INPUT_FRONTEND_DOWN
local BET_RIGHT  = 0xDEB34313 -- INPUT_FRONTEND_RIGHT
local BET_LEFT   = 0xA65EBAB4 -- INPUT_FRONTEND_LEFT
local BET_ENTER  = 0xC7B5340A -- INPUT_FRONTEND_ACCEPT (ENTER)
local KEY_HIT    = 0x760A9C6F -- G
local KEY_STAND  = 0x24978A28 -- H
local KEY_LEAVE  = 0xD9D0E1C0 -- SPACE

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function getTableConfig(tableId)
    if not Config or not Config.BlackjackTables then return nil end
    for _, tbl in ipairs(Config.BlackjackTables) do
        if tbl.id == tableId then
            return tbl
        end
    end
    return nil
end

local function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = GetScreenCoordFromWorldCoord(x, y, z)
    if not onScreen then return end

    SetTextScale(0.35, 0.35)
    SetTextFontForCurrentCommand(1)
    SetTextColor(255, 255, 255, 255)
    SetTextCentre(true)

    local str = CreateVarString(10, "LITERAL_STRING", text)
    DisplayText(str, _x, _y)
end

local function loadModel(hash)
    RequestModel(hash)
    while not HasModelLoaded(hash) do
        Wait(0)
    end
end

------------------------------------------------------------
-- Card entity system
------------------------------------------------------------
local function CreateCardEntity(cardData, position, rotation)
    local model = Config.CardModel or "p_cardsspread01x"
    local hash = GetHashKey(model)
    if not HasModelLoaded(hash) then
        loadModel(hash)
    end

    local obj = CreateObject(hash, position.x, position.y, position.z, false, false, false, false, true)
    SetEntityHeading(obj, rotation)
    SetEntityInvincible(obj, true)
    FreezeEntityPosition(obj, true)
    SetEntityVisible(obj, true)

    -- cardData is kept for potential future texturing/logic
    return obj
end

local function AttachCardToHand(ped, cardEntity, handIndex)
    local boneIndex = GetEntityBoneIndexByName(ped, "SKEL_R_Finger12")
    if boneIndex == -1 then
        boneIndex = GetPedBoneIndex(ped, 60309) -- fallback
    end
    local spacing = Config.CardOffsets and Config.CardOffsets.handSpacing or 0.04
    local offset = vector3(spacing * (handIndex - 1), 0.02, 0.0)
    AttachEntityToEntity(cardEntity, ped, boneIndex, offset.x, offset.y, offset.z, 0.0, 0.0, 20.0, false, false, false, false, 2, true)
end

local function clearCardEntities(tableId)
    local data = cardEntities[tableId]
    if not data then return end

    if data.dealer then
        for _, ent in ipairs(data.dealer) do
            if DoesEntityExist(ent) then
                DeleteObject(ent)
            end
        end
    end

    if data.players then
        for _, seatEntities in pairs(data.players) do
            for _, ent in ipairs(seatEntities) do
                if DoesEntityExist(ent) then
                    DeleteObject(ent)
                end
            end
        end
    end

    cardEntities[tableId] = nil
end

local function ensureCardTable(tableId)
    if not cardEntities[tableId] then
        cardEntities[tableId] = { dealer = {}, players = {} }
    end
    return cardEntities[tableId]
end

local function getSeatConfig(tableId, seatIndex)
    local tbl = getTableConfig(tableId)
    if not tbl or not tbl.seats then return nil end
    return tbl.seats[seatIndex]
end

local function cardPositionForSeat(tableId, seatIndex, cardIndex)
    local seat = getSeatConfig(tableId, seatIndex)
    if not seat then return nil end

    local offsets = Config.CardOffsets or {}
    local forwardDist = offsets.tableForward or 0.55
    local spacing = offsets.spacing or 0.15
    local height = offsets.tableHeight or 0.05

    local headingRad = math.rad(seat.heading or 0.0)
    local forward = vector3(math.sin(headingRad), -math.cos(headingRad), 0.0)
    local right = vector3(-forward.y, forward.x, 0.0)

    local base = seat.coords + forward * forwardDist + vector3(0.0, 0.0, height)
    local pos = base + right * ((cardIndex - 1) * spacing)
    local rot = (seat.heading or 0.0) - 90.0

    return pos, rot
end

local function cardPositionForDealer(tableId, cardIndex)
    local tbl = getTableConfig(tableId)
    if not tbl or not tbl.npc or not tbl.npc.coords then return nil end

    local offsets = Config.CardOffsets or {}
    local forwardDist = offsets.dealerForward or 0.6
    local spacing = offsets.spacing or 0.15
    local height = offsets.tableHeight or 0.05

    local headingRad = math.rad(tbl.npc.heading or 0.0)
    local forward = vector3(math.sin(headingRad), -math.cos(headingRad), 0.0)
    local right = vector3(-forward.y, forward.x, 0.0)

    local base = tbl.npc.coords + forward * forwardDist + vector3(0.0, 0.0, height)
    local pos = base + right * ((cardIndex - 1) * spacing)
    local rot = (tbl.npc.heading or 0.0) + 90.0

    return pos, rot
end

local function rebuildCardEntities(tableId, state)
    clearCardEntities(tableId)
    local holder = ensureCardTable(tableId)

    -- Dealer cards
    if state.dealer and state.dealer.cards then
        for idx, card in ipairs(state.dealer.cards) do
            local pos, rot = cardPositionForDealer(tableId, idx)
            if pos then
                local ent = CreateCardEntity(card, pos, rot)
                table.insert(holder.dealer, ent)
            end
        end
    end

    if state.players then
        for _, pdata in ipairs(state.players) do
            if pdata.seatIndex then
                holder.players[pdata.seatIndex] = holder.players[pdata.seatIndex] or {}
                for idx, card in ipairs(pdata.cards or {}) do
                    local pos, rot = cardPositionForSeat(tableId, pdata.seatIndex, idx)
                    if pos then
                        local ent = CreateCardEntity(card, pos, rot)
                        table.insert(holder.players[pdata.seatIndex], ent)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Seating
------------------------------------------------------------
CreateThread(function()
    while Config == nil or Config.BlackjackTables == nil do
        Wait(0)
    end

    for _, tbl in ipairs(Config.BlackjackTables) do
        if tbl.seats then
            for seatIndex, seat in ipairs(tbl.seats) do
                table.insert(BJ_SEATS, {
                    tableId = tbl.id,
                    seatIndex = seatIndex,
                    coords  = seat.coords,
                    heading = seat.heading or (tbl.npc and tbl.npc.heading) or 0.0
                })
            end
        end
    end

    print("[pe_blackjack] Seats loaded: " .. tostring(#BJ_SEATS))
end)

local function SitDown(seat)
    if isSeated then return end

    local ped = PlayerPedId()
    SetEntityCoords(ped, seat.coords.x, seat.coords.y, seat.coords.z - 1.0, false, false, false, true)
    SetEntityHeading(ped, seat.heading)

    local scenario = GetHashKey("PROP_HUMAN_SEAT_CHAIR_GENERIC")
    TaskStartScenarioAtPosition(ped, scenario, seat.coords.x, seat.coords.y, seat.coords.z, seat.heading, -1, true, false)

    FreezeEntityPosition(ped, true)

    isSeated = true
    currentSeat = seat
    currentSeatIndex = seat.seatIndex
    currentTableId = seat.tableId

    TriggerServerEvent("pe_blackjack:seatJoin", seat.tableId, seat.seatIndex)
end

local function StandUp()
    if not isSeated or not currentSeat then return end

    local ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, false)

    local heading = GetEntityHeading(ped)
    local backX   = currentSeat.coords.x - math.sin(math.rad(heading)) * 0.5
    local backY   = currentSeat.coords.y + math.cos(math.rad(heading)) * 0.5
    SetEntityCoords(ped, backX, backY, currentSeat.coords.z, false, false, false, true)

    TriggerServerEvent("pe_blackjack:seatLeave", currentTableId)
    clearCardEntities(currentTableId)

    isSeated = false
    currentSeat = nil
    currentSeatIndex = nil
    currentTableId = nil
    lastState = nil
end

------------------------------------------------------------
-- Dealer spawning and blips
------------------------------------------------------------
CreateThread(function()
    if not Config.BlackjackTables or #Config.BlackjackTables == 0 then
        print("[pe_blackjack] No tables configured")
        return
    end

    local models = {}
    for _, tbl in ipairs(Config.BlackjackTables) do
        local npcCfg = tbl.npc
        if npcCfg and npcCfg.model then
            local hash = GetHashKey(npcCfg.model)
            if IsModelValid(hash) then
                models[hash] = true
            else
                print(("[pe_blackjack] Invalid model '%s' for table %s"):format(tostring(npcCfg.model), tostring(tbl.id)))
            end
        end
    end

    for hash, _ in pairs(models) do
        loadModel(hash)
    end

    while true do
        local sleep = 1000
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        for _, tbl in ipairs(Config.BlackjackTables) do
            local npcCfg = tbl.npc
            if npcCfg and npcCfg.coords then
                local dist = #(playerCoords - npcCfg.coords)
                local spawnRadius = npcCfg.spawnRadius or 80.0
                local tableId = tbl.id

                if dist <= spawnRadius then
                    sleep = 250
                    if not bjDealerPeds[tableId] or not DoesEntityExist(bjDealerPeds[tableId]) then
                        local ped = Citizen.InvokeNative(0xD49F9B0955C367DE, GetHashKey(npcCfg.model), npcCfg.coords.x, npcCfg.coords.y, npcCfg.coords.z, npcCfg.heading or 0.0, false, false, false, false)
                        if ped ~= 0 then
                            Citizen.InvokeNative(0x283978A15512B2FE, ped, true)
                            SetEntityAsMissionEntity(ped, true, false)
                            SetEntityInvincible(ped, true)
                            SetBlockingOfNonTemporaryEvents(ped, true)
                            FreezeEntityPosition(ped, true)
                            SetEntityVisible(ped, true)
                            SetPedCanRagdoll(ped, false)
                            bjDealerPeds[tableId] = ped
                            print(("[pe_blackjack] Dealer spawned for table '%s'"):format(tableId))
                        end
                    end
                else
                    if bjDealerPeds[tableId] and DoesEntityExist(bjDealerPeds[tableId]) then
                        DeletePed(bjDealerPeds[tableId])
                        bjDealerPeds[tableId] = nil
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

CreateThread(function()
    if not Config.BlackjackTables then return end

    for _, tbl in ipairs(Config.BlackjackTables) do
        local npcCfg = tbl.npc
        if npcCfg and npcCfg.coords and npcCfg.blipSprite then
            local blip = Citizen.InvokeNative(0x554D9D53F696D002, npcCfg.blipSprite, npcCfg.coords.x, npcCfg.coords.y, npcCfg.coords.z)
            local labelText = npcCfg.blipLabel or ("Blackjack #" .. tostring(tbl.id))
            local label = CreateVarString(10, "LITERAL_STRING", labelText)
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, label)
        end
    end
end)

------------------------------------------------------------
-- State handling
------------------------------------------------------------
RegisterNetEvent("pe_blackjack:stateUpdate")
AddEventHandler("pe_blackjack:stateUpdate", function(tableId, state)
    if not tableId or not state then return end
    if currentTableId ~= tableId then return end

    lastState = state

    if state.playerBet then
        currentBet = state.playerBet
    end

    rebuildCardEntities(tableId, state)
end)

------------------------------------------------------------
-- Input + drawing loop
------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()
        local pCoords = GetEntityCoords(ped)

        if isSeated then
            local tblCfg = getTableConfig(currentTableId)
            local hintCoords = tblCfg and tblCfg.npc and (tblCfg.npc.coords + vector3(0.0, 0.0, 1.0)) or (pCoords + vector3(0.0, 0.0, 1.0))

            if IsControlJustPressed(0, KEY_LEAVE) then
                StandUp()
            end

            if lastState then
                local phase = lastState.phase
                if phase == "betting" then
                    DrawText3D(hintCoords.x, hintCoords.y, hintCoords.z, "↑/↓ Einsatz ±5 | ←/→ ±1 | ENTER bestätigen | SPACE aufstehen")

                    if IsControlJustPressed(0, BET_UP) then
                        currentBet = currentBet + 5
                    elseif IsControlJustPressed(0, BET_DOWN) then
                        currentBet = math.max(1, currentBet - 5)
                    elseif IsControlJustPressed(0, BET_RIGHT) then
                        currentBet = currentBet + 1
                    elseif IsControlJustPressed(0, BET_LEFT) then
                        currentBet = math.max(1, currentBet - 1)
                    elseif IsControlJustPressed(0, BET_ENTER) then
                        TriggerServerEvent("pe_blackjack:setBet", currentTableId, currentBet)
                    end
                elseif phase == "playerTurn" then
                    local serverId = GetPlayerServerId(PlayerId())
                    if lastState.currentTurn == serverId then
                        DrawText3D(hintCoords.x, hintCoords.y, hintCoords.z, "G: Karte ziehen | H: halten | SPACE: aufstehen")
                        if IsControlJustPressed(0, KEY_HIT) then
                            TriggerServerEvent("pe_blackjack:hit", currentTableId)
                        elseif IsControlJustPressed(0, KEY_STAND) then
                            TriggerServerEvent("pe_blackjack:stand", currentTableId)
                        end
                    else
                        DrawText3D(hintCoords.x, hintCoords.y, hintCoords.z, "Warte auf deinen Zug... SPACE: aufstehen")
                    end
                else
                    DrawText3D(hintCoords.x, hintCoords.y, hintCoords.z, "Runde läuft... SPACE: aufstehen")
                end
            else
                DrawText3D(pCoords.x, pCoords.y, pCoords.z + 1.0, "Warte auf nächste Runde...")
            end
        else
            local closestSeat = nil
            local closestDist = 1.5

            for _, seat in ipairs(BJ_SEATS) do
                local dist = #(pCoords - seat.coords)
                if dist < closestDist then
                    closestDist = dist
                    closestSeat = seat
                end
            end

            if closestSeat then
                DrawText3D(closestSeat.coords.x, closestSeat.coords.y, closestSeat.coords.z + 0.8, "Drücke ~COLOR_GREEN~E~COLOR_WHITE~, um dich zu setzen")
                if IsControlJustPressed(0, SEAT_KEY) then
                    SitDown(closestSeat)
                end
            end
        end
    end
end)

------------------------------------------------------------
-- Round cleanup
------------------------------------------------------------
RegisterNetEvent("pe_blackjack:roundEnded")
AddEventHandler("pe_blackjack:roundEnded", function(tableId)
    if currentTableId == tableId then
        clearCardEntities(tableId)
    end
end)
