-- Services.lua — Class-gated service listings
-- Covers: portals (Mage), food & water (Mage), summons (Warlock), lockpick (Rogue).
-- Wire format: [MCR]SV:<serviceKey>[,<note>]   [MCR]SVR:<serviceKey>
local AddonName, NS = ...
local MC = NS.MC
MC.Services = {}

---------------------------------------------------------------------------
-- Service definitions
---------------------------------------------------------------------------

-- Portal spell IDs in TBC Classic 2.5.x → destination display name.
-- Alliance: Stormwind, Ironforge, Darnassus, Exodar, Shattrath
-- Horde:    Orgrimmar, Thunder Bluff, Undercity, Silvermoon, Shattrath
local PORTAL_SPELL_IDS = {
    [10059] = "Stormwind",
    [11416] = "Ironforge",
    [11419] = "Darnassus",
    [32266] = "Exodar",
    [35717] = "Shattrath",   -- Alliance Shattrath portal
    [11417] = "Orgrimmar",
    [11420] = "Thunder Bluff",
    [11418] = "Undercity",
    [32267] = "Silvermoon",
    [35716] = "Shattrath",   -- Horde Shattrath portal
}

-- Spell IDs used only for fetching service icons via GetSpellInfo.
-- The player does not need to know these spells; icon data is always available.
local SERVICE_ICON_SPELL = {
    portal   = 10059,  -- Portal: Stormwind
    conjure  = 5504,   -- Conjure Water
    summon   = 698,    -- Ritual of Summoning
    lockpick = 1804,   -- Pick Lock
}

-- Public ordered list of all service types.
-- class = class token from select(2, UnitClass("player"))
MC.Services.DEFS = {
    { key = "portal",   label = "Portals",              class = "MAGE"    },
    { key = "conjure",  label = "Food & Water",         class = "MAGE"    },
    { key = "summon",   label = "Ritual of Summoning",  class = "WARLOCK" },
    { key = "lockpick", label = "Lockpicking",          class = "ROGUE"   },
}

---------------------------------------------------------------------------
-- Internal service cache: services[sender][serviceKey] = entry
---------------------------------------------------------------------------
local services = {}
local TTL = 1800  -- 30 minutes (matches listing cache TTL)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function MC.Services:GetPlayerClass()
    local _, classToken = UnitClass("player")
    return classToken
end

-- Returns only the service defs that match the current player's class.
function MC.Services:GetAvailableDefs()
    local cls = MC.Services:GetPlayerClass()
    local result = {}
    for _, def in ipairs(MC.Services.DEFS) do
        if def.class == cls then
            table.insert(result, def)
        end
    end
    return result
end

function MC.Services:GetLabelForKey(key)
    for _, def in ipairs(MC.Services.DEFS) do
        if def.key == key then return def.label end
    end
    return key
end

-- Returns the icon texture path for a service type using GetSpellInfo.
-- Falls back to question-mark texture when spell data is unavailable.
function MC.Services:GetIconForKey(key)
    local spellID = SERVICE_ICON_SPELL[key]
    if spellID then
        local _, _, icon = GetSpellInfo(spellID)
        if icon then return icon end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Scan the player's spellbook for known portal spells.
-- Returns a sorted list of destination names the mage can portal to.
-- Uses spellbook iteration — the reliable API for TBC Classic 2.5.x.
function MC.Services:GetKnownPortalDestinations()
    local known = {}
    local seen  = {}
    for i = 1, GetNumSpellTabs() do
        local _, _, offset, numSpells = GetSpellTabInfo(i)
        for j = offset + 1, offset + numSpells do
            local spellType, spellID = GetSpellBookItemInfo(j, BOOKTYPE_SPELL)
            if spellType == "SPELL" then
                local dest = PORTAL_SPELL_IDS[spellID]
                if dest and not seen[dest] then
                    seen[dest] = true
                    table.insert(known, dest)
                end
            end
        end
    end
    table.sort(known)
    return known
end

-- Build an auto-generated note string from known portal destinations.
-- Returns nil if the player is not a mage or has no portal spells trained.
function MC.Services:BuildPortalNote()
    if MC.Services:GetPlayerClass() ~= "MAGE" then return nil end
    local dests = MC.Services:GetKnownPortalDestinations()
    if #dests == 0 then return nil end
    return table.concat(dests, ", ")
end

---------------------------------------------------------------------------
-- My Services management
---------------------------------------------------------------------------

local function FindMyService(serviceKey)
    for i, svc in ipairs(MC.db.char.myServices) do
        if svc.serviceKey == serviceKey then return i, svc end
    end
    return nil
end

-- Add or update a service listing (upsert by serviceKey).
-- Enforces class gate. Broadcasts if opted in and channel is active.
function MC.Services:Add(serviceKey, note)
    -- Class gate: only accept keys that belong to the player's class.
    local playerClass = MC.Services:GetPlayerClass()
    local validForClass = false
    for _, def in ipairs(MC.Services.DEFS) do
        if def.key == serviceKey and def.class == playerClass then
            validForClass = true
            break
        end
    end
    if not validForClass then return false end

    -- Normalise note: strip whitespace, cap at 80 chars, nil if blank.
    local cleanNote = (note and note:match("^%s*(.-)%s*$") or "")
    cleanNote = (cleanNote ~= "") and cleanNote:sub(1, 80) or nil

    local idx, existing = FindMyService(serviceKey)
    if idx then
        existing.note = cleanNote
    else
        table.insert(MC.db.char.myServices, { serviceKey = serviceKey, note = cleanNote })
    end

    if MC.db.char.settings.optedIn and MC.Channel:IsActive() then
        MC.Broadcast:SendService({ serviceKey = serviceKey, note = cleanNote })
    end
    MC.UI:RefreshMyServices()
    return true
end

function MC.Services:Remove(serviceKey)
    local idx = FindMyService(serviceKey)
    if not idx then return end
    table.remove(MC.db.char.myServices, idx)
    if MC.db.char.settings.optedIn then
        MC.Broadcast:SendServiceRemove(serviceKey)
    end
    -- Remove from local cache
    local player = UnitName("player")
    MC.Services:CacheRemove(player, serviceKey)
    MC.UI:RefreshMyServices()
end

---------------------------------------------------------------------------
-- Service cache — entries received from other players
---------------------------------------------------------------------------

function MC.Services:CacheAdd(entry)
    local sender = entry.seller
    if MC.db.char.blocklist[sender] then return end
    services[sender] = services[sender] or {}
    services[sender][entry.serviceKey] = {
        seller     = sender,
        serviceKey = entry.serviceKey,
        note       = entry.note or nil,
        receivedAt = time(),
        _simulated = entry._simulated or nil,
    }
    MC.UI:RefreshBrowseServices()
end

function MC.Services:CacheRemove(seller, serviceKey)
    if services[seller] then
        services[seller][serviceKey] = nil
        if not next(services[seller]) then
            services[seller] = nil
        end
        MC.UI:RefreshBrowseServices()
    end
end

-- Returns a flat list of non-expired, non-blocked service entries matching filter.
function MC.Services:GetVisible(filter)
    local now = time()
    local result = {}
    for seller, sellerMap in pairs(services) do
        if not MC.db.char.blocklist[seller] then
            for _, entry in pairs(sellerMap) do
                if now - entry.receivedAt <= TTL then
                    local label = MC.Services:GetLabelForKey(entry.serviceKey)
                    if not filter or filter == ""
                        or label:lower():find(filter, 1, true)
                        or seller:lower():find(filter, 1, true)
                        or (entry.note and entry.note:lower():find(filter, 1, true))
                    then
                        table.insert(result, entry)
                    end
                end
            end
        end
    end
    -- Sort by service type first, then seller name
    table.sort(result, function(a, b)
        if a.serviceKey ~= b.serviceKey then
            return a.serviceKey < b.serviceKey
        end
        return a.seller < b.seller
    end)
    return result
end

---------------------------------------------------------------------------
-- Purge expired entries (called by repeating timer every 5 minutes)
---------------------------------------------------------------------------
local function PurgeExpiredServices()
    local now = time()
    for seller, sellerMap in pairs(services) do
        for key, entry in pairs(sellerMap) do
            if now - entry.receivedAt > TTL then
                sellerMap[key] = nil
            end
        end
        if not next(sellerMap) then
            services[seller] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Simulated data removal (used by /mc sim clear)
---------------------------------------------------------------------------
function MC.Services:ClearSimulated()
    local cleared = 0
    for seller, sellerMap in pairs(services) do
        for key, entry in pairs(sellerMap) do
            if entry._simulated then
                sellerMap[key] = nil
                cleared = cleared + 1
            end
        end
        if not next(sellerMap) then
            services[seller] = nil
        end
    end
    MC.UI:RefreshBrowseServices()
    return cleared
end

---------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------
function MC.Services:Enable()
    MC:ScheduleRepeatingTimer(PurgeExpiredServices, 300)
end
