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

local dealerPeds = {}

local DEALER_CONFIG = {
    coords  = vector3(-5509.11, -2914.93, 1.7),
    heading = 180.0,
    model   = `U_M_M_VALGENSTOREOWNER_01`
}

RegisterNetEvent("pe_blackjack:spawnDealer")
AddEventHandler("pe_blackjack:spawnDealer", function(tableId)
    if dealerPeds[tableId] and DoesEntityExist(dealerPeds[tableId]) then
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

    local dealerPed = CreatePed(
        model,
        DEALER_CONFIG.coords.x,
        DEALER_CONFIG.coords.y,
        DEALER_CONFIG.coords.z - 1.0,
        DEALER_CONFIG.heading,
        false, true, true, true
    )

    dealerPeds[tableId] = dealerPed

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
local BET_UP    = 0x6319DB71 -- INPUT_FRONTEND_UP
local BET_DOWN  = 0x05CA7C52 -- INPUT_FRONTEND_DOWN
local BET_RIGHT = 0xDEB34313 -- INPUT_FRONTEND_RIGHT
local BET_LEFT  = 0xA65EBAB4 -- INPUT_FRONTEND_LEFT
local BET_ENTER = 0xC7B5340A -- INPUT_FRONTEND_ACCEPT (ENTER)

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
