--- Server-side Security Zone Logic
--- Manages: multi-step objective validation, equipment tier resolution,
--- objective state persistence, guard discovery callbacks, access item checks,
--- cooldowns, loot validation, and alert level sync for anti-cheat.

-- ============================================================================
-- STATE
-- ============================================================================

--- Objective cooldowns: cooldowns[citizenid][objectiveId] = expiry os.time
---@type table<string, table<string, integer>>
local objectiveCooldowns = {}

--- Objective step states: objectiveStates[zoneId][objectiveId][stepId] = { opened = bool, openedAt = integer }
--- Tracks which steps have been "opened" (completed). Once opened, a step
--- stays open until a guard discovers it or the server restarts.
--- Opened steps can be re-looted after cooldown but don't require the tool again.
---@type table<string, table<string, table<string, table>>>
local objectiveStates = {}

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

--- Find a step definition within a specific objective
---@param zoneId string
---@param objectiveId string
---@param stepId string
---@return table? objDef, table? stepDef
local function findStepDef(zoneId, objectiveId, stepId)
    local objDef = findObjectiveDef(zoneId, objectiveId)
    if not objDef then return nil, nil end

    -- Support both new multi-step format (steps[]) and legacy single-step format
    if objDef.steps then
        for _, step in ipairs(objDef.steps) do
            if step.id == stepId then
                return objDef, step
            end
        end
    end

    return objDef, nil
end

-- ============================================================================
-- OBJECTIVE STATE HELPERS
-- ============================================================================

--- Get or initialize the state entry for a specific step
---@param zoneId string
---@param objectiveId string
---@param stepId string
---@return table state
local function getStepState(zoneId, objectiveId, stepId)
    if not objectiveStates[zoneId] then
        objectiveStates[zoneId] = {}
    end
    if not objectiveStates[zoneId][objectiveId] then
        objectiveStates[zoneId][objectiveId] = {}
    end
    if not objectiveStates[zoneId][objectiveId][stepId] then
        objectiveStates[zoneId][objectiveId][stepId] = { opened = false, openedAt = 0 }
    end
    return objectiveStates[zoneId][objectiveId][stepId]
end

--- Check if a step is currently in an "opened" state
---@param zoneId string
---@param objectiveId string
---@param stepId string
---@return boolean
local function isStepOpened(zoneId, objectiveId, stepId)
    local state = getStepState(zoneId, objectiveId, stepId)
    return state.opened == true
end

--- Mark a step as opened
---@param zoneId string
---@param objectiveId string
---@param stepId string
local function setStepOpened(zoneId, objectiveId, stepId)
    local state = getStepState(zoneId, objectiveId, stepId)
    state.opened = true
    state.openedAt = os.time()
end

--- Re-lock a step (guard discovered it)
---@param zoneId string
---@param objectiveId string
---@param stepId string
local function resetStepOpened(zoneId, objectiveId, stepId)
    local state = getStepState(zoneId, objectiveId, stepId)
    state.opened = false
    state.openedAt = 0
end

-- ============================================================================
-- EQUIPMENT TIER RESOLUTION
-- ============================================================================

--- Resolve the best available equipment from the player's inventory for a given tier.
--- Iterates the tier's tool list in reverse order (last = best) and returns the
--- first tool the player has. This allows advanced tools to take priority.
---@param source integer Player server id
---@param tierKey string Key into Config.EquipmentTiers (e.g. 'lockpick', 'hacking')
---@return table? result { item, label, durationMult, consumeChance, noiseRadiusOverride? } or nil
local function resolveEquipmentTier(source, tierKey)
    if not Config.EquipmentTiers then return nil end

    local tier = Config.EquipmentTiers[tierKey]
    if not tier then return nil end

    -- Iterate in reverse: last entries are the "best" tools
    for i = #tier, 1, -1 do
        local entry = tier[i]
        local count = exports.ox_inventory:GetItemCount(source, entry.item)
        if count and count > 0 then
            return {
                item = entry.item,
                label = entry.label,
                durationMult = entry.durationMult,
                consumeChance = entry.consumeChance,
                noiseRadiusOverride = entry.noiseRadiusOverride,
            }
        end
    end

    return nil
end

--- Attempt to consume an equipment item based on its consume chance.
--- Returns true if the item was consumed (removed from inventory), false otherwise.
---@param source integer
---@param itemName string
---@param consumeChance number 0.0 to 1.0
---@return boolean consumed
local function tryConsumeEquipment(source, itemName, consumeChance)
    if consumeChance <= 0.0 then return false end

    if consumeChance >= 1.0 or math.random() <= consumeChance then
        local removed = exports.ox_inventory:RemoveItem(source, itemName, 1)
        if removed then
            return true
        end
    end

    return false
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

--- Validate and process a multi-step objective interaction.
--- Checks: zone match, step validity, alert level, equipment tier, cooldown,
--- opened state, then rolls loot.
---
--- Parameters from client: zoneId, objectiveId, stepId, alertLevel
--- Returns a result table with the outcome.
lib.callback.register('qbx_pedscenarios:server:attemptObjectiveStep', function(source, zoneId, objectiveId, stepId, alertLevel)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    local citizenid = player.PlayerData.citizenid
    if not citizenid then return { error = 'no_citizen' } end

    if not zoneId or not objectiveId or not stepId then
        return { error = 'invalid_params' }
    end

    -- Look up objective and step definitions
    local objDef, stepDef = findStepDef(zoneId, objectiveId, stepId)
    if not objDef then return { error = 'invalid_objective' } end
    if not stepDef then return { error = 'invalid_step' } end

    -- Server-side alert level validation (step-level maxAlertLevel)
    if stepDef.maxAlertLevel and alertLevel then
        local stepMaxOrder = Config.AlertLevelOrder[stepDef.maxAlertLevel] or 0
        local currentOrder = Config.AlertLevelOrder[alertLevel] or 0
        if currentOrder > stepMaxOrder then
            return { error = 'alert_too_high' }
        end
    end

    -- Check cooldown (per-objective, not per-step)
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

    -- Determine if this step is already opened (previously completed, not yet
    -- discovered by a guard or reset by server restart)
    local stepAlreadyOpened = isStepOpened(zoneId, objectiveId, stepId)

    -- Equipment tier resolution
    local equipmentResult = nil
    local consumed = false

    if stepDef.equipmentTier and not stepAlreadyOpened then
        -- Step requires a tool and has not been opened yet
        local resolved = resolveEquipmentTier(source, stepDef.equipmentTier)
        if not resolved then
            return {
                error = 'missing_equipment',
                equipmentTier = stepDef.equipmentTier,
                tierOptions = Config.EquipmentTiers and Config.EquipmentTiers[stepDef.equipmentTier] or {},
            }
        end

        -- Attempt to consume the tool based on its consumeChance
        consumed = tryConsumeEquipment(source, resolved.item, resolved.consumeChance)

        equipmentResult = {
            item = resolved.item,
            label = resolved.label,
            durationMult = resolved.durationMult,
            consumed = consumed,
            noiseRadiusOverride = resolved.noiseRadiusOverride,
        }
    elseif stepDef.equipmentTier and stepAlreadyOpened then
        -- Step is already opened: no tool needed, use base duration
        equipmentResult = {
            item = nil,
            label = nil,
            durationMult = 1.0,
            consumed = false,
            noiseRadiusOverride = nil,
            stepAlreadyOpened = true,
        }
    end

    -- Legacy support: check requiredItem if no equipmentTier is defined
    if not stepDef.equipmentTier and stepDef.requiredItem and not stepAlreadyOpened then
        local hasItem = exports.ox_inventory:GetItemCount(source, stepDef.requiredItem)
        if not hasItem or hasItem < 1 then
            return { error = 'missing_item', requiredItem = stepDef.requiredItem }
        end

        -- Consume required item if configured (legacy behavior)
        if stepDef.consumeRequired then
            local removed = exports.ox_inventory:RemoveItem(source, stepDef.requiredItem, 1)
            if not removed then
                return { error = 'consume_failed' }
            end
        end
    end

    -- Roll loot (if this step has a loot table)
    local loot = {}
    local lootTable = stepDef.lootTable
    if lootTable then
        for _, entry in ipairs(lootTable) do
            if math.random() <= entry.chance then
                local qty = math.random(entry.min, entry.max)
                if qty > 0 then
                    loot[#loot + 1] = { item = entry.item, quantity = qty }
                end
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

    -- Set cooldown per-objective (not per-step) when any step with a lootTable succeeds
    if lootTable and (#givenItems > 0 or #loot == 0) then
        local cooldownMs = objDef.cooldownMs or 0
        if cooldownMs > 0 then
            if not objectiveCooldowns[citizenid] then objectiveCooldowns[citizenid] = {} end
            objectiveCooldowns[citizenid][objectiveId] = os.time() + math.floor(cooldownMs / 1000)
        end
    end

    -- Mark step as opened on success
    setStepOpened(zoneId, objectiveId, stepId)

    -- Award free-gangs reputation for completing objective step
    if #givenItems > 0 then
        awardSecurityGangRep(source)
    end

    lib.print.info(('Player %s (%s) completed step "%s" of objective "%s" in zone "%s", received %d items'):format(
        source, citizenid, stepId, objectiveId, zoneId, #givenItems))

    return {
        result = 'success',
        loot = givenItems,
        droppedLoot = droppedItems,
        equipment = equipmentResult,
        stepOpened = true,
    }
end)

--- Legacy callback: validate and process an objective interaction (single-step).
--- Maintained for backwards compatibility with objectives that do not use steps[].
--- Checks: zone match, alert level, required item, cooldown, then rolls loot.
lib.callback.register('qbx_pedscenarios:server:attemptObjective', function(source, zoneId, objectiveId, alertLevel)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    local citizenid = player.PlayerData.citizenid
    if not citizenid then return { error = 'no_citizen' } end

    if not zoneId or not objectiveId then return { error = 'invalid_params' } end

    local objDef = findObjectiveDef(zoneId, objectiveId)
    if not objDef then return { error = 'invalid_objective' } end

    -- If the objective has steps, redirect to the step-based flow
    if objDef.steps and #objDef.steps > 0 then
        return { error = 'use_step_api', message = 'This objective uses multi-step format. Use attemptObjectiveStep instead.' }
    end

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
    if objDef.lootTable then
        for _, entry in ipairs(objDef.lootTable) do
            if math.random() <= entry.chance then
                local qty = math.random(entry.min, entry.max)
                if qty > 0 then
                    loot[#loot + 1] = { item = entry.item, quantity = qty }
                end
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
        if objDef.cooldownMs and objDef.cooldownMs > 0 then
            if not objectiveCooldowns[citizenid] then objectiveCooldowns[citizenid] = {} end
            objectiveCooldowns[citizenid][objectiveId] = os.time() + math.floor(objDef.cooldownMs / 1000)
        end
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

--- Guard discovered an opened objective step. Re-locks it so the tool is
--- required again next time a player attempts it.
--- Called by the client when a guard's investigation reaches an opened objective.
lib.callback.register('qbx_pedscenarios:server:guardDiscoveredStep', function(source, zoneId, objectiveId, stepId)
    if not zoneId or not objectiveId or not stepId then
        return { error = 'invalid_params' }
    end

    -- Validate the step definition exists
    local objDef, stepDef = findStepDef(zoneId, objectiveId, stepId)
    if not objDef or not stepDef then
        return { error = 'invalid_step' }
    end

    local wasOpened = isStepOpened(zoneId, objectiveId, stepId)
    if not wasOpened then
        return { result = 'already_locked' }
    end

    resetStepOpened(zoneId, objectiveId, stepId)

    lib.print.info(('Guard discovered step "%s" of objective "%s" in zone "%s" — re-locked'):format(
        stepId, objectiveId, zoneId))

    return { result = 'relocked' }
end)

--- Get the opened/locked state of all steps for an objective.
--- Useful for clients to know which steps are already opened.
lib.callback.register('qbx_pedscenarios:server:getObjectiveStepStates', function(source, zoneId, objectiveId)
    if not zoneId or not objectiveId then
        return { error = 'invalid_params' }
    end

    local objDef = findObjectiveDef(zoneId, objectiveId)
    if not objDef then return { error = 'invalid_objective' } end

    local states = {}

    if objDef.steps then
        for _, step in ipairs(objDef.steps) do
            local state = getStepState(zoneId, objectiveId, step.id)
            states[step.id] = {
                opened = state.opened,
                openedAt = state.openedAt,
            }
        end
    end

    return { result = 'success', states = states }
end)

--- Resolve which equipment the player has available for a given tier,
--- without consuming it. Allows the client to show UI feedback about
--- which tool will be used and the expected duration multiplier.
lib.callback.register('qbx_pedscenarios:server:resolveEquipment', function(source, tierKey)
    if not tierKey then return nil end

    local resolved = resolveEquipmentTier(source, tierKey)
    if not resolved then return nil end

    return {
        item = resolved.item,
        label = resolved.label,
        durationMult = resolved.durationMult,
        noiseRadiusOverride = resolved.noiseRadiusOverride,
    }
end)

-- ============================================================================
-- CLEANUP
-- ============================================================================

AddEventHandler('playerDropped', function()
    -- Cooldowns persist (keyed by citizenid, not source)
    -- Objective states persist (keyed by zoneId, not player)
end)

RegisterNetEvent('qbx_core:server:onLogout', function(source)
    -- Cooldowns persist across sessions (keyed by citizenid)
    -- Objective states persist (keyed by zoneId, not player)
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

--- Reset all objective step states (re-locks everything, as if server restarted)
exports('ResetAllObjectiveStates', function()
    objectiveStates = {}
    lib.print.info('All objective step states have been reset.')
end)

--- Reset objective step states for a specific zone
---@param zoneId string
exports('ResetZoneObjectiveStates', function(zoneId)
    objectiveStates[zoneId] = nil
    lib.print.info(('Objective step states reset for zone "%s".'):format(zoneId))
end)

--- Get the current opened/locked state of a specific step
---@param zoneId string
---@param objectiveId string
---@param stepId string
---@return table
exports('GetStepState', function(zoneId, objectiveId, stepId)
    local state = getStepState(zoneId, objectiveId, stepId)
    return {
        opened = state.opened,
        openedAt = state.openedAt,
    }
end)
