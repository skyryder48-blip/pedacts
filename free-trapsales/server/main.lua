--- Server-side logic for free-trapsales
--- Handles admin controls and server-wide coordination.
--- All economy/inventory interactions are server-authoritative.

-- Drug zone logic is in server/drugzone.lua

-- ============================================================================
-- ADMIN COMMANDS
-- ============================================================================

lib.addCommand('trapsales', {
    help = 'Manage trap sales (admin)',
    restricted = 'group.admin',
    params = {
        {
            name = 'action',
            type = 'string',
            help = 'Action: reload | status | heat | rep',
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
        -- Drug zone heat summary
        local heatInfo = ''
        for _, zone in ipairs(Config.DrugZones) do
            local status = exports['free-trapsales']:GetDrugZoneStatus(zone.id)
            heatInfo = heatInfo .. ('\n  %s: Heat %.1f | Mult %.1f | %s'):format(
                zone.id, status.heat, status.spawnMultiplier,
                status.isLockdown and 'LOCKDOWN' or 'Active'
            )
        end

        exports.qbx_core:Notify(source,
            ('Drug Zones:%s'):format(heatInfo), 'inform')

    elseif action == 'heat' then
        local zoneId = args.target
        local value = args.value or 0
        if zoneId then
            exports['free-trapsales']:SetDrugZoneHeat(zoneId, value)
            exports.qbx_core:Notify(source, ('Set heat for "%s" to %.1f'):format(zoneId, value), 'success')
        else
            exports.qbx_core:Notify(source, 'Usage: /trapsales heat [zoneId] [value]', 'inform')
        end

    elseif action == 'rep' then
        local targetId = tonumber(args.target)
        local value = args.value or 0
        if targetId then
            for _, zone in ipairs(Config.DrugZones) do
                exports['free-trapsales']:SetPlayerDrugRep(targetId, zone.id, value)
            end
            exports.qbx_core:Notify(source, ('Set rep for player %d to %.0f in all zones'):format(targetId, value), 'success')
        else
            exports.qbx_core:Notify(source, 'Usage: /trapsales rep [playerId] [value]', 'inform')
        end

    elseif action == 'reload' then
        exports.qbx_core:Notify(source, 'Triggering client reload for all players', 'inform')
        TriggerClientEvent('free-trapsales:client:forceReload', -1)

    else
        exports.qbx_core:Notify(source, 'Usage: /trapsales [status|heat|rep|reload]', 'inform')
    end
end)

-- ============================================================================
-- LOGGING
-- ============================================================================

lib.print.info('free-trapsales server loaded.')
