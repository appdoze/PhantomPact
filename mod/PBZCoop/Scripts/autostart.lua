-- Phantom Pact auto-start: reads PhantomPact.ini, starts the network relay (net/pbzcoop_net.py, with the
-- player's own Python) when the game starts, and turns online sync on once the player is in gameplay.
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
    if modRole == "client" and (hostAddress == "" or hostAddress == placeholder or not hostAddress:match("^[%w%.%-:]+$")) then
        log("PhantomPact.ini: Role = Guest but HostAddress isn't set. Put the host's Tailscale IP there and restart the game.")
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
        local args = string.format('-I "%s" %s --dir "%s" --port %d --alive-file "%s"', relay,
            modRole, modDir(), port, alivePath)
        if modRole == "client" then
            args = args .. ' --peer ' .. hostAddress
        end
        -- pyw/pythonw: Python without a console window. The py launcher comes with python.org installs; plain
        -- pythonw covers the rest. "start" returns at once, so the game doesn't wait.
        local cmd = string.format('where pyw >nul 2>nul && (start "" pyw -3 %s) || (where pythonw >nul 2>nul && start "" pythonw %s)',
            args, args)
        local ok = os.execute(cmd)
        if not ok then
            log("Couldn't start the relay: Python 3 wasn't found. Install it from python.org (tick \"Add python to PATH\") and restart the game.")
            return false
        end
        log("Relay started as " .. role .. (modRole == "client" and (", joining " .. hostAddress) or "") .. " on UDP " .. port .. ".")
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
            end
        end)
        return false
    end)
end
