Config = Config or {}

Config.CardModel = "p_cardsspread01x"
Config.CardOffsets = {
    tableForward = 0.55,
    dealerForward = 0.6,
    spacing = 0.15,
    tableHeight = 0.05,
    handSpacing = 0.04
}

Config.BlackjackTables = {
    {
        id  = 1,
        npc = {
            coords      = vector3(-5508.6, -2912.96, 0.7),
            heading     = 110,
            model       = "U_M_M_VALGENSTOREOWNER_01",
            spawnRadius = 80.0,
            blipSprite  = 0x72A7CB0E,
            blipLabel   = "Blackjack"
        },
        seats = {
            { coords = vector3(-5512.2, -2914.1, 1.69), heading = 90.0 },
            { coords = vector3(-5511.44, -2912.11, 1.69), heading = 0.0 },
        }
    }
}
