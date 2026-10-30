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
--                          ShareCodex, on by default)
--   W <quest path> <branch> a quest step (branch) completed: the partner completes the same branch with its own
--                          QuestBranch.SucceedBranch, so the story moves on step by step, not only at the end
--   F <Level>-<Actor> <0|1> a lift moved: DoPositiveAction / DoNegativeAction (checked in game: moved, recorded)
--   O <store> <id> <n>     an upgrade: weapon / Phantom Edge / accessory / medicine level, or Soul Snap; raised to the
--                          partner's level (never lowered) with the backpack's own UpgradeWeapon / UpgradeAccessory /
--                          UpgradeMedicine / SnapSoulWeapon (each checked in game)
--   CYC <cycle> <difficulty> sent once per session; a tip says so when the two saves differ
--   J <store> <id>         new equipment, from a chest or anywhere: accessory (acc), medicine (med), weapon (weap) or
--                          Phantom Edge weapon (edge); the partner gets it through the backpack's own
--                          PushAccessoryToInventory / PushMedicineToInventory / AddWeaponItem (checked in game)
--   A <Level>-<Actor>      a world object done: chest opened, rubbish pile broken, gate or door opened, shortcut
--                          kicked down, blocked path broken, cage opened... (the game's LevelActorManager key)
--
-- World objects live in streamed-in levels, so the partner's are kept in a pending list and applied when that
-- actor is loaded, through the object's own function (each checked in game):
--   rubbish pile BeginDestroyRubbish, gate / double door OpenDoorNoAnim, landscape door DoPositiveAction, ground
--   blocker Break, rope ManualFadeRope: opened and recorded by the game itself;
--   chest "Change Switch State", fog gate OpenByMobScript: shown open, not recorded.
--   kick-down stone "Start PhysicsSimulate": it falls, not recorded; only while you're 30-100 m from it (its physics
--   doesn't run from further away, and it mustn't land on you).
-- Cages only open through the player's own interaction, so they aren't changed live (regroup gets you past one). Every shared object goes to shared_world.txt; "pbzsave coop-sync" writes
-- the game's own record into the save with the game closed, so the rest is open from the next load. The contents
-- of a chest stay with the player who opened it (new equipment is shared separately, J).
--
-- Only changes made while sync is on are shared: when sync starts, the current state is the baseline, so joining a
-- partner never pushes either player's whole story onto the other. Catch-up (PhantomPact.ini CatchUp = On, or the
-- "sync catchup" command) is the exception, on request: "Z" asks the partner for everything they have, and what
-- this world is missing is applied through the same handlers (saves that differ end up with the union). While a batch is applied the game's save veto
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
    -- World objects shared as "A <Level>-<Actor>": their LevelActorManager record means the same finished state
    -- whoever made it (checked against real saves; pbzsave coop-sync writes that record). live: changed in the
    -- running game through the object's own function (verified in game).
    local SHARED = {
        BP_Chest_C = { what = "chest", live = "chest" },
        BP_Rubbish_C = { what = "rubbish pile", live = "rubbish" },
        BP_Rubbish_b_C = { what = "rubbish pile" },
        BP_FogDoor_C = { what = "fog gate", live = "fog" },
        BP_Block_Gate_C = { what = "gate", live = "door" },
        BP_DoubleDoor_G_C = { what = "door", live = "door" },
        BP_MoveableStuff_CollisionLandscape_door_C = { what = "door", live = "landscape" },
        BP_MoveableStuff_CollisionLandscape_C = { what = "door", live = "landscape" },
        BP_KickStone_C = { what = "shortcut", live = "kick" },
        BP_GroundBlocker_C = { what = "blocked path", live = "blocker" },
        BP_RopeConnection_C = { what = "rope", live = "rope" },
        BP_NarrativeCage_C = { what = "cage" },
    }

    local sync = {
        on = true,
        known = nil,                -- { quests = set, bells = set, ... } once the baseline is taken
        pending = {},               -- partner's chests / rubbish piles not applied yet: id -> true
        shown = {},                 -- chests shown open this session (their record waits for pbzsave coop-sync)
        ledgered = {},              -- ids already in shared_world.txt
        codex = true,               -- send new codex entries (PhantomPact.ini ShareCodex)
        catchUp = false,            -- ask for the partner's whole progress when a session starts (CatchUp)
        askedCatchUp = false,
        answeredCatchUp = false,
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

    -- "<Level>-<Actor>" -> the actor's class when it's a shared one: the actor name is the class plus "_UAID_..."
    -- (World Partition) or "_<n>".
    local function actorClass(id)
        local name = id:match("^[^-]+%-(.+)$")
        if not name then
            return nil
        end
        local cls = name:match("^(.-)_UAID_") or name:match("^(.-)_%d+$") or name
        return SHARED[cls] and cls or nil
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
                    sync.ledgered[id] = true
                end
            end
            f:close()
        end
    end

    -- Equipment stores of the backpack (owned item ids are the map keys) and how the backpack adds one.
    local EQUIP = {
        acc = { map = "Accessories", what = "accessory", add = function(bp, id) bp:PushAccessoryToInventory(FName(id), false) end },
        med = { map = "MedicineInfos", what = "medicine", add = function(bp, id) bp:PushMedicineToInventory(FName(id), false, true) end },
        weap = { map = "MainWeaponInfos", what = "weapon", add = function(bp, id) bp:AddWeaponItem(FName(id), true, true, false, false) end },
        edge = { map = "ShaqiWeaponInfos", what = "Phantom Edge weapon", add = function(bp, id) bp:AddWeaponItem(FName(id), false, true, false, false) end },
    }

    -- Upgrade levels per store: the backpack map, the field holding the level (Soul Snap: a bool), how to raise it.
    local LEVELS = {
        weap = { map = "MainWeaponInfos", field = "WeaponLevel", what = "weapon level",
            raise = function(bp, id, lv) bp:UpgradeWeapon(FName(id), true, lv) end },
        edge = { map = "ShaqiWeaponInfos", field = "ShaChiWeaponLevel", what = "Phantom Edge weapon level",
            raise = function(bp, id, lv) bp:UpgradeWeapon(FName(id), false, lv) end },
        acc = { map = "Accessories", field = "CurrentLevel", what = "accessory level",
            raise = function(bp, id, lv) bp:UpgradeAccessory(FName(id), lv) end },
        med = { map = "MedicineInfos", field = "CurrentLevel", what = "medicine level",
            raise = function(bp, id, lv) bp:UpgradeMedicine(FName(id), lv) end },
        weapsnap = { map = "MainWeaponInfos", field = "bAlreadySnapSoul", what = "Soul Snap",
            raise = function(bp, id) bp:SnapSoulWeapon(FName(id), true) end },
        edgesnap = { map = "ShaqiWeaponInfos", field = "bAlreadySnapSoul", what = "Soul Snap",
            raise = function(bp, id) bp:SnapSoulWeapon(FName(id), false) end },
    }

    local function levelOf(bp, store, id)
        local def = LEVELS[store]
        local lv
        bp[def.map]:ForEach(function(k, v)
            if lv == nil and k:get():ToString() == id then
                local x = v:get()[def.field]
                lv = x == true and 1 or (x == false and 0 or tonumber(x))
            end
        end)
        return lv
    end

    local function backpack()
        for _, o in ipairs(FindAllOf("PBZBackPackSubsystem") or {}) do
            if valid(o) then
                return o
            end
        end
    end

    local function owns(bp, store, id)
        local found = false
        bp[EQUIP[store].map]:ForEach(function(k)
            found = found or k:get():ToString() == id
        end)
        return found
    end

    local function worldName(pawn)
        local name
        pcall(function() name = pawn:GetWorld():GetFName():ToString() end)
        return name
    end

    local function scan()
        local state = { quests = {}, bells = {}, mobs = {}, nodes = {}, codex = {}, actors = {}, equip = {}, steps = {},
            levels = {} }
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
        -- Quest steps: completed branches of the quests in progress, through the quest's own functions (its sets
        -- of branches must not be iterated from Lua: that broke UE4SS's game-thread queue in testing).
        if nc then
            each(nc:GetInProgressQuests(), function(e)
                local q = e
                pcall(function() q = e:get() end)
                if valid(q) then
                    local path = (q:GetClass():GetFullName():gsub("^%S+ ", ""))
                    each(q:GetAllBranches(), function(b)
                        local br = b
                        pcall(function() br = b:get() end)
                        if valid(br) and br:IsCompleted() then
                            state.steps[path .. " " .. br.ID:ToString()] = true
                        end
                    end)
                end
            end)
        end
        local gs = first("PBZGameSystem")
        if gs then
            for _, name in ipairs(mobDomains) do
                if gs:HasCompleteAddItemMobDomainName(FName(name)) then
                    state.mobs[name] = true
                end
            end
        end
        local epm = first("EventPipelineManager")
        if epm then
            for _, guid in ipairs(challengeNodes) do
                if epm.ExecuteNodeGuid:Contains(guid) then
                    state.nodes[guid] = true
                end
            end
        end
        local bp = backpack()
        if bp then
            for store, prop in pairs(EQUIP) do
                bp[prop.map]:ForEach(function(k)
                    state.equip[store .. " " .. k:get():ToString()] = true
                end)
            end
            for store, def in pairs(LEVELS) do
                bp[def.map]:ForEach(function(k, v)
                    local x = v:get()[def.field]
                    local lv = x == true and 1 or (x == false and 0 or tonumber(x))
                    if lv then
                        state.levels[store .. " " .. k:get():ToString()] = lv
                    end
                end)
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

    -- How each live object is opened, and whether the game records it by itself (then it leaves the pending list);
    -- nil = not now (tried again on the next scan).
    local KICK_MIN_CM, KICK_MAX_CM = 3000, 10000
    local function kick(a)
        if a.Finished then
            return false
        end
        local _, pawn = api.getPlayer1()
        if not valid(pawn) then
            return nil
        end
        local s, p = a:K2_GetActorLocation(), pawn:K2_GetActorLocation()
        local d = math.sqrt((s.X - p.X) ^ 2 + (s.Y - p.Y) ^ 2 + (s.Z - p.Z) ^ 2)
        if d < KICK_MIN_CM or d > KICK_MAX_CM then
            return nil
        end
        a["Start PhysicsSimulate"]()
        return false
    end
    local OPEN = {
        kick = kick,
        rubbish = function(a) if not a.bDestroyed then a:BeginDestroyRubbish() end return true end,
        door = function(a) a:OpenDoorNoAnim() return true end,
        landscape = function(a) a:DoPositiveAction() return true end,
        blocker = function(a) a:Break() return true end,
        rope = function(a) a:ManualFadeRope() return true end,
        chest = function(a) if not a.CurSwitchState then a["Change Switch State"]() end return false end,
        fog = function(a) a:OpenByMobScript() return false end,
    }

    -- The partner's world objects whose actor is loaded now. Recorded ones leave the list.
    local function applyPending()
        if next(sync.pending) == nil then
            return
        end
        local lam = first("PBZLevelActorManager")
        local actorClassObj = StaticFindObject("/Script/Engine.Actor")
        if not (lam and valid(actorClassObj)) then
            return
        end
        for id in pairs(sync.pending) do
            local cn = actorClass(id)
            if lam:HasSaveDataByActorID(FName(id)) or not (cn and SHARED[cn].live) then
                sync.pending[id] = nil      -- recorded already, or nothing to do live (pbzsave coop-sync records it)
            elseif not sync.shown[id] then
                local a = lam:GetActorByID(FName(id), actorClassObj)
                if valid(a) then
                    if sync.known then
                        sync.known.actors[id] = true     -- shown because of the partner: don't send it back
                    end
                    -- Each object on its own: one failing doesn't hold up the rest.
                    local ok, recorded = pcall(OPEN[SHARED[cn].live], a)
                    if not ok then
                        log("Shared progress: couldn't open " .. id .. ": " .. tostring(recorded))
                        recorded = nil
                    end
                    if recorded then
                        sync.pending[id] = nil      -- the game recorded it
                    elseif recorded == false then
                        sync.shown[id] = true       -- shown open this session; pbzsave coop-sync records it
                    end
                    log("Shared progress: partner's " .. SHARED[cn].what .. " " .. id)
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
            if not sync.sentCycle then
                sync.sentCycle = true
                pcall(function()
                    local gs = first("PBZGameSystem")
                    coop.sendEvent("CYC", gs:GetCycleCount(), gs:GetDifficultModeByte())
                end)
            end
            if sync.catchUp and not sync.askedCatchUp then
                sync.askedCatchUp = true
                coop.sendEvent("Z")
                log("Shared progress: asked the partner for their whole progress (catch-up).")
            end
            return
        end
        for kind, key in pairs({ quests = "Q", bells = "L", mobs = "G", nodes = "N", codex = "X", actors = "A", equip = "J", steps = "W" }) do
            for id in pairs(now[kind]) do
                if not sync.known[kind][id] then
                    sync.known[kind][id] = true
                    coop.sendEvent(key, id)
                    sync.sent = sync.sent + 1
                end
            end
        end
        -- Levels: sent when one goes up (after "J", so new equipment exists on the partner's side first).
        sync.known.levels = sync.known.levels or {}
        for id, lv in pairs(now.levels or {}) do
            if lv > (sync.known.levels[id] or 0) then
                sync.known.levels[id] = lv
                local store, item = id:match("^(%S+) (%S+)$")
                coop.sendEvent("O", store, item, lv)
                sync.sent = sync.sent + 1
            end
        end
    end

    -- Applies one change from the partner under the save veto.
    local function apply(label, kind, id, fn)
        if not sync.on then
            return
        end
        if sync.known and sync.known[kind] then
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
            local epm = first("EventPipelineManager")
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

    -- A quest step: begin the quest if needed, then complete that branch through the quest's own function.
    local function questOf(path)
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
        if not valid(q) then
            q = nc:BeginQuest(cls, FName("None"))
        end
        if not valid(q) then
            error("BeginQuest returned nothing")
        end
        return q
    end

    coop.handlers.W = function(rest)
        local path, branch = (rest or ""):match("^(/[%w_/%-]+%.[%w_%-]+) ([%w_%-]+)$")
        if not path then
            return
        end
        apply("quest step", "steps", path .. " " .. branch, function()
            local q = questOf(path)
            if q:GetQuestCompletion() == SUCCEEDED then
                return
            end
            local b = q:GetBranch(FName(branch))
            if not valid(b) then
                error("no branch " .. branch)
            end
            if not b:IsCompleted() then
                b:SucceedBranch()
            end
        end)
    end

    -- Lifts: their direction (Positive) is sent when it changes; the partner's lift is moved the same way.
    sync.lifts = {}                 -- lift id -> Positive as last seen or set
    sync.pendingLifts = {}          -- partner's lift moves for areas not loaded here: id -> up
    local function watchLifts()
        local _, pawn = api.getPlayer1()
        local world = valid(pawn) and worldName(pawn)
        if not world then
            return
        end
        for _, a in ipairs(FindAllOf("BP_Lift_C") or {}) do
            if valid(a) then
                local id = world .. "-" .. a:GetFName():ToString()
                -- The partner moved this lift while its area wasn't loaded here: move it now.
                local want = sync.pendingLifts[id]
                if want ~= nil then
                    sync.pendingLifts[id] = nil
                    if (a.Positive == true) ~= want then
                        if want then
                            a:DoPositiveAction()
                        else
                            a:DoNegativeAction()
                        end
                    end
                    sync.lifts[id] = want
                end
                local up = a.Positive == true
                local was = sync.lifts[id]
                sync.lifts[id] = up
                if was ~= nil and was ~= up then
                    coop.sendEvent("F", id, up and 1 or 0)
                    sync.sent = sync.sent + 1
                end
            end
        end
    end

    coop.handlers.F = function(rest)
        local id, dir = (rest or ""):match("^([%w_%-%.]+) ([01])$")
        if not (id and validId(id)) then
            return
        end
        apply("lift", "lifts", id, function()
            local lam = first("PBZLevelActorManager")
            local a = lam and lam:GetActorByID(FName(id), StaticFindObject("/Script/Engine.Actor"))
            local up = dir == "1"
            if not valid(a) then
                sync.pendingLifts[id] = up  -- not loaded here: moved when its area loads (watchLifts)
                return
            end
            sync.lifts[id] = up             -- moved because of the partner: don't send it back
            if (a.Positive == true) ~= up then
                if up then
                    a:DoPositiveAction()
                else
                    a:DoNegativeAction()
                end
            end
        end)
    end

    coop.handlers.O = function(rest)
        local store, id, lv = (rest or ""):match("^(%a+) ([%w_%.%-]+) (%d+)$")
        lv = tonumber(lv)
        if not (store and LEVELS[store] and lv and lv <= 999) then
            return
        end
        apply(LEVELS[store].what, "levelsApplied", store .. " " .. id, function()
            local bp = backpack()
            if not bp then
                error("no backpack")
            end
            local cur = levelOf(bp, store, id)
            if cur == nil then
                error("not owned here")
            end
            if lv > cur then
                LEVELS[store].raise(bp, id, lv)
                local after = levelOf(bp, store, id) or cur
                if sync.known then
                    sync.known.levels = sync.known.levels or {}
                    sync.known.levels[store .. " " .. id] = after     -- raised because of the partner: not sent back
                end
                if after <= cur then
                    error("the backpack didn't raise it")
                end
            end
        end)
    end

    coop.handlers.CYC = function(rest)
        local cycle, diff = (rest or ""):match("^(%d+) (%d+)$")
        cycle, diff = tonumber(cycle), tonumber(diff)
        if not cycle then
            return
        end
        local ok, mine, myDiff = pcall(function()
            local gs = first("PBZGameSystem")
            return gs:GetCycleCount(), gs:GetDifficultModeByte()
        end)
        if ok and (mine ~= cycle or myDiff ~= diff) and api.status and api.status.notify then
            api.status.notify("cycle", string.format("your partner's save is in cycle %d, difficulty %d; yours is cycle %d, "
                .. "difficulty %d: enemies and items can differ between your worlds.", cycle, diff, mine, myDiff))
        end
    end

    coop.handlers.J = function(rest)
        local store, id = (rest or ""):match("^(%a+) ([%w_%.%-]+)$")
        if not (store and EQUIP[store] and #id < 128) then
            return
        end
        apply(EQUIP[store].what, "equip", store .. " " .. id, function()
            local bp = backpack()
            if not bp then
                error("no backpack")
            end
            if not owns(bp, store, id) then
                EQUIP[store].add(bp, id)
                -- The backpack ignores ids it doesn't know (checked in game): only tell the player when it arrived.
                if not owns(bp, store, id) then
                    error("the backpack didn't take it")
                end
                if api.status and api.status.notify then
                    api.status.notify("loot", "your partner found a " .. EQUIP[store].what .. ": you got it too.")
                end
            end
        end)
    end

    coop.handlers.A = function(id)
        local cn = validId(id) and actorClass(id)
        if not cn then
            return
        end
        if not sync.pending[id] and not sync.ledgered[id] then
            sync.ledgered[id] = true
            sync.pending[id] = true
            appendLedger(id)
            if not SHARED[cn].live and api.status and api.status.notify then
                api.status.notify("world", "your partner opened a " .. SHARED[cn].what .. ": it opens for you from your "
                    .. "next load (pbzsave coop-sync). Regroup to get past it now.")
            end
        end
        apply(SHARED[cn].what, "actors", id, applyPending)
    end

    coop.extraTicks.sync = function()
        ticks = ticks + 1
        if ticks % POLL_TICKS == 0 then
            poll()
            if sync.on and net.enabled then
                pcall(watchLifts)
            end
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
        sync.askedCatchUp, sync.answeredCatchUp, sync.sentCycle = false, false, false
        log("Shared progress " .. (on and "on" or "off") .. ".")
    end

    -- The partner asked for everything (catch-up): our whole known state, as the usual events, once per session.
    local KINDS = { quests = "Q", bells = "L", mobs = "G", nodes = "N", codex = "X", actors = "A", equip = "J", steps = "W" }
    coop.handlers.Z = function()
        if not (sync.on and sync.known) or sync.answeredCatchUp then
            return
        end
        sync.answeredCatchUp = true
        local n = 0
        for kind, key in pairs(KINDS) do
            for id in pairs(sync.known[kind] or {}) do
                coop.sendEvent(key, id)
                n = n + 1
            end
        end
        for id, lv in pairs(sync.known.levels or {}) do
            local store, item = id:match("^(%S+) (%S+)$")
            if lv > 0 then
                coop.sendEvent("O", store, item, lv)
                n = n + 1
            end
        end
        log("Shared progress: sent our whole progress to the partner (" .. n .. " entries, catch-up).")
        if api.status and api.status.notify then
            api.status.notify("catchup", "your partner is catching up with your progress.")
        end
    end

    function sync.command(args)
        local a = (args or ""):lower()
        if a == "on" or a == "off" then
            sync.set(a == "on")
            return
        end
        if a == "catchup" then
            coop.sendEvent("Z")
            log("Shared progress: asked the partner for their whole progress (catch-up).")
            return
        end
        local waiting = 0
        for _ in pairs(sync.pending) do
            waiting = waiting + 1
        end
        log(string.format("Shared progress %s: sent %d, applied %d, failed %d, %d chest(s) / rubbish pile(s) waiting "
            .. "for their area (quests, bells, enemy rewards, challenge points, codex, equipment, chests, rubbish "
            .. "piles, gates, doors, shortcuts)",
            sync.on and "on" or "off", sync.sent, sync.applied, sync.failed, waiting))
    end

    return sync
end
