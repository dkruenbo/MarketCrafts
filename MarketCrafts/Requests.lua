-- Requests.lua — F7: Buyer request board (WTB posts)
-- Mirrors the architecture of Cache.lua but is keyed by buyer name + itemID.
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
-- requests[sender][itemID] = { buyer, itemID, itemName, note, itemIcon, receivedAt }
local requests     = {}
local pendingIcons = {}

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function MC.Requests:AddOrUpdate(entry)
    local sender = entry.buyer
    if not sender or sender == "" then return end
    -- Respect blocklist
    if MC.db.char.blocklist[sender] then return end

    requests[sender] = requests[sender] or {}
    local buyerTable = requests[sender]
    local now = time()

    -- Update if already present
    if buyerTable[entry.itemID] then
        buyerTable[entry.itemID].receivedAt = now
        buyerTable[entry.itemID].note       = entry.note
        if entry.itemName then buyerTable[entry.itemID].itemName = entry.itemName end
        MC.UI:RefreshRequests()
        return
    end

    -- Enforce per-buyer cap
    local count = 0
    for _ in pairs(buyerTable) do count = count + 1 end
    if count >= MAX_PER_BUYER then return end

    -- Store entry
    buyerTable[entry.itemID] = {
        buyer      = sender,
        itemID     = entry.itemID,
        itemName   = entry.itemName,
        note       = entry.note,
        itemIcon   = nil,
        receivedAt = now,
        _simulated = entry._simulated or nil,
    }

    -- Async icon resolution (same pattern as Cache.lua)
    if entry.itemID and entry.itemID > 0 then
        local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(entry.itemID)
        if icon then
            buyerTable[entry.itemID].itemIcon = icon
            if name then buyerTable[entry.itemID].itemName = name end
        else
            pendingIcons[entry.itemID] = true
            MC:ScheduleTimer(function()
                pendingIcons[entry.itemID] = nil
            end, 30)
        end
    end

    MC.UI:RefreshRequests()
end

function MC.Requests:Remove(buyer, itemID)
    if requests[buyer] then
        requests[buyer][itemID] = nil
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
        for itemID, entry in pairs(buyerTable) do
            if now - entry.receivedAt > TTL then
                buyerTable[itemID] = nil
            end
        end
        if not next(buyerTable) then
            requests[sender] = nil
        end
    end
end

function MC.Requests:Enable()
    MC:ScheduleRepeatingTimer(Purge, 60)

    -- Resolve icons for requests received before GetItemInfo had the data
    MC:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID)
        if not pendingIcons[itemID] then return end
        local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
        if not icon then return end
        pendingIcons[itemID] = nil
        for _, buyerTable in pairs(requests) do
            if buyerTable[itemID] then
                buyerTable[itemID].itemIcon = icon
                if name then buyerTable[itemID].itemName = name end
            end
        end
        MC.UI:RefreshRequests()
    end)
end
