//! Build-time assets: the syntect syntax set is loaded at runtime, and the
//! curated themes are embedded here.
//!
//! # The packdump that is not here
//!
//! The plan asked for a packdump trimmed to ~25 languages. **That is not
//! implementable against syntect's shipped assets**, and the reason is worth
//! recording so nobody retries it:
//!
//! `SyntaxSet::into_builder()` hands back `SyntaxDefinition`s whose patterns
//! still contain `ContextReference::Direct(ContextId { syntax_index, .. })` —
//! absolute indices into the *original* set. Dropping any syntax invalidates
//! them, and `SyntaxSetBuilder::build()` then panics while linking:
//!
//! ```text
//! panicked at syntect-5.3.0/src/parsing/syntax_set.rs:733:25:
//! index out of bounds: the len is 34 but the index is 67
//! ```
//!
//! Trimming would need the raw `.sublime-syntax` sources, which the crate does
//! not ship — only the compiled dump. So the syntax set stays whole (research
//! 2.10 measured its load at 0.33-1.4 ms, a non-issue, and ADR-2 already
//! budgets 1.79 MB of binary for it).
//!
//! # Themes
//!
//! M1 baked in one syntect theme here, because there was only one. M7 removed
//! it: a theme is now a palette plus two slot layers (`core/src/theme.rs`), and
//! the syntect `Theme` it needs is synthesized in memory from that palette. So
//! there is no `.tmTheme` to dump, and the runtime crate needs neither
//! `default-themes` nor `dump-create`.
//!
//! What is embedded instead is `core/themes/*.toml`, the output of
//! `just themes-import`. Embedded rather than read from disk so `mark render
//! --html` works from any directory with no bundle to find, and so a shipped
//! theme cannot be half-removed by an installer. User themes are read from
//! `~/.config/mark/themes` at runtime and need no rebuild.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=themes");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is set by cargo"));
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("set by cargo"));
    let themes = manifest.join("themes");

    let mut names: Vec<String> = fs::read_dir(&themes)
        .unwrap_or_else(|error| panic!("{}: {error} — run `just themes-import`", themes.display()))
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "toml"))
        .filter_map(|path| {
            path.file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
        })
        .collect();
    names.sort();

    assert!(
        !names.is_empty(),
        "{} holds no themes — run `just themes-import`",
        themes.display()
    );

    let mut generated = String::from(
        "/// The curated themes, converted by `just themes-import` and embedded\n\
         /// at build time. `(name, toml)`, sorted by name.\n\
         pub static BUILTIN: &[(&str, &str)] = &[\n",
    );
    for name in &names {
        let path = themes.join(format!("{name}.toml"));
        println!("cargo::rerun-if-changed={}", path.display());
        let _ = writeln!(
            generated,
            "    ({name:?}, include_str!({:?})),",
            path.display().to_string()
        );
    }
    generated.push_str("];\n");

    fs::write(out_dir.join("themes.rs"), generated).expect("write themes.rs");
}
