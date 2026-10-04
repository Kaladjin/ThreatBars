-- ThreatBars : fenêtre d'options (bouton roue crantée de l'en-tête, ou /tb)
local addonName, ns = ...

local PANEL_W, PANEL_H = 280, 400
local panel
local controls = {}

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------
local function Heading(parent, text, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 14, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
    return fs
end

local function Check(parent, label, y, key, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 12, y)
    local text = type(cb.Text) == "table" and cb.Text or nil
    if not text then
        text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    else
        text:SetFontObject("GameFontHighlight")
    end
    text:SetText(label)
    cb:SetScript("OnClick", function(self)
        local db = ns.GetDB()
        db[key] = self:GetChecked() and true or false
        if onChange then onChange(db[key]) end
    end)
    cb.Refresh = function(self) self:SetChecked(ns.GetDB()[key] and true or false) end
    controls[#controls + 1] = cb
    return cb
end

-- Curseur : MinimalSliderWithSteppersTemplate (celui des réglages Blizzard) si dispo, sinon curseur simple
local function Slider(parent, label, y, key, minV, maxV, step, fmt, onChange)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 18, y)
    title:SetText(label)

    local valueText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valueText:SetPoint("TOPRIGHT", -18, y)

    local function Changed(value)
        value = math.floor(value / step + 0.5) * step
        local db = ns.GetDB()
        if db[key] == value then return end
        db[key] = value
        valueText:SetFormattedText(fmt, value)
        if onChange then onChange(value) end
    end

    local holder = { title = title, valueText = valueText }
    local ok = pcall(function()
        if not MinimalSliderWithSteppersMixin then error("pas de template") end
        local s = CreateFrame("Frame", nil, parent, "MinimalSliderWithSteppersTemplate")
        if type(s.Slider) ~= "table" then error("template incomplet") end
        s:SetPoint("TOPLEFT", 14, y - 16)
        s:SetPoint("TOPRIGHT", -14, y - 16)
        s:SetHeight(20)
        s:Init(ns.GetDB()[key], minV, maxV, (maxV - minV) / step, {})
        s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v) Changed(v) end, holder)
        holder.Set = function(v) s:SetValue(v) end
        holder.SetEnabled = function(on) s:SetEnabled(on) end
    end)
    if not ok then
        local s = CreateFrame("Slider", nil, parent)
        s:SetOrientation("HORIZONTAL")
        s:SetPoint("TOPLEFT", 18, y - 20)
        s:SetPoint("TOPRIGHT", -18, y - 20)
        s:SetHeight(12)
        local track = s:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(4)
        track:SetColorTexture(0.3, 0.3, 0.3, 0.9)
        s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        s:SetMinMaxValues(minV, maxV)
        s:SetValueStep(step)
        if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
        s:EnableMouseWheel(true)
        s:SetScript("OnMouseWheel", function(self, d) self:SetValue(self:GetValue() + d * step) end)
        s:SetScript("OnValueChanged", function(_, v) Changed(v) end)
        holder.Set = function(v) s:SetValue(v) end
        holder.SetEnabled = function(on) if on then s:Enable() else s:Disable() end; s:SetAlpha(on and 1 or 0.4) end
    end

    holder.Refresh = function()
        local v = ns.GetDB()[key]
        holder.Set(v)
        valueText:SetFormattedText(fmt, v)
    end
    holder.Enable = function(on)
        holder.SetEnabled(on)
        local c = on and 1 or 0.5
        title:SetTextColor(c, c, c); valueText:SetTextColor(c, c, c)
    end
    controls[#controls + 1] = holder
    return holder
end

----------------------------------------------------------------------
-- Panneau
----------------------------------------------------------------------
local warnSlider, volSlider, testSoundBtn

local function UpdateEnabled()
    local on = ns.GetDB().alertOn
    warnSlider.Enable(on)
    volSlider.Enable(on)
    if testSoundBtn then testSoundBtn:SetEnabled(on) end
end

local function Build()
    panel = CreateFrame("Frame", "ThreatBarsOptions", UIParent)
    panel:SetSize(PANEL_W, PANEL_H)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:Hide()
    tinsert(UISpecialFrames, "ThreatBarsOptions") -- Échap ferme la fenêtre

    local bg = panel:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    ns.SetAtlasOr(bg, "damagemeters-background", 0.04, 0.04, 0.05, 0.92)
    local solid = panel:CreateTexture(nil, "BACKGROUND", nil, -2)
    solid:SetAllPoints()
    solid:SetColorTexture(0, 0, 0, 0.75) -- l'atlas du meter est très transparent

    local header = CreateFrame("Frame", nil, panel)
    header:SetHeight(ns.HEADER_H)
    header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() panel:StartMoving() end)
    header:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
    local htex = header:CreateTexture(nil, "BACKGROUND")
    htex:SetAllPoints()
    ns.SetAtlasOr(htex, "ui-damagemeters-header-bar", 0.1, 0.1, 0.1, 0.95)
    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
    title:SetPoint("TOPLEFT", 8, -9)
    title:SetText("ThreatBars — Options")

    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -2, -4)
    close:SetScript("OnClick", function() panel:Hide() end)

    local y = -ns.HEADER_H - 12

    Heading(panel, "Alerte", y); y = y - 22
    Check(panel, "Activer l'alerte (son + voile rouge)", y, "alertOn", UpdateEnabled); y = y - 30
    warnSlider = Slider(panel, "Seuil d'alerte", y, "warn", 50, 130, 5, "%d %% du pull"); y = y - 46
    volSlider = Slider(panel, "Volume du son", y, "volume", 0, 100, 5, "%d %%"); y = y - 44

    testSoundBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testSoundBtn:SetSize(110, 22)
    testSoundBtn:SetPoint("TOPLEFT", 16, y)
    testSoundBtn:SetText("Tester le son")
    testSoundBtn:SetScript("OnClick", function() ns.PlayAlertSound() end)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", testSoundBtn, "RIGHT", 8, 0)
    hint:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("0 % = voile seul, sans son")
    y = y - 36

    Heading(panel, "Affichage", y); y = y - 22
    Check(panel, "Afficher seulement en combat", y, "combatOnly", ns.UpdateVisibility); y = y - 26
    Check(panel, "Verrouiller la position", y, "locked"); y = y - 30
    Slider(panel, "Opacité du fond", y, "bgAlpha", 0, 100, 5, "%d %%", ns.ApplyLayout); y = y - 46
    Slider(panel, "Opacité générale", y, "alpha", 20, 100, 5, "%d %%", ns.ApplyLayout); y = y - 46

    local preview = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    preview:SetSize(24, 24)
    preview:SetPoint("TOPLEFT", 12, y)
    local hasText = type(preview.Text) == "table"
    local pt = hasText and preview.Text or preview:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not hasText then pt:SetPoint("LEFT", preview, "RIGHT", 2, 0) end
    pt:SetFontObject("GameFontHighlight")
    pt:SetText("Aperçu (barres factices)")
    preview:SetScript("OnClick", function(self) ns.SetTestMode(self:GetChecked()) end)
    preview.Refresh = function(self) self:SetChecked(ns.IsTestMode()) end
    controls[#controls + 1] = preview
    y = y - 30

    panel:SetHeight(-y + 10)

    panel:SetScript("OnShow", function()
        ns.SetOptionsOpen(true) -- le meter reste visible pendant les réglages
        ns.RefreshOptions()
    end)
    panel:SetScript("OnHide", function()
        ns.SetOptionsOpen(false)
        if ns.IsTestMode() then ns.SetTestMode(false) end
    end)
end

ns.RefreshOptions = function()
    if not panel then return end
    for _, c in ipairs(controls) do c:Refresh() end
    UpdateEnabled()
end

ns.ToggleOptions = function()
    if not panel then Build() end
    if panel:IsShown() then panel:Hide(); return end
    panel:ClearAllPoints()
    local m = ns.meter
    -- à côté du meter, côté où il y a de la place
    if m:GetLeft() and m:GetLeft() > PANEL_W + 20 then
        panel:SetPoint("TOPRIGHT", m, "TOPLEFT", -6, 0)
    else
        panel:SetPoint("TOPLEFT", m, "TOPRIGHT", 6, 0)
    end
    panel:Show()
end

ns.optBtn:SetScript("OnClick", ns.ToggleOptions)
ns.optBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Options ThreatBars")
    GameTooltip:Show()
end)
ns.optBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
