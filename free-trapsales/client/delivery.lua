--- Trap Phone Delivery System — Client
--- Shows phone messages, manages delivery blips, spawns drop-off peds/vehicles,
--- and handles the delivery interaction.

local activeDelivery = nil  ---@type table?  -- current accepted delivery
local deliveryBlip = nil    ---@type integer?
local deliveryPed = nil     ---@type integer?
local deliveryVehicle = nil ---@type integer?
local deliveryZone = nil    ---@type CZone?  -- trigger zone at drop-off
local inDelivery = false    -- interaction lock

-- ============================================================================
-- CLEANUP
-- ============================================================================

local function cleanupDeliveryBlip()
    if deliveryBlip and DoesBlipExist(deliveryBlip) then
        RemoveBlip(deliveryBlip)
    end
    deliveryBlip = nil
end

local function cleanupDeliveryPed()
    if deliveryPed and DoesEntityExist(deliveryPed) then
        ClearPedTasks(deliveryPed)
        TaskWanderStandard(deliveryPed, 10.0, 10)
        SetBlockingOfNonTemporaryEvents(deliveryPed, false)
        SetTimeout(15000, function()
            if deliveryPed and DoesEntityExist(deliveryPed) then
                SetEntityAsMissionEntity(deliveryPed, false, true)
                DeleteEntity(deliveryPed)
            end
            deliveryPed = nil
        end)
    else
        deliveryPed = nil
    end
end

local function cleanupDeliveryVehicle()
    if deliveryVehicle and DoesEntityExist(deliveryVehicle) then
        SetTimeout(20000, function()
            if deliveryVehicle and DoesEntityExist(deliveryVehicle) then
                SetEntityAsMissionEntity(deliveryVehicle, false, true)
                DeleteVehicle(deliveryVehicle)
            end
            deliveryVehicle = nil
        end)
    else
        deliveryVehicle = nil
    end
end

local function cleanupDeliveryZone()
    if deliveryZone then
        deliveryZone:remove()
        deliveryZone = nil
    end
end

function CleanupActiveDelivery()
    cleanupDeliveryBlip()
    cleanupDeliveryPed()
    cleanupDeliveryVehicle()
    cleanupDeliveryZone()
    activeDelivery = nil
    inDelivery = false
end

-- ============================================================================
-- DELIVERY PED + VEHICLE SPAWN
-- ============================================================================

---@param location table {x, y, z, w}
local function spawnDeliveryPed(location)
    local modelHash = Config.TrapPhone.pedModels[math.random(#Config.TrapPhone.pedModels)]
    if not RequestModelAsync(modelHash, 5000) then return end

    local heading = location.w or 0.0
    local ped = CreatePed(4, modelHash, location.x, location.y, location.z, heading, true, true)

    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(modelHash)
        return
    end

    -- Wait for network registration
    local timeout = 0
    while not NetworkGetEntityIsNetworked(ped) and timeout < 10 do
        Wait(100)
        timeout = timeout + 1
    end

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetModelAsNoLongerNeeded(modelHash)

    -- Idle scenario
    local scenarios = {
        'WORLD_HUMAN_SMOKING',
        'WORLD_HUMAN_STAND_MOBILE',
        'WORLD_HUMAN_LEANING',
        'WORLD_HUMAN_HANG_OUT_STREET',
    }
    TaskStartScenarioInPlace(ped, scenarios[math.random(#scenarios)], 0, true)

    deliveryPed = ped
end

---@param location table {x, y, z, w}
local function spawnDeliveryVehicle(location)
    local vehicleChoice = Config.TrapPhone.vehicles[math.random(#Config.TrapPhone.vehicles)]
    if not vehicleChoice then return end -- nil entry = no vehicle

    if not RequestModelAsync(vehicleChoice, 5000) then return end

    -- Offset vehicle slightly from ped position
    local heading = (location.w or 0.0)
    local rad = math.rad(heading + 90)
    local vx = location.x + math.cos(rad) * 3.0
    local vy = location.y + math.sin(rad) * 3.0

    -- Try to find a road-side position near the delivery point
    local sideFound, sidePos = GetPointOnRoadSide(vx, vy, location.z, 0)
    local spawnX, spawnY, spawnZ = vx, vy, location.z
    if sideFound then
        spawnX, spawnY, spawnZ = sidePos.x, sidePos.y, sidePos.z
    end

    local vehicle = CreateVehicle(vehicleChoice, spawnX, spawnY, spawnZ, heading, true, true)

    if not DoesEntityExist(vehicle) then
        SetModelAsNoLongerNeeded(vehicleChoice)
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleEngineOn(vehicle, false, false, true)
    SetVehicleDoorsLocked(vehicle, 0)
    SetModelAsNoLongerNeeded(vehicleChoice)

    deliveryVehicle = vehicle
end

-- ============================================================================
-- DELIVERY INTERACTION
-- ============================================================================

local function handleDeliveryInteraction()
    if inDelivery or not activeDelivery then return end
    inDelivery = true

    -- Face the ped
    if deliveryPed and DoesEntityExist(deliveryPed) then
        TaskTurnPedToFaceEntity(deliveryPed, cache.ped, 1000)
        TaskTurnPedToFaceEntity(cache.ped, deliveryPed, 1000)
        Wait(800)
    end

    -- Progress bar for the handoff
    local completed = lib.progressBar({
        duration = 3000,
        label = 'Making the drop...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = {
            dict = 'mp_common',
            clip = 'givetake1_a',
            flag = 49,
        },
    })

    if not completed then
        lib.notify({ title = 'Delivery', description = 'Drop-off cancelled.', type = 'error' })
        inDelivery = false
        return
    end

    -- Server validates and completes
    local result = lib.callback.await('free-trapsales:server:completeDelivery', false)

    if not result then
        lib.notify({ title = 'Delivery', description = 'Something went wrong.', type = 'error' })
        CleanupActiveDelivery()
        return
    end

    if result.result == 'risk_event' then
        lib.notify({
            title = result.event.label,
            description = 'It was a setup!',
            type = 'error', duration = 5000,
        })

        -- Handle ped behavior for risk event
        if deliveryPed and DoesEntityExist(deliveryPed) then
            if result.event.pedAttacks then
                GivePedLoadout(deliveryPed, `WEAPON_PISTOL`)
                TaskCombatPed(deliveryPed, cache.ped, 0, 16)
                SetPedKeepTask(deliveryPed, true)
            else
                ClearPedTasks(deliveryPed)
                TaskSmartFleePed(deliveryPed, cache.ped, 100.0, -1, false, false)
            end
        end

        if result.event.wantedLevel then
            Wait(1500)
            SetPlayerWantedLevel(cache.playerId, result.event.wantedLevel, false)
            SetPlayerWantedLevelNow(cache.playerId, false)
        end

        cleanupDeliveryBlip()
        cleanupDeliveryZone()
        -- Let ped/vehicle linger for the encounter
        SetTimeout(25000, function()
            cleanupDeliveryPed()
            cleanupDeliveryVehicle()
        end)
        activeDelivery = nil
        inDelivery = false
        return
    end

    if result.result == 'success' then
        lib.notify({
            title = 'Delivery Complete',
            description = ('Earned $%s'):format(lib.math.groupdigits(result.payment)),
            type = 'success', duration = 5000,
        })

        -- Ped thanks and walks away
        if deliveryPed and DoesEntityExist(deliveryPed) then
            PlayPedAmbientSpeechNative(deliveryPed, 'GENERIC_THANKS', 'SPEECH_PARAMS_FORCE_NORMAL')
        end

        CleanupActiveDelivery()
        return
    end

    -- Error cases
    if result.error == 'expired' then
        lib.notify({ title = 'Delivery', description = 'Delivery expired — took too long.', type = 'error' })
    elseif result.error == 'remove_failed' then
        lib.notify({ title = 'Delivery', description = 'Missing items.', type = 'error' })
    else
        lib.notify({ title = 'Delivery', description = 'Delivery failed.', type = 'error' })
    end

    CleanupActiveDelivery()
end

-- ============================================================================
-- PHONE UI
-- ============================================================================

local function openPhoneUI()
    local result = lib.callback.await('free-trapsales:server:checkTrapPhone', false)

    if not result then
        lib.notify({ title = 'Trap Phone', description = 'No signal.', type = 'error' })
        return
    end

    if result.error == 'cooldown' then
        local mins = math.floor(result.remainingSeconds / 60)
        local secs = result.remainingSeconds % 60
        lib.notify({
            title = 'Trap Phone',
            description = ('No new messages. Check back in %d:%02d'):format(mins, secs),
            type = 'inform', duration = 4000,
        })
        return
    end

    local contacts = result.contacts
    if not contacts or #contacts == 0 then
        lib.notify({
            title = 'Trap Phone',
            description = 'No messages right now.',
            type = 'inform', duration = 3000,
        })
        return
    end

    -- Build context menu options
    local options = {}

    if result.hasDistribution then
        options[#options + 1] = {
            title = '[ Distribution Network Active ]',
            description = ('Rep: %.0f — Higher quantity orders available'):format(result.bestRep),
            icon = 'crown',
            readOnly = true,
        }
    end

    for _, contact in ipairs(contacts) do
        -- Build order summary
        local orderLines = {}
        for _, order in ipairs(contact.orders) do
            local itemDef = Config.DrugItems[order.itemName]
            local label = itemDef and itemDef.label or order.itemName
            orderLines[#orderLines + 1] = ('%dx %s'):format(order.quantity, label)
        end

        -- Pick a random message template for the first order
        local firstOrder = contact.orders[1]
        local itemDef = Config.DrugItems[firstOrder.itemName]
        local itemLabel = itemDef and itemDef.label or firstOrder.itemName
        local template = Config.TrapPhone.messageTemplates[math.random(#Config.TrapPhone.messageTemplates)]
        local messageText = template:format(firstOrder.quantity, itemLabel:lower())

        -- Add remaining orders if any
        if #contact.orders > 1 then
            for i = 2, #contact.orders do
                local o = contact.orders[i]
                local def = Config.DrugItems[o.itemName]
                local lbl = def and def.label or o.itemName
                messageText = messageText .. ('\n+ %dx %s'):format(o.quantity, lbl:lower())
            end
        end

        local icon = contact.isDistribution and 'truck' or 'envelope'
        local tierLabel = contact.isDistribution and ' [DISTRO]' or ''

        options[#options + 1] = {
            title = contact.name .. tierLabel,
            description = messageText,
            icon = icon,
            metadata = {
                { label = 'Payout', value = ('$%s'):format(lib.math.groupdigits(contact.totalPayment)) },
                { label = 'Orders', value = table.concat(orderLines, ', ') },
            },
            onSelect = function()
                acceptDeliveryFromPhone(contact)
            end,
        }
    end

    lib.registerContext({
        id = 'trap_phone_messages',
        title = 'Trap Phone — Messages',
        options = options,
    })
    lib.showContext('trap_phone_messages')
end

-- ============================================================================
-- ACCEPT DELIVERY
-- ============================================================================

---@param contact table
function acceptDeliveryFromPhone(contact)
    if activeDelivery then
        lib.notify({ title = 'Trap Phone', description = 'Complete your current delivery first.', type = 'error' })
        return
    end

    local result = lib.callback.await('free-trapsales:server:acceptDelivery', false, contact)

    if not result then
        lib.notify({ title = 'Trap Phone', description = 'Failed to accept delivery.', type = 'error' })
        return
    end

    if result.error then
        if result.error == 'missing_items' then
            lib.notify({
                title = 'Trap Phone',
                description = ("Missing %s — need %d, have %d"):format(result.itemLabel, result.need, result.have),
                type = 'error', duration = 5000,
            })
        elseif result.error == 'expired' then
            lib.notify({ title = 'Trap Phone', description = 'Message expired.', type = 'error' })
        elseif result.error == 'active_delivery' then
            lib.notify({ title = 'Trap Phone', description = 'Complete your current delivery first.', type = 'error' })
        else
            lib.notify({ title = 'Trap Phone', description = 'Could not accept.', type = 'error' })
        end
        return
    end

    activeDelivery = contact

    -- Build order summary for notification
    local orderParts = {}
    for _, order in ipairs(contact.orders) do
        local itemDef = Config.DrugItems[order.itemName]
        local label = itemDef and itemDef.label or order.itemName
        orderParts[#orderParts + 1] = ('%dx %s'):format(order.quantity, label)
    end

    lib.notify({
        title = 'Delivery Accepted',
        description = ('Deliver %s to %s — $%s'):format(
            table.concat(orderParts, ' + '),
            contact.name,
            lib.math.groupdigits(contact.totalPayment)),
        type = 'success', duration = 6000,
    })

    -- Create GPS blip
    local loc = contact.location
    local cfg = Config.TrapPhone.blip
    deliveryBlip = AddBlipForCoord(loc.x, loc.y, loc.z)
    SetBlipSprite(deliveryBlip, cfg.sprite)
    SetBlipColour(deliveryBlip, cfg.colour)
    SetBlipScale(deliveryBlip, cfg.scale)
    SetBlipRoute(deliveryBlip, true)
    SetBlipRouteColour(deliveryBlip, cfg.colour)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('Drop-off: %s'):format(contact.name))
    EndTextCommandSetBlipName(deliveryBlip)

    if not cfg.shortRange then
        SetBlipAsShortRange(deliveryBlip, false)
    end

    -- Create a trigger zone at the delivery location
    deliveryZone = lib.zones.sphere({
        coords = vec3(loc.x, loc.y, loc.z),
        radius = 25.0,
        debug = Config.Debug,

        onEnter = function()
            CreateThread(function()
                if not activeDelivery then return end

                lib.notify({
                    title = 'Delivery',
                    description = 'You\'ve arrived. Find the buyer.',
                    type = 'inform', duration = 4000,
                })

                -- Spawn ped and optional vehicle at the drop-off
                spawnDeliveryPed(loc)
                spawnDeliveryVehicle(loc)
            end)
        end,

        onExit = function()
            -- If player leaves the zone without completing, leave ped/vehicle
            -- They can re-enter to interact
        end,
    })

    -- Timeout thread
    CreateThread(function()
        local timeoutMs = Config.TrapPhone.deliveryTimeoutMs
        Wait(timeoutMs)

        if activeDelivery and activeDelivery.id == contact.id then
            lib.notify({
                title = 'Delivery',
                description = ('%s got tired of waiting. Delivery failed.'):format(contact.name),
                type = 'error', duration = 5000,
            })
            lib.callback.await('free-trapsales:server:cancelDelivery', false)
            CleanupActiveDelivery()
        end
    end)
end

-- ============================================================================
-- OX_TARGET INTEGRATION
-- ============================================================================

if GetResourceState('ox_target') == 'started' then
    exports.ox_target:addGlobalPed({
        {
            name = 'trapsales_delivery_interact',
            icon = 'fas fa-box',
            label = 'Make Drop',
            distance = 2.5,
            canInteract = function(entity)
                return activeDelivery ~= nil and deliveryPed == entity and not inDelivery
            end,
            onSelect = function()
                handleDeliveryInteraction()
            end,
        },
    })
end

-- ============================================================================
-- KEYBIND FOR DELIVERY (fallback without ox_target)
-- ============================================================================

lib.addKeybind({
    name = 'trap_delivery_interact',
    description = 'Interact with delivery buyer',
    defaultKey = 'E',
    onPressed = function()
        if not activeDelivery or inDelivery then return end
        if not deliveryPed or not DoesEntityExist(deliveryPed) then return end

        local dist = #(GetEntityCoords(cache.ped) - GetEntityCoords(deliveryPed))
        if dist < 3.0 then
            handleDeliveryInteraction()
        end
    end,
})

-- ============================================================================
-- EVENTS
-- ============================================================================

--- Phone item used — server tells us to open the UI
RegisterNetEvent('free-trapsales:client:openTrapPhone', function()
    openPhoneUI()
end)

--- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        CleanupActiveDelivery()
    end
end)

--- Cleanup on logout
RegisterNetEvent('qbx_core:client:onLogout', function()
    CleanupActiveDelivery()
end)

lib.print.info('[free-trapsales] Trap phone delivery client loaded')
