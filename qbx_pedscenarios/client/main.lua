--- Main Client Entry Point
--- Initializes all scenarios and registers commands/interactions.
--- Waits for player to be fully loaded before starting.

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local initialized = false

--- Wait for player to be fully loaded and ready
local function waitForReady()
    while not QBX or not QBX.PlayerData or not QBX.PlayerData.citizenid do
        Wait(500)
    end
end

CreateThread(function()
    waitForReady()
    Wait(2000) -- Extra buffer for world to load

    InitDrugZones()
    InitSecurityZones()

    initialized = true
    lib.print.info('qbx_pedscenarios: All scenarios initialized.')
end)

-- ============================================================================
-- COMMANDS (using ox_lib command registration)
-- ============================================================================

-- Bodyguard commands
lib.addKeybind({
    name = 'spawn_bodyguard',
    description = 'Spawn a bodyguard',
    defaultKey = '',  -- No default key, player must bind
    onPressed = function()
        if not initialized then return end
        SpawnBodyguard()
    end,
})

RegisterCommand('bodyguard', function(_, args)
    if not initialized then return end

    local action = args[1]

    if action == 'spawn' or action == 'hire' then
        SpawnBodyguard()
    elseif action == 'dismiss' or action == 'fire' then
        DismissAllBodyguards()
    elseif action == 'count' then
        local count = GetBodyguardCount()
        lib.notify({
            title = 'Bodyguard',
            description = ('Active bodyguards: %d / %d'):format(count, Config.Bodyguard.maxBodyguards),
            type = 'inform',
        })
    else
        lib.notify({
            title = 'Bodyguard',
            description = 'Usage: /bodyguard [spawn|dismiss|count]',
            type = 'inform',
        })
    end
end, false)

-- Debug command
RegisterCommand('pedscenarios_debug', function()
    Config.Debug = not Config.Debug
    lib.notify({
        title = 'Ped Scenarios',
        description = 'Debug mode: ' .. (Config.Debug and 'ON' or 'OFF'),
        type = 'inform',
    })
    -- Restart zones with new debug state
    CleanupDrugZones()
    CleanupSecurityZones()
    Wait(500)
    InitDrugZones()
    InitSecurityZones()
end, false)

-- ============================================================================
-- OX_TARGET INTEGRATION (optional - add interactions to scenario peds)
-- ============================================================================

-- Drug buyer interaction target
-- This adds a targetable option to peds near drug zones
if GetResourceState('ox_target') == 'started' then
    exports.ox_target:addGlobalPed({
        {
            name = 'pedscenarios_drug_interact',
            icon = 'fas fa-pills',
            label = 'Deal',
            distance = 2.5,
            canInteract = function(entity)
                return exports.qbx_pedscenarios:IsDrugBuyer(entity)
            end,
            onSelect = function(data)
                exports.qbx_pedscenarios:InteractDrugBuyer(data.entity)
            end,
        },
    })
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

-- Player death: dismiss bodyguards temporarily
AddEventHandler('gameEventTriggered', function(event, data)
    if event == 'CEventNetworkEntityDamage' then
        local victim = data[1]
        local isDead = data[4] == 1

        if victim == cache.ped and isDead then
            -- Don't remove, just stop follow loops; they'll resume when player respawns
            for _, bgData in pairs(bodyguards or {}) do
                bgData.followThread = false
            end
        end
    end
end)

-- Player respawn: restart bodyguard follow behavior
RegisterNetEvent('qbx_pedscenarios:client:onPlayerRespawn', function()
    for ped, data in pairs(bodyguards or {}) do
        if DoesEntityExist(ped) then
            startFollowBehavior(ped)
        else
            bodyguards[ped] = nil
        end
    end
end)

-- Full cleanup on resource stop (also handled in utils.lua for peds)
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        CleanupDrugZones()
        CleanupSecurityZones()
    end
end)

-- Character logout: full cleanup
RegisterNetEvent('qbx_core:client:onLogout', function()
    CleanupDrugZones()
    CleanupSecurityZones()
    CleanupBodyguards()
    initialized = false
end)

-- Character login: reinitialize
RegisterNetEvent('qbx_core:client:onJobUpdate', function()
    -- Could be used to gate certain zones by job
end)
