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
//!
//! # Provenance
//!
//! The other thing stamped in here is which commit this is. `mark` ships as a
//! Homebrew `--HEAD` formula, so the semver in `Cargo.toml` moves on a
//! deliberate bump while the code moves every push: between two bumps every
//! install reports the same version and "which build am I running?" has no
//! answer. Brew already speaks in commits — `HEAD-43b49df -> HEAD-f63a7ca` —
//! so `mark --version` and `mark doctor` do too.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=themes");

    stamp_provenance();

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

/// Emit `MARK_BUILD_COMMIT` and `MARK_BUILD_DATE` for `env!` to pick up.
///
/// Both are overridable through the environment, because a build from a source
/// tarball has no `.git` to ask. Neither is ever fatal: a build with no
/// provenance reports `unknown` and still works.
fn stamp_provenance() {
    // Re-run when the checked-out commit moves. The index is watched too, so
    // staging a change refreshes the `-dirty` marker; an unstaged edit does
    // not, which is the one inaccuracy here and the reason `-dirty` means
    // "there was uncommitted work", not "this exact tree".
    for name in ["HEAD", "index"] {
        if let Some(path) = git_path(name) {
            println!("cargo::rerun-if-changed={}", path.display());
        }
    }
    // A branch's tip lives in its own ref file, not in `HEAD`, whose contents
    // stay `ref: refs/heads/<branch>` across commits.
    if let Some(reference) = git(&["symbolic-ref", "--quiet", "HEAD"])
        && let Some(path) = git_path(&reference)
    {
        println!("cargo::rerun-if-changed={}", path.display());
    }
    println!("cargo::rerun-if-env-changed=MARK_BUILD_COMMIT");
    println!("cargo::rerun-if-env-changed=MARK_BUILD_DATE");

    println!("cargo::rustc-env=MARK_BUILD_COMMIT={}", commit());
    println!("cargo::rustc-env=MARK_BUILD_DATE={}", commit_date());
}

fn commit() -> String {
    if let Some(value) = overridden("MARK_BUILD_COMMIT") {
        return value;
    }
    let Some(short) = git(&["rev-parse", "--short=7", "HEAD"]) else {
        return "unknown".to_owned();
    };
    // `--porcelain` is empty for a clean tree and non-empty for any other, so
    // this needs no parsing. Untracked files count: a build with an extra
    // source file in the tree is not the commit it claims to be.
    match git(&["status", "--porcelain"]) {
        Some(status) if !status.is_empty() => format!("{short}-dirty"),
        _ => short,
    }
}

/// The **commit** date, not the build date: two builds of one commit should
/// report the same thing, and what a bug report needs is how old the code is,
/// not when someone last ran `just build`.
fn commit_date() -> String {
    overridden("MARK_BUILD_DATE")
        .or_else(|| git(&["log", "-1", "--date=format:%Y-%m-%d", "--format=%cd"]))
        .unwrap_or_else(|| "unknown".to_owned())
}

fn overridden(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.is_empty())
}

fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        // Without this, a build run from another directory would describe
        // whatever repository the caller happened to be standing in.
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8(output.stdout).ok()?.trim().to_owned())
}

/// Where git actually keeps `name`. `--git-path` resolves through a worktree's
/// `.git` *file* and through `$GIT_DIR`, which joining onto `.git/` does not —
/// this repository is developed in worktrees.
fn git_path(name: &str) -> Option<PathBuf> {
    let path = PathBuf::from(git(&["rev-parse", "--git-path", name])?);
    path.exists().then_some(path)
}
