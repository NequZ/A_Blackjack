-- pe_blackjack/server.lua

local tableState = {
    inRound    = false,
    players    = {}, -- [src] = { desiredBet=number, hand = {}, stand=false, bust=false, bet=0 }
    dealerHand = {},
    deck       = {}
}

local WAIT_TIME_MS     = 20000
local waitingTimer     = false
local dealerSpawned    = {}
local DISCORD_WEBHOOK = "https://discordapp.com/api/webhooks/1442193509263081472/uzBTV6KD4j3nbFU9466erUFKTXgkJdei7-5GMaMqqYemaKVv3ScM3eBtN03x4vAJnKds"

local function sendDiscordEmbed(message, opts)
    if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == "" then
        return
    end

    opts = opts or {}
    local src   = opts.src or 0
    local title = opts.title or "Blackjack"
    local color = opts.color or 3447003 -- Farbe nach Geschmack

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

    PerformHttpRequest(
        DISCORD_WEBHOOK,
        function(err, text, headers) end,
        "POST",
        json.encode({ embeds = { embed } }),
        { ["Content-Type"] = "application/json" }
    )
end


-- >>> VORP CORE & Einsatz-Konfig
local VorpCore = nil
TriggerEvent("getCore", function(core)
    VorpCore = core
end)

local BASE_BET = 5 -- Einsatz pro Runde in Dollar (bar), nach Geschmack anpassen
-- VORP Character holen (kompatibel für beide Varianten)
local function getCharacter(src)
    if not VorpCore or not VorpCore.getUser then return nil end

    local user = VorpCore.getUser(src)
    if not user then return nil end

    -- Falls dein VORP eine Funktion liefert:
    if type(user.getUsedCharacter) == "function" then
        return user.getUsedCharacter()   -- hier DARF man Klammern benutzen
    end

    -- Falls es – wie deine Fehlermeldung sagt – schon ein Table ist:
    return user.getUsedCharacter
end



local function canPayBet(src, amount)
    local char = getCharacter(src)
    if not char then return true end -- failsafe: wenn VORP fehlt, nicht blocken
    return (char.money or 0) >= amount
end

local function removeMoney(src, amount)
    local char = getCharacter(src)
    if not char then return end
    char.removeCurrency(0, amount)      -- 0 = Cash
end

local function addMoney(src, amount)
    local char = getCharacter(src)
    if not char then return end
    char.addCurrency(0, amount)         -- 0 = Cash
end


--------------------------------------------------
-- Deck / Karten
--------------------------------------------------

local cards = {
    "2","3","4","5","6","7","8","9","10","J","Q","K","A"
}
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

local function drawCard()
    local deck = tableState.deck
    if #deck == 0 then
        tableState.deck = buildDeck()
        shuffleDeck(tableState.deck)
        deck = tableState.deck
    end
    local card = deck[#deck]
    deck[#deck] = nil
    return card
end

--------------------------------------------------
-- Helpers
--------------------------------------------------

local function broadcast(msg)

    print(("[Blackjack] %s"):format(msg))
end



local function sendToPlayer(src, msg)
    if src == 0 then return end -- 0 = Konsole, ignorieren

    -- Ingame nur an den Spieler selbst
    TriggerClientEvent("chat:addMessage", src, {
        args = { "^3Blackjack", msg }
    })
end




local function anyActivePlayers()
    for _src, _data in pairs(tableState.players) do
        return true
    end
    return false
end

local function allPlayersDone()
    for _src, p in pairs(tableState.players) do
        if not p.bust and not p.stand then
            return false
        end
    end
    return true
end

local function formatHand(hand, hideSecondCard)
    local parts = {}
    for i, c in ipairs(hand) do
        if hideSecondCard and i == 2 then
            parts[#parts+1] = "??"
        else
            parts[#parts+1] = c
        end
    end
    return table.concat(parts, " ")
end

local function sendUIUpdate(revealDealer, showBet)
    for src, p in pairs(tableState.players) do
        local playerValue = tableState.inRound and handValue(p.hand) or nil
        local dealerValue = (revealDealer and tableState.inRound) and handValue(tableState.dealerHand) or nil

        TriggerClientEvent("pe_blackjack:updateUI", src, {
            action       = "update",
            inRound      = tableState.inRound,
            showUI       = showBet or tableState.inRound,
            playerHand   = tableState.inRound and p.hand or {},
            playerValue  = playerValue,
            dealerHand   = tableState.inRound and tableState.dealerHand or {},
            dealerValue  = dealerValue,
            revealDealer = revealDealer,
            playerBet    = p.bet or p.desiredBet or BASE_BET
        })
    end
end



--------------------------------------------------
-- Dealer Logik
--------------------------------------------------

local function dealerPlay()
    local dealerHand  = tableState.dealerHand
    local dealerValue = handValue(dealerHand)

    broadcast(("Dealer: %s (Wert: %d)"):format(formatHand(dealerHand, false), dealerValue))

    while dealerValue < 17 do
        local card = drawCard()
        dealerHand[#dealerHand+1] = card
        dealerValue = handValue(dealerHand)
        broadcast(("Dealer zieht: %s → Hand: %s (Wert: %d)"):format(
            card,
            formatHand(dealerHand, false),
            dealerValue
        ))
    end

    return dealerValue
end

--------------------------------------------------
-- Runde beenden / auswerten
--------------------------------------------------

local function finishRound()
    if not anyActivePlayers() then
        broadcast("Keine Spieler am Tisch. Runde abgebrochen.")
        tableState.inRound    = false
        tableState.players    = {}
        tableState.dealerHand = {}
        return
    end

    local dealerValue = dealerPlay()

 for src, p in pairs(tableState.players) do
    local hv     = handValue(p.hand)
    local bet    = p.bet or BASE_BET
    local result
    local payout = 0
    local outcome -- "WIN" / "LOSS" / "PUSH"

    if p.bust then
        result  = ("Verloren! Du bist mit %d überkauft."):format(hv)
        payout  = 0
        outcome = "LOSS"
    elseif dealerValue > 21 then
        result  = ("Gewonnen! Dealer hat sich mit %d überkauft, du hast %d."):format(dealerValue, hv)
        payout  = bet * 2
        outcome = "WIN"
    elseif hv > dealerValue then
        result  = ("Gewonnen! Deine %d schlagen Dealer mit %d."):format(hv, dealerValue)
        payout  = bet * 2
        outcome = "WIN"
    elseif hv < dealerValue then
        result  = ("Verloren! Dealer %d schlägt deine %d."):format(dealerValue, hv)
        payout  = 0
        outcome = "LOSS"
    else
        result  = ("Push! Beide %d, unentschieden."):format(hv)
        payout  = bet -- Einsatz zurück
        outcome = "PUSH"
    end

    if payout > 0 then
        addMoney(src, payout)
    end

    if bet > 0 then
        result = result .. (" (Einsatz $%d, Auszahlung $%d)"):format(bet, payout)
    end

    -- Ingame-Message
    sendToPlayer(src, result)

    -- Nur WIN/LOSS ins Discord loggen, KEIN Push
    if outcome == "WIN" or outcome == "LOSS" then
        local color = outcome == "WIN" and 3066993 or 15158332 -- grün / rot

        local desc = string.format(
            "**Ergebnis:** %s\n**Hand:** %s (Wert: %d)\n**Dealer:** %s (Wert: %d)\n**Einsatz:** $%d\n**Auszahlung:** $%d",
            (outcome == "WIN") and "Gewonnen" or "Verloren",
            formatHand(p.hand, false),
            hv,
            formatHand(tableState.dealerHand, false),
            dealerValue,
            bet,
            payout
        )

        sendDiscordEmbed(desc, {
            src   = src,
            title = "Blackjack - " .. outcome,
            color = color
        })
    end
end


    sendUIUpdate(true)

    SetTimeout(8000, function()
        tableState.inRound    = false
        tableState.dealerHand = {}
        for _src, pdata in pairs(tableState.players) do
            pdata.hand  = {}
            pdata.bet   = nil
            pdata.stand = false
            pdata.bust  = false
        end

        if anyActivePlayers() then
            sendUIUpdate(false, true)
            startWaitingTimer()
        end
    end)
end


--------------------------------------------------
-- Runde starten
--------------------------------------------------

local function startRound(srcStarter)
    if tableState.inRound then
        sendToPlayer(srcStarter, "Es läuft bereits eine Runde.")
        return
    end

    if not anyActivePlayers() then
        sendToPlayer(srcStarter, "Keine Spieler am Tisch.")
        return
    end

    tableState.inRound    = true
    tableState.deck       = buildDeck()
    shuffleDeck(tableState.deck)
    tableState.dealerHand = {}

    local activeCount = 0

    -- Einsatz prüfen und abbuchen
    for src, pData in pairs(tableState.players) do
        local desired = pData.desiredBet or BASE_BET
        local bet     = math.floor(desired)

        if bet < 1 then bet = 1 end
        if bet > 1000 then bet = 1000 end

        if canPayBet(src, bet) then
            removeMoney(src, bet)

            pData.hand  = {}
            pData.stand = false
            pData.bust  = false
            pData.bet   = bet

            pData.hand[#pData.hand+1] = drawCard()
            pData.hand[#pData.hand+1] = drawCard()

            local hv = handValue(pData.hand)
            sendToPlayer(src, ("Einsatz: $%d | Deine Hand: %s (Wert: %d)"):format(
                bet,
                formatHand(pData.hand, false),
                hv
            ))

            activeCount = activeCount + 1
        else
            sendToPlayer(src, ("Du hast nicht genug Geld ($%d), um mitzuspielen."):format(bet))
            tableState.players[src] = nil
        end
    end


    if activeCount == 0 then
        broadcast("Niemand hat genug Geld, Runde wird abgebrochen.")
        tableState.inRound    = false
        tableState.dealerHand = {}
        return
    end

    -- Dealer
    tableState.dealerHand[#tableState.dealerHand+1] = drawCard()
    tableState.dealerHand[#tableState.dealerHand+1] = drawCard()

    broadcast(("Dealer zeigt: %s"):format(formatHand(tableState.dealerHand, true)))
    broadcast("Runde gestartet. G = Karte, H = halten, SPACE = aufstehen.")

    -- Blackjack-Check
    for src, p in pairs(tableState.players) do
        local hv = handValue(p.hand)
        if hv == 21 then
            sendToPlayer(src, "Blackjack!")
            p.stand = true
        end
    end

    sendUIUpdate(false)

    if allPlayersDone() then
        finishRound()
    end
end


--------------------------------------------------
-- Wartetimer
--------------------------------------------------

--------------------------------------------------
-- Wartetimer
--------------------------------------------------

--------------------------------------------------
-- Wartetimer (global, damit finishRound ihn findet)
--------------------------------------------------

function startWaitingTimer()
    if waitingTimer or tableState.inRound then
        return
    end

    waitingTimer = true
    broadcast(("Blackjack: Runde startet in %d Sekunden. Setzt euch an den Tisch."):format(WAIT_TIME_MS / 1000))
    sendUIUpdate(false, true)

    SetTimeout(WAIT_TIME_MS, function()
        waitingTimer = false

        if not anyActivePlayers() or tableState.inRound then
            return
        end

        -- 0 = "System"-Starter
        startRound(0)
    end)
end


--------------------------------------------------
-- Events / Commands
--------------------------------------------------

RegisterCommand("bjjoin", function(source)
    if tableState.inRound then
        sendToPlayer(source, "Runde läuft bereits, warte bis zur nächsten.")
        return
    end

    if tableState.players[source] then
        sendToPlayer(source, "Du bist bereits am Tisch.")
        return
    end

    tableState.players[source] = { hand = {}, stand = false, bust = false }
    broadcast(("[%d] ist dem Blackjack-Tisch beigetreten."):format(source))
end, false)

RegisterCommand("bjleave", function(source)
    if not tableState.players[source] then
        sendToPlayer(source, "Du bist nicht am Tisch.")
        return
    end

    tableState.players[source] = nil
    broadcast(("[%d] hat den Blackjack-Tisch verlassen."):format(source))

    if tableState.inRound and not anyActivePlayers() then
        broadcast("Alle Spieler weg, Runde abgebrochen.")
        tableState.inRound    = false
        tableState.players    = {}
        tableState.dealerHand = {}
    end
end, false)

RegisterCommand("bjstart", function(source)
    startRound(source)
end, false)

--------------------------------------------------
-- Hit / Stand Logik zentral
--------------------------------------------------

local function handleHit(src)
    if not tableState.inRound then
        sendToPlayer(src, "Es läuft keine Runde.")
        return
    end

    local p = tableState.players[src]
    if not p then
        sendToPlayer(src, "Du bist nicht am Tisch.")
        return
    end

    if p.stand then
        sendToPlayer(src, "Du hast bereits gehalten.")
        return
    end
    if p.bust then
        sendToPlayer(src, "Du bist schon überkauft.")
        return
    end

    local card = drawCard()
    p.hand[#p.hand+1] = card
    local hv = handValue(p.hand)

    sendToPlayer(src, ("Du ziehst: %s → Hand: %s (Wert: %d)"):format(
        card,
        formatHand(p.hand, false),
        hv
    ))

    if hv > 21 then
        p.bust = true
        sendToPlayer(src, "Überkauft! (>21)")
    end

    if allPlayersDone() then
        finishRound()
    else
        sendUIUpdate(false)
    end
end

local function handleStand(src)
    if not tableState.inRound then
        sendToPlayer(src, "Es läuft keine Runde.")
        return
    end

    local p = tableState.players[src]
    if not p then
        sendToPlayer(src, "Du bist nicht am Tisch.")
        return
    end

    if p.stand then
        sendToPlayer(src, "Du hast bereits gehalten.")
        return
    end

    p.stand = true
    sendToPlayer(src, "Du hältst.")

    if allPlayersDone() then
        finishRound()
    else
        sendUIUpdate(false)
    end
end

-- Commands bleiben zum Debug da
RegisterCommand("bjhit", function(source)
    handleHit(source)
end, false)

RegisterCommand("bjstand", function(source)
    handleStand(source)
end, false)

-- Events für Client-Tasten
RegisterNetEvent("pe_blackjack:hit")
AddEventHandler("pe_blackjack:hit", function()
    local src = source
    handleHit(src)
end)

RegisterNetEvent("pe_blackjack:stand")
AddEventHandler("pe_blackjack:stand", function()
    local src = source
    handleStand(src)
end)

--------------------------------------------------
-- Sitzsystem: Spieler setzt sich an Tisch
--------------------------------------------------

RegisterNetEvent("pe_blackjack:seatJoin")
AddEventHandler("pe_blackjack:seatJoin", function(tableId)
    local src = source

    if tableState.inRound then
        sendToPlayer(src, "Runde läuft bereits, warte bis zur nächsten.")
        return
    end

    if tableState.players[src] then
        sendToPlayer(src, "Du bist bereits am Tisch.")
        return
    end

    tableState.players[src] = {
        hand       = {},
        stand      = false,
        bust       = false,
        desiredBet = BASE_BET
    }
    broadcast(("[%d] hat sich an den Blackjack-Tisch gesetzt."):format(src))

    if not dealerSpawned[tableId] then
        dealerSpawned[tableId] = true
        TriggerClientEvent("pe_blackjack:spawnDealer", -1, tableId)
    end

    sendUIUpdate(false, true)
    startWaitingTimer()
end)
RegisterNetEvent("pe_blackjack:seatLeave")
AddEventHandler("pe_blackjack:seatLeave", function(tableId)
    local src = source

    if not tableState.players[src] then
        sendToPlayer(src, "Du bist nicht am Tisch.")
        return
    end

    -- Wenn er mitten in der Runde aufsteht → UI schließen und Spieler aus Runde entfernen
    if tableState.inRound then
        TriggerClientEvent("pe_blackjack:updateUI", src, { action = "close" })
    end

    tableState.players[src] = nil
    broadcast(("[%d] hat den Blackjack-Tisch verlassen."):format(src))

    -- Wenn keiner mehr spielt → Runde abbrechen
    if tableState.inRound and not anyActivePlayers() then
        broadcast("Alle Spieler weg, Runde abgebrochen.")
        tableState.inRound    = false
        tableState.players    = {}
        tableState.dealerHand = {}
    elseif not tableState.inRound and anyActivePlayers() then
        sendUIUpdate(false, true)
    end
end)


AddEventHandler("playerDropped", function()
    local src = source
    if tableState.players[src] then
        tableState.players[src] = nil
        if tableState.inRound and not anyActivePlayers() then
            broadcast("Alle Spieler weg, Runde abgebrochen.")
            tableState.inRound    = false
            tableState.players    = {}
            tableState.dealerHand = {}
        elseif not tableState.inRound and anyActivePlayers() then
            sendUIUpdate(false, true)
        end
    end
end)
RegisterNetEvent("pe_blackjack:setBet")
AddEventHandler("pe_blackjack:setBet", function(bet)
    local src = source
    local p = tableState.players[src]

    if not p then
        sendToPlayer(src, "Du sitzt nicht am Tisch.")
        return
    end

    if tableState.inRound then
        sendToPlayer(src, "Einsatz nur zwischen den Runden.")
        return
    end

    bet = math.floor(bet)
    if bet < 1 then bet = 1 end
    if bet > 1000 then bet = 1000 end

    p.desiredBet = bet
    sendToPlayer(src, ("Einsatz gesetzt: $%d"):format(bet))
    sendUIUpdate(false, true)
end)

