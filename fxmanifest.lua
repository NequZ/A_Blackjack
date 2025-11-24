fx_version 'cerulean'
game 'rdr3' -- oder 'gta5' je nachdem
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

name 'pe_blackjack'
description 'Blackjack - Pioneers Echoes'
author 'Niclas'

server_scripts {
    'server.lua',
    'config.lua'
}

client_scripts {
    'client.lua',
    'config.lua'
}

ui_page 'html/ui.html'

files {
    'html/ui.html',
    'html/ui.js',
    'html/ui.css'
}
