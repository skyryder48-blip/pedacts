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

---@param id string
---@return VehicleBuyerArchetype?
local function getVehicleArchetype(id)
    if not Config.VehicleBuyerArchetypes then return nil end
    for _, a in ipairs(Config.VehicleBuyerArchetypes) do
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

    local archetype = getArchetype(data.archetypeId) or getVehicleArchetype(data.archetypeId)
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

    SetPedRelationshipGroupHash(leadPed, `DRUGBUYER_GROUP`)

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
                SetPedRelationshipGroupHash(gPed, `DRUGBUYER_GROUP`)
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

                -- Vehicle buyer spawn loop
                local vbSettings = config.vehicleBuyer or Config.VehicleBuyerDefaults
                if vbSettings.enabled then
                    CreateThread(function()
                        -- Initial delay before first vehicle
                        Wait(math.random(15000, 30000))

                        while zoneActive[zoneId] do
                            if math.random() < getTimeOfDayMultiplier() * 0.5 then
                                spawnVehicleBuyer(config)
                            end
                            Wait(vbSettings.cooldownMs)
                        end
                    end)
                end
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
                        cleanupAllVehicleBuyers(zoneId)
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

    cleanupAllVehicleBuyers()
    vehicleCooldowns = {}
    vehicleToDriver = {}
    inNegotiation = false
end

-- ============================================================================
-- VEHICLE BUYER SYSTEM
-- High risk / high reward vehicle-based drug transactions
-- ============================================================================

local vehicleBuyers = {}   ---@type table<integer, VehicleBuyerData>
local vehicleCooldowns = {} ---@type table<string, integer>  -- zoneId -> next spawn time

---@class VehicleBuyerData
---@field vehicle integer
---@field driver integer
---@field passengers integer[]
---@field zoneId string
---@field archetypeId string
---@field requestedItem string
---@field quantity integer
---@field state string
---@field spawnTime integer
---@field patienceExpiry integer
---@field dispatchThread boolean?

local VehicleState = {
    DRIVING_IN = 'driving_in',
    PARKING = 'parking',
    WAITING = 'waiting',
    NEGOTIATING = 'negotiating',
    ROBBERY = 'robbery',
    LEAVING = 'leaving',
}

--- Reverse lookup: vehicle entity -> driver ped (for exports/interaction)
local vehicleToDriver = {} ---@type table<integer, integer>

-- ────────────────────────────────────────────────────────────────────────────
-- VEHICLE SPAWN HELPERS
-- ────────────────────────────────────────────────────────────────────────────

--- Find a road node at the requested distance from the zone center
---@param zoneCoords vector3
---@param spawnDistance number
---@return vector3?, number? -- coords, heading
local function findVehicleSpawnNode(zoneCoords, spawnDistance)
    for _ = 1, 12 do
        local angle = math.random() * 2 * math.pi
        local x = zoneCoords.x + math.cos(angle) * spawnDistance
        local y = zoneCoords.y + math.sin(angle) * spawnDistance

        local found, nodePos, heading = GetClosestVehicleNodeWithHeading(x, y, zoneCoords.z, 1, 3.0, 0)
        if found then
            return vec3(nodePos.x, nodePos.y, nodePos.z), heading
        end
    end
    return nil, nil
end

--- Find a road node near the zone center for parking
---@param zoneCoords vector3
---@param parkDistance number
---@return vector3?, number?
local function findParkingNode(zoneCoords, parkDistance)
    for _ = 1, 10 do
        local angle = math.random() * 2 * math.pi
        local dist = parkDistance * (0.6 + math.random() * 0.4)
        local x = zoneCoords.x + math.cos(angle) * dist
        local y = zoneCoords.y + math.sin(angle) * dist

        local found, nodePos, heading = GetClosestVehicleNodeWithHeading(x, y, zoneCoords.z, 1, 3.0, 0)
        if found then
            return vec3(nodePos.x, nodePos.y, nodePos.z), heading
        end
    end
    return nil, nil
end

-- ────────────────────────────────────────────────────────────────────────────
-- VEHICLE CLEANUP
-- ────────────────────────────────────────────────────────────────────────────

---@param driverPed integer
local function cleanupVehicleBuyer(driverPed)
    local data = vehicleBuyers[driverPed]
    if not data then return end

    data.dispatchThread = false

    -- Clear reverse lookup
    if data.vehicle then
        vehicleToDriver[data.vehicle] = nil
    end

    -- Clean up passengers
    if data.passengers then
        for _, passPed in ipairs(data.passengers) do
            if DoesEntityExist(passPed) then
                RemoveScenarioPed(passPed)
            end
        end
    end

    -- Clean up driver
    if DoesEntityExist(driverPed) then
        RemoveScenarioPed(driverPed)
    end

    -- Clean up vehicle
    if data.vehicle and DoesEntityExist(data.vehicle) then
        SetEntityAsMissionEntity(data.vehicle, false, true)
        DeleteVehicle(data.vehicle)
    end

    vehicleBuyers[driverPed] = nil
end

--- Drive away and cleanup (all occupants remain in vehicle)
---@param driverPed integer
local function vehicleDriveAwayAndCleanup(driverPed)
    local data = vehicleBuyers[driverPed]
    if not data then return end

    data.state = VehicleState.LEAVING
    data.dispatchThread = false

    local vehicle = data.vehicle
    if not DoesEntityExist(vehicle) or not DoesEntityExist(driverPed) then
        cleanupVehicleBuyer(driverPed)
        return
    end

    -- Start engine and drive away
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleHandbrake(vehicle, false)
    ClearPedTasks(driverPed)
    SetBlockingOfNonTemporaryEvents(driverPed, true)
    TaskVehicleDriveWander(driverPed, vehicle, 25.0, 786603)

    -- Delayed cleanup
    SetTimeout(20000, function()
        cleanupVehicleBuyer(driverPed)
    end)
end

-- ────────────────────────────────────────────────────────────────────────────
-- UNDERCOVER DISPATCH LOOP
-- ────────────────────────────────────────────────────────────────────────────

---@param driverPed integer
---@param zoneId string
local function startUndercoverDispatch(driverPed, zoneId)
    local data = vehicleBuyers[driverPed]
    if not data then return end
    data.dispatchThread = true

    -- Immediate dispatch on spawn
    TriggerServerEvent('qbx_pedscenarios:server:sendUndercoverDispatch', zoneId)

    CreateThread(function()
        while data.dispatchThread and DoesEntityExist(driverPed) do
            Wait(Config.VehicleBuyerArchetypes[2].dispatchIntervalMs or 20000)
            if not data.dispatchThread then return end
            if not DoesEntityExist(driverPed) then return end
            TriggerServerEvent('qbx_pedscenarios:server:sendUndercoverDispatch', zoneId)
        end
    end)
end

-- ────────────────────────────────────────────────────────────────────────────
-- ROBBERY BEHAVIOR (drive-by from vehicle)
-- ────────────────────────────────────────────────────────────────────────────

---@param driverPed integer
local function handleRobberyBehavior(driverPed)
    local data = vehicleBuyers[driverPed]
    if not data then return end

    data.state = VehicleState.ROBBERY
    local archetype = getVehicleArchetype(data.archetypeId)
    if not archetype then return end

    local vehicle = data.vehicle
    if not vehicle or not DoesEntityExist(vehicle) then
        cleanupVehicleBuyer(driverPed)
        return
    end

    lib.notify({
        title = 'Robbery!',
        description = 'They\'re pulling weapons from the car!',
        type = 'error', duration = 5000,
    })

    -- Arm passengers for drive-by (driver doesn't shoot, drives)
    local weaponPool = archetype.weapons or { `WEAPON_PISTOL` }

    -- Enable drive-by combat for all occupants
    SetPedConfigFlag(driverPed, 35, true) -- CPED_CONFIG_FLAG_DrivebysAllowed

    if data.passengers then
        for _, passPed in ipairs(data.passengers) do
            if DoesEntityExist(passPed) then
                local weapon = PickRandom(weaponPool)
                GivePedLoadout(passPed, weapon)
                SetPedCombatAttributes(passPed, 3, true) -- CanLeaveVehicle = disabled below
                SetPedConfigFlag(passPed, 35, true) -- DrivebysAllowed

                -- Drive-by task: shoot from vehicle at player
                local playerCoords = GetEntityCoords(cache.ped)
                TaskDriveBy(passPed, cache.ped, 0,
                    playerCoords.x, playerCoords.y, playerCoords.z,
                    50.0, 100, true, `FIRING_PATTERN_BURST_FIRE_DRIVEBY`)
                SetBlockingOfNonTemporaryEvents(passPed, true)
            end
        end
    end

    -- Server-side robbery processing (steal items, add heat)
    lib.callback.await('qbx_pedscenarios:server:processVehicleRobbery', false, data.zoneId)

    -- After a delay, they flee
    SetTimeout(6000, function()
        if not DoesEntityExist(driverPed) or not DoesEntityExist(vehicle) then
            cleanupVehicleBuyer(driverPed)
            return
        end

        -- Floor it out of there
        SetVehicleEngineOn(vehicle, true, true, false)
        SetVehicleHandbrake(vehicle, false)
        ClearPedTasks(driverPed)
        TaskVehicleDriveWander(driverPed, vehicle, 35.0, 786988) -- 786988 = rush + avoid traffic + ignore lights

        -- Clear passenger drive-by tasks so they stop shooting
        if data.passengers then
            for _, passPed in ipairs(data.passengers) do
                if DoesEntityExist(passPed) then
                    ClearPedTasks(passPed)
                end
            end
        end

        SetTimeout(15000, function()
            cleanupVehicleBuyer(driverPed)
        end)
    end)
end

-- ────────────────────────────────────────────────────────────────────────────
-- SUPPLIER BEHAVIOR (sells TO the player)
-- ────────────────────────────────────────────────────────────────────────────

---@param driverPed integer
local function handleSupplierInteraction(driverPed)
    local data = vehicleBuyers[driverPed]
    if not data or data.state ~= VehicleState.WAITING then return end
    if inNegotiation then return end

    inNegotiation = true
    data.state = VehicleState.NEGOTIATING

    local inventory = lib.callback.await('qbx_pedscenarios:server:getSupplierInventory', false, data.zoneId)

    if not inventory or not inventory.items or #inventory.items == 0 then
        inNegotiation = false
        lib.notify({
            title = 'Supplier',
            description = 'They have nothing to offer right now.',
            type = 'inform',
        })
        vehicleDriveAwayAndCleanup(driverPed)
        return
    end

    -- Build context menu of available items
    local options = {}
    for _, offer in ipairs(inventory.items) do
        options[#options + 1] = {
            title = ('%s x%d'):format(offer.label, offer.quantity),
            description = ('$%s total ($%s each)'):format(
                lib.math.groupdigits(offer.totalPrice),
                lib.math.groupdigits(offer.pricePerUnit)
            ),
            icon = 'fas fa-box',
            onSelect = function()
                local result = lib.callback.await('qbx_pedscenarios:server:processSupplierSale', false,
                    data.zoneId, offer.item, offer.quantity, offer.totalPrice)

                if result and result.result == 'success' then
                    lib.notify({
                        title = 'Supplier',
                        description = ('Purchased %dx %s for $%s'):format(
                            offer.quantity, offer.label,
                            lib.math.groupdigits(offer.totalPrice)
                        ),
                        type = 'success',
                    })
                elseif result and result.error == 'no_cash' then
                    lib.notify({
                        title = 'Supplier',
                        description = ('Not enough cash. Need $%s'):format(lib.math.groupdigits(offer.totalPrice)),
                        type = 'error',
                    })
                else
                    lib.notify({
                        title = 'Supplier',
                        description = 'Transaction failed.',
                        type = 'error',
                    })
                end
            end,
        }
    end

    options[#options + 1] = {
        title = 'No thanks',
        description = 'Turn them away',
        icon = 'xmark',
        onSelect = function() end,
    }

    lib.registerContext({
        id = 'vehicle_supplier_menu',
        title = 'Wholesale Supplier',
        options = options,
    })
    lib.showContext('vehicle_supplier_menu')

    while lib.getOpenContextMenu() == 'vehicle_supplier_menu' do
        Wait(100)
    end

    inNegotiation = false

    -- Sale animation
    if DoesEntityExist(driverPed) then
        local animCompleted = playSaleAnimation(driverPed)
        if not animCompleted then
            lib.notify({ title = 'Supplier', description = 'Exchange cancelled.', type = 'error' })
        end
    end

    vehicleDriveAwayAndCleanup(driverPed)
end

-- ────────────────────────────────────────────────────────────────────────────
-- VEHICLE BUYER INTERACTION (player approaches the vehicle)
-- All occupants remain in the vehicle for the entire transaction.
-- ────────────────────────────────────────────────────────────────────────────

---@param driverPed integer
local function onInteractWithVehicleBuyer(driverPed)
    local data = vehicleBuyers[driverPed]
    if not data or data.state ~= VehicleState.WAITING then return end

    local archetype = getVehicleArchetype(data.archetypeId)
    if not archetype then return end

    if archetype.behavior == 'supplier' then
        handleSupplierInteraction(driverPed)
        return
    end

    if archetype.behavior == 'robbery' then
        handleRobberyBehavior(driverPed)
        return
    end

    -- Normal buy behavior (big buyer / undercover)
    -- Player approaches the vehicle window — driver stays seated
    if inNegotiation then return end

    local acceptedPrice
    if Config.Negotiation.enabled then
        acceptedPrice = runNegotiation(driverPed, {
            ped = driverPed,
            groupPeds = {},
            zoneId = data.zoneId,
            archetypeId = data.archetypeId,
            requestedItem = data.requestedItem,
            quantity = data.quantity,
            state = PedState.NEGOTIATING,
            spawnTime = data.spawnTime,
            patienceExpiry = data.patienceExpiry,
        })
    else
        local offer = lib.callback.await('qbx_pedscenarios:server:startNegotiation', false,
            data.zoneId, data.archetypeId, data.requestedItem, data.quantity)
        if offer and not offer.error then acceptedPrice = offer.fairPrice end
    end

    if not acceptedPrice then
        vehicleDriveAwayAndCleanup(driverPed)
        return
    end

    -- Window exchange animation (player only)
    local animCompleted = playSaleAnimation(driverPed)
    if not animCompleted then
        lib.callback.await('qbx_pedscenarios:server:refuseSale', false)
        lib.notify({ title = 'Vehicle Deal', description = 'Exchange cancelled.', type = 'error' })
        vehicleDriveAwayAndCleanup(driverPed)
        return
    end

    local result = lib.callback.await('qbx_pedscenarios:server:completeSale', false, acceptedPrice, data.archetypeId)

    if not result then
        vehicleDriveAwayAndCleanup(driverPed)
        return
    end

    if result.result == 'risk_event' then
        if data.archetypeId == 'vehicle_undercover' then
            lib.notify({
                title = 'Undercover!',
                description = 'It was a setup! They\'re cops!',
                type = 'error', duration = 6000,
            })
            if result.event.wantedLevel then
                Wait(500)
                SetPlayerWantedLevel(cache.playerId, result.event.wantedLevel, false)
                SetPlayerWantedLevelNow(cache.playerId, false)
            end
        else
            handleRiskEvent(driverPed, result.event, {
                ped = driverPed,
                groupPeds = data.passengers or {},
                zoneId = data.zoneId,
                archetypeId = data.archetypeId,
                requestedItem = data.requestedItem,
                quantity = data.quantity,
                state = PedState.RISK,
                spawnTime = data.spawnTime,
                patienceExpiry = data.patienceExpiry,
            })
        end
        SetTimeout(5000, function()
            vehicleDriveAwayAndCleanup(driverPed)
        end)
        return
    end

    if result.result == 'success' then
        playSpeech(driverPed, 'GENERIC_THANKS')
        lib.notify({
            title = 'Vehicle Drug Sale',
            description = ('Sold for $%s'):format(lib.math.groupdigits(result.payment)),
            type = 'success',
        })
    end

    vehicleDriveAwayAndCleanup(driverPed)
end

-- ────────────────────────────────────────────────────────────────────────────
-- VEHICLE BUYER STATE MACHINE
-- ────────────────────────────────────────────────────────────────────────────

---@param driverPed integer
---@param zoneConfig DrugZoneConfig
local function startVehicleBuyerBehavior(driverPed, zoneConfig)
    local data = vehicleBuyers[driverPed]
    if not data then return end

    local archetype = getVehicleArchetype(data.archetypeId)
    if not archetype then return end

    local vbSettings = zoneConfig.vehicleBuyer or Config.VehicleBuyerDefaults
    local vehicle = data.vehicle

    -- Find parking spot near zone
    local parkPos, parkHeading = findParkingNode(zoneConfig.zone.coords, vbSettings.parkDistance)
    if not parkPos then
        cleanupVehicleBuyer(driverPed)
        return
    end

    -- Phase 1: Drive to parking spot
    data.state = VehicleState.DRIVING_IN
    TaskVehicleDriveToCoordLongrange(driverPed, vehicle, parkPos.x, parkPos.y, parkPos.z, 18.0, 786603, 5.0)

    -- Wait for arrival
    local arrivalTimeout = GetGameTimer() + 30000
    while data.state == VehicleState.DRIVING_IN and DoesEntityExist(driverPed) and DoesEntityExist(vehicle) do
        local vehPos = GetEntityCoords(vehicle)
        if #(vehPos - parkPos) < 8.0 then
            break
        end
        if GetGameTimer() > arrivalTimeout then
            cleanupVehicleBuyer(driverPed)
            return
        end
        Wait(500)
    end

    if not DoesEntityExist(driverPed) or not DoesEntityExist(vehicle) then
        cleanupVehicleBuyer(driverPed)
        return
    end

    -- Phase 2: Park the vehicle
    data.state = VehicleState.PARKING
    ClearPedTasks(driverPed)
    TaskVehiclePark(driverPed, vehicle, parkPos.x, parkPos.y, parkPos.z, parkHeading or 0.0, 1, 10.0, false)
    Wait(4000)

    -- Stop the vehicle
    if DoesEntityExist(vehicle) then
        SetVehicleHandbrake(vehicle, true)
        SetVehicleEngineOn(vehicle, false, false, true)
    end

    -- Start undercover dispatch if applicable
    if archetype.behavior == 'undercover' then
        startUndercoverDispatch(driverPed, data.zoneId)
    end

    -- Phase 3: Wait in vehicle for player to approach
    data.state = VehicleState.WAITING
    data.patienceExpiry = GetGameTimer() + archetype.patienceMs

    -- Robbery vehicles wait a moment then open fire if player is close
    if archetype.behavior == 'robbery' then
        Wait(2000)
        -- Check if player is within range, otherwise wait
        local timeout = GetGameTimer() + archetype.patienceMs
        while DoesEntityExist(driverPed) and DoesEntityExist(vehicle) do
            local playerDist = #(GetEntityCoords(cache.ped) - GetEntityCoords(vehicle))
            if playerDist < 8.0 then
                handleRobberyBehavior(driverPed)
                return
            end
            if GetGameTimer() > timeout then
                vehicleDriveAwayAndCleanup(driverPed)
                return
            end
            Wait(500)
        end
        cleanupVehicleBuyer(driverPed)
        return
    end

    lib.notify({
        title = 'Drug Zone',
        description = 'A vehicle has pulled up... approach the window.',
        type = 'inform', duration = 5000,
    })

    -- Wait for player interaction or patience to expire
    while data.state == VehicleState.WAITING and DoesEntityExist(driverPed) do
        if GetGameTimer() > data.patienceExpiry then
            lib.notify({
                title = 'Drug Zone',
                description = 'The vehicle drove off — you took too long.',
                type = 'inform',
            })
            vehicleDriveAwayAndCleanup(driverPed)
            return
        end
        Wait(500)
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- SPAWN VEHICLE BUYER
-- ────────────────────────────────────────────────────────────────────────────

---@param zoneConfig DrugZoneConfig
local function spawnVehicleBuyer(zoneConfig)
    local vbSettings = zoneConfig.vehicleBuyer or Config.VehicleBuyerDefaults
    if not vbSettings.enabled then return end

    -- Check cooldown
    if vehicleCooldowns[zoneConfig.id] and GetGameTimer() < vehicleCooldowns[zoneConfig.id] then
        return
    end

    -- Check max vehicles
    local activeCount = 0
    for _, vData in pairs(vehicleBuyers) do
        if vData.zoneId == zoneConfig.id and vData.state ~= VehicleState.LEAVING then
            activeCount = activeCount + 1
        end
    end
    if activeCount >= vbSettings.maxVehicles then return end

    -- Ask server for archetype
    local gameHour = GetClockHours()
    local spawnData = lib.callback.await('qbx_pedscenarios:server:rollVehicleBuyerSpawn', false,
        zoneConfig.id, gameHour)

    if not spawnData then return end

    local archetype = getVehicleArchetype(spawnData.archetypeId)
    if not archetype then return end

    -- Find road node for spawn
    local spawnPos, spawnHeading = findVehicleSpawnNode(zoneConfig.zone.coords, vbSettings.spawnDistance)
    if not spawnPos then return end

    -- Spawn vehicle
    local vehicleModel = PickRandom(archetype.vehicles)
    if not RequestModelAsync(vehicleModel, 5000) then return end

    local vehicle = CreateVehicle(vehicleModel, spawnPos.x, spawnPos.y, spawnPos.z, spawnHeading or 0.0, false, true)
    if not DoesEntityExist(vehicle) then
        SetModelAsNoLongerNeeded(vehicleModel)
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleDoorsLocked(vehicle, 0)
    SetModelAsNoLongerNeeded(vehicleModel)

    -- Spawn driver
    local driverModel = PickRandom(archetype.pedModels)
    local driver = SpawnScenarioPed(driverModel, spawnPos, spawnHeading or 0.0, 0)
    if not driver then
        SetEntityAsMissionEntity(vehicle, false, true)
        DeleteVehicle(vehicle)
        return
    end

    SetPedIntoVehicle(driver, vehicle, -1)
    SetPedRelationshipGroupHash(driver, `DRUGBUYER_GROUP`)
    SetBlockingOfNonTemporaryEvents(driver, true)

    -- Spawn passengers
    local passengers = {}
    local numOccupants = math.random(archetype.occupants[1], archetype.occupants[2])
    local maxPassengerSeats = GetVehicleMaxNumberOfPassengers(vehicle)

    for i = 2, numOccupants do
        local seatIndex = i - 2
        if seatIndex >= maxPassengerSeats then break end

        local passModel = PickRandom(archetype.pedModels)
        local passPed = SpawnScenarioPed(passModel, spawnPos, spawnHeading or 0.0, 0)
        if passPed then
            SetPedIntoVehicle(passPed, vehicle, seatIndex)
            SetPedRelationshipGroupHash(passPed, `DRUGBUYER_GROUP`)
            SetBlockingOfNonTemporaryEvents(passPed, true)
            passengers[#passengers + 1] = passPed
        end
    end

    vehicleBuyers[driver] = {
        vehicle = vehicle,
        driver = driver,
        passengers = passengers,
        zoneId = zoneConfig.id,
        archetypeId = spawnData.archetypeId,
        requestedItem = spawnData.requestedItem,
        quantity = spawnData.quantity,
        state = VehicleState.DRIVING_IN,
        spawnTime = GetGameTimer(),
        patienceExpiry = 0,
    }

    -- Register reverse lookup (vehicle -> driver) for interaction
    vehicleToDriver[vehicle] = driver

    vehicleCooldowns[zoneConfig.id] = GetGameTimer() + vbSettings.cooldownMs

    -- Start behavior in separate thread
    CreateThread(function()
        startVehicleBuyerBehavior(driver, zoneConfig)
    end)
end

-- ────────────────────────────────────────────────────────────────────────────
-- VEHICLE BUYER CLEANUP (called from zone exit and resource stop)
-- ────────────────────────────────────────────────────────────────────────────

local function cleanupAllVehicleBuyers(zoneId)
    for driverPed, vData in pairs(vehicleBuyers) do
        if not zoneId or vData.zoneId == zoneId then
            cleanupVehicleBuyer(driverPed)
        end
    end
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

--- Interact with a vehicle buyer. Accepts either a vehicle entity or driver ped.
exports('InteractVehicleBuyer', function(entity)
    -- Resolve to driver ped whether given vehicle or ped
    local driverPed = vehicleToDriver[entity] or entity
    local data = vehicleBuyers[driverPed]
    if data and data.state == VehicleState.WAITING then
        onInteractWithVehicleBuyer(driverPed)
        return true
    end
    return false
end)

--- Check if entity is a vehicle buyer. Accepts either a vehicle entity or driver ped.
exports('IsVehicleBuyer', function(entity)
    local driverPed = vehicleToDriver[entity] or entity
    local data = vehicleBuyers[driverPed]
    return data ~= nil and data.state == VehicleState.WAITING
end)
