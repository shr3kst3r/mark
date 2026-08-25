//! Compile `tests/fixtures/abi_smoke.c` against `core/include/mark.h` and the
//! built `libmark_core.a`, run it, and fail with its output.
//!
//! ADR-1's boundary is a hand-written C header over a `staticlib`, with no
//! binding generator. A Rust test calling a Rust `extern "C"` function
//! exercises the body but not the boundary: it cannot catch a header that has
//! drifted from the implementation, a symbol that did not survive into the
//! archive, or a signature that only agrees by accident. So the header gets a
//! real C consumer, built the way the Swift shell builds one.
//!
//! This test fails rather than skips when the archive or a C compiler is
//! missing. A test that silently passes when it did not run is the failure mode
//! `just swift-test` already guards against elsewhere in this repo.

use std::path::{Path, PathBuf};
use std::process::Command;

/// `target/<profile>/libmark_core.a`, freshly built.
///
/// The path is derived from the test binary's own location, so it is right
/// under `CARGO_TARGET_DIR`, `--release`, and a custom profile alike.
///
/// The build is not optional and this is the subtle part: **`cargo test` does
/// not produce the `staticlib`.** It builds the `lib` crate-type the test
/// harness links against and stops there, so whatever `libmark_core.a` happens
/// to be sitting in the profile directory is left over from the last
/// `cargo build` — possibly from before the change under test. Linking against
/// a stale archive is how a C harness reports "undefined symbol" for a function
/// that exists, or worse, silently tests the previous version. So the test asks
/// cargo for the archive rather than assuming one.
///
/// Nesting cargo inside a cargo test is safe here: the outer invocation
/// releases the build-directory lock before running test binaries. When the
/// archive is already current this costs one no-op cargo invocation.
fn staticlib() -> PathBuf {
    let exe = std::env::current_exe().expect("a test binary knows its own path");
    // .../target/<profile>/deps/abi_c-<hash>
    let profile_dir = exe
        .parent()
        .and_then(Path::parent)
        .expect("the test binary lives in <profile>/deps/");
    let profile = match profile_dir.file_name().and_then(|name| name.to_str()) {
        // The directory is `debug`; the profile that fills it is `dev`.
        Some("debug") | None => "dev",
        Some(other) => other,
    };

    let build = Command::new(env!("CARGO"))
        .args(["build", "-p", "mark-core", "--lib", "--profile", profile])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("cargo is on PATH — this test was started by it");
    assert!(
        build.status.success(),
        "building the staticlib failed:\n{}",
        String::from_utf8_lossy(&build.stderr)
    );

    let archive = profile_dir.join("libmark_core.a");
    assert!(
        archive.is_file(),
        "{} does not exist after `cargo build --lib`. mark-core declares \
         crate-type = [\"lib\", \"staticlib\"] (ADR-1), so cargo should have produced it.",
        archive.display()
    );
    archive
}

fn compiler() -> String {
    std::env::var("CC").unwrap_or_else(|_| "cc".to_owned())
}

#[test]
fn the_c_abi_works_from_c() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source = manifest.join("tests/fixtures/abi_smoke.c");
    let include = manifest.join("include");
    let archive = staticlib();

    let scratch = tempfile::tempdir().expect("a temp dir for the compiled binary");
    let binary = scratch.path().join("abi_smoke");

    let compile = Command::new(compiler())
        .arg("-std=c11")
        .args(["-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(&include)
        .arg(&source)
        .arg(&archive)
        // What a Rust staticlib pulls in on macOS. Kept explicit rather than
        // discovered, so a missing one is a compile error here instead of a
        // mystery when the Swift shell links.
        .args(["-lc++", "-liconv", "-framework", "CoreFoundation"])
        .arg("-o")
        .arg(&binary)
        // `.cargo/config.toml` pins MACOSX_DEPLOYMENT_TARGET=14.0 for the
        // shipping build, and cargo exports it into this process. Applying it
        // to a throwaway test binary only produces a screenful of "object file
        // was built for newer macOS version" warnings from the prebuilt Rust
        // std objects in the archive — noise that would hide a real linker
        // diagnostic. Nothing here ships, so this one link targets the host.
        .env_remove("MACOSX_DEPLOYMENT_TARGET")
        .output()
        .unwrap_or_else(|error| panic!("could not run {}: {error}", compiler()));

    assert!(
        compile.status.success(),
        "compiling {} against {} failed:\n{}\n{}",
        source.display(),
        archive.display(),
        String::from_utf8_lossy(&compile.stdout),
        String::from_utf8_lossy(&compile.stderr),
    );

    let run = Command::new(&binary)
        .output()
        .unwrap_or_else(|error| panic!("could not run {}: {error}", binary.display()));

    let stdout = String::from_utf8_lossy(&run.stdout);
    let stderr = String::from_utf8_lossy(&run.stderr);
    print!("{stdout}");
    assert!(
        run.status.success(),
        "the C ABI smoke test failed ({}):\n{stdout}\n{stderr}",
        run.status
    );
    // The count is printed rather than asserted exactly, but "zero checks ran"
    // must not read as success.
    assert!(
        !stdout.contains("0 checks"),
        "the C program ran no checks:\n{stdout}"
    );
}
