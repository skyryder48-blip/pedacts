--- Drug Zone Scenario — Enhanced
--- Full-featured drug dealing zone system with:
--- • Buyer archetypes (desperate, casual, bulk, group)
--- • Server-driven negotiation via ox_lib context menus
--- • Sale animations with progress bar and props
--- • Risk events (undercover, robbery) resolved server-side
--- • Time-of-day spawn scaling
--- • Curated + LOS-aware spawn positioning
--- • Ambient speech per state transition
--- • Police heat feedback (spawn suppression, lockdown awareness)

local zones = {}           ---@type table<string, CZone>
local zoneActive = {}      ---@type table<string, boolean>   -- keyed by zone.id
local zoneCooldowns = {}   ---@type table<string, integer>
local buyerPeds = {}       ---@type table<integer, BuyerData>
local inNegotiation = false

-- ============================================================================
-- TYPES
-- ============================================================================

---@class BuyerData
---@field ped integer -- lead ped handle
---@field groupPeds integer[] -- additional group member handles (empty for solo)
---@field zoneId string
---@field archetypeId string
---@field requestedItem string
---@field quantity integer
---@field state string -- idle | approaching | waiting | negotiating | leaving | risk
---@field spawnTime integer
---@field patienceExpiry integer -- game timer when ped gives up waiting

local PedState = {
    IDLE = 'idle',
    APPROACHING = 'approaching',
    WAITING = 'waiting',
    NEGOTIATING = 'negotiating',
    LEAVING = 'leaving',
    RISK = 'risk',
}

-- ============================================================================
-- ARCHETYPE LOOKUP
-- ============================================================================

---@param id string
---@return BuyerArchetype?
local function getArchetype(id)
    for _, a in ipairs(Config.BuyerArchetypes) do
        if a.id == id then return a end
    end
    return nil
end

-- ============================================================================
-- SMART SPAWN POSITIONING
-- ============================================================================

--- Pick a spawn point for a buyer ped.
--- Prefers curated spawn points, falls back to random scatter with LOS gating.
---@param zoneConfig DrugZoneConfig
---@return vector4?
local function pickSpawnPoint(zoneConfig)
    local playerCoords = GetEntityCoords(cache.ped)

    -- Try curated spawn points first (shuffled)
    if zoneConfig.spawnPoints and #zoneConfig.spawnPoints > 0 then
        local points = {}
        for i, p in ipairs(zoneConfig.spawnPoints) do points[i] = p end
        for i = #points, 2, -1 do
            local j = math.random(i)
            points[i], points[j] = points[j], points[i]
        end

        for _, point in ipairs(points) do
            local spawnPos = vec3(point.x, point.y, point.z)
            local dist = #(playerCoords - spawnPos)
            if dist > 12.0 and dist < zoneConfig.spawnRadius * 1.5 then
                if not HasEntityClearLosToCoord(cache.ped, point.x, point.y, point.z + 1.0, 17) then
                    return point
                end
            end
        end

        -- Fallback: first curated point far enough away
        for _, point in ipairs(points) do
            if #(playerCoords - vec3(point.x, point.y, point.z)) > 8.0 then
                return point
            end
        end
    end

    -- Random scatter fallback with LOS check
    for _ = 1, 15 do
        local angle = math.random() * 2 * math.pi
        local dist = 12.0 + math.random() * (zoneConfig.spawnRadius - 12.0)
        local x = zoneConfig.zone.coords.x + math.cos(angle) * dist
        local y = zoneConfig.zone.coords.y + math.sin(angle) * dist
        local z = zoneConfig.zone.coords.z

        local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
        if found and #(playerCoords - vec3(x, y, groundZ)) > 12.0 then
            if not HasEntityClearLosToCoord(cache.ped, x, y, groundZ + 1.0, 17) then
                return vec4(x, y, groundZ, math.random(0, 359) + 0.0)
            end
        end
    end

    -- Last resort
    local fallback = GetRandomSpawnPoint(zoneConfig.zone.coords, zoneConfig.spawnRadius)
    if fallback then
        return vec4(fallback.x, fallback.y, fallback.z, math.random(0, 359) + 0.0)
    end

    return nil
end

-- ============================================================================
-- PED TASKS & SPEECH
-- ============================================================================

---@param ped integer
---@param archetype BuyerArchetype
local function taskIdleScenario(ped, archetype)
    ClearPedTasks(ped)
    TaskStartScenarioInPlace(ped, PickRandom(archetype.idleScenarios), 0, true)
end

---@param ped integer
---@param target vector3
---@param speed number
local function taskApproach(ped, target, speed)
    ClearPedTasks(ped)
    TaskGoStraightToCoord(ped, target.x, target.y, target.z, speed, -1, 0.0, 0.5)
    SetPedKeepTask(ped, true)
end

---@param ped integer
---@param speech string
local function playSpeech(ped, speech)
    if speech and speech ~= '' then
        PlayPedAmbientSpeechNative(ped, speech, 'SPEECH_PARAMS_FORCE_NORMAL')
    end
end

---@param ped integer
---@param zoneId string
local function taskLeaveAndCleanup(ped, zoneId)
    local data = buyerPeds[ped]
    if not data then return end

    data.state = PedState.LEAVING
    ClearPedTasks(ped)
    TaskWanderStandard(ped, 10.0, 10)
    SetBlockingOfNonTemporaryEvents(ped, false)

    if data.groupPeds then
        for _, gPed in ipairs(data.groupPeds) do
            if DoesEntityExist(gPed) then
                ClearPedTasks(gPed)
                TaskWanderStandard(gPed, 10.0, 10)
                SetBlockingOfNonTemporaryEvents(gPed, false)
            end
            SetTimeout(12000, function()
                RemoveScenarioPed(gPed)
            end)
        end
    end

    SetTimeout(15000, function()
        RemoveScenarioPed(ped)
        buyerPeds[ped] = nil
    end)
end

-- ============================================================================
-- SALE ANIMATION SEQUENCE
-- ============================================================================

---@param ped integer
---@return boolean completed
local function playSaleAnimation(ped)
    local cfg = Config.SaleAnimation

    TaskTurnPedToFaceEntity(cache.ped, ped, 1000)
    TaskTurnPedToFaceEntity(ped, cache.ped, 1000)
    Wait(1200)

    lib.requestAnimDict(cfg.playerAnim.dict)
    lib.requestAnimDict(cfg.pedAnim.dict)

    -- Spawn props
    local playerPropHandle, pedPropHandle

    if cfg.playerProp.model then
        if RequestModelAsync(cfg.playerProp.model, 3000) then
            playerPropHandle = CreateObject(cfg.playerProp.model, 0.0, 0.0, 0.0, false, false, false)
            if DoesEntityExist(playerPropHandle) then
                local p = cfg.playerProp
                AttachEntityToEntity(playerPropHandle, cache.ped, GetPedBoneIndex(cache.ped, p.bone),
                    p.offset.x, p.offset.y, p.offset.z, p.rot.x, p.rot.y, p.rot.z,
                    true, true, false, true, 1, true)
            end
        end
    end

    if cfg.pedProp.model then
        if RequestModelAsync(cfg.pedProp.model, 3000) then
            pedPropHandle = CreateObject(cfg.pedProp.model, 0.0, 0.0, 0.0, false, false, false)
            if DoesEntityExist(pedPropHandle) then
                local p = cfg.pedProp
                AttachEntityToEntity(pedPropHandle, ped, GetPedBoneIndex(ped, p.bone),
                    p.offset.x, p.offset.y, p.offset.z, p.rot.x, p.rot.y, p.rot.z,
                    true, true, false, true, 1, true)
            end
        end
    end

    TaskPlayAnim(cache.ped, cfg.playerAnim.dict, cfg.playerAnim.name,
        8.0, -8.0, -1, cfg.playerAnim.flag, 0, false, false, false)
    TaskPlayAnim(ped, cfg.pedAnim.dict, cfg.pedAnim.name,
        8.0, -8.0, -1, cfg.pedAnim.flag, 0, false, false, false)

    local completed = lib.progressBar({
        duration = Config.Negotiation.saleDurationMs,
        label = 'Making the exchange...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
    })

    ClearPedTasks(cache.ped)
    ClearPedTasks(ped)

    if playerPropHandle and DoesEntityExist(playerPropHandle) then DeleteObject(playerPropHandle) end
    if pedPropHandle and DoesEntityExist(pedPropHandle) then DeleteObject(pedPropHandle) end

    RemoveAnimDict(cfg.playerAnim.dict)
    RemoveAnimDict(cfg.pedAnim.dict)

    return completed
end

-- ============================================================================
-- NEGOTIATION UI
-- ============================================================================

---@param ped integer
---@param data BuyerData
---@return integer? acceptedPrice
local function runNegotiation(ped, data)
    if inNegotiation then return nil end
    inNegotiation = true
    data.state = PedState.NEGOTIATING

    local archetype = getArchetype(data.archetypeId)
    if not archetype then inNegotiation = false return nil end

    local offer = lib.callback.await('qbx_pedscenarios:server:startNegotiation', false,
        data.zoneId, data.archetypeId, data.requestedItem, data.quantity)

    if not offer or offer.error then
        inNegotiation = false
        if offer and offer.error == 'missing_items' then
            lib.notify({
                title = 'Drug Deal',
                description = ("You don't have enough. Need %d, you have %d."):format(data.quantity, offer.hasCount),
                type = 'error',
            })
        end
        return nil
    end

    local currentOffer = offer.buyerOffer
    local round = offer.round
    local maxRounds = offer.maxRounds
    local accepted = nil

    while not accepted do
        local headerText = ('**%s** wants %dx %s'):format(
            archetype.label, offer.quantity, offer.itemLabel)

        local options = {
            {
                title = ('Accept $%s'):format(lib.math.groupdigits(currentOffer)),
                description = 'Take the offer',
                icon = 'check',
                onSelect = function()
                    accepted = currentOffer
                end,
            },
        }

        if round <= maxRounds then
            options[#options + 1] = {
                title = 'Counter-offer',
                description = ('Round %d/%d — name your price'):format(round, maxRounds),
                icon = 'hand-holding-dollar',
                onSelect = function()
                    local input = lib.inputDialog('Counter Offer', {
                        {
                            type = 'number',
                            label = ('Your price (fair ≈ $%s)'):format(lib.math.groupdigits(offer.fairPrice)),
                            default = offer.fairPrice,
                            min = 1,
                            max = math.floor(offer.fairPrice * 2),
                        },
                    })

                    if not input then accepted = -1 return end

                    local result = lib.callback.await('qbx_pedscenarios:server:counterOffer', false, math.floor(input[1]))

                    if not result or result.error then accepted = -1 return end

                    if result.result == 'accepted' then
                        accepted = result.finalPrice
                    elseif result.result == 'counter' then
                        currentOffer = result.buyerOffer
                        round = result.round
                        lib.notify({
                            title = 'Negotiation',
                            description = ('They counter with $%s'):format(lib.math.groupdigits(result.buyerOffer)),
                            type = 'inform', duration = 3000,
                        })
                    elseif result.result == 'final_offer' then
                        currentOffer = result.finalPrice
                        round = maxRounds + 1
                        lib.notify({
                            title = 'Negotiation',
                            description = ('Final offer: $%s — take it or leave it.'):format(lib.math.groupdigits(result.finalPrice)),
                            type = 'warning', duration = 4000,
                        })
                    elseif result.result == 'walked_away' then
                        lib.notify({
                            title = 'Drug Deal',
                            description = 'They walked away. You pushed too hard.',
                            type = 'error',
                        })
                        playSpeech(ped, archetype.speechAngry)
                        accepted = -1
                    end
                end,
            }
        end

        options[#options + 1] = {
            title = 'Refuse',
            description = 'Turn them away',
            icon = 'xmark',
            onSelect = function()
                lib.callback.await('qbx_pedscenarios:server:refuseSale', false)
                playSpeech(ped, archetype.speechAngry)
                accepted = -1
            end,
        }

        lib.registerContext({ id = 'drug_negotiation', title = headerText, options = options })
        lib.showContext('drug_negotiation')

        while not accepted and lib.getOpenContextMenu() == 'drug_negotiation' do
            Wait(100)
        end

        if not accepted then
            lib.callback.await('qbx_pedscenarios:server:refuseSale', false)
            accepted = -1
        end
    end

    inNegotiation = false
    return accepted ~= -1 and accepted or nil
end

-- ============================================================================
-- RISK EVENT HANDLER (client presentation)
-- ============================================================================

---@param ped integer
---@param event table
---@param data BuyerData
local function handleRiskEvent(ped, event, data)
    data.state = PedState.RISK

    if event.id == 'undercover' or event.id == 'dea_sting' then
        lib.notify({
            title = event.label,
            description = 'You\'ve been set up!',
            type = 'error', duration = 5000,
        })

        Wait(500)
        if event.pedAttacks then
            GivePedLoadout(ped, `WEAPON_PISTOL`)
            TaskCombatPed(ped, cache.ped, 0, 16)
            SetPedKeepTask(ped, true)
        else
            ClearPedTasks(ped)
            TaskSmartFleePed(ped, cache.ped, 100.0, -1, false, false)
        end

        if event.wantedLevel then
            Wait(1500)
            SetPlayerWantedLevel(cache.playerId, event.wantedLevel, false)
            SetPlayerWantedLevelNow(cache.playerId, false)
        end

    elseif event.id == 'robbery' then
        lib.notify({
            title = 'Robbery!',
            description = 'They\'re trying to rob you!',
            type = 'error', duration = 4000,
        })

        GivePedLoadout(ped, `WEAPON_KNIFE`)
        TaskCombatPed(ped, cache.ped, 0, 16)
        SetPedKeepTask(ped, true)
        SetPedFleeAttributes(ped, 0, false)

        if data.groupPeds then
            for _, gPed in ipairs(data.groupPeds) do
                if DoesEntityExist(gPed) then
                    GivePedLoadout(gPed, `WEAPON_SWITCHBLADE`)
                    TaskCombatPed(gPed, cache.ped, 0, 16)
                    SetPedKeepTask(gPed, true)
                end
            end
        end

    elseif event.id == 'snitch' then
        lib.notify({
            title = 'Snitch!',
            description = 'Someone tipped off the cops!',
            type = 'error', duration = 5000,
        })

        ClearPedTasks(ped)
        TaskSmartFleePed(ped, cache.ped, 100.0, -1, false, false)

        if event.wantedLevel then
            Wait(3000)
            SetPlayerWantedLevel(cache.playerId, event.wantedLevel, false)
            SetPlayerWantedLevelNow(cache.playerId, false)
        end
    end

    -- Delayed cleanup
    SetTimeout(20000, function()
        if DoesEntityExist(ped) then RemoveScenarioPed(ped) end
        if data.groupPeds then
            for _, gPed in ipairs(data.groupPeds) do RemoveScenarioPed(gPed) end
        end
        buyerPeds[ped] = nil
    end)
end

-- ============================================================================
-- FULL INTERACTION FLOW
-- ============================================================================

---@param ped integer
local function onInteractWithBuyer(ped)
    local data = buyerPeds[ped]
    if not data or data.state ~= PedState.WAITING then return end
    if inNegotiation then return end

    local archetype = getArchetype(data.archetypeId)
    if not archetype then return end

    TaskTurnPedToFaceEntity(ped, cache.ped, 1000)
    Wait(600)

    -- Negotiation
    local acceptedPrice
    if Config.Negotiation.enabled then
        acceptedPrice = runNegotiation(ped, data)
    else
        local offer = lib.callback.await('qbx_pedscenarios:server:startNegotiation', false,
            data.zoneId, data.archetypeId, data.requestedItem, data.quantity)
        if offer and not offer.error then acceptedPrice = offer.fairPrice end
    end

    if not acceptedPrice then
        taskLeaveAndCleanup(ped, data.zoneId)
        return
    end

    -- Animation
    local animCompleted = playSaleAnimation(ped)
    if not animCompleted then
        lib.callback.await('qbx_pedscenarios:server:refuseSale', false)
        lib.notify({ title = 'Drug Deal', description = 'Exchange cancelled.', type = 'error' })
        taskLeaveAndCleanup(ped, data.zoneId)
        return
    end

    -- Complete sale (server may trigger risk event)
    local result = lib.callback.await('qbx_pedscenarios:server:completeSale', false, acceptedPrice)

    if not result then
        taskLeaveAndCleanup(ped, data.zoneId)
        return
    end

    if result.result == 'risk_event' then
        handleRiskEvent(ped, result.event, data)
        return
    end

    if result.result == 'success' then
        playSpeech(ped, archetype.speechHappy)
        lib.notify({
            title = 'Drug Sale',
            description = ('Sold for $%s'):format(lib.math.groupdigits(result.payment)),
            type = 'success',
        })
        taskLeaveAndCleanup(ped, data.zoneId)
        return
    end

    if result.error then
        lib.notify({ title = 'Drug Deal', description = 'Something went wrong.', type = 'error' })
    end
    taskLeaveAndCleanup(ped, data.zoneId)
end

-- ============================================================================
-- SPAWN BUYER PED(S)
-- ============================================================================

---@param zoneConfig DrugZoneConfig
local function spawnBuyer(zoneConfig)
    local gameHour = GetClockHours()

    local spawnData = lib.callback.await('qbx_pedscenarios:server:rollBuyerSpawn', false,
        zoneConfig.id, gameHour)

    if not spawnData then return end

    local archetype = getArchetype(spawnData.archetypeId)
    if not archetype then return end

    local spawnPoint = pickSpawnPoint(zoneConfig)
    if not spawnPoint then return end

    local modelHash = PickRandom(archetype.pedModels)
    local leadPed = SpawnScenarioPed(modelHash, spawnPoint, spawnPoint.w, 0)
    if not leadPed then return end

    SetPedRelationshipGroupHash(leadPed, `YOURFRIENDLYGROUP`)

    -- Spawn group members
    local groupPeds = {}
    if spawnData.groupSize > 1 then
        for _ = 2, spawnData.groupSize do
            local offsetAngle = math.random() * 2 * math.pi
            local offsetDist = 1.0 + math.random() * 1.5
            local gx = spawnPoint.x + math.cos(offsetAngle) * offsetDist
            local gy = spawnPoint.y + math.sin(offsetAngle) * offsetDist

            local gPed = SpawnScenarioPed(PickRandom(archetype.pedModels), vec3(gx, gy, spawnPoint.z), spawnPoint.w, 0)
            if gPed then
                SetPedRelationshipGroupHash(gPed, `YOURFRIENDLYGROUP`)
                taskIdleScenario(gPed, archetype)
                groupPeds[#groupPeds + 1] = gPed
            end
        end
    end

    buyerPeds[leadPed] = {
        ped = leadPed,
        groupPeds = groupPeds,
        zoneId = zoneConfig.id,
        archetypeId = spawnData.archetypeId,
        requestedItem = spawnData.requestedItem,
        quantity = spawnData.quantity,
        state = PedState.IDLE,
        spawnTime = GetGameTimer(),
        patienceExpiry = 0,
    }

    taskIdleScenario(leadPed, archetype)
end

-- ============================================================================
-- BEHAVIOR UPDATE LOOP
-- ============================================================================

---@param zoneConfig DrugZoneConfig
local function updateBuyers(zoneConfig)
    local playerCoords = GetEntityCoords(cache.ped)

    for ped, data in pairs(buyerPeds) do
        if data.zoneId ~= zoneConfig.id then goto continue end
        if not DoesEntityExist(ped) then buyerPeds[ped] = nil goto continue end
        if data.state == PedState.LEAVING or data.state == PedState.RISK or data.state == PedState.NEGOTIATING then
            goto continue
        end

        local archetype = getArchetype(data.archetypeId)
        if not archetype then goto continue end

        local pedCoords = GetEntityCoords(ped)
        local dist = #(playerCoords - pedCoords)

        if data.state == PedState.IDLE then
            if dist < zoneConfig.approachRadius then
                data.state = PedState.APPROACHING
                playSpeech(ped, archetype.speechApproach)
                taskApproach(ped, playerCoords, archetype.approachSpeed)

                for _, gPed in ipairs(data.groupPeds) do
                    if DoesEntityExist(gPed) then
                        ClearPedTasks(gPed)
                        TaskFollowToOffsetOfEntity(gPed, ped, -1.0, -1.0, 0.0, archetype.approachSpeed, -1, 1.5, true)
                    end
                end
            end

        elseif data.state == PedState.APPROACHING then
            if dist < zoneConfig.interactRadius then
                data.state = PedState.WAITING
                data.patienceExpiry = GetGameTimer() + archetype.patienceMs
                taskIdleScenario(ped, archetype)

                for _, gPed in ipairs(data.groupPeds) do
                    if DoesEntityExist(gPed) then taskIdleScenario(gPed, archetype) end
                end

                lib.notify({
                    title = 'Drug Zone',
                    description = ('A %s wants to talk...'):format(archetype.label:lower()),
                    type = 'inform', duration = 4000,
                })

            elseif dist > zoneConfig.approachRadius * 2.0 then
                playSpeech(ped, archetype.speechAngry)
                taskLeaveAndCleanup(ped, data.zoneId)

            elseif GetScriptTaskStatus(ped, 0x7D8F4411) == 7 then
                taskApproach(ped, playerCoords, archetype.approachSpeed)
            end

        elseif data.state == PedState.WAITING then
            if GetGameTimer() > data.patienceExpiry then
                playSpeech(ped, archetype.speechAngry)
                lib.notify({
                    title = 'Drug Zone',
                    description = 'They got tired of waiting and left.',
                    type = 'inform',
                })
                taskLeaveAndCleanup(ped, data.zoneId)
            elseif dist > zoneConfig.interactRadius * 4.0 then
                taskLeaveAndCleanup(ped, data.zoneId)
            end
        end

        ::continue::
    end
end

-- ============================================================================
-- TIME-OF-DAY
-- ============================================================================

---@return number
local function getTimeOfDayMultiplier()
    if not Config.TimeOfDay.enabled then return 1.0 end
    local hour = GetClockHours()

    for _, slot in ipairs(Config.TimeOfDay.slots) do
        local inSlot
        if slot.startHour > slot.endHour then
            inSlot = hour >= slot.startHour or hour < slot.endHour
        else
            inSlot = hour >= slot.startHour and hour < slot.endHour
        end
        if inSlot then return slot.spawnMultiplier end
    end

    return 1.0
end

-- ============================================================================
-- ZONE LIFECYCLE
-- ============================================================================

function InitDrugZones()
    for _, config in ipairs(Config.DrugZones) do
        local zoneId = config.id

        local zoneData = {
            coords = config.zone.coords,
            radius = config.zone.radius,
            size = config.zone.size,
            rotation = config.zone.rotation,
            debug = Config.Debug,

            onEnter = function()
                if zoneCooldowns[zoneId] and GetGameTimer() < zoneCooldowns[zoneId] then return end

                local state = lib.callback.await('qbx_pedscenarios:server:getDrugZoneState', false, zoneId)

                if state and state.isLockdown then
                    lib.notify({
                        title = 'Drug Zone',
                        description = 'This area is too hot right now. Come back later.',
                        type = 'error', duration = 5000,
                    })
                    return
                end

                zoneActive[zoneId] = true
                lib.print.info(('Entered drug zone: %s | Heat: %.1f | Rep: %.0f'):format(
                    config.label, state and state.heat or 0, state and state.reputation or 0))

                -- Initial spawns (staggered)
                CreateThread(function()
                    for _ = 1, config.maxPeds do
                        if not zoneActive[zoneId] then return end
                        if math.random() < getTimeOfDayMultiplier() then
                            spawnBuyer(config)
                        end
                        Wait(math.random(800, 1500))
                    end
                end)

                -- Behavior ticks (500ms)
                CreateThread(function()
                    while zoneActive[zoneId] do
                        updateBuyers(config)
                        Wait(500)
                    end
                end)

                -- Replenishment loop
                CreateThread(function()
                    while zoneActive[zoneId] do
                        Wait(config.cooldownPerPedMs)
                        if not zoneActive[zoneId] then return end

                        local count = 0
                        for _, d in pairs(buyerPeds) do
                            if d.zoneId == zoneId and d.state ~= PedState.LEAVING and d.state ~= PedState.RISK then
                                count = count + 1
                            end
                        end

                        if count < config.maxPeds and math.random() < getTimeOfDayMultiplier() then
                            spawnBuyer(config)
                        end
                    end
                end)
            end,

            onExit = function()
                zoneActive[zoneId] = false
                zoneCooldowns[zoneId] = GetGameTimer() + Config.ZoneReEntryCooldown

                lib.print.info(('Exited drug zone: %s'):format(config.label))

                SetTimeout(6000, function()
                    if not zoneActive[zoneId] then
                        for ped, d in pairs(buyerPeds) do
                            if d.zoneId == zoneId then
                                if d.groupPeds then
                                    for _, gPed in ipairs(d.groupPeds) do RemoveScenarioPed(gPed) end
                                end
                                RemoveScenarioPed(ped)
                                buyerPeds[ped] = nil
                            end
                        end
                    end
                end)
            end,
        }

        zones[zoneId] = lib.zones[config.zone.type](zoneData)
    end
end

function CleanupDrugZones()
    for id, zone in pairs(zones) do
        zoneActive[id] = false
        zone:remove()
    end
    zones = {}

    for ped, data in pairs(buyerPeds) do
        if data.groupPeds then
            for _, gPed in ipairs(data.groupPeds) do RemoveScenarioPed(gPed) end
        end
        RemoveScenarioPed(ped)
    end
    buyerPeds = {}
    inNegotiation = false
end

-- ============================================================================
-- EXPORTS
-- ============================================================================

exports('InteractDrugBuyer', function(pedEntity)
    local data = buyerPeds[pedEntity]
    if data and data.state == PedState.WAITING then
        onInteractWithBuyer(pedEntity)
        return true
    end
    return false
end)

exports('IsDrugBuyer', function(pedEntity)
    local data = buyerPeds[pedEntity]
    return data ~= nil and data.state == PedState.WAITING
end)
