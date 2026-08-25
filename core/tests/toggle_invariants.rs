//! Property tests for the one operation that writes to a user's file.
//!
//! ADR-1 states the contract: "Toggling is a byte-range in-place edit of the
//! character between the brackets." Four invariants follow, and they are
//! property-tested rather than example-tested because the failure mode —
//! writing the wrong byte into somebody's notes — is expensive and silent.
//!
//! 1. Exactly one byte changes.
//! 2. Total length is unchanged.
//! 3. No byte outside the target marker span differs.
//! 4. Toggling twice restores the input byte for byte.

use mark_core::tasks::{self, Action};
use proptest::prelude::*;

/// Build a document out of fragments that includes tasks, prose brackets, code
/// fences, headings, and multi-byte text — i.e. everything that has ever fooled
/// a checkbox implementation.
fn document() -> impl Strategy<Value = String> {
    let fragment = prop_oneof![
        Just("- [ ] open task\n".to_owned()),
        Just("- [x] done task\n".to_owned()),
        Just("- [X] shouty task\n".to_owned()),
        Just("1. [ ] ordered task\n".to_owned()),
        Just("2. [x] ordered done\n".to_owned()),
        Just("- [ ] naïve — ünicode ✅\n".to_owned()),
        Just("  - [ ] nested task\n".to_owned()),
        Just("\nA literal [ ] in prose.\n\n".to_owned()),
        Just("\n# A heading\n\n".to_owned()),
        Just("\n```\n- [ ] inside a fence\n```\n\n".to_owned()),
        Just("\n> - [ ] quoted task\n\n".to_owned()),
        Just("\nplain paragraph text\n\n".to_owned()),
        "[a-z ]{0,20}\n".prop_map(|s| s),
    ];
    prop::collection::vec(fragment, 1..12).prop_map(|parts| parts.concat())
}

/// `source` with the marker character at `offset` lowercased — the only
/// difference a toggle round trip is allowed to leave behind.
fn canonical_marker_case(source: &str, offset: usize) -> String {
    let mut bytes = source.as_bytes().to_vec();
    if bytes.get(offset) == Some(&b'X') {
        bytes[offset] = b'x';
    }
    String::from_utf8(bytes).expect("lowercasing an ASCII byte keeps this UTF-8")
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![Just(Action::On), Just(Action::Off), Just(Action::Toggle)]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// Toggling any valid index changes exactly one byte, and only inside the
    /// marker span.
    #[test]
    fn toggle_changes_exactly_one_byte_inside_the_marker(
        source in document(),
        index in 0usize..16,
        action in action(),
    ) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();
        let task = &tasks[index];

        let toggled = tasks::toggle(&source, index, action).expect("valid index toggles");

        prop_assert_eq!(source.len(), toggled.source.len(), "length changed");

        let differing: Vec<usize> = source
            .bytes()
            .zip(toggled.source.bytes())
            .enumerate()
            .filter(|(_, (a, b))| a != b)
            .map(|(i, _)| i)
            .collect();

        // On/off against an already-correct box legitimately changes nothing.
        prop_assert!(differing.len() <= 1, "changed {} bytes: {:?}", differing.len(), differing);
        if let Some(offset) = differing.first() {
            prop_assert!(
                (task.start..task.end).contains(offset),
                "byte {} is outside the marker span {}..{}",
                offset, task.start, task.end
            );
            prop_assert_eq!(*offset, toggled.offset);
        }
    }

    /// Toggling twice is the identity, with one documented exception: GFM
    /// allows `[X]` as well as `[x]`, and once the box has been cleared to
    /// `[ ]` the original letter case is gone, so re-checking writes the
    /// canonical lowercase `x`. That is still a single byte inside the marker
    /// span; it is recorded here rather than papered over, because "round-trips
    /// byte for byte" is otherwise a claim a reader would take literally.
    #[test]
    fn toggling_twice_restores_the_document(source in document(), index in 0usize..16) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();

        let once = tasks::toggle(&source, index, Action::Toggle).expect("valid index");
        let twice = tasks::toggle(&once.source, index, Action::Toggle).expect("still valid");

        let expected = canonical_marker_case(&source, tasks[index].start + 1);
        prop_assert_eq!(&twice.source, &expected);
    }

    /// A toggle never invents, removes, or reorders tasks — the identity ADR-1
    /// defines is `(file, task-index)`, so an edit that renumbered would break
    /// every index a caller is holding.
    #[test]
    fn toggle_preserves_the_task_list_shape(source in document(), index in 0usize..16) {
        let before = tasks::enumerate_source(&source);
        prop_assume!(!before.is_empty());
        let index = index % before.len();

        let toggled = tasks::toggle(&source, index, Action::Toggle).expect("valid index");
        let after = tasks::enumerate_source(&toggled.source);

        prop_assert_eq!(before.len(), after.len());
        for (before, after) in before.iter().zip(&after) {
            prop_assert_eq!(before.start, after.start);
            prop_assert_eq!(before.end, after.end);
            prop_assert_eq!(&before.text, &after.text);
        }
        prop_assert_eq!(after[index].checked, !before[index].checked);
    }

    /// An out-of-range index is refused, and refusing costs nothing.
    #[test]
    fn out_of_range_indices_are_refused(source in document(), overshoot in 0usize..8) {
        let total = tasks::enumerate_source(&source).len();
        let error = tasks::toggle(&source, total + overshoot, Action::Toggle)
            .expect_err("index past the end must fail");
        let refused = matches!(
            error,
            tasks::TaskError::IndexOutOfRange { total: reported, .. } if reported == total
        );
        prop_assert!(refused, "unexpected error: {error}");
    }

    /// `--on` and `--off` are idempotent, so an agent retrying a command cannot
    /// flip a box it already set.
    #[test]
    fn on_and_off_are_idempotent(source in document(), index in 0usize..16) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();

        for action in [Action::On, Action::Off] {
            let once = tasks::toggle(&source, index, action).expect("valid index");
            let twice = tasks::toggle(&once.source, index, action).expect("valid index");
            prop_assert_eq!(&once.source, &twice.source);
        }
    }
}
