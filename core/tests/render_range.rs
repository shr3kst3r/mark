//! `render_range` over a partition equals a whole-document render.
//!
//! ADR-2's background fill needs an arbitrary block range, not just a prefix.
//! Until now the C ABI exposed only `mark_render_html(source, prefix_blocks)`,
//! so the Swift shell derived the tail by *subtraction* — rendering the whole
//! document and stripping the prefix off the front (see
//! `ProgressiveRenderer.tail(full:prefix:)`). That is only sound because block
//! renders concatenate, and it costs a whole-document render to obtain a tail.
//!
//! This file asserts the concatenation property directly, for arbitrary
//! partitions rather than the single split the Swift test covers, and pins the
//! out-of-range behaviour that a pump walking off the end depends on.

use mark_core::parse::Document;
use mark_core::render::{self, RenderOptions};
use proptest::prelude::*;

fn whole(source: &str) -> String {
    render::render(&Document::parse(source), &RenderOptions::default()).html
}

const MIXED: &str = "\
# Title

An opening paragraph with *emphasis* and a [link](https://example.com).

- [ ] an open task
- [x] a done task

```rust
fn main() { println!(\"hi\"); }
```

> a block quote

| a | b |
|---|---|
| 1 | 2 |

---

## Second heading

Closing paragraph.
";

#[test]
fn a_range_renders_exactly_its_own_blocks() {
    let doc = Document::parse(MIXED);
    let total = doc.blocks().len();
    assert!(total > 4, "the fixture needs several blocks, got {total}");

    for start in 0..total {
        for end in start..=total {
            let rendered = render::render_range(&doc, start..end);
            assert_eq!(rendered.blocks_emitted, end - start, "{start}..{end}");
            assert_eq!(rendered.blocks_total, total, "{start}..{end}");
            assert_eq!(
                rendered.html.matches("class=\"mk-blk").count(),
                end - start,
                "{start}..{end}"
            );
            for block in &doc.blocks()[start..end] {
                assert!(
                    rendered
                        .html
                        .contains(&format!("data-blk=\"{}\"", block.id)),
                    "{start}..{end} is missing {}",
                    block.id
                );
            }
        }
    }
}

#[test]
fn out_of_range_and_empty_ranges_render_nothing() {
    let doc = Document::parse(MIXED);
    let total = doc.blocks().len();
    for (start, end) in [
        (0usize, 0usize),
        (3, 3),
        (total, total),
        (total, total + 10),
        (total + 5, total + 9),
        (usize::MAX - 1, usize::MAX),
    ] {
        let rendered = render::render_range(&doc, start..end);
        assert_eq!(rendered.html, "", "{start}..{end}");
        assert_eq!(rendered.blocks_emitted, 0, "{start}..{end}");
    }
}

#[test]
fn a_reversed_range_is_clamped_to_empty_rather_than_panicking() {
    // The Rust API clamps — it is reachable from the C ABI, where a panic is
    // undefined behaviour (ADR-1). `mark_render_range` is stricter and reports
    // a reversed range as an error; see the ABI tests in `lib.rs`.
    let doc = Document::parse(MIXED);
    for (start, end) in [(4usize, 1usize), (usize::MAX, 0usize), (2, 0)] {
        let rendered = render::render_range(&doc, start..end);
        assert_eq!(rendered.html, "", "{start}..{end}");
        assert_eq!(rendered.blocks_emitted, 0, "{start}..{end}");
    }
}

#[test]
fn an_empty_document_has_no_ranges_to_render() {
    let doc = Document::parse("");
    assert_eq!(doc.blocks().len(), 0);
    assert_eq!(render::render_range(&doc, 0..0).html, "");
    assert_eq!(render::render_range(&doc, 0..usize::MAX).html, "");
    assert_eq!(render::render_range(&doc, 7..9).html, "");
}

#[test]
fn a_single_block_document_is_one_range() {
    let doc = Document::parse("only one paragraph\n");
    assert_eq!(doc.blocks().len(), 1);
    assert_eq!(
        render::render_range(&doc, 0..1).html,
        whole("only one paragraph\n")
    );
    assert_eq!(render::render_range(&doc, 1..2).html, "");
}

#[test]
fn render_ranges_agrees_with_render_range_one_at_a_time() {
    // The batched form exists only to build the per-document lookups once. If
    // it ever produced something different, the edit script's HTML would be
    // subtly wrong in exactly the way ADR-2 warns about.
    let doc = Document::parse(MIXED);
    let ranges: Vec<_> = vec![0..2, 2..2, 1..5, 3..doc.blocks().len(), 99..104];
    let batched = render::render_ranges(&doc, &ranges, &mark_core::theme::default_pair());
    for (range, rendered) in ranges.iter().zip(batched) {
        assert_eq!(
            rendered.html,
            render::render_range(&doc, range.clone()).html,
            "{range:?}"
        );
    }
}

/// Turn arbitrary numbers into sorted cut points covering `0..total` exactly
/// once, so the caller gets a genuine partition whatever the generator said.
fn cut_points(raw: &[usize], total: usize) -> Vec<usize> {
    let mut cuts: Vec<usize> = raw.iter().map(|value| value % (total + 1)).collect();
    cuts.push(0);
    cuts.push(total);
    cuts.sort_unstable();
    cuts.dedup();
    cuts
}

fn document() -> impl Strategy<Value = String> {
    let fragment = prop_oneof![
        Just("paragraph text\n\n".to_owned()),
        Just("# A heading\n\n".to_owned()),
        Just("- [ ] a task\n\n".to_owned()),
        Just("```rust\nfn f() {}\n```\n\n".to_owned()),
        Just("> quoted\n\n".to_owned()),
        Just("| a | b |\n|---|---|\n| 1 | 2 |\n\n".to_owned()),
        Just("naïve — ünicode ✅\n\n".to_owned()),
        Just("***\n\n".to_owned()),
    ];
    prop::collection::vec(fragment, 0..16).prop_map(|mut parts| {
        parts.insert(0, "# Document\n\n".to_owned());
        parts.concat()
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Concatenating any partition of the block list reproduces the whole
    /// document, byte for byte. This is the property the shell's
    /// prefix-then-fill depends on, and the one that makes `mark_render_range`
    /// a safe replacement for render-everything-and-slice.
    #[test]
    fn a_partition_concatenates_to_the_whole_document(
        source in document(),
        raw_cuts in prop::collection::vec(0usize..64, 0..8),
    ) {
        let doc = Document::parse(&source);
        let total = doc.blocks().len();
        let cuts = cut_points(&raw_cuts, total);

        let mut assembled = String::new();
        let mut emitted = 0usize;
        for pair in cuts.windows(2) {
            let rendered = render::render_range(&doc, pair[0]..pair[1]);
            emitted += rendered.blocks_emitted;
            assembled.push_str(&rendered.html);
        }
        prop_assert_eq!(emitted, total);
        prop_assert_eq!(assembled, whole(&source));
    }

    /// A prefix range and `prefix_blocks` are the same thing, so switching the
    /// shell from one to the other cannot change a byte.
    #[test]
    fn a_prefix_range_equals_the_prefix_blocks_tunable(
        source in document(),
        prefix in 1usize..24,
    ) {
        let doc = Document::parse(&source);
        let by_option = render::render(&doc, &RenderOptions {
            prefix_blocks: Some(prefix),
            ..RenderOptions::default()
        });
        let by_range = render::render_range(&doc, 0..prefix);
        prop_assert_eq!(by_option.html, by_range.html);
        prop_assert_eq!(by_option.blocks_emitted, by_range.blocks_emitted);
    }

    /// Prefix plus tail is the whole document — the exact identity
    /// `ProgressiveRenderer.tail(full:prefix:)` relies on today.
    #[test]
    fn a_prefix_and_its_tail_are_the_whole_document(
        source in document(),
        split in 0usize..24,
    ) {
        let doc = Document::parse(&source);
        let head = render::render_range(&doc, 0..split);
        let tail = render::render_range(&doc, split..usize::MAX);
        prop_assert_eq!(head.blocks_emitted + tail.blocks_emitted, doc.blocks().len());
        prop_assert_eq!(format!("{}{}", head.html, tail.html), whole(&source));
    }
}
