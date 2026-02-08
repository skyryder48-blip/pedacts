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
-- HELPERS
-- ============================================================================

---@param source integer
---@return string?
local function getCitizenId(source)
    local player = exports.qbx_core:GetPlayer(source)
    return player and player.PlayerData.citizenid or nil
end

---@param objectiveId string
---@return table?
local function findObjectiveDef(objectiveId)
    for _, zone in ipairs(Config.SecurityZones) do
        if zone.objectives then
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
--- Checks: player has required item, cooldown is clear, rolls loot.
lib.callback.register('qbx_pedscenarios:server:attemptObjective', function(source, objectiveId)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    local citizenid = player.PlayerData.citizenid
    if not citizenid then return { error = 'no_citizen' } end

    local objDef = findObjectiveDef(objectiveId)
    if not objDef then return { error = 'invalid_objective' } end

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

    -- Give loot to player
    local givenItems = {}
    for _, lootEntry in ipairs(loot) do
        local success = exports.ox_inventory:AddItem(source, lootEntry.item, lootEntry.quantity)
        if success then
            givenItems[#givenItems + 1] = lootEntry
        end
    end

    -- Set cooldown
    if not objectiveCooldowns[citizenid] then objectiveCooldowns[citizenid] = {} end
    objectiveCooldowns[citizenid][objectiveId] = os.time() + math.floor(objDef.cooldownMs / 1000)

    lib.print.info(('Player %s (%s) completed objective "%s", received %d items'):format(
        source, citizenid, objectiveId, #givenItems))

    return {
        result = 'success',
        loot = givenItems,
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
