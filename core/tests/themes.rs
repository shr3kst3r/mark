//! Themes, end to end through the C ABI and the user directory.
//!
//! The unit tests in `src/theme.rs` cover the format. What is here is the two
//! things a user can actually do that no unit test reaches: **drop a TOML into
//! `~/.config/mark/themes` and have it work with no rebuild**, and **get a
//! named error instead of invisible text when that TOML is wrong** — plan §2
//! M7's third and fourth gates.
//!
//! The user directory is overridden with `MARK_THEME_DIR` rather than by
//! writing into the real `~/.config`: a test that edits a developer's own
//! configuration is a test nobody runs twice. Environment variables are
//! process-wide, so these tests are a single `#[test]` that runs them in
//! sequence — `cargo test` would otherwise run them in parallel and they would
//! fight over the same variable.

use std::ffi::{CStr, CString, c_char};
use std::fs;
use std::path::PathBuf;

use mark_core::{MARK_THEME_LIST, mark_free, mark_last_error, mark_render_html, mark_theme_json};

fn take(pointer: *mut c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned();
    unsafe { mark_free(pointer) };
    Some(text)
}

fn error() -> String {
    take(mark_last_error()).unwrap_or_default()
}

fn c(text: &str) -> CString {
    CString::new(text).expect("no interior NUL in a test string")
}

/// A `[palette]` with all sixteen slots, so a test can remove exactly one.
fn palette() -> String {
    let mut out = String::from("[palette]\n");
    for index in 0..16u8 {
        out.push_str(&format!(
            "base{index:02X} = \"#{index:02x}{index:02x}{index:02x}\"\n"
        ));
    }
    out
}

struct UserDir(PathBuf);

impl UserDir {
    fn new(name: &str) -> UserDir {
        let dir = std::env::temp_dir().join(format!("mark-themes-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("a scratch theme directory");
        // SAFETY: the whole point of this test is the process-wide variable,
        // and every test that reads it runs in the one `#[test]` below.
        unsafe { std::env::set_var("MARK_THEME_DIR", &dir) };
        mark_core::theme::clear_cache();
        UserDir(dir)
    }

    fn write(&self, name: &str, body: &str) {
        fs::write(self.0.join(format!("{name}.toml")), body).expect("write a theme");
        // The registry revalidates by mtime, and a file written twice inside
        // one filesystem timestamp tick would look unchanged.
        mark_core::theme::clear_cache();
    }
}

impl Drop for UserDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
        unsafe { std::env::remove_var("MARK_THEME_DIR") };
        mark_core::theme::clear_cache();
    }
}

#[test]
fn the_user_theme_directory_behaves() {
    a_user_theme_loads_without_a_rebuild();
    a_missing_slot_is_a_named_error_not_invisible_text();
    a_user_file_shadows_a_shipped_theme_of_the_same_name();
    an_edited_user_theme_is_picked_up_without_a_restart();
    a_broken_user_theme_is_listed_as_a_problem_not_dropped();
    importing_a_tm_theme_produces_a_usable_theme();
}

/// **Gate 3.** A TOML in the user directory loads with no rebuild.
fn a_user_theme_loads_without_a_rebuild() {
    let dir = UserDir::new("gate3");
    dir.write(
        "mine",
        &format!("name = \"mine\"\nkind = \"dark\"\n\n{}", palette()),
    );

    let json = take(unsafe { mark_theme_json(c("mine").as_ptr(), 0) })
        .unwrap_or_else(|| panic!("resolving a user theme failed: {}", error()));
    let parsed: serde_json::Value = serde_json::from_str(&json).expect("json");
    assert_eq!(parsed["name"], "mine");
    // No `pair`, so it is used for both appearances.
    assert_eq!(parsed["paired"], false);
    assert!(
        parsed["css"]
            .as_str()
            .unwrap()
            .contains("--mk-background:#000000"),
        "{json}"
    );

    // And it renders: the point is not that the file parses, it is that a
    // document comes out in it.
    let html = take(unsafe {
        mark_render_html(
            c("```rust\nfn f() {}\n```\n").as_ptr(),
            0,
            c("mine").as_ptr(),
            0,
        )
    })
    .unwrap_or_else(|| panic!("rendering in a user theme failed: {}", error()));
    assert!(html.contains("<span class=\"t"), "{html}");

    let list = take(unsafe { mark_theme_json(std::ptr::null(), MARK_THEME_LIST) }).unwrap();
    assert!(list.contains("\"mine\""), "{list}");
    assert!(
        list.contains("\"user\""),
        "the source is not reported: {list}"
    );
    drop(dir);
}

/// **Gate 4.** A theme with a deliberately missing slot fails with a named
/// error rather than rendering invisible text.
fn a_missing_slot_is_a_named_error_not_invisible_text() {
    let dir = UserDir::new("gate4");
    let holed = palette().replace("base0D = \"#0d0d0d\"\n", "");
    dir.write(
        "holed",
        &format!("name = \"holed\"\nkind = \"dark\"\n\n{holed}"),
    );

    assert!(
        unsafe { mark_theme_json(c("holed").as_ptr(), 0) }.is_null(),
        "a theme missing base0D resolved anyway"
    );
    let message = error();
    assert!(message.contains("holed"), "{message}");
    assert!(message.contains("base0D"), "{message}");
    assert!(message.contains("base16 requires"), "{message}");

    // And the render path refuses too, rather than falling back to a theme the
    // user did not ask for and painting text they cannot see.
    assert!(
        unsafe { mark_render_html(c("# hi\n").as_ptr(), 0, c("holed").as_ptr(), 0) }.is_null(),
        "rendering in a broken theme produced a document"
    );
    assert!(error().contains("base0D"));

    // A chrome key pointing at a slot the palette does not define is the same
    // failure by a different route, and is named the same way.
    dir.write(
        "dangling",
        &format!(
            "name = \"dangling\"\nkind = \"dark\"\n\n{}\n[document]\nlink = \"base15\"\n",
            palette()
        ),
    );
    assert!(unsafe { mark_theme_json(c("dangling").as_ptr(), 0) }.is_null());
    let message = error();
    assert!(message.contains("[document] link"), "{message}");
    assert!(message.contains("base15"), "{message}");
    drop(dir);
}

fn a_user_file_shadows_a_shipped_theme_of_the_same_name() {
    let dir = UserDir::new("shadow");
    dir.write(
        "dracula",
        &format!("name = \"dracula\"\nkind = \"light\"\n\n{}", palette()),
    );
    let json = take(unsafe { mark_theme_json(c("dracula").as_ptr(), 0) }).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["kind"], "light", "the shipped dracula won: {json}");

    // But the *default* cannot be shadowed: it is the floor the app falls back
    // to, so a broken user file must not be able to take the renderer down.
    dir.write(
        "default-dark",
        "name = \"default-dark\"\nkind = \"nonsense\"\n",
    );
    let html = take(unsafe { mark_render_html(c("# hi\n").as_ptr(), 0, std::ptr::null(), 0) });
    assert!(
        html.is_some(),
        "the default theme was breakable: {}",
        error()
    );
    drop(dir);
}

fn an_edited_user_theme_is_picked_up_without_a_restart() {
    let dir = UserDir::new("edit");
    dir.write(
        "evolving",
        &format!("name = \"evolving\"\nkind = \"dark\"\n\n{}", palette()),
    );
    let before = take(unsafe { mark_theme_json(c("evolving").as_ptr(), 0) }).unwrap();
    assert!(before.contains("--mk-background:#000000"), "{before}");

    // Same name, different bytes. The registry stamps mtimes, so this is seen
    // without clearing anything — which is what "without a rebuild" has to
    // mean for someone iterating on a palette.
    fs::write(
        dir.0.join("evolving.toml"),
        format!(
            "name = \"evolving\"\nkind = \"dark\"\n\n{}",
            palette().replace("base00 = \"#000000\"", "base00 = \"#123456\"")
        ),
    )
    .unwrap();
    // Force the mtime forward: two writes inside one filesystem timestamp tick
    // are indistinguishable, and this test is about the mechanism, not about
    // the filesystem's resolution.
    let future = std::time::SystemTime::now() + std::time::Duration::from_secs(2);
    fs::File::open(dir.0.join("evolving.toml"))
        .and_then(|file| file.set_times(fs::FileTimes::new().set_modified(future)))
        .expect("touch");

    let after = take(unsafe { mark_theme_json(c("evolving").as_ptr(), 0) }).unwrap();
    assert!(
        after.contains("--mk-background:#123456"),
        "the edit was not picked up: {after}"
    );
    drop(dir);
}

fn a_broken_user_theme_is_listed_as_a_problem_not_dropped() {
    let dir = UserDir::new("problems");
    dir.write("wrong", "name = \"wrong\"\nkind = dark\n");
    let list = take(unsafe { mark_theme_json(std::ptr::null(), MARK_THEME_LIST) }).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&list).unwrap();
    let problems = parsed["problems"].as_array().expect("a problems array");
    assert_eq!(problems.len(), 1, "{list}");
    let message = problems[0].as_str().unwrap();
    assert!(message.contains("wrong.toml:2"), "{message}");
    assert!(message.contains("double-quoted"), "{message}");
    // The shipped themes are still all there: one bad file costs its own line
    // and nothing else.
    assert!(parsed["themes"].as_array().unwrap().len() >= 16, "{list}");
    drop(dir);
}

fn importing_a_tm_theme_produces_a_usable_theme() {
    // The escape hatch, exercised on a minimal but real `.tmTheme`. Chrome is
    // derived from the global settings, which is why an imported theme is less
    // coherent than a palette-derived one — inherent, not a defect.
    let dir = UserDir::new("import");
    let path = dir.0.join("Probe.tmTheme");
    fs::write(
        &path,
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>name</key><string>Probe</string>
  <key>settings</key>
  <array>
    <dict><key>settings</key><dict>
      <key>background</key><string>#1b1b1b</string>
      <key>foreground</key><string>#e0e0e0</string>
      <key>caret</key><string>#ffcc00</string>
      <key>selection</key><string>#404040</string>
    </dict></dict>
    <dict>
      <key>scope</key><string>keyword</string>
      <key>settings</key><dict><key>foreground</key><string>#ff44aa</string></dict>
    </dict>
    <dict>
      <key>scope</key><string>string</string>
      <key>settings</key><dict><key>foreground</key><string>#44ff88</string></dict>
    </dict>
  </array>
</dict>
</plist>
"#,
    )
    .unwrap();

    let (toml, name) = mark_core::theme::import(&path).expect("the tmTheme imports");
    assert_eq!(name, "probe");
    assert!(toml.contains("kind = \"dark\""), "{toml}");
    // The scope colours landed in the slots the default map assigns them.
    assert!(toml.contains("base0E = \"#ff44aa\""), "{toml}");
    assert!(toml.contains("base0B = \"#44ff88\""), "{toml}");
    // And the chrome came from the globals rather than from nowhere.
    assert!(toml.contains("base00 = \"#1b1b1b\""), "{toml}");
    assert!(toml.contains("base05 = \"#e0e0e0\""), "{toml}");

    fs::write(dir.0.join("probe.toml"), &toml).unwrap();
    mark_core::theme::clear_cache();
    let json = take(unsafe { mark_theme_json(c("probe").as_ptr(), 0) })
        .unwrap_or_else(|| panic!("the imported theme does not resolve: {}", error()));
    assert!(json.contains("--mk-background:#1b1b1b"), "{json}");
    drop(dir);
}
