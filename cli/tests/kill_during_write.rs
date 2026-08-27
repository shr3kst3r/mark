//! Killing a writer mid-write must never leave a truncated document.
//!
//! `2026-08-24-editing-pane-and-autosave` turns the write path from "one byte,
//! when a reader clicks a checkbox" into "the whole document, every 800 ms",
//! and its M9 gate is *"killing the app mid-debounce loses at most the last
//! 800 ms and never truncates"*. The "at most 800 ms" half is a property of the
//! debounce and is asserted in Swift (`EditorTests.killedMidDebounce`,
//! `flushingAtQuitWrites`). The "never truncates" half is a property of
//! `core::tasks::write_atomically` under an actual `SIGKILL`, which is what
//! this file provides.
//!
//! A real process really killed, rather than a simulation: temp-file-plus-
//! rename is only atomic because `rename(2)` is, and the way to find out
//! whether we are using it correctly is to be killed while using it. The
//! subject is `mark check`, which reads a 1 MB document, changes one byte, and
//! writes the whole thing back through the same primitive autosave uses.

use std::process::{Command, Stdio};
use std::time::Duration;

use tempfile::TempDir;

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_mark-cli")
}

/// `write_atomically`'s in-flight temp files, which exist only between the
/// `File::create` and the `rename`.
fn temp_files(directory: &std::path::Path) -> Vec<String> {
    std::fs::read_dir(directory)
        .expect("read the directory")
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with(".notes.md.mark-") && name.ends_with(".tmp"))
        .collect()
}

/// A document big enough that its write is not instantaneous — the whole point
/// is to be killed *during* one.
fn document(marker: char) -> String {
    let mut text = format!("# Kill test\n\n- [{marker}] the only task\n\n");
    for index in 0..14_000 {
        text.push_str(&format!(
            "Paragraph {index} of a document large enough that writing it takes measurable time.\n\n"
        ));
    }
    text
}

/// Every byte a write can land in the marker, and therefore every whole
/// document that may legitimately be on disk when a writer is killed.
///
/// `2026-08-27-five-task-states` turns this from two variants into five: the
/// point of the assertion is "whatever is there is a *whole* document", so the
/// set has to have one arm per writable byte or a correct write looks like a
/// truncation. The states come from the core rather than a literal list, so a
/// sixth would fail to compile here rather than fail mysteriously at 1 MB.
fn variants() -> Vec<String> {
    mark_core::tasks::State::ALL
        .iter()
        .map(|state| document(char::from(state.byte())))
        .collect()
}

#[test]
fn a_killed_write_never_truncates_the_document() {
    let directory = TempDir::new().expect("temp dir");
    let path = directory.path().join("notes.md");
    let variants = variants();
    let open = document(' ');
    std::fs::write(&path, &open).expect("write the fixture");
    assert!(open.len() > 1_000_000, "the fixture is too small to race");

    // Kill by *observation*, not by clock. Timing the kill against a
    // wall-clock fraction of a full run sounds reasonable and does not work:
    // reading and parsing 1 MB dominates the run, the write itself is a
    // millisecond or two at the end, and a sweep across the run lands every
    // kill outside the window it is supposed to test — 40 attempts, 40 clean
    // completions, and an assertion that never had a chance to fail.
    //
    // `write_atomically` writes through `.notes.md.mark-<pid>-<n>.tmp` in the
    // same directory, so that file existing *is* "a write is in flight". Poll
    // for it and kill the moment it appears.
    let attempts = 24;
    let mut caught = 0;
    let mut missed = 0;
    for attempt in 0..attempts {
        // Alternate the verb so a third and fourth byte really do get written
        // mid-kill, rather than the assertion below being widened for states
        // this test never produces.
        let action: &[&str] = match attempt % 3 {
            0 => &["--toggle"],
            1 => &["--state", "cancelled"],
            _ => &["--state", "in-progress"],
        };
        let mut child = Command::new(binary())
            .args(
                [
                    &["check", path.to_str().expect("utf-8 path"), "--item", "0"][..],
                    action,
                ]
                .concat(),
            )
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn mark-cli");

        let mut killed_mid_write = false;
        loop {
            if temp_files(directory.path()).is_empty() {
                match child.try_wait().expect("try_wait") {
                    Some(_) => break, // finished before we saw the temp file
                    None => {
                        std::thread::sleep(Duration::from_micros(50));
                        continue;
                    }
                }
            }
            // A temp file exists: the child is inside write_atomically, with
            // the document's new bytes not yet renamed into place.
            let _ = child.kill();
            killed_mid_write = true;
            break;
        }
        let _ = child.wait();
        if killed_mid_write {
            caught += 1;
        } else {
            missed += 1;
        }

        // The only thing that matters: whatever is on disk is a *whole*
        // document, one of the five legitimate versions. A truncated or
        // half-written file would be none of them.
        let after = std::fs::read_to_string(&path).expect("the document is still readable");
        assert!(
            variants.contains(&after),
            "attempt {attempt}: the document is no version of itself — {} bytes, expected {} \
             (a truncated write)",
            after.len(),
            open.len()
        );

        // Clear the debris so the next attempt's poll cannot see a previous
        // attempt's temp file and kill instantly.
        for stray in temp_files(directory.path()) {
            let _ = std::fs::remove_file(directory.path().join(stray));
        }
    }

    assert!(
        caught > 0,
        "no kill landed inside a write ({missed} misses); this test would pass against \
         a plain fs::write and proves nothing"
    );
    println!(
        "{attempts} attempts: {caught} processes killed mid-write, {missed} finished first; \
         the document survived every one"
    );

    let strays: Vec<String> = temp_files(directory.path());
    for stray in &strays {
        assert!(
            stray.starts_with(".notes.md.mark-") && stray.ends_with(".tmp"),
            "unexpected file left behind: {stray}"
        );
    }
    println!("{} temp file(s) left by killed writers", strays.len());
}
