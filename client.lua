-- pe_blackjack/client.lua

-------------------------------------------
-- Blackjack UI (NUI)
-------------------------------------------

local uiVisible = false
local inRound   = false
local betPhase  = false
local showUI    = false
local currentBet = 5

RegisterNetEvent("pe_blackjack:updateUI")
AddEventHandler("pe_blackjack:updateUI", function(data)
    if not data or not data.action then return end

    if data.action == "update" then
        inRound  = data.inRound and true or false
        betPhase = (data.showUI == true) and not inRound
        showUI   = (data.inRound == true) or (data.showUI == true)

        if data.playerBet then
            local parsed = math.floor(data.playerBet)
            if parsed < 1 then parsed = 1 end
            if parsed > 1000 then parsed = 1000 end
            currentBet = parsed
        end

        if not showUI then
            if uiVisible then
                SendNUIMessage({ action = "close" })
                SetNuiFocus(false, false)
                uiVisible = false
            end
            return
        end

        uiVisible = true

        if betPhase then
            SetNuiFocus(false, true)   -- Maus aktiv, Tastatur bleibt fürs Spiel
        else
            SetNuiFocus(false, false)
        end

        SendNUIMessage({
            action       = "update",
            inRound      = inRound,
            showUI       = showUI,
            betPhase     = betPhase,
            playerHand   = data.playerHand or {},
            playerValue  = data.playerValue,
            dealerHand   = data.dealerHand or {},
            dealerValue  = data.dealerValue,
            revealDealer = data.revealDealer,
            playerBet    = currentBet
        })

    elseif data.action == "close" then
        inRound = false
        betPhase = false
        showUI = false
        if uiVisible then
            SendNUIMessage({ action = "close" })
            SetNuiFocus(false, false)
            uiVisible = false
        end
    end
end)

-- NUI Callback: Einsatz setzen
RegisterNUICallback("setBet", function(data, cb)
    local bet = tonumber(data.bet)
    if bet then
        TriggerServerEvent("pe_blackjack:setBet", bet)
    end
    if cb then cb("ok") end
end)

local function updateBetDisplay()
    SendNUIMessage({ action = "betLocal", bet = currentBet })
end

local function adjustBet(delta)
    currentBet = math.floor(currentBet + delta)
    if currentBet < 1 then currentBet = 1 end
    if currentBet > 1000 then currentBet = 1000 end
    updateBetDisplay()
end

-------------------------------------------
-- NPC Dealer
-------------------------------------------

-------------------------------------------
-- Blackjack Dealer NPCs (Auto-Spawn)
-------------------------------------------

-------------------------------------------
-- Blackjack Dealer NPCs (Auto-Spawn)
-------------------------------------------

local bjDealerPeds = {} -- bjDealerPeds[tableId] = ped

CreateThread(function()
    if not Config.BlackjackTables or #Config.BlackjackTables == 0 then
        print("[pe_blackjack] WARNUNG: Keine Tische in Config.BlackjackTables definiert.")
        return
    end

    -- Modelle vorladen
    local models = {}
    for _, tbl in ipairs(Config.BlackjackTables) do
        local npcCfg = tbl.npc
        if npcCfg and npcCfg.model then
            local hash = GetHashKey(npcCfg.model)
            if IsModelValid(hash) then
                models[hash] = true
            else
                print(("[pe_blackjack] WARNUNG: Model '%s' ist ungültig (Tisch %s)."):format(
                    npcCfg.model, tbl.id
                ))
            end
        end
    end

    for hash, _ in pairs(models) do
        RequestModel(hash)
    end

    local allLoaded = false
    while not allLoaded do
        allLoaded = true
        for hash, _ in pairs(models) do
            if not HasModelLoaded(hash) then
                allLoaded = false
                break
            end
        end
        Wait(0)
    end

    -- Spawn / Despawn Loop
    while true do
        local sleep = 1000
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        for _, tbl in ipairs(Config.BlackjackTables) do
            local npcCfg = tbl.npc
            if npcCfg and npcCfg.coords then
                local dist        = #(playerCoords - npcCfg.coords)
                local spawnRadius = npcCfg.spawnRadius or 80.0
                local tableId     = tbl.id

                if dist <= spawnRadius then
                    sleep = 250

                    if not bjDealerPeds[tableId] or not DoesEntityExist(bjDealerPeds[tableId]) then
                        local x = npcCfg.coords.x
                        local y = npcCfg.coords.y
                        local z = npcCfg.coords.z  -- EXAKT aus Config, kein GroundZ

                        local modelHash = GetHashKey(npcCfg.model)
                        if not IsModelValid(modelHash) then
                            print(("[pe_blackjack] WARNUNG: Ungültiges Model '%s' für Tisch %s."):format(
                                tostring(npcCfg.model), tostring(tableId)
                            ))
                        else
                            local ped = Citizen.InvokeNative(
                                0xD49F9B0955C367DE,  -- CREATE_PED
                                modelHash,
                                x, y, z,
                                npcCfg.heading or 0.0,
                                false, false, false, false
                            )

                            if ped ~= 0 then
                                Citizen.InvokeNative(0x283978A15512B2FE, ped, true) -- Outfit

                                SetEntityAsMissionEntity(ped, true, false)
                                SetEntityInvincible(ped, true)
                                SetBlockingOfNonTemporaryEvents(ped, true)
                                FreezeEntityPosition(ped, true)
                                SetEntityVisible(ped, true)
                                SetPedCanRagdoll(ped, false)

                                bjDealerPeds[tableId] = ped
                                print(("[pe_blackjack] Dealer für Tisch '%s' gespawnt."):format(tableId))
                            else
                                print(("[pe_blackjack] Konnte Dealer für Tisch '%s' nicht spawnen."):format(tableId))
                            end
                        end
                    end
                else
                    -- Außerhalb Radius -> despawnen
                    if bjDealerPeds[tableId] and DoesEntityExist(bjDealerPeds[tableId]) then
                        DeletePed(bjDealerPeds[tableId])
                        bjDealerPeds[tableId] = nil
                        print(("[pe_blackjack] Dealer für Tisch '%s' despawned (außerhalb Streamingdistanz)."):format(tableId))
                    end
                end
            end
        end

        Wait(sleep)
    end
end)


-- BLIPs für alle Blackjack-Tische

CreateThread(function()
    if not Config.BlackjackTables then return end

    for _, tbl in ipairs(Config.BlackjackTables) do
        local npcCfg = tbl.npc
        if npcCfg and npcCfg.coords and npcCfg.blipSprite then
            local blip = Citizen.InvokeNative(
                0x554D9D53F696D002, -- _BLIP_ADD_FOR_COORDS
                npcCfg.blipSprite,
                npcCfg.coords.x,
                npcCfg.coords.y,
                npcCfg.coords.z
            )

            local labelText = npcCfg.blipLabel or ("Blackjack #" .. tostring(tbl.id))
            local label = CreateVarString(10, "LITERAL_STRING", labelText)
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, label) -- SET_BLIP_NAME
        end
    end
end)



-------------------------------------------
-- Sitzsystem für Blackjack-Tisch
-------------------------------------------

local SEAT_KEY = 0xCEFD9220 -- INPUT_PICKUP (E)
local BET_UP    = 0x6319DB71 -- INPUT_FRONTEND_UP
local BET_DOWN  = 0x05CA7C52 -- INPUT_FRONTEND_DOWN
local BET_RIGHT = 0xDEB34313 -- INPUT_FRONTEND_RIGHT
local BET_LEFT  = 0xA65EBAB4 -- INPUT_FRONTEND_LEFT
local BET_ENTER = 0xC7B5340A -- INPUT_FRONTEND_ACCEPT (ENTER)

local BJ_SEATS = {}

CreateThread(function()
   
    while Config == nil or Config.BlackjackTables == nil do
        Wait(0)
    end

    for _, tbl in ipairs(Config.BlackjackTables) do
        if tbl.seats then
            for _, seat in ipairs(tbl.seats) do
                table.insert(BJ_SEATS, {
                    tableId = tbl.id,
                    coords  = seat.coords,
                    heading = seat.heading or (tbl.npc and tbl.npc.heading) or 0.0
                })
            end
        end
    end

    print("[pe_blackjack] Seats aus Config geladen: " .. tostring(#BJ_SEATS))
end)


local isSeated    = false
local currentSeat = nil

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
local function SitDown(seat)
    if isSeated then return end

    local ped = PlayerPedId()

    -- Spieler an den Stuhl teleportieren
    SetEntityCoords(ped, seat.coords.x, seat.coords.y, seat.coords.z - 1.0, false, false, false, true)
    SetEntityHeading(ped, seat.heading)

    local scenario = GetHashKey("PROP_HUMAN_SEAT_CHAIR_GENERIC")
    TaskStartScenarioAtPosition(
        ped,
        scenario,
        seat.coords.x, seat.coords.y, seat.coords.z,
        seat.heading,
        -1,
        true,
        false
    )

    FreezeEntityPosition(ped, true)

    isSeated    = true
    currentSeat = seat

    -- Server: Blackjack beitreten
    TriggerServerEvent("pe_blackjack:seatJoin", seat.tableId)

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

    TriggerServerEvent("pe_blackjack:seatLeave", currentSeat.tableId)

    -- UI sicher zu
    if uiVisible then
        SendNUIMessage({ action = "close" })
        SetNuiFocus(false, false)
        uiVisible = false
    end

    betPhase   = false
    showUI     = false
    isSeated    = false
    currentSeat = nil
end

CreateThread(function()
    while true do
        Wait(0)

        local ped     = PlayerPedId()
        local pCoords = GetEntityCoords(ped)

        if isSeated then
            if IsControlJustPressed(0, 0xD9D0E1C0) then -- SPACE
                StandUp()
            end

            if betPhase and not inRound then
                DrawText3D(
                    pCoords.x,
                    pCoords.y,
                    pCoords.z + 1.0,
                    "Pfeile: Einsatz anpassen | ENTER bestätigen | SPACE aufstehen"
                )

                if IsControlJustPressed(0, BET_UP) then
                    adjustBet(5)
                end
                if IsControlJustPressed(0, BET_DOWN) then
                    adjustBet(-5)
                end
                if IsControlJustPressed(0, BET_RIGHT) then
                    adjustBet(1)
                end
                if IsControlJustPressed(0, BET_LEFT) then
                    adjustBet(-1)
                end
                if IsControlJustPressed(0, BET_ENTER) then
                    TriggerServerEvent("pe_blackjack:setBet", currentBet)
                end
            elseif inRound then
                DrawText3D(
                    pCoords.x,
                    pCoords.y,
                    pCoords.z + 1.0,
                    "G = Karte ziehen | H = halten | SPACE = aufstehen"
                )

                if IsControlJustPressed(0, 0x760A9C6F) then -- G
                    TriggerServerEvent("pe_blackjack:hit")
                end

                if IsControlJustPressed(0, 0x24978A28) then -- H
                    TriggerServerEvent("pe_blackjack:stand")
                end
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
                DrawText3D(
                    closestSeat.coords.x,
                    closestSeat.coords.y,
                    closestSeat.coords.z + 0.8,
                    "Drücke ~COLOR_GREEN~E~COLOR_WHITE~, um dich zu setzen"
                )

                if IsControlJustPressed(0, SEAT_KEY) then
                    SitDown(closestSeat)
                end
            end
        end
    end
end)
