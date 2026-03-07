-- Listener.lua — M3: Inbound message parser
-- Listens to CHAT_MSG_CHANNEL for [MCR]-prefixed messages, parses them,
-- and feeds results into Cache and Requests. Also monitors CHAT_MSG_SYSTEM for throttle.
local AddonName, NS = ...
local MC = NS.MC
MC.Listener = {}

---------------------------------------------------------------------------
-- Wire protocol prefixes
---------------------------------------------------------------------------
local PREFIX_L  = "[MCR]L:"
local PREFIX_R  = "[MCR]R:"
local PREFIX_Q  = "[MCR]Q:"   -- F7: buyer request (add/update)
local PREFIX_QR = "[MCR]QR:"  -- F7: buyer request remove
local PREFIX_SVR = "[MCR]SVR:" -- service remove (checked before SV — longer prefix)
local PREFIX_SV  = "[MCR]SV:"  -- service offer

---------------------------------------------------------------------------
-- Parsers
---------------------------------------------------------------------------
local function ParseListing(msg, sender)
    -- Strip prefix
    local body = string.sub(msg, #PREFIX_L + 1)
    -- F6: Try 5-field first: itemID, profName, itemName (comma-free), note (possibly empty), cdSeconds (digits).
    -- F1: If that fails, try 4-field: itemID, profName, itemName (comma-free), note (non-empty).
    -- Fallback: 3-field (pre-F1 clients, or itemName that still contains commas).
    local itemIDStr, profName, itemName, note, cdStr =
        body:match("^(%d+),([^,]+),([^,]+),([^,]*),(%d+)$")
    local cdSeconds = nil
    if itemIDStr then
        -- 5-field match succeeded; note may be empty string → normalise to nil
        cdSeconds = tonumber(cdStr)
    else
        -- Try 4-field
        itemIDStr, profName, itemName, note =
            body:match("^(%d+),([^,]+),([^,]+),(.+)$")
        if not itemIDStr then
            -- Fallback: 3-field format (no note, or itemName still contains commas)
            itemIDStr, profName, itemName = body:match("^(%d+),([^,]+),(.+)$")
            note = nil
        end
    end
    if not itemIDStr then return nil end
    local itemID = tonumber(itemIDStr)
    if not itemID or itemID <= 0 then return nil end
    return {
        itemID    = itemID,
        profName  = profName,
        itemName  = itemName,
        note      = (note and note ~= "") and note or nil,
        cdSeconds = cdSeconds,   -- F6: nil means no cooldown field sent
        seller    = sender,
    }
end

local function ParseRemove(msg, sender)
    local body = string.sub(msg, #PREFIX_R + 1)
    local itemID = tonumber(body)
    if not itemID or itemID <= 0 then return nil end
    return { itemID = itemID, seller = sender }
end

-- F7: Parse a buyer request.
-- Wire format: [MCR]Q:itemName[,note]   (itemName is comma-stripped on send)
-- Backward compat: old format [MCR]Q:itemID,itemName[,note] is also accepted.
local function ParseRequest(msg, sender)
    local body = string.sub(msg, #PREFIX_Q + 1)
    if not body or body == "" then return nil end
    -- Backward compat: if body starts with digits then comma, strip the
    -- leading itemID field (old clients sent itemID=0 which was non-functional).
    local afterID = body:match("^%d+,(.+)$")
    if afterID then body = afterID end
    -- 2-field: itemName (comma-free), note
    local itemName, note = body:match("^([^,]+),(.+)$")
    if not itemName then
        -- 1-field: itemName only
        itemName = body
        note = nil
    end
    if not itemName or itemName == "" then return nil end
    return {
        itemName = itemName,
        note     = (note and note ~= "") and note or nil,
        buyer    = sender,
    }
end

-- F7: Parse a buyer request removal.
-- Wire format: [MCR]QR:itemName
local function ParseRequestRemove(msg, sender)
    local body = string.sub(msg, #PREFIX_QR + 1)
    if not body or body == "" then return nil end
    -- Ignore legacy numeric-only removals (pre-fix clients sent itemID=0)
    if tonumber(body) then return nil end
    return { itemName = body, buyer = sender }
end

-- Parse a service offer.
-- Wire format: [MCR]SV:<serviceKey>[,<note>]
local function ParseService(msg, sender)
    local body = string.sub(msg, #PREFIX_SV + 1)
    if not body or body == "" then return nil end
    local serviceKey, note = body:match("^([^,]+),(.+)$")
    if not serviceKey then
        serviceKey = body
        note = nil
    end
    -- Validate: only accept known service keys
    local valid = false
    for _, def in ipairs(MC.Services.DEFS) do
        if def.key == serviceKey then valid = true; break end
    end
    if not valid then return nil end
    return {
        seller     = sender,
        serviceKey = serviceKey,
        note       = (note and note ~= "") and note or nil,
    }
end

-- Parse a service removal.
-- Wire format: [MCR]SVR:<serviceKey>
local function ParseServiceRemove(msg, sender)
    local body = string.sub(msg, #PREFIX_SVR + 1)
    if not body or body == "" then return nil end
    -- Accept only the key part; strip any trailing whitespace
    local key = body:match("^([^,%s]+)")
    if not key then return nil end
    return { seller = sender, serviceKey = key }
end
    local body = string.sub(msg, #PREFIX_QR + 1)
    if not body or body == "" then return nil end
    -- Ignore legacy numeric-only removals (pre-fix clients sent itemID=0)
    if tonumber(body) then return nil end
    return { itemName = body, buyer = sender }
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
function MC.Listener:OnChatMsgChannel(msg, sender, _, _, _, _, _, _, channelName)
    -- Defensive: channelName may arrive as a number or nil in some TBC builds.
    -- Coerce to string so :find() never errors.
    channelName = tostring(channelName or "")

    -- Ignore if this is not one of our MCMarket channels
    if not channelName:find("^MCMarket") then return end
    if not msg or string.sub(msg, 1, 5) ~= "[MCR]" then return end

    -- Skip own messages (handle both "Name" and "Name-Realm" formats)
    local myName = UnitName("player")
    if sender == myName or sender:match("^(.-)%-") == myName then return end

    if string.sub(msg, 1, #PREFIX_L) == PREFIX_L then
        local ok, err = pcall(function()
            local entry = ParseListing(msg, sender)
            if entry then
                MC.Cache:AddOrUpdate(entry)
            end
        end)
        if not ok and MC.debugMode then
            print("MCR ERROR (L):", err, "| msg:", msg, "| sender:", sender)
        end
    elseif string.sub(msg, 1, #PREFIX_R) == PREFIX_R then
        local ok, err = pcall(function()
            local data = ParseRemove(msg, sender)
            if data then
                MC.Cache:Remove(data.seller, data.itemID)
            end
        end)
        if not ok and MC.debugMode then
            print("MCR ERROR (R):", err, "| msg:", msg, "| sender:", sender)
        end
    elseif string.sub(msg, 1, #PREFIX_QR) == PREFIX_QR then
        -- F7: buyer request remove — check QR before Q (QR is a longer prefix)
        local ok, err = pcall(function()
            local data = ParseRequestRemove(msg, sender)
            if data then
                MC.Requests:Remove(data.buyer, data.itemName)
            end
        end)
        if not ok and MC.debugMode then
            print("MCR ERROR (QR):", err, "| msg:", msg, "| sender:", sender)
        end
    elseif string.sub(msg, 1, #PREFIX_Q) == PREFIX_Q then
        -- F7: buyer request add/update
        local ok, err = pcall(function()
            local entry = ParseRequest(msg, sender)
            if entry then
                MC.Requests:AddOrUpdate(entry)
            end
        end)
        if not ok and MC.debugMode then
            print("MCR ERROR (Q):", err, "| msg:", msg, "| sender:", sender)
        end
    elseif string.sub(msg, 1, #PREFIX_SVR) == PREFIX_SVR then
        -- service remove — check SVR before SV (SVR is the longer prefix)
        local ok, err = pcall(function()
            local data = ParseServiceRemove(msg, sender)
            if data then
                MC.Services:CacheRemove(data.seller, data.serviceKey)
            end
        end)
        if not ok and MC.debugMode then
            print("MCR ERROR (SVR):", err, "| msg:", msg, "| sender:", sender)
        end
    elseif string.sub(msg, 1, #PREFIX_SV) == PREFIX_SV then
        -- service offer
        local ok, err = pcall(function()
            local entry = ParseService(msg, sender)
            if entry then
                MC.Services:CacheAdd(entry)
            end
        end)
        if not ok and MC.debugMode then
            print("MCR ERROR (SV):", err, "| msg:", msg, "| sender:", sender)
        end
    end
end

---------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------
function MC.Listener:Enable()
    MC:RegisterEvent("CHAT_MSG_CHANNEL", function(_, ...)
        MC.Listener:OnChatMsgChannel(...)
    end)
    -- Also handle CHAT_MSG_SYSTEM to detect spam-filter throttle
    MC:RegisterEvent("CHAT_MSG_SYSTEM", function(_, msg)
        if msg and (msg:find("throttled") or msg:find("spam") or msg:find("flooded")) then
            MC.Broadcast:ClearQueue()
        end
    end)
end

function MC.Listener:Disable()
    MC:UnregisterEvent("CHAT_MSG_CHANNEL")
    MC:UnregisterEvent("CHAT_MSG_SYSTEM")
end
