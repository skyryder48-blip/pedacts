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
    description = 'Interact with nearby drug buyer',
    defaultKey = 'E',
    onPressed = function()
        if not initialized then return end

        local playerCoords = GetEntityCoords(cache.ped)
        local closestPed, closestDist = nil, 3.0

        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= cache.ped and DoesEntityExist(ped) then
                local dist = #(playerCoords - GetEntityCoords(ped))
                if dist < closestDist then
                    if exports.qbx_pedscenarios:IsDrugBuyer(ped) then
                        closestPed = ped
                        closestDist = dist
                    elseif exports.qbx_pedscenarios:IsVehicleBuyer(ped) then
                        closestPed = ped
                        closestDist = dist
                    end
                end
            end
        end

        if closestPed then
            if exports.qbx_pedscenarios:IsDrugBuyer(closestPed) then
                exports.qbx_pedscenarios:InteractDrugBuyer(closestPed)
            elseif exports.qbx_pedscenarios:IsVehicleBuyer(closestPed) then
                exports.qbx_pedscenarios:InteractVehicleBuyer(closestPed)
            end
        end
    end,
})

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
        {
            name = 'pedscenarios_vehicle_buyer_interact',
            icon = 'fas fa-car',
            label = 'Deal',
            distance = 3.0,
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
