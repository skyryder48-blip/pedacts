--- Main Client Entry Point for free-trapsales
--- Initializes drug sale zones and registers commands/interactions.
--- Waits for player to be fully loaded before starting.

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local initialized = false

--- Register relationship groups used by drug buyer peds
AddRelationshipGroup('DRUGBUYER_GROUP')

--- Wait for player to be fully loaded and ready
local function waitForReady()
    while not QBX or not QBX.PlayerData or not QBX.PlayerData.citizenid do
        Wait(500)
    end
end

--- Initialize drug zones (pcall-protected for safety)
local function initAllScenarios()
    if initialized then return end

    local ok, err = pcall(InitDrugZones)
    if not ok then
        lib.print.error(('InitDrugZones failed: %s'):format(tostring(err)))
    end

    initialized = true
    lib.print.info('free-trapsales: Drug zones initialized.')
end

--- Clean up all drug zones and reset state
local function cleanupAllScenarios()
    initialized = false

    local ok, err = pcall(CleanupDrugZones)
    if not ok then
        lib.print.error(('CleanupDrugZones failed: %s'):format(tostring(err)))
    end
end

CreateThread(function()
    lib.print.info('[free-trapsales] Waiting for player to be ready...')
    waitForReady()
    lib.print.info('[free-trapsales] Player ready, waiting 2s for world streaming...')
    Wait(2000) -- Extra buffer for world to load
    initAllScenarios()
end)

-- ============================================================================
-- COMMANDS (using ox_lib command registration)
-- ============================================================================

-- Debug command
RegisterCommand('trapsales_debug', function()
    Config.Debug = not Config.Debug
    lib.notify({
        title = 'Trap Sales',
        description = 'Debug mode: ' .. (Config.Debug and 'ON' or 'OFF'),
        type = 'inform',
    })
    -- Restart zones with new debug state
    cleanupAllScenarios()
    Wait(500)
    initAllScenarios()
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
                if dist < closestDist and exports['free-trapsales']:IsDrugBuyer(ped) then
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
                if dist < closestDist and exports['free-trapsales']:IsVehicleBuyer(veh) then
                    closestEntity = veh
                    closestDist = dist
                    interactionType = 'vehicle'
                end
            end
        end

        if closestEntity then
            if interactionType == 'foot' then
                exports['free-trapsales']:InteractDrugBuyer(closestEntity)
            elseif interactionType == 'vehicle' then
                exports['free-trapsales']:InteractVehicleBuyer(closestEntity)
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
            name = 'trapsales_drug_interact',
            icon = 'fas fa-pills',
            label = 'Deal',
            distance = 2.5,
            canInteract = function(entity)
                return exports['free-trapsales']:IsDrugBuyer(entity)
            end,
            onSelect = function(data)
                exports['free-trapsales']:InteractDrugBuyer(data.entity)
            end,
        },
    })

    -- Vehicle buyer interaction: target the vehicle, not the ped
    exports.ox_target:addGlobalVehicle({
        {
            name = 'trapsales_vehicle_buyer_interact',
            icon = 'fas fa-car',
            label = 'Deal',
            distance = 4.0,
            canInteract = function(entity)
                return exports['free-trapsales']:IsVehicleBuyer(entity)
            end,
            onSelect = function(data)
                exports['free-trapsales']:InteractVehicleBuyer(data.entity)
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
        cleanupAllScenarios()
    end
end)

-- Character logout: full cleanup
RegisterNetEvent('qbx_core:client:onLogout', function()
    cleanupAllScenarios()
end)

-- Character login: reinitialize zones after logout or character switch
RegisterNetEvent('qbx_core:client:onPlayerLoaded', function()
    if initialized then return end
    Wait(2000) -- Buffer for world streaming after character load
    initAllScenarios()
end)

-- Job update hook (could be used to gate certain zones by job)
RegisterNetEvent('qbx_core:client:onJobUpdate', function()
end)
