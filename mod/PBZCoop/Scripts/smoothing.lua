-- Guest side: how a mirrored enemy follows the host's copy. A small drift glides back over a few updates instead
-- of jumping (the enemy's own AI keeps animating it meanwhile); only a big gap (teleporting boss, respawn, a
-- streaming hitch) is still a jump. Pure function, so it's tested outside the game (luatest/tests/mod_logic.rs).

local GLIDE_FROM_CM = 150   -- closer than this: leave the enemy to its own AI
local SNAP_FROM_CM = 2000   -- further than this: jump
local BLEND = 0.25          -- share of the gap closed per update (net updates come every ~33 ms)
local MAX_STEP_CM = 120     -- and never more than this per update, so a glide never looks like a jump

-- cur, target: {X, Y, Z}. Returns nil (leave it), or x, y, z, snap (true when it's a jump: set the yaw too).
return function(cur, target)
    local dx, dy, dz = target.X - cur.X, target.Y - cur.Y, target.Z - cur.Z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d ~= d or d <= GLIDE_FROM_CM then
        return nil
    end
    if d > SNAP_FROM_CM then
        return target.X, target.Y, target.Z, true
    end
    local step = math.min(d * BLEND, MAX_STEP_CM)
    local k = step / d
    return cur.X + dx * k, cur.Y + dy * k, cur.Z + dz * k, false
end
