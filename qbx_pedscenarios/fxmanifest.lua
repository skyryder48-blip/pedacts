fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbx_pedscenarios'
description 'Dynamic ped scenario zones for QBX - Drug zones, Security zones'
version '1.0.0'
repository 'https://github.com/yourrepo/qbx_pedscenarios'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'shared/config.lua',
}

client_scripts {
    'client/utils.lua',
    'client/drugzone.lua',
    'client/securityzone.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/drugzone.lua',
    'server/securityzone.lua',
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

-- Optional: If 'free-gangs' is running, drug sales and security loot
-- automatically award gang reputation. See Config.GangIntegration.
