//! The property the line diff rests on, over random document pairs.
//!
//! `core/src/lines.rs` drives the editor's change gutter and `mark diff`, and
//! it fails the same way `core/src/diff.rs` does — quietly. ADR-2 wrote that
//! down for the block diff:
//!
//! > a block-diff bug shows up as a subtly stale or duplicated document rather
//! > than a crash, which is harder to notice than a hard failure.
//!
//! A line-diff bug shows up as a bar drawn against the wrong line, or a `+12`
//! that should be `+11`. Nobody files that; they just stop trusting the badge.
//! So the single property is asserted directly, the same way
//! `diff_apply.rs` asserts its own:
//!
//! > **Applying the hunks to the old lines yields exactly the new lines.**
//!
//! Two further invariants are asserted alongside it, because both are things a
//! plausible-looking rewrite would break:
//!
//! * the counts equal the hunks' own arithmetic, so `+N −M` can never disagree
//!   with the bars the gutter draws from the same [`LineDiff`];
//! * hunks are disjoint and ascending on both sides, which is what lets the
//!   gutter and [`lines::marks`] walk them once instead of searching.

use mark_core::lines::{self, HunkKind, LineDiff};
use proptest::prelude::*;

// --- helpers ---------------------------------------------------------------

fn lines_of(text: &str) -> Vec<String> {
    text.lines().map(str::to_owned).collect()
}

/// Applying the hunks to the old document must reproduce the new one.
fn assert_replays(old: &str, new: &str, diff: &LineDiff) -> Result<(), TestCaseError> {
    if diff.coarse {
        // By construction a coarse result does not describe the edit precisely
        // enough to replay, and says so by refusing.
        prop_assert!(lines::apply(diff, old, new).is_none());
        return Ok(());
    }
    let replayed = lines::apply(diff, old, new).expect("a precise diff must replay");
    prop_assert_eq!(replayed, lines_of(new));
    Ok(())
}

/// The counts must be the hunks' own arithmetic, not a second opinion.
fn assert_counts_agree(diff: &LineDiff) -> Result<(), TestCaseError> {
    let added: u32 = diff.hunks.iter().map(|h| h.new.end - h.new.start).sum();
    let removed: u32 = diff.hunks.iter().map(|h| h.old.end - h.old.start).sum();
    prop_assert_eq!(added, diff.added, "added disagrees with the hunks");
    prop_assert_eq!(removed, diff.removed, "removed disagrees with the hunks");
    Ok(())
}

/// Hunks must be disjoint and ascending on both sides.
fn assert_ordered(diff: &LineDiff) -> Result<(), TestCaseError> {
    let mut old_at = 0u32;
    let mut new_at = 0u32;
    for hunk in &diff.hunks {
        prop_assert!(
            hunk.old.start >= old_at,
            "old ranges overlap or go backwards"
        );
        prop_assert!(
            hunk.new.start >= new_at,
            "new ranges overlap or go backwards"
        );
        prop_assert!(hunk.old.end >= hunk.old.start);
        prop_assert!(hunk.new.end >= hunk.new.start);
        // A hunk with nothing on either side is not an edit and must not exist.
        prop_assert!(
            !(hunk.old.is_empty() && hunk.new.is_empty()),
            "an empty hunk is not an edit"
        );
        // The kind must match the ranges, or the gutter colours the wrong thing.
        let expected = match (hunk.old.is_empty(), hunk.new.is_empty()) {
            (true, false) => HunkKind::Added,
            (false, true) => HunkKind::Removed,
            _ => HunkKind::Changed,
        };
        if !diff.coarse {
            prop_assert_eq!(hunk.kind, expected, "kind disagrees with the ranges");
        }
        old_at = hunk.old.end;
        new_at = hunk.new.end;
    }
    Ok(())
}

/// Byte ranges must actually name the lines they claim to.
fn assert_byte_ranges(new: &str, diff: &LineDiff) -> Result<(), TestCaseError> {
    for hunk in &diff.hunks {
        let start = hunk.new_bytes.start as usize;
        let end = hunk.new_bytes.end as usize;
        prop_assert!(start <= end, "a reversed byte range");
        prop_assert!(
            end <= new.len(),
            "a byte range past the end of the document"
        );
        // Slicing panics on a non-boundary index, which is exactly the bug this
        // catches: an offset computed in characters rather than UTF-8 bytes.
        prop_assert!(new.is_char_boundary(start), "start is not a char boundary");
        prop_assert!(new.is_char_boundary(end), "end is not a char boundary");

        if !hunk.new.is_empty() && !diff.coarse {
            let span = &new[start..end];
            let expected: String = new
                .lines()
                .skip(hunk.new.start as usize)
                .take((hunk.new.end - hunk.new.start) as usize)
                .collect::<Vec<_>>()
                .join("\n");
            prop_assert!(
                span.starts_with(expected.as_str()) || expected.is_empty(),
                "byte range {start}..{end} = {span:?} does not begin the lines it names ({expected:?})"
            );
        }
    }
    Ok(())
}

// --- generators ------------------------------------------------------------

/// Lines drawn from a deliberately tiny alphabet, so random pairs actually
/// share content and the diff has something to find. A generator over free
/// text would produce two unrelated documents every time and only ever
/// exercise the all-changed path.
fn document() -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop_oneof![
            Just("alpha".to_owned()),
            Just("beta".to_owned()),
            Just("gamma".to_owned()),
            Just("".to_owned()),
            Just("# heading".to_owned()),
            Just("- [ ] a task".to_owned()),
            // Multi-byte, so a byte/character confusion in the offsets shows up.
            Just("🎉 party".to_owned()),
            Just("naïve".to_owned()),
        ],
        0..24,
    )
    .prop_map(|mut lines| {
        if lines.is_empty() {
            return String::new();
        }
        lines.push(String::new());
        lines.join("\n")
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn applying_the_hunks_yields_the_new_document(old in document(), new in document()) {
        let diff = lines::diff(&old, &new);
        assert_replays(&old, &new, &diff)?;
        assert_counts_agree(&diff)?;
        assert_ordered(&diff)?;
        assert_byte_ranges(&new, &diff)?;
    }

    #[test]
    fn a_document_against_itself_has_no_hunks(text in document()) {
        let diff = lines::diff(&text, &text);
        prop_assert!(diff.hunks.is_empty(), "{:?}", diff.hunks);
        prop_assert_eq!((diff.added, diff.removed), (0, 0));
        prop_assert!(!diff.coarse);
    }

    #[test]
    fn every_line_of_a_new_document_is_added(text in document()) {
        // The untracked-file case: `+N -0`, where N is what a reader counts.
        let diff = lines::diff("", &text);
        prop_assert_eq!(diff.added as usize, lines::count(&text));
        prop_assert_eq!(diff.removed, 0);
    }

    #[test]
    fn count_never_disagrees_with_the_diff(text in document()) {
        // `lines::count` feeds an untracked file's badge while `lines::diff`
        // feeds the gutter. If they ever disagree, one row shows two different
        // numbers for the same file.
        let diff = lines::diff(&text, "");
        prop_assert_eq!(diff.removed as usize, lines::count(&text));
    }

    #[test]
    fn marks_cover_exactly_the_changed_lines(old in document(), new in document()) {
        let diff = lines::diff(&old, &new);
        let marks = lines::marks(&diff);
        let total_new_lines = lines::count(&new) as u32;
        for line in marks.keys() {
            // A removal at end of document marks one past the last line, which
            // the ruler clamps; anything beyond that is a bug.
            prop_assert!(
                *line <= total_new_lines,
                "marked line {line} is past the document's {total_new_lines} lines"
            );
        }
        // Every non-empty new-side hunk range must be fully marked.
        for hunk in &diff.hunks {
            for line in hunk.new.clone() {
                prop_assert!(marks.contains_key(&line), "line {line} is in a hunk but unmarked");
            }
        }
    }
}
