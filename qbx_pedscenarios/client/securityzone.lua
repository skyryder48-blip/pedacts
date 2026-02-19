--- Security Zone Scenario — Enhanced v2
--- Full-featured security zone system with:
--- • Alert level state machine (patrol → suspicious → alert → combat)
--- • Stealth detection (crouch, cover, noise, time-of-day)
--- • Guard archetypes (rent-a-cop, private security, PMC, elite)
--- • Guard communication with radio propagation delay
--- • Reinforcement waves on combat trigger (+ continuous waves)
--- • Access systems (disguises, keycards, vehicles)
--- • Guard routines (scenario sequences between patrols)
--- • Multi-step objectives with equipment tiers and noise events
--- • Guard tactical behaviors (cover, flanking, suppressive fire, pursuit)
--- • Guard shift variations (time-of-day archetype/count changes)
--- • Guard morale system (flee/retreat on low morale)
--- • Objective state persistence and guard discovery
--- • Debug visualization (detection cones, suspicion bars, morale, waypoints)
--- • Animation/prop cleanup on interrupt (death, ragdoll, taser)

local secZones = {}             ---@type table<string, CZone>
local secZoneActive = {}        ---@type table<string, boolean>
local secGuards = {}            ---@type table<integer, GuardData>
local zoneAlertState = {}       ---@type table<string, ZoneAlertData>
local zoneObjectiveProps = {}   ---@type table<string, integer[]> -- zoneId -> prop handles
local zoneTargetZones = {}      ---@type table<string, integer[]> -- zoneId -> ox_target zone ids
local reinforcementWave = {}    ---@type table<string, integer> -- zoneId -> current wave index
local reinforcementsActive = {} ---@type table<string, boolean> -- zoneId -> post-exit reinforcement flag
local playerAccess = {}         ---@type table<string, {type: string, expiry: integer}> -- zoneId -> access grant
local keycardCache = {}         ---@type table<string, {result: boolean, expiry: integer}> -- zoneId -> cached check
local deadPostGuards = {}       ---@type table<string, table[]> -- zoneId -> dead post guard info for respawn

-- New state tables
local objectiveOpenStates = {} ---@type table<string, table<string, boolean>> -- zoneId -> { stepId = true }
local activeZoneEffects = {}   ---@type table<string, table> -- zoneId -> { detectionMultiplier, reinforcementDelay, ... }
local pursuingGuards = {}      ---@type table<integer, { zoneId: string, lastLosTime: integer, losTimeout: integer }> -- ped -> pursuit state
local activeInteractionCleanup = nil ---@type function? -- cleanup callback for current interaction

local interactWithObjective     -- forward declaration (defined after initObjectives)

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
---@field deathPos? vector3 -- where the guard died (for body discovery)
---@field bodyDiscovered? boolean -- has another guard found this body
---@field postConfig? table -- original post config entry (for respawn)
---@field morale number -- current morale (starts at Config.GuardMorale.base)
---@field wounded boolean -- has this guard been wounded below retreat threshold
---@field fleeing boolean -- is this guard fleeing due to morale

---@class ZoneAlertData
---@field level AlertLevel
---@field levelChangedAt integer -- GetGameTimer when level last changed
---@field lastKnownPlayerPos vector3? -- where player was last spotted
---@field suspicionPool number -- aggregate zone-wide suspicion
---@field combatStartedAt integer? -- when combat began (for reinforcement timing)
---@field continuousWaveCount integer? -- how many continuous waves have spawned

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

--- Check if a ped is facing toward a target position (horizontal plane).
---@param ped integer
---@param targetPos vector3
---@return boolean
local function isPedFacingPosition(ped, targetPos)
    local pedCoords = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local dir = targetPos - pedCoords
    local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)
    if len < 0.01 then return true end
    local dot = (fwd.x * dir.x + fwd.y * dir.y) / len
    return dot >= (Config.Stealth.guardFovDot or -0.2)
end

---@param zoneId string
---@param newLevel AlertLevel
---@param playerPos? vector3
local function setAlertLevel(zoneId, newLevel, playerPos)
    local state = zoneAlertState[zoneId]
    if not state then return end

    local oldLevel = state.level
    if oldLevel == newLevel then return end

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

    -- Notification for player (configurable — disable for pure visual immersion)
    if Config.AlertNotifications and Config.AlertNotifications.enabled and alertOrder(newLevel) > alertOrder(oldLevel) then
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

-- ============================================================================
-- STEALTH DETECTION
-- ============================================================================

--- Calculate the effective detection range for a guard against the player.
--- Factors: posture, movement, cover, time-of-day, alert level, zone effects.
---@param guardPed integer
---@param baseRange number
---@param zoneId string
---@return number effectiveRange
local function calculateDetectionRange(guardPed, baseRange, zoneId)
    if not Config.Stealth.enabled then
        local alertCfg = Config.AlertLevels[getAlertLevel(zoneId)]
        local range = baseRange * (alertCfg and alertCfg.detectionMultiplier or 1.0)
        -- Apply zone effects
        local effects = activeZoneEffects[zoneId]
        if effects and effects.detectionMultiplier then
            range = range * effects.detectionMultiplier
        end
        return range
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

    -- Apply zone effects (e.g. from disabling cameras)
    local effects = activeZoneEffects[zoneId]
    if effects and effects.detectionMultiplier then
        mult = mult * effects.detectionMultiplier
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
        for ped, data in pairs(secGuards) do
            if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) then
                if #(playerCoords - GetEntityCoords(ped)) < st.gunshotDetectionRange then
                    return true, playerCoords
                end
            end
        end
    end

    -- Check for nearby explosions (type -1 = any explosion type)
    if IsExplosionInSphere(-1, playerCoords.x, playerCoords.y, playerCoords.z, st.explosionDetectionRange) then
        return true, playerCoords
    end

    -- Check if player is honking a vehicle horn
    if IsPedInAnyVehicle(cache.ped, false) then
        local veh = GetVehiclePedIsIn(cache.ped, false)
        if IsHornActive(veh) then
            for ped, data in pairs(secGuards) do
                if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) then
                    if #(playerCoords - GetEntityCoords(ped)) < st.vehicleHornRange then
                        return true, playerCoords
                    end
                end
            end
        end
    end

    return false, nil
end

-- ============================================================================
-- NOISE EVENT GENERATION (from objective step interactions)
-- ============================================================================

--- Generate a noise event at a position. Guards within radius are alerted.
---@param zoneId string
---@param pos vector3
---@param radius number
local function generateNoiseEvent(zoneId, pos, radius)
    if radius <= 0 then return end

    for ped, data in pairs(secGuards) do
        if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) then
            local dist = #(pos - GetEntityCoords(ped))
            if dist < radius then
                data.suspicion = data.suspicion + Config.Stealth.suspicionBuildRate * 2.0
            end
        end
    end
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

    -- Check keycards (server check cached with short TTL to avoid blocking detection loop)
    if access.keycards then
        local cached = keycardCache[zoneId]
        if cached and GetGameTimer() < cached.expiry then
            if cached.result then return true, 'keycard' end
        else
            for _, keycard in ipairs(access.keycards) do
                local hasItem = lib.callback.await('qbx_pedscenarios:server:checkAccessItem', false, keycard.item)
                if hasItem then
                    local grantExpiry = keycard.grantDurationMs > 0
                        and (GetGameTimer() + keycard.grantDurationMs)
                        or 0

                    playerAccess[zoneId] = { type = 'keycard', expiry = grantExpiry }
                    keycardCache[zoneId] = { result = true, expiry = GetGameTimer() + 5000 }

                    if keycard.consumeOnUse then
                        lib.callback.await('qbx_pedscenarios:server:consumeAccessItem', false, keycard.item)
                    end

                    return true, 'keycard'
                end
            end
            keycardCache[zoneId] = { result = false, expiry = GetGameTimer() + 3000 }
        end
    end

    return false, nil
end

-- ============================================================================
-- GUARD SHIFT SYSTEM
-- ============================================================================

--- Determine the current shift for a zone based on game hour.
---@param shifts table[]
---@return table? shift -- the active shift entry, or nil if no match
local function getCurrentShift(shifts)
    if not shifts or #shifts == 0 then return nil end

    local hour = GetClockHours()
    for _, shift in ipairs(shifts) do
        if shift.startHour < shift.endHour then
            -- Same-day range (e.g. 6-18)
            if hour >= shift.startHour and hour < shift.endHour then
                return shift
            end
        else
            -- Overnight range (e.g. 18-6)
            if hour >= shift.startHour or hour < shift.endHour then
                return shift
            end
        end
    end

    -- Fallback: return first shift
    return shifts[1]
end

--- Apply post/patrol multiplier to determine if a given entry should spawn.
--- multiplier < 1.0: random chance to skip (cull)
--- multiplier > 1.0: spawn and possibly duplicate
---@param multiplier number
---@return integer count -- how many times to spawn (0 = skip, 1 = normal, 2+ = duplicate)
local function applySpawnMultiplier(multiplier)
    if multiplier <= 0 then return 0 end

    local wholeCount = math.floor(multiplier)
    local fractional = multiplier - wholeCount
    if math.random() < fractional then
        wholeCount = wholeCount + 1
    end

    return math.max(wholeCount, 0)
end

-- ============================================================================
-- GUARD MORALE HELPERS
-- ============================================================================

--- Check if an archetype is immune to morale
---@param archetypeId string
---@return boolean
local function isMoraleImmune(archetypeId)
    if not Config.GuardMorale or not Config.GuardMorale.enabled then return true end
    if not Config.GuardMorale.immuneArchetypes then return false end

    for _, id in ipairs(Config.GuardMorale.immuneArchetypes) do
        if id == archetypeId then return true end
    end
    return false
end

--- Count alive and dead guards in a zone
---@param zoneId string
---@return integer alive, integer dead
local function countGuards(zoneId)
    local alive, dead = 0, 0
    for _, data in pairs(secGuards) do
        if data.zoneId == zoneId then
            if data.alive then
                alive = alive + 1
            else
                dead = dead + 1
            end
        end
    end
    return alive, dead
end

--- Update morale for a single guard based on zone events
---@param ped integer
---@param data GuardData
---@param zoneId string
local function updateGuardMorale(ped, data, zoneId)
    if not Config.GuardMorale or not Config.GuardMorale.enabled then return end
    if isMoraleImmune(data.archetypeId) then return end
    if not data.alive or not DoesEntityExist(ped) then return end

    local cfg = Config.GuardMorale
    local _, deadCount = countGuards(zoneId)

    -- Dead colleague penalty
    local targetMorale = cfg.base - (deadCount * cfg.deadColleaguePenalty)

    -- Gunshot penalty: if player is shooting nearby
    if IsPedShooting(cache.ped) then
        local dist = #(GetEntityCoords(cache.ped) - GetEntityCoords(ped))
        if dist < 50.0 then
            data.morale = data.morale - cfg.gunshotPenalty * 0.1 -- applied per tick
        end
    end

    -- Wounded penalty: if guard has taken damage
    local maxHp = GetEntityMaxHealth(ped)
    local curHp = GetEntityHealth(ped)
    if maxHp > 0 and curHp < maxHp * 0.7 then
        targetMorale = targetMorale - cfg.woundedPenalty
    end

    -- Player hit boost: if guard damaged the player
    if HasEntityBeenDamagedByEntity(cache.ped, ped, true) then
        targetMorale = targetMorale + cfg.playerHitBoost
    end

    -- Lerp morale toward target
    targetMorale = math.max(0, math.min(cfg.base, targetMorale))
    data.morale = data.morale + (targetMorale - data.morale) * 0.1

    -- Apply morale effects
    if data.morale <= cfg.fleeThreshold and not data.fleeing then
        data.fleeing = true
        ClearPedTasks(ped)
        TaskSmartFleePed(ped, cache.ped, 200.0, -1, false, false)
        SetPedKeepTask(ped, true)
        lib.print.info(('Guard %d fleeing (morale %.0f)'):format(ped, data.morale))
    elseif data.morale <= cfg.retreatThreshold and not data.fleeing then
        -- Retreat to nearest post position
        local nearestPost = nil
        local nearestDist = math.huge
        local pedCoords = GetEntityCoords(ped)

        -- Find the zone config to get post positions
        for _, zoneCfg in ipairs(Config.SecurityZones) do
            if zoneCfg.id == zoneId and zoneCfg.posts then
                for _, post in ipairs(zoneCfg.posts) do
                    local d = #(pedCoords - vec3(post.coords.x, post.coords.y, post.coords.z))
                    if d < nearestDist then
                        nearestDist = d
                        nearestPost = post
                    end
                end
                break
            end
        end

        if nearestPost and not data.wounded then
            data.wounded = true
            ClearPedTasks(ped)
            TaskGoStraightToCoord(ped, nearestPost.coords.x, nearestPost.coords.y, nearestPost.coords.z,
                2.0, -1, nearestPost.coords.w, 1.0)
            SetPedKeepTask(ped, true)
            lib.print.info(('Guard %d retreating to post (morale %.0f)'):format(ped, data.morale))
        end
    end
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
    SetPedRelationshipGroupHash(ped, `SECURITY_GUARD`)
end

---@param post table
---@param zoneId string
---@param zoneConfig table
---@param archetypeOverrideFromShift? string
---@return integer?
local function spawnPostGuard(post, zoneId, zoneConfig, archetypeOverrideFromShift)
    local archetypeId = post.archetypeOverride or archetypeOverrideFromShift or zoneConfig.defaultArchetype
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
        postConfig = post,
        suspicion = 0,
        alerted = false,
        alive = true,
        morale = Config.GuardMorale and Config.GuardMorale.base or 100,
        wounded = false,
        fleeing = false,
    }

    return ped
end

---@param patrol table
---@param zoneId string
---@param zoneConfig table
---@param archetypeOverrideFromShift? string
---@return integer?
local function spawnPatrolGuard(patrol, zoneId, zoneConfig, archetypeOverrideFromShift)
    if #patrol.waypoints < 2 then return nil end

    local archetypeId = patrol.archetypeOverride or archetypeOverrideFromShift or zoneConfig.defaultArchetype
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
        morale = Config.GuardMorale and Config.GuardMorale.base or 100,
        wounded = false,
        fleeing = false,
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

            -- Check if fleeing/retreating due to morale
            local guardData = secGuards[ped]
            if guardData and (guardData.fleeing or guardData.wounded) then
                Wait(1000)
                goto continue
            end

            local wp = patrol.waypoints[idx]
            ClearPedTasks(ped)
            TaskGoStraightToCoord(ped, wp.x, wp.y, wp.z, patrol.speed, -1, wp.w, 0.5)
            SetPedKeepTask(ped, true)

            -- Wait until arrival, zone state change, or timeout (30s)
            local wpDeadline = GetGameTimer() + 30000
            repeat
                Wait(1000)
                if not DoesEntityExist(ped) or not secZoneActive[zoneId] then return end
                if getAlertLevel(zoneId) == 'combat' or getAlertLevel(zoneId) == 'alert' then goto continue end
            until #(GetEntityCoords(ped) - vec3(wp.x, wp.y, wp.z)) < 2.0 or GetGameTimer() > wpDeadline

            -- Routine steps at waypoint
            if patrol.routineSteps and #patrol.routineSteps > 0 and math.random() < 0.4 then
                local step = PickRandom(patrol.routineSteps)
                if step.coords then
                    TaskGoStraightToCoord(ped, step.coords.x, step.coords.y, step.coords.z, 1.0, -1, step.coords.w, 0.5)
                    local stepDeadline = GetGameTimer() + 15000
                    repeat Wait(500) until not DoesEntityExist(ped) or not secZoneActive[zoneId]
                        or #(GetEntityCoords(ped) - vec3(step.coords.x, step.coords.y, step.coords.z)) < 2.0
                        or GetGameTimer() > stepDeadline
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

        -- Use GetSafeCoordForPed for a walkable position, fall back to collision probe
        local safeFound, safeX, safeY, safeZ = GetSafeCoordForPed(x, y, z, true, 16)
        if safeFound then
            x, y, z = safeX, safeY, safeZ
        else
            RequestCollisionAtCoord(x, y, z)
            Wait(200)
            local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 100.0, false)
            if found then z = groundZ end
        end

        local modelHash = PickRandom(archetype.pedModels)
        local ped = SpawnScenarioPed(modelHash, vec3(x, y, z), 0.0, 0)
        if ped then
            configureGuard(ped, archetype, zoneConfig)

            -- Immediately hostile
            local hostileGroup = `SECURITY_GUARD`
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
                morale = Config.GuardMorale and Config.GuardMorale.base or 100,
                wounded = false,
                fleeing = false,
            }
        end
    end

    lib.notify({
        title = 'Security',
        description = 'Reinforcements have arrived!',
        type = 'error', duration = 3000,
    })
end

--- Spawn a continuous reinforcement wave (after all defined waves are used)
---@param cfg table -- reinforcements config
---@param zoneId string
---@param zoneConfig table
local function spawnContinuousWave(cfg, zoneId, zoneConfig)
    local waveData = {
        archetypeId = cfg.continuousArchetype or 'pmc',
        count = cfg.continuousCount or 3,
        spawnRadius = cfg.continuousSpawnRadius or 50.0,
    }
    spawnReinforcementWave(waveData, zoneId, zoneConfig)
end

-- ============================================================================
-- GUARD BEHAVIOR PER ALERT LEVEL
-- ============================================================================

--- Get alive guards in a zone sorted by distance from a position
---@param zoneId string
---@param pos vector3
---@return table[] -- array of { ped, data, dist }
local function getAliveGuardsByDistance(zoneId, pos)
    local guards = {}
    for ped, data in pairs(secGuards) do
        if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) and not data.fleeing then
            local dist = #(pos - GetEntityCoords(ped))
            guards[#guards + 1] = { ped = ped, data = data, dist = dist }
        end
    end
    table.sort(guards, function(a, b) return a.dist < b.dist end)
    return guards
end

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

        -- Skip guards that are fleeing due to morale
        if data.fleeing then goto continue end

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
                local hostileGroup = `SECURITY_GUARD`
                SetRelationshipBetweenGroups(5, hostileGroup, `PLAYER`)
                SetRelationshipBetweenGroups(5, `PLAYER`, hostileGroup)
                SetPedRelationshipGroupHash(ped, hostileGroup)

                local archetype = getArchetype(data.archetypeId)
                local tactics = archetype and archetype.tactics or {}

                -- Tactical behaviors
                if tactics.suppressiveFire then
                    -- Set combat attribute for suppressive fire (BF_CanFightArmedPedsWhenNotArmed)
                    SetPedCombatAttributes(ped, 2, true)
                    SetPedFiringPattern(ped, `FIRING_PATTERN_FULL_AUTO`)
                end

                if tactics.useCover then
                    -- Use cover-based combat: go to combat area with tactical awareness
                    local playerCoords = GetEntityCoords(cache.ped)
                    SetPedCombatAttributes(ped, 1, true) -- BF_CanUseCover
                    TaskGoToCoordAnyMeans(ped, playerCoords.x, playerCoords.y, playerCoords.z, 2.0, 0, false, 786603, 0.0)
                    SetTimeout(1500, function()
                        if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                            TaskCombatPed(ped, cache.ped, 0, 16)
                            SetPedKeepTask(ped, true)
                        end
                    end)
                else
                    TaskCombatPed(ped, cache.ped, 0, 16)
                    SetPedKeepTask(ped, true)
                end

                -- Retreat threshold from tactics
                if tactics.retreatThreshold then
                    SetPedFleeAttributes(ped, 2, true)
                end

                -- Check for flee behavior from archetype
                if archetype and archetype.fleeHealthThreshold then
                    SetPedFleeAttributes(ped, 2, true)
                end
            end
        end

        ::continue::
    end

    -- Flanking behavior: when in combat with 2+ alive guards, pick furthest to flank
    if level == 'combat' and state and state.lastKnownPlayerPos then
        local playerCoords = GetEntityCoords(cache.ped)
        local aliveGuards = getAliveGuardsByDistance(zoneId, playerCoords)

        if #aliveGuards >= 2 then
            -- The furthest guard attempts to flank
            local flanker = aliveGuards[#aliveGuards]
            local flankerArchetype = getArchetype(flanker.data.archetypeId)
            local flankerTactics = flankerArchetype and flankerArchetype.tactics or {}

            if flankerTactics.flanking and not flanker.data.fleeing then
                -- Calculate a flanking position: perpendicular to approach vector
                local guardPos = GetEntityCoords(flanker.ped)
                local toPlayer = playerCoords - guardPos
                local perpX = -toPlayer.y
                local perpY = toPlayer.x
                local perpLen = math.sqrt(perpX * perpX + perpY * perpY)
                if perpLen > 0.01 then
                    perpX = perpX / perpLen
                    perpY = perpY / perpLen
                end

                local flankDist = 15.0
                local side = math.random() > 0.5 and 1 or -1
                local flankX = playerCoords.x + perpX * flankDist * side
                local flankY = playerCoords.y + perpY * flankDist * side
                local flankZ = playerCoords.z

                ClearPedTasks(flanker.ped)
                TaskGoToCoordAnyMeans(flanker.ped, flankX, flankY, flankZ, 3.0, 0, false, 786603, 0.0)
                SetPedKeepTask(flanker.ped, true)

                -- After reaching flank position, engage
                SetTimeout(4000, function()
                    if DoesEntityExist(flanker.ped) and not IsPedDeadOrDying(flanker.ped, true) then
                        TaskCombatPed(flanker.ped, cache.ped, 0, 16)
                        SetPedKeepTask(flanker.ped, true)
                    end
                end)
            end
        end
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
-- OBJECTIVE INTERACTION (Multi-Step)
-- ============================================================================

--- Normalize an objective definition: if no `steps` field exists, wrap the
--- objective itself as a single step (backward compat).
---@param objDef table
---@return table[] steps
local function getObjectiveSteps(objDef)
    if objDef.steps and #objDef.steps > 0 then
        return objDef.steps
    end

    -- Backward compat: wrap the objective as a single step
    return {
        {
            id = objDef.id .. '_auto',
            label = objDef.label,
            icon = objDef.icon or 'fas fa-crosshairs',
            equipmentTier = objDef.equipmentTier,
            maxAlertLevel = objDef.maxAlertLevel,
            interactDurationMs = objDef.interactDurationMs,
            animDict = objDef.animDict,
            animName = objDef.animName,
            noiseRadius = objDef.noiseRadius or 0,
            onSuccess = objDef.onSuccess,
            onFail = objDef.onFail,
            lootTable = objDef.lootTable,
        },
    }
end

--- Spawn objective props and register ox_target interactions (multi-step)
---@param zoneId string
---@param zoneConfig table
local function initObjectives(zoneId, zoneConfig)
    if not zoneConfig.objectives or #zoneConfig.objectives == 0 then return end

    zoneObjectiveProps[zoneId] = {}
    zoneTargetZones[zoneId] = {}
    objectiveOpenStates[zoneId] = objectiveOpenStates[zoneId] or {}

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

        -- Get steps (with backward compat wrapping)
        local steps = getObjectiveSteps(obj)

        -- Register ox_target zone for this objective with per-step options
        if GetResourceState('ox_target') == 'started' then
            local options = {}

            for _, step in ipairs(steps) do
                options[#options + 1] = {
                    name = 'seczone_obj_' .. obj.id .. '_step_' .. step.id,
                    icon = step.icon or 'fas fa-crosshairs',
                    label = step.label,
                    distance = 2.0,
                    canInteract = function()
                        -- Check if step already completed
                        if objectiveOpenStates[zoneId] and objectiveOpenStates[zoneId][step.id] then
                            return false
                        end
                        -- Check alert level
                        if step.maxAlertLevel then
                            local current = getAlertLevel(zoneId)
                            if alertOrder(current) > alertOrder(step.maxAlertLevel) then
                                return false
                            end
                        end
                        return true
                    end,
                    onSelect = function()
                        interactWithObjective(zoneId, obj, step, zoneConfig)
                    end,
                }
            end

            local targetId = exports.ox_target:addSphereZone({
                coords = vec3(obj.coords.x, obj.coords.y, obj.coords.z),
                radius = 1.2,
                debug = Config.Debug,
                options = options,
            })
            if targetId then
                zoneTargetZones[zoneId][#zoneTargetZones[zoneId] + 1] = targetId
            end
        end
    end
end

--- Handle objective step interaction: check, animate, reward, noise
---@param zoneId string
---@param objDef table -- the parent objective definition
---@param stepDef table -- the specific step to interact with
---@param zoneConfig table -- the zone configuration
interactWithObjective = function(zoneId, objDef, stepDef, zoneConfig)
    -- Check cooldown first (on parent objective)
    if objDef.cooldownMs then
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
    end

    -- Check alert level for this step
    if stepDef.maxAlertLevel then
        local current = getAlertLevel(zoneId)
        if alertOrder(current) > alertOrder(stepDef.maxAlertLevel) then
            lib.notify({
                title = 'Too Dangerous',
                description = 'Can\'t do this while guards are on high alert!',
                type = 'error',
            })
            return
        end
    end

    -- Request equipment tier info from server
    local currentAlert = getAlertLevel(zoneId)
    local tierResult = lib.callback.await('qbx_pedscenarios:server:attemptObjectiveStep', false,
        zoneId, objDef.id, stepDef.id, currentAlert)

    if not tierResult then
        lib.notify({ title = stepDef.label, description = 'Failed — missing required equipment.', type = 'error' })
        -- Apply onFail escalation
        if stepDef.onFail and stepDef.onFail.escalation then
            local newLevel = stepDef.onFail.escalation
            if alertOrder(newLevel) > alertOrder(getAlertLevel(zoneId)) then
                setAlertLevel(zoneId, newLevel, GetEntityCoords(cache.ped))
                applyAlertBehavior(zoneId, zoneConfig)
            end
        end
        return
    end

    -- Handle server error responses
    if tierResult.error then
        if tierResult.error == 'cooldown' then
            local mins = math.ceil((tierResult.remainingMs or 0) / 60000)
            lib.notify({
                title = 'Locked',
                description = ('On cooldown. ~%d min remaining.'):format(mins),
                type = 'error',
            })
            return
        end

        if tierResult.error == 'missing_equipment' or tierResult.error == 'missing_item' then
            lib.notify({
                title = stepDef.label,
                description = ('You need equipment: %s'):format(tierResult.equipmentTier or stepDef.equipmentTier or 'unknown'),
                type = 'error',
            })
            return
        end

        if tierResult.error == 'inventory_full' then
            lib.notify({
                title = stepDef.label,
                description = 'Your inventory is full.',
                type = 'error',
            })
            return
        end

        if tierResult.error == 'alert_too_high' then
            lib.notify({
                title = 'Too Dangerous',
                description = 'Can\'t do this while guards are on high alert!',
                type = 'error',
            })
            return
        end

        -- Generic error
        lib.notify({ title = stepDef.label, description = tierResult.error, type = 'error' })
        return
    end

    -- Apply equipment tier duration modifier
    local equip = tierResult.equipment
    local durationMult = (equip and equip.durationMult) or 1.0
    local toolUsed = equip and equip.label
    local noiseRadiusOverride = equip and equip.noiseRadiusOverride
    local effectiveDuration = math.floor(stepDef.interactDurationMs * durationMult)
    local effectiveNoiseRadius = noiseRadiusOverride or stepDef.noiseRadius or 0

    -- Load animation if specified
    local animLoaded = false
    if stepDef.animDict then
        lib.requestAnimDict(stepDef.animDict)
        TaskPlayAnim(cache.ped, stepDef.animDict, stepDef.animName, 8.0, -8.0, -1, 1, 0, false, false, false)
        animLoaded = true
    end

    -- Set up cleanup for interrupts (death, ragdoll, taser)
    local cleanupDone = false
    local function doCleanup()
        if cleanupDone then return end
        cleanupDone = true
        activeInteractionCleanup = nil

        ClearPedTasks(cache.ped)
        if stepDef.animDict then
            RemoveAnimDict(stepDef.animDict)
        end
    end
    activeInteractionCleanup = doCleanup

    -- Monitor for death/ragdoll/taser during interaction
    local interactionAborted = false
    local monitorThread = CreateThread(function()
        while not cleanupDone do
            Wait(100)
            if IsPedDeadOrDying(cache.ped, true) or IsPedRagdoll(cache.ped) or IsPedBeingStunned(cache.ped, 0) then
                interactionAborted = true
                doCleanup()
                -- Cancel progress bar by clearing tasks (ox_lib should detect this)
                return
            end
        end
    end)

    -- Progress bar
    local completed = lib.progressBar({
        duration = effectiveDuration,
        label = stepDef.label .. (toolUsed and (' [' .. toolUsed .. ']') or '') .. '...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
    })

    -- Cleanup animation regardless of outcome
    doCleanup()

    if interactionAborted then
        lib.notify({ title = stepDef.label, description = 'Interrupted!', type = 'error' })
        -- Apply onFail escalation
        if stepDef.onFail and stepDef.onFail.escalation then
            local newLevel = stepDef.onFail.escalation
            if alertOrder(newLevel) > alertOrder(getAlertLevel(zoneId)) then
                setAlertLevel(zoneId, newLevel, GetEntityCoords(cache.ped))
                applyAlertBehavior(zoneId, zoneConfig)
            end
        end
        return
    end

    if not completed then
        lib.notify({ title = stepDef.label, description = 'Cancelled.', type = 'error' })
        -- Apply onFail escalation
        if stepDef.onFail and stepDef.onFail.escalation then
            local newLevel = stepDef.onFail.escalation
            if alertOrder(newLevel) > alertOrder(getAlertLevel(zoneId)) then
                setAlertLevel(zoneId, newLevel, GetEntityCoords(cache.ped))
                applyAlertBehavior(zoneId, zoneConfig)
            end
        end
        return
    end

    -- Generate noise event at objective coords
    local objCoords = vec3(objDef.coords.x, objDef.coords.y, objDef.coords.z)
    generateNoiseEvent(zoneId, objCoords, effectiveNoiseRadius)

    -- Apply onSuccess effects
    if stepDef.onSuccess then
        -- Escalation
        if stepDef.onSuccess.escalation then
            local newLevel = stepDef.onSuccess.escalation
            if alertOrder(newLevel) > alertOrder(getAlertLevel(zoneId)) then
                setAlertLevel(zoneId, newLevel, GetEntityCoords(cache.ped))
                applyAlertBehavior(zoneId, zoneConfig)
            end
        end

        -- Zone effects (temporary modifiers)
        if stepDef.onSuccess.zoneEffect then
            activeZoneEffects[zoneId] = activeZoneEffects[zoneId] or {}
            for key, value in pairs(stepDef.onSuccess.zoneEffect) do
                activeZoneEffects[zoneId][key] = value
            end
            lib.print.info(('Applied zone effect for "%s": %s'):format(zoneId, json.encode(stepDef.onSuccess.zoneEffect)))
        end
    end

    -- Mark step as completed for state persistence
    objectiveOpenStates[zoneId] = objectiveOpenStates[zoneId] or {}
    objectiveOpenStates[zoneId][stepDef.id] = true

    -- Handle loot (if step has loot table, use the server result)
    if tierResult.result == 'success' then
        local lootDesc = ''
        if tierResult.loot and #tierResult.loot > 0 then
            local parts = {}
            for _, l in ipairs(tierResult.loot) do
                parts[#parts + 1] = ('%dx %s'):format(l.quantity, l.item)
            end
            lootDesc = table.concat(parts, ', ')
        else
            lootDesc = 'Done'
        end

        lib.notify({
            title = stepDef.label,
            description = ('Success! %s'):format(lootDesc),
            type = 'success', duration = 5000,
        })

        -- Notify about dropped overflow
        if tierResult.droppedLoot and #tierResult.droppedLoot > 0 then
            local dropParts = {}
            for _, l in ipairs(tierResult.droppedLoot) do
                dropParts[#dropParts + 1] = ('%dx %s'):format(l.quantity, l.item)
            end
            lib.notify({
                title = 'Inventory Full',
                description = ('Dropped on ground: %s'):format(table.concat(dropParts, ', ')),
                type = 'warning', duration = 5000,
            })
        end
    elseif tierResult.result == 'no_loot' or not tierResult.result then
        -- Step completed but no loot (e.g. camera disable)
        lib.notify({
            title = stepDef.label,
            description = 'Done.',
            type = 'success', duration = 3000,
        })
    end
end

--- Cleanup objective props and ox_target zones
---@param zoneId string
local function cleanupObjectives(zoneId)
    -- Remove ox_target sphere zones
    if zoneTargetZones[zoneId] and GetResourceState('ox_target') == 'started' then
        for _, targetId in ipairs(zoneTargetZones[zoneId]) do
            exports.ox_target:removeZone(targetId)
        end
        zoneTargetZones[zoneId] = nil
    end

    -- Remove objective props
    if zoneObjectiveProps[zoneId] then
        for _, prop in ipairs(zoneObjectiveProps[zoneId]) do
            if DoesEntityExist(prop) then DeleteObject(prop) end
        end
        zoneObjectiveProps[zoneId] = nil
    end
end

-- ============================================================================
-- DEBUG VISUALIZATION
-- ============================================================================

--- Draw a detection cone from a guard's position/facing
---@param ped integer
---@param range number
---@param r integer
---@param g integer
---@param b integer
---@param a integer
local function drawDetectionCone(ped, range, r, g, b, a)
    local pedCoords = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local coneLen = Config.DebugVisualization.coneLength or 10.0
    local actualLen = math.min(range, coneLen)

    -- Draw center line
    local endPoint = pedCoords + fwd * actualLen
    DrawLine(pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        endPoint.x, endPoint.y, endPoint.z + 0.5,
        r, g, b, a)

    -- Draw cone edges (left and right at FOV boundary)
    local fovDot = Config.Stealth.guardFovDot or -0.2
    local halfAngle = math.acos(math.max(-1, math.min(1, fovDot)))
    local cosA = math.cos(halfAngle)
    local sinA = math.sin(halfAngle)

    -- Left edge
    local leftX = fwd.x * cosA - fwd.y * sinA
    local leftY = fwd.x * sinA + fwd.y * cosA
    local leftEnd = pedCoords + vec3(leftX, leftY, fwd.z) * actualLen
    DrawLine(pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        leftEnd.x, leftEnd.y, leftEnd.z + 0.5,
        r, g, b, a)

    -- Right edge
    local rightX = fwd.x * cosA + fwd.y * sinA
    local rightY = -fwd.x * sinA + fwd.y * cosA
    local rightEnd = pedCoords + vec3(rightX, rightY, fwd.z) * actualLen
    DrawLine(pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        rightEnd.x, rightEnd.y, rightEnd.z + 0.5,
        r, g, b, a)
end

--- Draw a suspicion bar above a guard's head
---@param ped integer
---@param suspicion number -- 0 to ~100
local function drawSuspicionBar(ped, suspicion)
    local pedCoords = GetEntityCoords(ped)
    local aboveHead = pedCoords + vec3(0, 0, 1.2)
    local fraction = math.min(suspicion / (Config.Stealth.suspicionThreshold or 100.0), 1.0)

    -- Color gradient: green → yellow → red
    local r = math.floor(255 * math.min(fraction * 2, 1.0))
    local g = math.floor(255 * math.min((1.0 - fraction) * 2, 1.0))

    SetDrawOrigin(aboveHead.x, aboveHead.y, aboveHead.z, 0)

    -- Background bar
    DrawRect(0.0, 0.0, 0.04, 0.006, 0, 0, 0, 120)
    -- Filled portion
    local barWidth = 0.038 * fraction
    local barOffset = -0.019 + barWidth / 2
    if barWidth > 0.001 then
        DrawRect(barOffset, 0.0, barWidth, 0.004, r, g, 0, 200)
    end

    EndScriptGfx2dCommands()
end

--- Draw morale indicator above a guard's head
---@param ped integer
---@param morale number
local function drawMoraleIndicator(ped, morale)
    local pedCoords = GetEntityCoords(ped)
    local aboveHead = pedCoords + vec3(0, 0, 1.5)
    local cfg = Config.GuardMorale

    -- Color: green at full, yellow at retreat threshold, red at flee threshold
    local r, g, b = 0, 255, 0
    if morale <= (cfg.fleeThreshold or 30) then
        r, g, b = 255, 0, 0
    elseif morale <= (cfg.retreatThreshold or 50) then
        r, g, b = 255, 165, 0
    elseif morale <= 70 then
        r, g, b = 255, 255, 0
    end

    -- Draw as a small marker
    DrawMarker(2, aboveHead.x, aboveHead.y, aboveHead.z, 0, 0, 0, 0, 0, 0,
        0.15, 0.15, 0.15, r, g, b, 200, false, false, 2, false, nil, nil, false)
end

--- Draw patrol waypoints as numbered markers
---@param zoneConfig table
local function drawPatrolWaypoints(zoneConfig)
    if not zoneConfig.patrols then return end

    for _, patrol in ipairs(zoneConfig.patrols) do
        for idx, wp in ipairs(patrol.waypoints) do
            DrawMarker(1, wp.x, wp.y, wp.z - 0.95, 0, 0, 0, 0, 0, 0,
                0.5, 0.5, 0.5, 0, 150, 255, 100, false, false, 2, false, nil, nil, false)

            -- Number above waypoint
            SetDrawOrigin(wp.x, wp.y, wp.z + 0.5, 0)
            DrawRect(0.0, 0.0, 0.012, 0.018, 0, 0, 0, 150)
            EndScriptGfx2dCommands()
        end
    end
end

--- Draw objective state markers
---@param zoneId string
---@param zoneConfig table
local function drawObjectiveStates(zoneId, zoneConfig)
    if not zoneConfig.objectives then return end

    for _, obj in ipairs(zoneConfig.objectives) do
        local objPos = vec3(obj.coords.x, obj.coords.y, obj.coords.z)
        local steps = getObjectiveSteps(obj)

        for _, step in ipairs(steps) do
            local isOpen = objectiveOpenStates[zoneId] and objectiveOpenStates[zoneId][step.id]
            local r, g, b = 255, 0, 0 -- red = locked
            if isOpen then
                r, g, b = 0, 255, 0 -- green = open
            end

            DrawMarker(28, objPos.x, objPos.y, objPos.z + 1.5, 0, 0, 0, 0, 0, 0,
                0.3, 0.3, 0.3, r, g, b, 150, true, false, 2, false, nil, nil, false)
        end
    end
end

--- Main debug visualization thread for a zone
---@param zoneId string
---@param zoneConfig table
local function startDebugVisualization(zoneId, zoneConfig)
    if not Config.Debug or not Config.DebugVisualization then return end
    local dbg = Config.DebugVisualization

    CreateThread(function()
        while secZoneActive[zoneId] do
            Wait(0) -- Runs every frame for drawing

            local level = getAlertLevel(zoneId)

            for ped, data in pairs(secGuards) do
                if data.zoneId ~= zoneId or not data.alive or not DoesEntityExist(ped) then
                    goto nextDebugGuard
                end

                local effectiveRange = calculateDetectionRange(ped, zoneConfig.detectionRadius, zoneId)

                -- Detection cones
                if dbg.drawDetectionCones then
                    local r, g, b = 0, 255, 0
                    if level == 'suspicious' then
                        r, g, b = 255, 255, 0
                    elseif level == 'alert' then
                        r, g, b = 255, 165, 0
                    elseif level == 'combat' then
                        r, g, b = 255, 0, 0
                    end
                    drawDetectionCone(ped, effectiveRange, r, g, b, dbg.coneAlpha or 80)
                end

                -- Suspicion bars
                if dbg.drawSuspicionBars then
                    drawSuspicionBar(ped, data.suspicion)
                end

                -- Morale indicators
                if dbg.drawMoraleIndicators and Config.GuardMorale and Config.GuardMorale.enabled then
                    if not isMoraleImmune(data.archetypeId) then
                        drawMoraleIndicator(ped, data.morale)
                    end
                end

                ::nextDebugGuard::
            end

            -- Patrol waypoints
            if dbg.drawPatrolWaypoints then
                drawPatrolWaypoints(zoneConfig)
            end

            -- Objective states
            if dbg.drawObjectiveStates then
                drawObjectiveStates(zoneId, zoneConfig)
            end
        end
    end)
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
    local disguiseSuspicious = false
    local disguiseSuspMult = 0

    if hasAccess then
        if accessType == 'disguise' then
            local ds = Config.Stealth.disguiseSuspicion
            if ds then
                if IsPedArmed(cache.ped, 4) then
                    disguiseSuspicious = true
                    disguiseSuspMult = ds.weaponDrawnMult
                elseif IsPedSprinting(cache.ped) then
                    disguiseSuspicious = true
                    disguiseSuspMult = ds.sprintMult
                elseif GetPedStealthMovement(cache.ped) then
                    disguiseSuspicious = true
                    disguiseSuspMult = ds.crouchMult
                end
            end
        end

        if not disguiseSuspicious then
            state.suspicionPool = math.max(state.suspicionPool - Config.Stealth.suspicionDecayRate * 2, 0)
            return
        end
    end

    -- Check for noise events (instant escalation — ignores disguise)
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

    -- Body discovery: alive guards discover dead bodies via LOS + facing
    for deadPed, deadData in pairs(secGuards) do
        if deadData.zoneId == zoneId and not deadData.alive and deadData.deathPos and not deadData.bodyDiscovered then
            for alivePed, aliveData in pairs(secGuards) do
                if aliveData.zoneId == zoneId and aliveData.alive and DoesEntityExist(alivePed) then
                    local dist = #(deadData.deathPos - GetEntityCoords(alivePed))
                    if dist < zoneConfig.detectionRadius
                        and isPedFacingPosition(alivePed, deadData.deathPos)
                        and HasEntityClearLosToEntity(alivePed, deadPed, 17) then
                        deadData.bodyDiscovered = true
                        -- Guards investigate the BODY location, not the player
                        if alertOrder(level) < alertOrder('alert') then
                            setAlertLevel(zoneId, 'alert', deadData.deathPos)
                            applyAlertBehavior(zoneId, zoneConfig)
                        end
                        break
                    end
                end
            end
        end
    end

    -- Guard discovery of opened objectives
    if objectiveOpenStates[zoneId] and zoneConfig.objectives then
        for _, obj in ipairs(zoneConfig.objectives) do
            local steps = getObjectiveSteps(obj)
            for _, step in ipairs(steps) do
                if objectiveOpenStates[zoneId][step.id] then
                    local objPos = vec3(obj.coords.x, obj.coords.y, obj.coords.z)
                    for alivePed, aliveData in pairs(secGuards) do
                        if aliveData.zoneId == zoneId and aliveData.alive and DoesEntityExist(alivePed) then
                            local dist = #(objPos - GetEntityCoords(alivePed))
                            if dist < zoneConfig.detectionRadius
                                and isPedFacingPosition(alivePed, objPos)
                                and HasEntityClearLosToCoord(alivePed, objPos.x, objPos.y, objPos.z, 17) then
                                -- Guard discovered the opened objective — server callback to re-lock and escalate
                                objectiveOpenStates[zoneId][step.id] = nil
                                lib.callback.await('qbx_pedscenarios:server:guardDiscoveredStep', false,
                                    zoneId, obj.id, step.id)
                                if alertOrder(level) < alertOrder('alert') then
                                    setAlertLevel(zoneId, 'alert', objPos)
                                    applyAlertBehavior(zoneId, zoneConfig)
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Guard-by-guard detection
    local anyDetected = false
    local thresholdMult = zoneConfig.alertOverrides and zoneConfig.alertOverrides.suspicionThresholdMult or 1.0
    local effectiveThreshold = Config.Stealth.suspicionThreshold * thresholdMult

    for ped, data in pairs(secGuards) do
        if data.zoneId ~= zoneId or not data.alive or not DoesEntityExist(ped) then
            -- Mark dead guards (don't escalate — body discovery handles that)
            if data.alive and DoesEntityExist(ped) and IsPedDeadOrDying(ped, true) then
                data.alive = false
                data.deathPos = GetEntityCoords(ped)

                -- Track dead post guards for respawn
                if data.role == 'post' and data.postConfig then
                    deadPostGuards[zoneId] = deadPostGuards[zoneId] or {}
                    deadPostGuards[zoneId][#deadPostGuards[zoneId] + 1] = {
                        post = data.postConfig,
                        archetypeId = data.archetypeId,
                        diedAt = GetGameTimer(),
                    }
                end
            end
            goto nextGuard
        end

        -- Update morale
        if Config.GuardMorale and Config.GuardMorale.enabled then
            updateGuardMorale(ped, data, zoneId)
        end

        -- Tactical retreat threshold check (from archetype tactics)
        local archetype = getArchetype(data.archetypeId)
        if archetype and archetype.tactics and archetype.tactics.retreatThreshold then
            local maxHp = GetEntityMaxHealth(ped)
            local curHp = GetEntityHealth(ped)
            if maxHp > 0 and (curHp / maxHp) < archetype.tactics.retreatThreshold then
                if not data.fleeing then
                    data.fleeing = true
                    ClearPedTasks(ped)
                    TaskSmartFleePed(ped, cache.ped, 100.0, -1, false, false)
                    SetPedKeepTask(ped, true)
                end
                goto nextGuard
            end
        end

        -- Skip guards that are fleeing
        if data.fleeing then goto nextGuard end

        do
            local pedCoords = GetEntityCoords(ped)
            local dist = #(playerCoords - pedCoords)
            local effectiveRange = calculateDetectionRange(ped, zoneConfig.detectionRadius, zoneId)

            -- Disguised players only detected at closer range
            if disguiseSuspicious then
                local ds = Config.Stealth.disguiseSuspicion
                effectiveRange = effectiveRange * (ds and ds.rangeFraction or 0.5)
            end

            if dist < effectiveRange then
                local hasLOS = HasEntityClearLosToEntity(ped, cache.ped, 17)
                local isFacing = isPedFacingPosition(ped, playerCoords)

                if hasLOS and isFacing then
                    anyDetected = true
                    state.lastKnownPlayerPos = playerCoords

                    -- Build suspicion (modified by disguise)
                    if disguiseSuspicious then
                        local ds = Config.Stealth.disguiseSuspicion
                        local rate = Config.Stealth.suspicionBuildRate * (ds and ds.buildRateFraction or 0.2) * disguiseSuspMult
                        data.suspicion = data.suspicion + rate
                    else
                        data.suspicion = data.suspicion + Config.Stealth.suspicionBuildRate
                    end

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
                elseif hasLOS and not isFacing then
                    -- Guard has LOS but isn't looking: very slow suspicion (peripheral awareness)
                    data.suspicion = data.suspicion + Config.Stealth.suspicionBuildRate * 0.1
                else
                    -- No LOS: behind-cover logic
                    if dist < effectiveRange * Config.Stealth.behindCoverModifier then
                        data.suspicion = data.suspicion + Config.Stealth.suspicionBuildRate * 0.3
                    else
                        data.suspicion = math.max(data.suspicion - Config.Stealth.suspicionDecayRate, 0)
                    end
                end
            else
                data.suspicion = math.max(data.suspicion - Config.Stealth.suspicionDecayRate, 0)
            end
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
            -- Carry forward fraction of suspicion instead of full reset
            local carry = Config.Stealth.suspicionCarryForward or 0.3
            state.suspicionPool = state.suspicionPool * carry
            for _, data in pairs(secGuards) do
                if data.zoneId == zoneId then data.suspicion = data.suspicion * carry end
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

    -- Post guard respawn: check if dead post guards should respawn
    if level == 'patrol' and Config.GuardRespawn and Config.GuardRespawn.enabled and deadPostGuards[zoneId] then
        local respawnDelay = Config.GuardRespawn.delayMs or 1800000
        local now = GetGameTimer()
        local toRemove = {}
        for i, dead in ipairs(deadPostGuards[zoneId]) do
            if now - dead.diedAt >= respawnDelay then
                spawnPostGuard(dead.post, zoneId, zoneConfig)
                toRemove[#toRemove + 1] = i
                lib.print.info(('Respawned post guard at zone "%s"'):format(zoneId))
            end
        end
        for j = #toRemove, 1, -1 do
            table.remove(deadPostGuards[zoneId], toRemove[j])
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

            -- Apply reinforcement delay from zone effects (e.g. jammed comms)
            local effectiveDelay = 0
            local effects = activeZoneEffects[zoneId]
            if effects and effects.reinforcementDelay then
                effectiveDelay = effects.reinforcementDelay
            end

            -- Defined waves
            if currentWave < cfg.maxWaves and currentWave < #cfg.waves then
                local nextWave = cfg.waves[currentWave + 1]
                local delayWithEffect = nextWave.delayMs + effectiveDelay
                if elapsed >= delayWithEffect then
                    reinforcementWave[zoneId] = currentWave + 1
                    spawnReinforcementWave(nextWave, zoneId, zoneConfig)
                    lib.print.info(('Zone "%s" reinforcement wave %d/%d'):format(
                        zoneId, currentWave + 1, cfg.maxWaves))
                end
            elseif cfg.continuous and currentWave >= #cfg.waves then
                -- Continuous reinforcement waves after defined waves complete
                state.continuousWaveCount = state.continuousWaveCount or 0
                local continuousInterval = cfg.continuousIntervalMs or 25000
                local lastWaveTime = 0

                -- Calculate time since last wave
                if #cfg.waves > 0 then
                    lastWaveTime = cfg.waves[#cfg.waves].delayMs + effectiveDelay
                end

                local continuousElapsed = elapsed - lastWaveTime
                local expectedWaves = math.floor(continuousElapsed / continuousInterval)

                if expectedWaves > state.continuousWaveCount then
                    state.continuousWaveCount = state.continuousWaveCount + 1
                    spawnContinuousWave(cfg, zoneId, zoneConfig)
                    lib.print.info(('Zone "%s" continuous reinforcement wave %d'):format(
                        zoneId, state.continuousWaveCount))
                end
            end

            ::tick::
        end
    end)
end

-- ============================================================================
-- PURSUIT MANAGEMENT
-- ============================================================================

--- Start a pursuit thread for a guard that continues chasing after zone exit
---@param ped integer
---@param data GuardData
local function startPursuit(ped, data)
    local archetype = getArchetype(data.archetypeId)
    local tactics = archetype and archetype.tactics or {}
    local losTimeout = tactics.pursueLosTimeout or 20000

    pursuingGuards[ped] = {
        zoneId = data.zoneId,
        lastLosTime = GetGameTimer(),
        losTimeout = losTimeout,
    }

    CreateThread(function()
        while pursuingGuards[ped] and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) do
            Wait(1000)

            local pursuit = pursuingGuards[ped]
            if not pursuit then break end

            local hasLOS = HasEntityClearLosToEntity(ped, cache.ped, 17)
            if hasLOS then
                pursuit.lastLosTime = GetGameTimer()
                TaskCombatPed(ped, cache.ped, 0, 16)
                SetPedKeepTask(ped, true)
            else
                -- Check if LOS timeout exceeded
                if GetGameTimer() - pursuit.lastLosTime > pursuit.losTimeout then
                    -- Give up pursuit
                    pursuingGuards[ped] = nil
                    ClearPedTasks(ped)
                    ReleaseScenarioPed(ped)
                    secGuards[ped] = nil
                    lib.print.info(('Guard %d gave up pursuit (LOS timeout)'):format(ped))
                    break
                end
            end
        end

        -- Cleanup if ped died during pursuit
        if pursuingGuards[ped] then
            pursuingGuards[ped] = nil
            if DoesEntityExist(ped) then
                ReleaseScenarioPed(ped)
            end
            secGuards[ped] = nil
        end
    end)
end

-- ============================================================================
-- ZONE LIFECYCLE
-- ============================================================================

function InitSecurityZones()
    if next(secZones) then
        lib.print.warn('InitSecurityZones: zones already exist, skipping duplicate init')
        return
    end

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
                reinforcementsActive[zoneId] = nil -- cancel any lingering post-exit reinforcement
                deadPostGuards[zoneId] = nil
                playerAccess[zoneId] = nil
                keycardCache[zoneId] = nil
                activeZoneEffects[zoneId] = nil

                -- Initialize alert state
                zoneAlertState[zoneId] = {
                    level = 'patrol',
                    levelChangedAt = GetGameTimer(),
                    lastKnownPlayerPos = nil,
                    suspicionPool = 0,
                    combatStartedAt = nil,
                    continuousWaveCount = 0,
                }

                lib.print.info(('Entered security zone: %s'):format(config.label))

                -- Show trespass warning if player doesn't have access
                if config.warningMessage then
                    local hasAccess = checkPlayerAccess(zoneId, config)
                    if not hasAccess then
                        lib.notify({
                            title = config.label,
                            description = config.warningMessage,
                            type = 'warning', duration = 5000,
                        })
                    end
                end

                -- Determine shift-based overrides
                local shiftArchetype = nil
                local postMultiplier = 1.0
                local patrolMultiplier = 1.0

                if Config.GuardShifts and Config.GuardShifts.enabled and config.shifts then
                    local currentShift = getCurrentShift(config.shifts)
                    if currentShift then
                        shiftArchetype = currentShift.defaultArchetype
                        postMultiplier = currentShift.postMultiplier or 1.0
                        patrolMultiplier = currentShift.patrolMultiplier or 1.0
                        lib.print.info(('Zone "%s" using shift archetype: %s (post: %.1f, patrol: %.1f)'):format(
                            zoneId, shiftArchetype or 'default', postMultiplier, patrolMultiplier))
                    end
                end

                -- Spawn post guards (with shift multiplier)
                for _, post in ipairs(config.posts) do
                    local spawnCount = applySpawnMultiplier(postMultiplier)
                    for _ = 1, spawnCount do
                        spawnPostGuard(post, zoneId, config, shiftArchetype)
                    end
                end

                -- Spawn patrol guards (with shift multiplier)
                if config.patrols then
                    for _, patrol in ipairs(config.patrols) do
                        local spawnCount = applySpawnMultiplier(patrolMultiplier)
                        for _ = 1, spawnCount do
                            spawnPatrolGuard(patrol, zoneId, config, shiftArchetype)
                        end
                    end
                end

                -- Initialize objectives
                initObjectives(zoneId, config)

                -- Start reinforcement manager
                reinforcementLoop(zoneId, config)

                -- Start debug visualization
                startDebugVisualization(zoneId, config)

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
                keycardCache[zoneId] = nil

                lib.print.info(('Exited security zone: %s'):format(config.label))

                -- Cleanup objectives (props + ox_target zones)
                cleanupObjectives(zoneId)

                local state = zoneAlertState[zoneId]
                local inCombat = state and state.level == 'combat'

                -- Handle pursuit on exit: guards with pursueOnExit continue chasing
                if inCombat then
                    for ped, data in pairs(secGuards) do
                        if data.zoneId == zoneId and data.alive and DoesEntityExist(ped) then
                            local archetype = getArchetype(data.archetypeId)
                            local tactics = archetype and archetype.tactics or {}
                            if tactics.pursueOnExit then
                                startPursuit(ped, data)
                            end
                        end
                    end
                end

                if inCombat and config.reinforcements and config.reinforcements.enabled then
                    -- Keep relationships hostile while reinforcements are still arriving
                    reinforcementsActive[zoneId] = true

                    -- Continue spawning remaining reinforcement waves
                    CreateThread(function()
                        local currentWave = reinforcementWave[zoneId] or 0
                        local cfg = config.reinforcements

                        while reinforcementsActive[zoneId]
                            and currentWave < cfg.maxWaves
                            and currentWave < #cfg.waves do
                            Wait(2000)
                            if secZoneActive[zoneId] then return end -- player re-entered, abort
                            if not state.combatStartedAt then break end

                            local elapsed = GetGameTimer() - state.combatStartedAt
                            local nextWave = cfg.waves[currentWave + 1]
                            if elapsed >= nextWave.delayMs then
                                currentWave = currentWave + 1
                                reinforcementWave[zoneId] = currentWave
                                spawnReinforcementWave(nextWave, zoneId, config)
                            end
                        end

                        -- Stop continuous waves on zone exit
                        reinforcementsActive[zoneId] = nil

                        -- Let combat play out before releasing guards
                        Wait(30000)

                        if not secZoneActive[zoneId] then
                            SetRelationshipBetweenGroups(1, `SECURITY_GUARD`, `PLAYER`)
                            SetRelationshipBetweenGroups(1, `PLAYER`, `SECURITY_GUARD`)

                            for ped, data in pairs(secGuards) do
                                if data.zoneId == zoneId then
                                    -- Don't release pursuing guards (they manage themselves)
                                    if not pursuingGuards[ped] then
                                        ReleaseScenarioPed(ped)
                                        secGuards[ped] = nil
                                    end
                                end
                            end
                            zoneAlertState[zoneId] = nil
                            reinforcementWave[zoneId] = nil
                        end
                    end)
                else
                    -- No combat: reset relationships immediately
                    SetRelationshipBetweenGroups(1, `SECURITY_GUARD`, `PLAYER`)
                    SetRelationshipBetweenGroups(1, `PLAYER`, `SECURITY_GUARD`)

                    -- Delayed release (not delete) so guards don't pop out of existence
                    SetTimeout(8000, function()
                        if not secZoneActive[zoneId] then
                            for ped, data in pairs(secGuards) do
                                if data.zoneId == zoneId then
                                    -- Don't release pursuing guards
                                    if not pursuingGuards[ped] then
                                        ReleaseScenarioPed(ped)
                                        secGuards[ped] = nil
                                    end
                                end
                            end
                            zoneAlertState[zoneId] = nil
                            reinforcementWave[zoneId] = nil
                        end
                    end)
                end
            end,
        }

        secZones[zoneId] = lib.zones[config.zone.type](zoneData)
    end
end

function CleanupSecurityZones()
    for id, zone in pairs(secZones) do
        secZoneActive[id] = false
        reinforcementsActive[id] = nil
        zone:remove()
    end
    secZones = {}

    -- Full cleanup (resource stop / logout): hard-delete peds
    for ped in pairs(secGuards) do
        RemoveScenarioPed(ped)
    end
    secGuards = {}

    -- Clean up pursuing guards
    for ped in pairs(pursuingGuards) do
        if DoesEntityExist(ped) then
            RemoveScenarioPed(ped)
        end
    end
    pursuingGuards = {}

    for zoneId in pairs(zoneObjectiveProps) do
        cleanupObjectives(zoneId)
    end

    -- Clean up any active interaction animation
    if activeInteractionCleanup then
        activeInteractionCleanup()
        activeInteractionCleanup = nil
    end

    SetRelationshipBetweenGroups(1, `SECURITY_GUARD`, `PLAYER`)
    SetRelationshipBetweenGroups(1, `PLAYER`, `SECURITY_GUARD`)

    zoneAlertState = {}
    reinforcementWave = {}
    playerAccess = {}
    keycardCache = {}
    deadPostGuards = {}
    objectiveOpenStates = {}
    activeZoneEffects = {}
end

-- ============================================================================
-- RESOURCE STOP CLEANUP
-- ============================================================================

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        -- Clean up any in-progress interaction animation/props
        if activeInteractionCleanup then
            activeInteractionCleanup()
            activeInteractionCleanup = nil
        end
    end
end)
