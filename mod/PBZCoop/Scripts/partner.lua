-- Staying together: regroup with your partner, and know how they're doing.
--
-- Regroup (PhantomPact.ini RegroupKey, F5 by default, or the "regroup" command): teleports you next to your
-- partner with the game's own teleport (PerformanceSystemSubsystem.TeleportToTargetPoint, the one that takes you
-- from one area to another), so it works across areas and gets you past a gate only your partner has opened.
--
-- Tips (the game's ink-bar tip, see status.lua): partner down, partner back, partner's health getting low, the
-- two of you far apart, and after you respawn, a reminder that regroup takes you back. Each player's death and
-- respawn stay their own game's: there is no revive.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_TICKS = 30           -- 16 ms ticks between checks (~0.5 s)
    local FRESH_S = 3.0             -- a partner position older than this is stale
    local COOLDOWN_S = 10.0         -- between two regroups
    local BEHIND_CM = 80            -- land a little behind the partner, not inside their ghost
    local ABOVE_CM = 50
    local FAR_CM = 15000            -- "far apart" hint above 150 m (same area)
    local LOW = { 0.5, 0.25 }       -- partner health tips at these fractions

    local partner = {
        key = "F5",
        lastRegroup = -math.huge,
        partnerDown = false,
        partnerZero = 0,            -- checks in a row at 0 health (one bad read during a teleport isn't "down")
        selfDown = false,
        selfZero = 0,
        lowShown = 1,
        far = false,
    }
    local ticks = 0

    local function tip(key, text)
        if api.status and api.status.notify then
            api.status.notify(key, text)
        else
            log(text)
        end
    end

    local function fresh()
        return net.enabled and net.target ~= nil and net.targetAt ~= nil and os.clock() - net.targetAt <= FRESH_S
    end

    function partner.regroup()
        if not fresh() then
            tip("regroup", "regroup: no position from your partner yet (connected?).")
            return
        end
        local t = net.target
        if t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0 then
            tip("regroup", "regroup: your partner is down; regroup once they're back.")
            return
        end
        if not t.Map or t.Map == "?" then
            tip("regroup", "regroup: your partner's area isn't known yet.")
            return
        end
        local now = os.clock()
        if now - partner.lastRegroup < COOLDOWN_S then
            tip("regroup", "regroup: wait a few seconds.")
            return
        end
        local _, pawn = api.getPlayer1()
        local perf = FindFirstOf("PerformanceSystemSubsystem")
        if not (valid(pawn) and valid(perf)) then
            tip("regroup", "regroup isn't available right now.")
            return
        end
        local yaw = math.rad(t.Yaw or 0)
        local transform = {
            Rotation = { X = 0.0, Y = 0.0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
            Translation = { X = t.X - math.cos(yaw) * BEHIND_CM, Y = t.Y - math.sin(yaw) * BEHIND_CM, Z = t.Z + ABOVE_CM },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        partner.lastRegroup = now
        local ok, err = pcall(function() perf:TeleportToTargetPoint(transform, FName(t.Map)) end)
        if ok then
            tip("regroup", "regrouping with your partner" .. (t.Map ~= net.localMap and " (loading their area)" or "") .. ".")
        else
            log("Regroup failed: " .. tostring(err))
            tip("regroup", "regroup failed (see the UE4SS log).")
        end
    end

    -- Down after two checks in a row at 0 health; back when health returns.
    local function watchPartner()
        if not fresh() then
            return
        end
        local t = net.target
        if not (t.MaxHp and t.MaxHp > 0 and t.Hp) then
            return
        end
        if t.Hp <= 0 then
            partner.partnerZero = partner.partnerZero + 1
            if partner.partnerZero >= 2 and not partner.partnerDown then
                partner.partnerDown = true
                tip("partner", "your partner is down.")
            end
            return
        end
        partner.partnerZero = 0
        local frac = t.Hp / t.MaxHp
        if partner.partnerDown then
            partner.partnerDown = false
            partner.lowShown = 1
            tip("partner", "your partner is back.")
            return
        end
        if frac >= 0.75 then
            partner.lowShown = 1
        end
        for _, th in ipairs(LOW) do
            if frac <= th and partner.lowShown > th then
                partner.lowShown = th
                tip("partnerhp", string.format("your partner's health: %d%%.", math.floor(frac * 100 + 0.5)))
                break
            end
        end
        -- Far apart in the same area: one hint each time you drift apart.
        local _, pawn = api.getPlayer1()
        if valid(pawn) and t.Map == net.localMap then
            local l = pawn:K2_GetActorLocation()
            local far = math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2) > FAR_CM
            if far and not partner.far then
                tip("far", string.format("your partner is %d m away: %s to regroup.",
                    math.floor(math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2) / 100), partner.key))
            end
            partner.far = far
        end
    end

    -- You died: once you're back (at a bell), regroup takes you to your partner.
    local function watchSelf()
        local _, pawn = api.getPlayer1()
        if not (valid(pawn) and game.getHealth) then
            return
        end
        local hp, maxhp = game.getHealth(pawn)
        if not (hp and maxhp and maxhp > 0) then
            return
        end
        if hp <= 0 then
            partner.selfZero = partner.selfZero + 1
            partner.selfDown = partner.selfDown or partner.selfZero >= 2
        else
            partner.selfZero = 0
            if partner.selfDown then
                partner.selfDown = false
                if fresh() then
                    tip("self", "you're back: " .. partner.key .. " regroups you with your partner.")
                end
            end
        end
    end

    coop.extraTicks.partner = function()
        ticks = ticks + 1
        if ticks % POLL_TICKS == 0 and net.enabled then
            local ok, err = pcall(function()
                watchPartner()
                watchSelf()
            end)
            if not ok then
                log("partner check failed: " .. tostring(err))
            end
        end
    end

    -- RegroupKey from PhantomPact.ini: a key name UE4SS knows (F1-F12, a letter...), or Off.
    function partner.bindKey(name)
        name = (name or "F5"):upper()
        if name == "OFF" or name == "" then
            partner.key = "the regroup command"
            return
        end
        if Key == nil or Key[name] == nil then
            log("PhantomPact.ini: RegroupKey = " .. name .. " isn't a key UE4SS knows; using F5.")
            name = "F5"
        end
        partner.key = name
        RegisterKeyBind(Key[name], function()
            ExecuteInGameThread(partner.regroup)
        end)
        log("Regroup key: " .. name .. ".")
    end

    function partner.command(args)
        if (args or ""):lower() == "regroup" then
            partner.regroup()
            return
        end
        local t = net.target
        if not fresh() then
            log("Partner: no recent position.")
            return
        end
        log(string.format("Partner: %s, health %s/%s, area %s%s", partner.partnerDown and "down" or "up",
            tostring(t.Hp), tostring(t.MaxHp), tostring(t.Map), t.Map == net.localMap and " (same as yours)" or ""))
    end

    return partner
end
