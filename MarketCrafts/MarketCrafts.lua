-- MarketCrafts.lua — Addon Core (Phase 0 + M2 Listing Management)
local AddonName, NS = ...

local MC = LibStub("AceAddon-3.0"):NewAddon("MarketCrafts", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
NS.MC = MC

---------------------------------------------------------------------------
-- SavedVariables defaults (character-scoped + account-scoped)
---------------------------------------------------------------------------
local DB_DEFAULTS = {
    global = {
        -- F5: account-scoped alt listings — shared across all characters on this
        -- account/install. Keyed by "RealmName-CharName".
        altListings = {},
    },
    char = {
        myListings  = {},   -- up to 5 entries: { itemID, profName, itemName }
        myRequests  = {},   -- F7: up to 3 buyer WTB requests: { itemName, note }
        blocklist   = {},   -- { ["PlayerName"] = true }
        favorites   = {},   -- { ["PlayerName"] = true }
        settings    = {
            optedIn           = false,
            lastBroadcast     = 0,    -- time() of last manual broadcast
            refreshCooldown   = 900,  -- 15 min in seconds
            minimapAngle      = 225,  -- degrees; 225 = bottom-left of minimap ring
            whisperTemplate   = "/w {seller} Hi, I'd like to get {item} crafted!",
        },
    },
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function MC:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("MarketCraftsDB", DB_DEFAULTS, true)
    -- true = use character scope by default

    self:RegisterChatCommand("mc", "HandleSlashCommand")

    -- Expose global so /run MarketCrafts:AddMyListing(...) works
    _G["MarketCrafts"] = self
end

function MC:OnEnable()
    MC.Channel:Enable()
    MC.ChatFilter:Enable()
    MC.Listener:Enable()    -- registers CHAT_MSG_CHANNEL + CHAT_MSG_SYSTEM
    MC.Cache:Enable()       -- starts purge timer + GET_ITEM_INFO_RECEIVED
    MC.Requests:Enable()    -- F7: starts request purge timer
    MC.MinimapButton:Create()
end

function MC:OnDisable()
    MC.Channel:Disable()
    MC.ChatFilter:Disable()
    MC.Listener:Disable()
    MC.Cache:Disable()
    MC.Broadcast:StopKeepAlive()
    MC.Broadcast:ClearQueue()
end

---------------------------------------------------------------------------
-- Slash Commands
---------------------------------------------------------------------------
function MC:HandleSlashCommand(input)
    local cmd, arg = input:match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        MC.UI:Toggle()
    elseif cmd == "optin" then
        MC:OptIn()
    elseif cmd == "optout" then
        MC.db.char.settings.optedIn = false
        MC.Broadcast:StopKeepAlive()
        MC.Broadcast:ClearQueue()
        MC:Print("You are now opted out. Your listings will no longer be broadcast.")
    elseif cmd == "ignore" and arg ~= "" then
        MC.Cache:Ignore(arg)
        MC:Print("Ignored: " .. arg)
    elseif cmd == "unignore" and arg ~= "" then
        MC.Cache:Unignore(arg)
        MC:Print("Unignored: " .. arg)
    elseif cmd == "list" then
        MC:PrintMyListings()
    elseif cmd == "debug" then
        MC.debugMode = not MC.debugMode
        MC:Print("Debug mode: " .. (MC.debugMode and "ON" or "OFF"))
        if MC.debugMode then
            MC:Print("Cache size: " .. MC.Cache:GetCacheSize() .. " listing(s)")
        end
    elseif cmd == "template" then
        if arg ~= "" then
            MC.db.char.settings.whisperTemplate = arg:sub(1, 200)
            MC:Print("Whisper template set: " .. MC.db.char.settings.whisperTemplate)
        else
            MC:Print("Template: " .. (MC.db.char.settings.whisperTemplate or "(none)"))
            MC:Print("Tokens: {seller}, {item}, {prof}")
        end
    elseif cmd == "favorites" then
        local count = 0
        for name in pairs(MC.db.char.favorites) do
            MC:Print("★ " .. name)
            count = count + 1
        end
        if count == 0 then MC:Print("No favourite sellers.") end
    elseif cmd == "importalt" then
        -- F5: snapshot current char's listings into the account-scoped alt store
        MC:ImportAlt()
    elseif cmd == "request" then
        -- F7: open main window directly on the Requests tab
        MC.UI:Open("requests")
    elseif cmd == "sim" then
        MC.MockData:HandleSimCommand(arg)
    elseif cmd == "help" then
        MC:Print("/mc — toggle window")
        MC:Print("/mc optin — start broadcasting your listings")
        MC:Print("/mc optout — stop broadcasting your listings")
        MC:Print("/mc ignore <Player> — block player's listings")
        MC:Print("/mc unignore <Player> — unblock player")
        MC:Print("/mc list — show your active listings")
        MC:Print("/mc importalt — save current char's listings as alt profile (all chars broadcast them)")
        MC:Print("/mc request — open Requests tab (WTB board)")
        MC:Print("/mc debug — toggle debug mode")
        MC:Print("/mc sim <N> — inject N fake sellers (debug mode)")
        MC:Print("/mc sim clear — remove simulated data")
        MC:Print("/mc template [text] — view/set whisper template ({seller},{item},{prof})")
        MC:Print("/mc favorites — list starred sellers")
        MC:Print("/mc unignore <Player> — unblock (or right-click seller in Browse)")
    else
        MC:Print("Unknown command. Type /mc help.")
    end
end

function MC:OptIn()
    self.db.char.settings.optedIn = true
    self:Print("You are now opted in. Your listings will be broadcast to other players.")
    if MC.Channel:IsActive() then
        MC.Broadcast:SendAllListings()
    else
        self:Print("(Waiting for channel — listings will broadcast once connected.)")
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

---------------------------------------------------------------------------
-- M2 — Listing Management API
---------------------------------------------------------------------------

-- Add or update a listing (upsert by itemID)
function MC:AddMyListing(itemID, profName, itemName, note, cdSeconds)
    -- Normalise note: nil or blank → nil; otherwise trim to 60 chars
    local cleanNote = (note and note:match("^%s*(.-)%s*$") or "")
    cleanNote = (cleanNote ~= "") and cleanNote:sub(1, 60) or nil
    local now = time()
    local listings = self.db.char.myListings
    -- Check for existing entry to update
    for _, entry in ipairs(listings) do
        if entry.itemID == itemID then
            entry.profName    = profName
            entry.itemName    = itemName
            entry.note        = cleanNote
            -- F6: update cooldown snapshot if a fresh reading was provided
            if cdSeconds ~= nil then
                entry.cdSeconds   = cdSeconds
                entry.cdUpdatedAt = now
            end
            MC.Broadcast:SendListing(entry)
            return true
        end
    end
    if #listings >= 5 then
        MC:Print("You can only list up to 5 recipes.")
        return false
    end
    local newEntry = {
        itemID      = itemID,
        profName    = profName,
        itemName    = itemName,
        note        = cleanNote,
        -- F6: cdSeconds = nil means "no cooldown"; otherwise the remaining seconds at cdUpdatedAt
        cdSeconds   = cdSeconds,
        cdUpdatedAt = (cdSeconds ~= nil) and now or nil,
    }
    table.insert(listings, newEntry)
    MC.Broadcast:SendListing(listings[#listings])
    return true
end

-- Remove a listing by itemID
function MC:RemoveMyListing(itemID)
    local listings = self.db.char.myListings
    for i, entry in ipairs(listings) do
        if entry.itemID == itemID then
            table.remove(listings, i)
            MC.Broadcast:SendRemove(itemID)
            return true
        end
    end
    return false
end

function MC:GetMyListings()
    return self.db.char.myListings
end

---------------------------------------------------------------------------
-- F7 — Buyer request management
---------------------------------------------------------------------------

function MC:AddMyRequest(itemName, note)
    if not itemName or itemName == "" then return false end
    local cleanNote = (note and note:match("^%s*(.-)%s*$") or "")
    cleanNote = (cleanNote ~= "") and cleanNote:sub(1, 60) or nil
    local requests = self.db.char.myRequests
    local nameKey = itemName:lower()
    for _, entry in ipairs(requests) do
        if entry.itemName:lower() == nameKey then
            entry.itemName = itemName
            entry.note     = cleanNote
            MC.Broadcast:SendRequest(entry)
            return true
        end
    end
    if #requests >= 3 then
        MC:Print("You can only post up to 3 requests.")
        return false
    end
    local newEntry = { itemName = itemName, note = cleanNote }
    table.insert(requests, newEntry)
    MC.Broadcast:SendRequest(requests[#requests])
    return true
end

function MC:RemoveMyRequest(itemName)
    if not itemName or itemName == "" then return false end
    local requests = self.db.char.myRequests
    local nameKey = itemName:lower()
    for i, entry in ipairs(requests) do
        if entry.itemName:lower() == nameKey then
            table.remove(requests, i)
            MC.Broadcast:SendRequestRemove(entry.itemName)
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- F5 — Alt listing import/export
---------------------------------------------------------------------------

-- Snapshot the current character's listings into the account-scoped alt store.
-- The snapshot is keyed by "Realm-CharName" and can be read by any character
-- on the same account/installation so they can broadcast it during keep-alives.
function MC:ImportAlt()
    local realm    = GetRealmName() or "Unknown"
    local charName = UnitName("player") or "Unknown"
    local key      = realm .. "-" .. charName
    local listings = self.db.char.myListings
    if #listings == 0 then
        self:Print("Nothing to import — your My Listings panel is empty.")
        return
    end
    -- Deep-copy; omit runtime/volatile fields (cdSeconds becomes stale quickly)
    local copy = {}
    for _, entry in ipairs(listings) do
        table.insert(copy, {
            itemID   = entry.itemID,
            profName = entry.profName,
            itemName = entry.itemName,
            note     = entry.note,
        })
    end
    self.db.global.altListings[key] = copy
    self:Print(string.format(
        "Saved %d listing(s) as alt profile '%s'. Other characters on this account will now broadcast them.",
        #copy, charName))
    MC.UI:RefreshMyListings()
end

-- Printf convenience (same as GuildCrafts)
function MC:Printf(fmt, ...)
    self:Print(string.format(fmt, ...))
end
