-- ChatFilter.lua — M3: Suppress [MCR] messages from chat frames
-- This is the simplest file in the addon. Its only job is returning true
-- for [MCR]-prefixed messages so they never appear in any chat frame.
-- No parsing, no cache writes, no globals, no closures over secure frames.
local AddonName, NS = ...
local MC = NS.MC
MC.ChatFilter = {}

local function MarketCraftsFilter(self, event, msg, author, ...)
    if msg and string.sub(msg, 1, 5) == "[MCR]" then
        return true  -- suppress: do not show in any chat frame
    end
    return false, msg, author, ...
end

function MC.ChatFilter:Enable()
    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", MarketCraftsFilter)
end

function MC.ChatFilter:Disable()
    ChatFrame_RemoveMessageEventFilter("CHAT_MSG_CHANNEL", MarketCraftsFilter)
end
