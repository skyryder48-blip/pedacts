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
-- KEYBIND INTERACTION (alternative to ox_target)
-- ============================================================================

lib.addKeybind({
    name = 'drug_deal_interact',
    description = 'Interact with nearby drug buyer or vehicle',
    defaultKey = 'E',
    onPressed = function()
        if not initialized then return end

        local playerCoords = GetEntityCoords(cache.ped)
        local closestEntity, closestDist, interactionType = nil, 4.0, nil

        -- Check foot buyers (peds)
        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= cache.ped and DoesEntityExist(ped) then
                local dist = #(playerCoords - GetEntityCoords(ped))
                if dist < closestDist and exports.qbx_pedscenarios:IsDrugBuyer(ped) then
                    closestEntity = ped
                    closestDist = dist
                    interactionType = 'foot'
                end
            end
        end

        -- Check vehicle buyers (vehicles)
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            if DoesEntityExist(veh) then
                local dist = #(playerCoords - GetEntityCoords(veh))
                if dist < closestDist and exports.qbx_pedscenarios:IsVehicleBuyer(veh) then
                    closestEntity = veh
                    closestDist = dist
                    interactionType = 'vehicle'
                end
            end
        end

        if closestEntity then
            if interactionType == 'foot' then
                exports.qbx_pedscenarios:InteractDrugBuyer(closestEntity)
            elseif interactionType == 'vehicle' then
                exports.qbx_pedscenarios:InteractVehicleBuyer(closestEntity)
            end
        end
    end,
})

-- ============================================================================
-- OX_TARGET INTEGRATION (optional - add interactions to scenario peds)
-- ============================================================================

-- Drug buyer interaction: foot buyers via addGlobalPed
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

    -- Vehicle buyer interaction: target the vehicle, not the ped
    exports.ox_target:addGlobalVehicle({
        {
            name = 'pedscenarios_vehicle_buyer_interact',
            icon = 'fas fa-car',
            label = 'Deal',
            distance = 4.0,
            canInteract = function(entity)
                return exports.qbx_pedscenarios:IsVehicleBuyer(entity)
            end,
            onSelect = function(data)
                exports.qbx_pedscenarios:InteractVehicleBuyer(data.entity)
            end,
        },
    })
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

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
    initialized = false
end)

-- Character login: reinitialize
RegisterNetEvent('qbx_core:client:onJobUpdate', function()
    -- Could be used to gate certain zones by job
end)
