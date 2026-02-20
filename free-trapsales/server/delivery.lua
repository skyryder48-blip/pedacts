--- Trap Phone Delivery System — Server
--- Handles contact generation, delivery validation, and completion.

local activeDeliveries = {} ---@type table<integer, DeliverySession>
local phoneCooldowns = {}  ---@type table<integer, integer> -- source → os.time expiry

---@class DeliveryOrder
---@field itemName string
---@field quantity integer
---@field payment integer

---@class DeliveryContact
---@field id string           -- unique contact id
---@field name string
---@field orders DeliveryOrder[]
---@field location vector4
---@field totalPayment integer
---@field isDistribution boolean
---@field expiresAt integer   -- os.time

---@class DeliverySession
---@field contact DeliveryContact
---@field zoneId string       -- nearest zone for rep/heat
---@field startedAt integer
---@field expiresAt integer

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Pick a random element from a table
local function pickRandom(t)
    return t[math.random(#t)]
end

--- Generate a random contact name
---@return string
local function generateContactName()
    local first = pickRandom(Config.TrapPhone.contactFirstNames)
    local last = pickRandom(Config.TrapPhone.contactLastNames)
    return first .. ' ' .. last
end

--- Find the nearest drug zone to a delivery location
---@param coords vector4
---@return string zoneId
local function findNearestZone(coords)
    local closest = Config.DrugZones[1].id
    local closestDist = math.huge

    for _, zone in ipairs(Config.DrugZones) do
        local zc = zone.zone.coords
        local dist = math.sqrt((coords.x - zc.x)^2 + (coords.y - zc.y)^2)
        if dist < closestDist then
            closestDist = dist
            closest = zone.id
        end
    end

    return closest
end

--- Get the player's best rep across all zones
---@param source integer
---@return number bestRep, string bestZoneId
local function getPlayerBestRep(source)
    local bestRep = 0
    local bestZone = Config.DrugZones[1].id

    for _, zone in ipairs(Config.DrugZones) do
        local rep = exports['free-trapsales']:GetPlayerDrugRep(source, zone.id)
        if rep > bestRep then
            bestRep = rep
            bestZone = zone.id
        end
    end

    return bestRep, bestZone
end

--- Generate delivery orders for a single contact
---@param source integer
---@param isDistribution boolean
---@return DeliveryOrder[], integer totalPayment
local function generateOrders(source, isDistribution)
    local tier = isDistribution and Config.TrapPhone.distribution or Config.TrapPhone.smallTime
    local maxOrders = tier.maxOrders
    local numOrders = math.random(1, maxOrders)

    -- Collect available drug items
    local itemKeys = {}
    for name, _ in pairs(Config.DrugItems) do
        itemKeys[#itemKeys + 1] = name
    end

    -- Shuffle and pick
    for i = #itemKeys, 2, -1 do
        local j = math.random(i)
        itemKeys[i], itemKeys[j] = itemKeys[j], itemKeys[i]
    end

    local orders = {}
    local totalPayment = 0

    for i = 1, math.min(numOrders, #itemKeys) do
        local itemName = itemKeys[i]
        local itemDef = Config.DrugItems[itemName]
        local qtyMin, qtyMax = tier.quantityRange[1], tier.quantityRange[2]
        local quantity = math.random(qtyMin, qtyMax)

        -- Calculate payment: base price with delivery premium
        local variance = 1.0 + (math.random() * 2 - 1) * itemDef.priceVariance
        local unitPrice = math.floor(itemDef.basePrice * variance * Config.TrapPhone.paymentMultiplier)

        if isDistribution then
            unitPrice = math.floor(unitPrice * Config.TrapPhone.distribution.paymentMultiplier)
        end

        local payment = unitPrice * quantity
        totalPayment = totalPayment + payment

        orders[#orders + 1] = {
            itemName = itemName,
            quantity = quantity,
            payment = payment,
        }
    end

    return orders, totalPayment
end

--- Pick a random delivery location not too close to the player
---@param playerCoords vector3
---@return vector4?
local function pickDeliveryLocation(playerCoords)
    local locations = Config.TrapPhone.deliveryLocations
    -- Shuffle copy
    local shuffled = {}
    for i, loc in ipairs(locations) do shuffled[i] = loc end
    for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end

    for _, loc in ipairs(shuffled) do
        local dist = math.sqrt((playerCoords.x - loc.x)^2 + (playerCoords.y - loc.y)^2)
        -- Pick locations at least 200m away but not more than 5000m
        if dist > 200.0 and dist < 5000.0 then
            return loc
        end
    end

    -- Fallback: just pick any
    return shuffled[1]
end

-- ============================================================================
-- CALLBACKS
-- ============================================================================

--- Generate contacts when player uses trap phone
lib.callback.register('free-trapsales:server:checkTrapPhone', function(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return nil end

    -- Check cooldown
    if phoneCooldowns[source] and os.time() < phoneCooldowns[source] then
        local remaining = phoneCooldowns[source] - os.time()
        return { error = 'cooldown', remainingSeconds = remaining }
    end

    -- Get player coords for location selection
    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)

    -- Check player rep for distribution access
    local bestRep, bestZone = getPlayerBestRep(source)
    local hasDistribution = bestRep >= Config.TrapPhone.distribution.repThreshold

    -- Generate contacts
    local numContacts = math.random(Config.TrapPhone.minContacts, Config.TrapPhone.maxContacts)
    local contacts = {}
    local usedLocations = {}
    local expiresAt = os.time() + math.floor(Config.TrapPhone.messageExpiryMs / 1000)

    for i = 1, numContacts do
        -- Decide if this contact is distribution tier
        local isDistro = hasDistribution and math.random() < 0.4
        local orders, totalPayment = generateOrders(source, isDistro)

        -- Pick a unique location
        local location
        for _ = 1, 20 do
            location = pickDeliveryLocation(playerCoords)
            if location then
                local locKey = ('%d_%d'):format(math.floor(location.x), math.floor(location.y))
                if not usedLocations[locKey] then
                    usedLocations[locKey] = true
                    break
                end
            end
        end

        if not location then goto nextContact end

        local contactId = ('%s_%d_%d'):format(source, i, os.time())

        contacts[#contacts + 1] = {
            id = contactId,
            name = generateContactName(),
            orders = orders,
            location = { x = location.x, y = location.y, z = location.z, w = location.w },
            totalPayment = totalPayment,
            isDistribution = isDistro,
            expiresAt = expiresAt,
        }

        ::nextContact::
    end

    -- Set cooldown
    phoneCooldowns[source] = os.time() + math.floor(Config.TrapPhone.cooldownMs / 1000)

    lib.print.info(('[free-trapsales] Player %d checked trap phone: %d contacts generated (distro=%s)'):format(
        source, #contacts, tostring(hasDistribution)))

    return {
        contacts = contacts,
        hasDistribution = hasDistribution,
        bestRep = bestRep,
    }
end)

--- Player accepts a delivery
lib.callback.register('free-trapsales:server:acceptDelivery', function(source, contact)
    if not contact or not contact.orders then return { error = 'invalid' } end

    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    -- Check if player already has an active delivery
    if activeDeliveries[source] then
        return { error = 'active_delivery' }
    end

    -- Check expiry
    if os.time() > (contact.expiresAt or 0) then
        return { error = 'expired' }
    end

    -- Verify player has all required items
    for _, order in ipairs(contact.orders) do
        local hasCount = exports.ox_inventory:GetItemCount(source, order.itemName)
        if not hasCount or hasCount < order.quantity then
            local itemDef = Config.DrugItems[order.itemName]
            return {
                error = 'missing_items',
                itemLabel = itemDef and itemDef.label or order.itemName,
                need = order.quantity,
                have = hasCount or 0,
            }
        end
    end

    -- Find nearest zone for rep/heat tracking
    local loc = vec4(contact.location.x, contact.location.y, contact.location.z, contact.location.w or 0)
    local zoneId = findNearestZone(loc)

    activeDeliveries[source] = {
        contact = contact,
        zoneId = zoneId,
        startedAt = os.time(),
        expiresAt = os.time() + math.floor(Config.TrapPhone.deliveryTimeoutMs / 1000),
    }

    lib.print.info(('[free-trapsales] Player %d accepted delivery to %s (zone=%s, payment=$%d)'):format(
        source, contact.name, zoneId, contact.totalPayment))

    return { success = true, zoneId = zoneId }
end)

--- Player completes a delivery at the drop-off point
lib.callback.register('free-trapsales:server:completeDelivery', function(source)
    local session = activeDeliveries[source]
    if not session then return { error = 'no_delivery' } end

    local player = exports.qbx_core:GetPlayer(source)
    if not player then return { error = 'no_player' } end

    -- Check if delivery timed out
    if os.time() > session.expiresAt then
        activeDeliveries[source] = nil
        return { error = 'expired' }
    end

    local contact = session.contact
    local zoneId = session.zoneId

    -- Roll risk event
    local riskEvent = nil
    if math.random() < Config.TrapPhone.deliveryRiskChance then
        riskEvent = exports['free-trapsales']:RollRiskEvent(zoneId, contact.orders[1].itemName, source)
    end

    if riskEvent then
        -- Risk event: remove items but no payment
        lib.print.warn(('[free-trapsales] Delivery RISK EVENT "%s" for player %d'):format(riskEvent.id, source))

        for _, order in ipairs(contact.orders) do
            if riskEvent.stealItem then
                exports.ox_inventory:RemoveItem(source, order.itemName, order.quantity)
            end
        end

        exports['free-trapsales']:RemovePlayerDrugRep(source, zoneId, Config.Reputation.lossOnRiskEvent)
        exports['free-trapsales']:AddZoneHeat(zoneId, 5.0)

        activeDeliveries[source] = nil

        return {
            result = 'risk_event',
            event = {
                id = riskEvent.id,
                label = riskEvent.label,
                wantedLevel = riskEvent.wantedLevel,
                pedAttacks = riskEvent.pedAttacks,
                stealItem = riskEvent.stealItem or false,
                pedModel = riskEvent.pedModel,
            },
        }
    end

    -- Normal delivery: remove items, award payment
    local totalPayment = 0
    local totalQty = 0

    for _, order in ipairs(contact.orders) do
        local removed = exports.ox_inventory:RemoveItem(source, order.itemName, order.quantity)
        if not removed then
            activeDeliveries[source] = nil
            return { error = 'remove_failed' }
        end
        totalPayment = totalPayment + order.payment
        totalQty = totalQty + order.quantity
    end

    -- Award cash
    player.Functions.AddMoney('cash', totalPayment, ('Trap delivery: %s'):format(contact.name))

    -- Award rep
    local repGain = Config.TrapPhone.repPerDelivery + (totalQty - 1) * Config.Reputation.bonusPerBulkUnit
    exports['free-trapsales']:AddPlayerDrugRep(source, zoneId, repGain)

    -- Add heat
    exports['free-trapsales']:AddZoneHeat(zoneId, Config.TrapPhone.heatPerDelivery)

    -- Record sale
    exports['free-trapsales']:RecordSale(source, zoneId, totalPayment)

    -- Free-gangs integration
    if Config.GangIntegration and Config.GangIntegration.enabled then
        local gangRepConfig = Config.GangIntegration.drugSale
        if gangRepConfig then
            local ok, err = pcall(function()
                if GetResourceState('free-gangs') == 'started' then
                    exports['free-gangs']:ProcessExternalDrugSale(source, contact.orders[1].itemName, totalQty, totalPayment)
                end
            end)
            if not ok then
                lib.print.warn(('[free-trapsales] free-gangs delivery integration failed: %s'):format(tostring(err)))
            end
        end
    end

    local newRep = exports['free-trapsales']:GetPlayerDrugRep(source, zoneId)

    lib.print.info(('[free-trapsales] Player %d completed delivery to %s | $%d | Rep: %.0f'):format(
        source, contact.name, totalPayment, newRep))

    activeDeliveries[source] = nil

    return {
        result = 'success',
        payment = totalPayment,
        newReputation = newRep,
    }
end)

--- Cancel an active delivery
lib.callback.register('free-trapsales:server:cancelDelivery', function(source)
    if activeDeliveries[source] then
        local contact = activeDeliveries[source].contact
        local zoneId = activeDeliveries[source].zoneId
        activeDeliveries[source] = nil
        -- Small rep penalty for wasting buyer's time
        exports['free-trapsales']:RemovePlayerDrugRep(source, zoneId, Config.Reputation.lossOnRefuseSale)
        lib.print.info(('[free-trapsales] Player %d cancelled delivery to %s'):format(source, contact.name))
        return { success = true }
    end
    return { error = 'no_delivery' }
end)

--- Check if player has an active delivery (used by client on reconnect)
lib.callback.register('free-trapsales:server:getActiveDelivery', function(source)
    local session = activeDeliveries[source]
    if not session then return nil end

    -- Check if expired
    if os.time() > session.expiresAt then
        activeDeliveries[source] = nil
        return nil
    end

    return {
        contact = session.contact,
        zoneId = session.zoneId,
        expiresAt = session.expiresAt,
    }
end)

-- ============================================================================
-- ITEM REGISTRATION
-- ============================================================================

--- Register the trap_phone as a usable item via ox_inventory
exports.ox_inventory:RegisterUsableItem('trap_phone', function(playerData)
    local source = playerData.source

    -- Trigger the client to open the phone UI
    TriggerClientEvent('free-trapsales:client:openTrapPhone', source)
end)

lib.print.info('[free-trapsales] Trap phone delivery system loaded')

-- Cleanup on player disconnect
AddEventHandler('playerDropped', function()
    local source = source
    activeDeliveries[source] = nil
    phoneCooldowns[source] = nil
end)
