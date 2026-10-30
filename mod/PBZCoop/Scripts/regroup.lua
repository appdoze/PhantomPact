-- Regroup and revive (fork extras; PhantomPact.ini RegroupKey, ReviveAtPartner, RegroupOnJoin).
--
-- Regroup (RegroupKey, F5 by default, or the "regroup" command): teleports you to where your partner stands with the
-- game's own teleport (PerformanceSystemSubsystem.TeleportToTargetPoint, checked in game). Only inside the area
-- you're both in (never loads another level, so it can't skip ahead in the story), and not while you or your
-- partner is down, either of you is in a cutscene, PvP is on, or the partner is silent. You land on your partner's
-- own position (where they stand), not on a computed point.
--
-- Revive (ReviveAtPartner = On): while your partner is down, the regroup key revives them ("Y" with your position).
-- Their game's revive point (PBZGameSystem.SetReviveTransform, read / set / restored in game) moves to your side for
-- that one revival, so the game's own respawn brings them back next to you; their own point is put back afterwards.
--
-- Regroup on join (RegroupOnJoin = On): a guest joining more than 150 m from the host in the same area is taken to
-- them once.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local POLL_TICKS = 30           -- 16 ms ticks between checks (~0.5 s)
    local FRESH_S = 3.0             -- a partner position older than this is stale
    local COOLDOWN_S = 10.0
    local FAR_CM = 15000            -- regroup on join: further than this
    local REVIVE_WINDOW_S = 180     -- a revive request waits this long for the downed player to be back
    local REVIVE_DELAY_S = 1.5
    local NEAR_CM = 3000            -- revived this close to the partner = the game used the revive point

    local regroup = {
        key = "F5",
        enabled = true,
        revive = true,
        joinRegroup = true,
        lastRegroup = -math.huge,
        joined = false,
        selfZero = 0,
        selfDown = false,
        reviveAt = nil,
        reviveOrig = nil,
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
        return net.enabled and net.target ~= nil and net.lastRemoteAt ~= nil and not net.partnerGone
            and os.clock() - net.lastRemoteAt <= FRESH_S
    end

    local function down(hp, maxhp)
        return maxhp and maxhp > 0 and hp and hp <= 0
    end

    local function selfState()
        local _, pawn = api.getPlayer1()
        if not valid(pawn) then
            return nil
        end
        local hp, maxhp = nil, nil
        if game.getHealth then
            hp, maxhp = game.getHealth(pawn)
        end
        return pawn, hp, maxhp
    end

    -- Why a regroup can't happen now, or nil.
    function regroup.refusal()
        if not fresh() then
            return "no recent position from your partner"
        end
        local t = net.target
        local pawn, hp, maxhp = selfState()
        if not pawn then
            return "you're not in the world"
        end
        if down(hp, maxhp) or net.deadSince then
            return "you're down"
        end
        if net.pvp then
            return "PvP is on"
        end
        if t.Cine or (game.inCutscene and game.inCutscene()) then
            return "a cutscene is playing"
        end
        if not t.Map or t.Map == "?" or t.Map ~= net.localMap then
            return "your partner is in another area"
        end
        if not (t.X and t.Y and t.Z) or t.X ~= t.X or t.Y ~= t.Y or t.Z ~= t.Z
            or math.abs(t.X) > 2e7 or math.abs(t.Y) > 2e7 or math.abs(t.Z) > 2e7 then
            return "your partner's position isn't usable"
        end
        return nil
    end

    local function teleportTo(x, y, z, yawDeg, map)
        local perf = FindFirstOf("PerformanceSystemSubsystem")
        if not valid(perf) then
            return false, "no teleport subsystem"
        end
        local yaw = math.rad(yawDeg or 0)
        local transform = {
            Rotation = { X = 0.0, Y = 0.0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
            Translation = { X = x, Y = y, Z = z },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        return pcall(function() perf:TeleportToTargetPoint(transform, FName(map)) end)
    end

    function regroup.regroup(force)
        if not regroup.enabled then
            return
        end
        local t = net.target
        -- Partner down: the same key revives them at your side.
        if fresh() and down(t.Hp, t.MaxHp) then
            if not regroup.revive then
                tip("regroup", "your partner is down.")
                return
            end
            local pawn = selfState()
            local l = pawn and pawn:K2_GetActorLocation()
            if l and not net.pvp then
                coop.sendEvent("Y", string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z),
                    net.localMap or "?")
                tip("regroup", "revive sent: your partner gets back up at your side.")
            end
            return
        end
        local why = regroup.refusal()
        if why then
            tip("regroup", "regroup: " .. why .. ".")
            return
        end
        local now = os.clock()
        if not force and now - regroup.lastRegroup < COOLDOWN_S then
            tip("regroup", "regroup: wait a few seconds.")
            return
        end
        regroup.lastRegroup = now
        local ok, err = teleportTo(t.X, t.Y, t.Z, t.Yaw, net.localMap)
        if ok then
            tip("regroup", "regrouping with your partner.")
        else
            log("Regroup failed: " .. tostring(err))
        end
    end

    -- Revive: the game's revive point, read, moved to the reviver, and put back after the revival.
    local function gameSystem()
        local gs = FindFirstOf("PBZGameSystem")
        return valid(gs) and gs or nil
    end

    local function restoreRevivePoint()
        local orig, gs = regroup.reviveOrig, gameSystem()
        regroup.reviveOrig = nil
        if orig and gs then
            pcall(function() gs:SetReviveTransform(orig) end)
        end
    end

    coop.handlers.Y = function(rest)
        if not regroup.revive or net.pvp then
            return
        end
        local x, y, z, map = (rest or ""):match("^(%S+) (%S+) (%S+) (%S+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local gs = gameSystem()
        if not (gs and x and y and z and x == x and y == y and z == z and map == net.localMap
            and math.abs(x) < 2e7 and math.abs(y) < 2e7 and math.abs(z) < 2e7) then
            return
        end
        regroup.reviveAt = os.clock()
        pcall(function()
            if not regroup.reviveOrig then
                local t, cam = {}, {}
                gs:GetReviveTransform(t, cam)
                regroup.reviveOrig = {
                    Translation = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
                    Rotation = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
                    Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
                }
            end
            gs:SetReviveTransform({ Translation = { X = x + 0.0, Y = y + 0.0, Z = z + 50.0 },
                Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } })
        end)
        tip("revive", "your partner is reviving you: you'll get back up at their side.")
    end

    -- Our own death and revival; and a revive request that expired is undone.
    local function watchSelf()
        local _, hp, maxhp = selfState()
        if regroup.reviveAt and os.clock() - regroup.reviveAt > REVIVE_WINDOW_S then
            regroup.reviveAt = nil
            restoreRevivePoint()
        end
        if not (hp and maxhp and maxhp > 0) then
            return
        end
        if hp <= 0 then
            regroup.selfZero = regroup.selfZero + 1
            regroup.selfDown = regroup.selfDown or regroup.selfZero >= 2
            return
        end
        regroup.selfZero = 0
        if not regroup.selfDown then
            return
        end
        regroup.selfDown = false
        if regroup.reviveAt and game.after then
            regroup.reviveAt = nil
            game.after(REVIVE_DELAY_S, function()
                ExecuteInGameThread(function()
                    restoreRevivePoint()
                    local t = net.target
                    local pawn = selfState()
                    local l = pawn and pawn:K2_GetActorLocation()
                    local near = t and l and t.Map == net.localMap and math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2) < NEAR_CM
                    tip("self", "revived at your partner's side.")
                    if not near then
                        regroup.regroup(true)
                    end
                end)
            end)
        end
    end

    -- A guest joining far from the host in the same area is taken to them once.
    local function joinCheck()
        if not fresh() then
            if not net.enabled then
                regroup.joined = false
            end
            return
        end
        if regroup.joined then
            return
        end
        regroup.joined = true
        if not regroup.joinRegroup or coop.isHost() then
            return
        end
        local t = net.target
        local pawn = selfState()
        if pawn and t.Map == net.localMap then
            local l = pawn:K2_GetActorLocation()
            if math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2) > FAR_CM and not regroup.refusal() then
                tip("regroup", "joined your partner's session: taking you to them.")
                regroup.regroup(true)
            end
        end
    end

    coop.extraTicks.regroup = function()
        ticks = ticks + 1
        if ticks % POLL_TICKS == 0 and net.enabled then
            local ok, err = pcall(function()
                joinCheck()
                watchSelf()
            end)
            if not ok then
                log("regroup check failed: " .. tostring(err))
            end
        end
    end

    function regroup.bindKey(name)
        name = (name or "F5"):upper()
        if name == "OFF" or name == "" then
            return
        end
        if Key == nil or Key[name] == nil then
            log("PhantomPact.ini: RegroupKey = " .. name .. " isn't a key UE4SS knows; using F5.")
            name = "F5"
        end
        regroup.key = name
        RegisterKeyBind(Key[name], function()
            ExecuteInGameThread(function() regroup.regroup() end)
        end)
    end

    return regroup
end
