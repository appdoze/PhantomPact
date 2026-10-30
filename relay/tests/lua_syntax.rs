//! Every mod script must compile as Lua 5.4 (the language UE4SS embeds): a syntax error would only show up when the
//! game loads the mod. Compiled, not run: the scripts need the game.

#[test]
fn mod_scripts_compile() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../mod/PBZCoop/Scripts");
    let lua = mlua::Lua::new();
    let mut n = 0;
    for entry in std::fs::read_dir(&dir).expect("mod/PBZCoop/Scripts") {
        let path = entry.unwrap().path();
        if path.extension().map_or(true, |e| e != "lua") {
            continue;
        }
        let src = std::fs::read_to_string(&path).unwrap();
        if let Err(e) = lua.load(&src).set_name(path.file_name().unwrap().to_string_lossy()).into_function() {
            panic!("{}: {e}", path.display());
        }
        n += 1;
    }
    assert!(n >= 8, "found {n} scripts");
}
