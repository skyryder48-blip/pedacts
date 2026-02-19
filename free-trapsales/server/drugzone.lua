--- Server-side Drug Zone Logic
--- Manages: reputation (per player per zone), zone heat, risk event rolls,
--- negotiation validation, sale processing.
--- All state is server-authoritative — clients request, server decides.
---
--- PERSISTENCE: Reputation stored per citizenid/zone in `trapsales_drug_rep`.
--- Zone heat stored in `trapsales_zone_heat` and survives restarts.
--- Run sql/install.sql before first use.

-- ============================================================================
-- STATE (in-memory cache, backed by database)
-- ============================================================================

--- Player reputation cache: playerRep[source][zoneId] = number
---@type table<integer, table<string, number>>
local playerRep = {}

--- Player stats cache: playerStats[source][zoneId] = { totalSales, totalEarned }
---@type table<integer, table<string, table>>
local playerStats = {}

--- Map of source → citizenid for active players
---@type table<integer, string>
local playerCitizenIds = {}

--- Zone heat cache: zoneHeat[zoneId] = number
---@type table<string, number>
local zoneHeat = {}

--- Zones currently in lockdown: zoneLockdown[zoneId] = expiry os.time (seconds)
---@type table<string, integer>
local zoneLockdown = {}

--- Active negotiation sessions: negotiations[source] = session data
---@type table<integer, table>
local negotiations = {}

--- Dirty flags for debounced saves: dirtyRep[source] = { [zoneId] = true }
---@type table<integer, table<string, boolean>>
local dirtyRep = {}

--- Dirty flag for heat saves
---@type table<string, boolean>
local dirtyHeat = {}

-- ============================================================================
-- FREE-GANGS INTEGRATION
-- ============================================================================

--- Check if the free-gangs resource is running
---@return boolean
local function isFreeGangsActive()
    if not Config.GangIntegration or not Config.GangIntegration.enabled then return false end
    return GetResourceState('free-gangs') == 'started'
end

--- Award gang reputation for an activity. Gracefully no-ops if free-gangs is absent.
---@param source integer Player server id
---@param zoneId string Drug zone id (for zone loyalty mapping)
---@param repConfig table Config entry (e.g. Config.GangIntegration.drugSale)
---@param quantity integer Number of units in the transaction
local function awardGangRep(source, zoneId, repConfig, quantity)
    if not isFreeGangsActive() then return end

    local gangData = exports['free-gangs']:GetPlayerGang(source)
    if not gangData or not gangData.name then return end

    local gangName = gangData.name

    -- Master rep (gang-wide)
    local masterAmount = repConfig.masterRep or 0
    if repConfig.bulkBonusPerUnit and quantity > 1 then
        masterAmount = masterAmount + math.floor((quantity - 1) * repConfig.bulkBonusPerUnit)
    end
    if masterAmount > 0 then
        exports['free-gangs']:AddMasterRep(gangName, masterAmount, 'DrugSale')
    end

    -- Individual rep (player-specific)
    local indivAmount = repConfig.individualRep or 0
    if indivAmount > 0 then
        exports['free-gangs']:AddIndividualRep(source, indivAmount, 'DrugSale')
    end

    -- Zone loyalty (territory influence)
    local loyalty = repConfig.zoneLoyalty or 0
    if loyalty > 0 then
        local mapping = Config.GangIntegration.zoneMapping
        local territoryZone = mapping and mapping[zoneId]
        if territoryZone then
            exports['free-gangs']:AddZoneLoyalty(territoryZone, gangName, loyalty * quantity)
        end
    end

    lib.print.info(('free-gangs: Awarded %s masterRep=%d indivRep=%d for zone "%s"'):format(
        gangName, masterAmount, indivAmount, zoneId))
end

-- ============================================================================
-- CITIZENID HELPERS
-- ============================================================================

--- Get citizenid for a source, with caching
---@param source integer
---@return string?
local function getCitizenId(source)
    if playerCitizenIds[source] then
        return playerCitizenIds[source]
    end

    local player = exports.qbx_core:GetPlayer(source)
    if not player then return nil end

    local cid = player.PlayerData.citizenid
    playerCitizenIds[source] = cid
    return cid
end

-- ============================================================================
-- DATABASE: REPUTATION
-- ============================================================================

--- Load all reputation data for a player from the database
---@param source integer
---@param citizenid string
local function loadPlayerRep(source, citizenid)
    local rows = MySQL.query.await(
        'SELECT zone_id, reputation, total_sales, total_earned FROM trapsales_drug_rep WHERE citizenid = ?',
        { citizenid }
    )

    playerRep[source] = {}
    playerStats[source] = {}

    if rows then
        for _, row in ipairs(rows) do
            playerRep[source][row.zone_id] = row.reputation
            playerStats[source][row.zone_id] = {
                totalSales = row.total_sales,
                totalEarned = row.total_earned,
            }
        end
    end

    lib.print.info(('Loaded drug rep for %s (source %d): %d zone(s)'):format(
        citizenid, source, rows and #rows or 0))
end

--- Save a single zone reputation for a player to the database
---@param citizenid string
---@param zoneId string
---@param reputation number
---@param totalSales integer
---@param totalEarned integer
local function savePlayerRepZone(citizenid, zoneId, reputation, totalSales, totalEarned)
    MySQL.insert.await(
        [[INSERT INTO trapsales_drug_rep (citizenid, zone_id, reputation, total_sales, total_earned, last_sale_at)
          VALUES (?, ?, ?, ?, ?, NOW())
          ON DUPLICATE KEY UPDATE
              reputation = VALUES(reputation),
              total_sales = VALUES(total_sales),
              total_earned = VALUES(total_earned),
              last_sale_at = NOW()]],
        { citizenid, zoneId, reputation, totalSales, totalEarned }
    )
end

--- Save all dirty reputation for a player
---@param source integer
local function savePlayerRepAll(source)
    local citizenid = playerCitizenIds[source]
    if not citizenid then return end

    local dirty = dirtyRep[source]
    if not dirty then return end

    local rep = playerRep[source] or {}
    local stats = playerStats[source] or {}

    for zoneId in pairs(dirty) do
        local r = rep[zoneId] or 0
        local s = stats[zoneId] or { totalSales = 0, totalEarned = 0 }
        savePlayerRepZone(citizenid, zoneId, r, s.totalSales, s.totalEarned)
    end

    dirtyRep[source] = nil
end

-- ============================================================================
-- DATABASE: ZONE HEAT
-- ============================================================================

--- Load all zone heat from database on resource start
local function loadAllZoneHeat()
    local rows = MySQL.query.await('SELECT zone_id, heat, lockdown_until FROM trapsales_zone_heat')

    if rows then
        for _, row in ipairs(rows) do
            zoneHeat[row.zone_id] = row.heat

            if row.lockdown_until then
                -- Parse timestamp to os.time for comparison
                -- lockdown_until is a MySQL TIMESTAMP
                local lockdownTime = os.time() -- fallback
                local pattern = '(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)'
                local y, m, d, h, min, sec = row.lockdown_until:match(pattern)
                if y then
                    lockdownTime = os.time({
                        year = tonumber(y), month = tonumber(m), day = tonumber(d),
                        hour = tonumber(h), min = tonumber(min), sec = tonumber(sec)
                    })
                end

                if lockdownTime > os.time() then
                    zoneLockdown[row.zone_id] = lockdownTime
                end
            end
        end
    end

    lib.print.info(('Loaded zone heat for %d zone(s) from database'):format(rows and #rows or 0))
end

--- Save a single zone's heat to the database
---@param zoneId string
local function saveZoneHeat(zoneId)
    local heat = zoneHeat[zoneId] or 0.0
    local lockdownUntil = nil

    if zoneLockdown[zoneId] and zoneLockdown[zoneId] > os.time() then
        lockdownUntil = os.date('%Y-%m-%d %H:%M:%S', zoneLockdown[zoneId])
    end

    MySQL.insert.await(
        [[INSERT INTO trapsales_zone_heat (zone_id, heat, lockdown_until)
          VALUES (?, ?, ?)
          ON DUPLICATE KEY UPDATE
              heat = VALUES(heat),
              lockdown_until = VALUES(lockdown_until)]],
        { zoneId, heat, lockdownUntil }
    )
end

--- Save all dirty zone heat
local function saveAllDirtyHeat()
    for zoneId in pairs(dirtyHeat) do
        saveZoneHeat(zoneId)
    end
    dirtyHeat = {}
end

-- ============================================================================
-- REPUTATION HELPERS (use in-memory cache, flag dirty for save)
-- ============================================================================

---@param source integer
---@param zoneId string
---@return number
local function getRep(source, zoneId)
    if not playerRep[source] then playerRep[source] = {} end
    return playerRep[source][zoneId] or 0
end

---@param source integer
---@param zoneId string
---@param amount number
local function addRep(source, zoneId, amount)
    if not playerRep[source] then playerRep[source] = {} end
    local current = playerRep[source][zoneId] or 0
    playerRep[source][zoneId] = math.min(current + amount, Config.Reputation.maxReputation)

    -- Mark dirty
    if not dirtyRep[source] then dirtyRep[source] = {} end
    dirtyRep[source][zoneId] = true
end

---@param source integer
---@param zoneId string
---@param amount number
local function removeRep(source, zoneId, amount)
    if not playerRep[source] then playerRep[source] = {} end
    local current = playerRep[source][zoneId] or 0
    playerRep[source][zoneId] = math.max(current - amount, 0)

    if not dirtyRep[source] then dirtyRep[source] = {} end
    dirtyRep[source][zoneId] = true
end

--- Track a completed sale in stats
---@param source integer
---@param zoneId string
---@param payment integer
local function recordSale(source, zoneId, payment)
    if not playerStats[source] then playerStats[source] = {} end
    if not playerStats[source][zoneId] then
        playerStats[source][zoneId] = { totalSales = 0, totalEarned = 0 }
    end

    playerStats[source][zoneId].totalSales = playerStats[source][zoneId].totalSales + 1
    playerStats[source][zoneId].totalEarned = playerStats[source][zoneId].totalEarned + payment

    if not dirtyRep[source] then dirtyRep[source] = {} end
    dirtyRep[source][zoneId] = true
end

-- ============================================================================
-- HEAT HELPERS
-- ============================================================================

---@param zoneId string
---@return number
local function getHeat(zoneId)
    return zoneHeat[zoneId] or 0.0
end

---@param zoneId string
---@param amount number
local function addHeat(zoneId, amount)
    local current = zoneHeat[zoneId] or 0.0
    local newHeat = math.min(current + amount, Config.DrugHeat.maxHeat)
    zoneHeat[zoneId] = newHeat
    dirtyHeat[zoneId] = true

    if newHeat >= Config.DrugHeat.thresholds.lockdown and not zoneLockdown[zoneId] then
        local lockdownExpiry = os.time() + math.floor(Config.DrugHeat.lockdownDurationMs / 1000)
        zoneLockdown[zoneId] = lockdownExpiry
        dirtyHeat[zoneId] = true
        lib.print.warn(('Drug zone "%s" entered LOCKDOWN (heat: %.1f)'):format(zoneId, newHeat))
    end
end

--- Get the spawn multiplier for current heat level
---@param zoneId string
---@return number
local function getHeatSpawnMultiplier(zoneId)
    if zoneLockdown[zoneId] then
        if os.time() < zoneLockdown[zoneId] then
            return Config.DrugHeat.spawnMultiplier.lockdown
        else
            zoneLockdown[zoneId] = nil
            zoneHeat[zoneId] = Config.DrugHeat.thresholds.reduced
            dirtyHeat[zoneId] = true
        end
    end

    local heat = getHeat(zoneId)
    local t = Config.DrugHeat.thresholds

    if heat >= t.lockdown then
        return Config.DrugHeat.spawnMultiplier.lockdown
    elseif heat >= t.dangerous then
        return Config.DrugHeat.spawnMultiplier.dangerous
    elseif heat >= t.reduced then
        return Config.DrugHeat.spawnMultiplier.reduced
    else
        return Config.DrugHeat.spawnMultiplier.normal
    end
end

--- Calculate the "fair" price for an item
---@param itemName string
---@param archetypeId string
---@param quantity integer
---@param playerSource integer
---@param zoneId string
---@return integer totalPrice, integer perUnitPrice
local function calculateFairPrice(itemName, archetypeId, quantity, playerSource, zoneId)
    local itemDef = Config.DrugItems[itemName]
    if not itemDef then return 0, 0 end

    local archetype = nil
    for _, a in ipairs(Config.BuyerArchetypes) do
        if a.id == archetypeId then archetype = a break end
    end
    -- Also search vehicle buyer archetypes
    if not archetype and Config.VehicleBuyerArchetypes then
        for _, a in ipairs(Config.VehicleBuyerArchetypes) do
            if a.id == archetypeId then archetype = a break end
        end
    end
    if not archetype then return 0, 0 end

    local variance = 1.0 + (math.random() * 2 - 1) * itemDef.priceVariance
    local baseUnit = math.floor(itemDef.basePrice * variance)
    baseUnit = math.floor(baseUnit * archetype.priceMultiplier)

    local rep = getRep(playerSource, zoneId)
    local repBonus = (rep / Config.Reputation.maxReputation) * Config.Reputation.maxPriceBonus
    baseUnit = math.floor(baseUnit * (1.0 + repBonus))

    local heat = getHeat(zoneId)
    if heat > Config.DrugHeat.thresholds.reduced then
        local heatPenalty = math.min((heat - Config.DrugHeat.thresholds.reduced) / Config.DrugHeat.maxHeat * 0.15, 0.15)
        baseUnit = math.floor(baseUnit * (1.0 - heatPenalty))
    end

    return baseUnit * quantity, baseUnit
end

-- ============================================================================
-- RISK EVENT DETERMINATION
-- ============================================================================

---@param zoneId string
---@param itemName string
---@param playerSource integer
---@return table?
local function rollRiskEvent(zoneId, itemName, playerSource)
    local heat = getHeat(zoneId)
    local rep = getRep(playerSource, zoneId)
    local itemDef = Config.DrugItems[itemName]
    if not itemDef then return nil end

    local heatScale = 1.0 + (heat / Config.DrugHeat.maxHeat) * 2.0
    local effectiveChance = Config.BaseRiskChance * itemDef.riskModifier * heatScale

    local repReduction = (rep / Config.Reputation.maxReputation) * 0.03
    effectiveChance = math.max(effectiveChance - repReduction, 0.02)

    if math.random() > effectiveChance then return nil end

    local eligible = {}
    local totalWeight = 0

    for _, event in ipairs(Config.RiskEvents) do
        if heat >= event.minHeat and rep >= event.minReputation then
            eligible[#eligible + 1] = event
            totalWeight = totalWeight + event.weight
        end
    end

    if #eligible == 0 then return nil end

    local roll = math.random() * totalWeight
    local cumulative = 0

    for _, event in ipairs(eligible) do
        cumulative = cumulative + event.weight
        if roll <= cumulative then return event end
    end

    return eligible[#eligible]
end

-- ============================================================================
-- PERSISTENCE LOOPS
-- ============================================================================

--- Heat decay + periodic save
CreateThread(function()
    local tickCount = 0
    local saveEveryNTicks = 5 -- save heat to DB every 5 decay ticks

    while true do
        Wait(Config.DrugHeat.decayIntervalMs)
        for zoneId, heat in pairs(zoneHeat) do
            if heat > 0 then
                zoneHeat[zoneId] = math.max(heat - Config.DrugHeat.decayRate, 0.0)
                dirtyHeat[zoneId] = true
            end
        end

        tickCount = tickCount + 1
        if tickCount >= saveEveryNTicks then
            tickCount = 0
            local ok, err = pcall(saveAllDirtyHeat)
            if not ok then
                lib.print.error(('Heat save failed (will retry next cycle): %s'):format(tostring(err)))
            end
        end
    end
end)

--- Debounced reputation save (every 30 seconds, saves only dirty entries)
CreateThread(function()
    while true do
        Wait(30000)

        for source in pairs(dirtyRep) do
            -- Verify player is still connected
            if GetPlayerName(source) then
                local ok, err = pcall(savePlayerRepAll, source)
                if not ok then
                    lib.print.error(('Rep save failed for %s (will retry): %s'):format(source, tostring(err)))
                end
            else
                -- Player gone, clean up
                dirtyRep[source] = nil
            end
        end
    end
end)

-- ============================================================================
-- PLAYER LIFECYCLE — LOAD & SAVE
-- ============================================================================

--- Load reputation when a player selects their character
RegisterNetEvent('qbx_core:server:onPlayerLoaded', function()
    local source = source
    local citizenid = getCitizenId(source)
    if not citizenid then return end

    loadPlayerRep(source, citizenid)
end)

--- Also handle cases where the resource restarts while players are online
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- Load zone heat from database
    loadAllZoneHeat()

    -- Load rep for all currently connected players
    local players = exports.qbx_core:GetQBPlayers()
    for src, player in pairs(players) do
        local cid = player.PlayerData.citizenid
        if cid then
            playerCitizenIds[src] = cid
            loadPlayerRep(src, cid)
        end
    end

    lib.print.info('free-trapsales drug zone persistence initialized.')
end)

--- Save on character logout
RegisterNetEvent('qbx_core:server:onLogout', function(source)
    savePlayerRepAll(source)

    playerRep[source] = nil
    playerStats[source] = nil
    playerCitizenIds[source] = nil
    dirtyRep[source] = nil
    negotiations[source] = nil
end)

--- Save on player disconnect
AddEventHandler('playerDropped', function()
    local src = source
    savePlayerRepAll(src)

    playerRep[src] = nil
    playerStats[src] = nil
    playerCitizenIds[src] = nil
    dirtyRep[src] = nil
    negotiations[src] = nil
end)

--- Save everything on resource stop (graceful shutdown)
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    lib.print.info('Saving all drug zone data before shutdown...')

    -- Save all player rep
    for source in pairs(playerRep) do
        if dirtyRep[source] then
            savePlayerRepAll(source)
        end
    end

    -- Save all zone heat
    for zoneId in pairs(zoneHeat) do
        saveZoneHeat(zoneId)
    end

    lib.print.info('Drug zone data saved.')
end)

-- ============================================================================
-- CALLBACKS
-- ============================================================================

--- Client requests zone state when entering a drug zone.
lib.callback.register('free-trapsales:server:getDrugZoneState', function(source, zoneId)
    local heat = getHeat(zoneId)
    local spawnMult = getHeatSpawnMultiplier(zoneId)
    local rep = getRep(source, zoneId)
    local isLocked = zoneLockdown[zoneId] and os.time() < zoneLockdown[zoneId] or false

    lib.print.info(('[free-trapsales] getDrugZoneState: src=%d zone=%s heat=%.1f spawnMult=%.2f rep=%.0f lockdown=%s'):format(
        source, tostring(zoneId), heat, spawnMult, rep, tostring(isLocked)))

    return {
        heat = heat,
        spawnMultiplier = spawnMult,
        reputation = rep,
        isLockdown = isLocked,
    }
end)

--- Client requests which archetype to spawn.
lib.callback.register('free-trapsales:server:rollBuyerSpawn', function(source, zoneId, gameHour)
    local rep = getRep(source, zoneId)
    local heat = getHeat(zoneId)

    lib.print.info(('[free-trapsales] rollBuyerSpawn: src=%d zone=%s hour=%s rep=%.0f heat=%.1f'):format(
        source, tostring(zoneId), tostring(gameHour), rep, heat))

    if zoneLockdown[zoneId] and os.time() < zoneLockdown[zoneId] then
        lib.print.info('[free-trapsales] rollBuyerSpawn: zone in lockdown, returning nil')
        return nil
    end

    local spawnMult = getHeatSpawnMultiplier(zoneId)
    if math.random() > spawnMult then
        lib.print.info(('[free-trapsales] rollBuyerSpawn: heat roll failed (spawnMult=%.2f)'):format(spawnMult))
        return nil
    end

    local pool = {}
    local totalWeight = 0

    for _, archetype in ipairs(Config.BuyerArchetypes) do
        if rep >= archetype.minReputation then
            local weight = archetype.baseWeight

            if Config.TimeOfDay.enabled and gameHour then
                for _, slot in ipairs(Config.TimeOfDay.slots) do
                    local inSlot
                    if slot.startHour > slot.endHour then
                        inSlot = gameHour >= slot.startHour or gameHour < slot.endHour
                    else
                        inSlot = gameHour >= slot.startHour and gameHour < slot.endHour
                    end

                    if inSlot and slot.archetypeWeightOverrides and slot.archetypeWeightOverrides[archetype.id] ~= nil then
                        weight = slot.archetypeWeightOverrides[archetype.id]
                    end
                end
            end

            if heat >= Config.DrugHeat.thresholds.dangerous then
                if archetype.id == 'bulk' or archetype.id == 'group' then
                    weight = math.floor(weight * 0.3)
                end
            end

            if weight > 0 then
                pool[#pool + 1] = { archetype = archetype, weight = weight }
                totalWeight = totalWeight + weight
            end
        end
    end

    if #pool == 0 then
        lib.print.info('[free-trapsales] rollBuyerSpawn: empty archetype pool, returning nil')
        return nil
    end

    lib.print.info(('[free-trapsales] rollBuyerSpawn: %d archetype(s) in pool, totalWeight=%.0f'):format(#pool, totalWeight))

    local roll = math.random() * totalWeight
    local cumulative = 0
    local selected = pool[1].archetype

    for _, entry in ipairs(pool) do
        cumulative = cumulative + entry.weight
        if roll <= cumulative then
            selected = entry.archetype
            break
        end
    end

    local groupSize = math.random(selected.groupSize[1], selected.groupSize[2])

    local zoneConfig = nil
    for _, z in ipairs(Config.DrugZones) do
        if z.id == zoneId then zoneConfig = z break end
    end

    local requestedItem = zoneConfig and zoneConfig.items[math.random(#zoneConfig.items)] or 'weed_brick'
    local qty = math.random(selected.quantityRange[1], selected.quantityRange[2])

    lib.print.info(('[free-trapsales] rollBuyerSpawn: SUCCESS — archetype=%s item=%s qty=%d group=%d'):format(
        selected.id, requestedItem, qty, groupSize))

    return {
        archetypeId = selected.id,
        groupSize = groupSize,
        requestedItem = requestedItem,
        quantity = qty,
    }
end)

--- Start negotiation
lib.callback.register('free-trapsales:server:startNegotiation', function(source, zoneId, archetypeId, itemName, quantity)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return nil end

    local hasCount = exports.ox_inventory:GetItemCount(source, itemName)
    if not hasCount or hasCount < quantity then
        return { error = 'missing_items', hasCount = hasCount or 0 }
    end

    local totalFair, perUnit = calculateFairPrice(itemName, archetypeId, quantity, source, zoneId)
    local openingOffer = math.floor(totalFair * Config.Negotiation.openingOfferFraction)

    negotiations[source] = {
        zoneId = zoneId,
        archetypeId = archetypeId,
        itemName = itemName,
        quantity = quantity,
        fairPrice = totalFair,
        perUnit = perUnit,
        currentOffer = openingOffer,
        round = 1,
        maxRounds = Config.Negotiation.maxRounds,
    }

    local itemDef = Config.DrugItems[itemName]

    return {
        itemLabel = itemDef and itemDef.label or itemName,
        quantity = quantity,
        buyerOffer = openingOffer,
        fairPrice = totalFair,
        perUnit = perUnit,
        round = 1,
        maxRounds = Config.Negotiation.maxRounds,
    }
end)

--- Counter-offer
lib.callback.register('free-trapsales:server:counterOffer', function(source, counterPrice)
    local session = negotiations[source]
    if not session then return { error = 'no_session' } end

    local archetype = nil
    for _, a in ipairs(Config.BuyerArchetypes) do
        if a.id == session.archetypeId then archetype = a break end
    end
    if not archetype and Config.VehicleBuyerArchetypes then
        for _, a in ipairs(Config.VehicleBuyerArchetypes) do
            if a.id == session.archetypeId then archetype = a break end
        end
    end
    if not archetype then return { error = 'invalid' } end

    local greedRatio = (counterPrice - session.fairPrice) / session.fairPrice

    if greedRatio > archetype.walkAwayThreshold then
        negotiations[source] = nil
        removeRep(source, session.zoneId, Config.Reputation.lossOnRefuseSale)
        return { result = 'walked_away', reason = 'too_greedy' }
    end

    if counterPrice <= session.fairPrice then
        session.currentOffer = counterPrice
        return { result = 'accepted', finalPrice = counterPrice }
    end

    session.round = session.round + 1

    if session.round > session.maxRounds then
        local finalOffer = math.floor(session.fairPrice * 0.95)
        session.currentOffer = finalOffer
        return { result = 'final_offer', finalPrice = finalOffer, round = session.round }
    end

    if math.random() < archetype.haggleChance then
        local newOffer = math.floor((session.currentOffer + counterPrice) / 2)
        newOffer = math.max(newOffer, session.currentOffer)
        session.currentOffer = newOffer
        return { result = 'counter', buyerOffer = newOffer, round = session.round, maxRounds = session.maxRounds }
    else
        session.currentOffer = counterPrice
        return { result = 'accepted', finalPrice = counterPrice }
    end
end)

--- Complete sale
--- @param source integer
--- @param acceptedPrice integer
--- @param archetypeId? string -- vehicle archetype id, used to force undercover risk
lib.callback.register('free-trapsales:server:completeSale', function(source, acceptedPrice, archetypeId)
    local session = negotiations[source]
    if not session then return { error = 'no_session' } end

    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    local hasCount = exports.ox_inventory:GetItemCount(source, session.itemName)
    if not hasCount or hasCount < session.quantity then
        negotiations[source] = nil
        return { error = 'missing_items' }
    end

    -- Undercover vehicle archetype ALWAYS triggers undercover risk
    if archetypeId == 'vehicle_undercover' then
        lib.print.warn(('UNDERCOVER VEHICLE bust for player %s in zone "%s"'):format(source, session.zoneId))

        removeRep(source, session.zoneId, Config.Reputation.lossOnRiskEvent)
        addHeat(session.zoneId, 8.0)

        -- Still take their items (verify removal succeeds)
        local removed = exports.ox_inventory:RemoveItem(source, session.itemName, session.quantity)
        local stealItem = removed and true or false
        if not removed then
            lib.print.warn(('Undercover bust: RemoveItem failed for player %s (%s x%d)'):format(
                source, session.itemName, session.quantity))
        end

        negotiations[source] = nil

        return {
            result = 'risk_event',
            event = {
                id = 'undercover',
                label = 'Undercover Vehicle',
                wantedLevel = 3,
                pedAttacks = false,
                stealItem = stealItem,
                pedModel = `s_m_y_cop_01`,
            },
        }
    end

    -- Roll risk event BEFORE processing
    local riskEvent = rollRiskEvent(session.zoneId, session.itemName, source)

    if riskEvent then
        lib.print.warn(('RISK EVENT "%s" for player %s in zone "%s"'):format(riskEvent.id, source, session.zoneId))

        removeRep(source, session.zoneId, Config.Reputation.lossOnRiskEvent)
        addHeat(session.zoneId, 5.0)

        local stealItem = false
        if riskEvent.stealItem then
            local removed = exports.ox_inventory:RemoveItem(source, session.itemName, session.quantity)
            stealItem = removed and true or false
            if not removed then
                lib.print.warn(('Risk event "%s": RemoveItem failed for player %s (%s x%d)'):format(
                    riskEvent.id, source, session.itemName, session.quantity))
            end
        end

        negotiations[source] = nil

        return {
            result = 'risk_event',
            event = {
                id = riskEvent.id,
                label = riskEvent.label,
                wantedLevel = riskEvent.wantedLevel,
                pedAttacks = riskEvent.pedAttacks,
                stealItem = stealItem,
                pedModel = riskEvent.pedModel,
            },
        }
    end

    -- Normal sale
    local removed = exports.ox_inventory:RemoveItem(source, session.itemName, session.quantity)
    if not removed then
        negotiations[source] = nil
        return { error = 'remove_failed' }
    end

    local maxAcceptable = math.floor(session.fairPrice * 1.5)
    local finalPrice = math.min(acceptedPrice, maxAcceptable)
    finalPrice = math.max(finalPrice, 1)

    player.Functions.AddMoney('cash', finalPrice, ('Drug sale: %dx %s'):format(session.quantity, session.itemName))

    -- Update reputation
    local repGain = Config.Reputation.gainPerSale + (session.quantity - 1) * Config.Reputation.bonusPerBulkUnit
    addRep(source, session.zoneId, repGain)

    -- Track stats
    recordSale(source, session.zoneId, finalPrice)

    -- Update heat
    local itemDef = Config.DrugItems[session.itemName]
    local heatGain = (itemDef and itemDef.heatPerSale or 1.0) * session.quantity
    addHeat(session.zoneId, heatGain)

    local newRep = getRep(source, session.zoneId)
    local newHeat = getHeat(session.zoneId)

    -- Award free-gangs reputation
    local isVehicleSale = archetypeId and archetypeId:find('^vehicle_') ~= nil
    local gangRepConfig = isVehicleSale
        and Config.GangIntegration and Config.GangIntegration.vehicleSale
        or Config.GangIntegration and Config.GangIntegration.drugSale
    if gangRepConfig then
        awardGangRep(source, session.zoneId, gangRepConfig, session.quantity)
    end

    -- Process external drug sale through free-gangs (XP, rep, influence, heat, stats, market, dispatch)
    if isFreeGangsActive() then
        local ok, gangSuccess, gangRewards = pcall(exports['free-gangs'].ProcessExternalDrugSale, exports['free-gangs'], source, session.itemName, session.quantity, finalPrice)
        if ok and gangSuccess then
            lib.print.info(('free-gangs ProcessExternalDrugSale: player %s sold %dx %s for $%d'):format(
                source, session.quantity, session.itemName, finalPrice))
        elseif not ok then
            lib.print.warn(('free-gangs ProcessExternalDrugSale failed: %s'):format(tostring(gangSuccess)))
        end
    end

    lib.print.info(('Player %s sold %dx %s for $%d in zone "%s" | Rep: %.0f | Heat: %.1f'):format(
        source, session.quantity, session.itemName, finalPrice, session.zoneId, newRep, newHeat
    ))

    negotiations[source] = nil

    return {
        result = 'success',
        payment = finalPrice,
        newReputation = newRep,
        newHeat = newHeat,
    }
end)

--- Refuse sale
lib.callback.register('free-trapsales:server:refuseSale', function(source)
    local session = negotiations[source]
    if session then
        removeRep(source, session.zoneId, Config.Reputation.lossOnRefuseSale)
    end
    negotiations[source] = nil
    return true
end)

--- Get player reputation for a zone
lib.callback.register('free-trapsales:server:getReputation', function(source, zoneId)
    return getRep(source, zoneId)
end)

--- Get player drug dealing stats (for potential UI)
lib.callback.register('free-trapsales:server:getDrugStats', function(source, zoneId)
    local rep = getRep(source, zoneId)
    local stats = playerStats[source] and playerStats[source][zoneId]
        or { totalSales = 0, totalEarned = 0 }

    return {
        reputation = rep,
        totalSales = stats.totalSales,
        totalEarned = stats.totalEarned,
    }
end)

-- ============================================================================
-- VEHICLE BUYER CALLBACKS
-- ============================================================================

--- Roll which vehicle buyer archetype to spawn
lib.callback.register('free-trapsales:server:rollVehicleBuyerSpawn', function(source, zoneId, gameHour)
    local rep = getRep(source, zoneId)
    local heat = getHeat(zoneId)

    if zoneLockdown[zoneId] and os.time() < zoneLockdown[zoneId] then
        return nil
    end

    local spawnMult = getHeatSpawnMultiplier(zoneId)
    if math.random() > spawnMult then return nil end

    if not Config.VehicleBuyerArchetypes then return nil end

    local pool = {}
    local totalWeight = 0

    for _, archetype in ipairs(Config.VehicleBuyerArchetypes) do
        if rep >= archetype.minReputation then
            local weight = archetype.baseWeight

            -- Reduce weight in high heat (except undercover which increases)
            if heat >= Config.DrugHeat.thresholds.dangerous then
                if archetype.behavior == 'undercover' then
                    weight = math.floor(weight * 2.0)
                elseif archetype.behavior ~= 'robbery' then
                    weight = math.floor(weight * 0.4)
                end
            end

            if weight > 0 then
                pool[#pool + 1] = { archetype = archetype, weight = weight }
                totalWeight = totalWeight + weight
            end
        end
    end

    if #pool == 0 then return nil end

    local roll = math.random() * totalWeight
    local cumulative = 0
    local selected = pool[1].archetype

    for _, entry in ipairs(pool) do
        cumulative = cumulative + entry.weight
        if roll <= cumulative then
            selected = entry.archetype
            break
        end
    end

    -- Determine item and quantity
    local zoneConfig = nil
    for _, z in ipairs(Config.DrugZones) do
        if z.id == zoneId then zoneConfig = z break end
    end

    local requestedItem = zoneConfig and zoneConfig.items[math.random(#zoneConfig.items)] or 'weed_brick'
    local qty = math.random(selected.quantityRange[1], selected.quantityRange[2])

    return {
        archetypeId = selected.id,
        requestedItem = requestedItem,
        quantity = qty,
    }
end)

--- Process a vehicle robbery (steal items from player, add heat)
lib.callback.register('free-trapsales:server:processVehicleRobbery', function(source, zoneId)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    -- Steal a random drug item the player has
    local zoneConfig = nil
    for _, z in ipairs(Config.DrugZones) do
        if z.id == zoneId then zoneConfig = z break end
    end

    local stolenItems = {}
    if zoneConfig then
        for _, itemName in ipairs(zoneConfig.items) do
            local count = exports.ox_inventory:GetItemCount(source, itemName)
            if count and count > 0 then
                local stealQty = math.min(count, math.random(1, 3))
                local removed = exports.ox_inventory:RemoveItem(source, itemName, stealQty)
                if removed then
                    stolenItems[#stolenItems + 1] = { item = itemName, quantity = stealQty }
                end
            end
        end
    end

    -- Significant heat for robbery
    addHeat(zoneId, 6.0)
    removeRep(source, zoneId, Config.Reputation.lossOnRiskEvent)

    lib.print.warn(('Vehicle ROBBERY on player %s in zone "%s", stole %d item type(s)'):format(
        source, zoneId, #stolenItems))

    return {
        result = 'robbed',
        stolenItems = stolenItems,
    }
end)

--- Generate wholesale inventory for a supplier vehicle
lib.callback.register('free-trapsales:server:getSupplierInventory', function(source, zoneId)
    local rep = getRep(source, zoneId)

    local zoneConfig = nil
    for _, z in ipairs(Config.DrugZones) do
        if z.id == zoneId then zoneConfig = z break end
    end

    if not zoneConfig then return { items = {} } end

    local offerings = {}

    for _, itemName in ipairs(zoneConfig.items) do
        local itemDef = Config.DrugItems[itemName]
        if itemDef then
            -- Wholesale: 0.7x base price, quantity 10-25
            local qty = math.random(10, 25)
            local pricePerUnit = math.floor(itemDef.basePrice * 0.7)

            -- Slightly better price at higher rep
            local repDiscount = (rep / Config.Reputation.maxReputation) * 0.10
            pricePerUnit = math.floor(pricePerUnit * (1.0 - repDiscount))

            offerings[#offerings + 1] = {
                item = itemName,
                label = itemDef.label,
                quantity = qty,
                pricePerUnit = pricePerUnit,
                totalPrice = pricePerUnit * qty,
            }
        end
    end

    return { items = offerings }
end)

--- Process a supplier sale (player buys drugs from supplier)
lib.callback.register('free-trapsales:server:processSupplierSale', function(source, zoneId, itemName, quantity, totalPrice)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    -- Verify item exists
    local itemDef = Config.DrugItems[itemName]
    if not itemDef then return { error = 'invalid_item' } end

    -- Check cash
    local cash = player.Functions.GetMoney('cash')
    if cash < totalPrice then
        return { error = 'no_cash' }
    end

    -- Take cash
    local removed = player.Functions.RemoveMoney('cash', totalPrice, ('Supplier purchase: %dx %s'):format(quantity, itemName))
    if not removed then
        return { error = 'payment_failed' }
    end

    -- Give items
    local added = exports.ox_inventory:AddItem(source, itemName, quantity)
    if not added then
        -- Refund if item add failed
        player.Functions.AddMoney('cash', totalPrice, 'Supplier refund: item delivery failed')
        return { error = 'item_failed' }
    end

    -- Adds heat because a transaction occurred
    local heatGain = (itemDef.heatPerSale or 1.0) * quantity * 0.5
    addHeat(zoneId, heatGain)

    -- Award free-gangs reputation for supplier purchase
    if Config.GangIntegration and Config.GangIntegration.supplierPurchase then
        awardGangRep(source, zoneId, Config.GangIntegration.supplierPurchase, quantity)
    end

    lib.print.info(('Player %s bought %dx %s from supplier for $%d'):format(
        source, quantity, itemName, totalPrice))

    return {
        result = 'success',
        item = itemName,
        quantity = quantity,
        totalPrice = totalPrice,
    }
end)

--- Undercover dispatch event (triggers police notification)
RegisterNetEvent('free-trapsales:server:sendUndercoverDispatch', function(zoneId)
    local source = source

    local zoneConfig = nil
    for _, z in ipairs(Config.DrugZones) do
        if z.id == zoneId then zoneConfig = z break end
    end

    if not zoneConfig then return end

    -- Dispatch notification (compatible with ps-dispatch, cd_dispatch, etc.)
    -- Try ps-dispatch first, then fallback
    local dispatchExport = exports['ps-dispatch']
    if dispatchExport then
        pcall(function()
            dispatchExport:SuspiciousActivity({
                coords = zoneConfig.zone.coords,
                description = 'Suspicious vehicle reported in drug area',
            })
        end)
    end

    -- Also add heat since undercover presence means police awareness
    addHeat(zoneId, 1.0)

    lib.print.info(('Undercover dispatch sent for zone "%s" by player %s'):format(zoneId, source))
end)

-- ============================================================================
-- ADMIN EXPORTS
-- ============================================================================

---@param zoneId string
---@return table
local function getDrugZoneAdminStatus(zoneId)
    return {
        heat = getHeat(zoneId),
        isLockdown = zoneLockdown[zoneId] and os.time() < zoneLockdown[zoneId] or false,
        spawnMultiplier = getHeatSpawnMultiplier(zoneId),
    }
end

exports('GetDrugZoneStatus', getDrugZoneAdminStatus)

---@param zoneId string
---@param heat number
local function setDrugZoneHeat(zoneId, heat)
    zoneHeat[zoneId] = math.min(math.max(heat, 0), Config.DrugHeat.maxHeat)
    dirtyHeat[zoneId] = true
    if heat < Config.DrugHeat.thresholds.lockdown then
        zoneLockdown[zoneId] = nil
    end
end

exports('SetDrugZoneHeat', setDrugZoneHeat)

---@param source integer
---@param zoneId string
---@param rep number
local function setPlayerDrugRep(source, zoneId, rep)
    if not playerRep[source] then playerRep[source] = {} end
    playerRep[source][zoneId] = math.min(math.max(rep, 0), Config.Reputation.maxReputation)
    if not dirtyRep[source] then dirtyRep[source] = {} end
    dirtyRep[source][zoneId] = true
end

exports('SetPlayerDrugRep', setPlayerDrugRep)
