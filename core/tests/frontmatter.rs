//! Frontmatter must be parsed as metadata, never rendered as content.
//!
//! The regression this guards is subtle and was found by rendering an actual
//! ADR from this repository. Without
//! `ENABLE_YAML_STYLE_METADATA_BLOCKS`, `pulldown-cmark` reads the closing
//! `---` of a YAML block as a **setext H2 underline**, so the frontmatter
//! becomes a heading whose text is the first metadata line:
//!
//! ```text
//! ## title: Test
//! tags: [a, b]
//! ```
//!
//! That corrupts the rendered body, puts a bogus entry in `mark toc`, and
//! makes it the document's title in `mark ls --json` — and it fires on every
//! ADR in `docs/adrs/` and effectively every Obsidian, Jekyll, or Hugo file.

use std::fs;
use std::path::{Path, PathBuf};

use mark_core::parse::{Document, MetadataKind};
use mark_core::render::{RenderOptions, render};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn frontmatter_md() -> String {
    fs::read_to_string(fixture("frontmatter.md")).expect("fixture is committed")
}

#[test]
fn frontmatter_is_not_a_block() {
    let source = frontmatter_md();
    let doc = Document::parse(&source);

    let kinds: Vec<&str> = doc.blocks().iter().map(|b| b.kind.slug()).collect();
    assert_eq!(kinds, ["heading", "paragraph", "list"]);

    // The first block starts after the closing delimiter, not at byte 0.
    assert!(doc.blocks()[0].start > 0);
    assert_eq!(doc.block_source(&doc.blocks()[0]).trim(), "# Body Heading");
}

#[test]
fn frontmatter_is_not_in_the_rendered_body() {
    let source = frontmatter_md();
    let doc = Document::parse(&source);
    let html = render(&doc, &RenderOptions::default()).html;

    for leaked in ["status:", "tags:", "2026-08-24-a-fixture", "Accepted"] {
        assert!(!html.contains(leaked), "{leaked:?} leaked into:\n{html}");
    }
    // ...and no phantom heading was invented from the closing delimiter.
    assert_eq!(html.matches("<h2").count(), 0);
    assert!(html.contains("<h1 id=\"body-heading\""), "{html}");
}

#[test]
fn frontmatter_is_not_in_the_table_of_contents() {
    let source = frontmatter_md();
    let headings = Document::parse(&source).headings();

    assert_eq!(headings.len(), 1);
    assert_eq!(headings[0].text, "Body Heading");
    assert_eq!(headings[0].level, 1);
}

#[test]
fn the_title_key_wins_over_the_first_heading() {
    let source = frontmatter_md();
    let doc = Document::parse(&source);
    assert_eq!(doc.title().as_deref(), Some("Frontmatter Title"));
}

#[test]
fn an_indented_title_key_is_not_the_document_title() {
    // The fixture has `nested:\n  title: Not The Document Title`. A scan that
    // ignored indentation would pick the wrong one.
    let source = frontmatter_md();
    let metadata = Document::parse(&source)
        .metadata()
        .expect("fixture has frontmatter")
        .clone();
    assert_eq!(metadata.title().as_deref(), Some("Frontmatter Title"));
    assert!(metadata.raw.contains("Not The Document Title"));
}

#[test]
fn metadata_records_its_kind_and_byte_span() {
    let source = frontmatter_md();
    let doc = Document::parse(&source);
    let metadata = doc.metadata().expect("fixture has frontmatter");

    assert_eq!(metadata.kind, MetadataKind::Yaml);
    assert_eq!(metadata.start, 0);
    assert!(source[metadata.start..metadata.end].starts_with("---\n"));
    assert!(
        source[metadata.start..metadata.end]
            .trim_end()
            .ends_with("---")
    );
}

#[test]
fn toml_frontmatter_is_handled_too() {
    // Hugo's `+++` blocks fail in exactly the same way when unhandled.
    let source = "+++\ntitle = \"Hugo Doc\"\ndraft = false\n+++\n\n# Body\n";
    let doc = Document::parse(source);

    let metadata = doc.metadata().expect("TOML frontmatter");
    assert_eq!(metadata.kind, MetadataKind::Toml);
    assert_eq!(doc.title().as_deref(), Some("Hugo Doc"));
    assert_eq!(doc.headings().len(), 1);
    assert_eq!(doc.blocks().len(), 1);
}

#[test]
fn a_document_without_frontmatter_has_no_metadata() {
    let doc = Document::parse("# Just a heading\n\nAnd a paragraph.\n");
    assert!(doc.metadata().is_none());
    assert_eq!(doc.title().as_deref(), Some("Just a heading"));
}

#[test]
fn frontmatter_without_a_title_key_falls_back_to_the_heading() {
    let doc = Document::parse("---\ntags: [a]\n---\n\n# Heading Wins\n");
    assert!(doc.metadata().is_some());
    assert_eq!(doc.title().as_deref(), Some("Heading Wins"));
}

#[test]
fn a_thematic_break_further_down_is_still_a_thematic_break() {
    // Frontmatter only opens at byte 0. This is the case that would break if
    // the fix were "swallow any `---`".
    let doc = Document::parse("intro\n\n---\n\nafter\n");
    assert!(doc.metadata().is_none());
    let kinds: Vec<&str> = doc.blocks().iter().map(|b| b.kind.slug()).collect();
    assert_eq!(kinds, ["paragraph", "rule", "paragraph"]);
}

#[test]
fn a_setext_heading_is_still_a_setext_heading() {
    let doc = Document::parse("Setext Title\n---\n\nbody\n");
    assert!(doc.metadata().is_none());
    assert_eq!(doc.headings().len(), 1);
    assert_eq!(doc.headings()[0].level, 2);
}

/// Every ADR in this repository begins with frontmatter, which is how the bug
/// was found. Rendering one must not produce a heading from it.
#[test]
fn the_repositorys_own_adrs_render_without_a_phantom_heading() {
    let corpus = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace root")
        .join("docs/adrs");

    let mut checked = 0;
    for entry in fs::read_dir(&corpus).expect("the ADR corpus exists") {
        let path = entry.expect("readable entry").path();
        if path.extension().is_none_or(|e| e != "md") {
            continue;
        }
        let source = fs::read_to_string(&path).expect("readable ADR");
        if !source.starts_with("---") {
            continue;
        }

        let doc = Document::parse(&source);
        assert!(
            doc.metadata().is_some(),
            "{} has frontmatter that was not recognised",
            path.display()
        );
        for heading in doc.headings() {
            assert!(
                !heading.text.contains("status:") && !heading.text.contains("supersedes:"),
                "{} produced a heading from its frontmatter: {:?}",
                path.display(),
                heading.text
            );
        }
        assert_eq!(
            doc.headings()[0].level,
            1,
            "{} should start with an H1",
            path.display()
        );
        checked += 1;
    }
    assert!(checked >= 5, "expected the five ADRs, checked {checked}");
}
