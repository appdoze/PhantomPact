//! Runs the fork's mod scripts outside the game against stand-ins for the game's objects: the parts whose logic
//! doesn't need the game (what is shared and when, the per-save ledger, the limits, regroup's refusals, revive).

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

/// A Lua state with the stand-in api (see STUBS) and `script` loaded as `M` ("" = stubs only).
fn load(script: &str, files: &Path) -> Lua {
    let lua = Lua::new();
    let lua_path = |p: &Path| p.to_string_lossy().replace('\\', "/") + "/";
    lua.globals().set("MOD_ROOT", lua_path(&mod_dir())).unwrap();
    lua.globals().set("MOD_DIR", lua_path(files)).unwrap();
    lua.load(STUBS).exec().unwrap();
    if script.is_empty() {
        return lua;
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
function StaticFindObject(p) return { path = p, IsValid = function() return true end } end
Key = { F5 = "F5", G = "G" }
bound = {}
function RegisterKeyBind(k, f) bound[k] = f end
slot = "NightmareRun0"
objects.PBZSaveLoadSubsystem = { GetContinueSlotName = function() return { ToString = function() return slot end } end }
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
-- A partner position that is fresh (upstream's coop.lua keeps net.lastRemoteAt).
function partner(t) net.target = t net.lastRemoteAt = os.clock() net.partnerGone = false end
"#;

/// One sync scan (the first one only sets the slot and the baseline).
const TICK: &str = "for _ = 1, 120 do api.coop.extraTicks.sync() end";

#[test]
fn world_objects_go_to_this_saves_ledger_once_and_never_when_off() {
    let dir = scratch("ledger");
    let lua = load("sync.lua", &dir);
    lua.load(format!(
        r#"
        objects.PBZLevelActorManager = {{ ActorSaveData = {{ ForEach = function() end }},
            HasSaveDataByActorID = function() return false end, GetActorByID = function() return nil end }}
        local A = api.coop.handlers.A
        A("PBZ_Xigu_WP-BP_Chest_C_1")                                  -- before any scan: no save known yet
        {TICK}
        A("PBZ_Xigu_WP-BP_Block_Gate_C_UAID_60CF84809909035702_1081357494")
        A("PBZ_Xigu_WP-BP_Block_Gate_C_UAID_60CF84809909035702_1081357494") -- resent: once
        A("PBZ_Xigu_WP-BP_NarrativeCage_C_0")
        A("PBZ_Xigu_WP-BP_SingleDoor_Poverty_C_UAID_1_2")              -- stateful: not shared
        A("PBZ_Xigu_WP-BP_Chest_C_1;os.exit()")                        -- not an id
        M.set(false)
        A("PBZ_Xigu_WP-BP_Chest_C_2")                                  -- sharing off: nothing recorded
        "#
    ))
    .exec()
    .unwrap();
    let ledger = std::fs::read_to_string(dir.join("shared_world_NightmareRun0.txt")).unwrap().replace("\r\n", "\n");
    assert_eq!(ledger, "A PBZ_Xigu_WP-BP_Block_Gate_C_UAID_60CF84809909035702_1081357494\nA PBZ_Xigu_WP-BP_NarrativeCage_C_0\n");
    assert!(!dir.join("shared_world.txt").exists(), "no save-less ledger");
}

#[test]
fn loading_another_save_starts_over_instead_of_sending_it() {
    let lua = load("sync.lua", &scratch("slots"));
    let out: String = lua
        .load(format!(
            r#"
            local bells = {{ "Bell_A" }}
            objects.BellManager = {{ GetAllActivateBellIDs = function() return bells end }}
            {TICK}                                   -- baseline for NightmareRun0
            bells = {{ "Bell_A", "Bell_B" }}
            {TICK}                                   -- a bell rung: sent
            slot = "ManualSave1"
            bells = {{ "Bell_A", "Bell_B", "Bell_C", "Bell_D" }}
            {TICK}                                   -- another save: new baseline, nothing sent
            {TICK}
            local s = {{}} for _, e in ipairs(sent) do if not e:match("^CYC") then s[#s + 1] = e end end
            return table.concat(s, ";")
            "#
        ))
        .eval()
        .unwrap();
    assert_eq!(out, "L Bell_B");
}

#[test]
fn equipment_only_base_game_items_up_to_the_session_limit() {
    let lua = load("sync.lua", &scratch("equip"));
    let out: String = lua
        .load(format!(
            r#"
            {TICK}
            local owned = {{}}
            local function obj(t) t.IsValid = function() return true end return t end
            local map = {{ ForEach = function(_, f) for id in pairs(owned) do
                f({{ get = function() return {{ ToString = function() return id end }} end }}) end end }}
            local bp = obj({{ Accessories = map,
                PushAccessoryToInventory = function(_, id) owned[id] = true end }})
            function FindAllOf(cls) if cls == "PBZBackPackSubsystem" then return {{ bp }} end return {{}} end
            local J = api.coop.handlers.J
            J("acc AC_Loot")                 -- base game: granted
            J("acc AC_Loot")                 -- owned: nothing
            J("acc AC_DebugGodRing")         -- not a base-game id: refused before anything is called
            M.granted = 40
            J("acc AC_ActHit")               -- over this session's limit
            local ids = {{}} for id in pairs(owned) do ids[#ids + 1] = id end
            table.sort(ids)
            return table.concat(ids, ",") .. " | failed " .. M.failed
            "#
        ))
        .eval()
        .unwrap();
    assert_eq!(out, "AC_Loot | failed 1");
}

#[test]
fn upgrades_only_go_up_and_cycles_are_compared() {
    let lua = load("sync.lua", &scratch("levels"));
    let out: String = lua
        .load(
            r#"
            local calls = {}
            local levels = { Tang = 30 }
            local function obj(t) t.IsValid = function() return true end return t end
            local map = { ForEach = function(_, f) for id, lv in pairs(levels) do
                f({ get = function() return { ToString = function() return id end } end },
                  { get = function() return { WeaponLevel = lv } end }) end end }
            local bp = obj({ MainWeaponInfos = map,
                UpgradeWeapon = function(_, id, normal, lv) calls[#calls + 1] = "UpgradeWeapon " .. id .. " " .. lv levels[id] = lv end })
            function FindAllOf(cls) if cls == "PBZBackPackSubsystem" then return { bp } end return {} end
            api.coop.handlers.O("weap Tang 45")
            api.coop.handlers.O("weap Tang 40")
            api.coop.handlers.O("weap Nope 50")
            objects.PBZGameSystem = { GetCycleCount = function() return 1 end, GetDifficultModeByte = function() return 4 end }
            api.coop.handlers.CYC("1 4")
            api.coop.handlers.CYC("0 2")
            return table.concat(calls, ", ") .. " | " .. table.concat(tips, " / ")
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("UpgradeWeapon Tang 45 | cycle: "), "{out}");
    assert!(out.contains("cycle 0, difficulty 2; yours is cycle 1, difficulty 4"), "{out}");
}

#[test]
fn quest_steps_lifts_and_catch_up() {
    let lua = load("sync.lua", &scratch("steps"));
    let out: String = lua
        .load(format!(
            r#"
            local log = {{}}
            local function obj(t) t.IsValid = function() return true end return t end
            local branch = obj({{ done = false, IsCompleted = function(self) return self.done end,
                SucceedBranch = function(self) self.done = true log[#log + 1] = "SucceedBranch" end }})
            local quest = obj({{ GetQuestCompletion = function() return 1 end, GetBranch = function() return branch end }})
            objects.PBZNarrativeComponent = obj({{ GetQuest = function() return nil end,
                BeginQuest = function() log[#log + 1] = "BeginQuest" return quest end,
                GetInProgressQuests = function() return {{}} end, GetAllQuests = function() return {{}} end }})
            api.coop.handlers.W("/Game/PBZstory/PBZQuest/Main/MainCh2.MainCh2_C MainCh2_PBZQuestBranch_4")
            -- a lift in an area not loaded here waits; a loaded one moves once
            local lift = obj({{ Positive = false, DoPositiveAction = function(self) self.Positive = true log[#log + 1] = "up" end,
                DoNegativeAction = function(self) self.Positive = false log[#log + 1] = "down" end }})
            local loaded = false
            objects.PBZLevelActorManager = {{ ActorSaveData = {{ ForEach = function() end }},
                GetActorByID = function() return loaded and lift or nil end }}
            api.coop.handlers.F("PBZ_Fujizhilin_WP-BP_Lift_C_UAID_9_9 1")
            local waiting = M.pendingLifts["PBZ_Fujizhilin_WP-BP_Lift_C_UAID_9_9"]
            loaded = true
            api.coop.handlers.F("PBZ_Fujizhilin_WP-BP_Lift_C_UAID_9_9 1")
            -- catch-up: asked once at the start, answered once
            M.catchUp = true
            {TICK}
            {TICK}
            M.known.bells["Bell_NLES_001"] = true
            api.coop.handlers.Z()
            api.coop.handlers.Z()
            return table.concat(log, ", ") .. " | waited " .. tostring(waiting) .. " | sent " .. table.concat(sent, ";")
            "#
        ))
        .eval()
        .unwrap();
    // Steps and lifts applied; catch-up asked once ("Z") and answered once (the bell).
    assert_eq!(out, "BeginQuest, SucceedBranch, up | waited true | sent Z;L Bell_NLES_001");
}

#[test]
fn regroup_stays_in_the_area_and_refuses_when_it_should() {
    let lua = load("regroup.lua", &scratch("regroup"));
    let out: String = lua
        .load(
            r#"
            objects.PerformanceSystemSubsystem = { TeleportToTargetPoint = function(self, t, level)
                teleports[#teleports + 1] = string.format("%s %.0f,%.0f,%.0f", level, t.Translation.X, t.Translation.Y, t.Translation.Z) end }
            M.regroup()                                                     -- no partner yet
            partner({ X = 1000, Y = 2000, Z = 300, Yaw = 90, Hp = 50, MaxHp = 100, Map = "PBZ_Duanhun_WP" })
            M.regroup()                                                     -- other area: refused
            partner({ X = 1000, Y = 2000, Z = 300, Yaw = 90, Hp = 50, MaxHp = 100, Map = "PBZ_Xigu_WP", Cine = true })
            M.regroup()                                                     -- partner in a cutscene
            partner({ X = 1000, Y = 2000, Z = 300, Yaw = 90, Hp = 50, MaxHp = 100, Map = "PBZ_Xigu_WP" })
            net.pvp = true M.regroup() net.pvp = false                      -- PvP
            hp[1] = 0 M.regroup() hp[1] = 100                               -- we're down
            M.regroup()                                                     -- ok: onto the partner's own spot
            M.regroup()                                                     -- cooldown
            return table.concat(teleports, ",") .. " | " .. table.concat(tips, " / ")
            "#,
        )
        .eval()
        .unwrap();
    assert!(out.starts_with("PBZ_Xigu_WP 1000,2000,300 | "), "{out}");
    for why in ["no recent position", "another area", "cutscene", "PvP is on", "you're down", "wait a few seconds"] {
        assert!(out.contains(why), "{why}: {out}");
    }
}

#[test]
fn revive_moves_the_revive_point_then_puts_it_back() {
    let lua = load("regroup.lua", &scratch("revive"));
    let out: String = lua
        .load(
            r#"
            local after = {}
            api.game.after = function(s, f) after[#after + 1] = f end
            local set = {}
            objects.PBZGameSystem = {
                GetReviveTransform = function(_, t) t.Translation = { X = 1, Y = 2, Z = 3 } t.Rotation = { X = 0, Y = 0, Z = 0, W = 1 } end,
                SetReviveTransform = function(_, t) set[#set + 1] = string.format("%.0f,%.0f,%.0f", t.Translation.X, t.Translation.Y, t.Translation.Z) end }
            -- the partner is down: our key sends a revive with our position
            partner({ X = 500, Y = 0, Z = 0, Yaw = 0, Hp = 0, MaxHp = 100, Map = "PBZ_Xigu_WP" })
            M.regroup()
            -- on the downed side: the revive arrives, we die and get back up next to the partner
            partner({ X = 500, Y = 0, Z = 0, Yaw = 0, Hp = 100, MaxHp = 100, Map = "PBZ_Xigu_WP" })
            api.coop.handlers.Y("500 0 0 PBZ_Xigu_WP")
            api.coop.handlers.Y("500 0 0 PBZ_Duanhun_WP")                -- another area: ignored
            local tick = api.coop.extraTicks.regroup
            local function check() for _ = 1, 30 do tick() end end
            hp[1] = 0 check() check()
            hp[1] = 100 partner(net.target) check()
            for _, f in ipairs(after) do f() end
            return table.concat(sent, ";") .. " | revive point " .. table.concat(set, " then ") .. " | teleports " .. #teleports
            "#,
        )
        .eval()
        .unwrap();
    assert_eq!(out, "Y 0 0 0 PBZ_Xigu_WP | revive point 500,0,50 then 1,2,3 | teleports 0");
}

#[test]
fn dialogue_lines_are_sent_once_and_shown_as_tips() {
    let lua = load("dialogue.lua", &scratch("dialogue"));
    let out: String = lua
        .load(
            r#"
            local line = "Hun: The blade remembers."
            function FindAllOf(cls) if cls == "PBZEventPipelineDialogWidget" then return { { IsVisible = function() return true end,
                DialogueData = { Text = { ToString = function() return line end } } } } end return {} end
            local tick = api.coop.extraTicks.dialogue
            for _ = 1, 60 do tick() end
            api.coop.handlers.T("Soul: Who goes there?")
            return table.concat(sent, ";") .. " | " .. table.concat(tips, " / ")
            "#,
        )
        .eval()
        .unwrap();
    assert_eq!(out, "T Hun: The blade remembers. | dialogue: (partner's dialogue) Soul: Who goes there?");
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
            show(at(0), at(100)) show(at(0), at(400)) show(at(0), at(1500)) show(at(0), at(2500))
            show(at(0), { X = 0/0, Y = 0, Z = 0 })
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
fn fork_loader_reads_the_ini_loads_every_extra_and_adds_its_commands() {
    let dir = scratch("fork");
    let lua = load("", &dir);
    let script = mod_dir().join("Scripts/fork.lua").to_string_lossy().replace('\\', "/");
    let out: String = lua
        .load(format!(
            r#"
            local commands = {{}}
            dofile("{script}")(api, commands)
            local names = {{}} for k in pairs(commands) do names[#names + 1] = k end table.sort(names)
            return table.concat(names, ",") .. " | sync " .. tostring(api.sync and api.sync.on) .. " | regroup key "
                .. tostring(api.regroup and api.regroup.key) .. " | bound " .. tostring(bound.F5 ~= nil) .. " | " .. logs[#logs]
            "#
        ))
        .eval()
        .unwrap();
    assert_eq!(out, "regroup,sync | sync true | regroup key F5 | bound true | Fork extras loaded: shared progress true, regroup true, dialogue true, map icon true");
}
