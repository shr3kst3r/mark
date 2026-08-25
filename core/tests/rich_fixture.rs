//! M6's gate, against the committed fixture: every construct ADR-5 governs in
//! one document, rendered once.
//!
//! The unit tests in `src/rich.rs` prove each renderer in isolation. This file
//! proves they are *wired in* — that a `$…$` in a task label reaches
//! `pulldown-latex`, that a `mermaid` fence reaches `merman` and a `rust` fence
//! does not, and that a failure of either shows as a badge rather than as a
//! blank region or a panic.

use std::fs;
use std::path::Path;

use mark_core::parse::Document;
use mark_core::render::{RenderOptions, render};

fn fixture() -> String {
    fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rich.md"))
        .expect("fixture is committed")
}

fn html() -> String {
    render(&Document::parse(&fixture()), &RenderOptions::default()).html
}

#[test]
fn the_fixture_renders_every_construct_without_panicking() {
    let source = fixture();
    let out = render(&Document::parse(&source), &RenderOptions::default());

    assert_eq!(out.math, 7, "math expressions");
    assert_eq!(out.diagrams, 3, "mermaid fences that merman claimed");
    assert_eq!(out.rich_failures, 2, "one bad expression, one bad diagram");
    // The `rust` fence, and the `mermaid` fence holding prose.
    assert_eq!(out.code_blocks, 2, "highlighted code blocks");
}

#[test]
fn math_renders_inline_and_display() {
    let html = html();
    assert_eq!(
        html.matches("<math display=\"inline\"").count(),
        4,
        "{html}"
    );
    assert_eq!(html.matches("<math display=\"block\"").count(), 2, "{html}");
}

#[test]
fn math_inside_a_task_label_renders_and_the_checkbox_still_works() {
    let source = fixture();
    let doc = Document::parse(&source);
    let out = render(&doc, &RenderOptions::default());

    // The item is `- [x] a task whose label carries $a^2 + b^2 = c^2$`.
    let block = out
        .html
        .split("<div class=\"mk-blk")
        .find(|block| block.contains("a task whose label"))
        .expect("the task list block");
    assert!(block.contains("class=\"mk-task\""), "{block}");
    assert!(block.contains("<math display=\"inline\""), "{block}");

    // And the byte span on the marker still points at a real `[x]`.
    let tasks = mark_core::tasks::enumerate(&doc);
    let task = tasks
        .iter()
        .find(|task| task.text.contains("a task whose label"))
        .expect("the task is enumerated");
    assert_eq!(&source[task.start..task.end], "[x]");
    // The label keeps the math in its source spelling rather than losing it.
    assert!(task.text.contains("$a^2 + b^2 = c^2$"), "{}", task.text);
}

#[test]
fn a_newcommand_expression_becomes_a_badge_and_not_merror_markup() {
    // ADR-5's named trap. `push_mathml` returns `Ok` here, so a check on the
    // `Result` alone renders the parser's own diagnostics into the page and
    // reports success. Asserted at the document level as well as in the unit
    // test, because "the detection exists" and "the detection is on the path
    // the renderer takes" are different claims.
    let html = html();
    assert!(
        html.contains("class=\"mk-rich-error mk-math-error\""),
        "{html}"
    );
    assert!(!html.contains("<merror"), "pulldown-latex markup leaked");
    assert!(!html.contains('╭'), "the context diagram leaked");
    assert!(html.contains("expected an argument"), "{html}");
    // The LaTeX is still there to select and copy.
    assert!(html.contains("\\newcommand{\\R}{\\mathbb{R}}"), "{html}");
}

#[test]
fn a_malformed_diagram_becomes_a_badge_carrying_merman_s_message() {
    let html = html();
    assert!(
        html.contains("class=\"mk-rich-error mk-diagram-error\""),
        "{html}"
    );
    assert!(html.contains("Diagram parse error"), "{html}");
    assert!(html.contains("A[[[Start"), "the source is not selectable");
}

#[test]
fn a_rust_fence_is_highlighted_and_a_prose_mermaid_fence_is_a_code_block() {
    let html = html();
    assert!(html.contains("data-lang=\"rust\""), "{html}");
    // `NoDiagram` means "not a diagram", which is a code block and not a badge.
    assert!(html.contains("data-lang=\"mermaid\""), "{html}");
    assert!(
        html.contains("this is just some prose that happens to sit in a mermaid fence"),
        "{html}"
    );
    // Two diagrams became SVG; the prose fence did not. Each diagram is
    // emitted once per appearance (M7), so there are four SVGs in two
    // wrappers.
    assert_eq!(html.matches("<div class=\"mk-diagram\">").count(), 2);
    assert_eq!(html.matches("<svg id=").count(), 4);
}

#[test]
fn every_diagram_has_a_distinct_id_derived_from_its_block() {
    let source = fixture();
    let doc = Document::parse(&source);
    let html = render(&doc, &RenderOptions::default()).html;

    let ids: Vec<String> = html
        .match_indices("<svg id=\"")
        .map(|(at, marker)| {
            let rest = &html[at + marker.len()..];
            rest[..rest.find('"').expect("a closed attribute")].to_owned()
        })
        .collect();
    // Two diagrams, each rendered for both appearances (M7). ADR-5's
    // constraint is unchanged: every id is distinct and derived from the
    // block's `data-blk`, with the dark copy taking a `-d` suffix.
    assert_eq!(ids.len(), 4, "{ids:?}");
    let unique: std::collections::HashSet<&String> = ids.iter().collect();
    assert_eq!(unique.len(), 4, "{ids:?}");

    for id in &ids {
        let block_id = id
            .strip_prefix("mk-")
            .expect("the mk- prefix")
            .trim_end_matches("-d");
        assert!(
            doc.blocks().iter().any(|b| b.id.as_str() == block_id),
            "{id} does not name a block"
        );
    }
}

#[test]
fn the_rendered_document_ships_no_javascript_and_fetches_nothing() {
    // ADR-5's headline constraint, checked on the whole rendered page rather
    // than on one renderer's output.
    let source = fixture();
    let out = render(
        &Document::parse(&source),
        &RenderOptions {
            standalone: true,
            ..RenderOptions::default()
        },
    );
    let html = out.html;

    for forbidden in [
        "<script",
        "<link",
        "<iframe",
        "<image",
        "@import",
        "src=",
        "url(http",
        "xlink:href",
        ".js",
    ] {
        assert!(!html.contains(forbidden), "{forbidden} in rendered HTML");
    }
    // Worth knowing rather than asserting away: merman's scoped `<style>`
    // carries Mermaid's own `.node .katex path { … }` selector, because
    // upstream Mermaid renders labels with KaTeX. It is a selector that
    // matches nothing here — no KaTeX is loaded, and the checks above are what
    // establish that.
    assert!(html.contains(".katex path"), "merman's stylesheet changed");
    for reference in html.split("http").skip(1) {
        assert!(
            reference.starts_with("://www.w3.org/"),
            "an external reference survived: http{}",
            &reference[..reference.len().min(60)]
        );
    }
}

#[test]
fn rendering_the_fixture_twice_is_byte_identical() {
    // ADR-5's memoization precondition, and ADR-2's re-render path: the
    // file-watcher re-render must produce the same bytes as the cold one, or
    // the block diff reports changes that did not happen.
    let source = fixture();
    let doc = Document::parse(&source);
    let cold = render(&doc, &RenderOptions::default());
    let warm = render(&doc, &RenderOptions::default());

    assert_eq!(cold.html, warm.html);
    assert!(
        warm.rich_time <= cold.rich_time,
        "cached re-render was slower: {:?} vs {:?}",
        warm.rich_time,
        cold.rich_time
    );
}

#[test]
fn a_prefix_render_and_its_tail_reassemble_the_document() {
    // ADR-2's prefix-then-fill must still hold with rich constructs in play:
    // a diagram's id comes from its block, so rendering block 12 first cannot
    // change what it is.
    let source = fixture();
    let doc = Document::parse(&source);
    let whole = render(&doc, &RenderOptions::default()).html;

    for split in [0, 1, 5, 12, doc.blocks().len()] {
        let head = mark_core::render::render_range(&doc, 0..split).html;
        let tail = mark_core::render::render_range(&doc, split..doc.blocks().len()).html;
        assert_eq!(whole, format!("{head}{tail}"), "split at {split}");
    }
}

#[test]
fn a_diagrams_id_survives_an_edit_above_it() {
    // ADR-5: ids derive from `data-blk`, which ADR-2 makes content-derived —
    // so a paragraph inserted above a diagram must not renumber its SVG, or
    // an incremental patch would replace a node it should have kept.
    let source = fixture();
    let before = render(&Document::parse(&source), &RenderOptions::default()).html;
    let edited = format!("A new opening paragraph.\n\n{source}");
    let after = render(&Document::parse(&edited), &RenderOptions::default()).html;

    let ids = |html: &str| -> Vec<String> {
        html.match_indices("<svg id=\"")
            .map(|(at, marker)| {
                let rest = &html[at + marker.len()..];
                rest[..rest.find('"').expect("a closed attribute")].to_owned()
            })
            .collect()
    };
    assert_eq!(ids(&before), ids(&after));
}
