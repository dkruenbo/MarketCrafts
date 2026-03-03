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
            -- Recipe picker: M6.5 future widget
            -- Do NOT use CastSpellByName — protected in TBC, causes taint.
            MC:Print("Please open your profession window, then use:")
            MC:Print("/run MarketCrafts:AddMyListing(itemID, \"Profession\", \"Item Name\")")
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
        -- Re-enable when cooldown expires
        MC:ScheduleTimer(function()
            if mainFrame then MC.UI:Refresh() end
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
