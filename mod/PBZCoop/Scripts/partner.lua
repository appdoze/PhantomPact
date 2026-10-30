-- How your partner is doing, as short tips (the game's ink-bar tip, see status.lua): partner down, partner back,
-- partner's health getting low, partner watching a cutscene, and the two of you far apart in the same area.
-- (From appdoze's PR #5, without its regroup teleport, which stays deferred: see docs/reviews.)
-- Each player's death and respawn stay their own game's; there is no revive. Spectating is in coop.lua.

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local POLL_S = 0.5
    local FRESH_S = 3.0             -- a partner position older than this is stale
    local FAR_CM = 15000            -- "far apart" above 150 m (same area)
    local LOW = { 0.5, 0.25 }       -- partner health tips at these fractions

    local partner = { down = false, zeroReads = 0, lowShown = 1, far = false, cine = false }
    local nextPoll = 0

    local function tip(key, text)
        if api.status and api.status.notify then
            api.status.notify(key, text)
        else
            log(text)
        end
    end

    local function fresh()
        return net.enabled and not net.partnerGone and net.target ~= nil and net.lastRemoteAt ~= nil
            and os.clock() - net.lastRemoteAt <= FRESH_S
    end

    -- Down after two reads in a row at 0 health (one bad read during a teleport isn't "down"); back when health
    -- returns.
    local function check()
        if not fresh() then
            return
        end
        local t = net.target
        if not (t.MaxHp and t.MaxHp > 0 and t.Hp) then
            return
        end
        if t.Hp <= 0 then
            partner.zeroReads = partner.zeroReads + 1
            if partner.zeroReads >= 2 and not partner.down then
                partner.down = true
                tip("partner", "your partner is down.")
            end
            return
        end
        partner.zeroReads = 0
        if partner.down then
            partner.down = false
            partner.lowShown = 1
            tip("partner", "your partner is back.")
            return
        end
        if t.Cine ~= partner.cine then
            partner.cine = t.Cine
            if t.Cine then
                tip("cine", "your partner is watching a cutscene.")
            end
        end
        local frac = t.Hp / t.MaxHp
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
        -- Far apart in the same area: one tip each time you drift apart.
        local _, pawn = api.getPlayer1()
        if valid(pawn) and t.Map ~= nil and t.Map == net.localMap then
            local l = pawn:K2_GetActorLocation()
            local d = math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2)
            local far = d > FAR_CM
            if far and not partner.far then
                tip("far", string.format("your partner is %d m away.", math.floor(d / 100)))
            end
            partner.far = far
        end
    end

    coop.extraTicks.partner = function()
        local now = os.clock()
        if now < nextPoll then
            return
        end
        nextPoll = now + POLL_S
        check()
    end

    -- partner: print what the mod knows about your partner
    function partner.command()
        local t = net.target
        if not fresh() then
            log("Partner: no recent position" .. (net.partnerGone and " (gone)." or "."))
            return
        end
        log(string.format("Partner: %s, health %s/%s, area %s%s%s", partner.down and "down" or "up", tostring(t.Hp),
            tostring(t.MaxHp), tostring(t.Map), t.Map == net.localMap and " (same as yours)" or "",
            t.Cine and ", in a cutscene" or ""))
    end

    return partner
end
