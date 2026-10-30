-- Phantom Pact auto-start: reads PhantomPact.ini, starts the network relay (relay\pbzcoop_relay.exe, or
-- net/pbzcoop_net.py with the player's own Python) when the game starts, and turns online sync on once the player
-- is in gameplay.
-- Players only edit the ini; nothing to run by hand.
--
-- The relay stops by itself when the game closes: this file rewrites net_alive.txt every few seconds and the
-- relay exits once it goes stale (--alive-file).

return function(api)
    local log, valid, getPlayer1 = api.log, api.valid, api.getPlayer1
    local modDir, modRoot = api.modDir, api.modRoot
    local neton = api.coop.commands.neton

    local ALIVE_EVERY_MS = 3000
    local RELAY_FRESH_S = 5       -- a relay status this recent means a relay is already running
    local placeholder = "PUT-THE-HOSTS-TAILSCALE-IP-HERE"

    -- Game builds this version was made and tested on, by PBZ.exe size (reading the size is instant; hashing a
    -- 500 MB exe at startup isn't). Another build still runs, with a warning: function and field names may differ.
    local KNOWN_BUILDS = {
        [511072344] = "Steam build 26266538",
    }
    local function checkGameBuild()
        local f = io.open(modRoot() .. "../../../PBZ.exe", "rb")
        if not f then
            return
        end
        local size = f:seek("end")
        f:close()
        if KNOWN_BUILDS[size] then
            log("Game build: " .. KNOWN_BUILDS[size] .. " (supported).")
        else
            api.gameBuildWarning = "This game update isn't tested with this Phantom Pact version; some co-op features may fail."
            log("WARNING: PBZ.exe (" .. tostring(size) .. " bytes) is a game build this Phantom Pact version wasn't "
                .. "tested on. Co-op may partly fail; check for a Phantom Pact update.")
        end
    end
    pcall(checkGameBuild)

    local function readText(path)
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local text = f:read("a")
        f:close()
        return text
    end

    local function writeText(path, text)
        local f = io.open(path, "w")
        if f then
            f:write(text)
            f:close()
        end
    end

    -- "Key = value" lines; ";" and "#" start comments.
    local function readSettings()
        local text = readText(modDir() .. "PhantomPact.ini")
        if not text then
            return nil
        end
        local s = {}
        for line in text:gmatch("[^\r\n]+") do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key and not line:match("^%s*[;#]") then
                s[key:lower()] = value
            end
        end
        return s
    end

    local settings = readSettings()
    if not settings then
        log("No PhantomPact.ini: co-op stays off (use the neton command to start it by hand).")
        return
    end
    local role = (settings.role or "off"):lower()
    local modRole = ({ host = "host", guest = "client" })[role]
    if not modRole then
        log("PhantomPact.ini: Role = " .. tostring(settings.role) .. ", co-op is off.")
        return
    end
    local port = tonumber(settings.port) or 47800
    local hostAddress = settings.hostaddress or ""
    -- Network: Tailscale (default), Direct (port forwarding, needs a Secret) or Steam (Steam's own networking).
    local network = (settings.network or "tailscale"):lower()
    if network ~= "tailscale" and network ~= "direct" and network ~= "steam" then
        log("PhantomPact.ini: Network = " .. tostring(settings.network) .. " isn't Tailscale, Direct or Steam; using Tailscale.")
        network = "tailscale"
    end
    -- Empty or Auto: find the partner among Steam friends playing PBZ (their relay advertises the other role).
    local partner = settings.partnersteamid or ""
    if partner == "" or partner:lower() == "auto" then
        partner = "auto"
    end
    if network == "steam" and partner ~= "auto" and not partner:match("^7656119%d+$") then
        log("PhantomPact.ini: PartnerSteamID must be Auto or a SteamID64 (17 digits, 7656119...). Co-op is off.")
        return
    end
    if network ~= "steam" and modRole == "client"
        and (hostAddress == "" or hostAddress == placeholder or not hostAddress:match("^[%w%.%-:]+$")) then
        log("PhantomPact.ini: Role = Guest but HostAddress isn't set. Put the host's IP there and restart the game.")
        return
    end

    if api.partner then
        api.partner.bindKey(settings.regroupkey)
    end

    -- Heartbeat for the relay; written before the relay starts so it doesn't see a stale one.
    local alivePath = modDir() .. "net_alive.txt"
    writeText(alivePath, tostring(os.time()))
    LoopAsync(ALIVE_EVERY_MS, function()
        writeText(alivePath, tostring(os.time()))
        return false
    end)

    local function relayRunning()
        local t = tonumber(((readText(modDir() .. "net_status.txt") or ""):match("time=(%d+)")))
        return t ~= nil and os.time() - t <= RELAY_FRESH_S
    end

    local function exists(path)
        local f = io.open(path, "rb")
        if f then
            f:close()
        end
        return f ~= nil
    end

    local function startRelay()
        -- Relay = Auto (default): the native relay (relay\pbzcoop_relay.exe, no Python needed) when it's installed,
        -- else the Python one. Native / Python force one. Both speak the same protocol, so the two players may differ.
        local choice = (settings.relay or "auto"):lower()
        local native = modRoot() .. "relay/pbzcoop_relay.exe"
        local relay = modRoot() .. "relay/pbzcoop_net.py"
        local useNative = choice ~= "python" and exists(native)
        if choice == "native" and not useNative then
            log("PhantomPact.ini: Relay = Native but " .. native .. " isn't installed; using the Python relay.")
        end
        if not useNative and not exists(relay) then
            log("Relay not found at " .. relay .. ". Reinstall Phantom Pact.")
            return false
        end
        local args = string.format('%s --dir "%s" --port %d --alive-file "%s"', modRole, modDir(), port, alivePath)
        if network == "steam" then
            -- The game's own steam_api64.dll sits next to PBZ.exe, three folders above ue4ss\Mods\PBZCoop.
            args = args .. string.format(' --transport steam --partner %s --steam-dll "%s"', partner,
                modRoot() .. "../../../steam_api64.dll")
        else
            if modRole == "client" then
                args = args .. ' --peer ' .. hostAddress
            end
            if network == "direct" then
                args = args .. ' --allow any'
                if modRole == "host" and (settings.upnp or "on"):lower() ~= "off" then
                    args = args .. ' --upnp'
                end
            end
        end
        local ok, kind
        if useNative then
            -- A Windows-subsystem program: no console window. "start" returns at once, so the game doesn't wait.
            ok = os.execute(string.format('start "" "%s" %s', native, args))
            kind = "native relay"
        else
            -- pyw/pythonw: Python without a console window. The py launcher comes with python.org installs; plain
            -- pythonw covers the rest.
            local py = string.format('-I "%s" %s', relay, args)
            ok = os.execute(string.format('where pyw >nul 2>nul && (start "" pyw -3 %s) || (where pythonw >nul 2>nul && start "" pythonw %s)',
                py, py))
            kind = "Python relay"
            if not ok then
                log("Couldn't start the relay: Python 3 wasn't found. Install it from python.org (tick \"Add python to PATH\") and restart the game.")
                return false
            end
        end
        if not ok then
            log("Couldn't start the native relay (" .. native .. ").")
            return false
        end
        log(kind .. " started as " .. role .. (modRole == "client" and (", joining " .. hostAddress) or "") .. " on UDP " .. port .. ".")
        return true
    end

    if relayRunning() then
        log("A relay is already running; using it.")
    elseif not startRelay() then
        return
    end

    -- Sync on once the player is in the world.
    local on = false
    LoopAsync(2000, function()
        if on then
            return true
        end
        ExecuteInGameThread(function()
            if on then
                return
            end
            local _, pawn = getPlayer1()
            if valid(pawn) then
                on = true
                neton(modRole)
                log("Phantom Pact " .. (modRole == "host" and "Host" or "Guest") .. ": co-op on.")
                if api.scaling and (tonumber(settings.coopenemyhealth) or tonumber(settings.coopenemyposture)) then
                    api.scaling.command(string.format("%d %d", tonumber(settings.coopenemyhealth) or 150,
                        tonumber(settings.coopenemyposture) or 130))
                end
                if api.sync then
                    api.sync.codex = (settings.sharecodex or "on"):lower() ~= "off"
                    api.sync.set((settings.shareprogress or "on"):lower() ~= "off")
                end
                if (settings.pvp or ""):lower() == "on" and api.pvp then
                    if tonumber(settings.pvpdamage) then
                        api.pvp.command("damage " .. settings.pvpdamage)
                    end
                    if tonumber(settings.pvpparryposture) then
                        api.pvp.command("parry " .. settings.pvpparryposture)
                    end
                    api.pvp.set(true)
                end
            end
        end)
        return false
    end)
end
