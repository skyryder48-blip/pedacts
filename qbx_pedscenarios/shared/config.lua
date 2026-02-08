---@class PedScenarioConfig
Config = {}

-- ============================================================================
-- GENERAL SETTINGS
-- ============================================================================

Config.Debug = true -- Enable debug drawing for zones

--- Maximum peds per zone (per player's client)
Config.MaxPedsPerZone = 4

--- Distance at which peds are despawned when player leaves zone
Config.DespawnDistance = 80.0

--- Cooldown in ms before a zone can re-trigger ped spawns after exiting
Config.ZoneReEntryCooldown = 30000

-- ============================================================================
-- PED MODELS (shared pools used across scenarios)
-- ============================================================================

Config.PedModels = {
    drugBuyers = {
        `a_m_y_skater_01`,
        `a_m_y_stbla_01`,
        `a_m_y_stbla_02`,
        `a_f_y_hipster_01`,
        `a_m_y_mexthug_01`,
        `a_m_m_tramp_01`,
        `a_f_y_rurmeth_01`,
        `a_m_y_rurmeth_01`,
    },
    securityGuards = {
        `s_m_m_security_01`,
        `s_m_m_bouncer_01`,
        `s_m_m_armoured_01`,
        `s_m_m_armoured_02`,
        `mp_m_securoguard_01`,
    },
    militaryGuards = {
        `s_m_m_marine_01`,
        `s_m_m_marine_02`,
        `s_m_y_marine_01`,
        `s_m_y_marine_02`,
        `s_m_y_marine_03`,
    },
}

-- ============================================================================
-- DRUG ZONE SCENARIOS
-- ============================================================================

---@class ZoneConfig
---@field type 'sphere'|'box'|'poly'
---@field coords vector3
---@field radius? number
---@field size? vector3
---@field rotation? number

-- ────────────────────────────────────────────────────────────────────────────
-- BUYER ARCHETYPES
-- Each archetype defines a category of buyer with unique behavior,
-- appearance, pricing, and spawn probability. Probability weights are
-- relative per-zone (the system normalizes them at runtime).
-- ────────────────────────────────────────────────────────────────────────────

---@class BuyerArchetype
---@field id string -- unique key
---@field label string -- display name (internal / debug)
---@field pedModels integer[] -- model pool for this archetype
---@field baseWeight number -- relative spawn weight (higher = more common)
---@field minReputation number -- minimum zone reputation to unlock this buyer
---@field quantityRange integer[] -- {min, max} items requested per sale
---@field priceMultiplier number -- multiplier on base item price (>1 = pays more)
---@field patienceMs integer -- how long they wait before leaving (ms)
---@field approachSpeed number -- 1.0 = walk, 2.0 = jog, 3.0 = run
---@field haggleChance number -- 0.0-1.0 chance they counter your counter-offer
---@field walkAwayThreshold number -- 0.0-1.0 how greedy a counter they'll tolerate (% above their offer)
---@field idleScenarios string[] -- scenarios to play while waiting
---@field speechApproach string -- ambient speech on approach
---@field speechHappy string -- speech on successful sale
---@field speechAngry string -- speech on failed/refused sale
---@field groupSize integer[] -- {min, max} peds in this buyer group (1,1 = solo)

Config.BuyerArchetypes = {
    {
        id = 'desperate',
        label = 'Desperate Addict',
        pedModels = {
            `a_m_m_tramp_01`,
            `a_f_y_rurmeth_01`,
            `a_m_y_rurmeth_01`,
            `a_m_m_stlat_02`,
            `a_f_y_tramp_01`,
        },
        baseWeight = 40,
        minReputation = 0,
        quantityRange = { 1, 1 },
        priceMultiplier = 0.65,
        patienceMs = 12000,
        approachSpeed = 2.5,
        haggleChance = 0.1,
        walkAwayThreshold = 0.10,
        idleScenarios = {
            'WORLD_HUMAN_STAND_IMPATIENT',
            'WORLD_HUMAN_BUM_STANDING',
        },
        speechApproach = 'GENERIC_HUMP',
        speechHappy = 'GENERIC_THANKS',
        speechAngry = 'GENERIC_CURSE_HIGH',
        groupSize = { 1, 1 },
    },
    {
        id = 'casual',
        label = 'Casual Buyer',
        pedModels = {
            `a_m_y_skater_01`,
            `a_m_y_stbla_01`,
            `a_f_y_hipster_01`,
            `a_m_y_hipster_01`,
            `a_f_y_beach_01`,
            `a_m_y_beach_01`,
        },
        baseWeight = 35,
        minReputation = 0,
        quantityRange = { 1, 2 },
        priceMultiplier = 1.0,
        patienceMs = 20000,
        approachSpeed = 1.0,
        haggleChance = 0.4,
        walkAwayThreshold = 0.25,
        idleScenarios = {
            'WORLD_HUMAN_SMOKING',
            'WORLD_HUMAN_HANG_OUT_STREET',
            'WORLD_HUMAN_STAND_MOBILE',
        },
        speechApproach = 'CHAT_STATE',
        speechHappy = 'GENERIC_THANKS',
        speechAngry = 'GENERIC_CURSE_MED',
        groupSize = { 1, 1 },
    },
    {
        id = 'bulk',
        label = 'Bulk Buyer',
        pedModels = {
            `a_m_y_mexthug_01`,
            `g_m_y_mexgang_01`,
            `g_m_y_ballasout_01`,
            `g_m_y_famfor_01`,
            `a_m_y_stbla_02`,
        },
        baseWeight = 15,
        minReputation = 25,
        quantityRange = { 3, 5 },
        priceMultiplier = 1.25,
        patienceMs = 25000,
        approachSpeed = 1.0,
        haggleChance = 0.6,
        walkAwayThreshold = 0.35,
        idleScenarios = {
            'WORLD_HUMAN_HANG_OUT_STREET',
            'WORLD_HUMAN_DRUG_DEALER',
        },
        speechApproach = 'CHAT_STATE',
        speechHappy = 'GENERIC_THANKS',
        speechAngry = 'GENERIC_INSULT_HIGH',
        groupSize = { 1, 2 },
    },
    {
        id = 'group',
        label = 'Group Buy',
        pedModels = {
            `a_m_y_stbla_01`,
            `a_m_y_stbla_02`,
            `a_f_y_hipster_01`,
            `a_m_y_skater_01`,
            `a_f_y_scdressy_01`,
        },
        baseWeight = 10,
        minReputation = 50,
        quantityRange = { 2, 4 },
        priceMultiplier = 1.15,
        patienceMs = 18000,
        approachSpeed = 1.0,
        haggleChance = 0.3,
        walkAwayThreshold = 0.20,
        idleScenarios = {
            'WORLD_HUMAN_HANG_OUT_STREET',
            'WORLD_HUMAN_STAND_MOBILE',
        },
        speechApproach = 'CHAT_STATE',
        speechHappy = 'GENERIC_THANKS',
        speechAngry = 'GENERIC_CURSE_MED',
        groupSize = { 2, 3 },
    },
}

-- ────────────────────────────────────────────────────────────────────────────
-- ITEM DEFINITIONS
-- Base prices, labels, and per-item risk modifiers.
-- ────────────────────────────────────────────────────────────────────────────

---@class DrugItemDef
---@field label string -- display name in negotiation UI
---@field basePrice integer -- base $ per unit (before archetype multiplier)
---@field priceVariance number -- 0.0-1.0 random variance range (0.2 = ±20%)
---@field heatPerSale number -- heat added to zone per sale of this item
---@field riskModifier number -- multiplier on risk event chance (1.0 = normal)

Config.DrugItems = {
    weed_brick = {
        label = 'Weed',
        basePrice = 120,
        priceVariance = 0.20,
        heatPerSale = 1.0,
        riskModifier = 0.7,
    },
    coke_brick = {
        label = 'Cocaine',
        basePrice = 300,
        priceVariance = 0.15,
        heatPerSale = 3.0,
        riskModifier = 1.3,
    },
    meth = {
        label = 'Meth',
        basePrice = 220,
        priceVariance = 0.18,
        heatPerSale = 2.5,
        riskModifier = 1.2,
    },
    crack = {
        label = 'Crack',
        basePrice = 150,
        priceVariance = 0.25,
        heatPerSale = 2.0,
        riskModifier = 1.1,
    },
    oxy = {
        label = 'Oxy',
        basePrice = 180,
        priceVariance = 0.12,
        heatPerSale = 1.5,
        riskModifier = 0.9,
    },
}

-- ────────────────────────────────────────────────────────────────────────────
-- POLICE HEAT SYSTEM
-- Heat accumulates per zone from sales and decays over time.
-- Higher heat = fewer buyers, higher risk event probability.
-- ────────────────────────────────────────────────────────────────────────────

Config.DrugHeat = {
    maxHeat = 100.0,              -- heat cap
    decayRate = 1.0,              -- heat lost per decay tick
    decayIntervalMs = 60000,      -- how often heat decays (ms)
    --- Heat thresholds affecting gameplay
    thresholds = {
        reduced = 30.0,           -- above this: spawn rate slows, buyers more cautious
        dangerous = 60.0,         -- above this: risk events more likely, some archetypes stop appearing
        lockdown = 85.0,          -- above this: zone temporarily stops spawning buyers entirely
    },
    --- How long lockdown lasts once triggered (ms)
    lockdownDurationMs = 120000,
    --- Spawn rate multipliers at each threshold
    spawnMultiplier = {
        normal = 1.0,             -- below 'reduced'
        reduced = 0.6,            -- between 'reduced' and 'dangerous'
        dangerous = 0.3,          -- between 'dangerous' and 'lockdown'
        lockdown = 0.0,           -- at or above 'lockdown'
    },
}

-- ────────────────────────────────────────────────────────────────────────────
-- RISK EVENT SYSTEM
-- Chance of negative outcomes per sale, scaled by heat and item type.
-- ────────────────────────────────────────────────────────────────────────────

---@class RiskEventDef
---@field id string
---@field label string
---@field weight number -- relative probability
---@field minHeat number -- minimum zone heat to enable this event
---@field minReputation number -- 0 = can happen anytime; higher = targets experienced dealers
---@field wantedLevel? integer -- if set, gives player this wanted level
---@field stealItem boolean -- does the ped try to take the drugs without paying
---@field pedAttacks boolean -- does the ped become hostile
---@field pedModel? integer -- override ped model for this event (e.g. undercover cop)

Config.RiskEvents = {
    {
        id = 'undercover',
        label = 'Undercover Cop',
        weight = 20,
        minHeat = 20.0,
        minReputation = 0,
        wantedLevel = 2,
        stealItem = false,
        pedAttacks = false,
        pedModel = `s_m_y_cop_01`,
    },
    {
        id = 'robbery',
        label = 'Robbery Attempt',
        weight = 25,
        minHeat = 10.0,
        minReputation = 0,
        wantedLevel = nil,
        stealItem = true,
        pedAttacks = true,
        pedModel = nil,
    },
    {
        id = 'snitch',
        label = 'Snitch',
        weight = 15,
        minHeat = 35.0,
        minReputation = 10,
        wantedLevel = 3,
        stealItem = false,
        pedAttacks = false,
        pedModel = nil,
    },
    {
        id = 'dea_sting',
        label = 'DEA Sting',
        weight = 10,
        minHeat = 60.0,
        minReputation = 40,
        wantedLevel = 4,
        stealItem = false,
        pedAttacks = true,
        pedModel = `s_m_m_fiboffice_01`,
    },
}

--- Base risk chance per sale (0.0 - 1.0), before heat and item modifiers
Config.BaseRiskChance = 0.08

-- ────────────────────────────────────────────────────────────────────────────
-- REPUTATION SYSTEM
-- Per-player, per-zone. Earned through successful sales, lost through
-- failed interactions and risk events. Unlocks better archetypes and prices.
-- ────────────────────────────────────────────────────────────────────────────

Config.Reputation = {
    gainPerSale = 2,              -- base rep gained per successful sale
    bonusPerBulkUnit = 1,         -- extra rep per unit above 1 in a sale
    lossOnRiskEvent = 10,         -- rep lost when a risk event fires
    lossOnRefuseSale = 1,         -- rep lost when player refuses to sell
    maxReputation = 100,
    --- Price bonus at max reputation (linear scale from 0 to this %)
    maxPriceBonus = 0.20,         -- 20% bonus at 100 rep
}

-- ────────────────────────────────────────────────────────────────────────────
-- TIME OF DAY
-- Controls spawn intensity based on in-game hour.
-- ────────────────────────────────────────────────────────────────────────────

---@class TimeSlot
---@field startHour integer -- 0-23
---@field endHour integer -- 0-23 (wraps around midnight)
---@field spawnMultiplier number
---@field archetypeWeightOverrides? table<string, number> -- archetype id -> weight override

Config.TimeOfDay = {
    enabled = true,
    slots = {
        { -- Late night: peak activity
            startHour = 22,
            endHour = 4,
            spawnMultiplier = 1.3,
            archetypeWeightOverrides = {
                desperate = 50,
                bulk = 25,
            },
        },
        { -- Morning: dead zone
            startHour = 5,
            endHour = 11,
            spawnMultiplier = 0.2,
            archetypeWeightOverrides = {
                bulk = 0,
                group = 0,
            },
        },
        { -- Afternoon: moderate
            startHour = 12,
            endHour = 17,
            spawnMultiplier = 0.5,
        },
        { -- Evening: ramping up
            startHour = 18,
            endHour = 21,
            spawnMultiplier = 0.9,
        },
    },
}

-- ────────────────────────────────────────────────────────────────────────────
-- NEGOTIATION SETTINGS
-- ────────────────────────────────────────────────────────────────────────────

Config.Negotiation = {
    enabled = true,
    --- The buyer's opening offer is this fraction of the "fair" price
    openingOfferFraction = 0.75,
    --- Maximum counter-offers before buyer walks
    maxRounds = 3,
    --- Duration of sale animation / progress bar (ms)
    saleDurationMs = 4000,
}

-- ────────────────────────────────────────────────────────────────────────────
-- SALE ANIMATION SETTINGS
-- ────────────────────────────────────────────────────────────────────────────

Config.SaleAnimation = {
    --- Player animation during handoff
    playerAnim = { dict = 'mp_common', name = 'givetake1_a', flag = 49 },
    --- Ped animation during handoff
    pedAnim = { dict = 'mp_common', name = 'givetake1_b', flag = 49 },
    --- Prop held by player during sale (bag)
    playerProp = { model = `prop_cs_package_01`, bone = 28422, offset = vec3(0.0, 0.0, 0.0), rot = vec3(0.0, 0.0, 0.0) },
    --- Prop held by ped (cash)
    pedProp = { model = `prop_cash_envelope_01`, bone = 28422, offset = vec3(0.0, 0.0, 0.0), rot = vec3(0.0, 0.0, 0.0) },
}

-- ────────────────────────────────────────────────────────────────────────────
-- ZONE DEFINITIONS
-- No blips. Word-of-mouth / meta discovery only.
-- ────────────────────────────────────────────────────────────────────────────

---@class DrugZoneConfig
---@field id string -- unique zone identifier (used for rep/heat keys)
---@field label string
---@field zone ZoneConfig
---@field maxPeds integer
---@field approachRadius number
---@field interactRadius number
---@field spawnRadius number
---@field cooldownPerPedMs integer
---@field items string[] -- keys into Config.DrugItems
---@field archetypeOverrides? table<string, number> -- per-zone weight overrides
---@field spawnPoints? vector4[] -- curated spawn positions (alleys, corners); if empty uses random

Config.DrugZones = {
    {
        id = 'grove_street',
        label = 'Grove Street',
        zone = {
            type = 'sphere',
            coords = vec3(95.0, -1960.0, 21.0),
            radius = 60.0,
        },
        maxPeds = 4,
        approachRadius = 15.0,
        interactRadius = 2.0,
        spawnRadius = 25.0,
        cooldownPerPedMs = 20000,
        items = { 'weed_brick', 'coke_brick', 'crack' },
        --- Curated spawn points: alleys, behind dumpsters, near walls.
        --- If this table is populated, peds prefer these over random scatter.
        --- Format: vec4(x, y, z, heading)
        spawnPoints = {
            vec4(85.0, -1970.0, 21.1, 320.0),
            vec4(110.0, -1945.0, 21.1, 180.0),
            vec4(78.0, -1955.0, 21.1, 90.0),
            vec4(105.0, -1978.0, 21.1, 45.0),
            vec4(120.0, -1960.0, 21.1, 270.0),
        },
        vehicleBuyer = {
            enabled = true,
            maxVehicles = 1,
            cooldownMs = 45000,
            spawnDistance = 80.0,
            parkDistance = 15.0,
        },
    },
    {
        id = 'strawberry_ave',
        label = 'Strawberry Ave',
        zone = {
            type = 'sphere',
            coords = vec3(200.0, -1650.0, 29.0),
            radius = 50.0,
        },
        maxPeds = 3,
        approachRadius = 12.0,
        interactRadius = 2.0,
        spawnRadius = 20.0,
        cooldownPerPedMs = 25000,
        items = { 'weed_brick', 'crack', 'oxy' },
        spawnPoints = {},
        vehicleBuyer = {
            enabled = true,
            maxVehicles = 1,
            cooldownMs = 55000,
            spawnDistance = 70.0,
            parkDistance = 12.0,
        },
    },
}

-- ============================================================================
-- SECURITY ZONE SCENARIOS — ENHANCED
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- ALERT LEVEL SYSTEM
-- Guards progress through states: patrol → suspicious → alert → combat.
-- Each level defines detection behavior and response.
-- ────────────────────────────────────────────────────────────────────────────

---@alias AlertLevel 'patrol'|'suspicious'|'alert'|'combat'

Config.AlertLevels = {
    patrol = {
        detectionMultiplier = 1.0,
        checkIntervalMs = 1500,
        transitionTo = 'suspicious',
    },
    suspicious = {
        detectionMultiplier = 1.3,
        checkIntervalMs = 800,
        durationMs = 12000,
        transitionTo = 'alert',
        decayTo = 'patrol',
        investigateSpeed = 1.2,
        speechOnEnter = 'GENERIC_HUMP',
    },
    alert = {
        detectionMultiplier = 1.6,
        checkIntervalMs = 500,
        durationMs = 25000,
        transitionTo = 'combat',
        decayTo = 'suspicious',
        searchSpeed = 2.0,
        speechOnEnter = 'GENERIC_INSULT_HIGH',
        radioPropagationMs = 2000,
    },
    combat = {
        detectionMultiplier = 2.0,
        checkIntervalMs = 300,
        durationMs = 60000,
        decayTo = 'alert',
        speechOnEnter = 'GENERIC_CURSE_HIGH',
    },
}

--- Numeric ordering for comparisons
Config.AlertLevelOrder = { patrol = 1, suspicious = 2, alert = 3, combat = 4 }

-- ────────────────────────────────────────────────────────────────────────────
-- STEALTH DETECTION SYSTEM
-- Modifiers that affect how easily the player is detected.
-- ────────────────────────────────────────────────────────────────────────────

Config.Stealth = {
    enabled = true,

    --- Posture modifiers (multiplied against detection range)
    crouchModifier = 0.5,
    sprintModifier = 1.8,
    walkModifier = 0.85,
    stillModifier = 0.4,

    --- Cover: if guard has no LOS to player, range is greatly reduced
    behindCoverModifier = 0.3,

    --- Instant-alert noise events (detected within range regardless of LOS)
    gunshotDetectionRange = 80.0,
    explosionDetectionRange = 120.0,
    vehicleHornRange = 40.0,

    --- Time-of-day visibility
    nightModifier = 0.65,
    dayModifier = 1.0,
    nightStartHour = 22,
    nightEndHour = 5,

    --- Suspicion accumulator: builds while player is visible, decays while hidden.
    --- Reaching threshold escalates the alert level.
    suspicionBuildRate = 15.0,
    suspicionDecayRate = 5.0,
    suspicionThreshold = 100.0,
}

-- ────────────────────────────────────────────────────────────────────────────
-- GUARD ARCHETYPES
-- ────────────────────────────────────────────────────────────────────────────

Config.GuardArchetypes = {
    {
        id = 'rent_a_cop',
        label = 'Security Guard',
        pedModels = { `s_m_m_security_01`, `s_m_m_bouncer_01` },
        health = 150, armor = 0, accuracy = 25,
        combatAbility = 0, combatMovement = 1, combatRange = 1,
        combatAttributes = { [0] = true, [46] = true },
        fleeHealthThreshold = 0.25,
        weapons = { `WEAPON_PISTOL`, `WEAPON_NIGHTSTICK` },
        idleScenarios = { 'WORLD_HUMAN_GUARD_STAND', 'WORLD_HUMAN_CLIPBOARD', 'WORLD_HUMAN_SMOKING' },
        routineScenarios = { 'WORLD_HUMAN_STAND_MOBILE', 'WORLD_HUMAN_DRINKING', 'WORLD_HUMAN_SMOKING' },
        speechPatrol = 'CHAT_STATE', speechSuspicious = 'GENERIC_HUMP',
        speechAlert = 'GENERIC_INSULT_MED', speechCombat = 'GENERIC_CURSE_MED',
    },
    {
        id = 'private_security',
        label = 'Private Security',
        pedModels = { `s_m_m_armoured_01`, `s_m_m_armoured_02`, `mp_m_securoguard_01` },
        health = 250, armor = 50, accuracy = 45,
        combatAbility = 1, combatMovement = 2, combatRange = 2,
        combatAttributes = { [0] = true, [1] = true, [2] = true, [3] = true, [46] = true },
        fleeHealthThreshold = nil,
        weapons = { `WEAPON_PISTOL`, `WEAPON_SMG`, `WEAPON_PUMPSHOTGUN` },
        idleScenarios = { 'WORLD_HUMAN_GUARD_STAND', 'WORLD_HUMAN_GUARD_PATROL' },
        routineScenarios = { 'WORLD_HUMAN_GUARD_STAND', 'WORLD_HUMAN_SMOKING' },
        speechPatrol = 'CHAT_STATE', speechSuspicious = 'GENERIC_INSULT_MED',
        speechAlert = 'GENERIC_INSULT_HIGH', speechCombat = 'GENERIC_CURSE_HIGH',
    },
    {
        id = 'pmc',
        label = 'PMC Operator',
        pedModels = { `s_m_m_marine_01`, `s_m_m_marine_02`, `s_m_y_marine_01` },
        health = 350, armor = 100, accuracy = 65,
        combatAbility = 2, combatMovement = 2, combatRange = 2,
        combatAttributes = { [0] = true, [1] = true, [2] = true, [3] = true, [5] = true, [20] = true, [46] = true },
        fleeHealthThreshold = nil,
        weapons = { `WEAPON_CARBINERIFLE`, `WEAPON_SMG`, `WEAPON_COMBATPISTOL` },
        idleScenarios = { 'WORLD_HUMAN_GUARD_STAND_ARMY', 'WORLD_HUMAN_GUARD_PATROL' },
        routineScenarios = { 'WORLD_HUMAN_GUARD_STAND_ARMY' },
        speechPatrol = 'CHAT_STATE', speechSuspicious = 'GENERIC_INSULT_MED',
        speechAlert = 'GENERIC_INSULT_HIGH', speechCombat = 'GENERIC_WAR_CRY',
    },
    {
        id = 'elite',
        label = 'Elite Operative',
        pedModels = { `s_m_y_marine_03`, `s_m_m_highsec_01`, `s_m_m_fiboffice_01` },
        health = 500, armor = 200, accuracy = 80,
        combatAbility = 2, combatMovement = 3, combatRange = 2,
        combatAttributes = { [0] = true, [1] = true, [2] = true, [3] = true, [5] = true, [13] = true, [20] = true, [21] = true, [46] = true },
        fleeHealthThreshold = nil,
        weapons = { `WEAPON_SPECIALCARBINE`, `WEAPON_COMBATMG`, `WEAPON_HEAVYPISTOL` },
        idleScenarios = { 'WORLD_HUMAN_GUARD_STAND' },
        routineScenarios = {},
        speechPatrol = 'CHAT_STATE', speechSuspicious = 'GENERIC_INSULT_HIGH',
        speechAlert = 'GENERIC_CURSE_HIGH', speechCombat = 'GENERIC_WAR_CRY',
    },
}

-- ────────────────────────────────────────────────────────────────────────────
-- ZONE DEFINITIONS
-- ────────────────────────────────────────────────────────────────────────────

Config.SecurityZones = {
    {
        id = 'warehouse_south',
        label = 'South Docks Warehouse',
        zone = {
            type = 'sphere',
            coords = vec3(1065.0, -3183.0, 5.9),
            radius = 55.0,
        },
        defaultArchetype = 'private_security',
        detectionRadius = 30.0,
        warningMessage = 'You are trespassing on private property!',

        --- Alert overrides
        alertOverrides = { suspicionThresholdMult = 1.0 },

        --- Access systems
        access = {
            disguises = {
                {
                    label = 'Security Uniform',
                    components = { [3] = { 0, 0 }, [11] = { 31, 0 } },
                },
            },
            keycards = {
                { item = 'warehouse_keycard', consumeOnUse = false, grantDurationMs = 0 },
            },
            vehicles = {
                { models = { `stockade`, `boxville` }, mustBeDriver = true },
            },
            bypassAlertLevel = 'alert',
        },

        posts = {
            { coords = vec4(1065.0, -3183.0, 5.9, 270.0), scenario = 'WORLD_HUMAN_GUARD_STAND' },
            { coords = vec4(1072.0, -3190.0, 5.9, 180.0), scenario = 'WORLD_HUMAN_GUARD_STAND' },
        },

        patrols = {
            {
                waypoints = {
                    vec4(1055.0, -3175.0, 5.9, 0.0),
                    vec4(1075.0, -3175.0, 5.9, 90.0),
                    vec4(1075.0, -3195.0, 5.9, 180.0),
                    vec4(1055.0, -3195.0, 5.9, 270.0),
                },
                speed = 1.0,
                routineSteps = {
                    { scenario = 'WORLD_HUMAN_GUARD_STAND', durationMs = 5000 },
                    { scenario = 'WORLD_HUMAN_SMOKING', durationMs = 8000,
                      coords = vec4(1060.0, -3180.0, 5.9, 90.0) },
                },
            },
        },

        reinforcements = {
            enabled = true, maxWaves = 2,
            waves = {
                { delayMs = 15000, count = 3, archetypeId = 'private_security', spawnRadius = 40.0 },
                { delayMs = 45000, count = 2, archetypeId = 'pmc', spawnRadius = 50.0 },
            },
        },

        objectives = {
            {
                id = 'warehouse_safe', label = 'Crack Safe', icon = 'fas fa-vault',
                type = 'safe', coords = vec4(1068.0, -3186.0, 5.9, 90.0),
                prop = `prop_ld_int_safe_01`,
                requiredItem = 'lockpick', consumeRequired = true,
                maxAlertLevel = 'suspicious', interactDurationMs = 12000,
                animDict = 'anim@heists@ornate_bank@grab_cash_heist', animName = 'grab_cash_a',
                cooldownMs = 1800000,
                lootTable = {
                    { item = 'cash_roll', min = 2, max = 5, chance = 1.0 },
                    { item = 'gold_chain', min = 0, max = 2, chance = 0.3 },
                    { item = 'rolex', min = 0, max = 1, chance = 0.1 },
                },
            },
            {
                id = 'warehouse_laptop', label = 'Hack Laptop', icon = 'fas fa-laptop',
                type = 'computer', coords = vec4(1070.0, -3182.0, 6.9, 270.0),
                prop = `prop_laptop_01a`,
                requiredItem = 'usb_hack', consumeRequired = true,
                maxAlertLevel = 'alert', interactDurationMs = 8000,
                animDict = 'anim@heists@prison_heiststation@cop_reactions', animName = 'yournotsupposedtobehere',
                cooldownMs = 2400000,
                lootTable = {
                    { item = 'crypto_key', min = 1, max = 3, chance = 0.8 },
                    { item = 'bank_schema', min = 0, max = 1, chance = 0.2 },
                },
            },
        },
    },

    {
        id = 'military_checkpoint',
        label = 'Military Checkpoint',
        zone = {
            type = 'sphere',
            coords = vec3(-2358.0, 3249.0, 32.8),
            radius = 45.0,
        },
        defaultArchetype = 'pmc',
        detectionRadius = 40.0,
        warningMessage = 'RESTRICTED AREA. Lethal force is authorized.',

        alertOverrides = { suspicionThresholdMult = 0.5 },

        access = {
            keycards = {
                { item = 'military_clearance', consumeOnUse = false, grantDurationMs = 300000 },
            },
            vehicles = {
                { models = { `barracks`, `crusader` }, mustBeDriver = false },
            },
            bypassAlertLevel = 'suspicious',
        },

        posts = {
            { coords = vec4(-2358.0, 3249.0, 32.8, 140.0), scenario = 'WORLD_HUMAN_GUARD_STAND_ARMY', archetypeOverride = 'elite' },
            { coords = vec4(-2362.0, 3245.0, 32.8, 200.0), scenario = 'WORLD_HUMAN_GUARD_STAND_ARMY' },
        },

        patrols = {
            {
                waypoints = {
                    vec4(-2350.0, 3255.0, 32.8, 0.0),
                    vec4(-2370.0, 3255.0, 32.8, 270.0),
                    vec4(-2370.0, 3240.0, 32.8, 180.0),
                    vec4(-2350.0, 3240.0, 32.8, 90.0),
                },
                speed = 1.0,
            },
        },

        reinforcements = {
            enabled = true, maxWaves = 3,
            waves = {
                { delayMs = 8000, count = 4, archetypeId = 'pmc', spawnRadius = 35.0 },
                { delayMs = 25000, count = 3, archetypeId = 'elite', spawnRadius = 40.0 },
                { delayMs = 50000, count = 2, archetypeId = 'elite', spawnRadius = 45.0 },
            },
        },

        objectives = {
            {
                id = 'military_intel', label = 'Download Intel', icon = 'fas fa-satellite-dish',
                type = 'computer', coords = vec4(-2355.0, 3247.0, 33.8, 180.0),
                requiredItem = 'military_usb', consumeRequired = true,
                maxAlertLevel = 'suspicious', interactDurationMs = 15000,
                animDict = 'mp_arresting', animName = 'a_uncuff',
                cooldownMs = 3600000,
                lootTable = {
                    { item = 'military_intel', min = 1, max = 1, chance = 1.0 },
                    { item = 'weapon_blueprint', min = 0, max = 1, chance = 0.15 },
                },
            },
        },
    },
}

-- ============================================================================
-- VEHICLE BUYER ARCHETYPES
-- High risk / high reward buyers that approach in vehicles.
-- ============================================================================

---@class VehicleBuyerArchetype
---@field id string
---@field label string
---@field pedModels integer[]
---@field vehicles integer[] -- vehicle model hashes
---@field baseWeight number
---@field minReputation number
---@field occupants integer[] -- {min, max} peds in the vehicle
---@field quantityRange integer[] -- {min, max} items per deal
---@field priceMultiplier number
---@field patienceMs integer -- how long driver waits after parking
---@field behavior string -- 'buy'|'robbery'|'supplier'|'undercover'

Config.VehicleBuyerArchetypes = {
    {
        id = 'vehicle_bigbuyer',
        label = 'Big Buyer',
        pedModels = {
            `g_m_y_mexgang_01`,
            `g_m_y_famfor_01`,
            `g_m_m_armboss_01`,
            `a_m_y_business_03`,
        },
        vehicles = {
            `schafter2`,
            `oracle2`,
            `fugitive`,
            `tailgater`,
            `emperor2`,
        },
        baseWeight = 30,
        minReputation = 40,
        occupants = { 1, 2 },
        quantityRange = { 8, 15 },
        priceMultiplier = 1.4,
        patienceMs = 35000,
        haggleChance = 0.5,
        walkAwayThreshold = 0.30,
        behavior = 'buy',
    },
    {
        id = 'vehicle_undercover',
        label = 'Undercover',
        pedModels = {
            `s_m_y_cop_01`,
            `a_m_y_business_01`,
            `a_m_m_bevhills_02`,
        },
        vehicles = {
            `washington`,
            `stanier`,
            `fugitive`,
            `buffalo`,
        },
        baseWeight = 15,
        minReputation = 0,
        occupants = { 1, 2 },
        quantityRange = { 1, 1 },
        priceMultiplier = 1.0,
        patienceMs = 40000,
        haggleChance = 0.1,
        walkAwayThreshold = 0.50,
        behavior = 'undercover',
        --- Dispatch notification interval (ms)
        dispatchIntervalMs = 20000,
    },
    {
        id = 'vehicle_robbery',
        label = 'Robbery',
        pedModels = {
            `g_m_y_ballasout_01`,
            `g_m_y_pologoon_01`,
            `g_m_y_pologoon_02`,
            `g_m_y_salvagoon_01`,
        },
        vehicles = {
            `buccaneer`,
            `manana`,
            `emperor`,
            `tornado`,
            `primo`,
        },
        baseWeight = 15,
        minReputation = 15,
        occupants = { 2, 3 },
        quantityRange = { 0, 0 },
        priceMultiplier = 0.0,
        patienceMs = 15000,
        behavior = 'robbery',
        --- Weapons given to occupants during robbery
        weapons = { `WEAPON_PISTOL`, `WEAPON_MICROSMG` },
    },
    {
        id = 'vehicle_supplier',
        label = 'Supplier',
        pedModels = {
            `g_m_m_mexboss_01`,
            `g_m_m_mexboss_02`,
            `a_m_y_business_02`,
            `g_m_m_chicold_01`,
        },
        vehicles = {
            `dubsta`,
            `baller`,
            `cavalcade`,
            `granger`,
        },
        baseWeight = 10,
        minReputation = 60,
        occupants = { 1, 2 },
        quantityRange = { 10, 25 },
        priceMultiplier = 0.7,
        patienceMs = 30000,
        behavior = 'supplier',
    },
}

-- ────────────────────────────────────────────────────────────────────────────
-- PER-ZONE VEHICLE BUYER SETTINGS
-- Added as a field to each DrugZone config above.
-- ────────────────────────────────────────────────────────────────────────────

Config.VehicleBuyerDefaults = {
    maxVehicles = 1,             -- max simultaneous vehicle buyers per zone
    cooldownMs = 45000,          -- min time between vehicle spawns
    spawnDistance = 80.0,        -- how far away vehicles spawn (road node search)
    parkDistance = 15.0,         -- how close to zone center they park
    enabled = true,
}

return Config
