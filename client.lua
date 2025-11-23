-- pe_blackjack/client.lua

-------------------------------------------
-- Blackjack UI (NUI)
-------------------------------------------

local uiVisible = false
local inRound   = false

RegisterNetEvent("pe_blackjack:updateUI")
AddEventHandler("pe_blackjack:updateUI", function(data)
    if not data or not data.action then return end

    if data.action == "update" then
        inRound = data.inRound and true or false

        -- UI nur zeigen, wenn Runde läuft ODER Einsatzphase aktiv ist
        local show = (data.inRound == true) or (data.showUI == true)

        if not show then
            if uiVisible then
                SendNUIMessage({ action = "close" })
                SetNuiFocus(false, false)
                uiVisible = false
            end
            return
        end

        uiVisible = true

       
        if data.showUI and not data.inRound then
            SetNuiFocus(false, true)   -- keyboard = false, mouse = true
        else
            SetNuiFocus(false, false)  -- alles beim Spiel
        end
        -- *****************

        SendNUIMessage({
            action       = "update",
            inRound      = data.inRound,
            showUI       = data.showUI,
            playerHand   = data.playerHand,
            playerValue  = data.playerValue,
            dealerHand   = data.dealerHand,
            dealerValue  = data.dealerValue,
            revealDealer = data.revealDealer,
            playerBet    = data.playerBet
        })

    elseif data.action == "close" then
        inRound = false
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

-------------------------------------------
-- NPC Dealer
-------------------------------------------

local dealerPed = nil

local DEALER_CONFIG = {
    coords  = vector3(-5509.11, -2914.93, 1.7),
    heading = 180.0,
    model   = `U_M_M_VALGENSTOREOWNER_01`
}

RegisterNetEvent("pe_blackjack:spawnDealer")
AddEventHandler("pe_blackjack:spawnDealer", function(tableId)
    if dealerPed and DoesEntityExist(dealerPed) then
        return
    end

    local model = DEALER_CONFIG.model

    if not IsModelValid(model) then
        print("[pe_blackjack] Dealer-Modell ungültig")
        return
    end

    RequestModel(model)
    while not HasModelLoaded(model) do
        Wait(0)
    end

    dealerPed = CreatePed(
        model,
        DEALER_CONFIG.coords.x,
        DEALER_CONFIG.coords.y,
        DEALER_CONFIG.coords.z - 1.0,
        DEALER_CONFIG.heading,
        false, true, true, true
    )

    SetEntityHeading(dealerPed, DEALER_CONFIG.heading)
    SetEntityCanBeDamaged(dealerPed, false)
    SetEntityInvincible(dealerPed, true)
    SetBlockingOfNonTemporaryEvents(dealerPed, true)
    FreezeEntityPosition(dealerPed, true)

    local scenario = GetHashKey("WORLD_HUMAN_POKER_PLAYER")
    TaskStartScenarioAtPosition(
        dealerPed,
        scenario,
        DEALER_CONFIG.coords.x,
        DEALER_CONFIG.coords.y,
        DEALER_CONFIG.coords.z,
        DEALER_CONFIG.heading,
        -1,
        true,
        false
    )
end)

-------------------------------------------
-- Sitzsystem für Blackjack-Tisch
-------------------------------------------

local SEAT_KEY = 0xCEFD9220 -- INPUT_PICKUP (E)

local BJ_SEATS = {
    {
        tableId = 1,
        coords  = vector3(-5512.2, -2914.1, 1.69),
        heading = 90.0
    },
    {
        tableId = 1,
        coords  = vector3(-5511.44, -2912.11, 1.69),
        heading = 0.0
    },
    {
        tableId = 1,
        coords  = vector3(-272.7, 804.0, 119.4),
        heading = 270.0
    },
    {
        tableId = 1,
        coords  = vector3(-272.2, 804.5, 119.4),
        heading = 180.0
    },
}

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

    -- >>> LOKAL: Einsatz-UI anzeigen + Mausfokus für Buttons
    uiVisible = true
    SendNUIMessage({
        action       = "update",
        inRound      = false,
        showUI       = true,
        playerHand   = {},
        dealerHand   = {},
        playerValue  = nil,
        dealerValue  = nil,
        playerBet    = currentBet or 5
    })
    -- Maus an, Tastatur bleibt im Game
    SetNuiFocus(false, true)
    -- <<<

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

            if inRound then
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
