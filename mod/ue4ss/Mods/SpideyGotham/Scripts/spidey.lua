-- Spidey in LEGO Gotham, gameplay logic. Loaded by main.lua with the shared state table, so it can be reloaded
-- without registering new frame loops. Tuning, bindings and cue names come from config.lua (generated from design/*.json).
local S, SCRIPT_DIR = ...
local C = assert(loadfile(SCRIPT_DIR .. "\\config.lua"))()
local A, IN = C.abilities, C.inputs

local HOME = (os.getenv("LOCALAPPDATA") or ".") .. "\\SpideyGotham\\"
local MOD_DIR = SCRIPT_DIR:gsub("[/\\]Scripts$", "")
local LINK_EXE = MOD_DIR .. "\\bin\\SpideyLink.exe"

local function log(s) print("[SpideyGotham] " .. tostring(s) .. "\n") end
local function now() return os.clock() end
---------------------------------------------------------------- cues -> SpideyLink
local function cue(id)
    if not id then return end
    local f = io.open(HOME .. "events.txt", "a")
    if f then f:write(id .. "\n"); f:close() end
end

local function ensureLink()
    if S.linkChecked then return end
    S.linkChecked = true
    local f = io.open(HOME .. "link.txt", "r")
    local alive = false
    if f then
        local state, t = f:read("a"):match("^(%S+)%s+(%d+)")
        f:close()
        alive = t and (os.time() - tonumber(t)) < 10 and state ~= "stopped"
    end
    if not alive then
        -- started outside Melty: bring the audio companion up next to the game
        log("starting SpideyLink (attach)")
        os.execute('start "" /b "' .. LINK_EXE .. '" --attach')
    end
end

---------------------------------------------------------------- math
local function V(x, y, z) return { X = x, Y = y, Z = z } end
local function add(a, b) return V(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
local function sub(a, b) return V(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function mul(a, k) return V(a.X * k, a.Y * k, a.Z * k) end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a) local l = len(a); if l < 1e-4 then return V(0, 0, 0) end return mul(a, 1 / l) end
local function copy(v) return V(v.X, v.Y, v.Z) end
local function fwd(rot) -- FRotator (degrees) -> unit vector
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    return V(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p))
end

---------------------------------------------------------------- game access
local KSL = nil
local function ksl()
    if not (KSL and KSL:IsValid()) then KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    return KSL
end

local function localPlayer()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() and pc:IsLocalController() then return pc, pc.Pawn end
    end
end

-- Spidey belongs to Batman only. The suit prints are drawn on Batman's minifig layout, and other characters
-- (Gordon, reached with the game's character switch) keep their own look, portrait and moves.
local SPIDEY_HOST = "BP_Batman_"
local function isHost(pawn)
    local ok, n = pcall(function() return pawn:GetClass():GetFName():ToString() end)
    return ok and n:sub(1, #SPIDEY_HOST) == SPIDEY_HOST
end

local keyCache = {}
local function key(name)
    local k = keyCache[name]
    if not k then k = { KeyName = FName(name) }; keyCache[name] = k end
    return k
end

local function down(pc, names)
    for _, n in ipairs(names) do if not pc:IsInputKeyDown(key(n)) then return false end end
    return true
end

local function inputDown(pc, id)
    local b = IN[id]
    for _, combo in ipairs(b.keyboard_combos or {}) do if down(pc, combo) then return true end end
    for _, combo in ipairs(b.gamepad_combos or {}) do if down(pc, combo) then return true end end
    return false
end

-- dev builds before ability blocking parked input mappings; put any still parked back where they were
if S.parked then
    for _, p in ipairs(S.parked) do
        pcall(function() if p.ctx:IsValid() then p.ctx.Mappings:ForEach(function(i, elem) if i == p.i then elem:get().Key.KeyName = FName(p.key) end end) end end)
    end
    log("restored " .. #S.parked .. " input mappings from an earlier dev build")
    S.parked = nil
end

---------------------------------------------------------------- game's own blocking effects (sheet: ability_blocks, kind effect)
-- LEGO Batman ships native "block" GameplayEffects (e.g. BlockGrapplingGameplayEffect); applying one to the
-- player stops that ability at the source, so the game never offers it (no grapple prompt, no half-started grapple).
local function applyBlockEffects(pawn, on)
    local asc = pawn and pawn.AbilitySystemComponent
    if on then
        S.blockEffects = S.blockEffects or {}
        for _, row in pairs(C.ability_blocks) do
            if row.effect and not S.blockEffects[row.id] then
                local ge = StaticFindObject(row.effect)
                if ge and ge:IsValid() and asc and asc:IsValid() then
                    S.blockEffects[row.id] = { asc = asc, handle = asc:BP_ApplyGameplayEffectToSelf(ge, 1.0, asc:MakeEffectContext()) }
                    log("applied " .. row.id .. " block")
                end
            end
        end
    else
        for id, e in pairs(S.blockEffects or {}) do
            pcall(function() if e.asc:IsValid() then e.asc:RemoveActiveGameplayEffect(e.handle, -1) end end)
            log("removed " .. id .. " block")
        end
        S.blockEffects = {}
    end
end

---------------------------------------------------------------- Batman's gadgets and glide off while Spidey (sheet: ability_blocks)
local function blockedClass(name)
    for _, row in pairs(C.ability_blocks) do
        for _, p in ipairs(row.class_prefixes) do if name:sub(1, #p) == p then return true end end
    end
    return false
end

-- the pawn's ability specs that are blocked, found once per pawn
local function blockedSpecs(pawn)
    if S.blockPawn == pawn and S.blockSpecs and S.blockVersion == C then return S.blockSpecs end
    S.blockPawn, S.blockSpecs, S.blockVersion, S.cancelTries = pawn, {}, C, {}
    local asc = pawn.AbilitySystemComponent
    asc.ActivatableAbilities.Items:ForEach(function(i, e)
        local spec = e:get()
        local ab = spec.Ability
        local cname = ab and ab:IsValid() and ab:GetClass():GetFName():ToString() or ""
        if cname ~= "" and blockedClass(cname) then table.insert(S.blockSpecs, i); S.blockNames = S.blockNames or {}; S.blockNames[i] = cname end
    end)
    log("blocking " .. #S.blockSpecs .. " Batman gadget/glide abilities while Spidey is on")
    return S.blockSpecs
end

local function cancelBlocked(pawn)
    local specs = blockedSpecs(pawn)
    if #specs == 0 then return end
    local wanted = {}
    for _, i in ipairs(specs) do wanted[i] = true end
    pawn.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(i, e)
        if not wanted[i] then return end
        local spec = e:get()
        S.cancelTries = S.cancelTries or {}
        if spec.ActiveCount and spec.ActiveCount > 0 then
            -- a few tries per activation, then leave it (never spam an ability that refuses to end)
            local tries = S.cancelTries[i] or 0
            if tries < 3 then
                if tries == 0 then log("blocked Batman ability " .. tostring(S.blockNames and S.blockNames[i])) end
                S.cancelTries[i] = tries + 1
                local function cancelAll(list)
                    pcall(function() list:ForEach(function(_, ie) local inst = ie:get(); if inst and inst:IsValid() then inst:K2_CancelAbility() end end) end)
                end
                cancelAll(spec.NonReplicatedInstances)
                cancelAll(spec.ReplicatedInstances)
            end
        else
            S.cancelTries[i] = 0
        end
    end)
end
---------------------------------------------------------------- LEGO Spidey suit (sheet: suit)
local KRL = nil
local function krl()
    if not (KRL and KRL:IsValid()) then KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end
    return KRL
end

local function part(pawn, name)
    if name == "CharacterMesh0" then
        local ok, m = pcall(function() return pawn.Mesh end)
        if ok and m and m.IsValid and m:IsValid() then return m end
    end
    if S.partPawn ~= pawn then S.partPawn, S.parts = pawn, {} end
    local cached = S.parts[name]
    if cached and cached:IsValid() then return cached end
    local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
    for _, e in ipairs(comps or {}) do
        local c = e
        local ok, inner = pcall(function() return e:get() end)
        if ok and inner then c = inner end
        local n = c:IsValid() and c:GetFName():ToString()
        if n == name or (n and n:find("(" .. name .. ")", 1, true)) then S.parts[name] = c; return c end
    end
end

local function suitTexture(pawn, rel)
    S.textures = S.textures or {}
    -- No caching across suit-ups: once Batman's textures are back, nothing references the imported prints and
    -- the engine's garbage collector frees them; reusing a freed texture crashed the game (20:12). Within one
    -- suit-up the same import is shared so every parameter gets the same object.
    local t = S.textures[rel]
    if t == nil then
        if rel:sub(1, 5) == "game:" then
            t = StaticFindObject(rel:sub(6)) -- a texture LEGO Batman keeps loaded (e.g. its flat normal map)
        else
            local path = MOD_DIR .. "\\" .. rel:gsub("/", "\\")
            t = krl():ImportFileAsTexture2D(pawn, path)
        end
        if not (t and t:IsValid()) then log("missing suit texture " .. rel); t = false end
        S.textures[rel] = t
    end
    return t or nil
end

local function paramValue(mid, kind, pname)
    -- current value as the game set it (read from the instance chain), so it can be put back
    local mat, found = mid, nil
    while mat and mat:IsValid() and found == nil do
        local list = kind == "texture" and mat.TextureParameterValues or kind == "vector" and mat.VectorParameterValues or mat.ScalarParameterValues
        pcall(function()
            list:ForEach(function(_, p)
                local v = p:get()
                if found == nil and v.ParameterInfo.Name:ToString() == pname then
                    local pv = v.ParameterValue
                    if kind == "vector" then found = { R = pv.R, G = pv.G, B = pv.B, A = pv.A } else found = pv end
                end
            end)
        end)
        local ok, parent = pcall(function() return mat.Parent end)
        mat = ok and parent or nil
    end
    if found == nil and kind == "scalar" then found = 0.0 end
    return found
end

local function setParam(mid, kind, pname, value)
    if kind == "texture" then mid:SetTextureParameterValue(FName(pname), value)
    elseif kind == "vector" then mid:SetVectorParameterValue(FName(pname), value)
    else mid:SetScalarParameterValue(FName(pname), value) end
end

local function isMid(m) return m and m:IsValid() and m:GetFullName():find("^MaterialInstanceDynamic") ~= nil end

-- What F6 puts back. A value that already looks like the suit (a suit-up that half failed, then a level load) is
-- never recorded as Batman's: the sheet's batman_value is used instead, so Batman always gets his face back.
local function original(row, current)
    if row.batman_value ~= nil and current == row.value then return row.batman_value end
    return current
end

-- our imports live in /Engine/Transient; the game's own textures under /Game
local function isOurImport(v)
    local ok, p = pcall(function() return v:GetFullName() end)
    return ok and p and p:find("/Engine/Transient", 1, true) ~= nil
end

-- Batman's own value for a parameter. An imported Spidey texture is never accepted as his: it is looked up on the
-- game's material the dynamic copy was made from instead (then it is always the real asset).
local function batmanValue(mid, kind, pname)
    local v = paramValue(mid, kind, pname)
    if kind == "texture" and v ~= nil and (not v.IsValid or not v:IsValid() or isOurImport(v)) then
        local ok, parent = pcall(function() return mid.Parent end)
        v = ok and parent and parent:IsValid() and paramValue(parent, kind, pname) or nil
    end
    return v
end

-- Every Batman suit is the same minifig body (so the Spidey prints fit all of them) plus its own pieces: cowl,
-- cape, armour, belts. Any visible mesh piece other than the kept ones (sheet: suit.other_parts) is hidden while
-- Spidey is on; each one hidden is recorded so F6 shows it again.
local function hideOtherParts(pawn, row, record)
    local function kept(n)
        for _, k in ipairs(row.parameters) do
            -- the same naming rule as part(): menu figures call their body "Mesh (CharacterMesh0)"
            if n == k or n:find("(" .. k .. ")", 1, true) then return true end
        end
        return false
    end
    S.otherHidden = S.otherHidden or {}
    for _, e in ipairs(pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.MeshComponent")) or {}) do
        local c = e; local ok, inner = pcall(function() return e:get() end); if ok and inner then c = inner end
        if c:IsValid() and not kept(c:GetFName():ToString()) and c:IsVisible() then
            local key = c:GetFullName()
            if record and S.suitUndo and not S.otherHidden[key] then
                S.otherHidden[key] = true
                table.insert(S.suitUndo, { c = c, kind = "visibility", value = true })
            end
            c:SetVisibility(false, false)
        end
    end
end

-- Put one material row of the suit on a part's current dynamic material, recording Batman's values for F6.
-- Remembers which material it went on: some suits (Batman Beyond) get a fresh face material from the game after
-- suit-up, and enforceSuit then repeats this on the new one (face print missing, 2026-10-10).
local function applyMaterialRow(pawn, row, c)
    local mid = c:GetMaterial(0)
    if not (mid and mid:IsValid()) then return end
    local value
    if row.kind == "texture" then value = suitTexture(pawn, row.value)
    elseif row.kind == "vector" then value = { R = row.value[1], G = row.value[2], B = row.value[3], A = row.value[4] }
    else value = row.value end
    if value == nil then return end
    for _, pname in ipairs(row.parameters) do
        table.insert(S.suitUndo, { mid = mid, kind = row.kind, name = pname, value = original(row, batmanValue(mid, row.kind, pname)) })
        setParam(mid, row.kind, pname, value)
    end
    S.rowMids = S.rowMids or {}
    S.rowMids[row.id] = mid:GetFullName()
end

local function suitUp(pawn, now_)
    if S.suitUndo then return true end -- already suited: never record Spidey's own textures as "Batman's originals"
    -- Right after a level load the minifig usually still wears the game's shared materials and gets its own dynamic
    -- copies a moment later; wait for those (the frame loop retries). After some loads (menu -> game) a part never
    -- gets one: after a second the suit makes that copy itself. The shared material is never edited.
    if S.suitWaitPawn ~= pawn:GetFullName() then S.suitWaitPawn, S.suitWaitSince = pawn:GetFullName(), now() end
    -- right after our own suit switch there is no waiting: the player must never see the base suit (if the game
    -- gives a part its own material afterwards, enforceSuit puts the suit on that one too)
    local waited = now_ or now() - S.suitWaitSince > 1.0
    for _, row in pairs(C.suit) do
        if row.kind == "texture" or row.kind == "vector" or row.kind == "scalar" then
            local c = part(pawn, row.component)
            if c and not isMid(c:GetMaterial(0)) then
                if not waited then return false end
                c:CreateDynamicMaterialInstance(0, c:GetMaterial(0), FName("None"))
                if not isMid(c:GetMaterial(0)) then return false end
                log("made " .. row.component .. " its own material copy (none after this load)")
            end
        end
    end
    S.suitWaitSince, S.suitWaitPawn = nil, nil
    S.suitUndo, S.textures, S.otherHidden = {}, {}, {}
    -- material swaps first, so the texture rows below land on the new material: other Batman suits' face materials
    -- can lack the slots the Spidey prints use (Batman Beyond lost its face)
    for _, row in pairs(C.suit) do
        if row.kind == "material" then
            local okm, errm = pcall(function()
                local c = part(pawn, row.component)
                local base = StaticFindObject(row.value)
                if not (base and base:IsValid()) then base = LoadAsset(row.value) end
                if c and base and base:IsValid() then
                    table.insert(S.suitUndo, { c = c, kind = "material", value = c:GetMaterial(0) })
                    c:CreateDynamicMaterialInstance(0, base, FName("None"))
                end
            end)
            if not okm then log("suit row " .. row.id .. " error: " .. tostring(errm)) end
        end
    end
    for _, row in pairs(C.suit) do
        if row.kind == "material" then goto continue end
        local c = part(pawn, row.component)
        local okr, errr = pcall(function()
        if row.kind == "hide_others" then hideOtherParts(pawn, row, true)
        elseif c then
            if row.kind == "visibility" then
                table.insert(S.suitUndo, { c = c, kind = "visibility", value = original(row, c:IsVisible()) })
                c:SetVisibility(row.value, true)
            elseif row.kind == "tick" then
                table.insert(S.suitUndo, { c = c, kind = "tick", value = original(row, c:IsComponentTickEnabled()) })
                c:SetComponentTickEnabled(row.value)
            elseif row.kind == "anim" then
                -- One fixed pose instead of the game's expression blueprint (Batman's comes back on F6): the pose
                -- plays for a moment so it settles, then the component is paused there. Paused, its animation
                -- can no longer write the face's material curves (MouthHide etc.), so the suit's values stick.
                table.insert(S.suitUndo, { c = c, kind = "anim", value = c:GetAnimationMode(), tick = c:IsComponentTickEnabled() })
                local seq = StaticFindObject(row.value)
                c:SetComponentTickEnabled(true)
                if seq and seq:IsValid() then c:PlayAnimation(seq, true) else log("missing animation " .. row.value) end
                S.animSettleUntil = now() + 0.25
            else
                applyMaterialRow(pawn, row, c)
            end
        end
        end)
        if not okr then log("suit row " .. row.id .. " error: " .. tostring(errr)) end
        ::continue::
    end
    S.suitPawn, S.suitPawnName = pawn, pawn:GetFullName()
    log("suited up as Spider-Man")
    return true
end

-- The main menu's big minifig is a cutscene copy of Batman whose materials are shared constant instances, so the
-- suit goes onto dynamic copies made per component. Nothing is recorded for undo: the figure only lives in the
-- menu, and the suit there is permanent so players can see the mod is installed.
local function suitMenuFigure(fig)
    local textures = {}
    -- face material first, as in suitUp: other suits' faces can lack the print slots
    for _, row in pairs(C.suit) do
        if row.kind == "material" then
            local c = part(fig, row.component)
            local base = StaticFindObject(row.value)
            if not (base and base:IsValid()) then base = LoadAsset(row.value) end
            if c and base and base:IsValid() then c:CreateDynamicMaterialInstance(0, base, FName("None")) end
        end
    end
    for _, row in pairs(C.suit) do
        local c = part(fig, row.component)
        if c then
            if row.kind == "visibility" then c:SetVisibility(row.value, true)
            elseif row.kind == "tick" then c:SetComponentTickEnabled(row.value)
            elseif row.kind == "texture" or row.kind == "vector" or row.kind == "scalar" then
                local mid = c:GetMaterial(0)
                if mid and mid:IsValid() and not mid:GetFullName():find("^MaterialInstanceDynamic") then
                    mid = c:CreateDynamicMaterialInstance(0, mid, FName("None"))
                end
                local value = row.value
                if row.kind == "texture" then
                    value = textures[row.value]
                    if value == nil then
                        if row.value:sub(1, 5) == "game:" then value = StaticFindObject(row.value:sub(6))
                        else value = krl():ImportFileAsTexture2D(fig, MOD_DIR .. "\\" .. row.value:gsub("/", "\\")) end
                        textures[row.value] = value
                    end
                elseif row.kind == "vector" then
                    value = { R = row.value[1], G = row.value[2], B = row.value[3], A = row.value[4] }
                end
                if value ~= nil and mid and mid:IsValid() then
                    for _, pname in ipairs(row.parameters) do setParam(mid, row.kind, pname, value) end
                end
            end
        end
    end
    -- The menu scene rims the figure with a strong cyan spot and panel light (Batman's look). On Spidey's white
    -- lenses that read as a bright cyan glow, so blue lights right next to the figure are turned white at half
    -- strength (once each): the lenses keep a white glow, as the player chose.
    local fl = fig:K2_GetActorLocation()
    for _, cls in ipairs({ "SpotLightComponent", "RectLightComponent" }) do
        for _, l in ipairs(FindAllOf(cls) or {}) do
            if l:IsValid() and not l:GetFullName():find("Default__") then
                local p, c = l:K2_GetComponentLocation(), l.LightColor
                local d = math.sqrt((p.X - fl.X) ^ 2 + (p.Y - fl.Y) ^ 2 + (p.Z - fl.Z) ^ 2)
                if d < 400 and c.B > 2 * c.R then   -- once whitened it is no longer blue, so this runs once per light
                    l:SetLightColor({ R = 1, G = 1, B = 1, A = 1 }, true)
                    l:SetIntensity(l.Intensity * 0.5)
                end
            end
        end
    end
    log("suited the main menu figure as Spider-Man")
end

local function suitDown()
    for i = #(S.suitUndo or {}), 1, -1 do
        local u = S.suitUndo[i]
        pcall(function()
            if u.kind == "visibility" then if u.c:IsValid() then u.c:SetVisibility(u.value, true) end
            elseif u.kind == "tick" then if u.c:IsValid() then u.c:SetComponentTickEnabled(u.value) end
            elseif u.kind == "anim" then
                if u.c:IsValid() then u.c:SetAnimationMode(u.value, true); u.c:SetComponentTickEnabled(u.tick) end
            elseif u.kind == "material" then
                if u.c:IsValid() and u.value and u.value:IsValid() then u.c:SetMaterial(0, u.value) end
            elseif u.mid:IsValid() then
                local v = u.value
                -- a texture that is gone or one of our imports: take Batman's from the game's material instead
                if u.kind == "texture" and (v == nil or not v:IsValid() or isOurImport(v)) then
                    local parent = u.mid.Parent
                    v = parent and parent:IsValid() and paramValue(parent, "texture", u.name) or nil
                end
                if v ~= nil then setParam(u.mid, u.kind, u.name, v) end
            end
        end)
    end
    S.suitUndo, S.suitPawn, S.suitPawnName, S.textures, S.rowMids = nil, nil, nil, {}, nil
    log("back to Batman")
end

-- Batman's gadget props (BatClaw, grapple gun, batarang) are actors the game attaches to the minifig's hands; the
-- game shows them when a gadget animation or a (blocked) gadget ability starts. Spidey holds nothing.
local function hideGadgetProps(pawn, row)
    local list = {}
    pcall(function() pawn:GetAttachedActors(list, true, true) end)
    for _, e in ipairs(list) do
        local a = e; local ok, inner = pcall(function() return e:get() end); if ok and inner then a = inner end
        if a:IsValid() then
            local cn = a:GetClass():GetFName():ToString()
            for _, part in ipairs(row.parameters) do
                if cn:find(part, 1, true) then
                    if not a.bHidden then a:SetActorHiddenInGame(true) end
                    break
                end
            end
        end
    end
end

local function enforceSuit(pawn)
    for _, row in pairs(C.suit) do
        if row.kind == "hide_actors" then
            hideGadgetProps(pawn, row)
        elseif row.kind == "hide_others" then
            -- recorded for F6 only on the suited player; the menu figure keeps the suit for good
            hideOtherParts(pawn, row, S.suitPawnName == pawn:GetFullName())
        elseif (row.kind == "texture" or row.kind == "vector" or (row.kind == "scalar" and not row.enforce_each_frame))
            and S.suitUndo and S.suitPawnName == pawn:GetFullName() then
            -- the game gave this part a new material after suit-up: put the suit on that one too
            local c = part(pawn, row.component)
            local m = c and c:GetMaterial(0)
            if m and m:IsValid() and isMid(m) and S.rowMids and S.rowMids[row.id] ~= m:GetFullName() then
                applyMaterialRow(pawn, row, c)
                if now() - (S.lastReapplyLog or 0) > 2 then S.lastReapplyLog = now(); log("suit re-applied to " .. row.component .. "'s new material") end
            end
        elseif row.enforce_each_frame then
            local c = part(pawn, row.component)
            if c and row.kind == "visibility" then
                if c:IsVisible() ~= row.value then c:SetVisibility(row.value, true) end
            elseif c and row.kind == "tick" then
                if c:IsComponentTickEnabled() ~= row.value then c:SetComponentTickEnabled(row.value) end
            elseif c and row.kind == "anim" then
                if c:GetAnimationMode() ~= 1 then
                    -- the game handed the face back to its expression blueprint (cutscenes, respawns): pose it again
                    local seq = StaticFindObject(row.value)
                    c:SetComponentTickEnabled(true)
                    if seq and seq:IsValid() then c:PlayAnimation(seq, true) end
                    S.animSettleUntil = now() + 0.25
                elseif S.animSettleUntil and now() < S.animSettleUntil then
                    if not c:IsComponentTickEnabled() then c:SetComponentTickEnabled(true) end
                elseif c:IsComponentTickEnabled() then
                    c:SetComponentTickEnabled(false)   -- settled: hold the neutral pose
                    S.animSettleUntil = nil
                end
            elseif c and row.kind == "scalar" then
                -- the face animation rewrites these every frame (that is how Batman's mouth came back)
                local mid = c:GetMaterial(0)
                for _, pname in ipairs(row.parameters) do mid:SetScalarParameterValue(FName(pname), row.value) end
            end
        end
    end
end

---------------------------------------------------------------- HUD portrait
-- The bottom-left portrait (W_PlayerPortrait_C) draws a texture through its material's "Icon" parameter.
-- Spidey's is rendered on the player's own PC on every suit-up (~0.02 s): a SceneCapture2D that sees only the suited
-- minifig, read back and saved as a TGA, then imported fresh on every suit-up (see suitTexture for why imports
-- are never reused). Batman's icon is put back by path, so a garbage-collected wrapper is never touched.
local PORTRAIT = HOME .. "portrait.tga"
local PORTRAIT_KEY = HOME .. "portrait.key"

local function suitKey()   -- changes whenever a suit texture file changes (good enough: sizes of the prints)
    local parts = {}
    for _, row in pairs(C.suit) do
        if row.kind == "texture" and not row.value:find("^game:") then
            local fh = io.open(MOD_DIR .. "\\" .. row.value:gsub("/", "\\"), "rb")
            if fh then parts[#parts + 1] = row.value .. "=" .. fh:seek("end"); fh:close() end
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

S.portraitShot = nil   -- re-checked against the saved portrait after every (re)load of this file

local function portraitCurrent()   -- a saved portrait exists and was taken with the current suit textures
    local fh = io.open(PORTRAIT, "rb"); if not fh then return false end; fh:close()
    local kf = io.open(PORTRAIT_KEY, "r"); if not kf then return false end
    local k = kf:read("a"); kf:close()
    return k == suitKey()
end

local function portraitMids()
    local mids = {}
    for _, w in ipairs(FindAllOf("W_PlayerPortrait_C") or {}) do
        if w:IsValid() and not w:GetFullName():find("Default__") then
            local ok, mid = pcall(function() return w.IMG_Character.Brush.ResourceObject end)
            if ok and mid and mid:IsValid() then mids[#mids + 1] = mid end
        end
    end
    return mids
end

local function capturePortrait(pawn)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local face = part(pawn, "Face")
    local head = face and face:K2_GetComponentLocation() or add(pawn:K2_GetActorLocation(), V(0, 0, 60))
    -- three-quarter view from the face's front-left, slightly above, like the game's own portraits. Aimed off the
    -- face (which turns when the minifig looks around), so the portrait always looks out at the player.
    local yaw = math.rad((face and face:K2_GetComponentRotation().Yaw or pawn:K2_GetActorRotation().Yaw) + 25)
    local cam = V(head.X + math.cos(yaw) * 150, head.Y + math.sin(yaw) * 150, head.Z + 18)
    local d = sub(V(head.X, head.Y, head.Z + 4), cam)
    local rot = { Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = cam, Scale3D = V(1, 1, 1) }
    local a = gs:BeginDeferredActorSpawnFromClass(pawn, StaticFindObject("/Script/Engine.SceneCapture2D"), xf, 1, nil, 0)
    a = gs:FinishSpawningActor(a, xf, 0)
    a:K2_SetActorLocationAndRotation(cam, rot, false, {}, true)
    local W = 256
    local rt = krl():CreateRenderTarget2D(pawn, W, W, 2, { R = 0, G = 0, B = 0, A = 0 }, false, false)
    local cc = a.CaptureComponent2D
    cc.TextureTarget = rt
    cc.CaptureSource = 0
    cc.PrimitiveRenderMode = 2
    cc.bCaptureEveryFrame = false
    cc.bCaptureOnMovement = false
    cc.FOVAngle = 30
    cc:ShowOnlyActorComponents(pawn, true)
    cc:CaptureScene()
    local samples = {}
    krl():ReadRenderTarget(pawn, rt, samples, false)
    a:K2_DestroyActor()
    if #samples ~= W * W then log("portrait capture failed (" .. #samples .. " pixels)"); return false end
    -- 32-bit TGA, top-left origin. The capture stores inverted opacity. Exposure is set from the picture itself
    -- (the brightest few percent of the minifig land near white), so the portrait looks the same in any lighting.
    local px, peaks = {}, {}
    for i = 1, #samples do
        local e = samples[i]
        local c = e.get and e:get() or e
        px[i] = { c.R, c.G, c.B, 255 - c.A }
        if px[i][4] > 128 then peaks[#peaks + 1] = math.max(c.R, c.G, c.B) ^ 0.75 end
    end
    table.sort(peaks)
    local peak = peaks[math.max(1, math.floor(#peaks * 0.97))] or 1
    local gain = math.max(0.8, math.min(4.0, (235 ^ 0.75) / math.max(peak, 1)))
    local function g(v) return math.min(255, math.floor(255 * ((v / 255) ^ 0.75) * gain)) end
    local parts, row = { string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, W % 256, W // 256, W % 256, W // 256, 32, 0x28) }, {}
    for i = 1, #px do
        local c = px[i]
        row[#row + 1] = string.char(g(c[3]), g(c[2]), g(c[1]), c[4])
        if #row == W then parts[#parts + 1] = table.concat(row); row = {} end
    end
    local f = io.open(PORTRAIT, "wb")
    if not f then return false end
    f:write(table.concat(parts)); f:close()
    S.portraitShot = true
    log("rendered HUD portrait")
    return true
end

local function texPath(t) return (t:GetFullName():gsub("^%S+%s+", "")) end

---------------------------------------------------------------- launch splash
-- The game shows Content\Splash\Splash.bmp (720x370, 24-bit) while it starts, before any mod runs. The mod builds a
-- Spider-Man one on the player's PC: the mod's own background (assets/splash_base.tga, drawn by tools/make_splash.py)
-- with the player's suited minifig rendered full-body into SPLASH_BOX, written over the game's file after the
-- original is kept as Splash_Batman_original.bmp next to it. Ours is 799,254 bytes (no row padding) where the
-- game's is 799,256, which tells them apart: when Steam puts the original back, the mod backs it up and rebuilds.
local SPLASH_W, SPLASH_H = 720, 370
local SPLASH_BOX = { x0 = 40, y0 = 20, x1 = 330, y1 = 356 }   -- matches tools/make_splash.py; bottom = the ledge
local SPLASH_DIR = MOD_DIR .. "\\..\\..\\..\\..\\..\\Content\\Splash\\"
local SPLASH_FILE, SPLASH_BACKUP = SPLASH_DIR .. "Splash.bmp", SPLASH_DIR .. "Splash_Batman_original.bmp"
local SPLASH_OURS = 54 + SPLASH_W * SPLASH_H * 3

local function fileSize(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local n = f:seek("end"); f:close(); return n
end

local function copyFile(from, to)
    local f = io.open(from, "rb"); if not f then return false end
    local data = f:read("a"); f:close()
    local o = io.open(to, "wb"); if not o then return false end
    o:write(data); o:close(); return true
end

-- the splash is ours and was built from the current suit and background
local function splashCurrent()
    if fileSize(SPLASH_FILE) ~= SPLASH_OURS then return false end
    local kf = io.open(HOME .. "splash.key", "r"); if not kf then return false end
    local k = kf:read("a"); kf:close()
    return k == suitKey() .. ";base=" .. tostring(fileSize(MOD_DIR .. "\\assets\\splash_base.tga"))
end

-- full-body render of the suited minifig, three-quarter view like the HUD portrait; returns W, rows of {r,g,b,a}
local function captureFigure(pawn, W)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local face = part(pawn, "Face")
    local mid = pawn:K2_GetActorLocation()
    local yaw = math.rad((face and face:K2_GetComponentRotation().Yaw or pawn:K2_GetActorRotation().Yaw) + 25)
    local dist = 420
    local cam = V(mid.X + math.cos(yaw) * dist, mid.Y + math.sin(yaw) * dist, mid.Z + 30)
    local d = sub(V(mid.X, mid.Y, mid.Z + 5), cam)
    local rot = { Pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y))), Yaw = math.deg(math.atan(d.Y, d.X)), Roll = 0 }
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = cam, Scale3D = V(1, 1, 1) }
    local a = gs:BeginDeferredActorSpawnFromClass(pawn, StaticFindObject("/Script/Engine.SceneCapture2D"), xf, 1, nil, 0)
    a = gs:FinishSpawningActor(a, xf, 0)
    a:K2_SetActorLocationAndRotation(cam, rot, false, {}, true)
    local rt = krl():CreateRenderTarget2D(pawn, W, W, 2, { R = 0, G = 0, B = 0, A = 0 }, false, false)
    local cc = a.CaptureComponent2D
    cc.TextureTarget = rt
    cc.CaptureSource = 0
    cc.PrimitiveRenderMode = 2
    cc.bCaptureEveryFrame = false
    cc.bCaptureOnMovement = false
    cc.FOVAngle = 32
    cc:ShowOnlyActorComponents(pawn, true)
    cc:CaptureScene()
    local samples = {}
    krl():ReadRenderTarget(pawn, rt, samples, false)
    a:K2_DestroyActor()
    if #samples ~= W * W then return nil end
    local px, peaks = {}, {}
    for i = 1, #samples do
        local e = samples[i]
        local c = e.get and e:get() or e
        px[i] = { c.R, c.G, c.B, 255 - c.A }   -- the capture stores inverted opacity
        if px[i][4] > 128 then peaks[#peaks + 1] = math.max(c.R, c.G, c.B) ^ 0.75 end
    end
    -- the same exposure as the portrait, so the figure looks the same in any lighting
    table.sort(peaks)
    local peak = peaks[math.max(1, math.floor(#peaks * 0.97))] or 1
    local gain = math.max(0.8, math.min(4.0, (235 ^ 0.75) / math.max(peak, 1)))
    for i = 1, #px do
        local c = px[i]
        for k = 1, 3 do c[k] = math.min(255, math.floor(255 * ((c[k] / 255) ^ 0.75) * gain)) end
    end
    return W, px
end

local function buildSplash(pawn)
    local bf = io.open(MOD_DIR .. "\\assets\\splash_base.tga", "rb"); if not bf then log("splash background missing"); return false end
    local base = bf:read("a"); bf:close()
    local W, fig = captureFigure(pawn, 512)
    if not W then log("splash render failed"); return false end
    -- the figure's outline in the render
    local minx, miny, maxx, maxy = W, W, -1, -1
    for y = 0, W - 1 do
        for x = 0, W - 1 do
            if fig[y * W + x + 1][4] > 20 then
                if x < minx then minx = x end; if x > maxx then maxx = x end
                if y < miny then miny = y end; if y > maxy then maxy = y end
            end
        end
    end
    if maxx < 0 then log("splash render empty"); return false end
    local fw, fh = maxx - minx + 1, maxy - miny + 1
    local bw, bh = SPLASH_BOX.x1 - SPLASH_BOX.x0, SPLASH_BOX.y1 - SPLASH_BOX.y0
    local s = math.min(bw / fw, bh / fh)
    local ox = SPLASH_BOX.x0 + math.floor((bw - fw * s) / 2)
    local oy = SPLASH_BOX.y1 - math.floor(fh * s)      -- feet on the ledge
    -- compose (base is BGRA, top-left origin after an 18-byte header) and write a bottom-up 24-bit BMP
    local rows = {}
    for y = SPLASH_H - 1, 0, -1 do
        local row = {}
        for x = 0, SPLASH_W - 1 do
            local o = 18 + (y * SPLASH_W + x) * 4
            local b, g, r = base:byte(o + 1, o + 3)
            local fx = math.floor((x - ox) / s) + minx
            local fy = math.floor((y - oy) / s) + miny
            if x >= ox and y >= oy and fx >= minx and fx <= maxx and fy >= miny and fy <= maxy then
                local c = fig[fy * W + fx + 1]
                local k = c[4] / 255
                if k > 0 then
                    r = math.floor(c[1] * k + r * (1 - k) + 0.5)
                    g = math.floor(c[2] * k + g * (1 - k) + 0.5)
                    b = math.floor(c[3] * k + b * (1 - k) + 0.5)
                end
            end
            row[#row + 1] = string.char(b, g, r)
        end
        rows[#rows + 1] = table.concat(row)
    end
    local size = SPLASH_OURS
    local function u32(n) return string.char(n % 256, (n // 256) % 256, (n // 65536) % 256, n // 16777216) end
    local header = "BM" .. u32(size) .. u32(0) .. u32(54) .. u32(40) .. u32(SPLASH_W) .. u32(SPLASH_H)
        .. string.char(1, 0, 24, 0) .. u32(0) .. u32(SPLASH_W * SPLASH_H * 3) .. u32(2835) .. u32(2835) .. u32(0) .. u32(0)
    -- keep the game's own splash first (also after Steam restored it: then it may be a newer one)
    local cur = fileSize(SPLASH_FILE)
    if cur and cur ~= SPLASH_OURS then
        if not copyFile(SPLASH_FILE, SPLASH_BACKUP) then log("could not back up the game's splash"); return false end
    end
    local f = io.open(SPLASH_FILE, "wb"); if not f then log("could not write the splash"); return false end
    f:write(header); f:write(table.concat(rows)); f:close()
    local kf = io.open(HOME .. "splash.key", "w")
    if kf then kf:write(suitKey() .. ";base=" .. tostring(fileSize(MOD_DIR .. "\\assets\\splash_base.tga"))); kf:close() end
    log("built the Spider-Man launch splash")
    return true
end

local function setPortrait(on, pawn)
    local icon = FName("Icon")
    if on then
        -- The portrait is one fixed snapshot kept on disk and reused on every suit-up. A new one is only taken when
        -- the suit's textures change (portrait.key holds their sizes), and only in the moment just after Spidey
        -- stops on the ground, before any idle animation (crossed arms etc.) starts, so it is always the plain
        -- standing pose.
        if not S.portraitShot and S.portraitStill and capturePortrait(pawn) then
            S.portraitTex = nil
            local kf = io.open(PORTRAIT_KEY, "w"); if kf then kf:write(suitKey()); kf:close() end
        end
        if not (S.portraitTex and S.portraitTex:IsValid()) then
            local fh = io.open(PORTRAIT, "rb")
            if not fh then return end
            fh:close()
            S.portraitTex = krl():ImportFileAsTexture2D(pawn, PORTRAIT)
            if not (S.portraitTex and S.portraitTex:IsValid()) then S.portraitTex = nil; return end
        end
        local want = S.portraitTex:GetAddress()
        for _, mid in ipairs(portraitMids()) do
            local cur = mid:K2_GetTextureParameterValue(icon)
            if not (cur and cur:IsValid() and cur:GetAddress() == want) then
                -- only the game's own icons count as originals (an earlier Spidey import lives in /Engine/Transient)
                if cur and cur:IsValid() and texPath(cur):sub(1, 6) == "/Game/" then S.portraitOrig = texPath(cur) end
                mid:SetTextureParameterValue(icon, S.portraitTex)
            end
        end
    else
        local orig = S.portraitOrig and (StaticFindObject(S.portraitOrig) or LoadAsset(S.portraitOrig))
        if orig and orig:IsValid() then
            for _, mid in ipairs(portraitMids()) do mid:SetTextureParameterValue(icon, orig) end
        end
        S.portraitTex, S.portraitOrig = nil, nil
    end
end

---------------------------------------------------------------- main menu: logo
-- The game's logo (LEGO brick, DC emblem, "BATMAN", subtitle) is read from the player's own install, the word
-- BATMAN is erased and the mod's SPIDER-MAN wordmark (assets/spidey_wordmark.tga, original art, same 2048x512
-- layout) is drawn in its place. The result is cached on disk and shown on every logo widget.
local WORDMARK = MOD_DIR .. "\\assets\\spidey_wordmark.tga"
local LOGO_ERASE = { x0 = 600, x1 = 1994, y0 = 140, y1 = 414, keepX0 = 1150, keepX1 = 1410, keepY1 = 172 }  -- keep DC emblem

local function buildLogo(ctxObj, logoTex)
    local out = HOME .. "menu_logo.tga"
    local wf = io.open(WORDMARK, "rb"); if not wf then log("missing wordmark"); return nil end
    local wm = wf:read("a"); wf:close()
    local key = logoTex:GetFullName() .. "|" .. #wm
    local kf = io.open(out .. ".key", "r")
    if kf then
        local k = kf:read("a"); kf:close()
        local of = io.open(out, "rb")
        if of then of:close(); if k == key then return out end end
    end
    local W, H = logoTex:Blueprint_GetSizeX(), logoTex:Blueprint_GetSizeY()
    if W ~= 2048 or H ~= 512 then log("unexpected logo size " .. W .. "x" .. H); return nil end
    local rt = krl():CreateRenderTarget2D(ctxObj, W, H, 2, { R = 0, G = 0, B = 0, A = 0 }, false, false)
    local canvas, size, ctx = {}, {}, {}
    krl():BeginDrawCanvasToRenderTarget(ctxObj, rt, canvas, size, ctx)
    canvas.Canvas:K2_DrawTexture(logoTex, { X = 0, Y = 0 }, { X = W, Y = H }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
        { R = 1, G = 1, B = 1, A = 1 }, 0, 0, { X = 0.5, Y = 0.5 })
    krl():EndDrawCanvasToRenderTarget(ctxObj, ctx)
    local samples = {}
    krl():ReadRenderTarget(ctxObj, rt, samples, false)
    if #samples ~= W * H then log("logo read failed"); return nil end
    local E = LOGO_ERASE
    local rows = { string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, W % 256, W // 256, H % 256, H // 256, 32, 0x28) }
    local row = {}
    for i = 1, #samples do
        local e = samples[i]
        local c = e.get and e:get() or e
        local x, y = (i - 1) % W, (i - 1) // W
        local r, g, b, a = c.R, c.G, c.B, c.A
        if y >= E.y0 and y < E.y1 and x >= E.x0 and x < E.x1 and not (y < E.keepY1 and x >= E.keepX0 and x <= E.keepX1) then
            r, g, b, a = 0, 0, 0, 0
        end
        if y >= E.y0 and y < E.y1 then   -- wordmark overlay (BGRA, top-left origin, 18-byte header)
            local o = 18 + (y * W + x) * 4
            local wb, wg, wr, wa = wm:byte(o + 1, o + 4)
            if wa > 0 then
                local k = wa / 255
                local na = wa + a * (1 - k)
                if na > 0 then
                    r = math.floor((wr * wa + r * a * (1 - k)) / na + 0.5)
                    g = math.floor((wg * wa + g * a * (1 - k)) / na + 0.5)
                    b = math.floor((wb * wa + b * a * (1 - k)) / na + 0.5)
                end
                a = math.floor(na + 0.5)
            end
        end
        row[#row + 1] = string.char(b, g, r, a)
        if #row == W then rows[#rows + 1] = table.concat(row); row = {} end
    end
    local f = io.open(out, "wb"); if not f then return nil end
    f:write(table.concat(rows)); f:close()
    kf = io.open(out .. ".key", "w"); if kf then kf:write(key); kf:close() end
    log("built SPIDER-MAN menu logo")
    return out
end

local function applyLogo(ctxObj)
    for _, w in ipairs(FindAllOf("W_LogoWidget_C") or {}) do
        if w:IsValid() and not w:GetFullName():find("Default__") then
            local ok, img = pcall(function() return w.IMG_Logo end)
            if ok and img and img:IsValid() then
                local cur = img.Brush.ResourceObject
                local name = cur and cur:IsValid() and cur:GetFullName() or ""
                if name:find("T_UI_GameLogo", 1, true) then
                    local file = buildLogo(ctxObj, cur)
                    if file then
                        local tex = krl():ImportFileAsTexture2D(ctxObj, file)
                        if tex and tex:IsValid() then img:SetBrushFromTexture(tex, false) end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------- main menu: figure
S.menuFigs = nil   -- a reload of this file suits the menu figures again with the new code

-- the materials currently on the parts the suit paints: changes when the game swaps a material or rebuilds the figure
local function menuSignature(fig)
    local names = {}
    for _, row in pairs(C.suit) do
        if row.kind == "material" or row.kind == "texture" or row.kind == "vector" or row.kind == "scalar" then
            local c = part(fig, row.component)
            local m = c and c:GetMaterial(0)
            names[#names + 1] = row.component .. "=" .. ((m and m:IsValid()) and m:GetFullName() or "-")
        end
    end
    table.sort(names)
    return table.concat(names, ";")
end

local function menuTick(t)
    if t - (S.lastMenuCheck or 0) < 0.5 then return end
    S.lastMenuCheck = t
    local pc = FindFirstOf("PlayerController")
    if not (pc and pc:IsValid()) then return end
    local okl, errl = pcall(applyLogo, pc)
    if not okl and t - (S.lastLogoErr or 0) > 5 then S.lastLogoErr = t; log("menu logo error: " .. tostring(errl)) end
    -- the menu shows the Batman suit the save has equipped (BP_Batman_<suit>_Cutscene_C): suit any of them
    local okp, inGame = pcall(function() return pc.Pawn:IsValid() and pc.Pawn.CharacterMovement:IsValid() end)
    if okp and inGame then   -- the menu figure only exists on the title screen; the next visit builds a new one
        S.menuFigList, S.menuFigs = nil, nil
        return
    end
    -- rescan every 3 s: the figure on screen is spawned after the menu's sequence figures
    if not S.menuFigList or t - (S.lastMenuScan or 0) > 3 then
        S.lastMenuScan, S.menuFigList = t, {}
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if a:IsValid() and a:GetFullName():find("Frontend", 1, true) and not a:GetFullName():find("Default__", 1, true) then
                local n = a:GetClass():GetFName():ToString()
                if n:sub(1, #SPIDEY_HOST) == SPIDEY_HOST and n:find("_Cutscene", 1, true) then table.insert(S.menuFigList, a) end
            end
        end
    end
    for _, fig in ipairs(S.menuFigList) do
        if fig:IsValid() then
            -- The figure gets the same name on every visit to the menu, and the game can hand its parts fresh
            -- materials later: suit it again whenever the suited parts' materials are not the ones we suited.
            local name = fig:GetFullName()
            S.menuFigs = S.menuFigs or {}
            local okg, sig = pcall(menuSignature, fig)
            if not okg or S.menuFigs[name] ~= sig then
                local ok, err = pcall(suitMenuFigure, fig); if not ok then log("menu figure error: " .. tostring(err)) end
                local oks, after = pcall(menuSignature, fig)
                S.menuFigs[name] = oks and after or true
            end
            pcall(enforceSuit, fig)
        end
    end
end

-- the hit actor of a trace result (the FHitResult's component -> its owner), or nil
local function hitActor(hit)
    local ok, a = pcall(function()
        local c = hit.Component
        if c and c.Get then c = c:Get() end
        if c and c:IsValid() then return c:GetOwner() end
    end)
    if ok and a and a:IsValid() then return a end
end

local function trace(pawn, from, to)
    local hit = {}
    local ok = ksl():LineTraceSingle(pawn, from, to, 0, false, {}, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
    if ok and hit.bBlockingHit then return copy(hit.ImpactPoint), hitActor(hit) end
end

---------------------------------------------------------------- web line visual
-- one line per use ("rope" for swing/launch, "shot" for web shots), so a shot can fly while swinging
local function webLineActor(pawn, slot)
    S.webLines = S.webLines or {}
    local have = S.webLines[slot]
    if have and have:IsValid() then return have end
    local world = pawn:GetWorld()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local mesh = StaticFindObject("/Engine/BasicShapes/Cylinder.Cylinder")
    if not (gs and gs:IsValid() and cls and cls:IsValid() and mesh and mesh:IsValid()) then return nil end
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = pawn:K2_GetActorLocation(), Scale3D = V(0.02, 0.02, 0.02) }
    local a = gs:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil, 0)
    if not (a and a:IsValid()) then return nil end
    a = gs:FinishSpawningActor(a, xf, 0)
    local smc = a.StaticMeshComponent
    smc:SetMobility(2)
    smc:SetStaticMesh(mesh)
    smc:SetCollisionEnabled(0)
    smc:SetCastShadow(false)
    -- White LEGO plastic so webs read clearly at night (the engine's basic-shape material stayed dark grey and has
    -- no color to set): a dynamic copy of the minifig's own material (sheet: web_material) with a plain white print
    -- (web_texture), a flat normal map and plain plastic shine, the same parameters the suit uses.
    local ab = slot == "shot" and A.web_shot or A.web_swing
    local okm, errm = pcall(function()
        local base = StaticFindObject(ab.web_material)
        if not (base and base:IsValid()) then return end
        local mid = smc:CreateDynamicMaterialInstance(0, base, FName("None"))
        local white = krl():ImportFileAsTexture2D(pawn, MOD_DIR .. "\\" .. ab.web_texture:gsub("/", "\\"))
        if white and white:IsValid() then
            mid:SetTextureParameterValue(FName("BC"), white)
            mid:SetTextureParameterValue(FName("BC_Pristine"), white)
        end
        local flat = StaticFindObject("/Game/Characters/Textures/Shared/T_Dummy_NML.T_Dummy_NML")
        if flat and flat:IsValid() then mid:SetTextureParameterValue(FName("DNRM"), flat) end
        local shine = krl():ImportFileAsTexture2D(pawn, MOD_DIR .. "\\assets\\web_mmr.png")
        if shine and shine:IsValid() then mid:SetTextureParameterValue(FName("MMR"), shine) end
        S.webTextures = S.webTextures or {}
        S.webTextures[slot] = { white, shine }   -- keep references while the web exists
    end)
    if not okm then log("web material error: " .. tostring(errm)) end
    S.webLines[slot] = a
    return a
end
-- lines spawned by an earlier build are still grey: spawn fresh ones
for _, a in pairs(S.webLines or {}) do pcall(function() if a:IsValid() then a:K2_DestroyActor() end end) end
S.webLines = {}

-- the web leaves from the hand the pose raises (a mesh socket), falling back to above the head
local function webStart(pawn, hand)
    if hand then
        local ok, h = pcall(function() return pawn.Mesh:GetSocketLocation(FName(hand)) end)
        if ok and h then return copy(h) end
    end
    local from = pawn:K2_GetActorLocation(); from.Z = from.Z + 60
    return from
end

-- a straight piece of web from one point to another, width in cm (the cylinder is 100 cm across and 100 cm tall)
local function webSegment(pawn, slot, from, to, width)
    local a = webLineActor(pawn, slot)
    if not a then return end
    local d = sub(to, from)
    local l = len(d)
    local mid = add(from, mul(d, 0.5))
    -- point the cylinder's Z along the web
    local dir = norm(d)
    local pitch = math.deg(math.asin(math.max(-1, math.min(1, dir.Z)))) - 90
    local yaw = math.deg(math.atan(dir.Y, dir.X))
    a:SetActorHiddenInGame(false)
    a:K2_SetActorLocationAndRotation(mid, { Pitch = pitch, Yaw = yaw, Roll = 0 }, false, {}, true)
    a:SetActorScale3D(V(width / 100, width / 100, math.max(l, 1) / 100))
end

-- the swing/launch rope: from the hand to the anchor
local function showWeb(pawn, anchor, hand)
    webSegment(pawn, "rope", webStart(pawn, hand), anchor, 3.5)
end

local function hideWeb(slot)
    local a = S.webLines and S.webLines[slot or "rope"]
    if a and a:IsValid() then a:SetActorHiddenInGame(true) end
end
-- the single line of earlier builds: hide it for good after a reload
if S.webLine and S.webLine:IsValid() then S.webLine:SetActorHiddenInGame(true) end
S.webLine = nil

---------------------------------------------------------------- swing pose
-- The game's own grapple-pull animation (one arm up the line) on the FullBody montage slot, plus a lean of the
-- whole mesh toward the anchor so the minifig hangs from the web instead of tumbling.
local function startPose(pawn, ab, loops)
    if not ab.pose_anim then return end
    S.poseSeqs = S.poseSeqs or {}
    local seq = S.poseSeqs[ab.pose_anim]
    if not (seq and seq:IsValid()) then seq = StaticFindObject(ab.pose_anim); S.poseSeqs[ab.pose_anim] = seq end
    local ai = pawn.Mesh:GetAnimInstance()
    if not (seq and seq:IsValid() and ai and ai:IsValid()) then return end
    ai:PlaySlotAnimationAsDynamicMontage(seq, FName(ab.pose_slot), 0.12, 0.25, 1.0, loops, -1.0, 0.0)
    S.poseSlot = ab.pose_slot
end

-- One frame of an animation, held still (the right-side swing pose: LEGO Batman has no right-arm grapple pose,
-- but its small-boost grapple raises both arms partway through; that moment is frozen and the web leaves the
-- right hand). Mirroring the left-arm pose instead turned the minifig inside out (see-through, 2026-10-10).
local function holdPose(pawn, animPath, slot, at)
    S.poseSeqs = S.poseSeqs or {}
    local seq = S.poseSeqs[animPath]
    if not (seq and seq:IsValid()) then seq = StaticFindObject(animPath); S.poseSeqs[animPath] = seq end
    local ai = pawn.Mesh:GetAnimInstance()
    if not (seq and seq:IsValid() and ai and ai:IsValid()) then return end
    local m = ai:PlaySlotAnimationAsDynamicMontage(seq, FName(slot), 0.12, 0.25, 1.0, 1, -1.0, at)
    if m and m:IsValid() then ai:Montage_SetPlayRate(m, 0.0) end
    S.poseSlot = slot
end

local function stopPose(pawn)
    if not S.poseSlot then return end
    local ai = pawn.Mesh:GetAnimInstance()
    if ai and ai:IsValid() then ai:StopSlotAnimation(0.25, FName(S.poseSlot)) end
    S.poseSlot = nil
end

local function tiltBody(pawn, anchor, maxDeg)
    local mesh = pawn.Mesh
    if not S.meshRel then
        local r = mesh.RelativeRotation
        S.meshRel = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
    end
    local dir = norm(sub(anchor, mesh:K2_GetComponentLocation()))
    local maxR = math.rad(maxDeg)
    if math.acos(math.max(-1, math.min(1, dir.Z))) > maxR then
        local h = norm(V(dir.X, dir.Y, 0))
        dir = V(h.X * math.sin(maxR), h.Y * math.sin(maxR), math.cos(maxR))
    end
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local hang = kml:MakeRotFromZX(dir, pawn:GetActorForwardVector())
    mesh:K2_SetWorldRotation(kml:ComposeRotators(S.meshRel, hang), false, {}, true)
end

local function untiltBody(pawn)
    if not S.meshRel then return end
    pcall(function() pawn.Mesh:K2_SetRelativeRotation(S.meshRel, false, {}, true) end)
    S.meshRel = nil
end

-- true when the anchor is to the player's right
local function anchorOnRight(pawn, anchor)
    local me = pawn:K2_GetActorLocation()
    return dot(sub(anchor, me), pawn:GetActorRightVector()) > 0
end

---------------------------------------------------------------- state
local function findAnchor(pc, pawn, ab)
    local camRot = pc.PlayerCameraManager:GetCameraRotation()
    local me = pawn:K2_GetActorLocation()
    local from = add(me, V(0, 0, 100))
    local look = fwd({ Pitch = 0, Yaw = camRot.Yaw })
    local best, bestScore = nil, -1e9
    -- webs only stick to real geometry in front of or beside the player (never behind, like the Spider-Man
    -- games); among those the nearest building/structure above wins, with a preference for what is ahead
    local minAhead = math.cos(math.rad(ab.max_anchor_angle_deg))
    for _, pitchUp in ipairs({ 25, 40, 55, 70 }) do
        for yawOff = -90, 90, 15 do
            local dir = fwd({ Pitch = pitchUp, Yaw = camRot.Yaw + yawOff })
            local hit = trace(pawn, from, add(from, mul(dir, ab.range_cm)))
            local flat = hit and V(hit.X - me.X, hit.Y - me.Y, 0)
            local ahead = flat and len(flat) > 1 and dot(norm(flat), look) or -1
            if hit and hit.Z > me.Z + ab.min_anchor_height_cm and ahead >= minAhead then
                local d = len(sub(hit, me))
                local score = -d / 1000 + 1.2 * ahead
                if score > bestScore then best, bestScore = hit, score end
            end
        end
    end
    return best
end
local function startSwing(pc, pawn, cm)
    local ab = A.web_swing
    local anchor = findAnchor(pc, pawn, ab)
    if not anchor then
        if now() - (S.lastNoAnchorLog or 0) > 2 then S.lastNoAnchorLog = now(); log("swing: nothing to attach to in range") end
        return false
    end
    log(string.format("swing: anchored %.0f cm away, %.0f cm up", len(sub(anchor, pawn:K2_GetActorLocation())), anchor.Z - pawn:K2_GetActorLocation().Z))
    S.swinging, S.anchor = true, anchor
    -- rope length in the swing plane (view direction and up), matching swingTick
    local f0 = fwd({ Pitch = 0, Yaw = pc.PlayerCameraManager:GetCameraRotation().Yaw })
    local r0 = V(-f0.Y, f0.X, 0)
    local d0 = sub(pawn:K2_GetActorLocation(), anchor)
    S.rope = len(sub(d0, mul(r0, dot(d0, r0))))
    S.swingStart = now()
    cm.GravityScale = ab.gravity_scale
    -- Spider-Man style pump: throw momentum forward along the view so the arc carries
    local look = fwd({ Pitch = 0, Yaw = pc.PlayerCameraManager:GetCameraRotation().Yaw })
    local v0 = cm.Velocity
    cm.Velocity = V(v0.X + look.X * ab.attach_pump_cms, v0.Y + look.Y * ab.attach_pump_cms, math.max(v0.Z, -200))
    local right = anchorOnRight(pawn, anchor)
    S.swingHand = right and ab.web_hand_right or ab.web_hand
    log("swing: web from the " .. (right and "right" or "left") .. " hand")
    -- both sides hang from the web like the Spider-Man games: one held frame of LEGO's rope-hang animation, reaching
    -- up with the hand on the anchor's side (player's choice, 2026-10-10)
    local anim, at = ab.pose_anim, ab.pose_hold_s
    if right then anim, at = ab.pose_anim_right, ab.pose_hold_s_right end
    local okp, errp = pcall(holdPose, pawn, anim, ab.pose_slot, at)
    if not okp then log("swing pose error: " .. tostring(errp)) end
    cue(ab.cue_on_start)
    cue("vo_swing")
    return true
end

local function endSwing(pawn, cm, fling)
    local ab = A.web_swing
    S.swinging, S.anchor = false, nil
    S.lastSwingEnd = now()
    cm.GravityScale = S.baseGravity or 1.0
    hideWeb()
    pcall(stopPose, pawn)
    untiltBody(pawn)
    if fling then
        local v = cm.Velocity
        local h = norm(V(v.X, v.Y, 0))
        pawn:LaunchCharacter(V(v.X + h.X * ab.release_boost_cms, v.Y + h.Y * ab.release_boost_cms, math.max(v.Z, 0) + ab.release_up_cms), true, true)
        cue(ab.cue_on_end)
    end
end

local function swingTick(pc, pawn, cm, dt)
    local ab = A.web_swing
    local p = pawn:K2_GetActorLocation()
    local v = copy(cm.Velocity)
    local d = sub(p, S.anchor)
    local dist = len(d)
    local camF = fwd({ Pitch = 0, Yaw = pc.PlayerCameraManager:GetCameraRotation().Yaw })
    local camR = V(-camF.Y, camF.X, 0)
    -- keep the swing going straight (player, 2026-10-10): an anchor off to the side must not drag Spidey sideways.
    -- The rope works only in the plane of the view direction and up: its sideways part is dropped, and sideways
    -- speed is bled off below.
    local flatD = sub(d, mul(camR, dot(d, camR)))
    local dir = mul(flatD, 1 / math.max(len(flatD), 1))
    dist = len(flatD)
    -- reel in a little so swings carry forward instead of dragging
    S.rope = math.max(400, S.rope - S.rope * ab.rope_pull * dt * 0.5)
    if dist > S.rope then
        local radial = dot(v, dir)
        if radial > 0 then v = sub(v, mul(dir, radial)) end
        v = sub(v, mul(dir, math.min((dist - S.rope) / math.max(dt, 0.008) * 0.35, 1500)))
    end
    -- Spider-Man style forward drive along the view direction, so each swing carries you on instead of back
    v = add(v, mul(camF, ab.forward_drive_cms2 * dt))
    local side = dot(v, camR)
    v = sub(v, mul(camR, side * math.min(1, ab.lateral_damping * dt)))
    -- no automatic release: the player holds this web until Q is let go (player's choice, 2026-10-10)
    local sp = len(v)
    if sp > ab.max_speed_cms then v = mul(v, ab.max_speed_cms / sp) end
    cm.Velocity = v
    if sp > 3000 then cue("vo_big_swing") end
    pcall(tiltBody, pawn, S.anchor, ab.max_body_tilt_deg)
    showWeb(pawn, S.anchor, S.swingHand or ab.web_hand)
end

-- Web launch (R / R1): from standing, a web shot straight up pulls Spidey into the
-- air to jump_height_multiplier times a normal jump (same gravity, so the launch speed is the jump speed times the
-- square root of that), high enough to start a swing from the ground. Only on the ground.
local function webLaunch(pc, pawn, cm)
    local ab = A.web_launch
    if cm:IsFalling() or S.swinging then return end
    local me = pawn:K2_GetActorLocation()
    local up = trace(pawn, add(me, V(0, 0, 100)), add(me, V(0, 0, ab.range_cm)))
    local anchor = up or add(me, V(0, 0, 1500))
    local speed = cm.JumpZVelocity * math.sqrt(ab.jump_height_multiplier)
    pawn:LaunchCharacter(V(0, 0, speed), false, true)
    S.launchAnchor, S.launchUntil = anchor, now() + 0.35
    pcall(startPose, pawn, ab, 1)
    cue(ab.cue_on_start)
    cue(ab.cue_on_end)
    log(string.format("web launch: %.0f cm/s up (jump %.0f)", speed, cm.JumpZVelocity))
end

---------------------------------------------------------------- web shot (RMB)
-- Like the Spider-Man games: a web shot snaps to the enemy nearest the aim (within a cone, in sight), flies out
-- from the hand and, on arrival, hits through LEGO Batman's own combat effects (sheet: abilities.web_shot
-- hit_effects: a batarang-style hit reaction plus projectile damage). With no enemy it splats on what you aim at.
local function healthSet(ch)
    local r
    pcall(function()
        ch.AbilitySystemComponent.SpawnedAttributes:ForEach(function(_, e)
            local s = e:get()
            if s:GetClass():GetFName():ToString() == "HealthAttributeSet" then r = s end
        end)
    end)
    return r
end

local function aliveEnemy(ch)
    if not (ch and ch:IsValid()) then return false end
    local h = healthSet(ch)
    return h ~= nil and h.Health.CurrentValue > 0
end

-- Breakables (bins, boxes, phone booths...) carry a TtSmashableObjectComponent. A web shot hits the nearest one
-- around its impact point like a batarang does: a "Hit" trigger with the shot's damage, so multi-hit objects take
-- several shots.
local TRIGGER_HIT = 1   -- ETriggerSource::Hit

-- Whether an object accepts this kind of hit is left to the game itself (Bp_TriggerSmashable with a Hit source;
-- objects that refuse it play their own "hit fail"). Reading AllowedTriggerSources (an enum array) from Lua is
-- avoided: it was the prime suspect for a crash (2026-10-10).
local function acceptsHits(sc) return true end

-- Web shots go where Spider-Man faces, not where the camera looks (facing the camera, they flew off behind him;
-- player, 2026-10-10): the aim line starts at his chest and runs along his facing, level with the ground.
local function shotTarget(pc, pawn, ab)
    local me = pawn:K2_GetActorLocation()
    local f = pawn:GetActorForwardVector()
    local look = norm(V(f.X, f.Y, 0))
    local origin = add(me, V(0, 0, 30))
    local hand = webStart(pawn, ab.web_hand)
    local minDot = math.cos(math.rad(ab.aim_cone_deg))
    local best, bestScore = nil, -1e9
    for _, ch in ipairs(FindAllOf("DinnerEnemyCharacter") or {}) do
        if ch:IsValid() and ch:GetFullName():find("PersistentLevel", 1, true) then
            local p = ch:K2_GetActorLocation()
            local dist = len(sub(p, me))
            if dist < ab.range_cm then
                local toE = sub(p, me)
                local a = dot(norm(V(toE.X, toE.Y, 0)), look)
                if a >= minDot then
                    local score = a * 4 - dist / ab.range_cm
                    if score > bestScore and aliveEnemy(ch) then
                        local block = trace(pawn, hand, p)   -- in sight: nothing solid well before the enemy
                        if not block or len(sub(block, hand)) > len(sub(p, hand)) - 120 then best, bestScore = ch, score end
                    end
                end
            end
        end
    end
    if best then return best, best:K2_GetActorLocation() end
    local hit, actor = trace(pawn, origin, add(origin, mul(look, ab.range_cm)))
    local point = hit or add(origin, mul(look, ab.range_cm))
    -- breakables do not block this trace (the web passed through a phone booth into the wall behind it): take the
    -- unbroken breakable closest to the aim line, in front of whatever the line hit
    local reach = len(sub(point, origin)) + 60
    local smash, smashD = nil, ab.smash_radius_cm
    for _, sc in ipairs(FindAllOf("TtSmashableObjectComponent") or {}) do
        if sc:IsValid() and not sc:GetFullName():find("Default__", 1, true) then
            local o = sc:GetOwner()
            if o and o:IsValid() then
                local c = add(o:K2_GetActorLocation(), V(0, 0, 60))
                -- distance to the aim line measured flat, so objects on the ground ahead still count
                local rel = sub(c, origin)
                local along = dot(rel, look)
                if along > 0 and along < reach and len(sub(c, me)) < ab.range_cm then
                    local side = sub(rel, mul(look, along))
                    local off = len(V(side.X, side.Y, 0))
                    if off < smashD and not sc:IsSmashableComplete() and acceptsHits(sc) then smash, smashD = sc, off end
                end
            end
        end
    end
    if smash then return nil, add(smash:GetOwner():K2_GetActorLocation(), V(0, 0, 60)), true, smash:GetOwner() end
    return nil, point, hit ~= nil, actor
end

local function smashAt(pawn, point, actor)
    local ab = A.web_shot
    local best, bestD = nil, ab.smash_radius_cm
    -- the object the web actually hit, when it is a breakable
    if actor and actor:IsValid() then
        local cls = StaticFindObject("/Script/TtSmashables.TtSmashableObjectComponent")
        for _, e in ipairs(actor:K2_GetComponentsByClass(cls) or {}) do
            local sc = e; local ok, inner = pcall(function() return e:get() end); if ok and inner then sc = inner end
            if sc:IsValid() and not sc:IsSmashableComplete() and acceptsHits(sc) then best = sc end
        end
    end
    -- otherwise the nearest breakable around the impact point
    if not best then for _, sc in ipairs(FindAllOf("TtSmashableObjectComponent") or {}) do
        if sc:IsValid() and not sc:GetFullName():find("Default__", 1, true) then
            local o = sc:GetOwner()
            if o and o:IsValid() then
                local d = len(sub(o:K2_GetActorLocation(), point))
                if d < bestD and not sc:IsSmashableComplete() and acceptsHits(sc) then best, bestD = sc, d end
            end
        end
    end end
    if not best then return false end
    local n = norm(sub(webStart(pawn, ab.web_hand), point))
    best:Bp_TriggerSmashable(n, ab.smash_damage, false, pawn, TRIGGER_HIT)
    log("web shot hit breakable " .. best:GetOwner():GetClass():GetFName():ToString())
    return true
end

local function landShot(pawn, shot)
    local ab = A.web_shot
    if shot.enemy and aliveEnemy(shot.enemy) then
        local src = pawn.AbilitySystemComponent
        for _, path in ipairs(ab.hit_effects) do
            S.hitEffects = S.hitEffects or {}
            local cls = S.hitEffects[path]
            if not (cls and cls:IsValid()) then cls = StaticFindObject(path); S.hitEffects[path] = cls end
            if cls and cls:IsValid() then
                pcall(function() src:BP_ApplyGameplayEffectToTarget(cls, shot.enemy.AbilitySystemComponent, 1.0, src:MakeEffectContext()) end)
            else log("missing hit effect " .. path) end
        end
        local h = healthSet(shot.enemy)
        log(string.format("web shot hit %s (health %.0f)", shot.enemy:GetFName():ToString(), h and h.Health.CurrentValue or -1))
        cue(ab.cue_on_end)
    elseif shot.solid then
        local oks, errs = pcall(smashAt, pawn, shot.point, shot.actor)
        if not oks then log("web shot smash error: " .. tostring(errs)) end
        cue("sfx_web_splat")
    end
end

local function fireShot(pc, pawn)
    local ab = A.web_shot
    if S.shot and not S.shot.landed then landShot(pawn, S.shot) end   -- a quick second shot lands the first
    local enemy, point, solid, actor = shotTarget(pc, pawn, ab)
    local from = webStart(pawn, ab.web_hand)
    S.shot = { enemy = enemy, point = point, solid = solid, actor = actor, from = from, start = now(), flight = math.max(0.05, len(sub(point, from)) / ab.web_speed_cms) }
    -- the arm thrust plays on the upper body, so running and swinging carry on underneath
    if not S.swinging then pcall(function()
        S.poseSeqs = S.poseSeqs or {}
        local seq = S.poseSeqs[ab.pose_anim]
        if not (seq and seq:IsValid()) then seq = StaticFindObject(ab.pose_anim); S.poseSeqs[ab.pose_anim] = seq end
        pawn.Mesh:GetAnimInstance():PlaySlotAnimationAsDynamicMontage(seq, FName(ab.pose_slot), 0.05, 0.2, 1.0, 1, -1.0, 0.0)
    end) end
    cue(ab.cue_on_start)
end

-- the shot is a short bolt of web (like Spider-Man Remastered's web shots, not a line back to the hand) that flies
-- from where it left the hand to the target and vanishes on impact
local function shotTick(pawn)
    local s = S.shot
    if not s then return end
    local ab = A.web_shot
    if s.enemy and s.enemy:IsValid() then s.point = s.enemy:K2_GetActorLocation() end   -- homes in on a moving enemy
    local k = (now() - s.start) / s.flight
    if k >= 1 then
        if not s.landed then s.landed = true; landShot(pawn, s) end
        hideWeb("shot"); S.shot = nil
        return
    end
    local path = sub(s.point, s.from)
    local total = len(path)
    local dir = mul(path, 1 / math.max(total, 1))
    local head = add(s.from, mul(dir, total * k))
    local tail = add(s.from, mul(dir, math.max(0, total * k - ab.bolt_length_cm)))
    webSegment(pawn, "shot", tail, head, ab.bolt_width_cm)
end

---------------------------------------------------------------- camera: no aim zoom on RMB
-- RMB also fires LEGO Batman's "get gadget out" event, and while that is up the camera uses an aim mode
-- (BP_CM_Aim_*: arm 360 cm, FOV 65, against the follow camera's 600 cm / 75), which reads as a zoom. Spidey has no
-- aim camera: the aim modes in use get the follow camera's arm length and FOV (read live from the game's own
-- default mode) while Spidey is on, and their own values back on F6. Pushing the default mode instead swung the
-- camera around (player's clip, 2026-10-10).
local function cameraComponent(pawn)
    if S.camPawn == pawn:GetFullName() and S.camComp and S.camComp:IsValid() then return S.camComp end
    S.camPawn, S.camComp = pawn:GetFullName(), nil
    for _, e in ipairs(pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent")) or {}) do
        local c = e; local ok, inner = pcall(function() return e:get() end); if ok and inner then c = inner end
        if c:GetClass():GetFName():ToString() == "TtCameraComponent" then S.camComp = c end
    end
    return S.camComp
end

S.aimModes = S.aimModes or {}   -- aim mode object -> its own { arm, fov }, for F6
local AIM_MODE_CLASSES = { "BP_CM_Aim_C", "BP_CM_Aim_Pistols_C" }   -- seen on RMB (2026-10-10)

local function flattenAim(m)
    local key = m:GetFullName()
    if not S.aimModes[key] then
        S.aimModes[key] = { obj = m, arm = m.ArmLength, fov = m.FieldOfView }
        log(string.format("aim camera %s: arm %.0f fov %.0f -> follow camera's %.0f / %.0f",
            m:GetClass():GetFName():ToString(), m.ArmLength, m.FieldOfView, S.followArm, S.followFov))
    end
    if m.ArmLength ~= S.followArm then m.ArmLength = S.followArm end
    if m.FieldOfView ~= S.followFov then m.FieldOfView = S.followFov end
end

local function noAimCamera(pawn)
    local camc = cameraComponent(pawn)
    if not camc then return end
    local m = camc:GetCurrentCameraMode()
    if not (m and m:IsValid()) then return end
    local n = m:GetClass():GetFName():ToString()
    if n:find("_Default", 1, true) then S.followArm, S.followFov = m.ArmLength, m.FieldOfView end
    -- the game keeps its camera modes in a pool: set the idle aim modes too, so even the first RMB does not zoom
    if S.followArm and now() - (S.lastAimSweep or 0) > 1.0 then
        S.lastAimSweep = now()
        for _, cls in ipairs(AIM_MODE_CLASSES) do
            for _, o in ipairs(FindAllOf(cls) or {}) do
                if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then flattenAim(o) end
            end
        end
    end
    if not n:find("_Aim", 1, true) then return end
    if S.followArm then flattenAim(m) end
end

local function restoreAimCameras()
    for key, a in pairs(S.aimModes or {}) do
        pcall(function() if a.obj:IsValid() then a.obj.ArmLength = a.arm; a.obj.FieldOfView = a.fov end end)
        S.aimModes[key] = nil
    end
end

---------------------------------------------------------------- base suit: Spidey always goes on the original suit
-- Whatever Batman suit the player wears, Spidey goes onto the original one (sheet: suit.base_suit), so every
-- property matches (Zur-En-Arrh's collar lifted the head through a bone offset the mod cannot reach). The game's own
-- costume system switches suits (TtPartyMember:RequestIdentity, the call its suit menu uses); the chosen suit is
-- remembered (also on disk, in case the game closes while Spidey is on) and put back on F6.
local IDENTITY_FILE = HOME .. "suit_before_spidey.txt"
if S.savedSuit == nil then
    local f = io.open(IDENTITY_FILE, "r")
    if f then S.savedSuit = f:read("a"); f:close() end
end

local function baseSuitTag()
    for _, row in pairs(C.suit) do if row.kind == "identity" then return row.value end end
end

local function partyMember(pc)
    local statics = StaticFindObject("/Script/TtPartySystem.Default__TtPartyStatics")
    local m = statics:GetPartyMemberForController(pc, {})
    if m and m:IsValid() then return m end
end

local function currentSuit(pc)
    local m = partyMember(pc)
    return m and m:GetCurrentIdentity().TagName:ToString()
end

local function requestSuit(pc, tag)
    local m = partyMember(pc)
    if not m then return false end
    -- instant handover: no LEGO brick-rebuild costume effect, Spidey appears at once (player, 2026-10-10)
    local ok = m:RequestIdentity({ TagName = FName(tag) }, { bInstantHandover = true })
    log("suit change to " .. tag .. (ok and "" or " refused"))
    return ok
end

local function rememberSuit(tag)
    S.savedSuit = tag
    local f = io.open(IDENTITY_FILE, "w"); if f then f:write(tag or ""); f:close() end
end

local function setPowers(on, pawn)
    S.powers = on
    if on then
        -- another Batman suit: change to the original first; the frame loop suits the new pawn once it arrives
        local base = baseSuitTag()
        local pc = localPlayer()
        local okc, cur = pcall(currentSuit, pc)
        if base and okc and cur and cur ~= base then
            local okr, done = pcall(requestSuit, pc, base)
            if okr and done then
                rememberSuit(cur)
                S.swapFrom, S.swapUntil = pawn:GetFullName(), now() + 3
            end
        end
        local ok, err = true, nil
        if not S.swapFrom then ok, err = pcall(suitUp, pawn) end
        if not ok then log("suit error: " .. tostring(err)) end
        ok, err = pcall(applyBlockEffects, pawn, true); if not ok then log("block effect error: " .. tostring(err)) end
        S.blockPawnName = pawn:GetFullName()
        S.portraitTex = nil   -- import the saved portrait fresh (see suitTexture for why imports are never reused)
        cue(A.toggle_powers.cue_on_start)
        log("powers ON")
    else
        restoreAimCameras()
        if S.shot then hideWeb("shot"); S.shot = nil end
        if S.launchAnchor then hideWeb(); S.launchAnchor = nil end
        pcall(applyBlockEffects, pawn, false)
        S.portraitDue = nil
        local okp, errp = pcall(setPortrait, false, pawn); if not okp then log("portrait restore error: " .. tostring(errp)) end
        -- Straight back into the suit the player had on before Spidey: the suited pawn is replaced by the game, so
        -- the suit is not taken off first (that showed the base suit for a moment). Only when there is no suit to
        -- go back to, or the game refuses the switch, is the suit taken off this pawn.
        local swapped = false
        if S.savedSuit and S.savedSuit ~= "" then
            local okr, res = pcall(requestSuit, localPlayer(), S.savedSuit)
            if not okr then log("suit change error: " .. tostring(res)) end
            swapped = okr and res
        end
        if swapped then
            S.suitUndo, S.suitPawn, S.suitPawnName, S.textures, S.rowMids = nil, nil, nil, {}, nil
            log("back to Batman")
        else
            local okd, errd = pcall(suitDown); if not okd then log("suit restore error: " .. tostring(errd)) end
        end
        rememberSuit(nil)
        S.swapFrom = nil
        cue(A.toggle_powers.cue_on_end)
        log("powers OFF")
    end
end

---------------------------------------------------------------- frame
local function frame()
    local t = now()
    local dt = math.min(t - (S.lastT or t), 0.1); S.lastT = t
    local pc, pawn = localPlayer()
    menuTick(t)   -- main menu figure and logo (no player pawn there)
    if not pawn then S.swinging = false; return end
    local cm = pawn.CharacterMovement
    if not (cm and cm:IsValid()) then return end
    ensureLink()
    if not S.baseGravity or not S.swinging then S.baseGravity = cm.GravityScale end

    -- toggle (edge-triggered); only Batman can become Spidey
    local host = isHost(pawn)
    local tog = inputDown(pc, "toggle")
    if tog and not S.prevToggle and host and t - S.lastToggle > A.toggle_powers.cooldown_s then
        S.lastToggle = t
        if S.swinging then endSwing(pawn, cm, false) end
        setPowers(not S.powers, pawn)
    end
    S.prevToggle = tog
    if not S.powers then
        -- the game closed while Spidey was on: put the player's own suit back once, on the first Batman frame
        if host and S.savedSuit and S.savedSuit ~= "" and not S.suitRestoreTried then
            S.suitRestoreTried = true
            local okr, errr = pcall(requestSuit, pc, S.savedSuit)
            if not okr then log("suit change error: " .. tostring(errr)) end
            rememberSuit(nil)
        end
        return
    end
    -- waiting for the original suit to arrive: do not suit the old pawn in the meantime
    if S.swapFrom then
        if pawn:GetFullName() == S.swapFrom and now() < S.swapUntil then return end
        S.swapFrom, S.swapArrived = nil, pawn:GetFullName()
    end

    -- Playing another character (the game's character switch): nothing Spidey happens on them. Batman, now run by
    -- the game, stays suited, and his record of his own look is kept, so F6 later restores the real Batman.
    if not host then
        if S.onOther ~= pawn:GetFullName() then
            S.onOther = pawn:GetFullName()
            log("playing " .. pawn:GetClass():GetFName():ToString() .. ": Spidey stays with Batman")
        end
        S.swinging, S.anchor, S.shot, S.launchAnchor = false, nil, nil, nil
        hideWeb(); hideWeb("shot")
        return
    end
    S.onOther = nil


    -- a new Batman pawn (respawn, level change) gets the suit too
    -- compare by name: a fresh Lua wrapper for the same pawn must not count as a new pawn
    if S.blockPawnName ~= pawn:GetFullName() then
        S.blockPawnName = pawn:GetFullName()
        S.blockEffects = {} -- effects lived on the old pawn
        pcall(applyBlockEffects, pawn, true)
    end
    if S.suitPawnName ~= pawn:GetFullName() then
        -- an old Batman still in the world gets his own look back first; one that is gone takes its record with it
        if S.suitPawn and S.suitPawn:IsValid() then pcall(suitDown) end
        S.suitUndo = nil
        -- the base suit our F6 switch asked for: suit it on its first frame, and keep it hidden until then
        local fromSwap = S.swapArrived == pawn:GetFullName()
        local ok, err = pcall(suitUp, pawn, fromSwap); if not ok then log("suit error: " .. tostring(err)) end
        if fromSwap then pcall(function() pawn:SetActorHiddenInGame(S.suitPawnName ~= pawn:GetFullName()) end) end
    end
    if S.swapArrived == pawn:GetFullName() and S.suitPawnName == pawn:GetFullName() then
        pcall(function() pawn:SetActorHiddenInGame(false) end)
        S.swapArrived = nil
        -- the game rebuilds the HUD portrait for the new pawn with the base suit's picture: re-check it every frame
        -- for a moment instead of once a second, so Batman 2025 never shows there
        S.portraitFastUntil = t + 2.0
    end
    if S.suitPawnName == pawn:GetFullName() then pcall(enforceSuit, pawn) end
    local okb, errb = pcall(cancelBlocked, pawn)
    if not okb and t - (S.lastBlockErr or 0) > 5 then S.lastBlockErr = t; log("ability block error: " .. tostring(errb)) end
    local okc, errc = pcall(noAimCamera, pawn)
    if not okc and t - (S.lastCamErr or 0) > 5 then S.lastCamErr = t; log("camera error: " .. tostring(errc)) end

    -- HUD portrait: set on the suit-up frame itself (suitUp and enforceSuit have already run this frame), then kept
    -- on once a second, since the HUD rebuilds its widgets (menus, cutscenes)
    S.portraitDue = S.portraitDue or t
    local v = cm.Velocity
    if cm:IsFalling() or S.swinging or v.X * v.X + v.Y * v.Y + v.Z * v.Z > 25 then S.stillSince = t end
    -- the plain standing pose: stopping/landing has settled (0.5 s) but idle animations have not begun (2 s)
    local still = t - (S.stillSince or t)
    S.portraitStill = still >= 0.5 and still <= 2.0
    if S.portraitShot == nil then S.portraitShot = portraitCurrent() end
    -- launch splash: built once from the plain standing pose (like the portrait), when it is missing or outdated
    if S.splashOk == nil then local okc, cur = pcall(splashCurrent); S.splashOk = okc and cur end
    if not S.splashOk and S.portraitStill and not S.splashTried and S.suitPawnName == pawn:GetFullName() then
        S.splashTried = true
        local oks, res = pcall(buildSplash, pawn)
        if not oks then log("splash error: " .. tostring(res)) end
        S.splashOk = oks and res
    end
    if t >= S.portraitDue or t < (S.portraitFastUntil or 0) or (not S.portraitShot and S.portraitStill) then
        S.portraitDue = t + 1.0
        local okp, errp = pcall(setPortrait, true, pawn)
        if not okp and t - (S.lastPortraitErr or 0) > 5 then S.lastPortraitErr = t; log("portrait error: " .. tostring(errp)) end
    end

    local falling = cm:IsFalling()
    local vz = cm.Velocity.Z
    if falling then S.maxFall = math.max(S.maxFall, -vz) end

    -- swing: one web per press. Holding Q stays on that web (no automatic re-attach); let go to release, press
    -- again for the next anchor. On the ground a fresh press web-jumps you up and the web attaches in the air.
    local swingHeld = inputDown(pc, "swing")
    if not swingHeld then S.swingSpent = false end
    if S.swinging then
        if not swingHeld or not falling then
            endSwing(pawn, cm, swingHeld == false and falling); S.lastSwingEnd = t
            if swingHeld then S.swingSpent = true end   -- landed while holding: this press is used up
        else swingTick(pc, pawn, cm, dt); S.swingTime = S.swingTime + dt end
    elseif swingHeld and not S.swingSpent and not falling and not S.prevSwing and t - (S.lastGroundLaunch or 0) > 0.5 then
        S.lastGroundLaunch = t
        pawn:LaunchCharacter(V(0, 0, A.web_swing.ground_launch_cms), false, true)
        cue(A.web_swing.cue_on_start)
    elseif swingHeld and not S.swingSpent and falling and t - S.lastSwingEnd > A.web_swing.cooldown_s and t - (S.lastAnchorTry or 0) > 0.2 then
        S.lastAnchorTry = t
        if startSwing(pc, pawn, cm) then S.swingSpent = true end
    end
    S.prevSwing = swingHeld

    -- web shot: press RMB
    local sh = inputDown(pc, "shoot")
    if sh and not S.prevShoot and t - (S.lastShot or 0) > A.web_shot.cooldown_s then
        S.lastShot = t
        local oks, errs = pcall(fireShot, pc, pawn); if not oks then log("web shot error: " .. tostring(errs)) end
    end
    S.prevShoot = sh
    local okt, errt = pcall(shotTick, pawn)
    if not okt and t - (S.lastShotErr or 0) > 5 then S.lastShotErr = t; log("web shot error: " .. tostring(errt)) end

    -- web launch: press (on the ground)
    local l = inputDown(pc, "launch")
    if l and not S.prevLaunch and t - (S.lastLaunch or 0) > A.web_launch.cooldown_s then S.lastLaunch = t; webLaunch(pc, pawn, cm) end
    S.prevLaunch = l
    if S.launchAnchor then
        if t < S.launchUntil then showWeb(pawn, S.launchAnchor, A.web_launch.web_hand)
        else S.launchAnchor = nil; if not S.swinging then hideWeb() end end
    end

    -- landings and music
    if falling then
        S.airborne = true
        if t - S.lastMusicBeat > 1 then cue("music_traversal"); S.lastMusicBeat = t end
    elseif S.airborne then
        S.airborne = false
        if S.maxFall > 2500 then cue("vo_land_hard") elseif S.swingTime > 8 then cue("vo_rooftop_quip") end
        S.maxFall, S.swingTime = 0, 0
    end
end


return { frame = frame, labels = "toggle " .. IN.toggle.label .. ", swing " .. IN.swing.label .. ", web launch " .. IN.launch.label }