-- =============================================================================
--  CP2077 Companion · Mod de telemetría para Cyber Engine Tweaks (CET)
--  Carpeta: <Cyberpunk 2077>/bin/x64/plugins/cyber_engine_tweaks/mods/cp2077_companion/
--
--  Qué hace:
--    * Lee el estado del juego (salud, eurodólares, posición, vehículo, búsqueda,
--      misión seguida, arma equipada, hora del juego) desde onUpdate.
--    * Escucha eventos del juego (llamadas de NPCs, SMS, cambios de misión)
--      con Observe() sobre PhoneSystem y JournalNotificationQueue.
--    * Empaqueta todo en un JSON versionado (schema v1) y lo envía al servidor.
--
--  Transporte (CET no trae cliente HTTP propio):
--    1. "http": POST a http://localhost:3000/telemetry usando el plugin
--       RedHttpClient (rayshader). Requiere lanzar el juego con -no-tls.
--    2. "file": escribe telemetry.json en la carpeta de este mod; server.js lo
--       vigila y lo trata exactamente igual que un POST. Funciona sin plugins.
--    En modo "auto" se usa HTTP si RedHttpClient está instalado y responde;
--    si falla varias veces seguidas, cambia solo a "file".
-- =============================================================================

local CONFIG = {
    endpoint      = "http://localhost:3000/telemetry",
    transport     = "auto",   -- "auto" | "http" | "file"
    sendInterval  = 0.2,      -- segundos entre envíos (5 Hz)
    slowInterval  = 1.0,      -- segundos entre lecturas "lentas" (misión, búsqueda...)
    eventTTL      = 10.0,     -- segundos que un evento se reenvía (el servidor deduplica por id)
    maxEvents     = 25,
    httpFailLimit = 5,        -- fallos HTTP seguidos antes de pasar a "file"
    bridgeFile    = "telemetry.json",
}

local SCHEMA_VERSION = 1

-- Nombres bonitos para los contactos más habituales (el juego usa CNames en minúsculas).
local CONTACT_NAMES = {
    judy = "Judy Álvarez", panam = "Panam Palmer", river = "River Ward",
    kerry = "Kerry Eurodyne", jackie = "Jackie Welles", johnny = "Johnny Silverhand",
    rogue = "Rogue", viktor = "Viktor Vektor", vik = "Viktor Vektor", misty = "Misty Olszewski",
    takemura = "Goro Takemura", reed = "Solomon Reed", songbird = "Songbird",
    alex = "Alex", regina = "Regina Jones", wakako = "Wakako Okada", dakota = "Dakota Smith",
    padre = "Padre", mrhands = "Mr. Hands", mr_hands = "Mr. Hands", elcapitan = "El Capitán",
    claire = "Claire Russell", mama_welles = "Mama Welles", delamain = "Delamain",
    evelyn = "Evelyn Parker", dexter = "Dexter DeShawn", hanako = "Hanako Arasaka",
    mitch = "Mitch Anderson", saul = "Saul Bekker", meredith = "Meredith Stout",
}

-- -----------------------------------------------------------------------------
--  Estado interno
-- -----------------------------------------------------------------------------
local state = {
    ready         = false,
    sessionId     = tostring(os.time()),
    seq           = 0,
    eventSeq      = 0,
    clock         = 0.0,      -- reloj propio (suma de deltas)
    sendTimer     = 0.0,
    slowTimer     = CONFIG.slowInterval, -- fuerza lectura lenta en el primer envío
    transport     = "file",
    httpFails     = 0,
    sentOk        = 0,
    sendErrors    = 0,
    lastError     = "",
    hooks         = { phone = false, journal = false },
    overlayOpen   = false,
    events        = {},       -- { {event=..., expires=...}, ... }
    activeCall    = nil,      -- llamada en curso (se incluye en cada snapshot)
    slow          = { wanted = nil, quest = nil, weapon = nil, world = nil },
}

-- -----------------------------------------------------------------------------
--  Utilidades
-- -----------------------------------------------------------------------------
local function log(msg)
    print("[CP2077 Companion] " .. tostring(msg))
end

-- Ejecuta fn de forma segura; devuelve el resultado o nil si la API falla.
local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function round(n, decimals)
    if type(n) ~= "number" or n ~= n then return nil end
    local m = 10 ^ (decimals or 0)
    return math.floor(n * m + 0.5) / m
end

local function nameToString(cname)
    if cname == nil then return nil end
    if type(cname) == "string" then return cname ~= "" and cname or nil end
    local s = safe(function() return Game.NameToString(cname) end)
    if s == nil or s == "" or s == "None" then
        s = safe(function() return cname.value end)
    end
    if s == nil or s == "" or s == "None" then return nil end
    return s
end

local function localize(text)
    if type(text) ~= "string" or text == "" then return nil end
    if text:find("^LocKey#") then
        local loc = safe(function() return Game.GetLocalizedText(text) end)
        if loc ~= nil and loc ~= "" then return loc end
    end
    return text
end

local function enumName(typeName, value)
    if value == nil then return nil end
    local s = safe(function() return EnumValueToString(typeName, EnumInt(value)) end)
    if s ~= nil and s ~= "" then return s end
    return tostring(value)
end

local function prettyContact(id)
    if id == nil then return "Desconocido" end
    local key = id:lower()
    if CONTACT_NAMES[key] then return CONTACT_NAMES[key] end
    local pretty = key:gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end)
    return pretty
end

-- -----------------------------------------------------------------------------
--  Codificador JSON mínimo (sin dependencias). NULL representa null explícito.
-- -----------------------------------------------------------------------------
local NULL = setmetatable({}, { __tostring = function() return "null" end })

local function isArray(t)
    if next(t) == nil then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n == #t
end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encode(v)
    local t = type(v)
    if v == nil or v == NULL then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v % 1 == 0 and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.4f", v)
    end
    if t == "string" then return encodeString(v) end
    if t == "table" then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[#parts + 1] = encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        if next(v) == nil then return "{}" end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = encodeString(k) .. ":" .. encode(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

-- Los arrays vacíos se codifican como [] (no {}).
local EMPTY_ARRAY = setmetatable({}, { __jsonArray = true })
local baseEncode = encode
encode = function(v)
    if type(v) == "table" and next(v) == nil and getmetatable(v) and getmetatable(v).__jsonArray then
        return "[]"
    end
    return baseEncode(v)
end

-- -----------------------------------------------------------------------------
--  Cola de eventos (llamadas, SMS, misiones...)
--  Cada evento lleva un id único y se reenvía durante eventTTL segundos, así no
--  se pierde aunque un envío falle; el servidor lo emite una sola vez.
-- -----------------------------------------------------------------------------
local function pushEvent(kind, payload)
    state.eventSeq = state.eventSeq + 1
    local event = {
        id   = state.sessionId .. "-" .. state.eventSeq,
        kind = kind,
        ts   = os.time(),
        data = payload,
    }
    table.insert(state.events, { event = event, expires = state.clock + CONFIG.eventTTL })
    while #state.events > CONFIG.maxEvents do table.remove(state.events, 1) end
    log("Evento " .. kind .. " → " .. encode(payload))
    return event
end

local function liveEvents()
    local out, keep = {}, {}
    for _, item in ipairs(state.events) do
        if item.expires > state.clock then
            keep[#keep + 1] = item
            out[#out + 1] = item.event
        end
    end
    state.events = keep
    if #out == 0 then return EMPTY_ARRAY end
    return out
end

-- -----------------------------------------------------------------------------
--  Lectores de datos del juego (cada uno aislado con pcall)
-- -----------------------------------------------------------------------------
local function readPlayer(player)
    local id = player:GetEntityID()
    local pools = Game.GetStatPoolsSystem()
    local current = safe(function()
        return pools:GetStatPoolValue(id, gamedataStatPoolType.Health, false)
    end)
    local max = safe(function()
        return pools:GetStatPoolMaxPointValue(id, gamedataStatPoolType.Health)
    end) or safe(function()
        return Game.GetStatsSystem():GetStatValue(id, gamedataStatType.Health)
    end)
    local money = safe(function()
        return Game.GetTransactionSystem():GetItemQuantity(player, MarketSystem.Money())
    end)
    local level = safe(function()
        return Game.GetStatsSystem():GetStatValue(id, gamedataStatType.Level)
    end)
    return {
        health = { current = round(current, 1) or NULL, max = round(max, 1) or NULL },
        money  = money or NULL,
        level  = level and math.floor(level) or NULL,
    }
end

local function readLocation(player)
    local pos = safe(function() return player:GetWorldPosition() end)
    if pos == nil then return NULL end
    local yaw = safe(function() return player:GetWorldYaw() end)
    if yaw == nil then
        yaw = safe(function()
            local fwd = player:GetWorldForward()
            local atan2 = math.atan2 or math.atan -- CET usa LuaJIT (math.atan2)
            return math.deg(atan2(fwd.y, fwd.x)) - 90
        end)
    end
    return {
        x   = round(pos.x, 2),
        y   = round(pos.y, 2),
        z   = round(pos.z, 2),
        yaw = round(yaw, 1) or NULL,
    }
end

local function readVehicle(player)
    local vehicle = safe(function() return player:GetMountedVehicle() end)
        or safe(function() return Game.GetMountedVehicle(player) end)
    if vehicle == nil then return NULL end
    local name = safe(function() return vehicle:GetDisplayName() end)
    local record = safe(function() return TDBID.ToStringDEBUG(vehicle:GetRecordID()) end)
    local speed = safe(function() return vehicle:GetCurrentSpeed() end)
    return {
        name     = localize(name) or record or "Vehículo",
        recordId = record or NULL,
        speedKmh = speed and round(math.abs(speed) * 3.6, 0) or NULL,
    }
end

local function readWanted()
    local prevention = safe(function()
        return Game.GetScriptableSystemsContainer():Get(CName.new("PreventionSystem"))
    end)
    if prevention == nil then return { level = NULL, chasing = NULL } end
    local level = safe(function() return prevention:GetHeatStageAsInt() end)
    if level == nil then
        level = safe(function() return EnumInt(prevention:GetHeatStage()) end)
    end
    local chasing = safe(function() return prevention:IsChasingPlayer() end)
    return { level = level or NULL, chasing = (chasing == true) }
end

local function findParentQuest(journal, entry)
    local current = entry
    for _ = 1, 8 do
        current = safe(function() return journal:GetParentEntry(current) end)
        if current == nil then return nil end
        if safe(function() return current:IsA("gameJournalQuest") end) then return current end
    end
    return nil
end

local function readQuest()
    local journal = Game.GetJournalManager()
    if journal == nil then return NULL end
    local objective = safe(function() return journal:GetTrackedEntry() end)
    if objective == nil then return NULL end
    local objectiveText = localize(safe(function() return objective:GetDescription() end))
    local quest = findParentQuest(journal, objective)
    local title = quest and localize(safe(function() return quest:GetTitle(journal) end)) or nil
    local questId = quest and safe(function() return quest:GetId() end) or nil
    return {
        id        = questId or NULL,
        title     = title or NULL,
        objective = objectiveText or NULL,
    }
end

local function readWeapon(player)
    local item = safe(function()
        return Game.GetTransactionSystem():GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight"))
    end)
    if item == nil then return NULL end
    local itemID = safe(function() return item:GetItemID() end)
    if itemID == nil then return NULL end
    local record = safe(function() return TDBID.ToStringDEBUG(itemID.id) end)
    local name = safe(function()
        return Game.GetLocalizedTextByKey(TweakDB:GetRecord(itemID.id):DisplayName())
    end)
    if name == "" then name = nil end
    return { name = name or record or NULL, recordId = record or NULL }
end

local function readWorld()
    local t = safe(function() return Game.GetTimeSystem():GetGameTime() end)
    local inMenu = safe(function()
        local defs = Game.GetAllBlackboardDefs().UI_System
        return Game.GetBlackboardSystem():Get(defs):GetBool(defs.IsInMenu)
    end)
    return {
        hour   = t and safe(function() return t:Hours() end) or NULL,
        minute = t and safe(function() return t:Minutes() end) or NULL,
        inMenu = (inMenu == true),
    }
end

-- -----------------------------------------------------------------------------
--  Snapshot completo (schema v1). Referencia completa en companion/README.md.
-- -----------------------------------------------------------------------------
local function buildSnapshot(player)
    state.seq = state.seq + 1
    return {
        v         = SCHEMA_VERSION,
        type      = "telemetry",
        source    = "cet",
        sessionId = state.sessionId,
        seq       = state.seq,
        ts        = os.time(),
        player    = readPlayer(player),
        location  = readLocation(player),
        vehicle   = readVehicle(player),
        wanted    = state.slow.wanted or { level = NULL, chasing = false },
        quest     = state.slow.quest or NULL,
        inventory = { equippedWeapon = state.slow.weapon or NULL },
        world     = state.slow.world or NULL,
        phone     = { activeCall = state.activeCall or NULL },
        events    = liveEvents(),
    }
end

local function refreshSlow(player)
    state.slow.wanted = readWanted()
    state.slow.quest  = readQuest()
    state.slow.weapon = readWeapon(player)
    state.slow.world  = readWorld()
end

-- -----------------------------------------------------------------------------
--  Transportes
-- -----------------------------------------------------------------------------
local function httpAvailable()
    return safe(function() return HttpClient ~= nil and HttpClient.Post ~= nil end) == true
end

local function sendFile(body)
    local f, err = io.open(CONFIG.bridgeFile, "w")
    if not f then
        state.lastError = "file: " .. tostring(err)
        return false
    end
    f:write(body)
    f:close()
    return true
end

local function sendHttp(body)
    local ok, response = pcall(function() return HttpClient.Post(CONFIG.endpoint, body) end)
    if not ok then
        state.lastError = "http: " .. tostring(response)
        return false
    end
    if response == nil then
        state.lastError = "http: sin respuesta (¿juego lanzado con -no-tls? ¿server.js arrancado?)"
        return false
    end
    local code = safe(function() return response:GetStatusCode() end) or 0
    if code < 200 or code >= 300 then
        state.lastError = "http: status " .. tostring(code)
        return false
    end
    return true
end

local function chooseTransport()
    if CONFIG.transport == "file" then return "file" end
    if CONFIG.transport == "http" then return "http" end
    return httpAvailable() and "http" or "file"
end

local function send(snapshot)
    local body = encode(snapshot)
    local ok
    if state.transport == "http" then
        ok = sendHttp(body)
        if ok then
            state.httpFails = 0
        else
            state.httpFails = state.httpFails + 1
            if CONFIG.transport == "auto" and state.httpFails >= CONFIG.httpFailLimit then
                log("HTTP falla repetidamente (" .. state.lastError .. "). Cambio a transporte 'file'.")
                state.transport = "file"
            end
        end
    else
        ok = sendFile(body)
    end
    if ok then state.sentOk = state.sentOk + 1 else state.sendErrors = state.sendErrors + 1 end
end

-- -----------------------------------------------------------------------------
--  Hooks de eventos del juego
-- -----------------------------------------------------------------------------
local function callPhaseName(request)
    local p = (enumName("questPhoneCallPhase", request.callPhase) or ""):lower()
    if p:find("incoming") then return "incoming" end
    if p:find("start") then return "active" end
    if p:find("end") then return "ended" end
    return p ~= "" and p or "unknown"
end

local function onTriggerCall(request)
    local callerId = nameToString(request.caller)
    local addresseeId = nameToString(request.addressee)
    local outgoing = callerId ~= nil and callerId:lower() == "player"
    -- Si V es quien llama, el NPC es el destinatario.
    local npcId = outgoing and addresseeId or callerId
    local phase = callPhaseName(request)
    local data = {
        contactId = npcId or NULL,
        contact   = prettyContact(npcId),
        phase     = phase,
        outgoing  = outgoing,
        mode      = enumName("questPhoneCallMode", request.callMode) or NULL,
    }
    if phase == "ended" then
        state.activeCall = nil
    else
        state.activeCall = data
    end
    pushEvent("phone_call", data)
end

local function onJournalUpdate(entryHash, className)
    local cls = nameToString(className) or ""
    local journal = Game.GetJournalManager()
    if journal == nil then return end
    local entry = safe(function() return journal:GetEntry(entryHash) end)
    if entry == nil then return end

    if cls == "gameJournalPhoneMessage" then
        local text = localize(safe(function() return entry:GetText() end))
        local senderEnum = enumName("gameMessageSender", safe(function() return entry:GetSender() end)) or ""
        local fromPlayer = senderEnum:lower():find("player") ~= nil
        local conversation = safe(function() return journal:GetParentEntry(entry) end)
        local contact = conversation and safe(function() return journal:GetParentEntry(conversation) end) or nil
        local contactId = contact and safe(function() return contact:GetId() end) or nil
        local contactName = contact and localize(safe(function() return contact:GetLocalizedName(journal) end)) or nil
        pushEvent("text_message", {
            contactId  = contactId or NULL,
            contact    = contactName or prettyContact(contactId),
            text       = text or "",
            fromPlayer = fromPlayer,
        })
    elseif cls == "gameJournalQuest" or cls == "gameJournalQuestObjective" then
        local title = localize(safe(function() return entry:GetTitle(journal) end))
                   or localize(safe(function() return entry:GetDescription() end))
        pushEvent("quest_update", {
            entryType = cls == "gameJournalQuest" and "quest" or "objective",
            id        = safe(function() return entry:GetId() end) or NULL,
            title     = title or NULL,
        })
        state.slowTimer = CONFIG.slowInterval -- refresca la misión seguida en el próximo envío
    end
end

local function registerHooks()
    state.hooks.phone = pcall(function()
        Observe("PhoneSystem", "OnTriggerCall", function(_, request)
            local ok, err = pcall(onTriggerCall, request)
            if not ok then log("Error procesando llamada: " .. tostring(err)) end
        end)
    end)
    state.hooks.journal = pcall(function()
        Observe("JournalNotificationQueue", "OnJournalUpdate", function(_, entryHash, className)
            local ok, err = pcall(onJournalUpdate, entryHash, className)
            if not ok then log("Error procesando journal: " .. tostring(err)) end
        end)
    end)
    log("Hooks: PhoneSystem.OnTriggerCall=" .. tostring(state.hooks.phone) ..
        " · JournalNotificationQueue.OnJournalUpdate=" .. tostring(state.hooks.journal))
end

-- -----------------------------------------------------------------------------
--  Registro en CET
-- -----------------------------------------------------------------------------
registerForEvent("onInit", function()
    registerHooks()
    state.transport = chooseTransport()
    state.ready = true
    log("Listo. Transporte: " .. state.transport .. " · destino: " ..
        (state.transport == "http" and CONFIG.endpoint or CONFIG.bridgeFile))
end)

registerForEvent("onUpdate", function(delta)
    if not state.ready then return end
    state.clock = state.clock + delta
    state.sendTimer = state.sendTimer + delta
    state.slowTimer = state.slowTimer + delta
    if state.sendTimer < CONFIG.sendInterval then return end
    state.sendTimer = 0

    local player = Game.GetPlayer()
    if player == nil then return end -- menú principal / pantalla de carga

    if state.slowTimer >= CONFIG.slowInterval then
        state.slowTimer = 0
        local ok, err = pcall(refreshSlow, player)
        if not ok then state.lastError = "slow: " .. tostring(err) end
    end

    local ok, snapshotOrErr = pcall(buildSnapshot, player)
    if ok then
        send(snapshotOrErr)
    else
        state.lastError = "snapshot: " .. tostring(snapshotOrErr)
        state.sendErrors = state.sendErrors + 1
    end
end)

-- Atajos de prueba (CET > Bindings): prueban toda la cadena sin esperar a una misión.
registerHotkey("cp_companion_test_call", "Companion: simular llamada de Judy", function()
    local data = { contactId = "judy", contact = prettyContact("judy"), phase = "incoming",
                   outgoing = false, mode = "Audio" }
    state.activeCall = data
    pushEvent("phone_call", data)
    pushEvent("text_message", { contactId = "judy", contact = prettyContact("judy"),
                                text = "V, ¿estás libre? Te espero en Lizzie's.", fromPlayer = false })
end)

registerHotkey("cp_companion_end_call", "Companion: colgar llamada simulada", function()
    if state.activeCall then
        local data = state.activeCall
        state.activeCall = nil
        pushEvent("phone_call", {
            contactId = data.contactId, contact = data.contact, phase = "ended",
            outgoing = data.outgoing, mode = data.mode,
        })
    end
end)

registerForEvent("onOverlayOpen", function() state.overlayOpen = true end)
registerForEvent("onOverlayClose", function() state.overlayOpen = false end)

registerForEvent("onDraw", function()
    if not state.overlayOpen then return end
    if ImGui.Begin("CP2077 Companion") then
        ImGui.Text("Transporte: " .. state.transport)
        ImGui.Text("Destino: " .. (state.transport == "http" and CONFIG.endpoint or CONFIG.bridgeFile))
        ImGui.Text("Enviados OK: " .. state.sentOk .. " · Errores: " .. state.sendErrors)
        ImGui.Text("Hooks → teléfono: " .. tostring(state.hooks.phone) ..
                   " · diario: " .. tostring(state.hooks.journal))
        ImGui.Text("Eventos en cola: " .. #state.events)
        if state.lastError ~= "" then ImGui.TextWrapped("Último error: " .. state.lastError) end
        if ImGui.Button(state.transport == "http" and "Usar archivo" or "Usar HTTP") then
            state.transport = state.transport == "http" and "file" or "http"
            state.httpFails = 0
        end
    end
    ImGui.End()
end)

return {}
