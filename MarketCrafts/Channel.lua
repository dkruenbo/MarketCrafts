-- Channel.lua — M1: Channel State Machine
-- Manages joining/leaving the MCMarket[N] channel pool with automatic
-- convergence to the lowest available channel.
local AddonName, NS = ...
local MC = NS.MC
local Channel = {}
MC.Channel = Channel

---------------------------------------------------------------------------
-- Channel pool (unbounded — walks MCMarket, MCMarket1, MCMarket2, … until one is open)
---------------------------------------------------------------------------
local function ChannelName(i)
    if i == 1 then return "MCMarket" end
    return "MCMarket" .. (i - 1)
end

-- Reverse: channel name → walk index (nil if not one of ours)
local function ChannelToIndex(name)
    if name == "MCMarket" then return 1 end
    local n = name:match("^MCMarket(%d+)$")
    return n and (tonumber(n) + 1) or nil
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state           = "IDLE"   -- IDLE | JOINING | ACTIVE | REVALIDATING | UNAVAILABLE
local activeIndex     = nil      -- walk index of the active channel (nil when not active)
local walkIndex       = nil      -- walk index currently being tried
local isIntentional   = false    -- flag: current YOU_LEFT was triggered by us
local stepTimer       = nil      -- AceTimer handle for per-step 5s timeout
local revalidateTimer = nil
local retryTimer      = nil
local MAX_WOW_CHANNELS = 20  -- GetChannelName range to scan for custom channels

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function CancelStepTimer()
    if stepTimer then
        MC:CancelTimer(stepTimer)
        stepTimer = nil
    end
end

local function HideChannelFromAllFrames(name)
    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame then ChatFrame_RemoveChannel(frame, name) end
    end
end

--- Safe leave: uses LeaveChannelByName if available, else falls back to
--- GetChannelName + LeaveChannel(index). TBC 2.5.5 API availability of
--- LeaveChannelByName must be verified empirically.
local function SafeLeaveChannel(name)
    if LeaveChannelByName then
        LeaveChannelByName(name)
    else
        local index = GetChannelName(name)
        if index and index > 0 then
            LeaveChannel(index)
        end
    end
end

---------------------------------------------------------------------------
-- Walk logic
---------------------------------------------------------------------------

-- Attempt to join ChannelName(index).
-- Sets a 5-second per-step timeout in case CHAT_MSG_CHANNEL_NOTICE never fires.
-- Circuit breaker at index > 50: if the chat server stops responding entirely,
-- this prevents an infinite timer loop counting up to MCMarket<Infinity>.
local function TryJoinAt(index)
    if index > 50 then
        state = "UNAVAILABLE"
        walkIndex = nil
        MC.Broadcast:StopKeepAlive()
        MC:Print("MarketCrafts: Market unavailable \xe2\x80\x94 unable to connect to any chat channels.")
        retryTimer = MC:ScheduleTimer(function() Channel:StartWalk() end, 900)
        return
    end

    walkIndex = index
    state = "JOINING"
    CancelStepTimer()

    -- Verify channel slot availability (WoW TBC hard limit: 10 custom channels).
    -- GetNumCustomChannels does not exist in TBC Classic 2.5.x, so count manually.
    local customCount = 0
    for ci = 1, MAX_WOW_CHANNELS do
        local cName = select(2, GetChannelName(ci))
        if cName and cName ~= "" then customCount = customCount + 1 end
    end
    if customCount >= 10 then
        MC:Print("MarketCrafts: Cannot join market channel \xe2\x80\x94 you are at the 10 custom channel limit.")
        state = "UNAVAILABLE"
        return
    end

    JoinChannelByName(ChannelName(index))

    -- Per-step 5-second timeout: if CHAT_MSG_CHANNEL_NOTICE never fires, try next
    stepTimer = MC:ScheduleTimer(function()
        stepTimer = nil
        if state == "JOINING" and walkIndex == index then
            -- Leave the channel we just tried before moving on
            SafeLeaveChannel(ChannelName(index))
            TryJoinAt(index + 1)
        end
    end, 5)
end

function Channel:StartWalk()
    if retryTimer then MC:CancelTimer(retryTimer); retryTimer = nil end
    TryJoinAt(1)  -- index 1 = "MCMarket", index 2 = "MCMarket1", etc.
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
function Channel:OnChatMsgChannelNotice(msg, _, _, channelString, _, _, _, channelIndex, channelName)
    -- channelIndex (arg8) is the WoW channel number for SendChatMessage.
    -- channelName  (arg9) is the bare name (e.g. "MCMarket") — may be empty in some TBC builds.
    -- channelString (arg4) is the formatted name with slot prefix (e.g. "7. MCMarket") — reliable fallback.

    -- Debug: logs argument layout to help diagnose TBC event payloads
    if MC.debugMode then
        print("MCR DEBUG:", msg, "| arg4:", channelString, "| arg8:", channelIndex, "| arg9:", channelName)
    end

    -- Normalise: if arg9 is empty, strip the "N. " prefix from arg4
    if (not channelName or channelName == "") and channelString and channelString ~= "" then
        channelName = channelString:match("^%d+%.%s*(.+)$") or channelString
    end

    if msg == "YOU_JOINED" then
        local matched = ChannelToIndex(channelName)
        if not matched then return end  -- not one of ours

        -- If we joined an MCMarket channel we weren't currently walking to,
        -- leave it immediately to prevent channel accumulation (Bug 4).
        if state ~= "JOINING" or walkIndex ~= matched then
            SafeLeaveChannel(ChannelName(matched))
            return
        end

        if state == "JOINING" and walkIndex == matched then
            CancelStepTimer()
            local prevIndex = activeIndex
            activeIndex = matched
            state = "ACTIVE"
            walkIndex = nil

            -- Store the WoW channel number for SendChatMessage
            Channel.wowChannelIndex = channelIndex
            HideChannelFromAllFrames(channelName)
            MC.Broadcast:StartKeepAlive()

            -- Re-broadcast only if we moved to a different channel
            if prevIndex ~= activeIndex then
                MC.Broadcast:SendAllListings()
            end

            -- Start re-validate cycle
            if not revalidateTimer then
                revalidateTimer = MC:ScheduleRepeatingTimer(function()
                    Channel:StartRevalidate()
                end, 600) -- 10 min
            end
        end

    elseif msg == "WRONG_PASSWORD" or msg == "BANNED" then
        if state == "JOINING" then
            CancelStepTimer()
            -- Leave the channel before trying the next one
            SafeLeaveChannel(ChannelName(walkIndex))
            TryJoinAt(walkIndex + 1)
        end

    elseif msg == "YOU_LEFT" then
        if isIntentional then
            -- Expected: we triggered this leave as part of re-validate or disable
            isIntentional = false
            if state == "REVALIDATING" then
                Channel:StartWalk()
            end
            -- If IDLE (OnDisable), do nothing
        else
            -- Unexpected kick — treat as an opportunity to re-validate
            state = "REVALIDATING"
            activeIndex = nil
            Channel.wowChannelIndex = nil
            if revalidateTimer then MC:CancelTimer(revalidateTimer); revalidateTimer = nil end
            Channel:StartWalk()
        end
    end
end

---------------------------------------------------------------------------
-- Re-validate
---------------------------------------------------------------------------
function Channel:StartRevalidate()
    if state ~= "ACTIVE" then return end
    state = "REVALIDATING"
    isIntentional = true
    local prevChannel = ChannelName(activeIndex)
    activeIndex = nil
    if revalidateTimer then MC:CancelTimer(revalidateTimer); revalidateTimer = nil end
    Channel.wowChannelIndex = nil
    SafeLeaveChannel(prevChannel)
    -- YOU_LEFT event will fire and trigger StartWalk() via OnChatMsgChannelNotice
end

---------------------------------------------------------------------------
-- Enable / Disable
---------------------------------------------------------------------------
function Channel:Enable()
    MC:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", function(_, ...)
        Channel:OnChatMsgChannelNotice(...)
    end)
    -- Login delay: random 10-15 seconds to stagger joins across players
    local delay = 10 + math.random() * 5
    MC:ScheduleTimer(function()
        Channel:StartWalk()
    end, delay)
end

function Channel:Disable()
    if revalidateTimer then MC:CancelTimer(revalidateTimer); revalidateTimer = nil end
    if retryTimer then MC:CancelTimer(retryTimer); retryTimer = nil end
    CancelStepTimer()
    MC.Broadcast:StopKeepAlive()
    if activeIndex then
        isIntentional = true
        state = "IDLE"
        SafeLeaveChannel(ChannelName(activeIndex))
        activeIndex = nil
        Channel.wowChannelIndex = nil
    end
    MC:UnregisterEvent("CHAT_MSG_CHANNEL_NOTICE")
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Channel:GetActiveChannelName()
    return activeIndex and ChannelName(activeIndex) or nil
end

function Channel:IsActive()
    return state == "ACTIVE" and Channel.wowChannelIndex ~= nil
end
