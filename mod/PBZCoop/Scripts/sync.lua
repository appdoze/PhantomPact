-- Shared progress (PhantomPact.ini "ShareProgress = On", or the "sync on|off" command).
--
-- What one player achieves during a session is applied in the other player's world through the game's own
-- functions, so both keep the same progress:
--   Q <quest class path>   a quest succeeded: begin it if needed, then Quest.SucceedQuest (the game's own completion)
--   L <bell id>            a bell rung: BellManager.ActivateBellByID
--   G <mob domain>         an enemy group's reward (amber / blackstone) taken: PBZGameSystem.AddCompleteAddItemMobDomainName
--   N <node guid>          a challenge point (Banyan Heart, Dragon Pillar, Scarecrow) done: the event pipeline's
--                          ExecuteNodeGuid record, the one the map's completion reads
--   X <enemy class path>   a codex entry discovered: PBZCodexSubsystem.DiscoveredEnemyPaths (sending needs
--                          "ShareCodex = On": reading the codex list isn't verified in game yet; receiving is)
--   A <Level>-<Actor>      a chest opened or a rubbish pile broken (the game's LevelActorManager key)
--
-- Chests and rubbish piles live in streamed-in levels, so the partner's are kept in a pending list and applied
-- when that actor is loaded: a rubbish pile through its own BeginDestroyRubbish (which also records it), a chest
-- through its own "Change Switch State" (shown open). A chest's record can't be written safely from Lua, so every
-- shared chest also goes to shared_world.txt; "pbzsave coop-sync" writes them into the save with the game closed,
-- and until then they are shown open again each session. The contents stay with the player who opened it.
--
-- Only changes made while sync is on are shared: when sync starts, the current state is the baseline, so joining a
-- partner never pushes either player's whole story onto the other. While a batch is applied the game's save veto
-- is held, so an autosave can't capture a half-applied state.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_TICKS = 120          -- 16 ms ticks between progress scans (~2 s)
    local VETO_ID = "PhantomPactSync"
    local VETO_REASON = 0           -- EPBZSaveVetoReason::GameplayFlow
    local SUCCEEDED = 2             -- EQuestCompletion::QC_Succeded
    local LEDGER = "shared_world.txt"
    local ACTOR_CLASSES = { "BP_Chest_C", "BP_Rubbish_C" }

    local sync = {
        on = true,
        known = nil,                -- { quests = set, bells = set, ... } once the baseline is taken
        pending = {},               -- partner's chests / rubbish piles not applied yet: id -> true
        shown = {},                 -- chests shown open this session (their record waits for pbzsave coop-sync)
        codex = false,              -- send new codex entries (PhantomPact.ini ShareCodex)
        sent = 0,
        applied = 0,
        failed = 0,
    }
    local ticks = 0

    local function first(cls)
        local o = FindFirstOf(cls)
        return valid(o) and o or nil
    end

    local function str(v)
        local s = v
        pcall(function() s = v:get() end)
        pcall(function() s = s:ToString() end)
        return tostring(s)
    end

    -- UFunction array results arrive as Lua tables, property arrays as TArray userdata.
    local function each(arr, fn)
        if arr == nil then
            return
        end
        if type(arr) == "table" then
            for _, e in ipairs(arr) do
                fn(e)
            end
        else
            arr:ForEach(function(_, e) fn(e) end)
        end
    end

    -- One identifier per line, "#" comments; the first word of each line.
    local function readList(name, pattern)
        local out = {}
        local f = io.open(api.modRoot() .. name, "r")
        if f then
            for line in f:lines() do
                local id = line:match(pattern)
                if id and not line:match("^#") then
                    out[#out + 1] = id
                end
            end
            f:close()
        end
        return out
    end
    local mobDomains = readList("mobdomains.txt", "^(%S+)")
    local challengeNodes = readList("challengenodes.txt", "^([%w_%-%.]+)")

    local function validId(id)
        return id ~= nil and #id > 0 and #id < 256 and id:match("^[%w_%-%.%+]+$") ~= nil
    end

    local function actorClass(id)
        for _, cn in ipairs(ACTOR_CLASSES) do
            if id:find("-" .. cn, 1, true) then
                return cn
            end
        end
    end

    -- Ledger of shared chests and rubbish piles for pbzsave coop-sync; read at start, so the partner's chests from
    -- an earlier session are shown open again.
    local function appendLedger(id)
        local f = io.open(api.modDir() .. LEDGER, "a")
        if f then
            f:write("A " .. id .. "\n")
            f:close()
        end
    end
    do
        local f = io.open(api.modDir() .. LEDGER, "r")
        if f then
            for line in f:lines() do
                local id = line:match("^A (%S+)")
                if validId(id) and actorClass(id) then
                    sync.pending[id] = true
                end
            end
            f:close()
        end
    end

    local function worldName(pawn)
        local name
        pcall(function() name = pawn:GetWorld():GetFName():ToString() end)
        return name
    end

    local function scan()
        local state = { quests = {}, bells = {}, mobs = {}, nodes = {}, codex = {}, actors = {} }
        local nc = first("PBZNarrativeComponent")
        if nc then
            each(nc:GetAllQuests(), function(e)
                local q = e
                pcall(function() q = e:get() end)
                if valid(q) and q:GetQuestCompletion() == SUCCEEDED then
                    state.quests[(q:GetClass():GetFullName():gsub("^%S+ ", ""))] = true
                end
            end)
        end
        local bm = first("BellManager")
        if bm then
            each(bm:GetAllActivateBellIDs(), function(e) state.bells[str(e)] = true end)
        end
        local gs = first("PBZGameSystem")
        if gs then
            for _, name in ipairs(mobDomains) do
                if gs:HasCompleteAddItemMobDomainName(FName(name)) then
                    state.mobs[name] = true
                end
            end
        end
        local epm = first("PBZEventPipelineManager")
        if epm then
            for _, guid in ipairs(challengeNodes) do
                if epm.ExecuteNodeGuid:Contains(guid) then
                    state.nodes[guid] = true
                end
            end
        end
        local cs = sync.codex and first("PBZCodexSubsystem")
        if cs then
            each(cs:GetDiscoveredEnemyPathStrings(), function(e) state.codex[str(e)] = true end)
        end
        -- Chests / rubbish piles: the game's own records (a rubbish pile records itself when broken), plus loaded
        -- chests that show open (a chest opened in play may only be recorded when the game saves).
        local lam = first("PBZLevelActorManager")
        if lam then
            lam.ActorSaveData:ForEach(function(k)
                local id = k:get():ToString()
                if actorClass(id) then
                    state.actors[id] = true
                end
            end)
            local _, pawn = api.getPlayer1()
            local world = valid(pawn) and worldName(pawn)
            if world then
                for _, c in ipairs(FindAllOf("BP_Chest_C") or {}) do
                    if valid(c) and c.CurSwitchState then
                        state.actors[world .. "-" .. c:GetFName():ToString()] = true
                    end
                end
            end
        end
        return state
    end

    -- The partner's chests / rubbish piles whose actor is loaded now. Recorded ones leave the list.
    local function applyPending()
        if next(sync.pending) == nil then
            return
        end
        local lam = first("PBZLevelActorManager")
        if not lam then
            return
        end
        local classes = {}
        for _, cn in ipairs(ACTOR_CLASSES) do
            local inst = first(cn)
            classes[cn] = inst and inst:GetClass() or nil
        end
        for id in pairs(sync.pending) do
            local cn = actorClass(id)
            if lam:HasSaveDataByActorID(FName(id)) then
                sync.pending[id] = nil
            elseif classes[cn] and not sync.shown[id] then
                local a = lam:GetActorByID(FName(id), classes[cn])
                if valid(a) then
                    if sync.known then
                        sync.known.actors[id] = true     -- shown because of the partner: don't send it back
                    end
                    if cn == "BP_Rubbish_C" then
                        if not a.bDestroyed then
                            a:BeginDestroyRubbish()
                        end
                        sync.pending[id] = nil
                    else
                        if not a.CurSwitchState then
                            a["Change Switch State"]()
                        end
                        sync.shown[id] = true
                    end
                    log("Shared progress: partner's " .. (cn == "BP_Rubbish_C" and "rubbish pile" or "chest") .. " " .. id)
                end
            end
        end
    end

    -- New entries since the last scan go to the partner; the first scan only sets the baseline.
    local function poll()
        if not (sync.on and net.enabled) then
            sync.known = nil
            return
        end
        local now = scan()
        if sync.known == nil then
            sync.known = now
            return
        end
        for kind, key in pairs({ quests = "Q", bells = "L", mobs = "G", nodes = "N", codex = "X", actors = "A" }) do
            for id in pairs(now[kind]) do
                if not sync.known[kind][id] then
                    sync.known[kind][id] = true
                    coop.sendEvent(key, id)
                    sync.sent = sync.sent + 1
                end
            end
        end
    end

    -- Applies one change from the partner under the save veto.
    local function apply(label, kind, id, fn)
        if not sync.on then
            return
        end
        if sync.known then
            sync.known[kind][id] = true     -- learned from the partner: don't send it back
        end
        local sl = first("PBZSaveLoadSubsystem")
        if sl then
            pcall(function() sl:EnterSaveVeto(FName(VETO_ID), VETO_REASON) end)
        end
        local ok, err = pcall(fn)
        if sl then
            pcall(function() sl:ExitSaveVeto(FName(VETO_ID)) end)
        end
        if ok then
            sync.applied = sync.applied + 1
            log("Shared progress: " .. label .. " " .. id)
        else
            sync.failed = sync.failed + 1
            log("Shared progress failed (" .. label .. " " .. id .. "): " .. tostring(err))
        end
    end

    coop.handlers.Q = function(path)
        if not path or path == "" then
            return
        end
        apply("quest", "quests", path, function()
            local nc = first("PBZNarrativeComponent")
            if not nc then
                error("no narrative component")
            end
            local cls = StaticFindObject(path)
            if not valid(cls) then
                cls = LoadAsset(path)
            end
            if not valid(cls) then
                error("unknown quest class")
            end
            local q = nc:GetQuest(cls)
            if valid(q) and q:GetQuestCompletion() == SUCCEEDED then
                return
            end
            if not valid(q) then
                q = nc:BeginQuest(cls, FName("None"))
            end
            if not valid(q) then
                error("BeginQuest returned nothing")
            end
            q:SucceedQuest(FText(""))
        end)
    end

    coop.handlers.L = function(id)
        if not id or id == "" then
            return
        end
        apply("bell", "bells", id, function()
            local bm = first("BellManager")
            if bm then
                bm:ActivateBellByID(FName(id))
            end
        end)
    end

    coop.handlers.G = function(name)
        if not name or name == "" then
            return
        end
        apply("enemy group reward", "mobs", name, function()
            local gs = first("PBZGameSystem")
            if gs and not gs:HasCompleteAddItemMobDomainName(FName(name)) then
                gs:AddCompleteAddItemMobDomainName(FName(name))
            end
        end)
    end

    coop.handlers.N = function(guid)
        if not validId(guid) then
            return
        end
        apply("challenge point", "nodes", guid, function()
            local epm = first("PBZEventPipelineManager")
            if not epm then
                error("no event pipeline")
            end
            if not epm.ExecuteNodeGuid:Contains(guid) then
                epm.ExecuteNodeGuid:Add(guid, true)
            end
        end)
    end

    -- "/Package/Path/Name.Name_C": the codex keeps it as an FSoftObjectPath (package, asset).
    coop.handlers.X = function(path)
        local pkg, asset = (path or ""):match("^(/[%w_/%-]+)%.([%w_%-]+)$")
        if not pkg then
            return
        end
        apply("codex entry", "codex", path, function()
            local cs = first("PBZCodexSubsystem")
            if not cs then
                error("no codex")
            end
            -- A set: adding an entry that's already there changes nothing (checked in game).
            cs.DiscoveredEnemyPaths:Add({ AssetPath = { PackageName = FName(pkg), AssetName = FName(asset) },
                SubPathString = "" })
        end)
    end

    coop.handlers.A = function(id)
        if not (validId(id) and actorClass(id)) then
            return
        end
        if not sync.pending[id] then
            sync.pending[id] = true
            appendLedger(id)
        end
        apply("chest / rubbish pile", "actors", id, applyPending)
    end

    coop.extraTicks.sync = function()
        ticks = ticks + 1
        if ticks % POLL_TICKS == 0 then
            poll()
            if sync.on and net.enabled then
                local ok, err = pcall(applyPending)
                if not ok then
                    log("Shared progress: chest / rubbish pile apply failed: " .. tostring(err))
                end
            end
        end
    end

    function sync.set(on)
        sync.on = on
        sync.known = nil
        log("Shared progress " .. (on and "on" or "off") .. ".")
    end

    function sync.command(args)
        local a = (args or ""):lower()
        if a == "on" or a == "off" then
            sync.set(a == "on")
            return
        end
        local waiting = 0
        for _ in pairs(sync.pending) do
            waiting = waiting + 1
        end
        log(string.format("Shared progress %s: sent %d, applied %d, failed %d, %d chest(s) / rubbish pile(s) waiting "
            .. "for their area (quests, bells, enemy rewards, challenge points, codex, chests, rubbish piles)",
            sync.on and "on" or "off", sync.sent, sync.applied, sync.failed, waiting))
    end

    return sync
end
