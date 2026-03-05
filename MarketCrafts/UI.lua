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
local refreshTimer = nil  -- debounce timer for Refresh()

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
        -- Clear cached scroll frame reference so it isn't reused after release (Bug 6)
        MC.UI.browseScrollFrame = nil
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

---------------------------------------------------------------------------
-- My Listings Panel
---------------------------------------------------------------------------
function MC.UI:BuildMyListingsPanel(parent)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle(string.format("My Listings (%d/5)", #MC.db.char.myListings))
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

    MC.UI.browseGroup = group
    MC.UI.searchFilter = ""
    MC.UI:RebuildBrowseRows(group)
end

function MC.UI:RebuildBrowseRows(parent)
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
        scroll:SetHeight(300)
        MC.UI.browseScrollFrame = scroll
        parent:AddChild(scroll)
    end

    local listings = MC.Cache:GetVisible(MC.UI.searchFilter, MC.UI.sortKey)

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

    -- Scrollable recipe list (350px leaves room for search box + frame chrome)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    scroll:SetHeight(350)
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
                table.insert(recipes, { itemID = itemID, name = name })
            end
        end
    end

    local tname = tradeName
    local filterText = ""

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
                    local id, rname = recipe.itemID, recipe.name
                    btn:SetCallback("OnClick", function()
                        local ok = MC:AddMyListing(id, tname, rname)
                        if ok then
                            btn:SetText("Listed")
                            btn:SetDisabled(true)
                            listed[id] = true
                            MC.UI:Refresh()
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

    RebuildRecipeRows()
end
