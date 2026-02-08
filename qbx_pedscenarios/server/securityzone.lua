--- Server-side Security Zone Logic
--- Manages: objective loot validation, access item checks, cooldowns,
--- and alert level sync for anti-cheat.

-- ============================================================================
-- STATE
-- ============================================================================

--- Objective cooldowns: cooldowns[citizenid][objectiveId] = expiry os.time
---@type table<string, table<string, integer>>
local objectiveCooldowns = {}

-- ============================================================================
-- FREE-GANGS INTEGRATION
-- ============================================================================

--- Check if the free-gangs resource is running
---@return boolean
local function isFreeGangsActive()
    if not Config.GangIntegration or not Config.GangIntegration.enabled then return false end
    return GetResourceState('free-gangs') == 'started'
end

--- Award gang reputation for completing a security zone objective
---@param source integer
local function awardSecurityGangRep(source)
    if not isFreeGangsActive() then return end

    local repConfig = Config.GangIntegration.securityLoot
    if not repConfig then return end

    local gangData = exports['free-gangs']:GetPlayerGang(source)
    if not gangData or not gangData.name then return end

    local gangName = gangData.name

    if (repConfig.masterRep or 0) > 0 then
        exports['free-gangs']:AddMasterRep(gangName, repConfig.masterRep, 'SecurityLoot')
    end

    if (repConfig.individualRep or 0) > 0 then
        exports['free-gangs']:AddIndividualRep(source, repConfig.individualRep, 'SecurityLoot')
    end

    lib.print.info(('free-gangs: Awarded %s masterRep=%d indivRep=%d for security loot'):format(
        gangName, repConfig.masterRep or 0, repConfig.individualRep or 0))
end

-- ============================================================================
-- HELPERS
-- ============================================================================

---@param source integer
---@return string?
local function getCitizenId(source)
    local player = exports.qbx_core:GetPlayer(source)
    return player and player.PlayerData.citizenid or nil
end

--- Find an objective definition scoped to a specific zone
---@param zoneId string
---@param objectiveId string
---@return table?
local function findObjectiveDef(zoneId, objectiveId)
    for _, zone in ipairs(Config.SecurityZones) do
        if zone.id == zoneId and zone.objectives then
            for _, obj in ipairs(zone.objectives) do
                if obj.id == objectiveId then
                    return obj
                end
            end
        end
    end
    return nil
end

-- ============================================================================
-- CALLBACKS
-- ============================================================================

--- Check if player has a keycard/access item
lib.callback.register('qbx_pedscenarios:server:checkAccessItem', function(source, itemName)
    local count = exports.ox_inventory:GetItemCount(source, itemName)
    return count and count > 0
end)

--- Consume an access keycard if configured
lib.callback.register('qbx_pedscenarios:server:consumeAccessItem', function(source, itemName)
    local removed = exports.ox_inventory:RemoveItem(source, itemName, 1)
    return removed and true or false
end)

--- Validate and process an objective interaction
--- Checks: zone match, alert level, required item, cooldown, then rolls loot.
lib.callback.register('qbx_pedscenarios:server:attemptObjective', function(source, zoneId, objectiveId, alertLevel)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    local citizenid = player.PlayerData.citizenid
    if not citizenid then return { error = 'no_citizen' } end

    if not zoneId or not objectiveId then return { error = 'invalid_params' } end

    local objDef = findObjectiveDef(zoneId, objectiveId)
    if not objDef then return { error = 'invalid_objective' } end

    -- Server-side alert level validation
    if objDef.maxAlertLevel and alertLevel then
        local objMaxOrder = Config.AlertLevelOrder[objDef.maxAlertLevel] or 0
        local currentOrder = Config.AlertLevelOrder[alertLevel] or 0
        if currentOrder > objMaxOrder then
            return { error = 'alert_too_high' }
        end
    end

    -- Check cooldown
    if objectiveCooldowns[citizenid] and objectiveCooldowns[citizenid][objectiveId] then
        local expiry = objectiveCooldowns[citizenid][objectiveId]
        if os.time() < expiry then
            local remaining = expiry - os.time()
            return {
                error = 'cooldown',
                remainingMs = remaining * 1000,
            }
        end
    end

    -- Check required item
    if objDef.requiredItem then
        local hasItem = exports.ox_inventory:GetItemCount(source, objDef.requiredItem)
        if not hasItem or hasItem < 1 then
            return { error = 'missing_item', requiredItem = objDef.requiredItem }
        end
    end

    -- Consume required item if configured
    if objDef.requiredItem and objDef.consumeRequired then
        local removed = exports.ox_inventory:RemoveItem(source, objDef.requiredItem, 1)
        if not removed then
            return { error = 'consume_failed' }
        end
    end

    -- Roll loot
    local loot = {}
    for _, entry in ipairs(objDef.lootTable) do
        if math.random() <= entry.chance then
            local qty = math.random(entry.min, entry.max)
            if qty > 0 then
                loot[#loot + 1] = { item = entry.item, quantity = qty }
            end
        end
    end

    -- Check if player can carry at least one item
    if #loot > 0 then
        local canCarryAny = false
        for _, entry in ipairs(loot) do
            if exports.ox_inventory:CanCarryItem(source, entry.item, 1) then
                canCarryAny = true
                break
            end
        end
        if not canCarryAny then
            return { error = 'inventory_full' }
        end
    end

    -- Give loot to player, drop overflow on the ground
    local givenItems = {}
    local droppedItems = {}
    for _, lootEntry in ipairs(loot) do
        local success = exports.ox_inventory:AddItem(source, lootEntry.item, lootEntry.quantity)
        if success then
            givenItems[#givenItems + 1] = lootEntry
        else
            -- Try smaller quantities
            local carried = 0
            for qty = lootEntry.quantity - 1, 1, -1 do
                if exports.ox_inventory:AddItem(source, lootEntry.item, qty) then
                    carried = qty
                    givenItems[#givenItems + 1] = { item = lootEntry.item, quantity = qty }
                    break
                end
            end
            local remainder = lootEntry.quantity - carried
            if remainder > 0 then
                droppedItems[#droppedItems + 1] = { item = lootEntry.item, quantity = remainder }
            end
        end
    end

    -- Drop overflow items on the ground near the player
    if #droppedItems > 0 then
        local playerPed = GetPlayerPed(source)
        if playerPed ~= 0 then
            local coords = GetEntityCoords(playerPed)
            local dropItems = {}
            for _, entry in ipairs(droppedItems) do
                dropItems[#dropItems + 1] = { entry.item, entry.quantity }
            end
            local ok, err = pcall(function()
                exports.ox_inventory:CustomDrop('seczone_loot', dropItems, coords)
            end)
            if not ok then
                lib.print.warn(('Could not create ground drop for overflow loot: %s'):format(tostring(err)))
            end
        end
    end

    -- Set cooldown only after successful loot
    if #givenItems > 0 or #loot == 0 then
        if not objectiveCooldowns[citizenid] then objectiveCooldowns[citizenid] = {} end
        objectiveCooldowns[citizenid][objectiveId] = os.time() + math.floor(objDef.cooldownMs / 1000)
    end

    -- Award free-gangs reputation for completing objective
    if #givenItems > 0 then
        awardSecurityGangRep(source)
    end

    lib.print.info(('Player %s (%s) completed objective "%s", received %d items'):format(
        source, citizenid, objectiveId, #givenItems))

    return {
        result = 'success',
        loot = givenItems,
        droppedLoot = droppedItems,
    }
end)

--- Check if an objective is on cooldown for this player
lib.callback.register('qbx_pedscenarios:server:checkObjectiveCooldown', function(source, objectiveId)
    local citizenid = getCitizenId(source)
    if not citizenid then return { available = false } end

    if objectiveCooldowns[citizenid] and objectiveCooldowns[citizenid][objectiveId] then
        local expiry = objectiveCooldowns[citizenid][objectiveId]
        if os.time() < expiry then
            return {
                available = false,
                remainingMs = (expiry - os.time()) * 1000,
            }
        end
    end

    return { available = true }
end)

-- ============================================================================
-- CLEANUP
-- ============================================================================

AddEventHandler('playerDropped', function()
    -- Cooldowns persist (keyed by citizenid, not source)
end)

RegisterNetEvent('qbx_core:server:onLogout', function(source)
    -- Cooldowns persist across sessions (keyed by citizenid)
end)

-- ============================================================================
-- ADMIN EXPORTS
-- ============================================================================

--- Reset all objective cooldowns for a player
---@param citizenid string
exports('ResetObjectiveCooldowns', function(citizenid)
    objectiveCooldowns[citizenid] = nil
end)

--- Get objective cooldown status
---@param citizenid string
---@param objectiveId string
---@return table
exports('GetObjectiveCooldown', function(citizenid, objectiveId)
    if objectiveCooldowns[citizenid] and objectiveCooldowns[citizenid][objectiveId] then
        local expiry = objectiveCooldowns[citizenid][objectiveId]
        if os.time() < expiry then
            return { onCooldown = true, expiresAt = expiry }
        end
    end
    return { onCooldown = false }
end)
