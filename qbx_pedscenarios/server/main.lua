--- Server-side logic for ped scenarios
--- Handles drug sale validation, bodyguard authorization, and admin controls.
--- All economy/inventory interactions are server-authoritative.

local playerBodyguardCounts = {} ---@type table<integer, integer> -- source -> count

-- Drug zone logic is in server/drugzone.lua

-- ============================================================================
-- BODYGUARD CALLBACKS
-- ============================================================================

--- Validate bodyguard spawn request
lib.callback.register('qbx_pedscenarios:server:requestBodyguard', function(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return false end

    local currentCount = playerBodyguardCounts[source] or 0
    local maxAllowed = Config.Bodyguard.maxBodyguards

    if currentCount >= maxAllowed then
        return false
    end

    -- Optional: charge money for bodyguard
    local cost = 500
    local playerCash = player.PlayerData.money.cash

    if playerCash < cost then
        exports.qbx_core:Notify(source, 'Not enough cash. Bodyguards cost $' .. cost, 'error')
        return false
    end

    player.Functions.RemoveMoney('cash', cost, 'Bodyguard hire')
    playerBodyguardCounts[source] = currentCount + 1

    lib.print.info(('Player %s hired bodyguard (%d/%d)'):format(source, currentCount + 1, maxAllowed))

    return true
end)

--- Handle bodyguard dismissal
lib.callback.register('qbx_pedscenarios:server:dismissBodyguard', function(source)
    playerBodyguardCounts[source] = 0
    return true
end)

-- ============================================================================
-- PLAYER LIFECYCLE
-- ============================================================================

--- Cleanup when player drops
AddEventHandler('playerDropped', function()
    local source = source
    playerBodyguardCounts[source] = nil
end)

--- Cleanup on character logout
RegisterNetEvent('qbx_core:server:onLogout', function(source)
    playerBodyguardCounts[source] = nil
end)

-- ============================================================================
-- ADMIN COMMANDS
-- ============================================================================

lib.addCommand('pedscenarios', {
    help = 'Manage ped scenarios (admin)',
    restricted = 'group.admin',
    params = {
        {
            name = 'action',
            type = 'string',
            help = 'Action: reload | status | resetplayer | heat | rep',
        },
        {
            name = 'target',
            type = 'string',
            help = 'Target player ID or zone ID',
            optional = true,
        },
        {
            name = 'value',
            type = 'number',
            help = 'Value to set (for heat/rep)',
            optional = true,
        },
    },
}, function(source, args)
    local action = args.action

    if action == 'status' then
        local totalBg = 0
        for _, count in pairs(playerBodyguardCounts) do
            totalBg = totalBg + count
        end

        -- Drug zone heat summary
        local heatInfo = ''
        for _, zone in ipairs(Config.DrugZones) do
            local status = exports.qbx_pedscenarios:GetDrugZoneStatus(zone.id)
            heatInfo = heatInfo .. ('\n  %s: Heat %.1f | Mult %.1f | %s'):format(
                zone.id, status.heat, status.spawnMultiplier,
                status.isLockdown and '🔒 LOCKDOWN' or '✅ Active'
            )
        end

        exports.qbx_core:Notify(source,
            ('Bodyguard contracts: %d\nDrug Zones:%s'):format(totalBg, heatInfo), 'inform')

    elseif action == 'heat' then
        local zoneId = args.target
        local value = args.value or 0
        if zoneId then
            exports.qbx_pedscenarios:SetDrugZoneHeat(zoneId, value)
            exports.qbx_core:Notify(source, ('Set heat for "%s" to %.1f'):format(zoneId, value), 'success')
        else
            exports.qbx_core:Notify(source, 'Usage: /pedscenarios heat [zoneId] [value]', 'inform')
        end

    elseif action == 'rep' then
        local targetId = tonumber(args.target)
        local value = args.value or 0
        if targetId then
            for _, zone in ipairs(Config.DrugZones) do
                exports.qbx_pedscenarios:SetPlayerDrugRep(targetId, zone.id, value)
            end
            exports.qbx_core:Notify(source, ('Set rep for player %d to %.0f in all zones'):format(targetId, value), 'success')
        else
            exports.qbx_core:Notify(source, 'Usage: /pedscenarios rep [playerId] [value]', 'inform')
        end

    elseif action == 'resetplayer' then
        local target = tonumber(args.target)
        if target then
            playerBodyguardCounts[target] = 0
            exports.qbx_core:Notify(source, ('Reset bodyguard count for player %d'):format(target), 'success')
            TriggerClientEvent('qbx_pedscenarios:client:forceCleanup', target)
        end

    elseif action == 'reload' then
        exports.qbx_core:Notify(source, 'Triggering client reload for all players', 'inform')
        TriggerClientEvent('qbx_pedscenarios:client:forceReload', -1)

    else
        exports.qbx_core:Notify(source, 'Usage: /pedscenarios [status|heat|rep|resetplayer|reload]', 'inform')
    end
end)

-- ============================================================================
-- LOGGING
-- ============================================================================

lib.print.info('qbx_pedscenarios server loaded.')
