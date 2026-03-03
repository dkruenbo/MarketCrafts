-- Channel.lua — M1: Channel State Machine
-- Manages joining/leaving the MCMarket[N] channel pool with automatic
-- convergence to the lowest available channel.
local AddonName, NS = ...
local MC = NS.MC
local Channel = {}
MC.Channel = Channel

---------------------------------------------------------------------------
-- Channel pool
---------------------------------------------------------------------------
local CHANNELS = { "MCMarket", "MCMarket1", "MCMarket2", "MCMarket3", "MCMarket4" }

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state           = "IDLE"   -- IDLE | JOINING | ACTIVE | REVALIDATING | UNAVAILABLE
local activeIndex     = nil      -- 1-based index into CHANNELS (nil when not active)
local walkIndex       = nil      -- current index being tried during a walk
local isIntentional   = false    -- flag: current YOU_LEFT was triggered by us
local stepTimer       = nil      -- AceTimer handle for per-step 5s timeout
local revalidateTimer = nil
local retryTimer      = nil

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

-- Attempt to join the channel at CHANNELS[index].
-- Sets a 5-second per-step timeout in case CHAT_MSG_CHANNEL_NOTICE never fires.
local function TryJoinAt(index)
    if index > #CHANNELS then
        -- Exhausted all fallbacks
        state = "UNAVAILABLE"
        walkIndex = nil
        MC.Broadcast:StopKeepAlive()
        MC:Print("MarketCrafts: Market unavailable \xe2\x80\x94 all MCMarket channels are locked.")
        retryTimer = MC:ScheduleTimer(function()
            Channel:StartWalk()
        end, 900) -- 15 min
        return
    end

    walkIndex = index
    state = "JOINING"
    CancelStepTimer()

    -- Verify channel slot availability
    if GetNumCustomChannels and GetNumCustomChannels() >= 10 then
        MC:Print("MarketCrafts: Cannot join market channel \xe2\x80\x94 you are at the 10 custom channel limit.")
        state = "UNAVAILABLE"
        return
    end

    JoinChannelByName(CHANNELS[index])

    -- Per-step 5-second timeout: if CHAT_MSG_CHANNEL_NOTICE never fires, try next
    stepTimer = MC:ScheduleTimer(function()
        stepTimer = nil
        if state == "JOINING" and walkIndex == index then
            TryJoinAt(index + 1)
        end
    end, 5)
end

function Channel:StartWalk()
    if retryTimer then MC:CancelTimer(retryTimer); retryTimer = nil end
    TryJoinAt(1)  -- Lua tables are 1-based; CHANNELS[1] = "MCMarket"
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
function Channel:OnChatMsgChannelNotice(msg, _, _, channelString, _, _, _, channelIndex, channelName)
    -- channelIndex (arg8) is the WoW channel number for SendChatMessage.
    -- channelName  (arg9) is the bare name (e.g. "MCMarket") — may be empty in some TBC builds.
    -- channelString (arg4) is the formatted name with slot prefix (e.g. "7. MCMarket") — reliable fallback.

    -- Debug: uncomment to diagnose argument layout on your build
    -- print("MCR DEBUG:", msg, "| arg4:", channelString, "| arg8:", channelIndex, "| arg9:", channelName)

    -- Normalise: if arg9 is empty, strip the "N. " prefix from arg4
    if (not channelName or channelName == "") and channelString and channelString ~= "" then
        channelName = channelString:match("^%d+%.%s*(.+)$") or channelString
    end

    if msg == "YOU_JOINED" then
        -- Find which of our channels this is
        local matched = nil
        for i, name in ipairs(CHANNELS) do
            if channelName == name then matched = i; break end
        end
        if not matched then return end  -- not one of ours

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
    local prevChannel = CHANNELS[activeIndex]
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
        SafeLeaveChannel(CHANNELS[activeIndex])
        activeIndex = nil
        Channel.wowChannelIndex = nil
    end
    MC:UnregisterEvent("CHAT_MSG_CHANNEL_NOTICE")
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Channel:GetActiveChannelName()
    return activeIndex and CHANNELS[activeIndex] or nil
end

function Channel:IsActive()
    return state == "ACTIVE" and Channel.wowChannelIndex ~= nil
end
