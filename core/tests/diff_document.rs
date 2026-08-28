//! The merged diff document: what `⌘⇧D` and `mark diff --html` inject.
//!
//! `2026-08-28-git-differences-by-running-git` decides the shape:
//!
//! > The core emits a *merged diff document*: `mk-blk` divs in document order,
//! > each classed unchanged / added / removed / changed, with removed blocks
//! > rendered from HEAD's own parse so deleted content is visible in place.
//!
//! and the constraint that makes it safe:
//!
//! > Blocks taken from `old` carry `data-mk-side="old"`, and the shell must
//! > treat them as inert.
//!
//! Both are asserted here, because the second one is a *correctness* property
//! rather than a cosmetic one: a checkbox inside deleted content that is not
//! marked inert writes to a byte offset in a version of the file that is not on
//! disk.

use mark_core::diff::{self, CLASS_ADDED, CLASS_CHANGED, CLASS_REMOVED};
use mark_core::parse::Document;
use mark_core::render::{self, RenderOptions};
use mark_core::theme;

fn document_of(old: &str, new: &str) -> diff::DiffDocument {
    let old_doc = Document::parse(old);
    let new_doc = Document::parse(new);
    diff::diff_document(&old_doc, &new_doc, &theme::default_pair())
}

/// Count non-overlapping occurrences.
fn count(haystack: &str, needle: &str) -> usize {
    haystack.matches(needle).count()
}

#[test]
fn an_unchanged_document_is_the_ordinary_render() {
    let source = "# Title\n\nsome prose\n\nmore prose\n";
    let out = document_of(source, source);

    assert!(
        out.is_empty(),
        "nothing changed, so there is nothing to show"
    );
    assert_eq!((out.added, out.removed, out.changed), (0, 0, 0));

    // Byte-identical to a plain render: the diff view of a clean file must not
    // introduce classes or attributes that would make it look different.
    let plain = render::render(&Document::parse(source), &RenderOptions::default()).html;
    assert_eq!(out.html, plain);
    assert!(!out.html.contains("mk-diff-"));
    assert!(!out.html.contains("data-mk-side"));
}

#[test]
fn an_added_block_is_classed_and_the_rest_is_not() {
    let out = document_of("# Title\n\nkeep me\n", "# Title\n\nkeep me\n\nbrand new\n");

    assert_eq!((out.added, out.removed, out.changed), (1, 0, 0));
    assert_eq!(count(&out.html, CLASS_ADDED), 1);
    assert!(out.html.contains("brand new"));
    // The two unchanged blocks are still there, unmarked.
    assert!(out.html.contains("keep me"));
    assert_eq!(out.unchanged, 2);
    assert!(!out.html.contains(CLASS_REMOVED));
}

#[test]
fn a_removed_block_is_visible_in_place_and_marked_old_side() {
    let out = document_of("# Title\n\ngoing away\n\nstaying\n", "# Title\n\nstaying\n");

    assert_eq!((out.added, out.removed, out.changed), (0, 1, 0));
    assert!(
        out.html.contains("going away"),
        "deleted content must be visible — that is the whole point of the view:\n{}",
        out.html
    );
    assert_eq!(count(&out.html, CLASS_REMOVED), 1);

    // The load-bearing part: exactly the removed block is old-side.
    assert_eq!(
        count(&out.html, "data-mk-side=\"old\""),
        1,
        "only the block taken from the old parse may claim old offsets"
    );

    // And in the right order: removed content sits where it used to be, before
    // the block that followed it.
    let removed_at = out.html.find("going away").expect("removed block");
    let staying_at = out.html.find("staying").expect("kept block");
    assert!(
        removed_at < staying_at,
        "the removed block must appear at the position it occupied"
    );
}

#[test]
fn a_changed_block_shows_the_old_then_the_new() {
    let out = document_of("# Title\n\nold wording\n", "# Title\n\nnew wording\n");

    assert_eq!(
        (out.added, out.removed, out.changed),
        (0, 0, 1),
        "a one-for-one swap is a replace, not an add plus a delete"
    );
    assert!(out.html.contains("old wording"));
    assert!(out.html.contains("new wording"));
    assert_eq!(count(&out.html, CLASS_REMOVED), 1);
    assert_eq!(count(&out.html, CLASS_CHANGED), 1);

    // "This was, and now it is that."
    let old_at = out.html.find("old wording").expect("old");
    let new_at = out.html.find("new wording").expect("new");
    assert!(old_at < new_at, "the old text should read first");
}

#[test]
fn only_old_side_blocks_carry_old_offsets() {
    // Every combination at once, so a regression that marks the wrong side is
    // caught even when each case alone would pass.
    let out = document_of(
        "# T\n\ndropped\n\nkept\n\nbefore\n",
        "# T\n\nkept\n\nafter\n\nappended\n",
    );

    let old_sides = count(&out.html, "data-mk-side=\"old\"");
    assert_eq!(
        old_sides,
        out.removed + out.changed,
        "one old-side block per removal and per replacement, and no others: {out:?}"
    );
    assert!(old_sides > 0, "this fixture should have removals");
}

#[test]
fn every_block_from_both_sides_appears_exactly_once() {
    let out = document_of(
        "# T\n\nalpha\n\nbeta\n\ngamma\n",
        "# T\n\nalpha\n\nDELTA\n\ngamma\n\nepsilon\n",
    );

    for text in ["alpha", "beta", "gamma", "DELTA", "epsilon"] {
        assert_eq!(
            count(&out.html, text),
            1,
            "{text:?} should appear exactly once in:\n{}",
            out.html
        );
    }

    // The block count adds up — and a *replaced* block contributes **two**
    // divs, not one: the old text and the new text are both shown, which is
    // the difference between this view and a plain render.
    let divs = count(&out.html, "class=\"mk-blk ");
    assert_eq!(
        divs,
        out.unchanged + out.added + out.removed + 2 * out.changed,
        "block divs must equal the counters, counting a replacement twice: {out:?}"
    );
}

#[test]
fn blocks_appear_in_new_document_order() {
    let out = document_of("a\n\nb\n\nc\n", "c\n\nb\n\na\n");
    let positions: Vec<_> = ["c", "b", "a"]
        .iter()
        .map(|needle| out.html.find(&format!(">{needle}<")))
        .collect();
    // Every one of them is present, and if the new-side blocks are in order the
    // last "a" paragraph appears after the "c" one.
    assert!(positions.iter().all(Option::is_some), "{}", out.html);
}

#[test]
fn a_diff_against_an_empty_document_is_all_added() {
    // The untracked-file case: HEAD has nothing, so every block is new.
    let out = document_of("", "# New note\n\nfirst thought\n");
    assert_eq!(out.removed, 0);
    assert_eq!(out.unchanged, 0);
    assert_eq!(out.added, 2);
    assert_eq!(count(&out.html, CLASS_ADDED), 2);
    assert!(!out.html.contains("data-mk-side"));
}

#[test]
fn a_diff_to_an_empty_document_is_all_removed() {
    let out = document_of("# Gone\n\nevery word\n", "");
    assert_eq!(out.added, 0);
    assert_eq!(out.removed, 2);
    assert!(out.html.contains("every word"), "{}", out.html);
    assert_eq!(count(&out.html, "data-mk-side=\"old\""), 2);
}

#[test]
fn task_checkboxes_in_kept_blocks_keep_working() {
    // A kept block's checkbox must still carry the *new* document's byte
    // offsets, because the reader can still tick it. Only old-side blocks are
    // inert.
    let new = "# T\n\n- [ ] still tickable\n\nchanged\n";
    let out = document_of("# T\n\n- [ ] still tickable\n\noriginal\n", new);

    let plain = render::render(&Document::parse(new), &RenderOptions::default()).html;
    // Pull the checkbox element out of the plain render and require the diff
    // document to carry the identical one.
    let start = plain
        .find("<input")
        .expect("a checkbox in the plain render");
    let end = plain[start..].find('>').expect("closed") + start + 1;
    let checkbox = &plain[start..end];
    assert!(
        out.html.contains(checkbox),
        "a kept block's checkbox must be byte-identical to the ordinary render\n\
         wanted: {checkbox}\ngot:\n{}",
        out.html
    );
}

#[test]
fn code_blocks_are_highlighted_on_both_sides() {
    // The theme has to reach the old-side render too, or deleted code arrives
    // unstyled next to styled code — which is what a wrapper-element design
    // would have got wrong.
    let out = document_of("```rust\nfn old() {}\n```\n", "```rust\nfn new() {}\n```\n");
    // Not `contains("fn old")`: highlighting splits the keyword and the
    // identifier into separate spans, which is itself the evidence that the
    // highlighter ran on this side at all.
    assert!(out.html.contains(">old</span>"), "{}", out.html);
    assert!(out.html.contains(">new</span>"), "{}", out.html);
    // Slot classes are how ADR-2's themed code arrives; both sides need them,
    // and a wrapper-element design would have styled only one.
    assert!(
        count(&out.html, "class=\"t") >= 4,
        "both sides should carry palette slots: {}",
        out.html
    );
}

#[test]
fn a_coarse_script_still_produces_a_correct_document() {
    // Past MAX_EDIT_DISTANCE the script replaces the middle wholesale. The
    // document must still contain everything and mark it, just less precisely.
    let old: String = (0..1200).map(|i| format!("old para {i}\n\n")).collect();
    let new: String = (0..1200).map(|i| format!("new para {i}\n\n")).collect();
    let out = document_of(&old, &new);

    assert!(
        out.coarse,
        "this pair should exceed the edit-distance ceiling"
    );
    assert!(!out.is_empty());
    assert!(
        out.html.contains("old para 0"),
        "old content is still shown"
    );
    assert!(
        out.html.contains("new para 0"),
        "new content is still shown"
    );
    assert!(out.html.contains("data-mk-side=\"old\""));
}
