-- PvP (PhantomPact.ini "PvP = On", or the "pvp on|off" command): you and your partner can fight each other.
--
-- The defender's game decides every hit. In your world your partner's ghost is made hostile to you and replays
-- their moves, so its swings hit you through the game's own combat: block, parry (deflect), perfect dodge,
-- posture and hit reactions all work exactly as against an enemy. Your own hits on the ghost are only for show;
-- they land in your partner's world, where your ghost swings at them.
--
-- Parrying pays off like against a boss. The game's deflect leaves an attacking player unharmed, so the mod judges
-- it on the defender's side: your guard (stance) came up during your partner's swing, you were in reach, and it
-- cost you neither health nor posture (a plain block costs posture). Then your partner staggers and loses posture
-- ("V parry"), and you see their ghost stagger too.
--
-- Death decides: the loser really dies (and respawns at their bell, as after any death). A death within a few
-- seconds of your partner's last hit counts as their win ("V lose"); dying to an enemy doesn't.

return function(api)
    local log, valid, getPlayer1, game = api.log, api.valid, api.getPlayer1, api.game
    local coop = api.coop
    local net = coop.net

    local HOSTILE = 2               -- ETeamAttitude::Hostile
    local KILL_WINDOW_S = 8.0       -- a death this soon after the partner's last hit is their kill
    local PARRY_REACH_CM = 350      -- a swing from further away can't have been parried (it missed)
    local STAGGER_TAG = "CharacterState.Hitreact.State.Normal.Heavy"

    local pvp = {
        on = false,
        damage = 1.0,       -- PvPDamage / 100: scales the ghost's attack, i.e. the damage you take
        parryPosture = 60,  -- PvPParryPosture: posture a parried attacker loses
        wins = 0,
        losses = 0,
    }
    net.pvp = false

    local factionOf = {}            -- actor address -> FactionComponent
    local function faction(actor)
        local addr = actor:GetAddress()
        local c = factionOf[addr]
        if valid(c) then
            return c
        end
        for _, comp in ipairs(FindAllOf("FactionComponent") or {}) do
            local ok, owner = pcall(function() return comp:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == addr then
                factionOf[addr] = comp
                return comp
            end
        end
        return nil
    end

    local function attr(actor, name)
        local ok, a = pcall(function() return actor.AttributeSetBase[name] end)
        return ok and a or nil
    end

    local function setAttr(actor, name, value)
        pcall(function()
            local a = actor.AttributeSetBase[name]
            a.BaseValue = value
            a.CurrentValue = value
        end)
    end

    -- The ghost was spawned as an empty shell (0 health counts as dead, and the dead can't attack): give it a full
    -- stat block. It gets ours, so both fighters hit equally hard and only skill decides; PvPDamage scales it.
    local function giveGhostStats(ghost, pawn)
        local src, dst = pawn.AttributeSetBase, ghost.AttributeSetBase
        src:GetClass():ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            pcall(function()
                local a = src[name]
                if type(a) == "userdata" and a.BaseValue ~= nil then
                    dst[name].BaseValue = a.BaseValue
                    dst[name].CurrentValue = a.CurrentValue
                end
            end)
        end)
        local atk = attr(pawn, "Attack")
        if atk then
            setAttr(ghost, "Attack", atk.CurrentValue * pvp.damage)
        end
        setAttr(ghost, "Health_Min", 1)
    end

    local hostileGhost = nil        -- address of the ghost currently set hostile to us
    local function setHostile(pawn, ghost, hostile)
        local pf, gf = faction(pawn), faction(ghost)
        if not (pf and gf) then
            return false
        end
        pcall(function()
            if hostile then
                pf:SetFactionRelationOverride(ghost, HOSTILE, true)
                gf:SetFactionRelationOverride(pawn, HOSTILE, true)
            else
                pf:ClearFactionRelationOverride(ghost)
                gf:ClearFactionRelationOverride(pawn)
            end
        end)
        return true
    end

    local function scoreRound(won)
        if won then
            pvp.wins = pvp.wins + 1
        else
            pvp.losses = pvp.losses + 1
        end
        log(string.format("PvP: you %s. Score %d - %d.", won and "WON the duel" or "were killed by your partner",
            pvp.wins, pvp.losses))
    end

    local lastPartnerHitAt = -100   -- os.clock() of the partner's last hit on us
    local deathScored = false       -- this death was already reported (until we're alive again)
    local function watchDeath(pawn)
        local hp = game.getHealth(pawn)
        local dead = (hp ~= nil and hp <= 0) or game.isDead(pawn)
        if not dead then
            deathScored = false
            return
        end
        if not deathScored then
            deathScored = true
            if os.clock() - lastPartnerHitAt <= KILL_WINDOW_S then
                coop.sendEvent("V", "lose")
                scoreRound(false)
            end
        end
    end

    -- Active move names on an actor (GA_Hun_* only: attacks, stance, dashes).
    local function activeMoves(actor)
        local bl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        local asc = valid(bl) and bl:GetAbilitySystemComponent(actor) or nil
        local out = {}
        if not valid(asc) then
            return out
        end
        pcall(function()
            asc.ActivatableAbilities.Items:ForEach(function(_, elem)
                local spec = elem:get()
                if spec.ActiveCount > 0 and valid(spec.Ability) then
                    local name = spec.Ability:GetClass():GetFName():ToString()
                    if name:find("^GA_Hun") then
                        out[#out + 1] = name
                    end
                end
            end)
        end)
        return out
    end

    local function isAttack(name)
        return not (name:find("Stance") or name:find("Dash") or name:find("Dodge") or name:find("Deflect")
            or name:find("Escape"))
    end

    -- One partner swing at a time: what we looked like when it started, and whether our guard came up during it.
    local swing = nil               -- { hp, posture, guarded }
    local function watchParry(pawn, ghost)
        local attacking = false
        for _, name in ipairs(activeMoves(ghost)) do
            if isAttack(name) then
                attacking = true
            end
        end
        local hp, posture = game.getHealth(pawn), game.getPosture(pawn)
        if attacking and not swing then
            swing = { hp = hp, posture = posture, guarded = false }
        end
        if swing then
            for _, name in ipairs(activeMoves(pawn)) do
                if name:find("Stance") then
                    swing.guarded = true
                end
            end
            -- A hit or a block during the swing settles it: no parry.
            if hp and swing.hp and hp < swing.hp - 0.5 then
                swing.spoiled = true
                lastPartnerHitAt = os.clock()
            elseif posture and swing.posture and posture < swing.posture - 0.5 then
                swing.spoiled = true
            end
        end
        if swing and not attacking then
            local near = api.distance(pawn:K2_GetActorLocation(), ghost:K2_GetActorLocation()) <= PARRY_REACH_CM
            if swing.guarded and not swing.spoiled and near then
                coop.sendEvent("V", "parry", string.format("%.0f", pvp.parryPosture))
                if game.playHitReaction then
                    game.playHitReaction(ghost, STAGGER_TAG)
                end
                log(string.format("PvP: PARRIED! Your partner staggers (-%.0f posture).", pvp.parryPosture))
            end
            swing = nil
        end
    end

    local function tick()
        if not pvp.on then
            return
        end
        local _, pawn = getPlayer1()
        local ghost = net.ghost
        if valid(pawn) then
            watchDeath(pawn)
        end
        if not (valid(pawn) and valid(ghost)) or net.ghostHidden then
            return
        end

        if hostileGhost ~= ghost:GetAddress() then
            giveGhostStats(ghost, pawn)
            if setHostile(pawn, ghost, true) then
                hostileGhost = ghost:GetAddress()
            end
        end

        -- The ghost shows the partner's real health (it never drops to 0 here, so it can keep fighting).
        local t = net.target
        if t and t.Hp and t.MaxHp and t.MaxHp > 0 then
            setAttr(ghost, "Health_Max", t.MaxHp)
            game.setHealth(ghost, math.max(1, t.Hp))
        end

        watchParry(pawn, ghost)
        -- Keep the ghost's posture pool from emptying here (their real posture lives on their PC).
        local gmax = attr(ghost, "Shachi_Max")
        if gmax and game.setPosture then
            game.setPosture(ghost, gmax.CurrentValue)
        end
    end
    coop.extraTicks.pvp = tick

    coop.handlers.V = function(rest)
        local kind, arg = rest:match("^(%S+)%s*(%S*)")
        if not pvp.on then
            return
        end
        if kind == "lose" then
            scoreRound(true)
        elseif kind == "parry" then
            -- Our swing was parried: stagger and lose posture, like a boss whose attack you deflected.
            local amount = math.min(tonumber(arg) or pvp.parryPosture, 400)
            local _, pawn = getPlayer1()
            if not valid(pawn) then
                return
            end
            local cur = game.getPosture(pawn)
            if cur and game.setPosture then
                game.setPosture(pawn, math.max(0, cur - amount))
            end
            if game.staggerSelf then
                game.staggerSelf(pawn, STAGGER_TAG)
            end
            log(string.format("PvP: your partner PARRIED you (-%.0f posture).", amount))
        end
    end

    function pvp.set(on)
        pvp.on = on
        net.pvp = on
        local _, pawn = getPlayer1()
        if valid(pawn) then
            setAttr(pawn, "Health_Min", 0)     -- (1.1.0 duels held health at 1; deaths are real now)
        end
        if not on then
            if valid(pawn) then
                if valid(net.ghost) then
                    setHostile(pawn, net.ghost, false)
                    if game.setupGhost then
                        game.setupGhost(net.ghost)       -- harmless again
                    end
                end
            end
            hostileGhost = nil
        end
        log("PvP " .. (on and string.format("ON (damage %d%%). Score %d - %d.", math.floor(pvp.damage * 100 + 0.5), pvp.wins, pvp.losses) or "off."))
    end

    -- pvp on | off | status | damage <percent>
    function pvp.command(args)
        local cmd, arg = (args or ""):match("^%s*(%S*)%s*(%S*)")
        if cmd == "on" then
            pvp.set(true)
        elseif cmd == "off" then
            pvp.set(false)
        elseif cmd == "parry" and tonumber(arg) then
            pvp.parryPosture = math.max(0, math.min(400, tonumber(arg)))
            log(string.format("PvP parry reward: %.0f posture.", pvp.parryPosture))
        elseif cmd == "damage" and tonumber(arg) then
            pvp.damage = math.max(0.1, math.min(3.0, tonumber(arg) / 100))
            hostileGhost = nil      -- re-apply the ghost's attack next tick
            log(string.format("PvP damage %d%%.", math.floor(pvp.damage * 100 + 0.5)))
        else
            log(string.format("PvP %s, damage %d%%, score %d - %d. Usage: pvp on|off|damage <percent>",
                pvp.on and "on" or "off", math.floor(pvp.damage * 100 + 0.5), pvp.wins, pvp.losses))
        end
    end

    return pvp
end
