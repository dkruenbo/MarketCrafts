-- Cache.lua — M5: In-memory peer listing cache with TTL, rate limiting,
-- validation, blocklist, and async icon resolution.
local AddonName, NS = ...
local MC = NS.MC
MC.Cache = {}

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------

-- listings[seller][itemID] = entry
local listings    = {}
-- rateTracker[sender] = { count, windowStart }
local rateTracker = {}
-- pendingIcons[itemID] = true — waiting for GET_ITEM_INFO_RECEIVED
local pendingIcons = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local TTL          = 1800  -- 30 minutes
local RATE_LIMIT   = 10    -- messages per minute per sender
local MAX_LISTINGS = 5

---------------------------------------------------------------------------
-- Add / Remove
---------------------------------------------------------------------------

-- Called by Listener after parsing a valid [MCR]L: message
function MC.Cache:AddOrUpdate(entry)
    local sender = entry.seller

    -- Blocklist check
    if MC.db.char.blocklist[sender] then return end

    -- Rate limit check
    local now = time()
    local rt = rateTracker[sender]
    if rt then
        if now - rt.windowStart < 60 then
            if rt.count >= RATE_LIMIT then return end  -- at or over limit
            rt.count = rt.count + 1
        else
            rateTracker[sender] = { count = 1, windowStart = now }
        end
    else
        rateTracker[sender] = { count = 1, windowStart = now }
    end

    -- Enforce max 5 listings per sender
    listings[sender] = listings[sender] or {}
    local senderListings = listings[sender]
    if not senderListings[entry.itemID] then
        local count = 0
        for _ in pairs(senderListings) do count = count + 1 end
        if count >= MAX_LISTINGS then return end
    end

    -- Store entry
    senderListings[entry.itemID] = {
        seller     = sender,
        itemID     = entry.itemID,
        itemName   = entry.itemName,
        profName   = entry.profName,
        itemIcon   = nil,
        receivedAt = now,
        _simulated = entry._simulated or nil,
    }

    -- Kick off async icon resolution
    local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(entry.itemID)
    if icon then
        senderListings[entry.itemID].itemIcon = icon
        if name then senderListings[entry.itemID].itemName = name end  -- locale-correct name
    else
        pendingIcons[entry.itemID] = true
        -- 30-second fallback: stop waiting, show question mark
        MC:ScheduleTimer(function()
            pendingIcons[entry.itemID] = nil
        end, 30)
    end

    MC.UI:RefreshBrowse()
end

function MC.Cache:Remove(seller, itemID)
    if listings[seller] then
        listings[seller][itemID] = nil
        if not next(listings[seller]) then
            listings[seller] = nil
        end
        MC.UI:RefreshBrowse()
    end
end

---------------------------------------------------------------------------
-- Query
---------------------------------------------------------------------------

-- Returns a flat list of non-expired, non-blocked entries matching the filter
function MC.Cache:GetVisible(filter, sortKey)
    local now = time()
    local result = {}
    for seller, sellerMap in pairs(listings) do
        if not MC.db.char.blocklist[seller] then
            for _, entry in pairs(sellerMap) do
                if now - entry.receivedAt <= TTL then
                    if filter == "" or filter == nil
                        or entry.itemName:lower():find(filter, 1, true)
                        or entry.profName:lower():find(filter, 1, true)
                        or entry.seller:lower():find(filter, 1, true)
                    then
                        table.insert(result, entry)
                    end
                end
            end
        end
    end
    sortKey = sortKey or "itemName"
    table.sort(result, function(a, b) return (a[sortKey] or "") < (b[sortKey] or "") end)
    return result
end

---------------------------------------------------------------------------
-- Blocklist
---------------------------------------------------------------------------
function MC.Cache:Ignore(name)
    MC.db.char.blocklist[name] = true
    MC.UI:RefreshBrowse()
end

function MC.Cache:Unignore(name)
    MC.db.char.blocklist[name] = nil
    MC.UI:RefreshBrowse()
end

---------------------------------------------------------------------------
-- Purge expired entries (every 5 min)
---------------------------------------------------------------------------
local function PurgeExpired()
    local now = time()
    for seller, sellerMap in pairs(listings) do
        for itemID, entry in pairs(sellerMap) do
            if now - entry.receivedAt > TTL then
                sellerMap[itemID] = nil
            end
        end
        if not next(sellerMap) then
            listings[seller] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Async icon resolution
---------------------------------------------------------------------------
function MC.Cache:OnGetItemInfoReceived(event, itemID)
    if not pendingIcons[itemID] then return end
    local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    if icon then
        pendingIcons[itemID] = nil
        -- Backfill icon into all cached entries for this itemID
        for _, sellerMap in pairs(listings) do
            if sellerMap[itemID] then
                sellerMap[itemID].itemIcon = icon
                if name then sellerMap[itemID].itemName = name end
            end
        end
        MC.UI:RefreshBrowse()
    end
end

---------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------
function MC.Cache:Enable()
    MC:ScheduleRepeatingTimer(PurgeExpired, 300)  -- every 5 minutes
    MC:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID)
        MC.Cache:OnGetItemInfoReceived(nil, itemID)
    end)
end

function MC.Cache:Disable()
    MC:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    -- Note: AceTimer-3.0 cancels all timers on OnEmbedDisable, so the
    -- purge repeating timer is cleaned up automatically.
end

--- Remove all entries flagged as _simulated. Returns count cleared.
function MC.Cache:ClearSimulated()
    local cleared = 0
    for seller, sellerMap in pairs(listings) do
        for itemID, entry in pairs(sellerMap) do
            if entry._simulated then
                sellerMap[itemID] = nil
                cleared = cleared + 1
            end
        end
        if not next(sellerMap) then
            listings[seller] = nil
        end
    end
    MC.UI:RefreshBrowse()
    return cleared
end

--- Debug helper: return total number of cached listings
function MC.Cache:GetCacheSize()
    local count = 0
    for _, sellerMap in pairs(listings) do
        for _ in pairs(sellerMap) do
            count = count + 1
        end
    end
    return count
end

--- F3: count distinct sellers with at least one non-expired, non-blocked listing
function MC.Cache:GetUniqueSellerCount()
    local count = 0
    local now = time()
    for seller, sellerMap in pairs(listings) do
        if not MC.db.char.blocklist[seller] then
            for _, entry in pairs(sellerMap) do
                if now - entry.receivedAt <= TTL then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count
end
