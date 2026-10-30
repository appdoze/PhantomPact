-- In-game connection status: the relay's net_status.txt turned into short tips at the bottom of the screen, in the
-- game's own ink-bar tip widget (WB_TipsText, the one behind "This door doesn't open from this side").
--
-- Shown when something changes: partner connected / lost, settings that differ between the two PCs (from the
-- relay's hello exchange), relay errors (Direct without a Secret, Steam unavailable), packets refused because the
-- Secrets differ, a lasting high ping, and an untested game build. Also keeps net.rttMs for the ghost's prediction.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_TICKS = 60           -- 16 ms ticks between status reads (~1 s)
    local SHOW_S = 4.0              -- how long a tip stays
    local HIGH_PING_MS = 250        -- warn when the round trip stays above this...
    local HIGH_PING_FOR = 5         -- ...for this many reads in a row
    local REPEAT_S = 60             -- the same warning at most once a minute

    local status = { on = true, last = {}, lastShown = {}, highPingReads = 0 }
    local ticks = 0
    local tip

    local function show(text)
        log("Status: " .. text)
        if not status.on then
            return
        end
        pcall(function()
            if not valid(tip) then
                local sample = FindFirstOf("WB_TipsText_C")
                local pc = FindFirstOf("PlayerController")
                if not (valid(sample) and valid(pc)) then
                    return
                end
                tip = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, sample:GetClass(), pc)
                tip:AddToViewport(400)
            end
            tip:SetVisibility(3)                    -- HitTestInvisible: seen, never clicked
            tip:SetText(FText("Phantom Pact: " .. text))
            pcall(function() tip:PlayAnimation(tip.FadeIn, 0, 1, 0, 1, false) end)
            local shown = tip
            if game.after then
                game.after(SHOW_S, function()
                    if valid(shown) and shown == tip then
                        pcall(function() shown:SetVisibility(1) end)   -- collapsed
                    end
                end)
            end
        end)
    end

    -- A message at most once per REPEAT_S per key, unless it changed.
    local function notify(key, text)
        local now = os.clock()
        local prev = status.lastShown[key]
        if prev and prev.text == text and now - prev.at < REPEAT_S then
            return
        end
        status.lastShown[key] = { text = text, at = now }
        show(text)
    end

    local function readStatus()
        local f = io.open(api.modDir() .. "net_status.txt", "r")
        if not f then
            return nil
        end
        local text = f:read("a") or ""
        f:close()
        local kv = {}
        for k, v in text:gmatch("(%w+)=(%S+)") do
            kv[k] = v
        end
        return kv
    end

    local function poll()
        if not net.enabled then
            status.last = {}
            return
        end
        local s = readStatus()
        if s == nil then
            return
        end
        local last = status.last
        net.rttMs = tonumber(s.rtt_ms)

        if s.error == "direct-needs-secret" and last.error ~= s.error then
            notify("error", "Direct needs the same Secret in PhantomPact.ini on both PCs.")
        elseif s.error == "steam-init" and last.error ~= s.error then
            notify("error", "Steam networking unavailable (is Steam running?).")
        end

        if s.connected == "yes" and last.connected ~= "yes" then
            notify("conn", "partner connected" .. (net.rttMs and string.format(" (ping %d ms)", net.rttMs) or "") ..
                (s.auth == "aes-gcm" and ", encrypted" or (s.auth == "hmac" and ", signed" or "")))
        elseif s.connected == "no" and last.connected == "yes" then
            notify("conn", "partner disconnected.")
        end

        if s.mismatch and s.mismatch ~= "-" and s.mismatch ~= last.mismatch then
            notify("mismatch", "settings differ from your partner's: " .. s.mismatch:gsub(",", ", "))
        end

        local rejected = tonumber(s.rejected) or 0
        if rejected > (tonumber(last.rejected) or 0) and s.connected ~= "yes" then
            notify("secret", "packets refused: check that both PCs use the same Secret.")
        end

        if net.rttMs and net.rttMs > HIGH_PING_MS then
            status.highPingReads = status.highPingReads + 1
            if status.highPingReads == HIGH_PING_FOR then
                notify("ping", string.format("high ping (%d ms). On Tailscale, run \"tailscale ping\": via DERP "
                    .. "means relayed.", net.rttMs))
            end
        else
            status.highPingReads = 0
        end
        status.last = s
    end

    coop.extraTicks.status = function()
        ticks = ticks + 1
        if ticks % POLL_TICKS == 0 then
            poll()
        end
        if ticks == POLL_TICKS and api.gameBuildWarning then
            notify("build", api.gameBuildWarning)
        end
    end

    status.notify = notify          -- other modules' tips (sync, partner), same once-a-minute rule

    function status.command(args)
        local a = (args or ""):lower()
        if a == "on" or a == "off" then
            status.on = a == "on"
            log("In-game status tips " .. a .. ".")
        elseif a ~= "" then
            show(args)                              -- "status <text>": test the tip
        else
            local s = readStatus() or {}
            log("Relay: connected=" .. tostring(s.connected) .. " rtt_ms=" .. tostring(s.rtt_ms) .. " auth="
                .. tostring(s.auth) .. " mismatch=" .. tostring(s.mismatch))
        end
    end

    return status
end
