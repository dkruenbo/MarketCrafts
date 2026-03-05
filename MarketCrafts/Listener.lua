-- Listener.lua — M3: Inbound message parser
-- Listens to CHAT_MSG_CHANNEL for [MCR]-prefixed messages, parses them,
-- and feeds results into Cache. Also monitors CHAT_MSG_SYSTEM for throttle.
local AddonName, NS = ...
local MC = NS.MC
MC.Listener = {}

---------------------------------------------------------------------------
-- Wire protocol prefixes
---------------------------------------------------------------------------
local PREFIX_L = "[MCR]L:"
local PREFIX_R = "[MCR]R:"

---------------------------------------------------------------------------
-- Parsers
---------------------------------------------------------------------------
local function ParseListing(msg, sender)
    -- Strip prefix
    local body = string.sub(msg, #PREFIX_L + 1)
    -- F1: Try 4-field first: itemID, profName, itemName (comma-free), note (greedy remainder).
    -- Broadcasters strip commas from itemName before sending, so [^,]+ is safe for
    -- any message produced by this addon. The fallback 3-field pattern handles old
    -- clients or any edge-case item name that still contains commas.
    local itemIDStr, profName, itemName, note =
        body:match("^(%d+),([^,]+),([^,]+),(.+)$")
    if not itemIDStr then
        -- Fallback: 3-field format (no note, or itemName still contains commas)
        itemIDStr, profName, itemName = body:match("^(%d+),([^,]+),(.+)$")
        note = nil
    end
    if not itemIDStr then return nil end
    local itemID = tonumber(itemIDStr)
    if not itemID or itemID <= 0 then return nil end
    return {
        itemID   = itemID,
        profName = profName,
        itemName = itemName,
        note     = (note and note ~= "") and note or nil,
        seller   = sender,
    }
end

local function ParseRemove(msg, sender)
    local body = string.sub(msg, #PREFIX_R + 1)
    local itemID = tonumber(body)
    if not itemID or itemID <= 0 then return nil end
    return { itemID = itemID, seller = sender }
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
