//! The memo cache must be sound, per ADR-2:
//!
//! > Highlighted output is cached by content hash, so highlighting must stay a
//! > pure function of `(language, code, theme)`. No ambient state.
//!
//! The test that matters is not "the cache is fast" — it is "the cache cannot
//! serve bytes the uncached path would not have produced". A memoization bug
//! here shows up as one code block wearing another's colours, which is the sort
//! of thing a human notices weeks later and cannot reproduce.

use std::fs;
use std::path::Path;

use mark_core::highlight::{Format, Highlighter, shared};
use mark_core::theme;

const RUST: &str = "fn main() {\n    let x: u32 = 1;\n    println!(\"{x}\");\n}\n";
const PYTHON: &str = "def main():\n    x = 1\n    print(x)\n";

#[test]
fn the_same_language_and_code_yield_byte_identical_output() {
    // Code unique to this test, so a concurrently running test cannot have
    // warmed the process-wide cache first.
    const CODE: &str = "fn unique_to_this_test() -> i32 { 7 }\n";
    let highlighter = shared();
    let first = highlighter.highlight(Some("rust"), CODE, &theme::default_pair());
    let second = highlighter.highlight(Some("rust"), CODE, &theme::default_pair());

    assert!(!first.cached, "first call should be a miss");
    assert!(second.cached, "second call should be a hit");
    assert_eq!(first.html, second.html);
    assert_eq!(first.syntax, second.syntax);
}

#[test]
fn a_cache_hit_equals_the_uncached_computation() {
    // The load-bearing assertion: memoized output is indistinguishable from
    // recomputing. Comparing two cached calls would pass even if the cache
    // were serving the wrong entry.
    let highlighter = Highlighter::new();
    for (language, code) in [
        (Some("rust"), RUST),
        (Some("python"), PYTHON),
        (Some("json"), "{\"a\": [1, 2]}\n"),
        (Some("nosuchlanguage"), "plain <text> & more\n"),
        (None, "no language at all\n"),
        (Some("rust"), ""),
    ] {
        let uncached =
            highlighter.highlight_uncached(Format::Html, language, code, &theme::default_pair());
        let first = highlighter.highlight(language, code, &theme::default_pair());
        let second = highlighter.highlight(language, code, &theme::default_pair());

        assert_eq!(uncached.html, first.html, "miss differs for {language:?}");
        assert_eq!(uncached.html, second.html, "hit differs for {language:?}");
        assert_eq!(uncached.syntax, second.syntax);
    }
}

#[test]
fn different_code_in_the_same_language_does_not_collide() {
    let highlighter = Highlighter::new();
    let one = highlighter
        .highlight(Some("rust"), RUST, &theme::default_pair())
        .html;
    let two = highlighter
        .highlight(
            Some("rust"),
            "fn other() -> bool { false }\n",
            &theme::default_pair(),
        )
        .html;
    assert_ne!(one, two);
}

#[test]
fn the_same_code_in_different_languages_does_not_collide() {
    let highlighter = Highlighter::new();
    let code = "x = 1\n";
    let python = highlighter
        .highlight(Some("python"), code, &theme::default_pair())
        .html;
    let ruby = highlighter
        .highlight(Some("ruby"), code, &theme::default_pair())
        .html;
    let plain = highlighter
        .highlight(None, code, &theme::default_pair())
        .html;

    assert_ne!(python, plain);
    assert_ne!(ruby, plain);
}

#[test]
fn html_and_ansi_never_serve_each_others_bytes() {
    let highlighter = Highlighter::new();
    let html = highlighter.highlight(Some("rust"), RUST, &theme::default_pair());
    let ansi = highlighter.highlight_ansi(Some("rust"), RUST, &theme::default_pair());

    assert!(html.html.contains("<span"), "html output lost its spans");
    assert!(!html.html.contains('\x1b'), "html output leaked escapes");
    assert!(ansi.html.contains('\x1b'), "ansi output lost its escapes");
    assert!(!ansi.html.contains("<span"), "ansi output leaked html");

    // ...and each is still stable across calls.
    assert_eq!(
        highlighter
            .highlight(Some("rust"), RUST, &theme::default_pair())
            .html,
        html.html
    );
    assert_eq!(
        highlighter
            .highlight_ansi(Some("rust"), RUST, &theme::default_pair())
            .html,
        ansi.html
    );
}

#[test]
fn counters_track_hits_and_misses() {
    let highlighter = Highlighter::new();
    assert_eq!(highlighter.stats().hits, 0);

    highlighter.highlight(Some("rust"), RUST, &theme::default_pair());
    highlighter.highlight(Some("rust"), RUST, &theme::default_pair());
    highlighter.highlight(Some("rust"), RUST, &theme::default_pair());

    let stats = highlighter.stats();
    assert_eq!((stats.misses, stats.hits, stats.entries), (1, 2, 1));
}

#[test]
fn clearing_the_cache_changes_nothing_but_timing() {
    let highlighter = Highlighter::new();
    let before = highlighter
        .highlight(Some("rust"), RUST, &theme::default_pair())
        .html;
    highlighter.clear_cache();
    let after = highlighter.highlight(Some("rust"), RUST, &theme::default_pair());

    assert!(!after.cached, "cache was not actually cleared");
    assert_eq!(before, after.html);
}

#[test]
fn rendering_a_document_twice_is_byte_identical() {
    // The re-render path ADR-2 is about: a file-watcher re-render must produce
    // the same HTML, from cache, that the cold render produced.
    use mark_core::parse::Document;
    use mark_core::render::{RenderOptions, render};

    let source =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mixed.md"))
            .expect("fixture is committed");

    let doc = Document::parse(&source);
    let cold = render(&doc, &RenderOptions::default());
    let warm = render(&doc, &RenderOptions::default());

    assert_eq!(cold.html, warm.html);
    assert!(cold.code_blocks >= 3, "fixture should exercise the cache");
    assert!(
        warm.highlight_time <= cold.highlight_time,
        "cached re-render was slower: {:?} vs {:?}",
        warm.highlight_time,
        cold.highlight_time
    );
}
