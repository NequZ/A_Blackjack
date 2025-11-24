-- pe_blackjack/server.lua
-- Server-side blackjack logic with 3D state updates (no NUI)

local WAIT_TIME_MS = 20000
local BASE_BET = 5

local DISCORD_WEBHOOK = "https://discordapp.com/api/webhooks/1442193509263081472/uzBTV6KD4j3nbFU9466erUFKTXgkJdei7-5GMaMqqYemaKVv3ScM3eBtN03x4vAJnKds"

------------------------------------------------------------
-- VORP Core helpers
------------------------------------------------------------
local VorpCore = nil
TriggerEvent("getCore", function(core)
    VorpCore = core
end)

local function getCharacter(src)
    if not VorpCore or not VorpCore.getUser then return nil end
    local user = VorpCore.getUser(src)
    if not user then return nil end
    if type(user.getUsedCharacter) == "function" then
        return user.getUsedCharacter()
    end
    return user.getUsedCharacter
end

local function canPayBet(src, amount)
    local char = getCharacter(src)
    if not char then return true end
    return (char.money or 0) >= amount
end

local function removeMoney(src, amount)
    local char = getCharacter(src)
    if not char then return end
    char.removeCurrency(0, amount)
end

local function addMoney(src, amount)
    local char = getCharacter(src)
    if not char then return end
    char.addCurrency(0, amount)
end

------------------------------------------------------------
-- Cards
------------------------------------------------------------
local cards = { "2","3","4","5","6","7","8","9","10","J","Q","K","A" }
local suits = { "♠", "♥", "♦", "♣" }

local function buildDeck()
    local d = {}
    for _, v in ipairs(cards) do
        for _, s in ipairs(suits) do
            d[#d+1] = v .. s
        end
    end
    return d
end

local function shuffleDeck(deck)
    math.randomseed(os.time())
    for i = #deck, 2, -1 do
        local j = math.random(1, i)
        deck[i], deck[j] = deck[j], deck[i]
    end
end

local function cardValue(v)
    if v == "J" or v == "Q" or v == "K" then
        return 10
    elseif v == "A" then
        return 11
    else
        return tonumber(v)
    end
end

local function getCardShort(card)
    local value = card:match("^(%d+)")
    if not value then
        value = card:sub(1,1)
    end
    return value
end

local function handValue(hand)
    local total = 0
    local aces  = 0

    for _, card in ipairs(hand) do
        local v = getCardShort(card)
        if v == "A" then
            aces = aces + 1
            total = total + 11
        else
            total = total + cardValue(v)
        end
    end

    while total > 21 and aces > 0 do
        total = total - 10
        aces  = aces - 1
    end

    return total
end

local function drawCard(state)
    local deck = state.deck
    if #deck == 0 then
        state.deck = buildDeck()
        shuffleDeck(state.deck)
        deck = state.deck
    end
    local card = deck[#deck]
    deck[#deck] = nil
    return card
end

------------------------------------------------------------
-- State storage per table
------------------------------------------------------------
local tables = {}
local playerTables = {}

local function ensureTable(tableId)
    if not tables[tableId] then
        tables[tableId] = {
            id = tableId,
            inRound = false,
            phase = "idle", -- idle | betting | dealing | playerTurn | dealerTurn | payout
            players = {}, -- [src] = {seatIndex=number, hand={}, stand=false, bust=false, bet=nil, desiredBet=BASE_BET}
            dealerHand = {},
            deck = {},
            turnOrder = {},
            currentTurnIndex = 0,
            waitingTimer = nil
        }
    end
    return tables[tableId]
end

------------------------------------------------------------
-- Discord logging
------------------------------------------------------------
local function sendDiscordEmbed(message, opts)
    if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == "" then
        return
    end

    opts = opts or {}
    local src   = opts.src or 0
    local title = opts.title or "Blackjack"
    local color = opts.color or 3447003

    local playerName = nil
    if src ~= 0 then
        playerName = GetPlayerName(src)
    end

    local embed = {
        title = title,
        description = message,
        color = color,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        footer = {
            text = playerName and (("Spieler: %s (ID: %d)"):format(playerName, src)) or "System"
        }
    }

    PerformHttpRequest(DISCORD_WEBHOOK, function() end, "POST", json.encode({ embeds = { embed } }), { ["Content-Type"] = "application/json" })
end

------------------------------------------------------------
-- Utility
------------------------------------------------------------
local function broadcast(msg)
    print(("[Blackjack] %s"):format(msg))
end

local function sendToPlayer(src, msg)
    if src == 0 then return end
    TriggerClientEvent("chat:addMessage", src, { args = { "^3Blackjack", msg } })
end

local function anyActivePlayers(state)
    for _src, _ in pairs(state.players) do
        return true
    end
    return false
end

------------------------------------------------------------
-- Networked state sharing
------------------------------------------------------------
local function buildStatePayload(state, revealDealer, targetSrc)
    local payload = {
        phase = state.phase,
        currentTurn = nil,
        dealer = {},
        players = {},
        playerBet = nil
    }

    if state.currentTurnIndex and state.turnOrder[state.currentTurnIndex] then
        payload.currentTurn = state.turnOrder[state.currentTurnIndex]
    end

    if revealDealer then
        payload.dealer.cards = state.dealerHand
    else
        payload.dealer.cards = {}
        for i, card in ipairs(state.dealerHand) do
            if i == 2 then
                payload.dealer.cards[#payload.dealer.cards+1] = "??"
            else
                payload.dealer.cards[#payload.dealer.cards+1] = card
            end
        end
    end

    for src, p in pairs(state.players) do
        table.insert(payload.players, {
            id = src,
            seatIndex = p.seatIndex,
            cards = p.hand,
            status = p.bust and "bust" or (p.stand and "stand" or "active"),
            bet = p.bet or p.desiredBet or BASE_BET
        })
        if targetSrc and src == targetSrc then
            payload.playerBet = p.desiredBet or BASE_BET
        end
    end

    return payload
end

local function sendStateUpdate(tableId, revealDealer)
    local state = tables[tableId]
    if not state then return end

    for src, _ in pairs(state.players) do
        local payload = buildStatePayload(state, revealDealer, src)
        TriggerClientEvent("pe_blackjack:stateUpdate", src, tableId, payload)
    end
end
------------------------------------------------------------
-- Dealer logic and resolution
------------------------------------------------------------
local function dealerPlay(state)
    state.phase = "dealerTurn"
    local dealerValue = handValue(state.dealerHand)
    while dealerValue < 17 do
        state.dealerHand[#state.dealerHand+1] = drawCard(state)
        dealerValue = handValue(state.dealerHand)
    end
    return dealerValue
end

local function finishRound(tableId)
    local state = tables[tableId]
    if not state then return end

    state.phase = "dealerTurn"
    sendStateUpdate(tableId, true)

    if not anyActivePlayers(state) then
        state.inRound = false
        state.dealerHand = {}
        state.turnOrder = {}
        state.currentTurnIndex = 0
        state.phase = "idle"
        return
    end

    local dealerValue = dealerPlay(state)

    state.phase = "payout"
    for src, p in pairs(state.players) do
        local hv = handValue(p.hand)
        local bet = p.bet or BASE_BET
        local result
        local payout = 0
        local outcome

        if p.bust then
            result = ("Verloren! Überkauft mit %d."):format(hv)
            payout = 0
            outcome = "LOSS"
        elseif dealerValue > 21 then
            result = ("Gewonnen! Dealer überkauft (%d), du hast %d."):format(dealerValue, hv)
            payout = bet * 2
            outcome = "WIN"
        elseif hv > dealerValue then
            result = ("Gewonnen! Deine %d schlagen Dealer %d."):format(hv, dealerValue)
            payout = bet * 2
            outcome = "WIN"
        elseif hv < dealerValue then
            result = ("Verloren! Dealer %d schlägt deine %d."):format(dealerValue, hv)
            payout = 0
            outcome = "LOSS"
        else
            result = ("Push! Beide %d."):format(hv)
            payout = bet
            outcome = "PUSH"
        end

        if payout > 0 then
            addMoney(src, payout)
        end

        sendToPlayer(src, result .. (" (Einsatz $%d, Auszahlung $%d)"):format(bet, payout))

        if outcome == "WIN" or outcome == "LOSS" then
            local color = outcome == "WIN" and 3066993 or 15158332
            local desc = string.format("**Ergebnis:** %s\n**Hand:** %s (%d)\n**Dealer:** %s (%d)\n**Einsatz:** $%d\n**Auszahlung:** $%d", outcome == "WIN" and "Gewonnen" or "Verloren", table.concat(p.hand, " "), hv, table.concat(state.dealerHand, " "), dealerValue, bet, payout)
            sendDiscordEmbed(desc, { src = src, title = "Blackjack - " .. outcome, color = color })
        end
    end

    sendStateUpdate(tableId, true)

    SetTimeout(8000, function()
        state.inRound = false
        state.dealerHand = {}
        state.turnOrder = {}
        state.currentTurnIndex = 0
        state.phase = anyActivePlayers(state) and "betting" or "idle"
        for _, p in pairs(state.players) do
            p.hand = {}
            p.bet = nil
            p.stand = false
            p.bust = false
        end
        sendStateUpdate(tableId, false)
        if anyActivePlayers(state) then
            TriggerClientEvent("pe_blackjack:roundEnded", -1, tableId)
            state.waitingTimer = nil
            state.waitingTimer = SetTimeout(WAIT_TIME_MS, function()
                state.waitingTimer = nil
                if anyActivePlayers(state) and not state.inRound then
                    startRound(tableId, 0)
                end
            end)
        end
    end)
end
------------------------------------------------------------
-- Turn handling
------------------------------------------------------------
local function nextTurn(tableId)
    local state = tables[tableId]
    if not state then return end

    local totalPlayers = #state.turnOrder
    local startIndex = state.currentTurnIndex

    for i = 1, totalPlayers do
        local idx = ((startIndex + i - 1) % totalPlayers) + 1
        local src = state.turnOrder[idx]
        local pdata = state.players[src]
        if pdata and not pdata.bust and not pdata.stand then
            state.currentTurnIndex = idx
            state.phase = "playerTurn"
            sendStateUpdate(tableId, false)
            return
        end
    end

    finishRound(tableId)
end

local function handleHit(src, tableId)
    local state = tables[tableId]
    if not state or not state.inRound then return end
    if state.turnOrder[state.currentTurnIndex] ~= src then return end

    local pdata = state.players[src]
    if not pdata or pdata.bust or pdata.stand then return end

    pdata.hand[#pdata.hand+1] = drawCard(state)
    local hv = handValue(pdata.hand)
    if hv > 21 then
        pdata.bust = true
        sendToPlayer(src, "Überkauft!")
        nextTurn(tableId)
    else
        sendStateUpdate(tableId, false)
    end
end

local function handleStand(src, tableId)
    local state = tables[tableId]
    if not state or not state.inRound then return end
    if state.turnOrder[state.currentTurnIndex] ~= src then return end

    local pdata = state.players[src]
    if not pdata or pdata.bust or pdata.stand then return end

    pdata.stand = true
    nextTurn(tableId)
end

------------------------------------------------------------
-- Round start
------------------------------------------------------------
function startRound(tableId, srcStarter)
    local state = tables[tableId]
    if not state then return end
    if state.inRound then
        sendToPlayer(srcStarter, "Runde läuft bereits.")
        return
    end
    if not anyActivePlayers(state) then
        sendToPlayer(srcStarter, "Keine Spieler am Tisch.")
        return
    end

    state.inRound = true
    state.phase = "dealing"
    state.deck = buildDeck()
    shuffleDeck(state.deck)
    state.dealerHand = {}
    state.turnOrder = {}
    state.currentTurnIndex = 0

    for src, pdata in pairs(state.players) do
        local bet = math.floor(pdata.desiredBet or BASE_BET)
        bet = math.max(1, math.min(1000, bet))
        if canPayBet(src, bet) then
            removeMoney(src, bet)
            pdata.bet = bet
            pdata.hand = { drawCard(state), drawCard(state) }
            pdata.stand = false
            pdata.bust = false
            table.insert(state.turnOrder, src)
            sendToPlayer(src, ("Einsatz $%d platziert."):format(bet))
        else
            sendToPlayer(src, ("Du hast nicht genug Geld für $%d."):format(bet))
            state.players[src] = nil
            playerTables[src] = nil
        end
    end

    if #state.turnOrder == 0 then
        state.inRound = false
        state.phase = "betting"
        sendStateUpdate(tableId, false)
        return
    end

    state.dealerHand[#state.dealerHand+1] = drawCard(state)
    state.dealerHand[#state.dealerHand+1] = drawCard(state)

    state.phase = "playerTurn"
    state.currentTurnIndex = 1
    sendStateUpdate(tableId, false)

    local allBlackjack = true
    for src, pdata in pairs(state.players) do
        if handValue(pdata.hand) ~= 21 then
            allBlackjack = false
        else
            pdata.stand = true
        end
    end
    if allBlackjack then
        finishRound(tableId)
    end
end
------------------------------------------------------------
-- Waiting timer
------------------------------------------------------------
local function startWaitingTimer(tableId)
    local state = ensureTable(tableId)
    if state.waitingTimer or state.inRound then
        return
    end
    state.phase = "betting"
    sendStateUpdate(tableId, false)
    state.waitingTimer = SetTimeout(WAIT_TIME_MS, function()
        state.waitingTimer = nil
        if anyActivePlayers(state) and not state.inRound then
            startRound(tableId, 0)
        end
    end)
end
------------------------------------------------------------
-- Events
------------------------------------------------------------
RegisterNetEvent("pe_blackjack:seatJoin")
AddEventHandler("pe_blackjack:seatJoin", function(tableId, seatIndex)
    local src = source
    local state = ensureTable(tableId)

    if state.players[src] then
        sendToPlayer(src, "Du sitzt bereits.")
        return
    end

    if state.inRound then
        sendToPlayer(src, "Warte bis zur n\u00e4chsten Runde.")
        return
    end

    state.players[src] = { seatIndex = seatIndex, hand = {}, stand = false, bust = false, desiredBet = BASE_BET }
    playerTables[src] = tableId
    broadcast(("[%d] sitzt jetzt an Tisch %s."):format(src, tostring(tableId)))

    startWaitingTimer(tableId)
    sendStateUpdate(tableId, false)
end)
RegisterNetEvent("pe_blackjack:seatLeave")
AddEventHandler("pe_blackjack:seatLeave", function(tableId)
    local src = source
    local state = tables[tableId]
    if not state or not state.players[src] then
        sendToPlayer(src, "Du sitzt nicht am Tisch.")
        return
    end

    if state.inRound then
        sendToPlayer(src, "Du verlässt den Tisch während der Runde.")
    end

    state.players[src] = nil
    playerTables[src] = nil
    broadcast(("[%d] hat Tisch %s verlassen."):format(src, tostring(tableId)))

    if state.inRound and not anyActivePlayers(state) then
        state.inRound = false
        state.phase = "idle"
        state.dealerHand = {}
        state.turnOrder = {}
        state.currentTurnIndex = 0
        TriggerClientEvent("pe_blackjack:roundEnded", -1, tableId)
    elseif not state.inRound and anyActivePlayers(state) then
        sendStateUpdate(tableId, false)
    end
end)
AddEventHandler("playerDropped", function()
    local src = source
    local tableId = playerTables[src]
    if not tableId then return end
    local state = tables[tableId]
    if not state then return end
    state.players[src] = nil
    playerTables[src] = nil
    if state.inRound and not anyActivePlayers(state) then
        state.inRound = false
        state.phase = "idle"
        state.dealerHand = {}
        state.turnOrder = {}
        state.currentTurnIndex = 0
        TriggerClientEvent("pe_blackjack:roundEnded", -1, tableId)
    elseif not state.inRound and anyActivePlayers(state) then
        sendStateUpdate(tableId, false)
    end
end)
RegisterNetEvent("pe_blackjack:setBet")
AddEventHandler("pe_blackjack:setBet", function(tableId, bet)
    local src = source
    local state = tables[tableId]
    if not state then return end
    local p = state.players[src]
    if not p then
        sendToPlayer(src, "Du sitzt nicht am Tisch.")
        return
    end
    if state.inRound then
        sendToPlayer(src, "Einsatz nur zwischen den Runden.")
        return
    end

    bet = math.floor(bet or BASE_BET)
    bet = math.max(1, math.min(1000, bet))
    p.desiredBet = bet
    sendToPlayer(src, ("Einsatz gesetzt: $%d"):format(bet))
    sendStateUpdate(tableId, false)
end)

RegisterNetEvent("pe_blackjack:hit")
AddEventHandler("pe_blackjack:hit", function(tableId)
    local src = source
    if not tableId then tableId = playerTables[src] end
    if not tableId then return end
    handleHit(src, tableId)
end)

RegisterNetEvent("pe_blackjack:stand")
AddEventHandler("pe_blackjack:stand", function(tableId)
    local src = source
    if not tableId then tableId = playerTables[src] end
    if not tableId then return end
    handleStand(src, tableId)
end)
------------------------------------------------------------
-- Debug commands (optional)
------------------------------------------------------------
RegisterCommand("bjstart", function(source, args)
    local tableId = tonumber(args[1]) or playerTables[source] or 1
    startRound(tableId, source)
end, false)

RegisterCommand("bjhit", function(source)
    local tableId = playerTables[source] or 1
    handleHit(source, tableId)
end, false)

RegisterCommand("bjstand", function(source)
    local tableId = playerTables[source] or 1
    handleStand(source, tableId)
end, false)
