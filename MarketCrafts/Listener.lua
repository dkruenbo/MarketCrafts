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
    -- Pattern: itemID (digits), profName (no commas — [^,]+), itemName (greedy, captures rest).
    -- Placing itemName last means it safely absorbs any commas in item names like
    -- "Plans: Arcanite Champion" without breaking the parse. profName is validated
    -- to contain no commas, so injecting one there would just fail the match silently.
    local itemIDStr, profName, itemName = body:match("^(%d+),([^,]+),(.+)$")
    if not itemIDStr then return nil end
    local itemID = tonumber(itemIDStr)
    if not itemID or itemID <= 0 then return nil end
    return {
        itemID   = itemID,
        profName = profName,
        itemName = itemName,
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
        -- Silent on error: BugGrabber will capture it
    elseif string.sub(msg, 1, #PREFIX_R) == PREFIX_R then
        local ok, err = pcall(function()
            local data = ParseRemove(msg, sender)
            if data then
                MC.Cache:Remove(data.seller, data.itemID)
            end
        end)
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
