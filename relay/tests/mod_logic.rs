//! Runs mod scripts outside the game against stand-ins for the game's objects: the parts whose logic doesn't need
//! the game (which objects are shared, the ledger, regroup's teleport target, partner tips).

use mlua::Lua;
use std::path::{Path, PathBuf};

fn mod_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../mod/PBZCoop")
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join("pbzcoop_mod_tests").join(name);
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A Lua state with the stand-in api (see STUBS) and `script` loaded as `M`.
fn load(script: &str, files: &Path) -> Lua {
    let lua = Lua::new();
    let lua_path = |p: &Path| p.to_string_lossy().replace('\\', "/") + "/";
    lua.globals().set("MOD_ROOT", lua_path(&mod_dir())).unwrap();
    lua.globals().set("MOD_DIR", lua_path(files)).unwrap();
    lua.load(STUBS).exec().unwrap();
    let src = std::fs::read_to_string(mod_dir().join("Scripts").join(script)).unwrap();
    {
        let f: mlua::Function = lua.load(&src).set_name(script).eval().unwrap();
        let m: mlua::Value = f.call(lua.globals().get::<_, mlua::Table>("api").unwrap()).unwrap();
        lua.globals().set("M", m).unwrap();
    }
    lua
}

const STUBS: &str = r#"
tips, logs, teleports = {}, {}, {}
objects = {}                         -- FindFirstOf results by class
function FindFirstOf(cls) return objects[cls] end
function FindAllOf(cls) return {} end
function FName(s) return s end
function ExecuteInGameThread(f) f() end
Key = { F5 = "F5", G = "G" }
bound = {}
function RegisterKeyBind(k, f) bound[k] = f end
net = { enabled = true, localMap = "PBZ_Xigu_WP" }
pawn = { K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end }
hp = { 100, 100 }
api = {
    log = function(s) logs[#logs + 1] = s end,
    valid = function(o) return o ~= nil end,
    game = { getHealth = function() return hp[1], hp[2] end },
    coop = { net = net, handlers = {}, extraTicks = {}, sendEvent = function() end },
    modRoot = function() return MOD_ROOT end,
    modDir = function() return MOD_DIR end,
    getPlayer1 = function() return nil, pawn end,
    status = { notify = function(key, text) tips[#tips + 1] = key .. ": " .. text end },
}
"#;

#[test]
fn shared_world_objects_go_to_the_ledger_once_and_gates_tell_the_player() {
    let dir = scratch("sync");
    let lua = load("sync.lua", &dir);
    lua.load(
        r#"
        local A = api.coop.handlers.A
        A("PBZ_Xigu_WP-BP_Block_Gate_C_UAID_60CF84809909035702_1081357494")
        A("PBZ_Xigu_WP-BP_Block_Gate_C_UAID_60CF84809909035702_1081357494")   -- resent: once
        A("PBZ_Xigu_WP-BP_KickStone_C_3")
        A("PBZ_Xigu_WP-BP_Chest_C_UAID_60CF8480990963A302_1103301003")
        A("PBZ_Xigu_WP-BP_SingleDoor_Poverty_C_UAID_1_2")                     -- stateful: not shared
        A("PBZ_Xigu_WP-BP_Lift_C_UAID_1_2")                                    -- stateful: not shared
        A("no level prefix")
        A("PBZ_Xigu_WP-BP_Chest_C_1;os.exit()")                                -- not an id
        "#,
    )
    .exec()
    .unwrap();
    // Lua's text mode writes CRLF on Windows; pbzsave and the mod read either.
    let ledger = std::fs::read_to_string(dir.join("shared_world.txt")).unwrap().replace("\r\n", "\n");
    assert_eq!(
        ledger,
        "A PBZ_Xigu_WP-BP_Block_Gate_C_UAID_60CF84809909035702_1081357494\nA PBZ_Xigu_WP-BP_KickStone_C_3\n\
         A PBZ_Xigu_WP-BP_Chest_C_UAID_60CF8480990963A302_1103301003\n"
    );
    let tips: Vec<String> = lua.globals().get("tips").unwrap();
    assert_eq!(tips.len(), 2, "gate and shortcut tips, none for the chest (shown open live): {tips:?}");
    assert!(tips[0].contains("opened a gate"), "{tips:?}");
    assert!(tips[1].contains("opened a shortcut"), "{tips:?}");

    // A new session reads the ledger back: the chest waits for its area, the rest needs nothing live.
    let lua = load("sync.lua", &dir);
    let waiting: i64 = lua.load("local n = 0 for _ in pairs(M.pending) do n = n + 1 end return n").eval().unwrap();
    assert_eq!(waiting, 3);
}

#[test]
fn regroup_teleports_behind_the_partner_into_their_area() {
    let lua = load("partner.lua", &scratch("regroup"));
    let out: String = lua
        .load(
            r#"
            objects.PerformanceSystemSubsystem = { TeleportToTargetPoint = function(self, t, level)
                teleports[#teleports + 1] = { t = t, level = level } end }
            -- no partner yet
            M.regroup()
            net.target = { X = 1000, Y = 2000, Z = 300, Yaw = 90, Hp = 50, MaxHp = 100, Map = "PBZ_Duanhun_WP" }
            net.targetAt = os.clock()
            M.regroup()
            M.regroup()                                       -- cooldown
            local tp = teleports[1]
            return string.format("%d %s %.1f %.1f %.1f %.3f %.3f | %s", #teleports, tp.level, tp.t.Translation.X,
                tp.t.Translation.Y, tp.t.Translation.Z, tp.t.Rotation.Z, tp.t.Rotation.W, table.concat(tips, " / "))
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("1 PBZ_Duanhun_WP 1000.0 1920.0 350.0 0.707 0.707 | "), "{out}");
    assert!(out.contains("no position from your partner"), "{out}");
    assert!(out.contains("loading their area"), "{out}");
    assert!(out.contains("wait a few seconds"), "{out}");
}

#[test]
fn partner_down_low_health_far_and_own_respawn_tips() {
    let lua = load("partner.lua", &scratch("tips"));
    let tips: Vec<String> = lua
        .load(
            r#"
            M.bindKey("g")
            local tick = api.coop.extraTicks.partner
            local function check() for _ = 1, 30 do tick() end end
            local function partner(hp, x)
                net.target = { X = x or 0, Y = 0, Z = 0, Yaw = 0, Hp = hp, MaxHp = 100, Map = "PBZ_Xigu_WP" }
                net.targetAt = os.clock()
                check()
            end
            partner(100) partner(45) partner(40) partner(20)     -- 50% once, then 25%
            partner(0)                                            -- one read at 0: not down yet
            partner(0)                                            -- down
            partner(100)                                          -- back
            partner(100, 20000)                                   -- 200 m away
            partner(100, 20500)                                   -- still far: no repeat
            hp[1] = 0 check() check() hp[1] = 80 check()          -- you died and came back
            return tips
            "#,
        )
        .eval()
        .unwrap();
    let want = [
        "partnerhp: your partner's health: 45%.",
        "partnerhp: your partner's health: 20%.",
        "partner: your partner is down.",
        "partner: your partner is back.",
        "far: your partner is 200 m away: G to regroup.",
        "self: you're back: G regroups you with your partner.",
    ];
    assert_eq!(tips, want);
    let bound: mlua::Table = lua.globals().get("bound").unwrap();
    assert!(bound.contains_key("G").unwrap(), "RegroupKey bound");
}
