-- Shared progress (PhantomPact.ini "ShareProgress = On", or the "sync on|off" command).
--
-- What one player achieves during a session is applied in the other player's world through the game's own
-- functions, so both keep the same progress:
--   Q <quest class path>   a quest succeeded: begin it if needed, then Quest.SucceedQuest (the game's own completion)
--   L <bell id>            a bell rung: BellManager.ActivateBellByID
--   G <mob domain>         an enemy group's reward (amber / blackstone) taken: PBZGameSystem.AddCompleteAddItemMobDomainName
--
-- Only changes made while sync is on are shared: when sync starts, the current state is the baseline, so joining a
-- partner never pushes either player's whole story onto the other. While a batch is applied the game's save veto
-- is held, so an autosave can't capture a half-applied state.
--
-- Not shared here: opened chests, broken rubbish piles and challenge points (their runtime save records can't be
-- written safely from Lua); pbzsave's "complete --only map" fills those in afterwards.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_TICKS = 120          -- 16 ms ticks between progress scans (~2 s)
    local VETO_ID = "PhantomPactSync"
    local VETO_REASON = 0           -- EPBZSaveVetoReason::GameplayFlow
    local SUCCEEDED = 2             -- EQuestCompletion::QC_Succeded

    local sync = {
        on = true,
        known = nil,                -- { quests = set, bells = set, mobs = set } once the baseline is taken
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

    local mobDomains = {}
    do
        local f = io.open(api.modRoot() .. "mobdomains.txt", "r")
        if f then
            for line in f:lines() do
                if line:match("^%S") and not line:match("^#") then
                    mobDomains[#mobDomains + 1] = line:match("^(%S+)")
                end
            end
            f:close()
        end
    end

    local function scan()
        local state = { quests = {}, bells = {}, mobs = {} }
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
        return state
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
        for kind, key in pairs({ quests = "Q", bells = "L", mobs = "G" }) do
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

    coop.extraTicks.sync = function()
        ticks = ticks + 1
        if ticks % POLL_TICKS == 0 then
            poll()
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
        log(string.format("Shared progress %s: sent %d, applied %d, failed %d (quests, bells, enemy-group rewards)",
            sync.on and "on" or "off", sync.sent, sync.applied, sync.failed))
    end

    return sync
end
