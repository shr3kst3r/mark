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
//! 4. Toggling twice restores the input byte for byte — **for a marker that was
//!    open or done**.
//!
//! `2026-08-27-five-task-states` narrows the fourth deliberately, and this is
//! the file where that shows. Toggle is open→done, done→open, and every other
//! state → done, because ticking a box ticks it; no mapping out of
//! in-progress, cancelled or blocked round-trips, and a click that silently
//! does nothing would be worse than one that does not. The first three
//! invariants are untouched: a state is still exactly one byte between the
//! brackets.

use mark_core::tasks::{self, Action, State};
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
        // The five states, and the shapes that must stay *out* of the task
        // list: an unrecognised byte, two bytes, a marker with no trailing
        // whitespace, and a bracket in prose.
        Just("- [/] in progress\n".to_owned()),
        Just("- [-] cancelled\n".to_owned()),
        Just("- [?] blocked\n".to_owned()),
        Just("- [-] with @due(2026-09-01) and !! metadata\n".to_owned()),
        Just("  - [?] nested and blocked\n".to_owned()),
        Just("1. [/] ordered and in progress\n".to_owned()),
        Just("\n> - [-] quoted and cancelled\n\n".to_owned()),
        Just("- [!] not a marker\n".to_owned()),
        Just("- [ab] not a marker either\n".to_owned()),
        Just("- [-]nospace\n".to_owned()),
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

/// All six actions, which is the ABI's whole `action` domain.
fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        Just(Action::On),
        Just(Action::Off),
        Just(Action::Toggle),
        Just(Action::InProgress),
        Just(Action::Cancel),
        Just(Action::Block),
    ]
}

/// Every state, for the per-target-state properties.
fn state() -> impl Strategy<Value = State> {
    prop_oneof![
        Just(State::Open),
        Just(State::InProgress),
        Just(State::Done),
        Just(State::Cancelled),
        Just(State::Blocked),
    ]
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

    /// Toggling twice is the identity **when the marker was open or done**,
    /// with one documented exception: GFM allows `[X]` as well as `[x]`, and
    /// once the box has been cleared to `[ ]` the original letter case is gone,
    /// so re-checking writes the canonical lowercase `x`. That is still a single
    /// byte inside the marker span; it is recorded here rather than papered
    /// over, because "round-trips byte for byte" is otherwise a claim a reader
    /// would take literally.
    ///
    /// The narrowing to open/done is `2026-08-27-five-task-states`', not a
    /// weakening for convenience: see `toggle_is_a_one_way_exit_from_the_
    /// extended_states` below, which asserts what happens instead.
    #[test]
    fn toggling_twice_restores_an_open_or_done_document(
        source in document(),
        index in 0usize..16,
    ) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();
        prop_assume!(matches!(tasks[index].state, State::Open | State::Done));

        let once = tasks::toggle(&source, index, Action::Toggle).expect("valid index");
        let twice = tasks::toggle(&once.source, index, Action::Toggle).expect("still valid");

        let expected = canonical_marker_case(&source, tasks[index].start + 1);
        prop_assert_eq!(&twice.source, &expected);
    }

    /// ...and toggling anything else lands on done and stays there, which is
    /// the behaviour that costs the round trip.
    #[test]
    fn toggle_is_a_one_way_exit_from_the_extended_states(
        source in document(),
        index in 0usize..16,
    ) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();
        prop_assume!(!matches!(tasks[index].state, State::Open | State::Done));

        let once = tasks::toggle(&source, index, Action::Toggle).expect("valid index");
        prop_assert_eq!(once.state, State::Done);
        // And it is now an ordinary done marker, so the next toggle opens it.
        let twice = tasks::toggle(&once.source, index, Action::Toggle).expect("still valid");
        prop_assert_eq!(twice.state, State::Open);
    }

    /// Cycling through every state and back to the start restores the
    /// document, which is the general form invariant 4 used to state for two.
    #[test]
    fn cycling_through_every_state_restores_the_document(
        source in document(),
        index in 0usize..16,
    ) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();
        let start = tasks[index].state;

        let mut current = source.clone();
        for state in State::ALL {
            current = tasks::toggle(&current, index, Action::for_state(state))
                .expect("valid index")
                .source;
        }
        current = tasks::toggle(&current, index, Action::for_state(start))
            .expect("valid index")
            .source;

        let expected = canonical_marker_case(&source, tasks[index].start + 1);
        prop_assert_eq!(&current, &expected);
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
        // The boolean relation this used to assert — `after.checked ==
        // !before.checked` — is not expressible over five states. What survives
        // is the cycle relation: toggle maps open↔done and everything else to
        // done, and `checked` is "terminal", so it can only change in the
        // directions `Action::Toggle` allows.
        prop_assert_eq!(
            after[index].state,
            Action::Toggle.apply(before[index].state)
        );
        prop_assert_eq!(after[index].checked, after[index].state.is_terminal());
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

    /// Setting a state is idempotent, for **every** state, so an agent
    /// retrying a command cannot flip a box it already set. (`Toggle` is
    /// excluded by construction: it is the one action that is not a target.)
    #[test]
    fn setting_a_state_is_idempotent(
        source in document(),
        index in 0usize..16,
        target in state(),
    ) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();

        let action = Action::for_state(target);
        let once = tasks::toggle(&source, index, action).expect("valid index");
        let twice = tasks::toggle(&once.source, index, action).expect("valid index");
        prop_assert_eq!(&once.source, &twice.source);
        prop_assert_eq!(twice.state, target);
    }

    /// Whatever the action, the result is one of the five states and `checked`
    /// agrees with it — the property `Task::checked`'s new definition rests on.
    #[test]
    fn a_write_always_lands_on_a_recognised_state(
        source in document(),
        index in 0usize..16,
        action in action(),
    ) {
        let tasks = tasks::enumerate_source(&source);
        prop_assume!(!tasks.is_empty());
        let index = index % tasks.len();

        let toggled = tasks::toggle(&source, index, action).expect("valid index");
        prop_assert_eq!(toggled.state, action.apply(tasks[index].state));
        prop_assert_eq!(toggled.checked, toggled.state.is_terminal());
        prop_assert_eq!(
            toggled.source.as_bytes()[toggled.offset],
            toggled.state.byte()
        );
        // The task list's shape is unchanged by *any* of the six actions: no
        // state change can invent, remove or renumber a task.
        let after = tasks::enumerate_source(&toggled.source);
        prop_assert_eq!(tasks.len(), after.len());
    }
}
