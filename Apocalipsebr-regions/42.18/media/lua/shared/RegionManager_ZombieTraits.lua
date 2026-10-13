require "RegionManager_Config"

-- Pure trait selection shared by clients. No engine RNG or per-zombie commands.
RegionManager.ZombieTraits = RegionManager.ZombieTraits or {}
local Traits = RegionManager.ZombieTraits
Traits.VERSION = 1
Traits.Keys = {
    "navigationChance", "hawkVisionChance", "normalVisionChance",
    "poorVisionChance", "badVisionChance", "randomVisionChance",
    "goodHearingChance", "pinpointHearingChance", "normalHearingChance",
    "poorHearingChance", "badHearingChance", "randomHearingChance"
}

function Traits.roll(identity, property)
    -- Explicit floating-point constants avoid 32-bit integer overflow in test
    -- Lua runtimes; multiplication remains exact within the Lua double range.
    local hash = 17.0
    local input = "regions-traits-v1:" .. tostring(identity) .. ":" .. property
    for i = 1, #input do
        hash = (hash * 131.0 + string.byte(input, i)) % 2147483647.0
    end
    -- Mix again so adjacent outfit variants don't produce adjacent percentiles.
    hash = (hash * 16807.0) % 2147483647.0
    return math.floor(hash % 100.0)
end

local function canonicalOutfit(outfit, female)
    if not outfit or outfit == 0 then return nil end
    -- Hat loss changes bit 15 without changing the zombie's outfit identity.
    local normalized = outfit % 4294967296.0
    if math.floor(normalized / 32768) % 2 == 1 then normalized = normalized - 32768 end
    return string.format("%.0f_%d", normalized, female)
end

function Traits.identity(zombie)
    local assigned = zombie:getModData().Apocalipse_TSY_AssignedPID
    if assigned then
        -- Normalize existing numeric outfit-based AssignedPID values as well.
        local outfit, female = tostring(assigned):match("^(-?%d+)_(%d)$")
        if outfit then return canonicalOutfit(tonumber(outfit), tonumber(female)) end
        return tostring(assigned)
    end
    return canonicalOutfit(zombie:getPersistentOutfitID(), zombie:isFemale() and 1 or 0)
end

function Traits.aggregate(zones, x, y)
    local chances, controlled = {}, false
    for _, zone in pairs(zones or {}) do
        local b = zone.bounds
        if zone.enabled ~= false and b and x >= b.minX and x <= b.maxX
            and y >= b.minY and y <= b.maxY then
            for _, key in ipairs(Traits.Keys) do
                local value = zone.zombieTraits and zone.zombieTraits[key]
                if type(value) == "number" then
                    chances[key] = math.max(chances[key] or 0, math.max(0, math.min(100, value)))
                    controlled = true
                end
            end
        end
    end
    return chances, controlled
end

function Traits.rulesKey(zones)
    local entries = {}
    for _, zone in pairs(zones or {}) do
        local values = {}
        for _, key in ipairs(Traits.Keys) do
            local value = zone.zombieTraits and zone.zombieTraits[key]
            if type(value) == "number" then values[#values + 1] = key .. "=" .. tostring(value) end
        end
        if #values > 0 and zone.bounds then
            local b = zone.bounds
            entries[#entries + 1] = tostring(zone.id) .. ":" .. tostring(zone.enabled ~= false)
                .. ":" .. b.minX .. ":" .. b.minY .. ":" .. b.maxX .. ":" .. b.maxY
                .. ":" .. table.concat(values, ";")
        end
    end
    table.sort(entries)
    return "v" .. Traits.VERSION .. ":" .. table.concat(entries, "|")
end

local function concrete(identity, property, setting)
    if setting == 4 then return Traits.roll(identity, property .. ":category") % 3 + 1 end
    if setting == 5 then return Traits.roll(identity, property .. ":category") % 2 + 2 end
    return setting
end

function Traits.cognition(identity, chances, defaults)
    if chances.navigationChance ~= nil then
        return Traits.roll(identity, "cognition") < chances.navigationChance
    end
    if defaults.cognition == 4 then
        return Traits.roll(identity, "cognition") < defaults.doorOpening
    end
    return defaults.cognition == 1
end

function Traits.sense(identity, property, chances, defaults)
    local best, normal, poor, random
    if property == "sight" then
        best = chances.hawkVisionChance or 0
        normal = chances.normalVisionChance or 0
        poor = math.max(chances.poorVisionChance or 0, chances.badVisionChance or 0)
        random = chances.randomVisionChance or 0
    else
        best = math.max(chances.pinpointHearingChance or 0, chances.goodHearingChance or 0)
        normal = chances.normalHearingChance or 0
        poor = math.max(chances.poorHearingChance or 0, chances.badHearingChance or 0)
        random = chances.randomHearingChance or 0
    end
    -- Retain existing max-chance/priority semantics. One concrete category is
    -- selected; conflicting booleans are never sent to the application layer.
    local roll = Traits.roll(identity, property)
    if roll < best then return 1 end
    if roll < normal then return 2 end
    if roll < poor then return 3 end
    if roll < random then return concrete(identity, property, 4) end
    return concrete(identity, property, defaults[property])
end

return Traits
