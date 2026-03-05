-- UI.lua — M4: AceGUI-based Market window
-- My Listings panel, Browse panel with search/scroll/Whisper, channel status.
local AddonName, NS = ...
local MC = NS.MC
local AceGUI = LibStub("AceGUI-3.0")
MC.UI = {}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local mainFrame = nil
local refreshTimer = nil   -- debounce timer for Refresh()
local FillMyListings       -- forward declaration; assigned before BuildMyListingsPanel
local MCBlocklistMenuFrame -- F11: context menu frame (created once, reused)

---------------------------------------------------------------------------
-- Toggle / Open / Refresh
---------------------------------------------------------------------------
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
    mainFrame:SetLayout("Flow")
    mainFrame:SetWidth(660)
    mainFrame:SetHeight(540)

    -- Register with UISpecialFrames so the Escape key closes this window.
    -- AceGUI Frame does not do this itself. Frame_OnClose fires on :Hide(), so
    -- WoW's Escape handler will correctly trigger our OnClose callback.
    _G["MarketCraftsMainFrame"] = mainFrame.frame
    local _mcFound = false
    for _, _n in ipairs(UISpecialFrames) do
        if _n == "MarketCraftsMainFrame" then _mcFound = true; break end
    end
    if not _mcFound then tinsert(UISpecialFrames, "MarketCraftsMainFrame") end

    -- Channel status indicator (M6.4)
    if MC.Channel:IsActive() then
        mainFrame:SetStatusText("Channel: " .. (MC.Channel:GetActiveChannelName() or "unknown"))
    else
        mainFrame:SetStatusText("Market unavailable — channel not joined")
    end

    mainFrame:SetCallback("OnClose", function(widget)
        -- Clear all cached widget references so stale refs don't survive a re-open
        MC.UI.browseScrollFrame = nil
        MC.UI.browseGroup       = nil
        MC.UI.myListingsGroup   = nil
        MC.UI.profChipsRow      = nil
        AceGUI:Release(widget)
        mainFrame = nil
    end)

    MC.UI:BuildMyListingsPanel(mainFrame)
    MC.UI:BuildBrowsePanel(mainFrame)
end

-- Update only the status bar text of an already-open window.
-- Called by Channel after settling so the user doesn't have to reopen the UI.
function MC.UI:UpdateStatus()
    if not mainFrame then return end
    if MC.Channel:IsActive() then
        mainFrame:SetStatusText("Channel: " .. (MC.Channel:GetActiveChannelName() or "unknown"))
    else
        mainFrame:SetStatusText("Market unavailable — channel not joined")
    end
end

-- F9: freshness label text + r,g,b colour for Browse rows
function MC.UI:FormatAge(receivedAt)
    local age = time() - receivedAt
    if age < 300 then
        return " (just now)", 0.3, 1.0, 0.3
    elseif age < 900 then
        return string.format(" (%dm ago)", math.floor(age / 60)), 1.0, 1.0, 0.3
    else
        return string.format(" (%dm ago)", math.floor(age / 60)), 0.6, 0.6, 0.6
    end
end

-- F6: Format a cooldown value applying client-side decay since the broadcast.
-- Returns a display string plus r, g, b colour components.
function MC.UI:FormatCooldown(cdSeconds, receivedAt)
    local remaining = math.max(0, cdSeconds - (time() - receivedAt))
    if remaining == 0 then
        return "CD: Ready", 0.2, 1.0, 0.2   -- green
    end
    local days  = math.floor(remaining / 86400)
    local hours = math.floor((remaining % 86400) / 3600)
    local mins  = math.floor((remaining % 3600) / 60)
    local text
    if days > 0 then
        text = string.format("CD: %dd %dh", days, hours)
    elseif hours > 0 then
        text = string.format("CD: %dh %dm", hours, mins)
    else
        text = string.format("CD: %dm", math.max(1, mins))
    end
    return text, 0.6, 0.6, 0.6   -- grey
end

function MC.UI:Refresh()
    if not mainFrame then return end
    -- Debounce: coalesce rapid-fire refreshes (e.g. during sim injection)
    -- into a single rebuild after 0.1s of quiet.
    if refreshTimer then MC:CancelTimer(refreshTimer) end
    refreshTimer = MC:ScheduleTimer(function()
        refreshTimer = nil
        if mainFrame then MC.UI:Open() end
    end, 0.1)
end

-- Partial refresh: rebuild only the My Listings panel in-place (no full window teardown)
function MC.UI:RefreshMyListings()
    if not mainFrame then return end
    if not MC.UI.myListingsGroup then MC.UI:Refresh(); return end
    if refreshTimer then MC:CancelTimer(refreshTimer) end
    refreshTimer = MC:ScheduleTimer(function()
        refreshTimer = nil
        if not mainFrame or not MC.UI.myListingsGroup then return end
        local g = MC.UI.myListingsGroup
        g:SetTitle(string.format("My Listings (%d/5)", #MC.db.char.myListings))
        g:ReleaseChildren()
        FillMyListings(g)
    end, 0.1)
end

-- Partial refresh: rebuild only the Browse rows (preserves scroll position)
function MC.UI:RefreshBrowse()
    if not mainFrame then return end
    if not MC.UI.browseGroup then MC.UI:Refresh(); return end
    if refreshTimer then MC:CancelTimer(refreshTimer) end
    refreshTimer = MC:ScheduleTimer(function()
        refreshTimer = nil
        if mainFrame and MC.UI.browseGroup then
            MC.UI:RebuildBrowseRows(MC.UI.browseGroup)
        end
    end, 0.1)
end

---------------------------------------------------------------------------
-- My Listings Panel
---------------------------------------------------------------------------
-- Inner content builder — called by BuildMyListingsPanel on initial build
-- and by RefreshMyListings for in-place updates.
FillMyListings = function(group)
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
            -- F1: display crafter note inline when present
            local noteStr = (entry.note and entry.note ~= "")
                and (" |cFF888888\226\128\148 " .. entry.note .. "|r")
                or ""
            lbl:SetText(string.format("[%s] %s", entry.profName, entry.itemName) .. noteStr)
            lbl:SetRelativeWidth(0.75)
            row:AddChild(lbl)

            local removeBtn = AceGUI:Create("Button")
            removeBtn:SetText("Remove")
            removeBtn:SetRelativeWidth(0.25)
            removeBtn:SetCallback("OnClick", function()
                MC:RemoveMyListing(entry.itemID)
                MC.UI:RefreshMyListings()
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
        addBtn:SetText("Add from Profession")
        addBtn:SetCallback("OnClick", function()
            local n = GetNumTradeSkills and GetNumTradeSkills() or 0
            if n == 0 then
                MC:Print("Open a Profession window first, then click 'Add from Profession' again.")
                return
            end
            MC.UI:OpenProfessionPicker()
        end)
        btnRow:AddChild(addBtn)
    end

    local refreshBtn = AceGUI:Create("Button")
    local now = time()
    local cd = MC.db.char.settings.refreshCooldown
    local last = MC.db.char.settings.lastBroadcast
    local remaining = cd - (now - last)
    if remaining > 0 then
        refreshBtn:SetText(string.format("Refresh (%ds)", math.ceil(remaining)))
        refreshBtn:SetDisabled(true)
        -- Re-enable when cooldown expires — target the button directly to avoid a full rebuild
        MC:ScheduleTimer(function()
            if refreshBtn and refreshBtn.frame and refreshBtn.frame:IsShown() then
                refreshBtn:SetDisabled(false)
                refreshBtn:SetText("Refresh My Listings")
                refreshBtn:SetCallback("OnClick", function()
                    MC.db.char.settings.lastBroadcast = time()
                    MC.Broadcast:SendAllListings()
                    MC.UI:Refresh()
                end)
            end
        end, remaining)
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

    -- Hint: tell the user they need an open profession window first.
    if #listings < 5 then
        local hint = AceGUI:Create("Label")
        hint:SetText("|cffaaaaaa Tip: open a Profession window from your spellbook, then click 'Add from Profession'.|r")
        hint:SetFullWidth(true)
        group:AddChild(hint)
    end

    -- F5: Alt Listings — entries imported from other characters on this account.
    -- Only shown when at least one alt profile exists.
    local altListings  = MC.db.global and MC.db.global.altListings or {}
    local myRealm      = GetRealmName() or ""
    local myChar       = UnitName("player") or ""
    local myKey        = myRealm .. "-" .. myChar
    local altCount     = 0
    for k, entries in pairs(altListings) do
        if k ~= myKey and entries then altCount = altCount + #entries end
    end

    if altCount > 0 then
        local altHeader = AceGUI:Create("Heading")
        altHeader:SetText("Alt Listings (broadcasting on your behalf)")
        altHeader:SetFullWidth(true)
        group:AddChild(altHeader)

        for key, entries in pairs(altListings) do
            if key ~= myKey and entries and #entries > 0 then
                -- Extract character name from "Realm-CharName" key
                local altName = key:match("%-(.+)$") or key
                for _, entry in ipairs(entries) do
                    local row = AceGUI:Create("SimpleGroup")
                    row:SetFullWidth(true)
                    row:SetLayout("Flow")

                    local noteStr = (entry.note and entry.note ~= "")
                        and (" |cFF888888\226\128\148 " .. entry.note .. "|r")
                        or ""
                    local lbl = AceGUI:Create("Label")
                    lbl:SetText(string.format("|cFFAAAAFF[%s]|r [%s] %s",
                        altName, entry.profName, entry.itemName) .. noteStr)
                    lbl:SetRelativeWidth(0.75)
                    row:AddChild(lbl)

                    local removeBtn = AceGUI:Create("Button")
                    removeBtn:SetText("Remove")
                    removeBtn:SetRelativeWidth(0.25)
                    local capturedKey = key
                    local capturedID  = entry.itemID
                    removeBtn:SetCallback("OnClick", function()
                        local list = MC.db.global.altListings[capturedKey]
                        if list then
                            for i, e in ipairs(list) do
                                if e.itemID == capturedID then
                                    table.remove(list, i)
                                    break
                                end
                            end
                            if #list == 0 then
                                MC.db.global.altListings[capturedKey] = nil
                            end
                        end
                        MC.UI:RefreshMyListings()
                    end)
                    row:AddChild(removeBtn)
                    group:AddChild(row)
                end
            end
        end

        local clearBtn = AceGUI:Create("Button")
        clearBtn:SetText("Clear All Alt Profiles")
        clearBtn:SetFullWidth(true)
        clearBtn:SetCallback("OnClick", function()
            for k in pairs(MC.db.global.altListings) do
                if k ~= myKey then MC.db.global.altListings[k] = nil end
            end
            MC.UI:RefreshMyListings()
        end)
        group:AddChild(clearBtn)
    end
end

function MC.UI:BuildMyListingsPanel(parent)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle(string.format("My Listings (%d/5)", #MC.db.char.myListings))
    group:SetFullWidth(true)
    group:SetLayout("List")
    parent:AddChild(group)
    MC.UI.myListingsGroup = group
    FillMyListings(group)
end

---------------------------------------------------------------------------
-- Browse Panel
---------------------------------------------------------------------------
function MC.UI:BuildBrowsePanel(parent)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle("Browse")
    group:SetFullWidth(true)
    group:SetLayout("List")
    parent:AddChild(group)

    -- Controls row: search + sort
    local controlRow = AceGUI:Create("SimpleGroup")
    controlRow:SetFullWidth(true)
    controlRow:SetLayout("Flow")

    -- Search box
    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search (item, profession, seller):")
    searchBox:SetRelativeWidth(0.65)
    searchBox:SetCallback("OnTextChanged", function(widget)
        MC.UI.searchFilter = widget:GetText():lower()
        MC.UI:RebuildBrowseRows(group)
    end)
    controlRow:AddChild(searchBox)

    -- Sort dropdown (M6.1)
    local sortDropdown = AceGUI:Create("Dropdown")
    sortDropdown:SetLabel("Sort by")
    sortDropdown:SetRelativeWidth(0.35)
    sortDropdown:SetList({ itemName = "Item Name", profName = "Profession", seller = "Seller" })
    sortDropdown:SetValue(MC.UI.sortKey or "itemName")
    sortDropdown:SetCallback("OnValueChanged", function(widget, _, key)
        MC.UI.sortKey = key
        MC.UI:RebuildBrowseRows(group)
    end)
    controlRow:AddChild(sortDropdown)
    group:AddChild(controlRow)

    -- Profession filter chips (F2) — persistent container, children rebuilt in RebuildBrowseRows
    local profChipsRow = AceGUI:Create("SimpleGroup")
    profChipsRow:SetFullWidth(true)
    profChipsRow:SetLayout("Flow")
    MC.UI.profChipsRow = profChipsRow
    group:AddChild(profChipsRow)

    MC.UI.browseGroup = group
    MC.UI.searchFilter = ""
    MC.UI.profFilter   = nil
    MC.UI:RebuildBrowseRows(group)
end

-- F11: right-click context menu to hide a sender from Browse
local function ShowBlocklistMenu(seller)
    if not MCBlocklistMenuFrame then
        MCBlocklistMenuFrame = CreateFrame("Frame", "MCBlocklistMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end
    local menu = {
        { text = seller, isTitle = true, notCheckable = true },
        { text = "Hide this seller", notCheckable = true, func = function()
            MC.Cache:Ignore(seller)
        end },
        { text = "Cancel", notCheckable = true, func = function() end },
    }
    EasyMenu(menu, MCBlocklistMenuFrame, "cursor", 0, 0, "MENU")
end

function MC.UI:RebuildBrowseRows(parent)
    -- F1: per-row note expansion state — persists across rebuilds within a session
    MC.UI.expandedNotes = MC.UI.expandedNotes or {}

    -- F2: rebuild profession filter chips from the full unfiltered cache
    local profChipsRow = MC.UI.profChipsRow
    if profChipsRow then
        profChipsRow:ReleaseChildren()
        local allListings = MC.Cache:GetVisible("", nil)
        local profSet = {}
        for _, e in ipairs(allListings) do profSet[e.profName] = true end
        local profs = {}
        for p in pairs(profSet) do table.insert(profs, p) end
        table.sort(profs)
        if #profs > 0 then
            local allBtn = AceGUI:Create("Button")
            allBtn:SetText("[All]")
            allBtn:SetWidth(50)
            allBtn:SetDisabled(not MC.UI.profFilter)
            allBtn:SetCallback("OnClick", function()
                MC.UI.profFilter = nil
                MC.UI:RebuildBrowseRows(parent)
            end)
            profChipsRow:AddChild(allBtn)
            for _, p in ipairs(profs) do
                local chipBtn = AceGUI:Create("Button")
                chipBtn:SetText(p)
                chipBtn:SetWidth(90)
                chipBtn:SetDisabled(MC.UI.profFilter == p)
                local pCapture = p
                chipBtn:SetCallback("OnClick", function()
                    MC.UI.profFilter = pCapture
                    MC.UI:RebuildBrowseRows(parent)
                end)
                profChipsRow:AddChild(chipBtn)
            end
        end
    end

    -- Reuse the existing scroll frame and clear its children, rather than
    -- releasing and re-creating it. Releasing doesn't remove the widget from
    -- the parent's children array, which causes stale references and layout bugs.
    local scroll = MC.UI.browseScrollFrame
    if scroll then
        scroll:ReleaseChildren()
    else
        scroll = AceGUI:Create("ScrollFrame")
        scroll:SetLayout("List")
        scroll:SetFullWidth(true)
        scroll:SetHeight(275)
        MC.UI.browseScrollFrame = scroll
        parent:AddChild(scroll)
    end

    local listings = MC.Cache:GetVisible(MC.UI.searchFilter, MC.UI.sortKey)

    -- F2: apply profession filter
    if MC.UI.profFilter then
        local filtered = {}
        for _, e in ipairs(listings) do
            if e.profName == MC.UI.profFilter then table.insert(filtered, e) end
        end
        listings = filtered
    end

    -- F10: sort favourites to the top, then by sortKey
    local favs = MC.db.char.favorites or {}
    if next(favs) then
        local sk = MC.UI.sortKey or "itemName"
        table.sort(listings, function(a, b)
            local af = favs[a.seller] and 1 or 0
            local bf = favs[b.seller] and 1 or 0
            if af ~= bf then return af > bf end
            return (a[sk] or "") < (b[sk] or "")
        end)
    end

    -- Header row
    local header = AceGUI:Create("SimpleGroup")
    header:SetFullWidth(true)
    header:SetLayout("Flow")
    for _, pair in ipairs({ {"Item", 0.27}, {"Profession", 0.22}, {"Seller", 0.31}, {"", 0.18} }) do
        local h = AceGUI:Create("Label")
        h:SetText(pair[1])
        h:SetRelativeWidth(pair[2])
        header:AddChild(h)
    end
    scroll:AddChild(header)

    if #listings == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetText("No listings found. Be the first to list — opt in and add a recipe under My Listings!")
        empty:SetFullWidth(true)
        scroll:AddChild(empty)
    else
        for _, entry in ipairs(listings) do
            local row = AceGUI:Create("SimpleGroup")
            row:SetFullWidth(true)
            row:SetLayout("Flow")

            -- Icon: F8 hover tooltip + shift-click to link in chat
            local icon = AceGUI:Create("Icon")
            icon:SetImage(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
            icon:SetImageSize(16, 16)
            icon:SetWidth(20)
            local itemID = entry.itemID
            icon.frame:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. itemID)
                GameTooltip:Show()
            end)
            icon.frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
            icon.frame:SetScript("OnMouseDown", function(_, button)
                if button == "LeftButton" and IsShiftKeyDown() then
                    local _, link = GetItemInfo(itemID)
                    if link then ChatEdit_InsertLink(link) end
                end
            end)
            row:AddChild(icon)

            -- F1/F6: per-entry flags shared between nameLbl and the detail row below
            local hasNote   = entry.note and entry.note ~= ""
            local hasCd     = entry.cdSeconds ~= nil
            local detailKey = entry.seller .. ":" .. entry.itemID

            local nameLbl = AceGUI:Create("Label")
            -- F1/F6: show [+]/[-] indicator when a note OR a cooldown is present
            if hasNote or hasCd then
                local isExpanded = MC.UI.expandedNotes[detailKey]
                nameLbl:SetText(entry.itemName
                    .. (isExpanded and " |cFFFF9944[-]|r" or " |cFF44FF44[+]|r"))
                local nk  = detailKey
                local par = parent
                nameLbl.frame:SetScript("OnMouseDown", function(_, button)
                    if button == "LeftButton" then
                        MC.UI.expandedNotes[nk] = not MC.UI.expandedNotes[nk]
                        MC.UI:RebuildBrowseRows(par)
                    end
                end)
            else
                nameLbl:SetText(entry.itemName)
            end
            nameLbl:SetRelativeWidth(0.25)
            row:AddChild(nameLbl)

            local profLbl = AceGUI:Create("Label")
            profLbl:SetText(entry.profName)
            profLbl:SetRelativeWidth(0.22)
            row:AddChild(profLbl)

            -- Seller + F9 freshness + F11 right-click to hide
            local ageStr, ar, ag, ab = MC.UI:FormatAge(entry.receivedAt)
            local colorHex = string.format("%02X%02X%02X",
                math.floor(ar * 255), math.floor(ag * 255), math.floor(ab * 255))
            local sellerLbl = AceGUI:Create("Label")
            sellerLbl:SetText(entry.seller .. " |cFF" .. colorHex .. ageStr .. "|r")
            sellerLbl:SetRelativeWidth(0.26)
            local sellerName = entry.seller
            sellerLbl.frame:SetScript("OnMouseDown", function(_, button)
                if button == "RightButton" then ShowBlocklistMenu(sellerName) end
            end)
            row:AddChild(sellerLbl)

            -- F10: favourite star toggle
            local isFav = favs[entry.seller]
            local starBtn = AceGUI:Create("Button")
            starBtn:SetText(isFav and "|cFFFFD700★|r" or "|cFF888888★|r")
            starBtn:SetWidth(28)
            local sn = entry.seller
            starBtn:SetCallback("OnClick", function()
                if MC.db.char.favorites[sn] then
                    MC.db.char.favorites[sn] = nil
                else
                    MC.db.char.favorites[sn] = true
                end
                MC.UI:RefreshBrowse()
            end)
            row:AddChild(starBtn)

            -- Whisper: F4 template expansion
            local whisperBtn = AceGUI:Create("Button")
            whisperBtn:SetText("Whisper")
            whisperBtn:SetRelativeWidth(0.13)
            local seller    = entry.seller
            local itemName  = entry.itemName
            local profName  = entry.profName
            whisperBtn:SetCallback("OnClick", function()
                local tpl = (MC.db.char.settings.whisperTemplate or "/w {seller} "):sub(1, 200)
                local msg = tpl:gsub("{seller}", seller)
                               :gsub("{item}",   itemName)
                               :gsub("{prof}",   profName)
                ChatFrame_OpenChat(msg)
            end)
            row:AddChild(whisperBtn)
            scroll:AddChild(row)

            -- F1/F6: expandable detail row — shows note and/or cooldown when [+] clicked
            if (hasNote or hasCd) and MC.UI.expandedNotes[detailKey] then
                local detailRow = AceGUI:Create("SimpleGroup")
                detailRow:SetFullWidth(true)
                detailRow:SetLayout("List")
                if hasNote then
                    local noteLbl = AceGUI:Create("Label")
                    noteLbl:SetText("|cFFCCCCCC  \226\134\179 " .. entry.note .. "|r")
                    noteLbl:SetFullWidth(true)
                    detailRow:AddChild(noteLbl)
                end
                if hasCd then
                    local cdText, cr, cg, cb = MC.UI:FormatCooldown(entry.cdSeconds, entry.receivedAt)
                    local cdHex = string.format("%02X%02X%02X",
                        math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255))
                    local cdLbl = AceGUI:Create("Label")
                    cdLbl:SetText("  |cFF" .. cdHex .. cdText .. "|r")
                    cdLbl:SetFullWidth(true)
                    detailRow:AddChild(cdLbl)
                end
                scroll:AddChild(detailRow)
            end
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
end

---------------------------------------------------------------------------
-- Profession Picker popup
-- Opens when user has a tradeskill window open; lets them click-to-add
-- recipes without typing any commands.
---------------------------------------------------------------------------
function MC.UI:OpenProfessionPicker()
    local numSkills = GetNumTradeSkills and GetNumTradeSkills() or 0
    if numSkills == 0 then
        MC:Print("Open a Profession window first.")
        return
    end

    -- GetTradeSkillLine() can return the WoW global UNKNOWN constant when the
    -- skill line isn't identified. Normalize it away and fall back gracefully.
    local tradeName = GetTradeSkillLine()
    if not tradeName or tradeName == "" or tradeName == UNKNOWN then tradeName = nil end
    -- Secondary fallback: the first "header" entry in the tradeskill list is
    -- always the profession name (e.g. "Tailoring") — same technique as GuildCrafts.
    if not tradeName then
        for i = 1, numSkills do
            local skillName, skillType = GetTradeSkillInfo(i)
            if skillType == "header" and skillName and skillName ~= "" and skillName ~= UNKNOWN then
                tradeName = skillName
                break
            end
        end
    end
    tradeName = tradeName or "Profession"

    -- Release any previous picker window
    if MC.UI.pickerFrame then
        MC.UI.pickerFrame:Release()
        MC.UI.pickerFrame = nil
    end

    local picker = AceGUI:Create("Frame")
    picker:SetTitle("Add Recipe — " .. tradeName)
    picker:SetLayout("List")
    picker:SetWidth(430)
    picker:SetHeight(490)
    MC.UI.pickerFrame = picker

    -- Escape key support for picker
    _G["MarketCraftsPickerFrame"] = picker.frame
    local _pFound = false
    for _, _n in ipairs(UISpecialFrames) do
        if _n == "MarketCraftsPickerFrame" then _pFound = true; break end
    end
    if not _pFound then tinsert(UISpecialFrames, "MarketCraftsPickerFrame") end

    picker:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
        MC.UI.pickerFrame = nil
    end)

    -- Search box
    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search recipes:")
    searchBox:SetFullWidth(true)
    picker:AddChild(searchBox)

    -- Scrollable recipe list (290px leaves room for search box + note field + frame chrome)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    scroll:SetHeight(290)
    picker:AddChild(scroll)

    -- Build a set of already-listed itemIDs for quick lookup
    local listed = {}
    for _, entry in ipairs(MC.db.char.myListings) do
        listed[entry.itemID] = true
    end

    -- Collect non-header recipes from the open tradeskill window
    local recipes = {}
    for i = 1, numSkills do
        local name, skillType = GetTradeSkillInfo(i)
        if skillType ~= "header" and name then
            local link = GetTradeSkillItemLink(i)
            local itemID = link and tonumber(link:match("item:(%d+)"))
            if itemID then
                -- F6: capture current cooldown for time-gated recipes (nil = no cooldown)
                local cd = GetTradeSkillCooldown and GetTradeSkillCooldown(i) or nil
                table.insert(recipes, { itemID = itemID, name = name, cdSeconds = cd })
            end
        end
    end

    local tname = tradeName
    local filterText = ""
    local noteBox  -- declared early so RebuildRecipeRows can close over it

    local function RebuildRecipeRows()
        scroll:ReleaseChildren()
        local filter = filterText:lower()
        local shown = 0

        for _, recipe in ipairs(recipes) do
            if filter == "" or recipe.name:lower():find(filter, 1, true) then
                shown = shown + 1
                local row = AceGUI:Create("SimpleGroup")
                row:SetFullWidth(true)
                row:SetLayout("Flow")

                local nameLbl = AceGUI:Create("Label")
                nameLbl:SetText(recipe.name)
                nameLbl:SetRelativeWidth(0.76)
                row:AddChild(nameLbl)

                local btn = AceGUI:Create("Button")
                btn:SetRelativeWidth(0.24)
                if listed[recipe.itemID] or #MC.db.char.myListings >= 5 then
                    btn:SetText(listed[recipe.itemID] and "Listed" or "Full")
                    btn:SetDisabled(true)
                else
                    btn:SetText("Add")
                    local id, rname, rcd = recipe.itemID, recipe.name, recipe.cdSeconds
                    btn:SetCallback("OnClick", function()
                        -- F1: capture note text at click time (noteBox created after this function)
                        local note = noteBox and noteBox:GetText() or ""
                        -- F6: pass cooldown snapshot so it's stored with the listing
                        local ok = MC:AddMyListing(id, tname, rname, note, rcd)
                        if ok then
                            btn:SetText("Listed")
                            btn:SetDisabled(true)
                            listed[id] = true
                            MC.UI:RefreshMyListings()
                        end
                    end)
                end
                row:AddChild(btn)
                scroll:AddChild(row)
            end
        end

        if shown == 0 then
            local lbl = AceGUI:Create("Label")
            lbl:SetText(filter ~= ""
                and "No recipes match your search."
                or "No learnable recipes found. Make sure a Profession window is open.")
            lbl:SetFullWidth(true)
            scroll:AddChild(lbl)
        end
    end

    searchBox:SetCallback("OnTextChanged", function(widget)
        filterText = widget:GetText() or ""
        RebuildRecipeRows()
    end)

    -- F1: crafter note field — placed below the recipe list so users can type a
    -- note before clicking Add.  The noteBox upvalue is now valid for btn callbacks.
    noteBox = AceGUI:Create("EditBox")
    noteBox:SetLabel("Crafter note (optional, 60 chars):")
    noteBox:SetFullWidth(true)
    noteBox:SetMaxLetters(60)
    picker:AddChild(noteBox)

    RebuildRecipeRows()
end
