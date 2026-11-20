-- UI/Minimap.lua: a small round button on the minimap. Left-click opens the bet window,
-- right-click the bookie window, drag to move it around the edge. /book icon shows or hides it.
-- Hand-rolled (no LibDBIcon): it only needs Minimap, a Button and a few textures.
-- Saved in SteveBookDB.minimap = { hide = bool, angle = degrees }.
local ADDON, ns = ...

local M = {}
ns.UI = ns.UI or {}
ns.UI.Minimap = M

local DEFAULT_ANGLE = 225        -- bottom left, clear of the tracking and calendar buttons
local button

local function settings()
    local db = SteveBookDB
    if not db then return nil end
    db.minimap = db.minimap or {}
    return db.minimap
end

local function place()
    local s = settings()
    if not (button and s and Minimap) then return end
    local angle = math.rad(s.angle or DEFAULT_ANGLE)
    local radius = ((Minimap.GetWidth and Minimap:GetWidth()) or 140) / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function open(which)
    local ui = ns.UI and ns.UI[which]
    if ui and ui.Toggle then ui.Toggle() end
end

local function build()
    if button or not (Minimap and CreateFrame) then return end
    button = CreateFrame("Button", "SteveBookMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    if button.SetHighlightTexture then
        button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    end

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnClick", function(_, btn)
        open(btn == "RightButton" and "Bookie" or "Bettor")
    end)

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            if type(mx) ~= "number" or type(cx) ~= "number" then return end
            local s = settings()
            if s then s.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360 end
            place()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    button:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("SteveBook")
        GameTooltip:AddLine("Left-click: place bets", 1, 1, 1)
        GameTooltip:AddLine("Right-click: bookie window", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this icon  (/book icon hides it)", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

-- Create the button if needed, then show or hide it per the saved setting.
function M.Apply()
    local s = settings()
    if not s then return end
    build()
    if not button then return end
    place()
    if s.hide then button:Hide() else button:Show() end
end

-- /book icon. Returns true when the icon is now shown.
function M.Toggle()
    local s = settings()
    if not s then return false end
    s.hide = not s.hide
    M.Apply()
    return not s.hide
end

function M.IsShown()
    local s = settings()
    return s ~= nil and not s.hide
end
