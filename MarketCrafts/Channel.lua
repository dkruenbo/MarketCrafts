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
local state           = "IDLE"   -- IDLE | JOINING | ACTIVE | UNAVAILABLE
local activeIndex     = nil      -- walk index of the active channel (nil when not active)
local walkIndex         = nil    -- walk index currently being tried
local intentionalLeaves = 0      -- count of pending intentional YOU_LEFT events
local stepTimer         = nil    -- AceTimer handle for per-step 5s timeout
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
    if not ChatFrame_RemoveChannel then return end
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
        MC:Print("MarketCrafts: Market unavailable — unable to connect to any chat channels.")
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
        MC:Print("MarketCrafts: Cannot join market channel — you are at the 10 custom channel limit.")
        state = "UNAVAILABLE"
        retryTimer = MC:ScheduleTimer(function() Channel:StartWalk() end, 60)
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

function Channel:StartWalk(fromIndex)
    if retryTimer then MC:CancelTimer(retryTimer); retryTimer = nil end

    -- After /reload WoW auto-restores channels. Only skip the walk if we are
    -- already in MCMarket (index 1) — the optimal slot. If we are in MCMarket1
    -- or higher we still walk so we converge down to MCMarket.
    if not fromIndex then
        local name = ChannelName(1)  -- "MCMarket"
        local slot = GetChannelName(name)
        if slot and slot > 0 then
            state = "ACTIVE"
            activeIndex = 1
            walkIndex = nil
            Channel.wowChannelIndex = slot
            HideChannelFromAllFrames(name)
            MC.Broadcast:StartKeepAlive()
            MC.UI:UpdateStatus()
            if MC.debugMode then
                print("MCR: already in", name, "slot", slot, "- skipping walk")
            end
            return
        end
    end

    TryJoinAt(fromIndex or 1)
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
function Channel:OnChatMsgChannelNotice(msg, _, _, channelString, _, _, _, channelIndex, channelName)
    -- Normalise: if arg9 is empty, strip the "N. " prefix from arg4
    if (not channelName or channelName == "") and channelString and channelString ~= "" then
        channelName = channelString:match("^%d+%.%s*(.+)$") or channelString
    end

    -- Early exit: ignore events for non-MCMarket channels entirely
    if not channelName or not ChannelToIndex(channelName) then return end

    -- Debug: only logs MCMarket-related events
    if MC.debugMode then
        print("MCR DEBUG:", msg, "| ch:", channelName, "| idx:", channelIndex, "| state:", state, "| walk:", walkIndex, "| active:", activeIndex, "| intentionalLeaves:", intentionalLeaves)
    end

    -- In TBC Classic, successfully joining a custom channel fires YOU_CHANGED
    -- instead of YOU_JOINED (YOU_JOINED may never fire at all).
    -- Treat both as a successful join when we are actively walking.
    if msg == "YOU_JOINED" or msg == "YOU_CHANGED" then
        local matched = ChannelToIndex(channelName)

        -- If this is not the channel we're trying to join, leave it immediately.
        if state ~= "JOINING" or walkIndex ~= matched then
            intentionalLeaves = intentionalLeaves + 1  -- prevent YOU_LEFT from triggering a re-walk
            SafeLeaveChannel(channelName)
            return
        end

        if state == "JOINING" and walkIndex == matched then
            CancelStepTimer()
            local prevIndex = activeIndex
            activeIndex = matched
            state = "ACTIVE"
            walkIndex = nil

            -- Look up the WoW slot number via GetChannelName rather than
            -- trusting arg8, which may be 0 or unreliable on YOU_CHANGED.
            local wowSlot = GetChannelName(channelName)
            Channel.wowChannelIndex = (wowSlot and wowSlot > 0) and wowSlot or channelIndex
            if MC.debugMode then
                print("MCR: settled on", channelName, "wowSlot=", Channel.wowChannelIndex)
            end
            HideChannelFromAllFrames(channelName)
            MC.Broadcast:StartKeepAlive()
            MC.UI:UpdateStatus()

            -- H2: deferred slot resolve — GetChannelName may return 0 immediately after YOU_CHANGED
            if not Channel.wowChannelIndex or Channel.wowChannelIndex == 0 then
                local snapName = channelName
                MC:ScheduleTimer(function()
                    if state == "ACTIVE" then
                        local slot = GetChannelName(snapName)
                        if slot and slot > 0 then
                            Channel.wowChannelIndex = slot
                            MC.UI:UpdateStatus()
                            if MC.debugMode then
                                print("MCR: deferred slot resolve →", slot)
                            end
                        end
                    end
                end, 0.5)
            end

            -- Re-broadcast only if we moved to a different channel
            if prevIndex ~= activeIndex then
                MC.Broadcast:SendAllListings()
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
        -- Only react to YOU_LEFT for channels we care about.
        -- If it's not our active channel and not intentional, ignore it.
        local leftIndex = ChannelToIndex(channelName)

        if intentionalLeaves > 0 then
            -- Expected: we triggered this leave.
            intentionalLeaves = intentionalLeaves - 1
        elseif leftIndex and leftIndex == activeIndex then
            -- Looks like an unexpected kick from our active channel.
            -- Verify with the API before acting -- TBC can fire spurious YOU_LEFT.
            local stillIn = GetChannelName(channelName)
            if stillIn and stillIn > 0 then
                -- Still in the channel; event was spurious. Do nothing.
                if MC.debugMode then
                    print("MCR: spurious YOU_LEFT ignored, still in slot", stillIn)
                end
            else
                -- Genuinely removed -- restart from the channel we were on.
                local kickedFrom = activeIndex
                activeIndex = nil
                Channel.wowChannelIndex = nil
                state = "JOINING"
                MC.UI:UpdateStatus()
                Channel:StartWalk(kickedFrom)
            end
        end
        -- If leftIndex ~= activeIndex and not intentional, it's a stale channel
        -- being cleaned up by the server or another addon. Ignore it.
    end
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
    if retryTimer then MC:CancelTimer(retryTimer); retryTimer = nil end
    CancelStepTimer()
    MC.Broadcast:StopKeepAlive()
    if activeIndex then
        intentionalLeaves = intentionalLeaves + 1
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
