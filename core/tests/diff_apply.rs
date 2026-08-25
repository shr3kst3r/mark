//! The property ADR-2's incremental patching rests on.
//!
//! > On a file change the core re-parses, diffs the block-hash sequence, and
//! > emits a minimal edit script; the shell patches only the affected blocks by
//! > `data-blk` and leaves every other DOM node untouched.
//!
//! and, from the same ADR's Consequences:
//!
//! > We are also accepting a **correctness surface**: a block-diff bug shows up
//! > as a subtly stale or duplicated document rather than a crash […] This needs
//! > tests that assert the patched DOM equals a freshly rendered one.
//!
//! So this file asserts two things about random document pairs:
//!
//! 1. **Identity.** Applying the edit script to the old block list yields
//!    exactly the new block list.
//! 2. **Content.** Concatenating the patched per-block HTML yields the same
//!    document a fresh whole-document render produces.
//!
//! Property (2) holds **up to the attributes that encode absolute position** —
//! `data-mk-start`, `data-mk-end`, `data-mk-idx`, and a heading's deduplicated
//! `id`. That is not a bug in the diff and it is not avoidable: ADR-2 requires
//! block ids to be content-derived so that inserting a paragraph does not
//! renumber the blocks below it, and the byte offset of every one of those
//! blocks nevertheless *did* move. A patch that leaves them untouched therefore
//! leaves stale position attributes behind, by construction.
//!
//! `stale_position_attributes_are_the_one_thing_a_patch_cannot_fix` below pins
//! that down as an executable statement rather than a comment, because the
//! consequence lands on M5's Swift half: after applying a patch the shell must
//! re-stamp task attributes from `mark_tasks_json(new_source)`, or a checkbox
//! click in an untouched block will write the wrong byte.

use std::collections::HashSet;

use mark_core::block::BlockId;
use mark_core::diff::{self, EditScript, Op};
use mark_core::parse::Document;
use mark_core::render::{self, RenderOptions};
use proptest::prelude::*;

// --- helpers ---------------------------------------------------------------

fn ids_of(doc: &Document<'_>) -> Vec<BlockId> {
    doc.blocks().iter().map(|block| block.id.clone()).collect()
}

fn whole(doc: &Document<'_>) -> String {
    render::render(doc, &RenderOptions::default()).html
}

/// Every block of `doc`, rendered on its own — the shell's DOM, as a list.
fn block_html(doc: &Document<'_>) -> Vec<String> {
    let ranges: Vec<_> = (0..doc.blocks().len()).map(|i| i..i + 1).collect();
    render::render_ranges(doc, &ranges, &mark_core::theme::default_pair())
        .into_iter()
        .map(|rendered| rendered.html)
        .collect()
}

/// Apply `script` to a list of per-block HTML, the way the shell applies it to
/// the DOM: keep untouched, drop deletes, splice in the HTML the script
/// carries.
fn patch(old_html: &[String], script: &EditScript) -> Result<String, String> {
    let mut out: Vec<String> = Vec::new();
    let mut cursor = 0usize;

    for (index, op) in script.ops.iter().enumerate() {
        match op {
            Op::Keep { count, .. } => {
                let end = cursor + count;
                if end > old_html.len() {
                    return Err(format!("op {index}: keep runs past the document"));
                }
                out.extend_from_slice(&old_html[cursor..end]);
                cursor = end;
            }
            Op::Delete { old_ids, .. } => cursor += old_ids.len(),
            Op::Insert { html, .. } => {
                out.push(
                    html.clone()
                        .ok_or(format!("op {index}: insert has no HTML"))?,
                );
            }
            Op::Replace { old_ids, html, .. } => {
                cursor += old_ids.len();
                out.push(
                    html.clone()
                        .ok_or(format!("op {index}: replace has no HTML"))?,
                );
            }
        }
    }
    Ok(out.concat())
}

/// Blank out every attribute whose value is an absolute position in the source
/// document, so the comparison is about *content* rather than about offsets
/// that a node-preserving patch is expected to leave stale.
fn without_positions(html: &str) -> String {
    const POSITIONAL: [&str; 4] = [
        "data-mk-start=\"",
        "data-mk-end=\"",
        "data-mk-idx=\"",
        "id=\"",
    ];

    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    'outer: while !rest.is_empty() {
        for name in POSITIONAL {
            if rest.starts_with(name) {
                out.push_str(name);
                out.push_str("*\"");
                let after = &rest[name.len()..];
                let close = after.find('"').map_or(after.len(), |at| at + 1);
                rest = &after[close..];
                continue 'outer;
            }
        }
        let mut chars = rest.chars();
        out.push(chars.next().expect("rest is not empty"));
        rest = chars.as_str();
    }
    out
}

/// Every `Op::Insert` names an anchor that is really the old block at its
/// index, or `None` at the end of the document. This is what makes the shell's
/// `querySelector('[data-blk=...]')` sound.
fn anchors_are_sound(script: &EditScript, old: &[BlockId]) -> Result<(), String> {
    for (index, op) in script.ops.iter().enumerate() {
        let Op::Insert {
            old_index, before, ..
        } = op
        else {
            continue;
        };
        match (before, old.get(*old_index)) {
            (Some(anchor), Some(block)) if anchor == block => {}
            (None, None) => {}
            (before, block) => {
                return Err(format!(
                    "op {index}: anchor {before:?} does not match old block {block:?} \
                     at index {old_index}"
                ));
            }
        }
    }
    Ok(())
}

/// Everything the diff promises about one pair of documents, in one call.
fn check_pair(old_source: &str, new_source: &str) -> EditScript {
    let old = Document::parse(old_source);
    let new = Document::parse(new_source);
    let script = diff::diff_documents(&old, &new, &mark_core::theme::default_pair());

    let old_ids = ids_of(&old);
    let new_ids = ids_of(&new);

    assert_eq!(
        script.apply(&old_ids).expect("the script applies"),
        new_ids,
        "the edit script did not reproduce the new block list\nold: {old_source:?}\nnew: {new_source:?}"
    );
    assert_eq!(script.old_blocks, old_ids.len());
    assert_eq!(script.new_blocks, new_ids.len());
    assert_eq!(
        script.kept + script.deleted + script.replaced,
        script.old_blocks,
        "counters do not account for every old block"
    );
    assert_eq!(
        script.kept + script.inserted + script.replaced,
        script.new_blocks,
        "counters do not account for every new block"
    );
    anchors_are_sound(&script, &old_ids).expect("insert anchors are sound");

    let patched = patch(&block_html(&old), &script).expect("the patch applies");
    assert_eq!(
        without_positions(&patched),
        without_positions(&whole(&new)),
        "the patched document differs from a fresh render\nold: {old_source:?}\nnew: {new_source:?}"
    );
    script
}

// --- example cases ---------------------------------------------------------

#[test]
fn an_empty_document_diffs_against_anything() {
    assert!(check_pair("", "").ops.is_empty());
    assert_eq!(check_pair("", "# H\n\npara\n").inserted, 2);
    assert_eq!(check_pair("# H\n\npara\n", "").deleted, 2);
}

#[test]
fn a_single_block_document() {
    let script = check_pair("just one paragraph\n", "just one paragraph\n");
    assert!(script.is_noop());
    let script = check_pair("just one paragraph\n", "a different paragraph\n");
    assert_eq!(script.replaced, 1);
}

#[test]
fn an_unchanged_document_is_all_keep() {
    let source = "# Title\n\nintro\n\n```rust\nfn main() {}\n```\n\n- [ ] a task\n";
    let script = check_pair(source, source);
    assert!(script.is_noop(), "{script:?}");
    assert_eq!(script.ops.len(), 1);
    assert_eq!(script.ops[0].tag(), "keep");
}

#[test]
fn a_document_where_every_block_changed() {
    let old = "alpha\n\nbravo\n\ncharlie\n\ndelta\n";
    let new = "one\n\ntwo\n\nthree\n\nfour\n";
    let script = check_pair(old, new);
    assert_eq!(script.kept, 0);
    assert_eq!(script.replaced, 4);
    assert_eq!(script.ops.len(), 1, "{script:?}");
    assert_eq!(script.ops[0].tag(), "replace");
}

#[test]
fn many_identical_blocks() {
    // Content-hash-plus-ordinal identity is most likely to go wrong here: the
    // blocks are indistinguishable except by their ordinal, so a diff that
    // matches on hash alone produces a plausible but wrong script.
    let old = "same\n\nsame\n\nsame\n\nsame\n\nsame\n\nsame\n";

    check_pair(old, "same\n\nsame\n\nsame\n\nsame\n\nsame\n");
    check_pair(
        old,
        "same\n\nsame\n\nsame\n\nsame\n\nsame\n\nsame\n\nsame\n",
    );
    check_pair(old, "new\n\nsame\n\nsame\n\nsame\n\nsame\n\nsame\n\nsame\n");
    check_pair(old, "same\n\nsame\n\nnew\n\nsame\n\nsame\n\nsame\n");
    check_pair(old, "same\n\nsame\n\nsame\n");
    check_pair(old, "");
    check_pair("", old);
}

#[test]
fn identical_blocks_keep_the_shared_prefix_rather_than_replacing_it() {
    // Not just correct — minimal. Dropping the last of six identical blocks
    // must touch one block, not six.
    let script = check_pair(
        "same\n\nsame\n\nsame\n\nsame\n\nsame\n\nsame\n",
        "same\n\nsame\n\nsame\n\nsame\n\nsame\n",
    );
    assert_eq!(script.kept, 5);
    assert_eq!(script.deleted, 1);
    assert_eq!(script.replaced, 0);
}

#[test]
fn a_one_word_edit_touches_one_block() {
    let old = "# Title\n\none\n\ntwo\n\nthree\n\nfour\n\nfive\n";
    let new = "# Title\n\none\n\nTWO\n\nthree\n\nfour\n\nfive\n";
    let script = check_pair(old, new);
    assert_eq!(script.replaced, 1);
    assert_eq!(script.kept, 5);
    assert_eq!(
        script.ops.iter().map(Op::tag).collect::<Vec<_>>(),
        ["keep", "replace", "keep"]
    );
}

#[test]
fn a_checkbox_toggle_patches_only_its_own_block() {
    // The M5 round trip, at the core's end of it.
    let old = "# Tasks\n\n- [ ] first\n\nnote\n\n- [ ] second\n";
    let new = "# Tasks\n\n- [x] first\n\nnote\n\n- [ ] second\n";
    let script = check_pair(old, new);
    assert_eq!(script.replaced, 1);
    assert_eq!(
        script.ops.iter().map(Op::tag).collect::<Vec<_>>(),
        ["keep", "replace", "keep"]
    );
    let Some(Op::Replace { html, .. }) = script.ops.iter().find(|op| op.tag() == "replace") else {
        panic!("expected a replace: {script:?}");
    };
    assert!(html.as_deref().unwrap().contains(" checked>"), "{script:?}");
}

#[test]
fn stale_position_attributes_are_the_one_thing_a_patch_cannot_fix() {
    // Executable form of the caveat in this file's header, and the reason M5's
    // Swift half must re-stamp task attributes after a patch.
    //
    // A task is inserted above an existing one. The lower task's block is
    // content-identical, so ADR-2 requires its id to be unchanged and the diff
    // to keep it — but in the new document that task is `data-mk-idx="1"`,
    // while the kept DOM node still says `data-mk-idx="0"`.
    //
    // The thematic break is not decoration: two task items separated by a blank
    // line are one loose list, i.e. one block, and there would be nothing to
    // keep.
    let old = "- [ ] second\n\ntrailing\n";
    let new = "- [ ] first\n\n***\n\n- [ ] second\n\ntrailing\n";

    let old_doc = Document::parse(old);
    let new_doc = Document::parse(new);
    let script = diff::diff_documents(&old_doc, &new_doc, &mark_core::theme::default_pair());

    assert_eq!(
        script.ops.iter().map(Op::tag).collect::<Vec<_>>(),
        ["insert", "keep"],
        "the lower block must be kept, or ADR-2's whole point is lost"
    );

    let patched = patch(&block_html(&old_doc), &script).expect("the patch applies");
    let fresh = whole(&new_doc);

    // Identical once positions are blanked...
    assert_eq!(without_positions(&patched), without_positions(&fresh));
    // ...and genuinely different before that.
    assert_ne!(patched, fresh);
    assert_eq!(patched.matches("data-mk-idx=\"0\"").count(), 2);
    assert_eq!(fresh.matches("data-mk-idx=\"0\"").count(), 1);
    assert_eq!(fresh.matches("data-mk-idx=\"1\"").count(), 1);
}

#[test]
fn an_edit_that_moves_no_byte_offsets_patches_byte_for_byte() {
    // The complement of the test above: when the edit disturbs no other
    // block's position, "the patched DOM equals a freshly rendered one" holds
    // exactly, with no normalization at all.
    //
    // "Confined to the tail" is not enough for that, and the reason is worth
    // recording. Appending a paragraph changes the *previous* block's
    // `data-mk-end`, because a block's span runs to the start of the next one.
    // The block's id is unaffected — `parse::build` hashes the trimmed slice
    // precisely so trailing blank lines belong to the document's layout rather
    // than to the block's identity — so the diff still keeps it, and the kept
    // node's stale `data-mk-end` is the same class of staleness as above.
    //
    // A same-length replacement of the last block moves nothing.
    let old = "# Title\n\nintro\n\nalpha\n";
    let new = "# Title\n\nintro\n\nbravo\n";

    let old_doc = Document::parse(old);
    let new_doc = Document::parse(new);
    let script = diff::diff_documents(&old_doc, &new_doc, &mark_core::theme::default_pair());
    assert_eq!(
        script.ops.iter().map(Op::tag).collect::<Vec<_>>(),
        ["keep", "replace"]
    );
    let patched = patch(&block_html(&old_doc), &script).expect("the patch applies");
    assert_eq!(patched, whole(&new_doc));
}

#[test]
fn appending_a_block_leaves_the_previous_block_id_alone() {
    // The property that makes the test above's caveat tolerable: the span
    // shifts, the identity does not, so an append is one insert rather than a
    // replace of the tail.
    let old = Document::parse("# Title\n\nintro\n\n- [ ] task\n");
    let new = Document::parse("# Title\n\nintro\n\n- [ ] task\n\nappended\n");
    let script = diff::diff_documents(&old, &new, &mark_core::theme::default_pair());
    assert_eq!(
        script.ops.iter().map(Op::tag).collect::<Vec<_>>(),
        ["keep", "insert"]
    );
    assert_eq!(script.kept, 3);
    assert_eq!(script.inserted, 1);
}

#[test]
fn block_ids_are_unique_within_every_document_we_diff() {
    // Anchoring an insert by `data-blk` requires this; a duplicate would make
    // `querySelector` pick an arbitrary one.
    for source in [
        "same\n\nsame\n\nsame\n",
        "---\n\n---\n\n---\n",
        "- a\n\n- a\n\n> q\n\n> q\n",
        "",
    ] {
        let doc = Document::parse(source);
        let mut seen = HashSet::new();
        for block in doc.blocks() {
            assert!(
                seen.insert(block.id.clone()),
                "duplicate data-blk {} in {source:?}",
                block.id
            );
        }
    }
}

// --- properties ------------------------------------------------------------

/// Fragments that each form one top-level block, chosen for the constructs
/// that carry contracts (tasks, code, headings) plus the ones that repeat
/// (rules, short paragraphs) and so stress ordinal-based identity.
fn fragment() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("paragraph\n\n".to_owned()),
        Just("another paragraph\n\n".to_owned()),
        Just("# Heading\n\n".to_owned()),
        Just("## Heading\n\n".to_owned()),
        Just("---\n\n".to_owned()),
        Just("> quoted\n\n".to_owned()),
        Just("- [ ] open\n\n".to_owned()),
        Just("- [x] done\n\n".to_owned()),
        Just("```rust\nfn main() {}\n```\n\n".to_owned()),
        Just("```\nplain fence\n```\n\n".to_owned()),
        Just("| a | b |\n|---|---|\n| 1 | 2 |\n\n".to_owned()),
        Just("naïve — ünicode ✅\n\n".to_owned()),
        "[a-z]{1,12}\n\n".prop_map(|text| text),
    ]
}

/// A document as a list of fragments. The fixed first fragment keeps a leading
/// `---` from being parsed as YAML frontmatter, which would swallow content and
/// make the generator test something other than what it says.
fn fragments() -> impl Strategy<Value = Vec<String>> {
    prop::collection::vec(fragment(), 0..14).prop_map(|mut parts| {
        parts.insert(0, "# Document\n\n".to_owned());
        parts
    })
}

/// One structural edit to a fragment list.
#[derive(Debug, Clone)]
enum Edit {
    Insert(usize, String),
    Delete(usize),
    Replace(usize, String),
    Duplicate(usize),
    Swap(usize, usize),
}

fn edit() -> impl Strategy<Value = Edit> {
    prop_oneof![
        (0usize..24, fragment()).prop_map(|(at, text)| Edit::Insert(at, text)),
        (0usize..24).prop_map(Edit::Delete),
        (0usize..24, fragment()).prop_map(|(at, text)| Edit::Replace(at, text)),
        (0usize..24).prop_map(Edit::Duplicate),
        (0usize..24, 0usize..24).prop_map(|(a, b)| Edit::Swap(a, b)),
    ]
}

fn apply_edits(parts: &[String], edits: &[Edit]) -> Vec<String> {
    let mut parts = parts.to_vec();
    for edit in edits {
        match edit {
            Edit::Insert(at, text) => {
                let at = at % (parts.len() + 1);
                parts.insert(at, text.clone());
            }
            Edit::Delete(at) => {
                if !parts.is_empty() {
                    parts.remove(at % parts.len());
                }
            }
            Edit::Replace(at, text) => {
                if !parts.is_empty() {
                    let at = at % parts.len();
                    parts[at] = text.clone();
                }
            }
            Edit::Duplicate(at) => {
                if !parts.is_empty() {
                    let at = at % parts.len();
                    let copy = parts[at].clone();
                    parts.insert(at, copy);
                }
            }
            Edit::Swap(a, b) => {
                if !parts.is_empty() {
                    let (a, b) = (a % parts.len(), b % parts.len());
                    parts.swap(a, b);
                }
            }
        }
    }
    parts
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// The property this whole module exists for, over documents that are
    /// plausible edits of one another — the file-watcher and typing cases.
    #[test]
    fn an_edit_script_reproduces_the_edited_document(
        parts in fragments(),
        edits in prop::collection::vec(edit(), 0..6),
    ) {
        let old: String = parts.concat();
        let new: String = apply_edits(&parts, &edits).concat();
        check_pair(&old, &new);
    }

    /// The same property over two *unrelated* documents, which is where the
    /// edit-distance cap and the coarse fallback live.
    #[test]
    fn an_edit_script_reproduces_an_unrelated_document(
        old_parts in fragments(),
        new_parts in fragments(),
    ) {
        check_pair(&old_parts.concat(), &new_parts.concat());
    }

    /// Diffing a document against itself is always a single keep, whatever it
    /// contains. A stray insert or delete here would mean the file watcher
    /// repaints on every unrelated save.
    #[test]
    fn a_document_never_differs_from_itself(parts in fragments()) {
        let source: String = parts.concat();
        let script = check_pair(&source, &source);
        prop_assert!(script.is_noop(), "{script:?}");
        prop_assert!(script.ops.len() <= 1, "{script:?}");
    }
}
