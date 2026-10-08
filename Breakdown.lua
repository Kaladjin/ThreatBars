--[[
ThreatBars : détail de VOTRE menace par capacité (calculé après le combat)

Principe (0.5.1) — on part de ce qui est sûr et on ne devine rien :
  1. Menace totale : relevée en continu sur TOUS les mobs du combat (cible + barres de vie
     ennemies), par mob. Le total est la somme de votre menace finale sur chaque mob.
  2. Dégâts et soins exacts par sort : lus après le combat dans le meter intégré de Blizzard
     (C_DamageMeter). Ils couvrent aussi ce qui n'a pas d'événement de sort : coups blancs, DoT,
     procs, auras, Bouclier sacré, Épines, Consécration…
  3. Sorts SANS dégâts qui génèrent de la menace (Fracasser armure, cris, Provocation…) : liste
     fermée. Leur menace est mesurée directement : saut de menace (sur tous les mobs) juste après
     chaque lancer « propre » (sans autre sort ni coup blanc prévu autour), valeur médiane.
     Un sort hors liste et sans dégâts (Maîtrise du blocage, Rage sanguinaire…) ne reçoit jamais
     de menace.
  4. Sorts À dégâts que vous lancez (Frappe héroïque, Vengeance, Heurt de bouclier…) : même mesure
     directe quand il y a assez de lancers propres, ce qui capte leurs bonus de menace.
  5. Le reste de la menace est réparti sur les autres sources selon leurs dégâts exacts (soins
     comptés pour moitié). Le total affiché est donc toujours égal à la menace réelle.
]]

local addonName, ns = ...

local AUTO_ATTACK = 6603
local MAX_SAMPLES = 40000
local MEASURE_MIN, MEASURE_MAX = 0.4, 1.4 -- durée de mesure après un lancer (s), adaptée au
                                           -- rythme des mises à jour de menace du serveur
local QUIET_BEFORE = 0.3 -- aucun autre événement juste avant le lancer (s)
local MIN_CLEAN_DMG = 3  -- lancers propres nécessaires pour mesurer un sort à dégâts
local DMT = Enum and Enum.DamageMeterType or {}
local DM_DAMAGE, DM_HEAL = DMT.DamageDone or 0, DMT.HealingDone or 2

-- Sorts sans dégâts qui génèrent de la menace (noms FR et EN). Complétable.
local THREAT_NO_DAMAGE = {}
for _, n in ipairs({
    "Fracasser armure", "Sunder Armor",
    "Cri démoralisant", "Demoralizing Shout",
    "Cri de guerre", "Battle Shout",
    "Cri de commandement", "Commanding Shout",
    "Provocation", "Taunt",
    "Rugissement démoralisant", "Demoralizing Roar",
    "Grondement", "Growl",
    "Rugissement provocateur", "Challenging Roar",
    "Cri de défi", "Challenging Shout",
    "Lucioles (farouche)", "Faerie Fire (Feral)", "Lucioles", "Faerie Fire",
    "Défense vertueuse", "Righteous Defense",
}) do THREAT_NO_DAMAGE[n] = true end

local IsCur = (C_Spell and C_Spell.IsCurrentSpell) or IsCurrentSpell
local DM = C_DamageMeter

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
local lastRec      -- dernier combat terminé

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
        series = {},    -- [clé du mob] = { { t, menace }, ... } (menace = false : observation coupée)
        last = {},      -- dernière menace lue par mob
        seen = {},      -- mobs vus à cette image
        casts = {},     -- { t, spellID, auProchainCoup }
        auto = {},      -- { t, true/false }
        speeds = {},    -- { t, vitesse main droite, main gauche }
        queued = {},    -- sorts "au prochain coup" en attente : [id] = true
        nextSpeed = 0, autoOn = nil,
    }
    SetAuto(IsCurrent(AUTO_ATTACK))
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

-- Identifiant unique du mob (jamais le nom : trois "Gnoll" doivent rester trois mobs)
local function GuidKey(unit)
    local g = UnitGUID(unit)
    if Usable(g) then return g end
end

local function SampleUnit(unit, now)
    local key = GuidKey(unit)
    if not key or rec.seen[key] then return end
    rec.seen[key] = true
    local ok, _, _, _, _, v = pcall(UnitDetailedThreatSituation, "player", unit)
    local s = rec.series[key]
    if ok and Usable(v) then -- Usable gère nil et les valeurs secrètes
        if rec.last[key] ~= v then
            rec.last[key] = v
            if not s then s = {}; rec.series[key] = s end
            Push(s, { now, v })
        end
    elseif s and rec.last[key] then
        rec.last[key] = false -- valeur secrète ou plus de menace : on coupe la série
        Push(s, { now, false })
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

    wipe(rec.seen)
    -- cible (ou cible de la cible / focus), puis tous les ennemis qui ont une barre de vie
    local mob = ns.PickMob()
    if mob then SampleUnit(mob, now) end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and plates then
            for _, plate in ipairs(plates) do
                local u = plate.namePlateUnitToken
                if u then
                    local hostile = UnitCanAttack("player", u)
                    if ns.SafeTrue(hostile) then SampleUnit(u, now) end
                end
            end
        end
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

-- Heures prévues des coups blancs (départ de l'attaque auto puis tous les "vitesse d'arme" ;
-- une Frappe héroïque remplace un coup et recale le rythme). Servent seulement à écarter
-- les lancers qui tombent en même temps qu'un coup blanc.
local function PredictSwings(r, tEnd)
    local swings = {}
    for _, p in ipairs(Periods(r.auto, tEnd)) do
        local anchors = { p[1] }
        for _, c in ipairs(r.casts) do
            if c[3] and c[1] > p[1] and c[1] <= p[2] then anchors[#anchors + 1] = c[1] end
        end
        table.sort(anchors)
        for i, a in ipairs(anchors) do
            local spd = SpeedAt(r, a)
            local stop = anchors[i + 1] or p[2]
            local t = (i == 1) and a or (a + spd)
            while t < stop - 0.25 * spd do swings[#swings + 1] = t; t = t + spd end
        end
        local _, oh = SpeedAt(r, p[1])
        if oh then
            local t = p[1]
            while t < p[2] do swings[#swings + 1] = t; t = t + oh end
        end
    end
    table.sort(swings)
    return swings
end

-- Valeur d'une série à l'instant t (dernier relevé <= t) ; nil si inconnue ou coupée
local function ValueAt(s, t)
    local v
    for _, p in ipairs(s) do
        if p[1] > t then break end
        v = p[2]
    end
    return v
end

local function HasCut(s, t1, t2)
    for _, p in ipairs(s) do
        if p[1] > t2 then break end
        if p[1] > t1 and p[2] == false then return true end
    end
    return false
end

-- Saut de menace (tous mobs confondus) entre juste avant un lancer et MEASURE s après ;
-- nil si le lancer n'est pas "propre" (autre sort ou coup blanc prévu dans la fenêtre)
local function MeasureCast(r, c, swings, measure)
    local tc = c[1]
    local t1, t2 = tc - 0.02, tc + measure
    -- rien d'autre ni pendant la mesure, ni juste avant (une menace pas encore envoyée
    -- par le serveur fausserait le saut) : la zone calme suit la durée de mesure
    local quiet = math.max(QUIET_BEFORE, measure)
    for _, o in ipairs(r.casts) do
        if o ~= c and o[1] > tc - quiet and o[1] <= t2 then return nil end
    end
    for _, sw in ipairs(swings) do
        if sw > t2 then break end
        -- un sort "au prochain coup" EST le coup : seuls les autres coups comptent
        if sw > tc - quiet and not (c[3] and math.abs(sw - tc) < 0.15) then return nil end
    end
    local delta, any = 0, false
    for _, s in pairs(r.series) do
        if not HasCut(s, t1, t2) then
            local a, b = ValueAt(s, t1), ValueAt(s, t2)
            if b and b ~= false then
                delta = delta + (b - ((a and a ~= false) and a or 0))
                any = true
            end
        end
    end
    return any and delta or nil
end

local function Median(t)
    if #t == 0 then return nil end
    table.sort(t)
    local n = #t
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return (t[n / 2] + t[n / 2 + 1]) / 2
end

-- Dégâts / soins exacts du joueur par sort pour le combat qui vient de finir
local function ReadMeter(fightDuration)
    if not (DM and DM.GetCombatSessionSourceFromID) then return nil end
    local guid = UnitGUID("player")
    if not Usable(guid) then return nil end

    local sessionID
    pcall(function()
        local best
        for _, s in ipairs(DM.GetAvailableCombatSessions() or {}) do
            local id, d = s.sessionID, s.durationSeconds
            if Usable(id) and (not best or id > best) then
                if not Usable(d) or math.abs(d - fightDuration) <= math.max(3, fightDuration * 0.25) then
                    best = id
                end
            end
        end
        sessionID = best
    end)

    local function Read(meterType)
        local src
        pcall(function()
            if sessionID then
                src = DM.GetCombatSessionSourceFromID(sessionID, meterType, guid)
            else
                src = DM.GetCombatSessionSourceFromType(1, meterType, guid) -- session courante
            end
        end)
        local out = {}
        for _, sp in ipairs(src and src.combatSpells or {}) do
            local id, amount = sp.spellID, sp.totalAmount
            if not (Usable(id) and Usable(amount)) then return nil end
            if amount > 0 then out[id] = (out[id] or 0) + amount end
        end
        return out
    end
    local dmg = Read(DM_DAMAGE)
    if not dmg then return nil end
    return dmg, Read(DM_HEAL) or {}
end

local function Analyse(r, tEnd, fightDuration)
    -- 1. menace totale réelle : somme de la menace finale (lisible) sur chaque mob
    local total = 0
    for _, s in pairs(r.series) do
        local last
        for _, p in ipairs(s) do if p[2] ~= false then last = p[2] end end
        if last and last > 0 then total = total + last end
    end
    if total <= 0 then return nil end

    -- 2. mesure directe des lancers propres ; la fenêtre suit le rythme des mises à jour serveur
    -- délai entre un lancer et le premier changement de menace qui suit (sur n'importe quel mob) :
    -- sa médiane vaut environ la moitié de l'intervalle de mise à jour du serveur
    local changes = {}
    for _, s in pairs(r.series) do
        for i = 2, #s do
            if s[i][2] ~= false then changes[#changes + 1] = s[i][1] end
        end
    end
    table.sort(changes)
    local delays, ci = {}, 1
    for _, c in ipairs(r.casts) do
        while changes[ci] and changes[ci] < c[1] do ci = ci + 1 end
        if changes[ci] and changes[ci] - c[1] < 2 then delays[#delays + 1] = changes[ci] - c[1] end
    end
    local measure = math.min(MEASURE_MAX, math.max(MEASURE_MIN, (Median(delays) or 0.2) * 2 + 0.1))
    local swings = PredictSwings(r, tEnd)
    local counts, clean = {}, {}
    for _, c in ipairs(r.casts) do
        local id = c[2]
        counts[id] = (counts[id] or 0) + 1
        local d = MeasureCast(r, c, swings, measure)
        if d then
            clean[id] = clean[id] or {}
            table.insert(clean[id], d)
        end
    end

    -- 3. dégâts et soins exacts
    local dmg, heal = ReadMeter(fightDuration)

    local rows = {}
    local function Row(id, amount, count, kind)
        local name, icon = SpellInfo(id)
        if id == AUTO_ATTACK or id == 1 then name = "Attaque automatique"; icon = icon or 135274 end
        rows[#rows + 1] = { name = name or ("Sort " .. id), icon = icon, id = id, total = amount, count = count or 0, kind = kind }
    end

    -- 4. sorts sans dégâts de la liste : menace mesurée
    local fixed, fixedRows, unmeasured = 0, {}, {}
    for id, n in pairs(counts) do
        local name = SpellInfo(id)
        local isDamage = dmg and dmg[id]
        if name and THREAT_NO_DAMAGE[name] and not isDamage then
            local per = clean[id] and math.max(0, Median(clean[id]) or 0) or 0
            if per > 0 then
                fixedRows[#fixedRows + 1] = { id, per * n, n }
                fixed = fixed + per * n
            else
                unmeasured[#unmeasured + 1] = name -- aucun lancer propre : sa menace reste dans le reste
            end
        end
    end
    if fixed > total then -- mesures trop hautes : on les ramène au total
        for _, fr in ipairs(fixedRows) do fr[2] = fr[2] * total / fixed end
        fixed = total
    end
    for _, fr in ipairs(fixedRows) do Row(fr[1], fr[2], fr[3], "fixed") end
    local rest = total - fixed

    if not dmg then
        -- meter Blizzard indisponible : on ne peut pas répartir le reste honnêtement
        if rest > 0 then
            rows[#rows + 1] = { name = "Autres sources (détail indisponible)", icon = 134400, total = rest, count = 0, other = true }
        end
    else
        -- 5. sorts à dégâts lancés avec assez de mesures propres : menace mesurée (bonus compris)
        local measured, mRows = 0, {}
        for id, n in pairs(counts) do
            if dmg[id] and clean[id] and #clean[id] >= MIN_CLEAN_DMG then
                local per = math.max(0, Median(clean[id]) or 0)
                mRows[id] = per * n
                measured = measured + per * n
            end
        end
        -- 6. le reste réparti selon les dégâts exacts (soins pour moitié)
        local pool = {}
        local weight = 0
        for id, amount in pairs(dmg) do
            if not mRows[id] then pool[id] = amount; weight = weight + amount end
        end
        for id, amount in pairs(heal) do
            pool[id] = (pool[id] or 0) + amount * 0.5
            weight = weight + amount * 0.5
        end
        if measured > rest or (weight == 0 and measured < rest) then
            -- mesures incohérentes avec le total : tout répartir selon les dégâts
            wipe(mRows); measured = 0
            wipe(pool); weight = 0
            for id, amount in pairs(dmg) do pool[id] = amount; weight = weight + amount end
            for id, amount in pairs(heal) do pool[id] = (pool[id] or 0) + amount * 0.5; weight = weight + amount * 0.5 end
        end
        for id, amount in pairs(mRows) do Row(id, amount, counts[id], "measured") end
        local remaining = rest - measured
        if weight > 0 then
            for id, w in pairs(pool) do Row(id, remaining * w / weight, counts[id], "share") end
        elseif remaining > 0 then
            rows[#rows + 1] = { name = "Autres sources", icon = 134400, total = remaining, count = 0, other = true }
        end
    end

    -- fusion des lignes de même nom, tri
    local byName, merged = {}, {}
    for _, row in ipairs(rows) do
        local e = byName[row.name]
        if e then e.total = e.total + row.total; e.count = math.max(e.count, row.count)
        else byName[row.name] = row; merged[#merged + 1] = row end
    end
    for i = #merged, 1, -1 do if merged[i].total <= 0 then table.remove(merged, i) end end
    table.sort(merged, function(a, b) return a.total > b.total end)
    table.sort(unmeasured)
    return { total = total, rows = merged, meter = dmg and true or false, measure = measure, unmeasured = unmeasured }
end

-- Appelé à la fin du combat. Renvoie tout de suite un objet qui sera rempli ~1 s plus tard,
-- le temps que le meter Blizzard clôture la session et que ses valeurs redeviennent lisibles.
ns.BD_Finish = function(fightDuration)
    if not rec then return nil end
    local r = rec
    rec = nil
    local tEnd = GetTime()
    wipe(r.queued)
    lastRec = r
    local db = ns.GetDB()
    if db and db.recordDebug then
        db.debugRec = { series = r.series, casts = r.casts, auto = r.auto, speeds = r.speeds, t0 = r.t0, tEnd = tEnd }
    end
    local bd = { pending = true, created = time() }
    C_Timer.After(1, function()
        local ok, res = pcall(Analyse, r, tEnd, fightDuration)
        bd.pending = nil
        if ok and res then
            for k, v in pairs(res) do bd[k] = v end
            bd.duration = fightDuration
        else
            bd.failed = true
            if not ok and db and db.recordDebug then
                print("|cffc79c6e[ThreatBars]|r erreur d'analyse : " .. tostring(res))
            end
        end
        if ns.RefreshBreakdown then ns.RefreshBreakdown() end
    end)
    return bd
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
        GameTooltip:AddLine(" ")
        if d.kind == "fixed" or d.kind == "measured" then
            GameTooltip:AddLine("Menace mesurée directement après chaque lancer.", 0.7, 0.7, 0.7, true)
        elseif d.kind == "share" then
            GameTooltip:AddLine("Part de menace calculée à partir des dégâts exacts du meter Blizzard.", 0.7, 0.7, 0.7, true)
        elseif d.other then
            GameTooltip:AddLine("Le meter Blizzard n'a pas donné de dégâts lisibles pour ce combat.", 0.7, 0.7, 0.7, true)
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
        { name = "Cri démoralisant", icon = 132366, id = 1160, total = 7000000, count = 3 },
    },
}

ns.RefreshBreakdown = function()
    if not win or not win:IsShown() then return end
    if current.entry and not current.bd then -- calcul terminé entre-temps ?
        local bd = current.entry.breakdown
        if bd and not bd.pending then
            if bd.rows then
                current.bd, current.msg = bd, nil
                current.label = string.format("Estimation · %s [%s]", current.entry.mob or "?", ns.FormatClock(current.entry.duration or 0))
            else
                current.msg = "Pas assez de mesures pour ce combat\n(combat trop court, ou valeurs masquées par le jeu)."
            end
            current.entry = nil
        end
    end
    local bd, label, msg = current.bd, current.label, current.msg
    if bd and bd.unmeasured and #bd.unmeasured > 0 then
        label = (label or "") .. "  |cffff9933· non mesuré : " .. table.concat(bd.unmeasured, ", ") .. "|r"
    end
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
    local bd = entry and entry.breakdown
    if bd and bd.pending and time() - (bd.created or 0) > 30 then bd.pending = nil; bd.failed = true end
    if not entry then
        data.msg = "Aucun combat enregistré."
    elseif bd and bd.pending then
        data.msg = "Calcul en cours…"
        data.entry = entry
    elseif not bd or bd.failed or not bd.rows then
        data.msg = "Pas assez de mesures pour ce combat\n(combat trop court, ou valeurs masquées par le jeu)."
    else
        data.bd = entry.breakdown
        data.label = string.format("Estimation · %s [%s]", entry.mob or "?", ns.FormatClock(entry.duration or 0))
    end
    Open(data, sticky)
end

ns.BD_Close = function() if win then win:Hide() end end
ns.BD_LastRec = function() return lastRec end
