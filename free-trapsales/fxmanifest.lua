fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'free-trapsales'
description 'Dynamic drug sale zones & phone delivery system for QBX'
version '1.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'shared/config.lua',
}

client_scripts {
    'client/utils.lua',
    'client/drugzone.lua',
    'client/delivery.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/drugzone.lua',
    'server/delivery.lua',
    'server/main.lua',
}

modules {
    'qbx_core:playerdata',
}

dependencies {
    'ox_lib',
    'qbx_core',
    'ox_inventory',
}

-- Optional: If 'free-gangs' is running, drug sales automatically
-- award gang reputation. See Config.GangIntegration.
