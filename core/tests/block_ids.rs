//! Block identity, per ADR-2 (`2026-08-24-progressive-document-rendering`).
//!
//! > Block ids are content-derived, never positional. Any change making them
//! > positional breaks incremental patching's whole point.
//!
//! The property that makes that concrete: inserting a paragraph must not change
//! the `data-blk` of any block below it. It is the easiest thing in the whole
//! project to regress silently — a positional id looks identical in every
//! single-document test and only fails once M5 starts patching.

use mark_core::block::BlockId;
use mark_core::parse::Document;
use mark_core::render::{RenderOptions, render};

fn ids(source: &str) -> Vec<BlockId> {
    Document::parse(source)
        .blocks()
        .iter()
        .map(|b| b.id.clone())
        .collect()
}

const DOCUMENT: &str = "\
# Title

First paragraph.

## Section

Second paragraph.

```rust
fn main() {}
```

- a list
- with items

Last paragraph.
";

#[test]
fn inserting_a_paragraph_does_not_renumber_the_blocks_below_it() {
    let before = ids(DOCUMENT);

    let insertion_point = DOCUMENT.find("## Section").expect("fixture has a section");
    let after_source = format!(
        "{}An inserted paragraph.\n\n{}",
        &DOCUMENT[..insertion_point],
        &DOCUMENT[insertion_point..]
    );
    let after = ids(&after_source);

    assert_eq!(
        after.len(),
        before.len() + 1,
        "expected exactly one new block"
    );

    // Everything above the insertion is unchanged...
    assert_eq!(&after[..2], &before[..2]);
    // ...and so is everything below it, only shifted by one position.
    assert_eq!(&after[3..], &before[2..]);
}

#[test]
fn inserting_at_the_very_top_leaves_every_other_id_alone() {
    let before = ids(DOCUMENT);
    let after = ids(&format!("A new opening paragraph.\n\n{DOCUMENT}"));

    assert_eq!(after.len(), before.len() + 1);
    assert_eq!(&after[1..], &before[..]);
}

#[test]
fn deleting_a_block_leaves_the_survivors_alone() {
    let before = ids(DOCUMENT);
    let removed = DOCUMENT.replace("Second paragraph.\n\n", "");
    let after = ids(&removed);

    assert_eq!(after.len(), before.len() - 1);
    let mut expected = before.clone();
    expected.remove(3);
    assert_eq!(after, expected);
}

#[test]
fn editing_one_block_changes_only_that_id() {
    let before = ids(DOCUMENT);
    let after = ids(&DOCUMENT.replace("First paragraph.", "First paragraph, edited."));

    assert_eq!(after.len(), before.len());
    let changed: Vec<usize> = before
        .iter()
        .zip(&after)
        .enumerate()
        .filter(|(_, (a, b))| a != b)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(changed, vec![1]);
}

#[test]
fn identical_blocks_are_distinguished_by_ordinal_not_position() {
    let source = "same\n\nsame\n\nsame\n";
    let ids = ids(source);

    // Same hash, different ordinals.
    let hashes: Vec<&str> = ids
        .iter()
        .map(|id| id.as_str().split('-').next().unwrap())
        .collect();
    assert_eq!(hashes[0], hashes[1]);
    assert_eq!(hashes[1], hashes[2]);
    assert_eq!(
        ids.iter().map(BlockId::as_str).collect::<Vec<_>>(),
        vec![
            format!("{}-0", hashes[0]),
            format!("{}-1", hashes[0]),
            format!("{}-2", hashes[0]),
        ]
    );

    // Prepending a *different* block leaves all three untouched.
    let after = self::ids(&format!("different\n\n{source}"));
    assert_eq!(&after[1..], &ids[..]);
}

#[test]
fn ids_are_stable_across_processes_and_runs() {
    // Not a tautology: a `DefaultHasher`-based id would pass a
    // same-process comparison and fail this one, because its seed is
    // randomised per process. The literal is the guard.
    let ids = ids("# Title\n");
    assert_eq!(ids[0].as_str(), "204b8185e5e3edc9-0");
}

#[test]
fn trailing_blank_lines_do_not_change_an_id() {
    // Otherwise editing a *neighbour* would move a block's id, which is the
    // same failure as a positional id wearing a disguise.
    assert_eq!(ids("para\n"), ids("para\n\n\n"));
}

#[test]
fn kind_is_part_of_identity() {
    let paragraph = ids("foo\n");
    let code = ids("    foo\n");
    assert_ne!(paragraph[0], code[0]);
}

#[test]
fn rendered_html_carries_the_same_ids_the_parser_reports() {
    let doc = Document::parse(DOCUMENT);
    let html = render(&doc, &RenderOptions::default()).html;
    for block in doc.blocks() {
        assert!(
            html.contains(&format!("data-blk=\"{}\"", block.id)),
            "block {} missing from the rendered HTML",
            block.id
        );
    }
    assert_eq!(html.matches("data-blk=").count(), doc.blocks().len());
}
