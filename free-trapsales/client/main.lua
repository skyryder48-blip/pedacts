--- Main Client Entry Point for free-trapsales
--- Initializes drug sale zones and registers commands/interactions.
--- Uses QBX statebags and events for player readiness detection.

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local initialized = false

--- Register relationship groups used by drug buyer peds
AddRelationshipGroup('DRUGBUYER_GROUP')

--- Initialize drug zones (pcall-protected for safety)
local function initAllScenarios()
    if initialized then return end

    lib.print.info('[free-trapsales] initAllScenarios: starting initialization...')

    local ok, err = pcall(InitDrugZones)
    if not ok then
        lib.print.error(('[free-trapsales] InitDrugZones failed: %s'):format(tostring(err)))
    end

    initialized = true
    lib.print.info('[free-trapsales] Drug zones initialized.')
end

--- Clean up all drug zones and reset state
local function cleanupAllScenarios()
    initialized = false

    local ok, err = pcall(CleanupDrugZones)
    if not ok then
        lib.print.error(('[free-trapsales] CleanupDrugZones failed: %s'):format(tostring(err)))
    end
end

-- If the player is already logged in when the resource starts (e.g. resource
-- restart while in-game), initialize immediately. LocalPlayer.state.isLoggedIn
-- is a QBX statebag that persists across resource restarts.
CreateThread(function()
    lib.print.info('[free-trapsales] Checking if player is already logged in...')

    if LocalPlayer.state.isLoggedIn then
        lib.print.info('[free-trapsales] Player already logged in, initializing after 2s buffer...')
        Wait(2000)
        initAllScenarios()
    else
        lib.print.info('[free-trapsales] Player not logged in yet, waiting for onPlayerLoaded event...')
    end
end)

-- ============================================================================
-- COMMANDS
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
    lib.print.info('[free-trapsales] Player logged out, cleaning up...')
    cleanupAllScenarios()
end)

-- Character login: initialize zones (first login or after character switch)
RegisterNetEvent('qbx_core:client:onPlayerLoaded', function()
    lib.print.info('[free-trapsales] onPlayerLoaded event received')
    if initialized then
        lib.print.info('[free-trapsales] Already initialized, skipping')
        return
    end
    Wait(2000) -- Buffer for world streaming after character load
    initAllScenarios()
end)
