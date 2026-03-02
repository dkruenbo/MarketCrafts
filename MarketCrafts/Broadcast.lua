-- Broadcast.lua — M3: Outbound message queue with keep-alive and back-off
local AddonName, NS = ...
local MC = NS.MC
MC.Broadcast = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local KEEPALIVE_INTERVAL = 1200  -- 20 minutes
local BASE_SPACING       = 1.5   -- seconds between messages in a burst
local BACKOFF_SPACING    = 3.0   -- increased spacing during back-off
local PREFIX             = "[MCR]"

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local keepAliveTimer = nil
local sendQueue      = {}
local sendTimer      = nil
local backOffUntil   = 0    -- time() timestamp; all sends suppressed before this
local spacingUntil   = 0    -- time() timestamp; use BACKOFF_SPACING before this

local function GetSpacing()
    return time() < spacingUntil and BACKOFF_SPACING or BASE_SPACING
end

---------------------------------------------------------------------------
-- Internal queue
---------------------------------------------------------------------------
local function FlushQueue()
    if #sendQueue == 0 then
        sendTimer = nil
        return
    end
    local msg = sendQueue[1]
    if MC.Channel:IsActive() then
        table.remove(sendQueue, 1)
        SendChatMessage(msg, "CHANNEL", nil, MC.Channel.wowChannelIndex)
    else
        -- Channel not active — retry after spacing instead of dropping the message
        sendTimer = MC:ScheduleTimer(FlushQueue, GetSpacing())
        return
    end
    if #sendQueue > 0 then
        sendTimer = MC:ScheduleTimer(FlushQueue, GetSpacing())
    else
        sendTimer = nil
    end
end

local function Enqueue(msg)
    -- Safety: hard truncate before sending
    msg = string.sub(msg, 1, 255)
    -- Drop message silently during back-off window (e.g. after server throttle).
    -- This prevents the keep-alive timer from immediately re-flooding the queue
    -- right after ClearQueue() was called.
    if time() < backOffUntil then return end
    table.insert(sendQueue, msg)
    if not sendTimer then
        sendTimer = MC:ScheduleTimer(FlushQueue, 0.01)  -- near-immediate; AceTimer does not accept 0
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function MC.Broadcast:SendListing(entry)
    if not MC.db.char.settings.optedIn then return end
    local payload = string.format("%sL:%d,%s,%s",
        PREFIX, entry.itemID, entry.profName, entry.itemName)
    Enqueue(payload)
end

function MC.Broadcast:SendRemove(itemID)
    if not MC.db.char.settings.optedIn then return end
    Enqueue(string.format("%sR:%d", PREFIX, itemID))
end

function MC.Broadcast:SendAllListings()
    if not MC.db.char.settings.optedIn then return end
    for _, entry in ipairs(MC.db.char.myListings) do
        MC.Broadcast:SendListing(entry)
    end
end

---------------------------------------------------------------------------
-- Keep-alive (called by Channel.lua after successful YOU_JOINED)
---------------------------------------------------------------------------
function MC.Broadcast:StartKeepAlive()
    MC.Broadcast:StopKeepAlive()
    keepAliveTimer = MC:ScheduleRepeatingTimer(function()
        MC.Broadcast:SendAllListings()
    end, KEEPALIVE_INTERVAL)
end

function MC.Broadcast:StopKeepAlive()
    if keepAliveTimer then MC:CancelTimer(keepAliveTimer); keepAliveTimer = nil end
end

---------------------------------------------------------------------------
-- Back-off: called if CHAT_MSG_SYSTEM indicates server throttle.
-- Sets a 5-minute suppression window so the keep-alive timer cannot
-- immediately re-flood the queue after a throttle event.
-- Also increases message spacing to BACKOFF_SPACING for the duration.
---------------------------------------------------------------------------
function MC.Broadcast:ClearQueue()
    sendQueue = {}
    if sendTimer then MC:CancelTimer(sendTimer); sendTimer = nil end
    backOffUntil = time() + 300  -- suppress all sends for 5 minutes
    spacingUntil = time() + 300  -- slow down spacing for 5 minutes
end
