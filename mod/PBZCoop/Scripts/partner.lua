-- Staying together: regroup with your partner, and know how they're doing.
--
-- Regroup (PhantomPact.ini RegroupKey, F5 by default, or the "regroup" command): teleports you next to your
-- partner with the game's own teleport (PerformanceSystemSubsystem.TeleportToTargetPoint, the one that takes you
-- from one area to another), so it works across areas and gets you past a gate only your partner has opened.
--
-- Revive: while your partner is down, the regroup key revives them ("Y" event, with your position). Their game's
-- revive point (PBZGameSystem.SetReviveTransform, checked in game) is set to your side, so the game's own revival
-- brings them back right next to you instead of at their bell; their own revive point is put back afterwards. If
-- the game revived them elsewhere anyway, they're teleported to you.
--
-- Dialogue: lines your character hears in a conversation (the game's PBZEventPipelineDialogWidget, its
-- DialogueData.Text) are sent as "T <text>" and shown to your partner as tips.
--
-- Tips (the game's ink-bar tip, see status.lua): partner down, partner back, partner's health getting low,
-- partner watching a cutscene, the two of you far apart, and after you respawn, a reminder that regroup takes you
-- back.

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
    local REVIVE_WINDOW_S = 180     -- a revive request waits this long for the downed player to be back
    local REVIVE_DELAY_S = 1.5      -- after getting up, before the teleport (the respawn settles first)
    local DIALOGUE_TICKS = 15       -- ~0.25 s between dialogue checks
    local DIALOGUE_MAX = 200        -- characters of a line sent

    local partner = {
        key = "F5",
        lastRegroup = -math.huge,
        partnerDown = false,
        partnerZero = 0,            -- checks in a row at 0 health (one bad read during a teleport isn't "down")
        selfDown = false,
        selfZero = 0,
        lowShown = 1,
        far = false,
        partnerCine = false,
        reviveAt = nil,             -- when the partner asked to revive us (os.clock)
        joinRegroup = true,         -- guest: regroup with the host when the session starts far apart
        joined = false,
        lastLine = nil,             -- last dialogue line sent
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

    function partner.regroup(force)
        if not fresh() then
            tip("regroup", "regroup: no position from your partner yet (connected?).")
            return
        end
        local t = net.target
        if t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0 then
            -- Partner down: the same key revives them at your side.
            local _, me = api.getPlayer1()
            local l = valid(me) and me:K2_GetActorLocation()
            if l then
                coop.sendEvent("Y", string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z),
                    net.localMap or "?")
            else
                coop.sendEvent("Y")
            end
            tip("regroup", "revive sent: your partner comes back to you once they're on their feet.")
            return
        end
        if not t.Map or t.Map == "?" then
            tip("regroup", "regroup: your partner's area isn't known yet.")
            return
        end
        local now = os.clock()
        if not force and now - partner.lastRegroup < COOLDOWN_S then
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

    -- Guest joining far from the host (other area, or more than FAR_CM away): brought to the host once.
    local function joinCheck()
        if partner.joined or not fresh() then
            return
        end
        partner.joined = true
        if not partner.joinRegroup or coop.isHost() then
            return
        end
        local t = net.target
        local _, pawn = api.getPlayer1()
        if not (valid(pawn) and t.Map) then
            return
        end
        local l = pawn:K2_GetActorLocation()
        local far = t.Map ~= net.localMap or math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2) > FAR_CM
        if far then
            tip("regroup", "joined your partner's session: taking you to them.")
            partner.regroup(true)
        end
    end

    -- Down after two checks in a row at 0 health; back when health returns.
    local function watchPartner()
        if not fresh() then
            if not net.enabled then
                partner.joined = false
            end
            return
        end
        joinCheck()
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
        if t.Cine ~= partner.partnerCine then
            partner.partnerCine = t.Cine
            if t.Cine then
                tip("cine", "your partner is watching a cutscene.")
            end
        end
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
                if partner.reviveAt and os.clock() - partner.reviveAt <= REVIVE_WINDOW_S and game.after then
                    partner.reviveAt = nil
                    game.after(REVIVE_DELAY_S, function()
                        ExecuteInGameThread(function()
                            partner.restoreRevivePoint()
                            -- Revived at the partner's side by the game itself; if not, teleport there.
                            local t = net.target
                            local _, me = api.getPlayer1()
                            local l = valid(me) and me:K2_GetActorLocation()
                            local near = t and l and t.Map == net.localMap
                                and math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2) < 3000
                            tip("self", "revived: back at your partner's side.")
                            if not near then
                                partner.regroup(true)
                            end
                        end)
                    end)
                elseif fresh() then
                    tip("self", "you're back: " .. partner.key .. " regroups you with your partner.")
                end
            end
        end
    end

    -- The game's revive point: read, set to the reviver's side, and put back after the revival.
    local function gameSystem()
        local gs = FindFirstOf("PBZGameSystem")
        return valid(gs) and gs or nil
    end

    function partner.restoreRevivePoint()
        local orig = partner.reviveOrig
        partner.reviveOrig = nil
        local gs = gameSystem()
        if orig and gs then
            pcall(function() gs:SetReviveTransform(orig) end)
        end
    end

    coop.handlers.Y = function(rest)
        partner.reviveAt = os.clock()
        local x, y, z, map = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local gs = gameSystem()
        if gs and x and x == x and y and z and map == net.localMap then
            pcall(function()
                if not partner.reviveOrig then
                    local t, cam = {}, {}
                    gs:GetReviveTransform(t, cam)
                    partner.reviveOrig = {
                        Translation = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
                        Rotation = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
                        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
                    }
                end
                gs:SetReviveTransform({ Translation = { X = x + 0.0, Y = y + 0.0, Z = z + 50.0 },
                    Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } })
            end)
        end
        tip("revive", "your partner is reviving you: you'll get back up at their side.")
    end

    -- Dialogue: the line in a visible dialogue widget, sent once each.
    local function watchDialogue()
        local line
        for _, w in ipairs(FindAllOf("PBZEventPipelineDialogWidget") or {}) do
            if valid(w) and w:IsVisible() then
                local ok, text = pcall(function() return w.DialogueData.Text:ToString() end)
                if ok and text and text:match("%S") then
                    line = text
                    break
                end
            end
        end
        if line and line ~= partner.lastLine then
            local clean = line:gsub("[%c]+", " "):sub(1, DIALOGUE_MAX)
            coop.sendEvent("T", clean)
        end
        partner.lastLine = line
    end

    coop.handlers.T = function(text)
        if text and text:match("%S") then
            tip("dialogue", "(partner's dialogue) " .. text:sub(1, DIALOGUE_MAX))
        end
    end

    coop.extraTicks.partner = function()
        ticks = ticks + 1
        if ticks % DIALOGUE_TICKS == 0 and net.enabled then
            local ok, err = pcall(watchDialogue)
            if not ok then
                log("dialogue check failed: " .. tostring(err))
            end
        end
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
