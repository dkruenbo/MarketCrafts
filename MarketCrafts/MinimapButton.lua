-- MinimapButton.lua -- Draggable minimap button for MarketCrafts
-- Modelled after GuildCrafts' proven minimap button implementation.
local AddonName, NS = ...
local MC = NS.MC

local MinimapButton = {}
MC.MinimapButton = MinimapButton

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local ICON_TEXTURE = "Interface\\Icons\\Trade_Engineering"
local BUTTON_SIZE  = 31
local DRAG_RADIUS  = 80  -- distance from minimap centre

---------------------------------------------------------------------------
-- Private
---------------------------------------------------------------------------
local btn

local function UpdatePosition(angle)
    local x = math.cos(angle)
    local y = math.sin(angle)

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x * DRAG_RADIUS, y * DRAG_RADIUS)
end

local function AngleFromCursor()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale  = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    return math.atan2(cy - my, cx - mx)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
function MinimapButton:Create()
    if btn then return end

    btn = CreateFrame("Button", "MarketCraftsMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Border overlay (standard minimap button look)
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    -- Icon as a separate BACKGROUND texture (same approach as GuildCrafts)
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
    btn.icon = icon

    -- Tooltip: F3 live crafter count
    btn:SetScript("OnEnter", function(frame)
        GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
        GameTooltip:AddLine("MarketCrafts")
        local count = MC.Cache:GetUniqueSellerCount()
        if count > 0 then
            GameTooltip:AddLine(count .. " crafter(s) currently online", 1, 1, 1)
        else
            GameTooltip:AddLine("No crafters online", 0.6, 0.6, 0.6)
        end
        GameTooltip:AddLine("|cffffffffLeft-click|r to toggle window", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffDrag|r to reposition", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Click handler
    btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            MC.UI:Toggle()
        end
    end)

    -- Drag to reposition around the minimap ring
    btn:SetScript("OnDragStart", function(frame)
        frame.isDragging = true
        frame:SetScript("OnUpdate", function()
            local angle = AngleFromCursor()
            UpdatePosition(angle)
            MC.db.char.settings.minimapAngle = angle
        end)
    end)

    btn:SetScript("OnDragStop", function(frame)
        frame.isDragging = false
        frame:SetScript("OnUpdate", nil)
    end)

    -- Restore saved position (default: ~225 degrees = bottom-left)
    local savedAngle = MC.db.char.settings.minimapAngle
    if not savedAngle then
        savedAngle = math.rad(225)
        MC.db.char.settings.minimapAngle = savedAngle
    end
    UpdatePosition(savedAngle)

    btn:Show()
end

function MinimapButton:Show()
    if btn then btn:Show() end
end

function MinimapButton:Hide()
    if btn then btn:Hide() end
end
