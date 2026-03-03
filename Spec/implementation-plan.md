# MarketCrafts — Implementation Plan

> **Addon:** MarketCrafts (standalone)
> **Game:** World of Warcraft — Burning Crusade Classic 2.5.5
> **Date:** 2026-03-02

---

## How to Read This Document

Each milestone maps to the spec. Milestones are ordered by dependency — do not start one until the previous is passing its smoke tests. Each section describes **what to build**, **how to build it**, and **how to verify it** before moving on.

---

## Phase 0 — Scaffolding (pre-M1)

Before writing any logic, get a loadable addon shell with all libraries in place. Nothing else can be tested without this.

### 0.1 Directory Structure

Create exactly this layout:

```
MarketCrafts/
├── MarketCrafts.toc
├── MarketCrafts.lua
├── Channel.lua
├── Broadcast.lua
├── Listener.lua
├── Cache.lua
├── ChatFilter.lua
├── UI.lua
└── Libs/
    ├── LibStub/LibStub.lua
    ├── CallbackHandler-1.0/CallbackHandler-1.0.lua
    ├── AceAddon-3.0/AceAddon-3.0.lua
    ├── AceEvent-3.0/AceEvent-3.0.lua
    ├── AceTimer-3.0/AceTimer-3.0.lua
    ├── AceDB-3.0/AceDB-3.0.lua
    ├── AceConsole-3.0/AceConsole-3.0.lua
    └── AceGUI-3.0/AceGUI-3.0.lua
```

Download all Ace3 libraries from CurseForge or the official Ace3 SVN. Bundle every library — do not rely on shared libraries from other addons.

### 0.2 TOC File

```toc
## Interface: 20504
## Title: MarketCrafts
## Notes: Server-wide crafting service board for TBC Classic
## Author: dkruenbo
## Version: 0.1.0
## SavedVariables: MarketCraftsDB

Libs\LibStub\LibStub.lua
Libs\CallbackHandler-1.0\CallbackHandler-1.0.lua
Libs\AceAddon-3.0\AceAddon-3.0.lua
Libs\AceEvent-3.0\AceEvent-3.0.lua
Libs\AceTimer-3.0\AceTimer-3.0.lua
Libs\AceDB-3.0\AceDB-3.0.lua
Libs\AceConsole-3.0\AceConsole-3.0.lua
Libs\AceGUI-3.0\AceGUI-3.0.lua

MarketCrafts.lua
Channel.lua
Broadcast.lua
Listener.lua
Cache.lua
ChatFilter.lua
UI.lua
```

**Note:** Verify the correct interface number against the live TBC 2.5.5 build before first release. `20504` is the expected value but confirm empirically.

### 0.3 MarketCrafts.lua — Addon Core

```lua
local AddonName, NS = ...

local MC = LibStub("AceAddon-3.0"):NewAddon("MarketCrafts", "AceConsole-3.0", "AceEvent-3.0")
NS.MC = MC

local DB_DEFAULTS = {
    char = {
        myListings  = {},   -- up to 5 entries: { itemID, profName, itemName }
        blocklist   = {},   -- { ["PlayerName"] = true }
        settings    = {
            optedIn         = false,
            lastBroadcast   = 0,    -- time() of last manual broadcast
            refreshCooldown = 900,  -- 15 min in seconds
        },
    },
}

function MC:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("MarketCraftsDB", DB_DEFAULTS, true)
    -- true = use character scope by default

    self:RegisterChatCommand("mc", "HandleSlashCommand")
end

function MC:OnEnable()
    MC.Channel:Enable()
    MC.ChatFilter:Enable()
    MC.Listener:Enable()   -- registers CHAT_MSG_CHANNEL + CHAT_MSG_SYSTEM
    MC.Cache:Enable()      -- starts purge timer + GET_ITEM_INFO_RECEIVED
end

function MC:OnDisable()
    MC.Channel:Disable()
end

function MC:HandleSlashCommand(input)
    local cmd, arg = input:match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        MC.UI:Toggle()
    elseif cmd == "ignore" and arg ~= "" then
        MC.Cache:Ignore(arg)
        MC:Print("Ignored: " .. arg)
    elseif cmd == "unignore" and arg ~= "" then
        MC.Cache:Unignore(arg)
        MC:Print("Unignored: " .. arg)
    elseif cmd == "list" then
        MC:PrintMyListings()
    elseif cmd == "help" then
        MC:Print("/mc — toggle window")
        MC:Print("/mc ignore <Player> — block player's listings")
        MC:Print("/mc unignore <Player> — unblock player")
        MC:Print("/mc list — show your active listings")
    else
        MC:Print("Unknown command. Type /mc help.")
    end
end

function MC:PrintMyListings()
    local listings = self.db.char.myListings
    if #listings == 0 then
        self:Print("You have no active listings.")
        return
    end
    for i, l in ipairs(listings) do
        self:Print(string.format("[%d] %s — %s", i, l.itemName, l.profName))
    end
end
```

### 0.4 Smoke Test

Log in to the game. `/mc help` should print the command list. No Lua errors in BugSack. No taint in the taint log (`/run SetCVar("taintLog", 1)` then reload, check Interface/Logs/taint.log).

---

## M1 — Channel State Machine

**Goal:** The addon reliably joins and stays on the lowest available `MCMarket[N]` channel, handles hijacking, and re-validates every 10 minutes. This is the hardest piece of the addon.

### State Machine

```
IDLE
  │  OnEnable / login delay fires
  ▼
JOINING[index=0]
  │  YOU_JOINED           → ACTIVE[index]
  │  WRONG_PASSWORD/BANNED → JOINING[index+1]
  │  5s timeout           → JOINING[index+1]
  │  index > 4            → UNAVAILABLE
  ▼
ACTIVE[index]
  │  10-min timer fires   → REVALIDATING (leave, set flag)
  │  unexpected YOU_LEFT  → REVALIDATING (already left, set flag)
  ▼
REVALIDATING
  │  YOU_LEFT received (flag set) → JOINING[index=0]
  ▼
UNAVAILABLE
  │  15-min retry timer   → JOINING[index=0]
```

### Channel.lua

```lua
local AddonName, NS = ...
local MC = NS.MC
local Channel = {}
MC.Channel = Channel

-- Channel pool
local CHANNELS = { "MCMarket", "MCMarket1", "MCMarket2", "MCMarket3", "MCMarket4" }

-- State
local state          = "IDLE"   -- IDLE | JOINING | ACTIVE | REVALIDATING | UNAVAILABLE
local activeIndex    = nil      -- 1-based index into CHANNELS (nil when not active)
local walkIndex      = nil      -- current index being tried during a walk
local isIntentional  = false    -- flag: current YOU_LEFT was triggered by us
local stepTimer      = nil      -- AceTimer handle for per-step 5s timeout
local revalidateTimer = nil
local retryTimer     = nil

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

-- Attempt to join the channel at CHANNELS[walkIndex].
-- Sets a 5-second per-step timeout in case CHAT_MSG_CHANNEL_NOTICE never fires.
local function TryJoinAt(index)
    if index > #CHANNELS then
        -- Exhausted all fallbacks
        state = "UNAVAILABLE"
        walkIndex = nil
        MC.Broadcast:StopKeepAlive()
        MC:Print("MarketCrafts: Market unavailable — all MCMarket channels are locked.")
        retryTimer = MC:ScheduleTimer(function()
            Channel:StartWalk()
        end, 900) -- 15 min
        return
    end

    walkIndex = index
    state = "JOINING"
    CancelStepTimer()

    -- Verify channel slot availability
    if GetNumCustomChannels() >= 10 then
        MC:Print("MarketCrafts: Cannot join market channel — you are at the 10 custom channel limit.")
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

function Channel:OnChatMsgChannelNotice(msg, _, _, _, _, _, _, _, channelName, _, channelIndex)
    -- channelIndex here is the WoW channel number, not our CHANNELS table index.
    -- channelName identifies which MCMarket[N] channel this is for.

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

function Channel:StartRevalidate()
    if state ~= "ACTIVE" then return end
    state = "REVALIDATING"
    isIntentional = true
    local prevChannel = CHANNELS[activeIndex]
    activeIndex = nil
    if revalidateTimer then MC:CancelTimer(revalidateTimer); revalidateTimer = nil end
    Channel.wowChannelIndex = nil
    LeaveChannelByName(prevChannel)
    -- YOU_LEFT event will fire and trigger StartWalk() via OnChatMsgChannelNotice
end

function Channel:Enable()
    MC:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", function(_, ...)
        Channel:OnChatMsgChannelNotice(...)
    end)
    -- Login delay: random 10–15 seconds
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
        LeaveChannelByName(CHANNELS[activeIndex])
        activeIndex = nil
        Channel.wowChannelIndex = nil
    end
    MC:UnregisterEvent("CHAT_MSG_CHANNEL_NOTICE")
end

function Channel:GetActiveChannelName()
    return activeIndex and CHANNELS[activeIndex] or nil
end

function Channel:IsActive()
    return state == "ACTIVE" and Channel.wowChannelIndex ~= nil
end
```

### M1 Verification

- `/run LeaveChannelByName("MCMarket")` — addon should detect `YOU_LEFT`, revalidate, and rejoin.
- On a second account: password-lock `MCMarket`. First account's next re-validate (or force with `/run MarketCrafts.Channel:StartRevalidate()`) should land on `MCMarket1`.
- Remove the password. Wait or force a re-validate — first account should converge back down to `MCMarket`.
- Fill all 10 custom channel slots on an alt, then log in main — should print the slot warning and not error.
- Kill your internet for 6+ seconds during a join walk — per-step timeout should advance to the next fallback.
- Check taint log — zero entries expected.

---

## M2 — Saved Listings

**Goal:** Players can mark up to 5 recipes as "for sale". Listings persist in `SavedVariables`. No broadcasting yet.

### 2.1 Update SavedVariables Schema

The schema in `MarketCrafts.lua` `DB_DEFAULTS` should reflect the simplified listing shape (no spec/tip):

```lua
myListings = {},
-- Each entry: { itemID = <number>, profName = <string>, itemName = <string> }
```

`itemName` is included at storage time so it is available immediately for display without requiring `GetItemInfo`.

### 2.2 Listing Management API (Cache.lua or MarketCrafts.lua)

```lua
-- Add or update a listing (upsert by itemID)
function MC:AddMyListing(itemID, profName, itemName)
    local listings = self.db.char.myListings
    -- Check for existing entry to update
    for _, entry in ipairs(listings) do
        if entry.itemID == itemID then
            entry.profName = profName
            entry.itemName = itemName
            MC.Broadcast:SendListing(entry)  -- M3: no-op until Broadcast exists
            return true
        end
    end
    if #listings >= 5 then
        MC:Print("You can only list up to 5 recipes.")
        return false
    end
    table.insert(listings, { itemID = itemID, profName = profName, itemName = itemName })
    MC.Broadcast:SendListing(listings[#listings])
    return true
end

-- Remove a listing by itemID
function MC:RemoveMyListing(itemID)
    local listings = self.db.char.myListings
    for i, entry in ipairs(listings) do
        if entry.itemID == itemID then
            table.remove(listings, i)
            MC.Broadcast:SendRemove(itemID)  -- M3: no-op until Broadcast exists
            return true
        end
    end
    return false
end

function MC:GetMyListings()
    return self.db.char.myListings
end
```

### 2.3 Stub Broadcast calls

Until M3 exists, make `Broadcast:SendListing()` and `Broadcast:SendRemove()` empty stubs so M2 doesn't error:

```lua
-- Broadcast.lua (stub for M2)
local MC = NS.MC
MC.Broadcast = {}
function MC.Broadcast:SendListing(entry) end
function MC.Broadcast:SendRemove(itemID) end
function MC.Broadcast:SendAllListings() end
```

### M2 Verification

- Log in, add a listing via `/run MarketCrafts:AddMyListing(22861, "Alchemy", "Flask of Supreme Power")`.
- `/mc list` — should print the listing.
- `/reload` — listing should persist.
- Add a 6th listing — should print the cap warning.
- Remove a listing — should be gone from `/mc list` and not re-appear after `/reload`.

---

## M3 — Broadcast, Listener, and Chat Filter

**Goal:** Sellers send listings to the channel on the correct triggers. Listeners parse them into cache. `[MCR]` messages are invisible in chat.

### 3.1 ChatFilter.lua

Implement exactly as specced. This should be the simplest file in the addon.

```lua
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
```

**Critical:** The filter does no parsing, no cache writes, no globals, no closures over secure frames. Its only job is returning `true` for `[MCR]` prefixed messages.

### 3.2 Broadcast.lua

```lua
local AddonName, NS = ...
local MC = NS.MC
MC.Broadcast = {}

local KEEPALIVE_INTERVAL = 1200  -- 20 minutes
local MESSAGE_SPACING    = 1.5   -- seconds between messages in a burst
local PREFIX             = "[MCR]"

local keepAliveTimer = nil
local sendQueue      = {}
local sendTimer      = nil
local backOffUntil   = 0    -- time() timestamp; all sends suppressed before this

local function FlushQueue()
    if #sendQueue == 0 then
        sendTimer = nil
        return
    end
    local msg = table.remove(sendQueue, 1)
    if MC.Channel:IsActive() then
        SendChatMessage(msg, "CHANNEL", nil, MC.Channel.wowChannelIndex)
    end
    if #sendQueue > 0 then
        sendTimer = MC:ScheduleTimer(FlushQueue, MESSAGE_SPACING)
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
        sendTimer = MC:ScheduleTimer(FlushQueue, 0.01)  -- near-immediate start; AceTimer does not accept 0
    end
end

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

-- Called by Channel.lua after a successful YOU_JOINED to start the keep-alive
function MC.Broadcast:StartKeepAlive()
    MC.Broadcast:StopKeepAlive()
    keepAliveTimer = MC:ScheduleRepeatingTimer(function()
        MC.Broadcast:SendAllListings()
    end, KEEPALIVE_INTERVAL)
end

function MC.Broadcast:StopKeepAlive()
    if keepAliveTimer then MC:CancelTimer(keepAliveTimer); keepAliveTimer = nil end
end

-- Back-off: called if CHAT_MSG_SYSTEM indicates server throttle.
-- Sets a 5-minute suppression window so the keep-alive timer cannot
-- immediately re-flood the queue after a throttle event.
function MC.Broadcast:ClearQueue()
    sendQueue = {}
    if sendTimer then MC:CancelTimer(sendTimer); sendTimer = nil end
    backOffUntil = time() + 300  -- suppress all sends for 5 minutes
end
```

All keep-alive wiring (`StartKeepAlive` / `StopKeepAlive`) is already embedded in the Channel.lua code above. The initial login broadcast is handled naturally: `prevIndex` is `nil` on first join, so the `prevIndex ~= activeIndex` check fires and calls `SendAllListings()`.

### 3.3 Listener.lua

```lua
local AddonName, NS = ...
local MC = NS.MC
MC.Listener = {}

local PREFIX_L = "[MCR]L:"
local PREFIX_R = "[MCR]R:"

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

function MC.Listener:OnChatMsgChannel(event, msg, sender, _, _, _, _, _, _, channelName)
    -- Ignore if this is not one of our MCMarket channels
    if not channelName:find("^MCMarket") then return end
    if not msg or string.sub(msg, 1, 5) ~= "[MCR]" then return end

    -- Skip own messages
    if sender == UnitName("player") then return end

    if string.sub(msg, 1, #PREFIX_L) == PREFIX_L then
        local entry = ParseListing(msg, sender)
        if entry then
            MC.Cache:AddOrUpdate(entry)
        end
    elseif string.sub(msg, 1, #PREFIX_R) == PREFIX_R then
        local data = ParseRemove(msg, sender)
        if data then
            MC.Cache:Remove(data.seller, data.itemID)
        end
    end
end

function MC.Listener:Enable()
    MC:RegisterEvent("CHAT_MSG_CHANNEL", function(_, ...)
        MC.Listener:OnChatMsgChannel(...)
    end)
    -- Also handle CHAT_MSG_SYSTEM to detect spam-filter throttle
    MC:RegisterEvent("CHAT_MSG_SYSTEM", function(_, msg)
        if msg and (msg:find("throttled") or msg:find("spam")) then
            MC.Broadcast:ClearQueue()
        end
    end)
end
```

Both `MC.Listener:Enable()` and the `CHAT_MSG_SYSTEM` handler inside it are already wired into `MC:OnEnable()` — see Phase 0. Note that `ClearQueue()` sets `backOffUntil` for 5 minutes, so the keep-alive timer cannot immediately re-flood the queue after a throttle: `Enqueue` silently drops any message while `time() < backOffUntil`.

### M3 Verification

- Two accounts on same realm, both with the addon loaded.
- Account A opts in: `/run MarketCrafts.db.char.settings.optedIn = true`.
- Account A: `MarketCrafts:AddMyListing(22861, "Alchemy", "Flask of Supreme Power")`.
- Account B: `/run for k,v in pairs(MarketCrafts.Cache.listings) do print(k) end` — should show the listing.
- In Account B's chat box, confirm no `[MCR]` text appeared (filter is working).
- Force keep-alive on A: `/run MarketCrafts.Broadcast:SendAllListings()` — B's listing count should refresh.
- Password-lock `MCMarket` on a third account. Wait for re-validate. Both A and B should converge to `MCMarket1` and messages should still flow.
- Taint log: zero entries.

---

## M4 — UI

**Goal:** The Market window showing browse listings, My Listings panel, search, Whisper button, all via AceGUI-3.0.

### 4.1 Window Structure (AceGUI)

```
AceGUI Frame ("MarketCrafts")
├── AceGUI InlineGroup — "My Listings"
│   ├── ScrollFrame (up to 5 rows)
│   │   └── [itemName] [profession] [X Remove]
│   └── Button — "Add Listing" (opens recipe picker)
│   └── Button — "Refresh My Listings" (15-min cooldown)
└── AceGUI InlineGroup — "Browse"
    ├── EditBox — Search
    └── ScrollFrame — Listing rows
        └── [icon] [itemName] [profession] [seller] [Whisper]
```

### 4.2 UI.lua — Skeleton

```lua
local AddonName, NS = ...
local MC = NS.MC
local AceGUI = LibStub("AceGUI-3.0")
MC.UI = {}

local mainFrame = nil

function MC.UI:Toggle()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    else
        MC.UI:Open()
    end
end

function MC.UI:Open()
    if mainFrame then mainFrame:Release(); mainFrame = nil end

    mainFrame = AceGUI:Create("Frame")
    mainFrame:SetTitle("MarketCrafts")
    mainFrame:SetStatusText("Server-wide crafting service board")
    mainFrame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
        mainFrame = nil
    end)
    mainFrame:SetLayout("Flow")

    MC.UI:BuildMyListingsPanel(mainFrame)
    MC.UI:BuildBrowsePanel(mainFrame)
end

function MC.UI:Refresh()
    if mainFrame then
        MC.UI:Open()  -- rebuild with fresh data
    end
end
```

### 4.3 My Listings Panel

```lua
function MC.UI:BuildMyListingsPanel(parent)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle("My Listings")
    group:SetFullWidth(true)
    group:SetLayout("List")
    parent:AddChild(group)

    local listings = MC.db.char.myListings
    if #listings == 0 then
        local label = AceGUI:Create("Label")
        label:SetText("No active listings.")
        group:AddChild(label)
    else
        for _, entry in ipairs(listings) do
            local row = AceGUI:Create("SimpleGroup")
            row:SetFullWidth(true)
            row:SetLayout("Flow")

            local lbl = AceGUI:Create("Label")
            lbl:SetText(string.format("[%s] %s", entry.profName, entry.itemName))
            lbl:SetRelativeWidth(0.75)
            row:AddChild(lbl)

            local removeBtn = AceGUI:Create("Button")
            removeBtn:SetText("Remove")
            removeBtn:SetRelativeWidth(0.25)
            removeBtn:SetCallback("OnClick", function()
                MC:RemoveMyListing(entry.itemID)
                MC.UI:Refresh()
            end)
            row:AddChild(removeBtn)
            group:AddChild(row)
        end
    end

    -- Buttons row
    local btnRow = AceGUI:Create("SimpleGroup")
    btnRow:SetFullWidth(true)
    btnRow:SetLayout("Flow")

    if #listings < 5 then
        local addBtn = AceGUI:Create("Button")
        addBtn:SetText("Add Listing")
        addBtn:SetCallback("OnClick", function()
            -- Recipe picker: future widget; for now print instructions
            MC:Print("Recipe picker not yet implemented — use /run MarketCrafts:AddMyListing(itemID, prof, name)")
        end)
        btnRow:AddChild(addBtn)
    end

    local refreshBtn = AceGUI:Create("Button")
    local now = time()
    local cd = MC.db.char.settings.refreshCooldown
    local last = MC.db.char.settings.lastBroadcast
    local remaining = cd - (now - last)
    if remaining > 0 then
        refreshBtn:SetText(string.format("Refresh (%ds)", remaining))
        refreshBtn:SetDisabled(true)
    else
        refreshBtn:SetText("Refresh My Listings")
        refreshBtn:SetCallback("OnClick", function()
            MC.db.char.settings.lastBroadcast = time()
            MC.Broadcast:SendAllListings()
            MC.UI:Refresh()
        end)
    end
    btnRow:AddChild(refreshBtn)
    group:AddChild(btnRow)
end
```

### 4.4 Browse Panel

```lua
function MC.UI:BuildBrowsePanel(parent)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle("Browse")
    group:SetFullWidth(true)
    group:SetLayout("List")
    parent:AddChild(group)

    -- Search box
    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search (item, profession, seller):")
    searchBox:SetFullWidth(true)
    searchBox:SetCallback("OnTextChanged", function(widget)
        MC.UI.searchFilter = widget:GetText():lower()
        MC.UI:RebuildBrowseRows(group)
    end)
    group:AddChild(searchBox)

    MC.UI.browseGroup = group
    MC.UI.searchFilter = ""
    MC.UI:RebuildBrowseRows(group)
end

function MC.UI:RebuildBrowseRows(parent)
    -- Release the previous scroll frame to prevent widget accumulation on each search keystroke.
    if MC.UI.browseScrollFrame then
        MC.UI.browseScrollFrame:Release()
        MC.UI.browseScrollFrame = nil
    end

    local listings = MC.Cache:GetVisible(MC.UI.searchFilter)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)

    -- Header row
    local header = AceGUI:Create("SimpleGroup")
    header:SetFullWidth(true)
    header:SetLayout("Flow")
    for _, col in ipairs({ "Item", "Profession", "Seller", "" }) do
        local h = AceGUI:Create("Label")
        h:SetText(col)
        h:SetRelativeWidth(col == "" and 0.15 or 0.28)
        header:AddChild(h)
    end
    scroll:AddChild(header)

    if #listings == 0 then
        local empty = AceGUI:Create("Label")
        -- Friendly first-run message: distinguishes "empty market" from "addon broken".
        empty:SetText("No listings found. Be the first to list — opt in and add a recipe under My Listings!")
        empty:SetFullWidth(true)
        scroll:AddChild(empty)
    else
        for _, entry in ipairs(listings) do
            local row = AceGUI:Create("SimpleGroup")
            row:SetFullWidth(true)
            row:SetLayout("Flow")

            -- Icon
            local icon = AceGUI:Create("Icon")
            icon:SetImage(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
            icon:SetImageSize(16, 16)
            icon:SetWidth(20)
            row:AddChild(icon)

            local nameLbl = AceGUI:Create("Label")
            nameLbl:SetText(entry.itemName)
            nameLbl:SetRelativeWidth(0.26)
            row:AddChild(nameLbl)

            local profLbl = AceGUI:Create("Label")
            profLbl:SetText(entry.profName)
            profLbl:SetRelativeWidth(0.27)
            row:AddChild(profLbl)

            local sellerLbl = AceGUI:Create("Label")
            sellerLbl:SetText(entry.seller)
            sellerLbl:SetRelativeWidth(0.27)
            row:AddChild(sellerLbl)

            local whisperBtn = AceGUI:Create("Button")
            whisperBtn:SetText("Whisper")
            whisperBtn:SetRelativeWidth(0.15)
            local seller = entry.seller
            whisperBtn:SetCallback("OnClick", function()
                ChatFrame_OpenChat("/w " .. seller .. " ")
            end)
            row:AddChild(whisperBtn)
            scroll:AddChild(row)
        end
    end

    -- Status line
    local sellers = {}
    for _, e in ipairs(listings) do sellers[e.seller] = true end
    local sellerCount = 0
    for _ in pairs(sellers) do sellerCount = sellerCount + 1 end
    local status = AceGUI:Create("Label")
    status:SetText(string.format("Showing %d listings from %d sellers", #listings, sellerCount))
    status:SetFullWidth(true)
    scroll:AddChild(status)

    MC.UI.browseScrollFrame = scroll
    parent:AddChild(scroll)
end
```

### M4 Verification

- `/mc` opens window without error.
- Listings from M3 test appear in Browse panel.
- Search text filters rows in real-time.
- Whisper button opens the chat input with `/w PlayerName ` pre-filled.
- Remove button in My Listings removes from DB and refreshes UI.
- Refresh button is greyed out within 15 min of last broadcast.
- Check for taint: zero entries, especially around button callbacks.

---

## M5 — Cache, TTL, Validation, and Anti-Abuse

**Goal:** In-memory peer listing cache with 30-min TTL, rate limiting, validation, blocklist, and async icon resolution.

### Cache.lua

```lua
local AddonName, NS = ...
local MC = NS.MC
MC.Cache = {}

-- listings[seller][itemID] = entry
local listings  = {}
-- rateLimiter[sender] = { count, windowStart }
local rateTracker = {}
-- pendingIcons[itemID] = true — waiting for GET_ITEM_INFO_RECEIVED
local pendingIcons = {}

local TTL          = 1800  -- 30 minutes
local RATE_LIMIT   = 10    -- messages per minute per sender
local MAX_LISTINGS = 5

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
            rt.count = rt.count + 1
            if rt.count > RATE_LIMIT then return end
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
    }

    -- Kick off async icon resolution
    local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(entry.itemID)
    if icon then
        senderListings[entry.itemID].itemIcon = icon
        if name then senderListings[entry.itemID].itemName = name end  -- use locale-correct name if available
    else
        pendingIcons[entry.itemID] = true
        -- 30-second fallback: stop waiting, show question mark
        MC:ScheduleTimer(function()
            pendingIcons[entry.itemID] = nil
        end, 30)
    end

    MC.UI:Refresh()
end

function MC.Cache:Remove(seller, itemID)
    if listings[seller] then
        listings[seller][itemID] = nil
        if not next(listings[seller]) then
            listings[seller] = nil
        end
        MC.UI:Refresh()
    end
end

-- Returns a flat list of non-expired, non-blocked entries matching the filter
function MC.Cache:GetVisible(filter)
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
    table.sort(result, function(a, b) return a.itemName < b.itemName end)
    return result
end

function MC.Cache:Ignore(name)
    MC.db.char.blocklist[name] = true
    MC.UI:Refresh()
end

function MC.Cache:Unignore(name)
    MC.db.char.blocklist[name] = nil
    MC.UI:Refresh()
end

-- Periodic purge of expired entries from memory (every 5 min)
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

-- Async icon resolution
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
        MC.UI:Refresh()
    end
end

function MC.Cache:Enable()
    MC:ScheduleRepeatingTimer(PurgeExpired, 300)  -- every 5 minutes
    MC:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID)
        MC.Cache:OnGetItemInfoReceived(nil, itemID)
    end)
end
```

Both `MC.Cache:Enable()` and `MC.Listener:Enable()` are wired into `MC:OnEnable()` — see Phase 0 for the updated code. The `listings[seller]` reference in `Remove` is already correct in the code above.

### M5 Verification

- Receive a valid listing — appears in UI with icon (or question mark if uncached).
- Set `receivedAt` to 31 minutes ago manually and trigger purge — entry disappears.
- Send 11 consecutive messages rapidly from a test account — 11th is silently dropped.
- Send a 6th listing from one account — silently ignored.
- `/mc ignore TestPlayer` — TestPlayer's rows vanish from Browse.
- `/mc unignore TestPlayer` — rows return.
- Set `GET_ITEM_INFO_RECEIVED` to fire for a pending icon — icon should update and UI refresh.

---

## M6 — Polish

These are quality-of-life improvements. Each is independent and can be shipped separately after M5.

### 6.1 Sort / Filter Controls

Add a sort dropdown above the Browse scroll frame:

```lua
local sortDropdown = AceGUI:Create("Dropdown")
sortDropdown:SetLabel("Sort by")
sortDropdown:SetList({ itemName = "Item Name", profName = "Profession", seller = "Seller" })
sortDropdown:SetValue("itemName")
sortDropdown:SetCallback("OnValueChanged", function(widget, _, key)
    MC.UI.sortKey = key
    MC.UI:RebuildBrowseRows(MC.UI.browseGroup)
end)
```

Pass `MC.UI.sortKey` into `Cache:GetVisible()` and sort accordingly.

### 6.2 Cooldown UI on Refresh Button

Replace the static "Refresh (Xs)" label with a live countdown. Use an `AceTimer-3.0` one-shot to re-enable the button when the cooldown expires, rather than polling every second.

```lua
local remaining = MC.db.char.settings.refreshCooldown - (time() - MC.db.char.settings.lastBroadcast)
if remaining > 0 then
    refreshBtn:SetText(string.format("Refresh (%ds)", math.ceil(remaining)))
    refreshBtn:SetDisabled(true)
    MC:ScheduleTimer(function()
        -- Re-enable the button when cooldown expires
        if mainFrame then MC.UI:Refresh() end
    end, remaining)
end
```

### 6.3 Spam-Filter Back-off

Expand the `CHAT_MSG_SYSTEM` handler in Listener.lua to detect the exact throttle message text for TBC Classic (test empirically — common strings include "flooded" and "throttled"). When detected:

1. Clear the send queue immediately.
2. Increase `MESSAGE_SPACING` to 3 seconds for the next 5 minutes.
3. Resume normal spacing after the back-off window.

### 6.4 Channel Status Indicator

Add a small status label to the window title or status bar indicating the current channel:

```lua
if MC.Channel:IsActive() then
    mainFrame:SetStatusText("Channel: " .. (MC.Channel:GetActiveChannelName() or "unknown"))
else
    mainFrame:SetStatusText("Market unavailable — channel not joined")
end
```

`GetActiveChannelName()` is the public getter defined in `Channel.lua` — `activeIndex` itself is a local upvalue and not directly accessible.

### 6.5 Recipe Picker (Add Listing dialog)

When "Add Listing" is clicked, open a secondary AceGUI window with:

- A profession dropdown (Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring).
- A text search box to find recipes by name.
- A list of known recipes (populated by `GetTradeSkillInfo` / `GetTradeSkillItemLink` — iterate trade skill lines).
- A "List This" button that calls `MC:AddMyListing(itemID, profName, itemName)`.

**Note:** `GetTradeSkillInfo` requires the corresponding tradeskill window to be open. Do **not** attempt `CastSpellByName` to open it — that call is protected in TBC Classic and reliably causes taint, which can corrupt action bars. Instead, display a prompt: *"Please open your profession window, then click Add Listing."* Once the window is open the addon can scan it freely without any protected API calls.

---

## Cross-Cutting Concerns

### Error Handling

All event callbacks and timer callbacks must be wrapped in `pcall` or use AceAddon's built-in error isolation. Do not let a single malformed message crash the addon. Pattern:

```lua
MC:RegisterEvent("CHAT_MSG_CHANNEL", function(_, ...)
    local ok, err = pcall(function() MC.Listener:OnChatMsgChannel(...) end)
    if not ok then
        -- Silent: don't print to the user for every malformed message
        -- BugGrabber will capture it
    end
end)
```

### Taint Safety

Rules to follow throughout development:

- Never modify secure frames from within event callbacks that fire during combat or from `ChatFrame_AddMessageEventFilter`.
- Only call `CloseDropDownMenus()`, `StaticPopup_*`, and similar protected functions outside of combat.
- Never store references to Blizzard secure frames in addon upvalues.
- Run `/run SetCVar("taintLog", 1)` before every test session and check logs after.

### AceDB Profile Mode

`AceDB-3.0:New("MarketCraftsDB", defaults, true)` — the third argument `true` sets **character scope** as the default profile. This means `self.db.char` is per-character. Do not use `self.db.profile` or `self.db.realm` — those are wrong scopes for this addon.

### `LeaveChannelByName` — TBC API Verification

Empirically verify that `LeaveChannelByName(name)` exists in the TBC 2.5.5 API before M1 goes to a live realm. If it does not exist, the alternative is:

```lua
-- Fallback: find the channel's WoW slot and call LeaveChannel(index)
local function LeaveByName(name)
    local index = GetChannelName(name)
    if index and index > 0 then
        LeaveChannel(index)
    end
end
```

Use `if LeaveChannelByName then ... else ... end` for the guard.

---

## Testing Plan

### Per-Milestone Acceptance Criteria

| Milestone | Pass Criteria |
|---|---|
| Phase 0 | Addon loads. `/mc help` works. Zero Lua errors. Zero taint. |
| M1 | Join/leave cycle works. Re-validate moves to lower channel after lock clears. Per-step timeout fires correctly. All fallbacks exhausted → correct user message. Two accounts exchange no data yet. |
| M2 | Listings persist across `/reload`. Cap at 5 enforced. Remove works. |
| M3 | Two accounts: A broadcasts, B receives. No `[MCR]` visible in any chat frame. Throttle detection clears queue. Taint log clean. |
| M4 | Window opens. Browse and My Listings render. Whisper pre-fills chat. Search filters. Refresh cooldown enforced. |
| M5 | Items expire after 30 min. Rate limiter blocks floods. 6th listing from peer is dropped. Blocklist persists. Icon async resolution works. |
| M6 | Sort works. Cooldown countdown accurate. Spam back-off delays subsequent messages. Channel status shows in window. |

### Regression Tests After Each Milestone

- Zero Lua errors in BugSack after each `/reload`.
- Zero entries in taint log after each play session.
- All slash commands still respond correctly.
- Channel re-validate does not cause visible disruption to a seller mid-session.

### Final Integration Test (Before Release)

1. Three accounts on the same realm.
2. Account A: opted in, 5 listings from different professions.
3. Account B: no listings, browsing.
4. Account C: no MarketCrafts — confirm they see raw `[MCR]L:` messages in their channel list (visible by design) and can read them.
5. Have account D (no addon) password-lock `MCMarket`. Wait for A and B to converge to `MCMarket1`. Password-lock `MCMarket1`. Both should fall to `MCMarket2`. Unlock `MCMarket`. A and B should converge back within 10 minutes.
6. Flood test: script account D to send `[MCR]L:` messages rapidly via chat macro. A and B should rate-limit and not display D's 11th+ listing.
7. Check Blizzard spam filter: back-off triggers, queue clears, normal operation resumes.
