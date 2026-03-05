-- Requests.lua — F7: Buyer request board (WTB posts)
-- Mirrors the architecture of Cache.lua but is keyed by buyer name + itemName.
-- Wire types handled by Listener.lua: [MCR]Q: (add/update) and [MCR]QR: (remove).
local AddonName, NS = ...
local MC = NS.MC
MC.Requests = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local TTL          = 1800   -- 30 minutes, matching listing TTL
local MAX_PER_BUYER = 3     -- hard cap on requests per buyer

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
-- requests[sender][nameKey] = { buyer, itemName, note, receivedAt }
-- nameKey = itemName:lower() for case-insensitive dedup
local requests = {}

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function MC.Requests:AddOrUpdate(entry)
    local sender = entry.buyer
    if not sender or sender == "" then return end
    if not entry.itemName or entry.itemName == "" then return end
    -- Respect blocklist
    if MC.db.char.blocklist[sender] then return end

    requests[sender] = requests[sender] or {}
    local buyerTable = requests[sender]
    local now = time()
    local nameKey = entry.itemName:lower()

    -- Update if already present
    if buyerTable[nameKey] then
        buyerTable[nameKey].receivedAt = now
        buyerTable[nameKey].note       = entry.note
        buyerTable[nameKey].itemName   = entry.itemName
        MC.UI:RefreshRequests()
        return
    end

    -- Enforce per-buyer cap
    local count = 0
    for _ in pairs(buyerTable) do count = count + 1 end
    if count >= MAX_PER_BUYER then return end

    -- Store entry
    buyerTable[nameKey] = {
        buyer      = sender,
        itemName   = entry.itemName,
        note       = entry.note,
        receivedAt = now,
    }

    MC.UI:RefreshRequests()
end

function MC.Requests:Remove(buyer, itemName)
    if not itemName or itemName == "" then return end
    local nameKey = itemName:lower()
    if requests[buyer] then
        requests[buyer][nameKey] = nil
        if not next(requests[buyer]) then
            requests[buyer] = nil
        end
    end
    MC.UI:RefreshRequests()
end

-- Returns a flat, sorted, filtered list of non-expired, non-blocked requests.
function MC.Requests:GetVisible(filter)
    local now = time()
    filter = filter or ""
    local result = {}
    for _, buyerTable in pairs(requests) do
        for _, entry in pairs(buyerTable) do
            if now - entry.receivedAt <= TTL
               and not MC.db.char.blocklist[entry.buyer] then
                if filter == ""
                   or (entry.itemName and entry.itemName:lower():find(filter, 1, true))
                   or (entry.note and entry.note:lower():find(filter, 1, true))
                   or entry.buyer:lower():find(filter, 1, true) then
                    table.insert(result, entry)
                end
            end
        end
    end
    -- Most recent first
    table.sort(result, function(a, b) return a.receivedAt > b.receivedAt end)
    return result
end

-- Returns total number of non-expired request entries for status display.
function MC.Requests:GetCount()
    local now = time()
    local n = 0
    for _, buyerTable in pairs(requests) do
        for _, entry in pairs(buyerTable) do
            if now - entry.receivedAt <= TTL then n = n + 1 end
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Purge + Enable
---------------------------------------------------------------------------
local function Purge()
    local now = time()
    for sender, buyerTable in pairs(requests) do
        for nameKey, entry in pairs(buyerTable) do
            if now - entry.receivedAt > TTL then
                buyerTable[nameKey] = nil
            end
        end
        if not next(buyerTable) then
            requests[sender] = nil
        end
    end
end

function MC.Requests:Enable()
    MC:ScheduleRepeatingTimer(Purge, 60)
    -- No GET_ITEM_INFO_RECEIVED needed — requests are name-based, no itemID to resolve.
end
