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
    if script.is_empty() {
        return lua; // stubs only: the test loads what it needs
    }
    let src = std::fs::read_to_string(mod_dir().join("Scripts").join(script)).unwrap();
    {
        let f: mlua::Function = lua.load(&src).set_name(script).eval().unwrap();
        let m: mlua::Value = f.call(lua.globals().get::<_, mlua::Table>("api").unwrap()).unwrap();
        lua.globals().set("M", m).unwrap();
    }
    lua
}

const STUBS: &str = r#"
tips, logs, teleports, sent = {}, {}, {}, {}
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
host = true
api = {
    log = function(s) logs[#logs + 1] = s end,
    valid = function(o) return o ~= nil end,
    game = { getHealth = function() return hp[1], hp[2] end },
    coop = { net = net, handlers = {}, extraTicks = {}, isHost = function() return host end, sendEvent = function(k, ...)
        local args = { ... }
        sent[#sent + 1] = k .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
    end },
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
    assert!(tips.is_empty(), "everything shared here opens live: {tips:?}");

    // A new session reads the ledger back; once the gate's area is loaded it opens through its own function and
    // leaves the list (the game records it); the chest is shown open and stays for pbzsave coop-sync.
    let lua = load("sync.lua", &dir);
    let out: String = lua
        .load(
            r#"
            local opened = {}
            local function actor(name) return {
                IsValid = function() return true end, CurSwitchState = false, Finished = false,
                K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                OpenDoorNoAnim = function() opened[#opened + 1] = name end,
                ["Change Switch State"] = function() opened[#opened + 1] = name end } end
            objects.PBZLevelActorManager = {
                ActorSaveData = { ForEach = function() end },
                HasSaveDataByActorID = function(_, id) return false end,
                GetActorByID = function(_, id) return actor(id) end,
            }
            function StaticFindObject(p) return { path = p } end
            net.enabled = true
            for _ = 1, 120 do api.coop.extraTicks.sync() end
            local n = 0 for _ in pairs(M.pending) do n = n + 1 end
            return #opened .. " opened, " .. n .. " pending: " .. table.concat(opened, ", ")
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("2 opened, 2 pending"), "gate opened (recorded), chest shown, kick stone waits until you're 30-100 m away: {out}");
    assert!(out.contains("Block_Gate") && out.contains("Chest"), "{out}");
}

#[test]
fn partner_montages_play_on_the_ghost_and_replace_ability_replays() {
    let lua = load("", &scratch("moves"));
    let out: String = lua
        .load(
            r#"
            local played, abilities = {}, {}
            api.coop.handlers.M = function(rest) abilities[#abilities + 1] = rest end
            local moves = dofile(MOD_ROOT .. "Scripts/moves.lua")(api)
            local function anim(rec) return { IsValid = function() return true end,
                Montage_Play = function(_, m, rate, kind, start, stopAll) rec[#rec + 1] = m.path .. "@" .. string.format("%.2f", start) end } end
            net.ghost = { IsValid = function() return true end, Mesh = { GetAnimInstance = function() return anim(played) end } }
            net.rttMs = 100
            function StaticFindObject(p) if p:find("Missing") then return nil end return { IsValid = function() return true end, path = p } end
            local U, M = api.coop.handlers.U, api.coop.handlers.M
            M("1 GA_Hun_Light_A 90")                                                -- before any montage: replayed
            U("/PBZCombatAsset/Hun/AM_Hun_Tang_StanceEnter.AM_Hun_Tang_StanceEnter 0.20")
            M("2 GA_Hun_Light_A 90")                                                -- now montages lead
            U("/Missing/AM_X.AM_X 0")                                               -- not loadable here
            U("bad path 1")
            U("/Ok/AM_Y.AM_Y nan")
            -- sender: our own montage changes, then restarts
            local cur = { path = "/PBZCombatAsset/Hun/AM_Hun_Double_Exec.AM_Hun_Double_Exec", pos = 0.1 }
            local mont = { IsValid = function() return true end, GetAddress = function() return cur.path end,
                GetFullName = function() return "AnimMontage " .. cur.path end }
            pawn.Mesh = { GetAnimInstance = function() return { IsValid = function() return true end,
                GetCurrentActiveMontage = function() return mont end,
                Montage_GetPosition = function() return cur.pos end } end }
            net.enabled = true
            local tick = api.coop.extraTicks.moves
            tick() cur.pos = 0.5 tick() cur.pos = 0.0 tick()
            return table.concat(played, " ") .. " | abilities " .. #abilities .. " | sent " .. table.concat(sent, " ; ")
                .. " | failed " .. moves.failed
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("/PBZCombatAsset/Hun/AM_Hun_Tang_StanceEnter.AM_Hun_Tang_StanceEnter@0.25 | abilities 1"), "{out}");
    assert!(out.contains("sent U /PBZCombatAsset/Hun/AM_Hun_Double_Exec.AM_Hun_Double_Exec 0.10 ; U /PBZCombatAsset/Hun/AM_Hun_Double_Exec.AM_Hun_Double_Exec 0.00"),
        "sent on start and on restart, not while playing: {out}");
    assert!(out.ends_with("failed 1"), "{out}");
}

#[test]
fn revive_brings_the_downed_partner_back_and_dialogue_lines_become_tips() {
    let lua = load("partner.lua", &scratch("revive"));
    let out: String = lua
        .load(
            r#"
            local after = {}
            api.game.after = function(s, f) after[#after + 1] = f end
            objects.PerformanceSystemSubsystem = { TeleportToTargetPoint = function(self, t, level)
                teleports[#teleports + 1] = level end }
            local tick = api.coop.extraTicks.partner
            local function check() for _ = 1, 30 do tick() end end
            -- partner down: the regroup key sends a revive instead
            net.target = { X = 0, Y = 0, Z = 0, Yaw = 0, Hp = 0, MaxHp = 100, Map = "PBZ_Xigu_WP" }
            net.targetAt = os.clock()
            M.regroup()
            -- the other side: revive received while down -> the game's revive point moves to the reviver's side
            -- and is put back once revived; revived next to the partner, so no teleport is needed
            local revive = { Translation = { X = 1, Y = 2, Z = 3 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
            local set = {}
            objects.PBZGameSystem = {
                GetReviveTransform = function(_, t, cam) t.Translation = revive.Translation t.Rotation = revive.Rotation end,
                SetReviveTransform = function(_, t) set[#set + 1] = string.format("%.0f,%.0f,%.0f", t.Translation.X, t.Translation.Y, t.Translation.Z) end,
            }
            net.localMap = "PBZ_Xigu_WP"
            api.coop.handlers.Y("500 0 0 PBZ_Xigu_WP")
            net.target = { X = 500, Y = 0, Z = 0, Yaw = 0, Hp = 100, MaxHp = 100, Map = "PBZ_Xigu_WP" }
            hp[1] = 0 net.targetAt = os.clock() check() check()
            hp[1] = 100 net.targetAt = os.clock() check()
            for _, f in ipairs(after) do f() end
            -- dialogue: a visible widget's line is sent once; a received line becomes a tip
            local line = "Hun: The blade remembers."
            function FindAllOf(cls) if cls == "PBZEventPipelineDialogWidget" then return { { IsValid = function() return true end,
                IsVisible = function() return true end, DialogueData = { Text = { ToString = function() return line end } } } } end return {} end
            check() check()
            api.coop.handlers.T("Soul: Who goes there?")
            return table.concat(sent, ";") .. " | teleports " .. table.concat(teleports, ",") .. " | revive point " .. table.concat(set, " then ") .. " | " .. table.concat(tips, " / ")
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("Y 0 0 0 PBZ_Xigu_WP;T Hun: The blade remembers. | teleports  | revive point 500,0,50 then 1,2,3 |"), "{out}");
    assert!(out.contains("revive sent"), "{out}");
    assert!(out.contains("your partner is reviving you"), "{out}");
    assert!(out.contains("revived: back at your partner's side"), "{out}");
    assert!(out.contains("(partner's dialogue) Soul: Who goes there?"), "{out}");
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

#[test]
fn guest_joining_far_away_is_taken_to_the_host_once() {
    let lua = load("partner.lua", &scratch("join"));
    let out: String = lua
        .load(
            r#"
            host = false
            objects.PerformanceSystemSubsystem = { TeleportToTargetPoint = function(self, t, level)
                teleports[#teleports + 1] = level end }
            local tick = api.coop.extraTicks.partner
            net.target = { X = 0, Y = 0, Z = 0, Yaw = 0, Hp = 100, MaxHp = 100, Map = "PBZ_Pangzhen_WP" }
            for _ = 1, 3 do net.targetAt = os.clock() for _ = 1, 30 do tick() end end
            return #teleports .. " " .. (teleports[1] or "-") .. " | " .. table.concat(tips, " / ")
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("1 PBZ_Pangzhen_WP | "), "once, into the host's area: {out}");
    assert!(out.contains("taking you to them"), "{out}");
}

#[test]
fn partner_line_says_where_the_partner_is() {
    let lua = load("hud.lua", &scratch("hud"));
    let out: String = lua
        .load(
            r#"
            local lines = {}
            local function at(t) net.target = t net.targetAt = os.clock() lines[#lines + 1] = M.lineText() end
            lines[#lines + 1] = M.lineText()
            at({ X = 3500, Y = 0, Z = 0, Hp = 82, MaxHp = 100, Map = "PBZ_Xigu_WP" })
            at({ X = 0, Y = 0, Z = 0, Hp = 0, MaxHp = 100, Map = "PBZ_Xigu_WP" })
            at({ X = 0, Y = 0, Z = 0, Hp = 50, MaxHp = 100, Map = "PBZ_Xigu_WP", Cine = true })
            at({ X = 0, Y = 0, Z = 0, Hp = 50, MaxHp = 100, Map = "PBZ_Duanhun_WP" })
            return table.concat(lines, " | ")
            "#,
        )
        .eval()
        .unwrap();
    assert_eq!(out, "Partner: connecting... | Partner 82% · 35 m | Partner: down | Partner 50% · in a cutscene | Partner 50% · in another area");
}

#[test]
fn guest_enemies_glide_back_and_only_jump_across_big_gaps() {
    let lua = load("", &scratch("smooth"));
    let out: String = lua
        .load(
            r#"
            local smooth = dofile(MOD_ROOT .. "Scripts/smoothing.lua")
            local function at(x) return { X = x, Y = 0, Z = 0 } end
            local res = {}
            local function show(cur, tgt) local x, _, _, snap = smooth(cur, tgt)
                res[#res + 1] = x == nil and "-" or string.format("%.0f%s", x, snap and "!" or "") end
            show(at(0), at(100))       -- within 1.5 m: left to the AI
            show(at(0), at(400))       -- 25% of 4 m
            show(at(0), at(1500))      -- 25% would be 3.75 m: capped at 1.2 m
            show(at(0), at(2500))      -- beyond 20 m: jump
            show(at(0), { X = 0/0, Y = 0, Z = 0 })   -- NaN: nothing
            -- a 6 m drift closes in a few updates without ever jumping
            local cur, n = at(0), 0
            while true do local x = smooth(cur, at(600)) if not x then break end cur = at(x) n = n + 1 end
            return table.concat(res, " ") .. " | 6 m closed in " .. n .. " updates to " .. string.format("%.0f", cur.X)
            "#,
        )
        .eval()
        .unwrap();
    assert_eq!(out, "- 100 120 2500! - | 6 m closed in 6 updates to 486");
}

#[test]
fn catch_up_asks_once_and_answers_with_everything_once() {
    let lua = load("sync.lua", &scratch("catchup"));
    let out: String = lua
        .load(
            r#"
            M.catchUp = true
            net.enabled = true
            local tick = api.coop.extraTicks.sync
            for _ = 1, 120 do tick() end                           -- first scan: baseline, and the request
            for _ = 1, 120 do tick() end                           -- no second request
            local asked = table.concat(sent, ";")
            sent = {}
            M.known.quests["/Game/Quests/Q1.Q1_C"] = true
            M.known.bells["Bell_NLES_001"] = true
            M.known.actors["PBZ_Xigu_WP-BP_Chest_C_1"] = true
            api.coop.handlers.Z()
            api.coop.handlers.Z()                                   -- answered once per session
            table.sort(sent)
            return asked .. " | " .. table.concat(sent, ";")
            "#,
        )
        .eval()
        .unwrap();
    assert_eq!(out, "Z | A PBZ_Xigu_WP-BP_Chest_C_1;L Bell_NLES_001;Q /Game/Quests/Q1.Q1_C");
}

#[test]
fn quest_steps_complete_the_same_branch_and_lifts_follow_the_partner() {
    let lua = load("sync.lua", &scratch("steps"));
    let out: String = lua
        .load(
            r#"
            local log = {}
            local function obj(t) t.IsValid = function() return true end return t end
            local branch = obj({ done = false, IsCompleted = function(self) return self.done end,
                SucceedBranch = function(self) self.done = true log[#log + 1] = "SucceedBranch" end })
            local quest = obj({ GetQuestCompletion = function() return 1 end,
                GetBranch = function(_, id) log[#log + 1] = "GetBranch " .. id return branch end })
            objects.PBZNarrativeComponent = obj({ GetQuest = function() return nil end,
                BeginQuest = function() log[#log + 1] = "BeginQuest" return quest end,
                GetInProgressQuests = function() return {} end, GetAllQuests = function() return {} end })
            function StaticFindObject(p) return obj({ path = p }) end
            local W = api.coop.handlers.W
            W("/Game/PBZstory/PBZQuest/Main/MainCh2.MainCh2_C MainCh2_PBZQuestBranch_4")
            W("/Game/PBZstory/PBZQuest/Main/MainCh2.MainCh2_C MainCh2_PBZQuestBranch_4")  -- already done: no-op
            W("not a path B1")
            -- lifts: the partner's lift went up; ours moves up once, and isn't sent back
            local lift = obj({ Positive = false, DoPositiveAction = function(self) self.Positive = true log[#log + 1] = "up" end,
                DoNegativeAction = function(self) self.Positive = false log[#log + 1] = "down" end })
            objects.PBZLevelActorManager = { GetActorByID = function() return lift end, ActorSaveData = { ForEach = function() end } }
            api.coop.handlers.F("PBZ_Fujizhilin_WP-BP_Lift_C_UAID_1_2 1")
            api.coop.handlers.F("PBZ_Fujizhilin_WP-BP_Lift_C_UAID_1_2 1")
            api.coop.handlers.F("PBZ_Fujizhilin_WP-BP_Lift_C_UAID_1_2 0")
            return table.concat(log, ", ") .. " | sent " .. #sent
            "#,
        )
        .eval()
        .unwrap();
    assert_eq!(out, "BeginQuest, GetBranch MainCh2_PBZQuestBranch_4, SucceedBranch, BeginQuest, GetBranch MainCh2_PBZQuestBranch_4, up, down | sent 0");
}
