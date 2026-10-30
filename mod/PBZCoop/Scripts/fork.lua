-- Fork extras (appdoze/PhantomPact) on top of the upstream mod: loaded by one line in main.lua, settings read from
-- PhantomPact.ini here, so upstream files stay as they are.
--   sync.lua      shared progress (ShareProgress, ShareCodex, CatchUp)
--   regroup.lua   regroup / revive / regroup on join (RegroupKey, ReviveAtPartner, RegroupOnJoin)
--   dialogue.lua  partner's dialogue lines as tips (ShareDialogue)
--   mapicon.lua   partner on the map (PartnerMapIcon)
--   smoothing.lua guest enemy glide (loaded by coop.lua)

return function(api, commands)
    local log = api.log
    local dir = api.modRoot() .. "Scripts/"

    local function settings()
        local f = io.open(api.modRoot() .. "PhantomPact.ini", "r")
        if not f then
            return {}
        end
        local s = {}
        for line in f:lines() do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key and not line:match("^%s*[;#]") then
                s[key:lower()] = (value:gsub("%s*;.*$", ""))
            end
        end
        f:close()
        return s
    end

    local s = settings()
    local function on(key, default)
        return (s[key] or default):lower() ~= "off"
    end

    local function load(name)
        local ok, mod = pcall(function() return dofile(dir .. name)(api) end)
        if not ok then
            log("Fork extra " .. name .. " failed to load: " .. tostring(mod))
            return nil
        end
        return mod
    end

    local sync = load("sync.lua")
    if sync then
        api.sync = sync
        sync.codex = on("sharecodex", "on")
        sync.catchUp = (s.catchup or "off"):lower() == "on"
        sync.set(on("shareprogress", "on"))
        commands.sync = sync.command
    end

    local regroup = load("regroup.lua")
    if regroup then
        api.regroup = regroup
        regroup.revive = on("reviveatpartner", "on")
        regroup.joinRegroup = on("regrouponjoin", "on")
        regroup.enabled = (s.regroupkey or "F5"):lower() ~= "off"
        if regroup.enabled then
            regroup.bindKey(s.regroupkey or "F5")
        end
        commands.regroup = function() regroup.regroup() end
    end

    local dialogue = load("dialogue.lua")
    if dialogue then
        dialogue.on = on("sharedialogue", "on")
    end

    local mapicon = load("mapicon.lua")
    if mapicon then
        mapicon.on = on("partnermapicon", "on")
    end

    log("Fork extras loaded: shared progress " .. tostring(sync and sync.on) .. ", regroup "
        .. tostring(regroup and regroup.enabled) .. ", dialogue " .. tostring(dialogue and dialogue.on)
        .. ", map icon " .. tostring(mapicon and mapicon.on))
end
