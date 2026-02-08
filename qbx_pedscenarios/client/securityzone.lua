--- Security Zone Scenario — Enhanced
--- Full-featured security zone system with:
--- • Alert level state machine (patrol → suspicious → alert → combat)
--- • Stealth detection (crouch, cover, noise, time-of-day)
--- • Guard archetypes (rent-a-cop, private security, PMC, elite)
--- • Guard communication with radio propagation delay
--- • Reinforcement waves on combat trigger
--- • Access systems (disguises, keycards, vehicles)
--- • Guard routines (scenario sequences between patrols)
--- • Lootable objectives (safes, computers) with ox_target + server validation

local secZones = {}             ---@type table<string, CZone>
local secZoneActive = {}        ---@type table<string, boolean>
local secGuards = {}            ---@type table<integer, GuardData>
local zoneAlertState = {}       ---@type table<string, ZoneAlertData>
local zoneObjectiveProps = {}   ---@type table<string, integer[]> -- zoneId -> prop handles
local reinforcementWave = {}    ---@type table<string, integer> -- zoneId -> current wave index
local playerAccess = {}         ---@type table<string, {type: string, expiry: integer}> -- zoneId -> access grant

-- ============================================================================
-- TYPES
-- ============================================================================

---@class GuardData
---@field ped integer
---@field zoneId string
---@field archetypeId string
---@field role 'post'|'patrol'|'reinforcement'
---@field patrolIndex? integer
---@field suspicion number -- per-guard suspicion accumulator toward player
---@field alerted boolean -- has this guard been radio-alerted by another guard
---@field alive boolean

---@class ZoneAlertData
---@field level AlertLevel
---@field levelChangedAt integer -- GetGameTimer when level last changed
---@field lastKnownPlayerPos vector3? -- where player was last spotted
---@field suspicionPool number -- aggregate zone-wide suspicion
---@field combatStartedAt integer? -- when combat began (for reinforcement timing)

-- ============================================================================
-- ARCHETYPE LOOKUP
-- ============================================================================

local archetypeCache = {}

---@param id string
---@return table?
local function getArchetype(id)
    if archetypeCache[id] then return archetypeCache[id] end
    for _, a in ipairs(Config.GuardArchetypes) do
        if a.id == id then
            archetypeCache[id] = a
            return a
        end
    end
    return nil
end

-- ============================================================================
-- ALERT LEVEL HELPERS
-- ============================================================================

---@param level AlertLevel
---@return integer
local function alertOrder(level)
    return Config.AlertLevelOrder[level] or 0
end

---@param zoneId string
---@return AlertLevel
local function getAlertLevel(zoneId)
    return zoneAlertState[zoneId] and zoneAlertState[zoneId].level or 'patrol'
end

---@param zoneId string
---@param newLevel AlertLevel
---@param playerPos? vector3
local function setAlertLevel(zoneId, newLevel, playerPos)
    local state = zoneAlertState[zoneId]
    if not state then return end

    local oldLevel = state.level
    if oldLevel == newLevel then return end

    -- Only escalate, never skip levels (except decay)
    state.level = newLevel
    state.levelChangedAt = GetGameTimer()

    if playerPos then
        state.lastKnownPlayerPos = playerPos
    end

    if newLevel == 'combat' and not state.combatStartedAt then
        state.combatStartedAt = GetGameTimer()
    end

    -- Play speech for new level on the nearest guard
    local alertCfg = Config.AlertLevels[newLevel]
    if alertCfg and alertCfg.speechOnEnter then
        local nearest = getNearestGuard(zoneId)
        if nearest and DoesEntityExist(nearest) then
            PlayPedAmbientSpeechNative(nearest, alertCfg.speechOnEnter, 'SPEECH_PARAMS_FORCE_SHOUTED')
        end
    end

    -- Notification for player
    if alertOrder(newLevel) > alertOrder(oldLevel) then
        local msgs = {
            suspicious = { title = 'Security', desc = 'Something caught their attention...', type = 'warning' },
            alert = { title = 'ALERT', desc = 'Guards are searching for an intruder!', type = 'error' },
            combat = { title = 'COMBAT', desc = 'Guards are engaging!', type = 'error' },
        }
        local msg = msgs[newLevel]
        if msg then
            lib.notify({ title = msg.title, description = msg.desc, type = msg.type, duration = 4000 })
        end
    end

    lib.print.info(('Zone "%s" alert: %s → %s'):format(zoneId, oldLevel, newLevel))
end

---@param zoneId string
---@return integer?
local function getNearestGuard(zoneId)
    local playerCoords = GetEntityCoords(cache.ped)
    local nearest, nearestDist = nil, math.huge

    for ped, data in pairs(secGuards) do
        if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) then
            local dist = #(playerCoords - GetEntityCoords(ped))
            if dist < nearestDist then
                nearest = ped
                nearestDist = dist
            end
        end
    end

    return nearest
end

-- ============================================================================
-- STEALTH DETECTION
-- ============================================================================

--- Calculate the effective detection range for a guard against the player.
--- Factors: posture, movement, cover, time-of-day, alert level.
---@param guardPed integer
---@param baseRange number
---@param zoneId string
---@return number effectiveRange
local function calculateDetectionRange(guardPed, baseRange, zoneId)
    if not Config.Stealth.enabled then
        local alertCfg = Config.AlertLevels[getAlertLevel(zoneId)]
        return baseRange * (alertCfg and alertCfg.detectionMultiplier or 1.0)
    end

    local mult = 1.0
    local st = Config.Stealth

    -- Posture
    if IsPedInCover(cache.ped, false) then
        mult = mult * st.behindCoverModifier
    elseif GetPedStealthMovement(cache.ped) then
        mult = mult * st.crouchModifier
    elseif IsPedSprinting(cache.ped) then
        mult = mult * st.sprintModifier
    elseif IsPedWalking(cache.ped) then
        mult = mult * st.walkModifier
    elseif IsPedStill(cache.ped) then
        mult = mult * st.stillModifier
    end

    -- Time of day
    local hour = GetClockHours()
    local isNight
    if st.nightStartHour > st.nightEndHour then
        isNight = hour >= st.nightStartHour or hour < st.nightEndHour
    else
        isNight = hour >= st.nightStartHour and hour < st.nightEndHour
    end
    mult = mult * (isNight and st.nightModifier or st.dayModifier)

    -- Alert level multiplier
    local alertCfg = Config.AlertLevels[getAlertLevel(zoneId)]
    if alertCfg then
        mult = mult * alertCfg.detectionMultiplier
    end

    return baseRange * mult
end

--- Check for instant-detection noise events (gunshots, explosions)
---@param zoneId string
---@param zoneConfig table
---@return boolean triggered, vector3? sourcePos
local function checkNoiseEvents(zoneId, zoneConfig)
    local playerCoords = GetEntityCoords(cache.ped)
    local st = Config.Stealth

    -- Check if player fired a weapon recently
    if IsPedShooting(cache.ped) then
        -- Any guard within gunshot range is instantly alerted
        for ped, data in pairs(secGuards) do
            if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) then
                if #(playerCoords - GetEntityCoords(ped)) < st.gunshotDetectionRange then
                    return true, playerCoords
                end
            end
        end
    end

    return false, nil
end

-- ============================================================================
-- ACCESS SYSTEM CHECKS
-- ============================================================================

--- Check if player currently has valid access to a zone
---@param zoneId string
---@param zoneConfig table
---@return boolean hasAccess, string? accessType
local function checkPlayerAccess(zoneId, zoneConfig)
    local access = zoneConfig.access
    if not access then return false, nil end

    -- Check if alert level is too high for access to work
    if access.bypassAlertLevel then
        local currentLevel = getAlertLevel(zoneId)
        if alertOrder(currentLevel) >= alertOrder(access.bypassAlertLevel) then
            return false, nil
        end
    end

    -- Check cached access grant (keycard with duration)
    if playerAccess[zoneId] then
        if playerAccess[zoneId].expiry == 0 or GetGameTimer() < playerAccess[zoneId].expiry then
            return true, playerAccess[zoneId].type
        end
        playerAccess[zoneId] = nil
    end

    -- Check disguise
    if access.disguises then
        for _, disguise in ipairs(access.disguises) do
            local matches = true
            for componentId, expected in pairs(disguise.components) do
                local drawable = GetPedDrawableVariation(cache.ped, componentId)
                local texture = GetPedTextureVariation(cache.ped, componentId)
                if drawable ~= expected[1] or texture ~= expected[2] then
                    matches = false
                    break
                end
            end
            if matches then
                return true, 'disguise'
            end
        end
    end

    -- Check vehicle
    if access.vehicles and IsPedInAnyVehicle(cache.ped, false) then
        local veh = GetVehiclePedIsIn(cache.ped, false)
        local vehModel = GetEntityModel(veh)
        for _, vehicleAccess in ipairs(access.vehicles) do
            if vehicleAccess.mustBeDriver and GetPedInVehicleSeat(veh, -1) ~= cache.ped then
                goto nextVehicle
            end
            for _, model in ipairs(vehicleAccess.models) do
                if vehModel == model then
                    return true, 'vehicle'
                end
            end
            ::nextVehicle::
        end
    end

    -- Check keycards (async server check, but we cache the result)
    if access.keycards then
        for _, keycard in ipairs(access.keycards) do
            local hasItem = lib.callback.await('qbx_pedscenarios:server:checkAccessItem', false, keycard.item)
            if hasItem then
                local expiry = keycard.grantDurationMs > 0
                    and (GetGameTimer() + keycard.grantDurationMs)
                    or 0

                playerAccess[zoneId] = { type = 'keycard', expiry = expiry }

                if keycard.consumeOnUse then
                    lib.callback.await('qbx_pedscenarios:server:consumeAccessItem', false, keycard.item)
                end

                return true, 'keycard'
            end
        end
    end

    return false, nil
end

-- ============================================================================
-- GUARD SPAWNING
-- ============================================================================

--- Configure a guard ped with archetype properties
---@param ped integer
---@param archetype table
---@param zoneConfig table
local function configureGuard(ped, archetype, zoneConfig)
    SetEntityMaxHealth(ped, archetype.health)
    SetEntityHealth(ped, archetype.health)
    SetPedArmour(ped, archetype.armor)
    SetPedAccuracy(ped, archetype.accuracy)
    SetPedCombatAbility(ped, archetype.combatAbility)
    SetPedCombatMovement(ped, archetype.combatMovement)
    SetPedCombatRange(ped, archetype.combatRange)
    SetPedAlertness(ped, 3)
    SetPedSeeingRange(ped, zoneConfig.detectionRadius * 1.5)
    SetPedHearingRange(ped, zoneConfig.detectionRadius * 0.6)

    ApplyCombatAttributes(ped, archetype.combatAttributes)

    -- Give random weapon from archetype pool
    local weapon = PickRandom(archetype.weapons)
    GivePedLoadout(ped, weapon)

    -- Set relationship group
    SetPedRelationshipGroupHash(ped, `YOURFRIENDLYGROUP`)
end

---@param post table
---@param zoneId string
---@param zoneConfig table
---@return integer?
local function spawnPostGuard(post, zoneId, zoneConfig)
    local archetypeId = post.archetypeOverride or zoneConfig.defaultArchetype
    local archetype = getArchetype(archetypeId)
    if not archetype then return nil end

    local modelHash = PickRandom(archetype.pedModels)
    local ped = SpawnScenarioPed(modelHash, post.coords, post.coords.w, 0)
    if not ped then return nil end

    configureGuard(ped, archetype, zoneConfig)

    if post.scenario then
        TaskStartScenarioInPlace(ped, post.scenario, 0, true)
    end

    secGuards[ped] = {
        ped = ped,
        zoneId = zoneId,
        archetypeId = archetypeId,
        role = 'post',
        suspicion = 0,
        alerted = false,
        alive = true,
    }

    return ped
end

---@param patrol table
---@param zoneId string
---@param zoneConfig table
---@return integer?
local function spawnPatrolGuard(patrol, zoneId, zoneConfig)
    if #patrol.waypoints < 2 then return nil end

    local archetypeId = patrol.archetypeOverride or zoneConfig.defaultArchetype
    local archetype = getArchetype(archetypeId)
    if not archetype then return nil end

    local startPoint = patrol.waypoints[1]
    local modelHash = PickRandom(archetype.pedModels)
    local ped = SpawnScenarioPed(modelHash, startPoint, startPoint.w, 0)
    if not ped then return nil end

    configureGuard(ped, archetype, zoneConfig)

    secGuards[ped] = {
        ped = ped,
        zoneId = zoneId,
        archetypeId = archetypeId,
        role = 'patrol',
        patrolIndex = 1,
        suspicion = 0,
        alerted = false,
        alive = true,
    }

    -- Patrol loop with optional routine steps
    CreateThread(function()
        local idx = 1
        while DoesEntityExist(ped) and secZoneActive[zoneId] do
            local alert = getAlertLevel(zoneId)
            if alert == 'combat' or alert == 'alert' then
                Wait(1000)
                goto continue
            end

            local wp = patrol.waypoints[idx]
            ClearPedTasks(ped)
            TaskGoStraightToCoord(ped, wp.x, wp.y, wp.z, patrol.speed, -1, wp.w, 0.5)
            SetPedKeepTask(ped, true)

            -- Wait until arrival or zone state change
            repeat
                Wait(1000)
                if not DoesEntityExist(ped) or not secZoneActive[zoneId] then return end
                if getAlertLevel(zoneId) == 'combat' or getAlertLevel(zoneId) == 'alert' then goto continue end
            until #(GetEntityCoords(ped) - vec3(wp.x, wp.y, wp.z)) < 2.0

            -- Routine steps at waypoint
            if patrol.routineSteps and #patrol.routineSteps > 0 and math.random() < 0.4 then
                local step = PickRandom(patrol.routineSteps)
                if step.coords then
                    TaskGoStraightToCoord(ped, step.coords.x, step.coords.y, step.coords.z, 1.0, -1, step.coords.w, 0.5)
                    repeat Wait(500) until not DoesEntityExist(ped) or not secZoneActive[zoneId]
                        or #(GetEntityCoords(ped) - vec3(step.coords.x, step.coords.y, step.coords.z)) < 2.0
                end

                if DoesEntityExist(ped) and secZoneActive[zoneId] and getAlertLevel(zoneId) == 'patrol' then
                    ClearPedTasks(ped)
                    TaskStartScenarioInPlace(ped, step.scenario, 0, true)
                    Wait(step.durationMs)
                end
            else
                Wait(2000)
            end

            idx = idx % #patrol.waypoints + 1
            ::continue::
        end
    end)

    return ped
end

--- Spawn reinforcement guards
---@param wave table
---@param zoneId string
---@param zoneConfig table
local function spawnReinforcementWave(wave, zoneId, zoneConfig)
    local archetype = getArchetype(wave.archetypeId)
    if not archetype then return end

    local playerCoords = GetEntityCoords(cache.ped)

    for _ = 1, wave.count do
        local angle = math.random() * 2 * math.pi
        local dist = wave.spawnRadius * 0.8 + math.random() * wave.spawnRadius * 0.4
        local x = zoneConfig.zone.coords.x + math.cos(angle) * dist
        local y = zoneConfig.zone.coords.y + math.sin(angle) * dist
        local z = zoneConfig.zone.coords.z

        local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
        if found then z = groundZ end

        local modelHash = PickRandom(archetype.pedModels)
        local ped = SpawnScenarioPed(modelHash, vec3(x, y, z), 0.0, 0)
        if ped then
            configureGuard(ped, archetype, zoneConfig)

            -- Immediately hostile
            local hostileGroup = `YOURFRIENDLYGROUP`
            SetPedRelationshipGroupHash(ped, hostileGroup)
            TaskCombatPed(ped, cache.ped, 0, 16)
            SetPedKeepTask(ped, true)

            secGuards[ped] = {
                ped = ped,
                zoneId = zoneId,
                archetypeId = wave.archetypeId,
                role = 'reinforcement',
                suspicion = 100,
                alerted = true,
                alive = true,
            }
        end
    end

    lib.notify({
        title = 'Security',
        description = 'Reinforcements have arrived!',
        type = 'error', duration = 3000,
    })
end

-- ============================================================================
-- GUARD BEHAVIOR PER ALERT LEVEL
-- ============================================================================

--- Apply behavior changes to all zone guards based on current alert level
---@param zoneId string
---@param zoneConfig table
local function applyAlertBehavior(zoneId, zoneConfig)
    local level = getAlertLevel(zoneId)
    local state = zoneAlertState[zoneId]

    for ped, data in pairs(secGuards) do
        if data.zoneId ~= zoneId or not data.alive or not DoesEntityExist(ped) then
            if DoesEntityExist(ped) and IsPedDeadOrDying(ped, true) then
                data.alive = false
            end
            goto continue
        end

        if level == 'suspicious' then
            -- Investigating guard walks toward last known position
            if state.lastKnownPlayerPos and not data.alerted then
                data.alerted = true
                ClearPedTasks(ped)
                local cfg = Config.AlertLevels.suspicious
                TaskGoStraightToCoord(ped, state.lastKnownPlayerPos.x, state.lastKnownPlayerPos.y,
                    state.lastKnownPlayerPos.z, cfg.investigateSpeed, -1, 0.0, 1.0)
                SetPedKeepTask(ped, true)

                local archetype = getArchetype(data.archetypeId)
                if archetype then
                    PlayPedAmbientSpeechNative(ped, archetype.speechSuspicious, 'SPEECH_PARAMS_FORCE_NORMAL')
                end
            end

        elseif level == 'alert' then
            -- All guards converge on last known position
            if state.lastKnownPlayerPos and not data.alerted then
                -- Radio delay: stagger response
                local delay = data.role == 'post' and 0 or (Config.AlertLevels.alert.radioPropagationMs or 2000)

                SetTimeout(delay, function()
                    if not DoesEntityExist(ped) or not secZoneActive[zoneId] then return end
                    data.alerted = true
                    ClearPedTasks(ped)
                    local cfg = Config.AlertLevels.alert
                    TaskGoStraightToCoord(ped, state.lastKnownPlayerPos.x, state.lastKnownPlayerPos.y,
                        state.lastKnownPlayerPos.z, cfg.searchSpeed, -1, 0.0, 1.0)
                    SetPedKeepTask(ped, true)

                    local archetype = getArchetype(data.archetypeId)
                    if archetype then
                        PlayPedAmbientSpeechNative(ped, archetype.speechAlert, 'SPEECH_PARAMS_FORCE_SHOUTED')
                    end
                end)
            end

        elseif level == 'combat' then
            if not data.alerted then
                data.alerted = true
                ClearPedTasks(ped)
                local hostileGroup = `YOURFRIENDLYGROUP`
                SetRelationshipBetweenGroups(5, hostileGroup, `PLAYER`)
                SetRelationshipBetweenGroups(5, `PLAYER`, hostileGroup)
                SetPedRelationshipGroupHash(ped, hostileGroup)
                TaskCombatPed(ped, cache.ped, 0, 16)
                SetPedKeepTask(ped, true)

                -- Check for flee behavior
                local archetype = getArchetype(data.archetypeId)
                if archetype and archetype.fleeHealthThreshold then
                    SetPedFleeAttributes(ped, 2, true)
                end
            end
        end

        ::continue::
    end
end

--- Reset guard alerted flags (used when level decays)
---@param zoneId string
local function resetGuardAlerts(zoneId)
    for _, data in pairs(secGuards) do
        if data.zoneId == zoneId then
            data.alerted = false
        end
    end
end

-- ============================================================================
-- OBJECTIVE INTERACTION
-- ============================================================================

--- Spawn objective props and register ox_target interactions
---@param zoneId string
---@param zoneConfig table
local function initObjectives(zoneId, zoneConfig)
    if not zoneConfig.objectives or #zoneConfig.objectives == 0 then return end

    zoneObjectiveProps[zoneId] = {}

    for _, obj in ipairs(zoneConfig.objectives) do
        -- Spawn prop if defined
        local propHandle = nil
        if obj.prop then
            if RequestModelAsync(obj.prop, 5000) then
                propHandle = CreateObject(obj.prop, obj.coords.x, obj.coords.y, obj.coords.z, false, false, false)
                if DoesEntityExist(propHandle) then
                    SetEntityHeading(propHandle, obj.coords.w)
                    FreezeEntityPosition(propHandle, true)
                    zoneObjectiveProps[zoneId][#zoneObjectiveProps[zoneId] + 1] = propHandle
                end
                SetModelAsNoLongerNeeded(obj.prop)
            end
        end

        -- Register ox_target zone for this objective
        if GetResourceState('ox_target') == 'started' then
            exports.ox_target:addSphereZone({
                coords = vec3(obj.coords.x, obj.coords.y, obj.coords.z),
                radius = 1.2,
                debug = Config.Debug,
                options = {
                    {
                        name = 'seczone_obj_' .. obj.id,
                        icon = obj.icon,
                        label = obj.label,
                        distance = 2.0,
                        canInteract = function()
                            -- Check alert level constraint
                            if obj.maxAlertLevel then
                                local current = getAlertLevel(zoneId)
                                if alertOrder(current) > alertOrder(obj.maxAlertLevel) then
                                    return false
                                end
                            end
                            return true
                        end,
                        onSelect = function()
                            interactWithObjective(zoneId, obj)
                        end,
                    },
                },
            })
        end
    end
end

--- Handle objective interaction: check, animate, reward
---@param zoneId string
---@param objDef table
function interactWithObjective(zoneId, objDef)
    -- Check cooldown first
    local cdCheck = lib.callback.await('qbx_pedscenarios:server:checkObjectiveCooldown', false, objDef.id)
    if cdCheck and not cdCheck.available then
        local mins = math.ceil((cdCheck.remainingMs or 0) / 60000)
        lib.notify({
            title = 'Locked',
            description = ('On cooldown. Available in ~%d min.'):format(mins),
            type = 'error',
        })
        return
    end

    -- Check alert level
    if objDef.maxAlertLevel then
        local current = getAlertLevel(zoneId)
        if alertOrder(current) > alertOrder(objDef.maxAlertLevel) then
            lib.notify({
                title = 'Too Dangerous',
                description = 'Can\'t do this while guards are on high alert!',
                type = 'error',
            })
            return
        end
    end

    -- Load animation if specified
    if objDef.animDict then
        lib.requestAnimDict(objDef.animDict)
        TaskPlayAnim(cache.ped, objDef.animDict, objDef.animName, 8.0, -8.0, -1, 1, 0, false, false, false)
    end

    -- Progress bar
    local completed = lib.progressBar({
        duration = objDef.interactDurationMs,
        label = objDef.label .. '...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
    })

    ClearPedTasks(cache.ped)
    if objDef.animDict then RemoveAnimDict(objDef.animDict) end

    if not completed then
        lib.notify({ title = objDef.label, description = 'Cancelled.', type = 'error' })
        return
    end

    -- Server processes the objective (validates items, rolls loot, applies cooldown)
    local result = lib.callback.await('qbx_pedscenarios:server:attemptObjective', false, objDef.id)

    if not result then
        lib.notify({ title = objDef.label, description = 'Failed.', type = 'error' })
        return
    end

    if result.error == 'cooldown' then
        local mins = math.ceil((result.remainingMs or 0) / 60000)
        lib.notify({
            title = 'Locked',
            description = ('On cooldown. ~%d min remaining.'):format(mins),
            type = 'error',
        })
        return
    end

    if result.error == 'missing_item' then
        lib.notify({
            title = objDef.label,
            description = ('You need: %s'):format(result.requiredItem),
            type = 'error',
        })
        return
    end

    if result.result == 'success' then
        local lootDesc = ''
        if result.loot and #result.loot > 0 then
            local parts = {}
            for _, l in ipairs(result.loot) do
                parts[#parts + 1] = ('%dx %s'):format(l.quantity, l.item)
            end
            lootDesc = table.concat(parts, ', ')
        else
            lootDesc = 'Nothing useful'
        end

        lib.notify({
            title = objDef.label,
            description = ('Success! Got: %s'):format(lootDesc),
            type = 'success', duration = 5000,
        })
    end
end

--- Cleanup objective props and ox_target zones
---@param zoneId string
local function cleanupObjectives(zoneId)
    if zoneObjectiveProps[zoneId] then
        for _, prop in ipairs(zoneObjectiveProps[zoneId]) do
            if DoesEntityExist(prop) then DeleteObject(prop) end
        end
        zoneObjectiveProps[zoneId] = nil
    end
end

-- ============================================================================
-- MAIN DETECTION & ALERT LOOP
-- ============================================================================

--- Core detection tick. Runs at interval based on current alert level.
---@param zoneId string
---@param zoneConfig table
local function detectionTick(zoneId, zoneConfig)
    local state = zoneAlertState[zoneId]
    if not state then return end

    local level = state.level
    local playerCoords = GetEntityCoords(cache.ped)

    -- Check for player access (disguise/keycard/vehicle)
    local hasAccess, accessType = checkPlayerAccess(zoneId, zoneConfig)
    if hasAccess then
        -- Player has access: slowly decay suspicion
        state.suspicionPool = math.max(state.suspicionPool - Config.Stealth.suspicionDecayRate * 2, 0)
        return
    end

    -- Check for noise events (instant escalation)
    local noiseTriggered, noisePos = checkNoiseEvents(zoneId, zoneConfig)
    if noiseTriggered then
        if alertOrder(level) < alertOrder('alert') then
            setAlertLevel(zoneId, 'alert', noisePos)
        elseif level == 'alert' then
            setAlertLevel(zoneId, 'combat', noisePos)
        end
        state.suspicionPool = Config.Stealth.suspicionThreshold
        applyAlertBehavior(zoneId, zoneConfig)
        return
    end

    -- Check guard-by-guard detection
    local anyDetected = false
    local thresholdMult = zoneConfig.alertOverrides and zoneConfig.alertOverrides.suspicionThresholdMult or 1.0
    local effectiveThreshold = Config.Stealth.suspicionThreshold * thresholdMult

    for ped, data in pairs(secGuards) do
        if data.zoneId ~= zoneId or not data.alive or not DoesEntityExist(ped) then
            -- Check if guard died
            if DoesEntityExist(ped) and IsPedDeadOrDying(ped, true) then
                data.alive = false
                -- Dead guard found = instant alert escalation
                if alertOrder(level) < alertOrder('alert') then
                    setAlertLevel(zoneId, 'alert', GetEntityCoords(ped))
                    applyAlertBehavior(zoneId, zoneConfig)
                end
            end
            goto nextGuard
        end

        local pedCoords = GetEntityCoords(ped)
        local dist = #(playerCoords - pedCoords)
        local effectiveRange = calculateDetectionRange(ped, zoneConfig.detectionRadius, zoneId)

        if dist < effectiveRange then
            local hasLOS = HasEntityClearLosToEntity(ped, cache.ped, 17)

            if hasLOS then
                anyDetected = true
                state.lastKnownPlayerPos = playerCoords
                data.suspicion = data.suspicion + Config.Stealth.suspicionBuildRate

                -- Check if player attacked any guard
                if HasEntityBeenDamagedByEntity(ped, cache.ped, true) then
                    ClearEntityLastDamageEntity(ped)
                    state.suspicionPool = effectiveThreshold
                    if alertOrder(level) < alertOrder('combat') then
                        setAlertLevel(zoneId, 'combat', playerCoords)
                        applyAlertBehavior(zoneId, zoneConfig)
                        return
                    end
                end
            else
                -- No LOS: slower suspicion with behind-cover modifier
                if dist < effectiveRange * Config.Stealth.behindCoverModifier then
                    data.suspicion = data.suspicion + Config.Stealth.suspicionBuildRate * 0.3
                else
                    data.suspicion = math.max(data.suspicion - Config.Stealth.suspicionDecayRate, 0)
                end
            end
        else
            data.suspicion = math.max(data.suspicion - Config.Stealth.suspicionDecayRate, 0)
        end

        ::nextGuard::
    end

    -- Aggregate suspicion pool from individual guards
    local maxGuardSuspicion = 0
    for _, data in pairs(secGuards) do
        if data.zoneId == zoneId and data.suspicion > maxGuardSuspicion then
            maxGuardSuspicion = data.suspicion
        end
    end
    state.suspicionPool = maxGuardSuspicion

    -- Check threshold crossing for escalation
    if state.suspicionPool >= effectiveThreshold then
        local alertCfg = Config.AlertLevels[level]
        if alertCfg and alertCfg.transitionTo then
            setAlertLevel(zoneId, alertCfg.transitionTo, state.lastKnownPlayerPos)
            resetGuardAlerts(zoneId)
            applyAlertBehavior(zoneId, zoneConfig)
            state.suspicionPool = 0
            -- Reset individual suspicion
            for _, data in pairs(secGuards) do
                if data.zoneId == zoneId then data.suspicion = 0 end
            end
        end
    end

    -- Alert level decay: if no detection for the duration, step down
    if not anyDetected and level ~= 'patrol' then
        local alertCfg = Config.AlertLevels[level]
        if alertCfg and alertCfg.durationMs then
            local elapsed = GetGameTimer() - state.levelChangedAt
            if elapsed > alertCfg.durationMs then
                if alertCfg.decayTo then
                    setAlertLevel(zoneId, alertCfg.decayTo)
                    resetGuardAlerts(zoneId)
                    state.suspicionPool = 0
                    for _, data in pairs(secGuards) do
                        if data.zoneId == zoneId then data.suspicion = 0 end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- REINFORCEMENT MANAGER
-- ============================================================================

---@param zoneId string
---@param zoneConfig table
local function reinforcementLoop(zoneId, zoneConfig)
    local cfg = zoneConfig.reinforcements
    if not cfg or not cfg.enabled then return end

    reinforcementWave[zoneId] = 0

    CreateThread(function()
        while secZoneActive[zoneId] do
            Wait(2000)

            local state = zoneAlertState[zoneId]
            if not state or state.level ~= 'combat' or not state.combatStartedAt then
                goto tick
            end

            local elapsed = GetGameTimer() - state.combatStartedAt
            local currentWave = reinforcementWave[zoneId] or 0

            if currentWave < cfg.maxWaves and currentWave < #cfg.waves then
                local nextWave = cfg.waves[currentWave + 1]
                if elapsed >= nextWave.delayMs then
                    reinforcementWave[zoneId] = currentWave + 1
                    spawnReinforcementWave(nextWave, zoneId, zoneConfig)
                    lib.print.info(('Zone "%s" reinforcement wave %d/%d'):format(
                        zoneId, currentWave + 1, cfg.maxWaves))
                end
            end

            ::tick::
        end
    end)
end

-- ============================================================================
-- ZONE LIFECYCLE
-- ============================================================================

function InitSecurityZones()
    for _, config in ipairs(Config.SecurityZones) do
        local zoneId = config.id

        local zoneData = {
            coords = config.zone.coords,
            radius = config.zone.radius,
            size = config.zone.size,
            rotation = config.zone.rotation,
            debug = Config.Debug,

            onEnter = function()
                secZoneActive[zoneId] = true
                playerAccess[zoneId] = nil

                -- Initialize alert state
                zoneAlertState[zoneId] = {
                    level = 'patrol',
                    levelChangedAt = GetGameTimer(),
                    lastKnownPlayerPos = nil,
                    suspicionPool = 0,
                    combatStartedAt = nil,
                }

                lib.print.info(('Entered security zone: %s'):format(config.label))

                -- Spawn post guards
                for _, post in ipairs(config.posts) do
                    spawnPostGuard(post, zoneId, config)
                end

                -- Spawn patrol guards
                if config.patrols then
                    for _, patrol in ipairs(config.patrols) do
                        spawnPatrolGuard(patrol, zoneId, config)
                    end
                end

                -- Initialize objectives
                initObjectives(zoneId, config)

                -- Start reinforcement manager
                reinforcementLoop(zoneId, config)

                -- Main detection loop (interval adapts to alert level)
                CreateThread(function()
                    while secZoneActive[zoneId] do
                        detectionTick(zoneId, config)

                        local level = getAlertLevel(zoneId)
                        local alertCfg = Config.AlertLevels[level]
                        Wait(alertCfg and alertCfg.checkIntervalMs or 1000)
                    end
                end)
            end,

            onExit = function()
                secZoneActive[zoneId] = false
                playerAccess[zoneId] = nil

                lib.print.info(('Exited security zone: %s'):format(config.label))

                -- Reset relationships
                SetRelationshipBetweenGroups(1, `YOURFRIENDLYGROUP`, `PLAYER`)
                SetRelationshipBetweenGroups(1, `PLAYER`, `YOURFRIENDLYGROUP`)

                -- Cleanup objectives
                cleanupObjectives(zoneId)

                -- Delayed guard cleanup
                SetTimeout(8000, function()
                    if not secZoneActive[zoneId] then
                        for ped, data in pairs(secGuards) do
                            if data.zoneId == zoneId then
                                RemoveScenarioPed(ped)
                                secGuards[ped] = nil
                            end
                        end
                        zoneAlertState[zoneId] = nil
                        reinforcementWave[zoneId] = nil
                    end
                end)
            end,
        }

        secZones[zoneId] = lib.zones[config.zone.type](zoneData)
    end
end

function CleanupSecurityZones()
    for id, zone in pairs(secZones) do
        secZoneActive[id] = false
        zone:remove()
    end
    secZones = {}

    for ped in pairs(secGuards) do
        RemoveScenarioPed(ped)
    end
    secGuards = {}

    for zoneId in pairs(zoneObjectiveProps) do
        cleanupObjectives(zoneId)
    end

    zoneAlertState = {}
    reinforcementWave = {}
    playerAccess = {}
end
