-- MinimapButton.lua — Draggable minimap button for MarketCrafts
local AddonName, NS = ...
local MC = NS.MC

local MinimapButton = {}
MC.MinimapButton = MinimapButton

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local BUTTON_SIZE  = 31
local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Coin_01"
local RADIUS       = 80   -- pixels from minimap centre

---------------------------------------------------------------------------
-- Private
---------------------------------------------------------------------------
local btn

local function UpdatePosition(angle)
    local rad = math.rad(angle)
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(rad) * RADIUS,
        math.sin(rad) * RADIUS)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
function MinimapButton:Create()
    if btn then return end

    btn = CreateFrame("Button", "MarketCraftsMinimapButton", Minimap)
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)

    -- Icon
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(ICON_TEXTURE)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim outer pixel border
    icon:SetAllPoints()

    -- Circular border (re-uses the standard minimap tracking border)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56, 56)
    border:SetPoint("CENTER", btn, "CENTER", 0, 0)

    -- Highlight on mouse-over
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints()

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("MarketCrafts")
        GameTooltip:AddLine("Click to toggle window", 1, 1, 1)
        GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Left-click toggles the main window
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetScript("OnClick", function(self, mouseBtn)
        MC.UI:Toggle()
    end)

    -- Drag to reposition around the minimap ring
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my   = Minimap:GetCenter()
            local px, py   = GetCursorPosition()
            local scale    = UIParent:GetEffectiveScale()
            px, py         = px / scale, py / scale
            local angle    = math.deg(math.atan2(py - my, px - mx))
            MC.db.char.settings.minimapAngle = angle
            UpdatePosition(angle)
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    -- Restore saved position (default: bottom-left of minimap)
    UpdatePosition(MC.db.char.settings.minimapAngle or 225)
end

function MinimapButton:Show()
    if btn then btn:Show() end
end

function MinimapButton:Hide()
    if btn then btn:Hide() end
end
