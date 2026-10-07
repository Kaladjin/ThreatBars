--[[
ThreatBars : détail de VOTRE menace par capacité (estimation calculée après le combat)

Sans combat log, le serveur ne donne qu'un total de menace. On enregistre donc pendant le combat :
  * la menace du joueur sur le mob affiché, à chaque fois qu'elle change (relevé à chaque image) ;
  * les sorts lancés (UNIT_SPELLCAST_SUCCEEDED) ;
  * les sorts "au prochain coup" (Frappe héroïque, Enchaînement, Mutiler…) : repérés parce qu'ils
    restent "en attente" (IsCurrentSpell) ; on note le moment où ils partent réellement ;
  * les périodes d'attaque automatique (coups blancs) ;
  * vos effets périodiques présents sur le mob (DoT), d'après ses auras.

Après le combat, chaque hausse de menace (entre deux relevés) est reliée aux événements survenus
juste avant : sorts lancés, Frappes héroïques parties, coups blancs (prévus à partir de la vitesse
de l'arme), ticks de DoT (toutes les 3 s). On cherche la menace par événement qui explique le mieux
l'ensemble (moindres carrés positifs), ce qui démêle aussi les événements regroupés dans une même
mise à jour du serveur. Le décalage entre un événement et sa mise à jour est choisi automatiquement.
Ce qui reste inexpliqué est affiché en « Non attribué ».
]]

local addonName, ns = ...

local AUTO_ATTACK = 6603
local DOT_PERIOD = 3        -- intervalle supposé entre deux ticks de DoT (s)
local LAGS = {}               -- décalages testés entre un événement et sa mise à jour : 0 à 0,6 s
for i = 0, 24 do LAGS[#LAGS + 1] = i * 0.025 end
local MAX_SAMPLES = 20000
local DOT_SCAN_EVERY = 0.5

-- Effets périodiques reconnus (noms FR et EN). Les autres auras (Fracasser armure, cris…)
-- ne génèrent pas de menace dans la durée et ne doivent pas être confondues avec un DoT.
local DOT_NAMES = {}
for _, n in ipairs({
    "Pourfendre", "Rend", "Blessures profondes", "Deep Wounds",
    "Garrot", "Garrote", "Rupture",
    "Morsure de serpent", "Serpent Sting",
    "Corruption", "Malédiction d'agonie", "Curse of Agony", "Siphon de vie", "Siphon Life",
    "Immolation", "Immolate",
    "Mot de l'ombre : Douleur", "Mot de l'ombre : douleur", "Shadow Word: Pain",
    "Peste dévorante", "Devouring Plague",
    "Éclat lunaire", "Moonfire", "Essaim d'insectes", "Insect Swarm",
    "Griffure", "Rake", "Déchirure", "Rip",
    "Horion de flammes", "Flame Shock",
}) do DOT_NAMES[n] = true end

-- Effets au sol / à durée lancés par le joueur (pas d'aura sur le mob) : nom -> { durée, période }
local TIMED_EFFECTS = { ["Consécration"] = { 8, 1 }, ["Consecration"] = { 8, 1 } }

local IsCur = (C_Spell and C_Spell.IsCurrentSpell) or IsCurrentSpell

local function Usable(v) return ns.Usable(v) end

local spellCache = {}
local function SpellInfo(id)
    local c = spellCache[id]
    if c then return c.name, c.icon end
    local name, icon
    pcall(function()
        if C_Spell and C_Spell.GetSpellInfo then
            local i = C_Spell.GetSpellInfo(id)
            if i then name, icon = i.name, i.iconID end
        elseif GetSpellInfo then
            local n, _, ic = GetSpellInfo(id)
            name, icon = n, ic
        end
    end)
    if not Usable(name) then name = nil end
    if not Usable(icon) then icon = nil end
    spellCache[id] = { name = name, icon = icon }
    return name, icon
end

local function IsCurrent(id)
    if not IsCur then return false end
    local ok, v = pcall(IsCur, id)
    return ok and ns.SafeTrue(v) or false -- jamais de test direct : la valeur pourrait être secrète
end

----------------------------------------------------------------------
-- Enregistrement pendant le combat
----------------------------------------------------------------------
local rec          -- combat en cours
local lastRec      -- dernier combat terminé (pour /tb rec)

local function Push(list, item)
    if rec.n < MAX_SAMPLES then
        list[#list + 1] = item
        rec.n = rec.n + 1
    end
end

local function SetAuto(on)
    if not rec or rec.autoOn == on then return end
    rec.autoOn = on
    Push(rec.auto, { GetTime(), on })
end

ns.BD_Start = function()
    rec = {
        t0 = GetTime(), n = 0,
        samples = {},   -- { t, clé du mob, menace }  (menace = false : observation interrompue)
        casts = {},     -- { t, spellID, auProchainCoup }
        speeds = {},    -- { t, main, offhand }
        auto = {},      -- { t, true/false }
        dots = {},      -- { t, clé, { ids } }
        queued = {},    -- sorts "au prochain coup" en attente : [id] = true
        last = {},      -- dernière menace lue par mob
        lastDots = {},
        curKey = nil, nextDotScan = 0, autoOn = nil, nextSpeed = 0,
    }
    SetAuto(IsCurrent(AUTO_ATTACK))
end

local function ScanDots(mob, key, t)
    local ids = {}
    pcall(function()
        if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
        for i = 1, 40 do
            local a = C_UnitAuras.GetAuraDataByIndex(mob, i, "HARMFUL|PLAYER")
            if not a then break end
            local id = a.spellId
            if Usable(id) then
                local name = SpellInfo(id)
                if name and DOT_NAMES[name] then ids[#ids + 1] = id end
            end
        end
    end)
    table.sort(ids)
    local sig = table.concat(ids, ",")
    if rec.lastDots[key] ~= sig then
        rec.lastDots[key] = sig
        Push(rec.dots, { t, key, ids })
    end
end

local function RecordSpeed(now)
    local ok, mh, oh = pcall(UnitAttackSpeed, "player")
    if not ok or not Usable(mh) or mh <= 0 then return end
    if not Usable(oh) or oh <= 0 then oh = nil end
    local last = rec.speeds[#rec.speeds]
    if not last or math.abs(last[2] - mh) > 0.01 or (last[3] or 0) ~= (oh or 0) then
        Push(rec.speeds, { now, mh, oh })
    end
end

local function Sample(now)
    -- sorts "au prochain coup" : ils partent (avec le coup) quand ils ne sont plus en attente
    for id in pairs(rec.queued) do
        if not IsCurrent(id) then
            rec.queued[id] = nil
            Push(rec.casts, { now, id, true })
        end
    end
    if now >= rec.nextSpeed then
        RecordSpeed(now)
        rec.nextSpeed = now + 1
    end

    local mob = ns.PickMob()
    local key = mob and ns.MobKey(mob)
    if key ~= rec.curKey then
        if rec.curKey and rec.last[rec.curKey] then
            Push(rec.samples, { now, rec.curKey, false }) -- on arrête d'observer l'ancien mob
        end
        rec.curKey = key
        if key then rec.last[key] = nil end
    end
    if not key then return end

    local ok, _, _, _, _, v = pcall(UnitDetailedThreatSituation, "player", mob)
    if ok and Usable(v) then -- Usable gère nil et les valeurs secrètes (pas de comparaison directe)
        if rec.last[key] ~= v then
            rec.last[key] = v
            Push(rec.samples, { now, key, v })
            ScanDots(mob, key, now)
            rec.nextDotScan = now + DOT_SCAN_EVERY
        elseif now >= rec.nextDotScan then
            ScanDots(mob, key, now)
            rec.nextDotScan = now + DOT_SCAN_EVERY
        end
    elseif rec.last[key] then
        -- valeur secrète ou absente : on coupe la chaîne pour ne pas inventer un saut
        rec.last[key] = false
        Push(rec.samples, { now, key, false })
    end
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_ENTER_COMBAT")  -- début de l'attaque automatique
driver:RegisterEvent("PLAYER_LEAVE_COMBAT")  -- fin de l'attaque automatique
if driver.RegisterUnitEvent then
    driver:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    driver:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
driver:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if not rec then return end
    if event == "PLAYER_ENTER_COMBAT" then SetAuto(true)
    elseif event == "PLAYER_LEAVE_COMBAT" then SetAuto(false)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit ~= "player" or not Usable(spellID) or spellID == AUTO_ATTACK then return end
        if IsCurrent(spellID) then
            rec.queued[spellID] = true          -- en attente du prochain coup (Frappe héroïque…)
        else
            Push(rec.casts, { GetTime(), spellID })
        end
    end
end)
driver:SetScript("OnUpdate", function()
    if rec then Sample(GetTime()) end
end)

----------------------------------------------------------------------
-- Analyse après le combat
----------------------------------------------------------------------
-- Moindres carrés positifs par descente de coordonnées sur les équations normales
local function NNLS(rows, y, m)
    local G, b = {}, {}
    for j = 1, m do G[j] = {}; b[j] = 0 end
    for i, row in ipairs(rows) do
        for j, aj in pairs(row) do
            b[j] = b[j] + aj * y[i]
            local Gj = G[j]
            for k, ak in pairs(row) do Gj[k] = (Gj[k] or 0) + aj * ak end
        end
    end
    local x = {}
    for j = 1, m do x[j] = 0 end
    for _ = 1, 400 do
        for j = 1, m do
            local gjj = G[j][j] or 0
            if gjj > 0 then
                local sum = b[j]
                for k, gjk in pairs(G[j]) do
                    if k ~= j then sum = sum - gjk * x[k] end
                end
                x[j] = math.max(0, sum / gjj)
            end
        end
    end
    return x
end

-- Périodes "actives" à partir d'une liste d'événements { t, on }
local function Periods(events, tEnd)
    local list, start = {}, nil
    for _, e in ipairs(events) do
        if e[2] and not start then start = e[1]
        elseif not e[2] and start then list[#list + 1] = { start, e[1] }; start = nil end
    end
    if start then list[#list + 1] = { start, tEnd } end
    return list
end

local function SpeedAt(r, t)
    local mh, oh = 2.5, nil
    for _, sp in ipairs(r.speeds) do
        if sp[1] <= t + 0.5 then mh, oh = sp[2], sp[3] else break end
    end
    return mh, oh
end

-- Liste de tous les événements susceptibles de produire de la menace : { t, colonne, info }
local function BuildEvents(r, tEnd)
    local ev = {}
    local function Add(t, key, info) ev[#ev + 1] = { t, key, info } end

    -- sorts lancés et sorts "au prochain coup"
    for _, c in ipairs(r.casts) do
        Add(c[1], "c" .. c[2], { kind = "cast", id = c[2] })
    end

    -- coups blancs prévus : départ de l'attaque auto, puis tous les "vitesse d'arme" ;
    -- une Frappe héroïque remplace un coup et recale le rythme
    for _, p in ipairs(Periods(r.auto, tEnd)) do
        local anchors = { p[1] }
        for _, c in ipairs(r.casts) do
            if c[3] and c[1] > p[1] and c[1] <= p[2] then anchors[#anchors + 1] = c[1] end
        end
        table.sort(anchors)
        for i, a in ipairs(anchors) do
            local spd = SpeedAt(r, a)
            local stop = (anchors[i + 1] or p[2])
            local t = (i == 1) and a or (a + spd)
            while t < stop - 0.25 * spd do
                Add(t, "auto", { kind = "auto", id = AUTO_ATTACK })
                t = t + spd
            end
        end
        local _, oh = SpeedAt(r, p[1])
        if oh then -- main gauche : son propre rythme, sans recalage possible
            local t = p[1]
            while t < p[2] do
                Add(t, "auto", { kind = "auto", id = AUTO_ATTACK })
                t = t + oh
            end
        end
    end

    -- ticks de DoT (d'après la présence de l'aura sur le mob)
    local open = {}
    local function Close(key, id, st, en)
        local t = st + DOT_PERIOD
        while t <= en + 0.2 do
            Add(t, "d" .. id, { kind = "dot", id = id, key = key })
            t = t + DOT_PERIOD
        end
    end
    for _, d in ipairs(r.dots) do
        local t, key, ids = d[1], d[2], d[3]
        open[key] = open[key] or {}
        local now = {}
        for _, id in ipairs(ids) do now[id] = true end
        for id, st in pairs(open[key]) do
            if not now[id] then Close(key, id, st, t); open[key][id] = nil end
        end
        for id in pairs(now) do
            if not open[key][id] then open[key][id] = t end
        end
    end
    for key, ids in pairs(open) do
        for id, st in pairs(ids) do Close(key, id, st, tEnd) end
    end

    -- effets à durée lancés (Consécration…)
    for _, c in ipairs(r.casts) do
        local name = SpellInfo(c[2])
        local te = name and TIMED_EFFECTS[name]
        if te then
            local t = c[1] + te[2]
            while t <= c[1] + te[1] + 0.05 do
                Add(t, "p" .. c[2], { kind = "dot", id = c[2] })
                t = t + te[2]
            end
        end
    end

    table.sort(ev, function(x, y) return x[1] < y[1] end)
    return ev
end

-- Intervalles entre deux relevés consécutifs d'un même mob : { key, t1, t2, dy }
local function BuildIntervals(r)
    local byKey, out = {}, {}
    for _, s in ipairs(r.samples) do
        local list = byKey[s[2]] or {}
        byKey[s[2]] = list
        list[#list + 1] = s
    end
    for key, list in pairs(byKey) do
        local prev
        for _, s in ipairs(list) do
            if s[3] == false then
                prev = nil
            else
                if prev then out[#out + 1] = { key = key, t1 = prev[1], t2 = s[1], dy = s[3] - prev[3] } end
                prev = s
            end
        end
    end
    table.sort(out, function(x, y) return x.t1 < y.t1 end)
    return out
end

-- Construit le système pour un décalage donné et le résout
local function Fit(intervals, events, lag)
    local cols, colIndex = {}, {}
    local A, y, used = {}, {}, {}
    local ei = 1
    for _, iv in ipairs(intervals) do
        local row = {}
        -- événements dont l'effet (t + décalage) tombe dans l'intervalle
        while events[ei] and events[ei][1] + lag <= iv.t1 do ei = ei + 1 end
        local k = ei
        while events[k] and events[k][1] + lag <= iv.t2 do
            local e = events[k]
            if e[3].kind ~= "dot" or not e[3].key or e[3].key == iv.key then
                local j = colIndex[e[2]]
                if not j then
                    cols[#cols + 1] = e[3]
                    j = #cols
                    colIndex[e[2]] = j
                end
                row[j] = (row[j] or 0) + 1
            end
            k = k + 1
        end
        -- une baisse de menace sans événement (reset, effet du mob) n'apprend rien : on l'écarte
        if iv.dy > 0 or next(row) then
            A[#A + 1] = row
            y[#y + 1] = iv.dy
            for j, v in pairs(row) do used[j] = (used[j] or 0) + v end
        end
    end
    local x = NNLS(A, y, #cols)
    local sse = 0
    for i, row in ipairs(A) do
        local pred = 0
        for j, v in pairs(row) do pred = pred + x[j] * v end
        sse = sse + (y[i] - pred) ^ 2
    end
    return { x = x, cols = cols, used = used, y = y, sse = sse, n = #A }
end

local function Analyse(r, tEnd)
    local intervals = BuildIntervals(r)
    if #intervals < 3 then return nil end
    local events = BuildEvents(r, tEnd)

    -- choix du décalage qui explique le mieux les relevés
    local best, bestLag
    for _, lag in ipairs(LAGS) do
        local f = Fit(intervals, events, lag)
        if not best or f.sse < best.sse then best, bestLag = f, lag end
    end

    local total = 0
    for _, v in ipairs(best.y) do total = total + v end
    if total <= 0 then return nil end

    local counts = {}
    for _, c in ipairs(r.casts) do counts[c[2]] = (counts[c[2]] or 0) + 1 end

    -- totaux par capacité (lancer + partie périodique regroupés sous le même nom)
    local byName, explained = {}, 0
    for j, info in ipairs(best.cols) do
        local amount = best.x[j] * (best.used[j] or 0)
        if amount > 0 then
            local name, icon = SpellInfo(info.id)
            if info.kind == "auto" then name = "Attaque automatique" end
            name = name or ("Sort " .. info.id)
            local e = byName[name]
            if not e then
                e = { name = name, icon = icon, id = info.id, total = 0, count = 0 }
                byName[name] = e
            end
            e.total = e.total + amount
            if info.kind == "cast" then
                e.count = counts[info.id] or e.count
                e.id, e.icon = info.id, icon or e.icon -- l'icône du sort lancé prime
            elseif info.kind == "auto" then
                e.count = e.count + (best.used[j] or 0)
            end
            explained = explained + amount
        end
    end
    local rows = {}
    for _, e in pairs(byName) do rows[#rows + 1] = e end
    local rest = total - explained
    if rest > total * 0.03 then
        rows[#rows + 1] = { name = "Non attribué", icon = 134400, total = rest, count = 0, other = true }
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    return { total = math.max(total, explained), rows = rows, lag = bestLag, intervals = best.n }
end

ns.BD_Finish = function(fightDuration)
    if not rec then return nil end
    local r = rec
    rec = nil
    local tEnd = GetTime()
    for id in pairs(r.queued) do r.queued[id] = nil end
    lastRec = r
    local db = ns.GetDB()
    if db and db.recordDebug then
        db.debugRec = { samples = r.samples, casts = r.casts, auto = r.auto, dots = r.dots, speeds = r.speeds, t0 = r.t0, tEnd = tEnd }
    end
    local ok, res = pcall(Analyse, r, tEnd)
    if not ok then
        if db and db.recordDebug then print("|cffc79c6e[ThreatBars]|r erreur d'analyse : " .. tostring(res)) end
        return nil
    end
    if res then res.duration = fightDuration end
    return res
end

----------------------------------------------------------------------
-- Fenêtre de détail (reprend la fenêtre de détail du meter Blizzard)
----------------------------------------------------------------------
local win, entries, caption, scroll = nil, {}, nil, 0
local current, currentSticky

local function FormatEntry(value, perSecond, pct)
    local a, b = ns.Abbrev(value) or "0", ns.Abbrev(perSecond) or "0"
    local p = math.floor(pct * 100 + 0.5)
    if type(DAMAGE_METER_ENTRY_FORMAT_COMPLETE) == "string" then
        local ok, txt = pcall(string.format, DAMAGE_METER_ENTRY_FORMAT_COMPLETE, a, b, p)
        if ok then return txt end
    end
    return string.format("%s (%s)  %d%%", a, b, p)
end

local function Build()
    win = CreateFrame("Frame", "ThreatBarsBreakdown", UIParent)
    win:SetFrameStrata("HIGH")
    win:SetSize(300, 200)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:Hide()

    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    ns.SetAtlasOr(bg, "common-dropdown-bg", 0.05, 0.05, 0.06, 0.95)

    caption = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    caption:SetPoint("TOPLEFT", 20, -12)
    caption:SetPoint("TOPRIGHT", -30, -12)
    caption:SetJustifyH("LEFT")
    caption:SetWordWrap(false)

    win.Close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    win.Close:SetPoint("TOPRIGHT", 0, 0)
    win.Close:SetScript("OnClick", function() win:Hide() end)
    win.Close:Hide()

    win.List = CreateFrame("Frame", nil, win)
    win.List:SetPoint("TOPLEFT", 20, -28)
    win.List:SetPoint("BOTTOMRIGHT", -22, 17)
    win.List:SetClipsChildren(true)

    win.Empty = win.List:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
    win.Empty:SetPoint("TOPLEFT", 0, -4)
    win.Empty:SetPoint("RIGHT")
    win.Empty:SetJustifyH("LEFT")
    win.Empty:SetTextColor(0.7, 0.7, 0.7)

    win:EnableMouseWheel(true)
    win:SetScript("OnMouseWheel", function(_, d)
        scroll = math.max(0, scroll - d)
        ns.RefreshBreakdown()
    end)

    -- comme Blizzard : un clic ailleurs ferme la fenêtre, sauf si elle est épinglée (Maj+clic)
    win:RegisterEvent("GLOBAL_MOUSE_DOWN")
    win:SetScript("OnEvent", function(self)
        if currentSticky or not self:IsShown() then return end
        local inside = self:IsMouseOver()
        if not inside and ns.meter and ns.meter:IsMouseOver() then inside = true end -- clic sur une barre
        if not inside then self:Hide() end
    end)
    win:SetScript("OnHide", function() scroll = 0 end)
    tinsert(UISpecialFrames, "ThreatBarsBreakdown")
end

local function Anchor()
    local m = ns.meter
    win:ClearAllPoints()
    local mx = m:GetCenter()
    local sx = UIParent:GetCenter()
    if mx and sx and mx < sx then
        win:SetPoint("TOPLEFT", m, "TOPRIGHT")
        win:SetPoint("BOTTOMLEFT", m, "BOTTOMRIGHT")
    else
        win:SetPoint("TOPRIGHT", m, "TOPLEFT")
        win:SetPoint("BOTTOMRIGHT", m, "BOTTOMLEFT")
    end
    win:SetWidth(math.max(260, m:GetWidth()))
end

local function GetEntry(i)
    if entries[i] then return entries[i] end
    local e = ns.CreateEntry(win.List)
    local H, S = ns.BAR_H, ns.BAR_SPACING
    e:SetPoint("TOPLEFT", 0, -(i - 1) * (H + S))
    e:SetPoint("RIGHT", win.List, "RIGHT", 0, 0)
    e.Icon:SetTexCoord(0.0625, 0.9, 0.0626, 0.9) -- même recadrage d'icône que Blizzard
    e:EnableMouse(true)
    e:SetScript("OnEnter", function(self)
        local d = self.data
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if d.id and not d.other and d.id ~= AUTO_ATTACK then
            pcall(GameTooltip.SetSpellByID, GameTooltip, d.id)
        else
            GameTooltip:SetText(d.name)
        end
        if d.count and d.count > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Utilisations", tostring(d.count), 1, 0.82, 0, 1, 1, 1)
            GameTooltip:AddDoubleLine("Menace par utilisation", ns.Abbrev(d.total / d.count) or "?", 1, 0.82, 0, 1, 1, 1)
        end
        if d.other then
            GameTooltip:AddLine("Menace qui n'a pas pu être reliée à une capacité\n(rage, soins reçus, bruit de mesure…)", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    e:SetScript("OnLeave", function() GameTooltip:Hide() end)
    entries[i] = e
    return e
end

local FAKE_BREAKDOWN = {
    duration = 60, total = 125000000,
    rows = {
        { name = "Frappe héroïque", icon = 132282, id = 78, total = 41000000, count = 22 },
        { name = "Fracasser armure", icon = 132363, id = 7386, total = 33000000, count = 18 },
        { name = "Attaque automatique", icon = 135274, id = AUTO_ATTACK, total = 21000000, count = 0 },
        { name = "Vengeance", icon = 132353, id = 6572, total = 17000000, count = 9 },
        { name = "Pourfendre", icon = 132155, id = 772, total = 6000000, count = 2 },
        { name = "Non attribué", icon = 134400, total = 7000000, count = 0, other = true },
    },
}

ns.RefreshBreakdown = function()
    if not win or not win:IsShown() then return end
    local bd, label, msg = current.bd, current.label, current.msg
    caption:SetText(label or "")
    for _, e in ipairs(entries) do e:Hide() end
    if not bd then
        win.Empty:SetText(msg or "")
        win.Empty:Show()
        return
    end
    win.Empty:Hide()
    local rows = bd.rows
    local H, S = ns.BAR_H, ns.BAR_SPACING
    local avail = math.max(1, math.floor((win.List:GetHeight() + S) / (H + S)))
    scroll = math.min(scroll, math.max(0, #rows - avail))
    local maxV = rows[1] and rows[1].total or 1
    local sum = 0
    for _, r in ipairs(rows) do sum = sum + r.total end
    local dur = math.max(1, bd.duration or 1)
    local cr, cg, cb = 0.5, 0.5, 0.5
    pcall(function()
        local c = RAID_CLASS_COLORS[current.class]
        if c then cr, cg, cb = c.r, c.g, c.b end
    end)
    for i = 1, math.min(avail, #rows - scroll) do
        local d = rows[i + scroll]
        local e = GetEntry(i)
        e.data = d
        e.bar:SetMinMaxValues(0, maxV)
        e.bar:SetValue(d.total)
        if d.other then e.barTex:SetVertexColor(0.45, 0.45, 0.45) else e.barTex:SetVertexColor(cr, cg, cb) end
        e.Icon:SetTexture(d.icon or 134400)
        e.bar.Name:SetText(d.name)
        e.bar.Value:SetText(FormatEntry(d.total, d.total / dur, sum > 0 and d.total / sum or 0))
        e:Show()
    end
end

local function Open(data, sticky)
    if not win then Build() end
    current, currentSticky = data, sticky
    win.Close:SetShown(sticky and true or false)
    Anchor()
    win:Show()
    ns.RefreshBreakdown()
end

-- Clic sur une ligne du meter
ns.OnEntryClick = function(row, button)
    if button ~= "LeftButton" and button ~= "RightButton" then return end
    if not row then return end
    local sticky = IsShiftKeyDown and IsShiftKeyDown() or false
    if win and win:IsShown() and current and current.row == row and not sticky then
        win:Hide()
        return
    end
    local data = { row = row, class = ns.Usable(row.class) and row.class or nil }

    if not ns.SafeTrue(row.isPlayer) then
        data.msg = "Le détail n'est disponible que pour votre personnage."
        return Open(data, sticky)
    end

    if ns.IsTestMode() then
        data.bd = FAKE_BREAKDOWN
        data.label = "Aperçu · Mannequin d'entraînement [1:00]"
        return Open(data, sticky)
    end

    local db = ns.GetDB()
    local view = ns.GetView()
    local entry
    if view > 0 then
        entry = db.log[view]
    elseif ns.InFight() then
        data.msg = "Le détail est calculé à la fin du combat."
        return Open(data, sticky)
    else
        entry = db.log[1] -- dernier combat
    end
    if not entry then
        data.msg = "Aucun combat enregistré."
    elseif not entry.breakdown then
        data.msg = "Pas assez de mesures pour ce combat\n(combat trop court, ou valeurs masquées par le jeu)."
    else
        data.bd = entry.breakdown
        data.label = string.format("Estimation · %s [%s]", entry.mob or "?", ns.FormatClock(entry.duration or 0))
    end
    Open(data, sticky)
end

ns.BD_Close = function() if win then win:Hide() end end
ns.BD_LastRec = function() return lastRec end
