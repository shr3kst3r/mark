//! How long a document is, in the units a writer cares about.
//!
//! `mark stats` has always reported bytes, blocks, and per-stage timings —
//! facts about the *renderer*. A writer wants a different set: how many words,
//! how long it takes to read, and how much of that is prose rather than code.
//!
//! **Counted from the event stream, not from the bytes.** That is the whole
//! reason this is in the core rather than being a `split(separator: " ")` in
//! Swift. A word count that includes a document's frontmatter, its mermaid
//! diagram, and 200 lines of embedded Rust is not a word count of the writing —
//! and neither the CLI nor the window could produce the right one without the
//! parser. `mark stats` and the editor's status line therefore get the same
//! answer, which is the rule ADR-1 exists to keep.
//!
//! What counts as prose, precisely:
//!
//! * **Frontmatter does not count.** `Document::parse` captures it as metadata
//!   rather than content, so it reaches neither the rendered body nor the table
//!   of contents — but its events *are* still in the stream, so it is skipped
//!   here explicitly.
//! * **Code does not count** — neither fenced blocks nor inline spans. Code is
//!   measured separately, in bytes, because "words" is not a useful unit for it.
//! * **Link text counts; the URL does not.** `[the runbook](https://…)` is two
//!   words. The destination is machinery.
//! * **A task's marker does not count**, but its text does.
//! * **Math and diagrams do not count.** Both are figures.

use serde::Serialize;

use pulldown_cmark::{Event, Tag, TagEnd};

use crate::parse::Document;

/// The reading speed [`Counts::reading_minutes`] is derived from.
///
/// 238 words per minute is the mean for silent reading of English prose
/// (Brysbaert 2019, a meta-analysis of 190 studies). A round 200 or 250 is the
/// usual choice and is nobody's measurement; this one at least has a source,
/// and it is stated here so a reader who disagrees knows what to change.
pub const WORDS_PER_MINUTE: f64 = 238.0;

/// What a writer wants to know about a document's length.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
pub struct Counts {
    /// Words of prose. Code, math, diagrams, frontmatter and URLs are not
    /// prose; see the module docs for exactly what that means.
    pub words: usize,
    /// Characters of that same prose, whitespace included.
    pub characters: usize,
    /// The same, with whitespace dropped — the count a word limit is usually
    /// really about.
    pub characters_no_spaces: usize,
    /// Lines in the file, counted the way an editor counts them: a trailing
    /// newline makes a final empty line, because that is a line a caret can sit
    /// on.
    pub lines: usize,
    /// Top-level blocks, which is the unit ADR-2 renders in.
    pub blocks: usize,
    pub headings: usize,
    /// Bytes inside fenced and indented code blocks. Bytes rather than words,
    /// because "words" is not a useful unit for code.
    pub code_bytes: usize,
}

impl Counts {
    /// Minutes to read the prose, rounded up, and never zero for a document
    /// that has any words in it — "0 min" reads as a failure rather than as
    /// "quick".
    #[must_use]
    pub fn reading_minutes(&self) -> usize {
        if self.words == 0 {
            return 0;
        }
        ((self.words as f64) / WORDS_PER_MINUTE).ceil() as usize
    }
}

/// Count a parsed document.
#[must_use]
pub fn count(doc: &Document<'_>) -> Counts {
    let source = doc.source();
    let mut counts = Counts {
        lines: line_count(source),
        blocks: doc.blocks().len(),
        headings: doc.headings().len(),
        ..Counts::default()
    };

    // Depth of the constructs whose text is not prose. A counter rather than a
    // flag, because they nest: an image's alt text inside a link inside a
    // heading is three `Start`s deep and the code has to come back out of all
    // of them.
    let mut skipping = 0usize;

    for (event, span) in doc.events() {
        match event {
            Event::Start(Tag::CodeBlock(_)) => {
                skipping += 1;
            }
            Event::End(TagEnd::CodeBlock) => {
                skipping = skipping.saturating_sub(1);
            }
            // Frontmatter. `Document::parse` captures it as *metadata* and
            // keeps it out of the rendered body and out of the table of
            // contents — but the events are still in the stream, so it has to
            // be skipped here too. Counting `title: A document about many
            // things` as eleven words of prose is the bug this arm exists for.
            Event::Start(Tag::MetadataBlock(_)) => {
                skipping += 1;
            }
            Event::End(TagEnd::MetadataBlock(_)) => {
                skipping = skipping.saturating_sub(1);
            }
            // An image's alt text is a caption for a figure, not prose the
            // reader reads. A *link's* text is prose and is deliberately not
            // skipped — only its destination is, and the destination never
            // arrives as a `Text` event.
            Event::Start(Tag::Image { .. }) => {
                skipping += 1;
            }
            Event::End(TagEnd::Image) => {
                skipping = skipping.saturating_sub(1);
            }
            Event::Code(code) => {
                // An inline span. Counted as code, not as words.
                counts.code_bytes += code.len();
            }
            Event::InlineMath(text) | Event::DisplayMath(text) => {
                let _ = text;
            }
            Event::Text(text) if skipping == 0 => {
                counts.words += words_in(text);
                counts.characters += text.chars().count();
                counts.characters_no_spaces += text.chars().filter(|c| !c.is_whitespace()).count();
            }
            Event::Text(_) => {
                // Inside a code block: the bytes are the measure.
                counts.code_bytes += span.len();
            }
            _ => {}
        }
    }
    counts
}

/// Count a document from its source, for a caller that has not parsed one.
#[must_use]
pub fn count_source(source: &str) -> Counts {
    count(&Document::parse(source))
}

/// Words in a run of text.
///
/// Split on whitespace, then require that a token hold at least one
/// alphanumeric character. That second rule is what stops a bullet's `-`, a
/// lone `—`, and the `|` and `---` of a table border being counted as words —
/// all of which arrive as ordinary text events.
fn words_in(text: &str) -> usize {
    text.split_whitespace()
        .filter(|token| token.chars().any(char::is_alphanumeric))
        .count()
}

/// Lines, as an editor counts them.
fn line_count(source: &str) -> usize {
    if source.is_empty() {
        return 1;
    }
    source.bytes().filter(|b| *b == b'\n').count() + 1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counts(source: &str) -> Counts {
        count_source(source)
    }

    #[test]
    fn prose_is_counted() {
        let c = counts("one two three\n");
        assert_eq!(c.words, 3);
        assert_eq!(c.lines, 2, "a trailing newline makes a final empty line");
    }

    #[test]
    fn a_fenced_code_block_is_not_prose() {
        let c = counts("some words here\n\n```rust\nfn main() { println!(\"hello\"); }\n```\n");
        assert_eq!(c.words, 3, "the code was counted as words");
        assert!(c.code_bytes > 0, "the code was not counted at all");
    }

    #[test]
    fn an_inline_code_span_is_not_prose() {
        let c = counts("run `cargo build --release` now\n");
        // `run` and `now`.
        assert_eq!(c.words, 2);
        assert!(c.code_bytes > 0);
    }

    #[test]
    fn frontmatter_is_not_prose() {
        // The events *are* in the stream even though the body and the table of
        // contents never see them, so this needed its own arm rather than
        // coming free.
        let with = counts("---\ntitle: A document about many things\ntags: a b c\n---\n\nword\n");
        let without = counts("word\n");
        assert_eq!(with.words, without.words);
    }

    #[test]
    fn link_text_counts_and_the_url_does_not() {
        let c = counts("see [the runbook](https://example.com/very/long/path)\n");
        // `see`, `the`, `runbook`.
        assert_eq!(c.words, 3);
    }

    #[test]
    fn an_images_alt_text_is_a_caption_not_prose() {
        let c = counts("before ![a picture of a hill](x.png) after\n");
        assert_eq!(c.words, 2);
    }

    #[test]
    fn a_tasks_text_counts_but_its_marker_does_not() {
        let c = counts("- [ ] write the runbook\n");
        assert_eq!(c.words, 3);
    }

    #[test]
    fn list_bullets_and_table_borders_are_not_words() {
        // All of these arrive as ordinary text events, and a naive
        // whitespace split counts every one of them.
        assert_eq!(counts("- one\n- two\n").words, 2);
        assert_eq!(counts("| a | b |\n|---|---|\n| 1 | 2 |\n").words, 4);
        assert_eq!(counts("a — b\n").words, 2);
    }

    #[test]
    fn math_and_diagrams_are_figures() {
        let c = counts("text $x^2 + y^2$ more\n");
        assert_eq!(c.words, 2, "the expression was counted as words");
    }

    #[test]
    fn characters_are_counted_with_and_without_spaces() {
        let c = counts("ab cd\n");
        assert_eq!(c.characters, 5);
        assert_eq!(c.characters_no_spaces, 4);
    }

    #[test]
    fn reading_time_rounds_up_and_is_never_zero_for_real_prose() {
        assert_eq!(Counts::default().reading_minutes(), 0);
        let short = Counts {
            words: 5,
            ..Counts::default()
        };
        assert_eq!(short.reading_minutes(), 1, "\"0 min\" reads as a failure");
        let long = Counts {
            words: 238 * 3,
            ..Counts::default()
        };
        assert_eq!(long.reading_minutes(), 3);
    }

    #[test]
    fn an_empty_document_is_one_line_and_no_words() {
        let c = counts("");
        assert_eq!(c.words, 0);
        assert_eq!(c.lines, 1);
        assert_eq!(c.reading_minutes(), 0);
    }
}
