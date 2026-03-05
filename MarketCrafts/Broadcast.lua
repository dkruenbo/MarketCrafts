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
local qHead, qTail   = 1, 0    -- ring-buffer head/tail pointers
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
    if qHead > qTail then
        sendTimer = nil
        return
    end
    local msg = sendQueue[qHead]
    if MC.Channel:IsActive() then
        sendQueue[qHead] = nil
        qHead = qHead + 1
        SendChatMessage(msg, "CHANNEL", nil, MC.Channel.wowChannelIndex)
    else
        -- Channel not active — retry after spacing instead of dropping the message
        sendTimer = MC:ScheduleTimer(FlushQueue, GetSpacing())
        return
    end
    if qHead <= qTail then
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
    qTail = qTail + 1
    sendQueue[qTail] = msg
    if not sendTimer then
        sendTimer = MC:ScheduleTimer(FlushQueue, 0.01)  -- near-immediate; AceTimer does not accept 0
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function MC.Broadcast:SendListing(entry)
    if not MC.db.char.settings.optedIn then return end
    local profName = entry.profName:gsub(",", "")
    local itemName = entry.itemName:gsub(",", "")
    local payload

    -- F6: decay the stored cooldown from the moment it was measured.
    -- cdSeconds ~= nil means the recipe is time-gated; we always include the field
    -- so receivers can distinguish "timed recipe, currently ready" (0) from
    -- "no cooldown at all" (field absent).
    local currentCD = nil
    if entry.cdSeconds ~= nil and entry.cdUpdatedAt then
        currentCD = math.max(0, entry.cdSeconds - (time() - entry.cdUpdatedAt))
    end

    local hasNote = entry.note and entry.note ~= ""

    if currentCD ~= nil then
        -- 5-field: note (may be empty) + cooldown — both required for this format
        local note = hasNote and entry.note:gsub(",", "") or ""
        payload = string.format("%sL:%d,%s,%s,%s,%d",
            PREFIX, entry.itemID, profName, itemName, note, currentCD)
    elseif hasNote then
        -- 4-field: note, no cooldown
        local note = entry.note:gsub(",", "")
        payload = string.format("%sL:%d,%s,%s,%s",
            PREFIX, entry.itemID, profName, itemName, note)
    else
        -- 3-field: no note, no cooldown
        payload = string.format("%sL:%d,%s,%s",
            PREFIX, entry.itemID, profName, itemName)
    end
    Enqueue(payload)
end

function MC.Broadcast:SendRemove(itemID)
    if not MC.db.char.settings.optedIn then return end
    Enqueue(string.format("%sR:%d", PREFIX, itemID))
end

function MC.Broadcast:SendAllListings()
    if not MC.db.char.settings.optedIn then return end
    -- Broadcast own listings
    for _, entry in ipairs(MC.db.char.myListings) do
        MC.Broadcast:SendListing(entry)
    end
    -- F5: broadcast imported alt profiles (different characters on same account)
    local altListings = MC.db.global and MC.db.global.altListings or {}
    local myRealm  = GetRealmName() or ""
    local myChar   = UnitName("player") or ""
    local myKey    = myRealm .. "-" .. myChar
    for key, entries in pairs(altListings) do
        -- Skip the current character's own profile (already sent above)
        if key ~= myKey then
            for _, entry in ipairs(entries) do
                MC.Broadcast:SendListing(entry)
            end
        end
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
    sendQueue = {}; qHead = 1; qTail = 0
    if sendTimer then MC:CancelTimer(sendTimer); sendTimer = nil end
    backOffUntil = time() + 300  -- suppress all sends for 5 minutes
    spacingUntil = time() + 300  -- slow down spacing for 5 minutes
end
