-- MarketCrafts.lua — Addon Core (Phase 0 + M2 Listing Management)
local AddonName, NS = ...

local MC = LibStub("AceAddon-3.0"):NewAddon("MarketCrafts", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
NS.MC = MC

---------------------------------------------------------------------------
-- SavedVariables defaults (character-scoped)
---------------------------------------------------------------------------
local DB_DEFAULTS = {
    char = {
        myListings  = {},   -- up to 5 entries: { itemID, profName, itemName }
        blocklist   = {},   -- { ["PlayerName"] = true }
        settings    = {
            optedIn         = false,
            lastBroadcast   = 0,    -- time() of last manual broadcast
            refreshCooldown = 900,  -- 15 min in seconds
            minimapAngle    = 225,  -- degrees; 225 = bottom-left of minimap ring
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
    MC.Listener:Enable()   -- registers CHAT_MSG_CHANNEL + CHAT_MSG_SYSTEM
    MC.Cache:Enable()      -- starts purge timer + GET_ITEM_INFO_RECEIVED
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
        MC.db.char.settings.optedIn = true
        MC:Print("You are now opted in. Your listings will be broadcast to other players.")
        MC.Broadcast:SendAllListings()
    elseif cmd == "optout" then
        MC.db.char.settings.optedIn = false
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
    elseif cmd == "sim" then
        MC.MockData:HandleSimCommand(arg)
    elseif cmd == "help" then
        MC:Print("/mc \xe2\x80\x94 toggle window")
        MC:Print("/mc optin \xe2\x80\x94 start broadcasting your listings")
        MC:Print("/mc optout \xe2\x80\x94 stop broadcasting your listings")
        MC:Print("/mc ignore <Player> \xe2\x80\x94 block player's listings")
        MC:Print("/mc unignore <Player> \xe2\x80\x94 unblock player")
        MC:Print("/mc list \xe2\x80\x94 show your active listings")
        MC:Print("/mc debug \xe2\x80\x94 toggle debug mode")
        MC:Print("/mc sim <N> \xe2\x80\x94 inject N fake sellers (debug mode)")
        MC:Print("/mc sim clear \xe2\x80\x94 remove simulated data")
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
        self:Print(string.format("[%d] %s \xe2\x80\x94 %s", i, l.itemName, l.profName))
    end
end

---------------------------------------------------------------------------
-- M2 — Listing Management API
---------------------------------------------------------------------------

-- Add or update a listing (upsert by itemID)
function MC:AddMyListing(itemID, profName, itemName)
    local listings = self.db.char.myListings
    -- Check for existing entry to update
    for _, entry in ipairs(listings) do
        if entry.itemID == itemID then
            entry.profName = profName
            entry.itemName = itemName
            MC.Broadcast:SendListing(entry)
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
            MC.Broadcast:SendRemove(itemID)
            return true
        end
    end
    return false
end

function MC:GetMyListings()
    return self.db.char.myListings
end

-- Printf convenience (same as GuildCrafts)
function MC:Printf(fmt, ...)
    self:Print(string.format(fmt, ...))
end
