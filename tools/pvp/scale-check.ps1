# Co-op difficulty check on a running two-copy session (pvp-session.ps1): the same thug spawned in both worlds must
# get the scaled health/posture in both, the client's hits must still land in the host world, and the host's kill
# must still reach the client. Also lists the bells (rest points) in the world.
$run = "$PSScriptRoot\pvp-run.ps1"
$enemy = 'eval local out={} for _,e in ipairs(PBZ.game.listEnemies(true)) do local a=e.AttributeSetBase out[#out+1]=string.format("%s hp=%.0f/%.0f posture=%.0f/%.0f dead=%s", e:GetFName():ToString():sub(1,30), a.Health.CurrentValue, a.Health_Max.CurrentValue, a.Shachi.CurrentValue, a.Shachi_Max.CurrentValue, tostring(PBZ.game.isDead(e))) end return #out.." enemies: "..table.concat(out," | ")'
& $run -I 1 -Cmd 'spawnenemy BP_Monster_MaleThug_Sword_Blue 450' -Wait 1.5
& $run -I 2 -Cmd 'spawnenemy BP_Monster_MaleThug_Sword_Blue 450' -Wait 3
"host:   " + (& $run -I 1 -Cmd $enemy -Wait 0.8)
"client: " + (& $run -I 2 -Cmd $enemy -Wait 0.8)
# Client hits the shared thug (damage reported to the host world).
& $run -I 2 -Cmd 'eval for _,e in ipairs(PBZ.game.listEnemies(true)) do if not PBZ.game.isDead(e) then local h=PBZ.game.getHealth(e) PBZ.game.setHealth(e, h-200) end end return "client hit -200"' -Wait 3 | Out-Null
"host after client hit: " + (& $run -I 1 -Cmd $enemy -Wait 0.8)
& $run -I 1 -Cmd 'eval for _,e in ipairs(PBZ.game.listEnemies(true)) do PBZ.game.applyDamage(e,99999,0) end return "host kill"' -Wait 3 | Out-Null
"client after host kill: " + (& $run -I 2 -Cmd $enemy -Wait 0.8)
& $run -I 1 -Cmd 'eval local out={} local seen={} for _,a in ipairs(FindAllOf("Actor") or {}) do local c=a:GetClass():GetFName():ToString() if (c:find("Bell") or c:find("bell") or c:find("Rest") or c:find("CheckPoint") or c:find("Checkpoint") or c:find("Shrine")) and not seen[a:GetAddress()] then seen[a:GetAddress()]=true local l=a:K2_GetActorLocation() out[#out+1]=string.format("%s @ %.0f,%.0f,%.0f", c, l.X, l.Y, l.Z) end end return #out.." bell-like actors: "..table.concat(out," | ")' -Wait 3
