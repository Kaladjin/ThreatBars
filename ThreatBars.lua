--[[
ThreatBars 0.4.0 — threat meter pour WoW: Forever (interface 16001)
Apparence calquée sur le damage meter intégré de Blizzard (Blizzard_DamageMeter) :
mêmes atlas, polices, hauteur de barre (25) et espacement (4).

Données : UnitDetailedThreatSituation(unité, mob), calculé par le serveur.
  * value      = menace brute (échelle x100 de Blizzard, affichée telle quelle)
  * rawPercent = % de la menace du tank  -> sert à la colonne "différence"
  * scaled%    = % du seuil de pull       -> sert à l'alerte sonore
Pas de combat log (interdit sur ce moteur). En combat certaines valeurs peuvent être
"secrètes" : on n'en fait des calculs que si Usable() le permet, sinon on les passe
telles quelles aux widgets (StatusBar / FontString), qui savent les afficher.
]]

local addonName, ns = ...

local DEFAULTS = {
    point     = { "CENTER", "CENTER", 320, 0 },
    w         = 300,
    h         = 180,
    locked    = false,
    alertOn    = true,  -- interrupteur général de l'alerte (son + voile)
    warn       = 90,    -- alerte quand un non-tank atteint ce % du seuil de pull
    volume     = 80,    -- 0-100, relatif au volume général ; 0 = alerte visuelle seule
    combatOnly = false, -- n'afficher le meter qu'en combat
    bgAlpha    = 100,   -- opacité du fond (en-tête, fond, fonds de barres)
    alpha      = 100,   -- opacité générale du meter
    pets       = true,
    minimized  = false,
    log        = {},    -- dernières rencontres (instantanés de fin de combat)
    hidden     = false,
}

local BAR_H, BAR_SPACING, HEADER_H = 25, 4, 32 -- valeurs du meter Blizzard
local LOG_MAX = 10 -- rencontres gardées dans l'historique
local TICK = 0.25
local db

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                local t = {}; for i, x in pairs(v) do t[i] = x end; dst[k] = t
            else
                dst[k] = v
            end
        end
    end
end

----------------------------------------------------------------------
-- Valeurs secrètes
----------------------------------------------------------------------
local function IsSecret(v)
    if v == nil or type(issecretvalue) ~= "function" then return false end
    local ok, s = pcall(issecretvalue, v)
    return ok and s and true or false
end

-- issecretvalue n'est pas fiable à 100 % sur la bêta : on vérifie par une vraie opération
local function Usable(v)
    if v == nil or IsSecret(v) then return false end
    return (pcall(function()
        if type(v) == "number" then return v + 0 end
        return v == v
    end))
end

local function SafeTrue(v) return Usable(v) and v == true end

local function Abbrev(v)
    -- AbbreviateLargeNumbers est le formateur du meter Blizzard (gère les secrets côté client)
    if type(AbbreviateLargeNumbers) == "function" then
        local ok, s = pcall(AbbreviateLargeNumbers, v)
        if ok and s then return s end
    end
    if not Usable(v) then return nil end
    if v >= 1e6 then return string.format("%.2fM", v / 1e6) end
    if v >= 1e3 then return string.format("%.1fK", v / 1e3) end
    return string.format("%d", v)
end

local function Print(msg) print("|cffc79c6e[ThreatBars]|r " .. msg) end

----------------------------------------------------------------------
-- Collecte
----------------------------------------------------------------------
local roster = {}

local function BuildRoster()
    wipe(roster)
    if IsInRaid() then
        for i = 1, 40 do
            roster[#roster + 1] = "raid" .. i
            if db.pets then roster[#roster + 1] = "raidpet" .. i end
        end
    else
        roster[#roster + 1] = "player"
        if db.pets then roster[#roster + 1] = "pet" end
        if IsInGroup() then
            for i = 1, 4 do
                roster[#roster + 1] = "party" .. i
                if db.pets then roster[#roster + 1] = "partypet" .. i end
            end
        end
    end
end

-- Cible hostile ; sinon cible de la cible (heal/off-tank) ; sinon focus
local function PickMob()
    for _, u in ipairs({ "target", "targettarget", "focus" }) do
        local exists = UnitExists(u)
        if not Usable(exists) then return "target" end
        if exists then
            local hostile = UnitCanAttack("player", u)
            if not Usable(hostile) or hostile then return u end
        end
    end
end

local rows, pool = {}, {}

-- Combat en cours et historique
--   fight = { start = GetTime(), mobs = { [clé] = { name, first, last, snap, snapAt } } }
--   view  = 0 : affichage en direct ; n > 0 : rencontre n de db.log (1 = la plus récente)
local fight
local view = 0

local function Collect(mob)
    for i = #rows, 1, -1 do pool[#pool + 1] = rows[i]; rows[i] = nil end
    if not mob then return end
    local seen = {}
    for _, unit in ipairs(roster) do
        local exists = UnitExists(unit)
        if not Usable(exists) or exists then
            local isTanking, _, scaled, raw, value = UnitDetailedThreatSituation(unit, mob)
            if type(raw) == "number" then -- nil = pas sur la liste de menace
                local guid = UnitGUID(unit)
                local key = (Usable(guid) and guid) or unit
                if not seen[key] then
                    seen[key] = true
                    local r = table.remove(pool) or {}
                    r.tanking, r.scaled, r.raw, r.value = isTanking, scaled, raw, value
                    r.tps = nil
                    r.name = UnitName(unit)
                    local _, class = UnitClass(unit)
                    r.class = class
                    r.isPlayer = UnitIsUnit(unit, "player")
                    rows[#rows + 1] = r
                end
            end
        end
    end
    -- Tri par menace brute si lisible ; sinon ordre du groupe
    local sortable = true
    for _, r in ipairs(rows) do
        if not Usable(r.value) then sortable = false; break end
    end
    if sortable then
        pcall(table.sort, rows, function(a, b) return a.value > b.value end)
    end
end

----------------------------------------------------------------------
-- Fenêtre (style damage meter Blizzard)
----------------------------------------------------------------------
local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function SetAtlasOr(tex, atlas, r, g, b, a)
    if HasAtlas(atlas) then tex:SetAtlas(atlas) else tex:SetColorTexture(r, g, b, a) end
end

local bgRegions = {} -- textures soumises au réglage "opacité du fond"

local frame = CreateFrame("Frame", "ThreatBarsFrame", UIParent)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:SetResizable(true)
if frame.SetResizeBounds then frame:SetResizeBounds(200, 120, 600, 600) end

local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
bg:SetAllPoints()
SetAtlasOr(bg, "damagemeters-background", 0, 0, 0, 0.6)
bgRegions[#bgRegions + 1] = bg

local header = CreateFrame("Frame", nil, frame)
header:SetHeight(HEADER_H)
header:SetPoint("TOPLEFT")
header:SetPoint("TOPRIGHT")
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")
header:SetScript("OnDragStart", function() if not db.locked then frame:StartMoving() end end)
header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local p, _, rp, x, y = frame:GetPoint()
    db.point = { p, rp, x, y }
end)
local headerTex = header:CreateTexture(nil, "BACKGROUND")
headerTex:SetAllPoints()
SetAtlasOr(headerTex, "ui-damagemeters-header-bar", 0.1, 0.1, 0.1, 0.9)
bgRegions[#bgRegions + 1] = headerTex

local titleText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
titleText:SetPoint("TOPLEFT", 8, -9)
titleText:SetText("Menace")

local mobText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
mobText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
-- (ancré à droite plus bas, contre le sélecteur de session)
mobText:SetJustifyH("LEFT")
mobText:SetWordWrap(false)
mobText:SetTextColor(1, 1, 1)

local minBtn = CreateFrame("Button", nil, header)
minBtn:SetSize(18, 19)
minBtn:SetPoint("TOPRIGHT", -3, -5)
local function UpdateMinBtn()
    local s = db and db.minimized and "expand" or "collapse"
    local n = "ui-questtrackerbutton-" .. s .. "-all"
    if HasAtlas(n) then
        minBtn:SetNormalAtlas(n)
        minBtn:SetPushedAtlas(n .. "-pressed")
        minBtn:SetHighlightAtlas("ui-questtrackerbutton-red-highlight", "ADD")
    end
end

-- Bouton options (même roue crantée que le meter Blizzard)
local optBtn = CreateFrame("Button", nil, header)
optBtn:SetSize(22, 22)
optBtn:SetPoint("RIGHT", minBtn, "LEFT", -2, -1)
if HasAtlas("common-dropdown-a-button-settings-shadowless") then
    optBtn:SetNormalAtlas("common-dropdown-a-button-settings-shadowless")
    optBtn:SetPushedAtlas("common-dropdown-a-button-settings-pressed-shadowless")
    optBtn:SetHighlightAtlas("common-dropdown-a-button-settings-hover-shadowless")
else
    optBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    optBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
end

-- Sélecteur de session, à la même place que sur le meter Blizzard :
-- "Actuel" (direct) ou une des dernières rencontres. Menu natif via MenuUtil.
local sessionBtn = CreateFrame("Button", nil, header)
sessionBtn:SetHeight(20)
sessionBtn:SetPoint("RIGHT", optBtn, "LEFT", -4, 1)
sessionBtn.Label = sessionBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
sessionBtn.Label:SetPoint("CENTER")
local sessionHL = sessionBtn:CreateTexture(nil, "HIGHLIGHT")
sessionHL:SetAllPoints()
sessionHL:SetColorTexture(1, 1, 1, 0.12)

mobText:SetPoint("RIGHT", sessionBtn, "LEFT", -6, 0)

local body = CreateFrame("Frame", nil, frame)
body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
body:SetPoint("BOTTOMRIGHT", 0, 0)
body:SetClipsChildren(true)

local emptyText = body:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
emptyText:SetPoint("CENTER")
emptyText:SetTextColor(0.6, 0.6, 0.6)

local resize = CreateFrame("Button", nil, frame)
resize:SetSize(30, 30)
resize:SetPoint("BOTTOMRIGHT", 4, -4)
if HasAtlas("damagemeters-scalehandle") then
    resize:SetNormalAtlas("damagemeters-scalehandle")
    resize:SetHighlightAtlas("damagemeters-scalehandle-hover")
    resize:SetPushedAtlas("damagemeters-scalehandle-pressed")
end
resize:SetAlpha(0)
resize:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
resize:SetScript("OnLeave", function(self) self:SetAlpha(0) end)
resize:SetScript("OnMouseDown", function() if not db.locked then frame:StartSizing("BOTTOMRIGHT") end end)
resize:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    db.w, db.h = frame:GetWidth(), frame:GetHeight()
    local p, _, rp, x, y = frame:GetPoint()
    db.point = { p, rp, x, y }
end)

-- Voile d'alerte, dans le meter uniquement
local alertTex = body:CreateTexture(nil, "OVERLAY", nil, 7)
alertTex:SetAllPoints()
alertTex:SetColorTexture(0.9, 0.05, 0.05, 0.25)
alertTex:Hide()

-- Ligne = copie du DamageMeterEntryTemplate (style "Default")
local bars = {}
local function GetBar(i)
    if bars[i] then return bars[i] end
    local e = CreateFrame("Frame", nil, body)
    e:SetHeight(BAR_H)
    e:SetPoint("TOPLEFT", 0, -(i - 1) * (BAR_H + BAR_SPACING) - 2)
    e:SetPoint("RIGHT", body, "RIGHT", -15, 0)

    e.Icon = e:CreateTexture(nil, "ARTWORK")
    e.Icon:SetSize(BAR_H - 1, BAR_H - 1)
    e.Icon:SetPoint("LEFT", 0, 0)

    local sb = CreateFrame("StatusBar", nil, e)
    sb:SetPoint("LEFT", e.Icon, "RIGHT", 0, 0)
    sb:SetPoint("TOP", 0, -1)
    sb:SetPoint("BOTTOMRIGHT", -4, 1)
    local barTex = sb:CreateTexture(nil, "ARTWORK")
    SetAtlasOr(barTex, "UI-HUD-CoolDownManager-Bar", 1, 1, 1, 1)
    sb:SetStatusBarTexture(barTex)
    sb:SetMinMaxValues(0, 100)

    local back = sb:CreateTexture(nil, "BACKGROUND")
    back:SetPoint("TOPLEFT", -2, 2)
    back:SetPoint("BOTTOMRIGHT", 2, -2)
    SetAtlasOr(back, "ui-damagemeters-bar-shadowbg", 0, 0, 0, 0.5)
    bgRegions[#bgRegions + 1] = back
    back:SetAlpha(db and db.bgAlpha / 100 or 1)
    if HasAtlas("ui-damagemeters-bar-shadowedge") then
        local edge = sb:CreateTexture(nil, "OVERLAY")
        edge:SetPoint("TOPLEFT", -2, 2)
        edge:SetPoint("BOTTOMRIGHT", 2, -2)
        edge:SetAtlas("ui-damagemeters-bar-shadowedge")
        bgRegions[#bgRegions + 1] = edge
        edge:SetAlpha(db and db.bgAlpha / 100 or 1)
    end

    sb.Value = sb:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    sb.Value:SetPoint("RIGHT", -3, 0)
    sb.Value:SetJustifyH("RIGHT")
    sb.Name = sb:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    sb.Name:SetPoint("LEFT", 2, 0)
    sb.Name:SetPoint("RIGHT", sb.Value, "LEFT", -25, 0)
    sb.Name:SetJustifyH("LEFT")
    sb.Name:SetWordWrap(false)

    e.bar, e.barTex = sb, barTex
    bars[i] = e
    return e
end

local function ApplyLayout()
    frame:ClearAllPoints()
    local p = db.point
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    frame:SetWidth(db.w)
    frame:SetHeight(db.minimized and HEADER_H or db.h)
    body:SetShown(not db.minimized)
    resize:SetShown(not db.minimized)
    bg:SetShown(not db.minimized)
    for _, t in ipairs(bgRegions) do t:SetAlpha(db.bgAlpha / 100) end
    frame:SetAlpha(db.alpha / 100)
    UpdateMinBtn()
end

minBtn:SetScript("OnClick", function()
    db.minimized = not db.minimized
    ApplyLayout()
end)

----------------------------------------------------------------------
-- Rendu
----------------------------------------------------------------------
local testMode = false
local lastSound = 0

local function SetClassVisuals(e, class)
    local okc, c = pcall(function() return RAID_CLASS_COLORS[class] end)
    if okc and c then e.barTex:SetVertexColor(c.r, c.g, c.b) else e.barTex:SetVertexColor(0.5, 0.5, 0.5) end
    local oka = pcall(function()
        local atlas = GetClassAtlas and GetClassAtlas(class)
        if atlas then e.Icon:SetAtlas(atlas) else error() end
    end)
    if not oka then e.Icon:SetTexture(nil) end
end

-- "125M (2.1M)  100%" pour le tank, "116M (1.9M)  -7%" pour les autres (TPS entre parenthèses).
-- ATTENTION : sur certains contenus Blizzard rend toutes ces valeurs "secrètes".
-- Une chaîne secrète peut être testée (if v then) et affichée, mais JAMAIS comparée
-- (v ~= "" fait planter l'addon), ni utilisée en calcul.
local function SetValueText(fs, r)
    -- valeur brute du serveur (échelle x100, comme les autres threat meters) ;
    -- nil, chaîne normale, ou chaîne secrète si la valeur l'est
    local v = Abbrev(r.value)
    -- menace par seconde entre parenthèses, comme les DPS du meter Blizzard : "125M (2.08M)"
    if v and r.tps and Usable(r.tps) then
        local t = Abbrev(r.tps)
        if t then
            local ok, txt = pcall(string.format, "%s (%s)", v, t)
            if ok then v = txt end
        end
    end

    if SafeTrue(r.tanking) then
        if v then
            if pcall(fs.SetFormattedText, fs, "%s  |cff40ff40100%%|r", v) then return end
        end
        fs:SetText("|cff40ff40100%|r")
        return
    end

    if Usable(r.raw) then
        local d = r.raw - 100
        local col = d >= 0 and "ff4040" or "b0b0b0"
        local ok = pcall(fs.SetFormattedText, fs, "%s  |cff%s%+d%%|r", v or "", col, math.floor(d + (d >= 0 and 0.5 or -0.5)))
        if ok then return end
    end

    -- valeurs secrètes : pas de calcul possible, on affiche en gris le % de la menace
    -- du tank tel que donné par le serveur (le formatage d'un secret est autorisé)
    local ok
    if v then
        ok = pcall(fs.SetFormattedText, fs, "%s  |cff909090%.0f%%|r", v, r.raw)
    else
        ok = pcall(fs.SetFormattedText, fs, "|cff909090%.0f%%|r", r.raw)
    end
    if not ok then
        if not (v and pcall(fs.SetText, fs, v)) then fs:SetText("") end
    end
end

-- PlaySound n'a pas de paramètre de volume : on joue le son sur le canal "Dialog"
-- dont on règle temporairement le volume, puis on le restaure.
local GetCV = (C_CVar and C_CVar.GetCVar) or GetCVar
local SetCV = (C_CVar and C_CVar.SetCVar) or SetCVar
local restoreTimer

local function RestoreDialogVolume()
    restoreTimer = nil
    if db and db.savedDialogVol then
        pcall(SetCV, "Sound_DialogVolume", db.savedDialogVol)
        db.savedDialogVol = nil
    end
end

local function PlayAlertSound()
    local vol = db.volume / 100
    if vol <= 0 then return end
    local ok = pcall(function()
        if GetCV("Sound_EnableDialog") == "0" then error("dialog off") end
        if not db.savedDialogVol then db.savedDialogVol = GetCV("Sound_DialogVolume") end
        SetCV("Sound_DialogVolume", string.format("%.2f", vol))
        PlaySound(SOUNDKIT.RAID_WARNING, "Dialog")
    end)
    if ok then
        if restoreTimer then restoreTimer:Cancel() end
        restoreTimer = C_Timer.NewTimer(2.5, RestoreDialogVolume)
    else
        RestoreDialogVolume()
        PlaySound(SOUNDKIT.RAID_WARNING, "Master") -- repli : volume général
    end
end
ns.PlayAlertSound = function() PlayAlertSound() end

local function Alert()
    alertTex:Show()
    C_Timer.After(0.35, function() alertTex:Hide() end)
    if GetTime() - lastSound > 3 then
        lastSound = GetTime()
        PlayAlertSound()
    end
end

local function FormatClock(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if type(SecondsToClock) == "function" then
        local ok, txt = pcall(SecondsToClock, sec)
        if ok and txt then return txt end
    end
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function LogEntryLabel(e)
    local name = e.mob or "?"
    if e.others and e.others > 0 then name = name .. " (+" .. e.others .. ")" end
    return string.format("%s [%s]  %s", name, FormatClock(e.duration or 0), date("%H:%M", e.at or 0))
end
ns.LogEntryLabel = LogEntryLabel

local function UpdateSessionLabel()
    sessionBtn.Label:SetText(view == 0 and "Actuel" or ("#" .. view))
    sessionBtn:SetWidth(sessionBtn.Label:GetStringWidth() + 12)
end

local function SetView(i)
    if not db.log[i] then i = 0 end
    view = i
    UpdateSessionLabel()
    if ns.MarkDirty then ns.MarkDirty() end
end

-- Menu des sessions : rencontres passées (la plus ancienne en haut), séparateur, puis "Actuel",
-- dans le même ordre que le meter Blizzard.
local function BuildSessionMenu(_, root)
    local function IsSelected(i) return view == i end
    local function Select(i) SetView(i) end
    for i = #db.log, 1, -1 do
        root:CreateRadio(LogEntryLabel(db.log[i]), IsSelected, Select, i)
    end
    if #db.log > 0 then root:CreateDivider() end
    root:CreateRadio("Actuel", IsSelected, Select, 0)
end

sessionBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
sessionBtn:SetScript("OnClick", function(self, button)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(self, BuildSessionMenu)
    else
        -- repli sans menu : clic gauche = rencontre plus ancienne, clic droit = retour au direct
        if button == "RightButton" then SetView(0)
        else SetView(view < #db.log and view + 1 or 0) end
    end
end)
sessionBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Session")
    GameTooltip:AddLine("Direct ou une des " .. LOG_MAX .. " dernières rencontres", 1, 1, 1)
    GameTooltip:Show()
end)
sessionBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

----------------------------------------------------------------------
-- Suivi du combat : TPS et instantanés pour l'historique
----------------------------------------------------------------------
local function MobKey(mob)
    local g = UnitGUID(mob)
    if Usable(g) then return g end
    local n = UnitName(mob)
    if Usable(n) then return n end
end

-- Appelé à chaque rafraîchissement en direct. Calcule le TPS de chaque ligne
-- (menace / temps depuis que ce mob est suivi) et garde le dernier état lisible.
local function Track(mob, now)
    if not fight or not mob or #rows == 0 then return end
    local key = MobKey(mob)
    if not key then return end
    local m = fight.mobs[key]
    if not m then
        local n = UnitName(mob)
        m = { name = Usable(n) and n or "?", first = now }
        fight.mobs[key] = m
    end
    m.last = now

    local dur = now - m.first
    local snap = {}
    for _, r in ipairs(rows) do
        if dur >= 1 and Usable(r.value) then r.tps = r.value / dur end
        -- les valeurs secrètes ne peuvent ni être calculées ni sauvegardées
        if snap and Usable(r.value) and Usable(r.raw) and Usable(r.name) then
            snap[#snap + 1] = {
                name = r.name, class = Usable(r.class) and r.class or nil,
                value = r.value, raw = r.raw,
                tanking = SafeTrue(r.tanking), isPlayer = SafeTrue(r.isPlayer),
            }
        else
            snap = nil
        end
    end
    if snap then m.snap, m.snapAt = snap, now end
end

local function StartFight()
    fight = { start = GetTime(), mobs = {} }
    if view ~= 0 then SetView(0) end -- en combat on revient au direct
end

-- Fin de combat : on garde le mob suivi le plus longtemps (les autres sont comptés en "+N")
local function EndFight()
    if not fight then return end
    local best, count = nil, 0
    for _, m in pairs(fight.mobs) do
        if m.snap then
            count = count + 1
            if not best or (m.last - m.first) > (best.last - best.first) then best = m end
        end
    end
    if best then
        local dur = math.max(1, best.snapAt - best.first)
        for _, r in ipairs(best.snap) do r.tps = r.value / dur end
        table.insert(db.log, 1, {
            mob = best.name, others = count - 1, at = time(),
            duration = GetTime() - fight.start, rows = best.snap,
        })
        while #db.log > LOG_MAX do table.remove(db.log) end
        if view > 0 then SetView(math.min(view + 1, LOG_MAX)) end -- reste sur la même rencontre
    end
    fight = nil
end

ns.ClearLog = function()
    wipe(db.log)
    SetView(0)
end

----------------------------------------------------------------------
-- Rendu
----------------------------------------------------------------------
local FAKE = {
    { name = "Kaladjin", class = "WARRIOR", tanking = true, isPlayer = true, scaled = 100, raw = 100, value = 125000000 },
    { name = "Furtif", class = "ROGUE", scaled = 85, raw = 93, value = 116250000 },
    { name = "Givre", class = "MAGE", scaled = 55, raw = 71, value = 88750000 },
    { name = "Lumière", class = "PRIEST", scaled = 17, raw = 22, value = 27500000 },
}
for _, f in ipairs(FAKE) do f.tps = f.value / 60 end

local function Render()
    local now = GetTime()
    local list, mob, live = rows, nil, false

    if testMode then
        list = FAKE
        titleText:SetText("[" .. FormatClock(60) .. "]")
        mobText:SetText("Mannequin d'entraînement")
    elseif view > 0 and db.log[view] then
        local e = db.log[view]
        list = e.rows
        titleText:SetText("[" .. FormatClock(e.duration or 0) .. "]")
        local name = e.mob or "?"
        if e.others and e.others > 0 then name = name .. " |cff999999(+" .. e.others .. ")|r" end
        mobText:SetText(name)
    else
        live = true
        mob = PickMob()
        Collect(mob)
        Track(mob, now)
        titleText:SetText(fight and ("[" .. FormatClock(now - fight.start) .. "]") or "Menace")
        if mob then
            if not pcall(mobText.SetText, mobText, UnitName(mob)) then mobText:SetText("") end
        else
            mobText:SetText("")
        end
    end

    if db.minimized then return end

    -- Échelle des barres : la plus haute menace remplit la barre (comme le meter Blizzard)
    local maxRaw = 100
    for _, r in ipairs(list) do
        if Usable(r.raw) and r.raw > maxRaw then maxRaw = r.raw end
    end

    local avail = math.max(1, math.floor((body:GetHeight() + BAR_SPACING) / (BAR_H + BAR_SPACING)))
    -- Alerte (direct uniquement) : je tanke et un autre approche du pull, ou c'est moi qui approche
    local alert = false
    local iTank = false
    for _, r in ipairs(list) do
        if SafeTrue(r.tanking) and SafeTrue(r.isPlayer) then iTank = true end
    end

    for i = 1, math.max(#bars, math.min(#list, avail)) do
        local r = list[i]
        if r and i <= avail then
            local e = GetBar(i)
            e.bar:SetMinMaxValues(0, maxRaw)
            e.bar:SetValue(r.raw) -- accepte un secret
            SetClassVisuals(e, r.class)
            if not pcall(e.bar.Name.SetText, e.bar.Name, r.name) then e.bar.Name:SetText("?") end
            SetValueText(e.bar.Value, r)
            e:Show()
            if live and db.alertOn and not alert and not SafeTrue(r.tanking) and (iTank or SafeTrue(r.isPlayer))
                and Usable(r.scaled) and r.scaled >= db.warn then
                alert = true
            end
        elseif bars[i] then
            bars[i]:Hide()
        end
    end

    if #list == 0 then
        emptyText:SetText(mob and "Pas de menace sur cette cible" or "Aucune cible")
        emptyText:Show()
    else
        emptyText:Hide()
    end

    if alert then Alert() end
end

----------------------------------------------------------------------
-- Événements
----------------------------------------------------------------------
local events, dirty, elapsed = {}, true, 0
local inCombat, hideTimer = false, nil
local optionsOpen = false

-- Visibilité : masqué (/tb hide) > aperçu/options ouvertes > "combat seulement"
local function UpdateVisibility()
    if not db then return end
    if hideTimer then hideTimer:Cancel(); hideTimer = nil end
    local show
    if db.hidden then show = false
    elseif testMode or optionsOpen or not db.combatOnly then show = true
    else show = inCombat end
    frame:SetShown(show)
    if show then dirty = true end
end
ns.UpdateVisibility = UpdateVisibility

function events:ADDON_LOADED(name)
    if name ~= addonName then return end
    ThreatBarsDB = ThreatBarsDB or {}
    if ThreatBarsDB.sound == false then ThreatBarsDB.volume = 0 end -- migration 0.2
    ThreatBarsDB.sound = nil
    CopyDefaults(ThreatBarsDB, DEFAULTS)
    db = ThreatBarsDB
    RestoreDialogVolume() -- au cas où un /reload a coupé la restauration
    ApplyLayout()
    inCombat = InCombatLockdown() and true or false
    if inCombat then StartFight() end
    UpdateSessionLabel()
    UpdateVisibility()
    frame:UnregisterEvent("ADDON_LOADED")
end

function events:PLAYER_LOGIN() BuildRoster(); dirty = true end
function events:GROUP_ROSTER_UPDATE() BuildRoster(); dirty = true end
function events:UNIT_PET() BuildRoster(); dirty = true end
function events:PLAYER_TARGET_CHANGED() dirty = true end
function events:PLAYER_FOCUS_CHANGED() dirty = true end
function events:UNIT_THREAT_LIST_UPDATE() dirty = true end
function events:UNIT_THREAT_SITUATION_UPDATE() dirty = true end
function events:PLAYER_REGEN_DISABLED()
    inCombat = true
    StartFight()
    UpdateVisibility()
end
function events:PLAYER_REGEN_ENABLED()
    inCombat = false
    if fight then Render() end -- dernier relevé avant de clore le combat
    EndFight()
    dirty = true
    -- en mode "combat seulement", on laisse le meter 3 s pour lire l'état final
    if db.combatOnly and not testMode and not optionsOpen then
        if hideTimer then hideTimer:Cancel() end
        hideTimer = C_Timer.NewTimer(3, function() hideTimer = nil; UpdateVisibility() end)
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    local h = events[event]
    if h then h(self, ...) end
end)
for ev in pairs(events) do frame:RegisterEvent(ev) end

frame:SetScript("OnSizeChanged", function() dirty = true end)
ns.MarkDirty = function() dirty = true end

-- Les events de menace sont irréguliers : petit rafraîchissement cadencé en plus
frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < TICK then return end
    elapsed = 0
    if db and (dirty or inCombat or testMode) then
        dirty = false
        Render()
    end
end)

ns.SetTestMode = function(on)
    testMode = on and true or false
    dirty = true
    UpdateVisibility()
    if ns.RefreshOptions then ns.RefreshOptions() end
end
ns.IsTestMode = function() return testMode end
ns.SetOptionsOpen = function(on) optionsOpen = on; UpdateVisibility() end
ns.ApplyLayout = function() ApplyLayout(); dirty = true end
ns.GetDB = function() return db end
ns.HasAtlas, ns.SetAtlasOr, ns.meter, ns.optBtn = HasAtlas, SetAtlasOr, frame, optBtn
ns.HEADER_H = HEADER_H

----------------------------------------------------------------------
-- Commandes
----------------------------------------------------------------------
local function Probe()
    Print("interface " .. tostring(select(4, GetBuildInfo())) .. ", issecretvalue=" .. type(issecretvalue))
    local mob = PickMob()
    if not mob then Print("cible un mob (en combat) puis relance /tb probe") return end
    local labels = { "isTanking", "status", "scaled%", "raw%", "threatValue" }
    local v = { UnitDetailedThreatSituation("player", mob) }
    for i = 1, 5 do
        Print(string.format("%s : %s, secret=%s, lisible=%s", labels[i], type(v[i]), tostring(IsSecret(v[i])), tostring(Usable(v[i]))))
    end
end

SLASH_THREATBARS1 = "/tb"
SLASH_THREATBARS2 = "/threatbars"
SlashCmdList.THREATBARS = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    local n = tonumber(arg)
    if cmd == "" or cmd == "options" or cmd == "config" then ns.ToggleOptions()
    elseif cmd == "test" then ns.SetTestMode(not testMode)
    elseif cmd == "lock" then db.locked = true
    elseif cmd == "unlock" then db.locked = false
    elseif cmd == "warn" and n then db.warn = math.max(0, math.min(130, n)); Print("alerte à " .. db.warn .. "% du pull")
    elseif cmd == "volume" and n then db.volume = math.max(0, math.min(100, n)); Print("volume " .. db.volume .. "%")
    elseif cmd == "pets" then db.pets = not db.pets; BuildRoster()
    elseif cmd == "hide" then db.hidden = true; UpdateVisibility()
    elseif cmd == "show" then db.hidden = false; UpdateVisibility()
    elseif cmd == "reset" then
        wipe(ThreatBarsDB); CopyDefaults(ThreatBarsDB, DEFAULTS); db = ThreatBarsDB
        ApplyLayout(); UpdateVisibility(); if ns.RefreshOptions then ns.RefreshOptions() end
    elseif cmd == "probe" then Probe()
    elseif cmd == "clearlog" then ns.ClearLog(); Print("historique effacé")
    else
        Print("/tb (options) | test | lock | unlock | warn <%> | volume <0-100> | pets | show | hide | reset | clearlog | probe")
    end
    dirty = true
end
