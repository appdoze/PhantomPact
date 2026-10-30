-- In-game connection status: the relay's net_status.txt turned into short tips at the bottom of the screen, in the
-- game's own ink-bar tip widget (WB_TipsText, the one behind "This door doesn't open from this side").
-- (From appdoze's PR #2; the tip is re-created after map travel, which removes it from the screen.)
--
-- Shown when something changes: partner connected / lost, settings that differ between the two PCs (the relays'
-- hello exchange), packets refused because the Secrets differ, a lasting high ping, and an untested game build.
-- Also keeps net.rttMs for the ghost's prediction (coop.lua).

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_S = 1.0              -- status reads
    local SHOW_S = 4.0              -- how long a tip stays
    local HIGH_PING_MS = 250        -- warn when the round trip stays above this...
    local HIGH_PING_FOR = 5         -- ...for this many reads in a row
    local REPEAT_S = 60             -- the same warning at most once a minute
    local TIP_CLASS = "/Game/PBZContent/UI/InGame/SwitchUI/WB_TipsText.WB_TipsText_C"

    local status = { on = true, last = {}, lastShown = {}, highPingReads = 0, buildShown = false }
    local nextPoll = 0
    local tip

    local function show(text)
        log("Status: " .. text)
        if not status.on then
            return
        end
        pcall(function()
            local onScreen = valid(tip) and select(2, pcall(function() return tip:IsInViewport() end)) == true
            if not onScreen then
                -- Made from the widget's class: copying an instance on screen (as first written) found none until
                -- the game had shown a tip itself, so tips never appeared.
                local cls = FindObject("WidgetBlueprintGeneratedClass", "WB_TipsText_C")
                if not valid(cls) then
                    cls = StaticFindObject(TIP_CLASS)
                end
                if not valid(cls) and type(LoadAsset) == "function" then
                    pcall(LoadAsset, TIP_CLASS)
                    cls = StaticFindObject(TIP_CLASS)
                end
                local pc = api.getPlayer1()
                if not (valid(cls) and valid(pc)) then
                    return
                end
                tip = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
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
        for k, v in text:gmatch("([%w_]+)=(%S+)") do
            kv[k] = v
        end
        return kv
    end

    local function poll()
        local s = readStatus()
        if s == nil then
            return
        end
        local last = status.last
        net.rttMs = tonumber(s.rtt_ms)

        if s.connected == "yes" and last.connected ~= "yes" then
            notify("conn", "partner connected" .. (net.rttMs and string.format(" (ping %d ms)", net.rttMs) or "")
                .. (s.auth == "on" and ", signed" or "") .. ".")
        elseif s.connected == "no" and last.connected == "yes" then
            notify("conn", "partner disconnected.")
        end

        if s.mismatch and s.mismatch ~= "-" and s.mismatch ~= last.mismatch then
            notify("mismatch", "settings differ from your partner's: " .. s.mismatch:gsub(",", ", "))
        end

        local rejected = tonumber(s.rejected) or 0
        if rejected > (tonumber(last.rejected) or 0) and s.connected ~= "yes" then
            notify("secret", "packets refused: both PCs need the same Secret in PhantomPact.ini (or both none).")
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
        local now = os.clock()
        if now < nextPoll then
            return
        end
        nextPoll = now + POLL_S
        poll()
        if api.gameBuildWarning and not status.buildShown then
            status.buildShown = true
            notify("build", api.gameBuildWarning)
        end
    end

    status.notify = notify          -- other modules' tips (partner.lua)

    -- tips on|off, tips <text> (show a test tip), tips (print the relay's status)
    function status.command(args)
        local a = (args or ""):lower()
        if a == "on" or a == "off" then
            status.on = a == "on"
            log("In-game status tips " .. a .. ".")
        elseif a ~= "" then
            show(args)
        else
            local s = readStatus() or {}
            log("Relay: connected=" .. tostring(s.connected) .. " rtt_ms=" .. tostring(s.rtt_ms) .. " auth="
                .. tostring(s.auth) .. " mismatch=" .. tostring(s.mismatch) .. " rejected=" .. tostring(s.rejected))
        end
    end

    return status
end
