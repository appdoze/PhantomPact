-- Phantom Pact auto-start: reads PhantomPact.ini, starts the network relay (net/pbzcoop_net.py, with the
-- Python bundled in PBZCoop\python, else the player's own) when the game starts, and turns online sync on once the player is in gameplay.
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

    -- Game builds this version was tested on, by PBZ.exe size (instant to read; hashing a 500 MB exe isn't).
    -- Another build still runs, with a warning: function and field names may have changed. (From appdoze's PR #2.)
    local KNOWN_BUILDS = {
        [511072344] = "Steam build 26266538",
    }
    pcall(function()
        local f = io.open(modRoot() .. "../../../PBZ.exe", "rb")
        if not f then
            return
        end
        local size = f:seek("end")
        f:close()
        if KNOWN_BUILDS[size] then
            log("Game build: " .. KNOWN_BUILDS[size] .. " (tested).")
        else
            api.gameBuildWarning = "this game update isn't tested with this Phantom Pact version; some co-op "
                .. "features may fail."
            log("WARNING: this game build (PBZ.exe " .. tostring(size) .. " bytes) wasn't tested with Phantom Pact "
                .. tostring(api.version) .. ". Co-op may partly fail; check for a Phantom Pact update.")
        end
    end)

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
    if api.hud then
        api.hud.set((settings.partnercompass or "on"):lower() ~= "off")
    end
    if api.mapicon then
        api.mapicon.on = (settings.partnermapicon or "on"):lower() ~= "off"
    end
    local role = (settings.role or "off"):lower()
    local modRole = ({ host = "host", guest = "client" })[role]
    if not modRole then
        log("PhantomPact.ini: Role = " .. tostring(settings.role) .. ", co-op is off.")
        return
    end
    local port = tonumber(settings.port) or 47800
    -- Connect = Steam (P2P through Steam, friends only) or Tailscale (UDP to the host's IP). Old inis have no
    -- Connect line and keep working over Tailscale.
    local steam = (settings.connect or "tailscale"):lower() == "steam"
    local hostAddress = settings.hostaddress or ""
    if hostAddress == placeholder then
        hostAddress = ""
    end
    if steam then
        -- Optional for Steam: the host's Steam name (or SteamID64); empty finds any friend hosting in the game.
        -- Names go on the command line in quotes, so characters cmd.exe treats specially are refused.
        if hostAddress:find('[%"%%&|<>^]') then
            log("PhantomPact.ini: HostAddress has a character that can't be used (\" % & | < > ^). Leave it empty to join any friend who's hosting.")
            return
        end
    elseif modRole == "client" and (hostAddress == "" or not hostAddress:match("^[%w%.%-:]+$")) then
        log("PhantomPact.ini: Role = Guest but HostAddress isn't set. Put the host's Tailscale IP there (or use Connect = Steam) and restart the game.")
        return
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

    local function startRelay()
        local relay = modRoot() .. "relay/pbzcoop_net.py"
        local f = io.open(relay, "r")
        if not f then
            log("Relay not found at " .. relay .. ". Reinstall Phantom Pact.")
            return false
        end
        f:close()
        -- --ini: the relay reads the Secret (if any) and the settings both players should share from the ini
        -- itself, so the secret never appears on a command line.
        local args = string.format('-I "%s" %s --dir "%s" --port %d --alive-file "%s" --ini "%s" --mod-version %s',
            relay, modRole, modDir(), port, alivePath, modDir() .. "PhantomPact.ini", api.version or "?")
        if steam then
            args = args .. ' --transport steam'
        end
        if modRole == "client" and hostAddress ~= "" then
            args = args .. ' --peer "' .. hostAddress .. '"'
        end
        -- pythonw: Python without a console window. The release zip carries Python's own embeddable build in
        -- PBZCoop\python, so players install nothing; without it, the player's Python (the py launcher from
        -- python.org installs, else pythonw on PATH). "start" returns at once, so the game doesn't wait.
        local bundled = (modRoot() .. "python/pythonw.exe"):gsub("/", "\\")
        local cmd
        local f = io.open(bundled, "rb")
        local which = f and "bundled Python" or "your Python"
        if f then
            f:close()
            cmd = string.format('start "" "%s" %s', bundled, args)
        else
            cmd = string.format('where pyw >nul 2>nul && (start "" pyw -3 %s) || (where pythonw >nul 2>nul && start "" pythonw %s)',
                args, args)
        end
        local ok = os.execute(cmd)
        if not ok then
            log("Couldn't start the relay: Python wasn't found. Reinstall Phantom Pact (the zip includes it) and restart the game.")
            return false
        end
        local joining = modRole ~= "client" and ""
            or hostAddress ~= "" and (", joining " .. hostAddress)
            or ", looking for a Steam friend who's hosting"
        local secret = settings.secret or ""
        local signed = secret ~= "" and not secret:upper():find("^PUT%-") and secret:lower() ~= "off"
        log("Relay started as " .. role .. joining .. (steam and " over Steam" or (" on UDP " .. port))
            .. (signed and ", packets signed (Secret set)" or "") .. " (" .. which .. ").")
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
