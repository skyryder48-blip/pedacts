--- Utility functions for ped scenario management
--- Handles model streaming, ped creation, and entity cleanup

local activePeds = {} ---@type table<integer, integer> -- pedHandle -> zoneId or 0

--- Request and load a ped model with timeout
---@param modelHash integer
---@param timeout? integer ms (default 5000)
---@return boolean success
function RequestModelAsync(modelHash, timeout)
    if HasModelLoaded(modelHash) then return true end
    if not IsModelInCdimage(modelHash) then
        lib.print.warn(('Model 0x%X not found in cdimage'):format(modelHash))
        return false
    end

    RequestModel(modelHash)
    local endTime = GetGameTimer() + (timeout or 5000)

    while not HasModelLoaded(modelHash) do
        if GetGameTimer() > endTime then
            lib.print.warn(('Timed out loading model 0x%X'):format(modelHash))
            return false
        end
        Wait(0)
    end

    return true
end

--- Spawn a ped at the given position
---@param modelHash integer
---@param coords vector3|vector4
---@param heading? number
---@param zoneId? integer -- associate with a zone for cleanup
---@return integer? pedHandle
function SpawnScenarioPed(modelHash, coords, heading, zoneId)
    if not RequestModelAsync(modelHash) then return nil end

    heading = heading or (coords.w and coords.w or 0.0)
    local ped = CreatePed(4, modelHash, coords.x, coords.y, coords.z, heading, false, true)

    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end

    -- Core setup: no-despawn, freeze AI defaults
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetModelAsNoLongerNeeded(modelHash)

    -- Track for cleanup
    activePeds[ped] = zoneId or 0

    return ped
end

--- Clean up a single ped (hard delete)
---@param ped integer
function RemoveScenarioPed(ped)
    if DoesEntityExist(ped) then
        ClearPedTasks(ped)
        SetEntityAsMissionEntity(ped, false, true)
        DeleteEntity(ped)
    end
    activePeds[ped] = nil
end

--- Release a ped back to the game engine without deleting it.
--- The ped stays in the world and will despawn naturally when the player moves away.
---@param ped integer
function ReleaseScenarioPed(ped)
    if DoesEntityExist(ped) then
        SetBlockingOfNonTemporaryEvents(ped, false)
        SetPedKeepTask(ped, false)
        SetEntityAsMissionEntity(ped, false, true)
    end
    activePeds[ped] = nil
end

--- Remove all peds associated with a specific zoneId
---@param zoneId integer
function RemovePedsByZone(zoneId)
    for ped, zone in pairs(activePeds) do
        if zone == zoneId then
            RemoveScenarioPed(ped)
        end
    end
end

--- Remove ALL tracked scenario peds
function RemoveAllScenarioPeds()
    for ped in pairs(activePeds) do
        RemoveScenarioPed(ped)
    end
    activePeds = {}
end

--- Get count of active peds for a zone
---@param zoneId integer
---@return integer
function GetActivePedCount(zoneId)
    local count = 0
    for ped, zone in pairs(activePeds) do
        if zone == zoneId and DoesEntityExist(ped) then
            count = count + 1
        else
            -- Prune dead references
            if not DoesEntityExist(ped) then
                activePeds[ped] = nil
            end
        end
    end
    return count
end

--- Get all tracked peds for a zone
---@param zoneId integer
---@return integer[]
function GetPedsByZone(zoneId)
    local peds = {}
    for ped, zone in pairs(activePeds) do
        if zone == zoneId and DoesEntityExist(ped) then
            peds[#peds + 1] = ped
        end
    end
    return peds
end

--- Pick a random entry from a table
---@generic T
---@param tbl T[]
---@return T
function PickRandom(tbl)
    return tbl[math.random(#tbl)]
end

--- Get a random spawn point within radius of center, on the ground
---@param center vector3
---@param radius number
---@return vector3?
function GetRandomSpawnPoint(center, radius)
    for _ = 1, 10 do -- try up to 10 times
        local angle = math.random() * 2 * math.pi
        local dist = math.random() * radius
        local x = center.x + math.cos(angle) * dist
        local y = center.y + math.sin(angle) * dist

        local found, z = GetGroundZFor_3dCoord(x, y, center.z + 50.0, false)
        if found then
            -- Verify it's a walkable position with a navmesh check
            local nodeFound, nodeCoords = GetClosestVehicleNode(x, y, z, 1, 3.0, 0)
            if nodeFound then
                return vec3(nodeCoords.x, nodeCoords.y, nodeCoords.z)
            end
            -- Fallback: just use ground z
            return vec3(x, y, z)
        end
    end
    return nil
end

--- Apply combat attributes to a ped from config table
---@param ped integer
---@param attributes table<integer, boolean>
function ApplyCombatAttributes(ped, attributes)
    for attr, value in pairs(attributes) do
        SetPedCombatAttributes(ped, attr, value)
    end
end

--- Give weapon to ped
---@param ped integer
---@param weapon integer hash
---@param ammo? integer
function GivePedLoadout(ped, weapon, ammo)
    GiveWeaponToPed(ped, weapon, ammo or 999, false, true)
    SetCurrentPedWeapon(ped, weapon, true)
end

-- ============================================================================
-- DEBUG VISUALIZATION HELPERS
-- Used by security zone detection system when Config.Debug is true.
-- ============================================================================

--- Draw a 3D text label above a world position
---@param coords vector3
---@param text string
---@param r? integer
---@param g? integer
---@param b? integer
function DrawDebugText3D(coords, text, r, g, b)
    local onScreen, screenX, screenY = World3dToScreen2d(coords.x, coords.y, coords.z + 1.0)
    if onScreen then
        SetTextScale(0.3, 0.3)
        SetTextFont(4)
        SetTextProportional(true)
        SetTextColour(r or 255, g or 255, b or 255, 215)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextOutline()
        SetTextEntry('STRING')
        AddTextComponentString(text)
        DrawText(screenX, screenY)
    end
end

--- Draw a horizontal bar above a world position (like a health bar)
---@param coords vector3
---@param value number 0-100
---@param maxValue number
---@param offsetY? number screen-space vertical offset
---@param r? integer
---@param g? integer
---@param b? integer
function DrawDebugBar(coords, value, maxValue, offsetY, r, g, b)
    local onScreen, screenX, screenY = World3dToScreen2d(coords.x, coords.y, coords.z + 1.2)
    if not onScreen then return end

    screenY = screenY + (offsetY or 0.0)
    local barWidth = 0.04
    local barHeight = 0.006
    local fillFraction = math.min(value / maxValue, 1.0)

    -- Background
    DrawRect(screenX, screenY, barWidth, barHeight, 0, 0, 0, 150)
    -- Fill
    local fillX = screenX - barWidth * 0.5 + (barWidth * fillFraction * 0.5)
    DrawRect(fillX, screenY, barWidth * fillFraction, barHeight, r or 255, g or 200, b or 0, 200)
end

--- Draw a detection cone line for a guard (simplified as a forward line)
---@param ped integer
---@param length number
---@param r integer
---@param g integer
---@param b integer
---@param a integer
function DrawDebugCone(ped, length, r, g, b, a)
    local pedCoords = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local endPos = pedCoords + fwd * length

    DrawLine(pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        endPos.x, endPos.y, endPos.z + 0.5,
        r, g, b, a)

    -- Draw cone edges (approx FOV)
    local fovDot = Config.Stealth and Config.Stealth.guardFovDot or -0.2
    local halfAngle = math.acos(math.max(-1.0, math.min(1.0, fovDot)))
    local sinA = math.sin(halfAngle)
    local cosA = math.cos(halfAngle)

    -- Left edge
    local leftX = fwd.x * cosA - fwd.y * sinA
    local leftY = fwd.x * sinA + fwd.y * cosA
    local leftEnd = pedCoords + vec3(leftX, leftY, 0.0) * length
    DrawLine(pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        leftEnd.x, leftEnd.y, leftEnd.z + 0.5,
        r, g, b, a * 0.5)

    -- Right edge
    local rightX = fwd.x * cosA + fwd.y * sinA
    local rightY = -fwd.x * sinA + fwd.y * cosA
    local rightEnd = pedCoords + vec3(rightX, rightY, 0.0) * length
    DrawLine(pedCoords.x, pedCoords.y, pedCoords.z + 0.5,
        rightEnd.x, rightEnd.y, rightEnd.z + 0.5,
        r, g, b, a * 0.5)
end

--- Draw a small marker at a world position
---@param coords vector3|vector4
---@param r integer
---@param g integer
---@param b integer
---@param label? string
function DrawDebugMarker(coords, r, g, b, label)
    DrawMarker(28, coords.x, coords.y, coords.z + 0.5, 0, 0, 0, 0, 0, 0, 0.15, 0.15, 0.15, r, g, b, 180, false, true, 2, false, nil, nil, false)
    if label then
        DrawDebugText3D(vec3(coords.x, coords.y, coords.z), label, r, g, b)
    end
end

-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        RemoveAllScenarioPeds()
    end
end)
