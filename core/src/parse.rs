//! `pulldown-cmark` → a list of top-level [`Block`]s carrying byte ranges.
//!
//! Two properties matter downstream and are worth stating here:
//!
//! * Every event is kept with its byte range (`into_offset_iter`). ADR-1 rests
//!   on this: mapping a rendered element back to an exact byte span is what
//!   makes the checkbox contract cheap, and it is why `pulldown-cmark` was
//!   chosen over `swift-markdown` and `comrak`.
//! * Blocks are segmented at nesting depth 0 only. A `Block` therefore owns a
//!   contiguous slice of the event stream, which lets [`crate::render`] emit
//!   one block at a time without re-parsing (ADR-2's prefix-then-fill).

use std::cell::OnceCell;
use std::ops::Range;

use pulldown_cmark::{
    CodeBlockKind, CowStr, Event, MetadataBlockKind, Options, Parser, Tag, TagEnd,
};
use serde::Serialize;

use crate::block::{Block, BlockId, BlockKind, OrdinalCounter, block_hash};

/// The extension set for the whole product.
///
/// `ENABLE_MATH` yields `Event::InlineMath` / `Event::DisplayMath` carrying raw
/// TeX with a byte range, which is what [`crate::rich`] feeds to
/// `pulldown-latex` (ADR-5). It is **not** narrow enough on its own: a space
/// before the second `$` saves `$5 and $10`, but `~$7`, `$5-$10` and
/// `US$5 … US$10` all parse as mathematics and typeset the prose between the
/// two amounts as italic identifiers. [`demote_currency`] is what actually
/// keeps currency out of the math path; see
/// `docs/adrs/2026-09-10-currency-is-not-math.md`.
///
/// The two metadata options are not optional in practice. Without them a
/// document's closing `---` parses as a setext H2 underline, so YAML
/// frontmatter renders as a heading whose text is the first metadata line —
/// which corrupts the body, the table of contents, and `mark ls` titles alike.
/// Every ADR in this repository, and effectively every Obsidian, Jekyll, or
/// Hugo file, starts with frontmatter. Pluses-delimited blocks are enabled for
/// Hugo's TOML frontmatter at the same time, since the failure mode is
/// identical.
#[must_use]
pub fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_GFM
        | Options::ENABLE_MATH
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
        | Options::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS
}

/// A parsed document. Borrows its source, so events can borrow too and nothing
/// is copied out of the file.
pub struct Document<'a> {
    source: &'a str,
    events: Vec<(Event<'a>, Range<usize>)>,
    blocks: Vec<Block>,
    /// Built on first use. Counting newlines from the start of the file per
    /// lookup is O(n) each time, which on a 1 MB document with ~1,800 tasks
    /// measured as ~200 ms of the render — the single largest cost in the
    /// pipeline before this existed.
    lines: OnceCell<LineIndex>,
    metadata: Option<Metadata>,
}

impl<'a> Document<'a> {
    #[must_use]
    pub fn parse(source: &'a str) -> Document<'a> {
        let mut events: Vec<(Event<'a>, Range<usize>)> = Vec::new();
        let mut blocks: Vec<Block> = Vec::new();
        let mut ordinals = OrdinalCounter::default();
        let mut depth: usize = 0;
        let mut open: Option<(BlockKind, Range<usize>, usize)> = None;
        // Frontmatter is captured, not blocked: it is metadata *about* the
        // document rather than content in it, so it must reach neither the
        // rendered body nor the table of contents.
        let mut metadata: Option<Metadata> = None;
        let mut meta_open: Option<(MetadataKind, Range<usize>, usize)> = None;

        for (event, range) in Parser::new_ext(source, options()).into_offset_iter() {
            // Before segmentation, so every consumer downstream — both
            // renderers, `plain_text`, headings and their anchors, task
            // labels, the word count — sees one `Text` event and none of them
            // has to know this rule exists.
            let event = demote_currency(source, event, &range);
            let index = events.len();
            match &event {
                Event::Start(Tag::MetadataBlock(kind)) if depth == 0 => {
                    meta_open = Some((MetadataKind::from(*kind), range.clone(), index));
                    depth += 1;
                }
                Event::Start(tag) => {
                    if depth == 0 {
                        open = Some((kind_of(tag), range.clone(), index));
                    }
                    depth += 1;
                }
                Event::End(_) => {
                    // A `TagEnd` without a matching `Start` cannot happen: the
                    // parser is balanced. Saturating rather than panicking
                    // keeps the C ABI's promise of never unwinding even if
                    // that ever stops being true.
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        if let Some((kind, span, first)) = meta_open.take() {
                            metadata = Some(Metadata {
                                kind,
                                raw: raw_text(&events[first + 1..]),
                                start: span.start,
                                end: span.end,
                            });
                        } else if let Some((kind, span, first)) = open.take() {
                            blocks.push(build(source, kind, span, first..index + 1, &mut ordinals));
                        }
                    }
                }
                _ => {
                    if depth == 0 {
                        let kind = leaf_kind(&event);
                        blocks.push(build(
                            source,
                            kind,
                            range.clone(),
                            index..index + 1,
                            &mut ordinals,
                        ));
                    }
                }
            }
            events.push((event, range));
        }

        Document {
            source,
            events,
            blocks,
            lines: OnceCell::new(),
            metadata,
        }
    }

    /// The document's frontmatter, if it has any. Never part of [`blocks`],
    /// [`headings`], or the rendered HTML.
    ///
    /// [`blocks`]: Document::blocks
    /// [`headings`]: Document::headings
    #[must_use]
    pub fn metadata(&self) -> Option<&Metadata> {
        self.metadata.as_ref()
    }

    #[must_use]
    pub fn source(&self) -> &'a str {
        self.source
    }

    /// Line index over this document's source, built on first use.
    pub fn lines(&self) -> &LineIndex {
        self.lines.get_or_init(|| LineIndex::new(self.source))
    }

    /// 1-based line number of a byte offset.
    #[must_use]
    pub fn line_of(&self, offset: usize) -> usize {
        self.lines().line_of(offset)
    }

    #[must_use]
    pub fn blocks(&self) -> &[Block] {
        &self.blocks
    }

    #[must_use]
    pub fn events(&self) -> &[(Event<'a>, Range<usize>)] {
        &self.events
    }

    /// The events belonging to one block, in document order.
    #[must_use]
    pub fn block_events(&self, block: &Block) -> &[(Event<'a>, Range<usize>)] {
        &self.events[block.event_range.clone()]
    }

    /// The raw source of one block.
    #[must_use]
    pub fn block_source(&self, block: &Block) -> &'a str {
        &self.source[block.start..block.end]
    }

    /// The document's title: a `title` key in the frontmatter, else its first
    /// `#` heading, else its first heading of any level. `mark ls` shows this
    /// next to each file.
    ///
    /// Frontmatter wins because it is the one place an author states the title
    /// outright; Obsidian and Hugo users routinely have a `title:` that differs
    /// from the first heading, and guessing from the body would override them.
    #[must_use]
    pub fn title(&self) -> Option<String> {
        if let Some(title) = self.metadata.as_ref().and_then(Metadata::title) {
            return Some(title);
        }
        let mut first: Option<String> = None;
        for block in &self.blocks {
            let BlockKind::Heading { level } = block.kind else {
                continue;
            };
            let text = plain_text(self.block_events(block));
            if text.is_empty() {
                continue;
            }
            if level == 1 {
                return Some(text);
            }
            first.get_or_insert(text);
        }
        first
    }

    /// Headings in document order, with anchors deduplicated the way GitHub
    /// does it (`title`, `title-1`, `title-2`).
    #[must_use]
    pub fn headings(&self) -> Vec<Heading> {
        let mut out: Vec<Heading> = Vec::new();
        let mut seen: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

        for block in &self.blocks {
            let BlockKind::Heading { level } = block.kind else {
                continue;
            };
            let text = plain_text(self.block_events(block));
            let base = slugify(&text);
            let anchor = match seen.entry(base.clone()) {
                std::collections::hash_map::Entry::Occupied(mut e) => {
                    let n = e.get_mut();
                    *n += 1;
                    format!("{base}-{n}")
                }
                std::collections::hash_map::Entry::Vacant(e) => {
                    e.insert(0);
                    base
                }
            };
            out.push(Heading {
                level,
                text,
                anchor,
                start: block.start,
                end: block.end,
                line: self.line_of(block.start),
                block: block.id.clone(),
            });
        }
        out
    }
}

/// Which delimiter opened a frontmatter block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MetadataKind {
    /// `---` fenced. YAML, as Obsidian and Jekyll write it.
    Yaml,
    /// `+++` fenced. TOML, as Hugo writes it.
    Toml,
}

impl From<MetadataBlockKind> for MetadataKind {
    fn from(kind: MetadataBlockKind) -> Self {
        match kind {
            MetadataBlockKind::YamlStyle => MetadataKind::Yaml,
            MetadataBlockKind::PlusesStyle => MetadataKind::Toml,
        }
    }
}

/// A document's frontmatter, kept out of the body and the TOC.
///
/// The raw text is preserved rather than parsed into a map. A real YAML parser
/// is a dependency this milestone does not need, and the one key anything
/// currently asks for is `title`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Metadata {
    pub kind: MetadataKind,
    /// The block's contents, without the delimiter lines.
    pub raw: String,
    /// Byte range of the whole block, delimiters included.
    pub start: usize,
    pub end: usize,
}

impl Metadata {
    /// The `title` key, if there is a top-level one.
    ///
    /// Deliberately a scan rather than a YAML parse: a nested `title:` under
    /// some other key is not the document's title, so only unindented keys
    /// count, and anything more elaborate than a scalar is ignored.
    #[must_use]
    pub fn title(&self) -> Option<String> {
        let separator = match self.kind {
            MetadataKind::Yaml => ':',
            MetadataKind::Toml => '=',
        };
        for line in self.raw.lines() {
            if line.starts_with([' ', '\t', '-', '#']) {
                continue;
            }
            let Some((key, value)) = line.split_once(separator) else {
                continue;
            };
            if key.trim() != "title" {
                continue;
            }
            let value = value.trim().trim_matches(['"', '\'']).trim();
            if !value.is_empty() {
                return Some(value.to_owned());
            }
        }
        None
    }
}

/// One entry of the table of contents.
#[derive(Debug, Clone, Serialize)]
pub struct Heading {
    pub level: u8,
    pub text: String,
    pub anchor: String,
    pub start: usize,
    pub end: usize,
    /// 1-based line number of the heading's first byte.
    pub line: usize,
    pub block: BlockId,
}

/// Two prices in one sentence, not one expression: `$4.50 vs ~$7`.
///
/// `pulldown-cmark` opens inline math at a `$` followed by a non-space and
/// closes it at the next `$` preceded by a non-space, so whether a sentence
/// about money survives depends entirely on the character sitting in front of
/// its second dollar sign. A space saves `$5 or $10`. An approximation sign, a
/// range hyphen, or a currency prefix does not, and `Coffee is $4.50 vs a
/// fancy latte at ~$7` becomes one `<math>` element whose prose is typeset as
/// italic identifiers.
///
/// The rule, per `docs/adrs/2026-09-10-currency-is-not-math.md`: when the
/// opening `$` **and** the closing `$` are both followed immediately by an
/// ASCII digit, the span is two currency amounts, and it becomes a single
/// `Event::Text` carrying its own source slice with the delimiters still in
/// it. That pair of conditions is not the signature of one expression — a real
/// expression's closing delimiter is followed by prose, punctuation, or the end
/// of the line, never by a digit belonging to a second number. `$2x$` stays
/// math; `$5-$10` does not.
///
/// `Event::DisplayMath` is deliberately not considered: `$$…$$` is
/// unambiguous, and nobody writes a price with two dollar signs.
///
/// The range is passed through untouched. Rewriting the event is allowed;
/// rewriting the offsets is not, because ADR-1's one-byte checkbox writes and
/// ADR-2's incremental patching both index the file through them.
fn demote_currency<'a>(source: &'a str, event: Event<'a>, range: &Range<usize>) -> Event<'a> {
    if matches!(event, Event::InlineMath(_)) && is_currency_pair(source, range) {
        return Event::Text(CowStr::Borrowed(&source[range.clone()]));
    }
    event
}

/// Whether both `$` delimiters of the span at `range` are followed by a digit.
///
/// `range` is an `Event::InlineMath` range, so it includes both delimiters and
/// starts with a single `$`.
fn is_currency_pair(source: &str, range: &Range<usize>) -> bool {
    let opens_on_digit = source[range.clone()]
        .strip_prefix('$')
        .and_then(|after| after.bytes().next())
        .is_some_and(|byte| byte.is_ascii_digit());
    // A span that ends the file has nothing after its closing `$`, so it is
    // not a price.
    let closes_on_digit = source[range.end..]
        .bytes()
        .next()
        .is_some_and(|byte| byte.is_ascii_digit());

    opens_on_digit && closes_on_digit
}

fn build(
    source: &str,
    kind: BlockKind,
    span: Range<usize>,
    event_range: Range<usize>,
    ordinals: &mut OrdinalCounter,
) -> Block {
    // Hash the trimmed slice: trailing blank lines belong to the document's
    // layout, not the block's content, and letting them into the hash would
    // make an id change when a *neighbour* is edited.
    let hash = block_hash(&kind, source[span.clone()].trim());
    let ordinal = ordinals.next(hash);
    Block {
        id: BlockId::new(hash, ordinal),
        kind,
        start: span.start,
        end: span.end,
        hash,
        ordinal,
        event_range,
    }
}

fn kind_of(tag: &Tag<'_>) -> BlockKind {
    match tag {
        Tag::Heading { level, .. } => BlockKind::Heading {
            level: *level as u8,
        },
        Tag::Paragraph => BlockKind::Paragraph,
        Tag::CodeBlock(kind) => BlockKind::CodeBlock {
            language: code_language(kind).map(str::to_owned),
        },
        Tag::List(start) => BlockKind::List {
            ordered: start.is_some(),
        },
        Tag::BlockQuote(_) => BlockKind::BlockQuote,
        Tag::Table(_) => BlockKind::Table,
        Tag::FootnoteDefinition(_) => BlockKind::FootnoteDefinition,
        Tag::HtmlBlock => BlockKind::Html,
        Tag::DefinitionList => BlockKind::DefinitionList,
        _ => BlockKind::Other,
    }
}

fn leaf_kind(event: &Event<'_>) -> BlockKind {
    match event {
        Event::Rule => BlockKind::ThematicBreak,
        Event::Html(_) => BlockKind::Html,
        _ => BlockKind::Other,
    }
}

/// The info string's first word, lowercased — `rust,ignore` and `Rust` both
/// resolve to `rust`. Returns `None` for an indented or bare fence.
#[must_use]
pub fn code_language<'a>(kind: &'a CodeBlockKind<'a>) -> Option<&'a str> {
    match kind {
        CodeBlockKind::Fenced(info) => {
            let token = info.split([' ', ',', '\t', '{']).next().unwrap_or("");
            if token.is_empty() { None } else { Some(token) }
        }
        CodeBlockKind::Indented => None,
    }
}

/// Verbatim text of a run of events. Unlike [`plain_text`] this preserves line
/// structure, because frontmatter is line-oriented.
fn raw_text(events: &[(Event<'_>, Range<usize>)]) -> String {
    let mut out = String::new();
    for (event, _) in events {
        if let Event::Text(text) = event {
            out.push_str(text);
        }
    }
    out
}

/// Concatenated text of a run of events, with markup dropped. Used for heading
/// titles, task labels, and document titles.
#[must_use]
pub fn plain_text(events: &[(Event<'_>, Range<usize>)]) -> String {
    let mut out = String::new();
    for (event, _) in events {
        match event {
            Event::Text(text) | Event::Code(text) => out.push_str(text),
            // Math is flattened back to the source spelling rather than
            // dropped. A heading reading `Area of $x^2$` must keep its `x^2`,
            // or its anchor silently changes the day math is switched on and
            // every link to it breaks.
            Event::InlineMath(tex) => out.push_str(&format!("${tex}$")),
            Event::DisplayMath(tex) => out.push_str(&format!("$${tex}$$")),
            Event::SoftBreak | Event::HardBreak => out.push(' '),
            Event::End(TagEnd::Paragraph) => out.push(' '),
            _ => {}
        }
    }
    out.trim().to_owned()
}

/// GitHub-flavoured anchor slug.
#[must_use]
pub fn slugify(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if ch.is_alphanumeric() {
            out.extend(ch.to_lowercase());
        } else if ch == ' ' || ch == '-' || ch == '_' {
            out.push('-');
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

/// Byte offsets of every line start, for O(log n) offset → line lookups.
///
/// Anything reporting line numbers for more than a handful of offsets in one
/// document should build one of these rather than counting newlines per
/// lookup: the naive version is quadratic in the document, and on a 1 MB file
/// with ~1,800 task markers that was ~200 ms.
pub struct LineIndex {
    starts: Vec<usize>,
}

impl LineIndex {
    #[must_use]
    pub fn new(source: &str) -> LineIndex {
        let mut starts = Vec::with_capacity(source.len() / 32 + 1);
        starts.push(0);
        starts.extend(
            source
                .bytes()
                .enumerate()
                .filter(|(_, byte)| *byte == b'\n')
                .map(|(index, _)| index + 1),
        );
        LineIndex { starts }
    }

    /// 1-based line number containing `offset`.
    #[must_use]
    pub fn line_of(&self, offset: usize) -> usize {
        match self.starts.binary_search(&offset) {
            Ok(index) => index + 1,
            Err(index) => index,
        }
    }

    /// Number of lines, counting a trailing newline as ending the last line.
    #[must_use]
    pub fn len(&self) -> usize {
        self.starts.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.starts.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_are_top_level_only() {
        let src = "# Title\n\npara\n\n- a\n- b\n";
        let doc = Document::parse(src);
        let kinds: Vec<_> = doc.blocks().iter().map(|b| b.kind.slug()).collect();
        assert_eq!(kinds, ["heading", "paragraph", "list"]);
    }

    #[test]
    fn block_spans_round_trip_to_source() {
        let src = "# Title\n\npara\n";
        let doc = Document::parse(src);
        assert_eq!(doc.block_source(&doc.blocks()[0]).trim(), "# Title");
        assert_eq!(doc.block_source(&doc.blocks()[1]).trim(), "para");
    }

    #[test]
    fn thematic_break_is_a_block() {
        let doc = Document::parse("a\n\n---\n\nb\n");
        let kinds: Vec<_> = doc.blocks().iter().map(|b| b.kind.slug()).collect();
        assert_eq!(kinds, ["paragraph", "rule", "paragraph"]);
    }

    #[test]
    fn code_language_takes_the_first_token() {
        let doc = Document::parse("```rust,ignore\nfn main() {}\n```\n");
        assert_eq!(
            doc.blocks()[0].kind,
            BlockKind::CodeBlock {
                language: Some("rust".into())
            }
        );
    }

    #[test]
    fn mermaid_is_a_code_block_whose_language_says_mermaid() {
        // The block list stays uniform; it is `render` that turns this one
        // into an `<svg>` (ADR-5), so the diff, the TOC, and the byte ranges
        // do not have to know diagrams exist.
        let doc = Document::parse("```mermaid\ngraph TD;\n```\n");
        assert_eq!(
            doc.blocks()[0].kind,
            BlockKind::CodeBlock {
                language: Some("mermaid".into())
            }
        );
    }

    #[test]
    fn math_is_its_own_event_carrying_raw_tex_and_a_byte_range() {
        let src = "Inline $x^2$ and $$\\int f$$.\n";
        let doc = Document::parse(src);
        let math: Vec<_> = doc
            .events()
            .iter()
            .filter_map(|(event, range)| match event {
                Event::InlineMath(tex) => Some(("inline", tex.to_string(), range.clone())),
                Event::DisplayMath(tex) => Some(("display", tex.to_string(), range.clone())),
                _ => None,
            })
            .collect();

        assert_eq!(math.len(), 2, "{math:?}");
        assert_eq!(math[0].0, "inline");
        assert_eq!(math[0].1, "x^2");
        assert_eq!(&src[math[0].2.clone()], "$x^2$");
        assert_eq!(math[1].0, "display");
        assert_eq!(math[1].1, "\\int f");
        assert_eq!(&src[math[1].2.clone()], "$$\\int f$$");
    }

    #[test]
    fn a_dollar_sign_in_prose_is_still_a_dollar_sign() {
        // The regression enabling ENABLE_MATH could plausibly introduce: a
        // price list turning into mathematics. Both shapes here are saved by
        // the space in front of the second `$`, and for a long time this test
        // and its neighbour in `render` were the whole guard — which is why
        // they only ever asserted on shapes that were never at risk. The
        // shapes that are at risk are in the next test; do not add another
        // passing one here and call currency covered.
        for source in ["That costs $5 and $10 total.\n", "a $ b $ c\n"] {
            let doc = Document::parse(source);
            assert!(
                doc.events()
                    .iter()
                    .all(|(e, _)| !matches!(e, Event::InlineMath(_) | Event::DisplayMath(_))),
                "{source:?} parsed as math"
            );
        }
    }

    #[test]
    fn currency_pairs_that_hug_their_delimiters_are_not_math() {
        // Every shape here parsed as one inline math span before
        // `demote_currency`, with the prose between the two amounts typeset as
        // italic identifiers. The first is the sentence that was reported.
        let sources = [
            "Coffee is $4.50 vs\na fancy latte at ~$7).\n",
            "coffee $4.50 vs latte ~$7.\n",
            "costs $5 or ~$10.\n",
            "a range of $5-$10 today.\n",
            "US$5 and US$10.\n",
            "fees are $2/share vs $3/share.\n",
        ];

        for source in sources {
            let doc = Document::parse(source);
            assert!(
                doc.events()
                    .iter()
                    .all(|(e, _)| !matches!(e, Event::InlineMath(_) | Event::DisplayMath(_))),
                "{source:?} parsed as math"
            );
            // Not merely "not math": every character of the source, both
            // dollar signs included, has to survive into the text.
            let text = plain_text(doc.events());
            for amount in source.split('$').skip(1) {
                let amount = amount.split_whitespace().next().unwrap_or_default();
                assert!(
                    text.contains(&format!("${amount}")),
                    "{source:?} lost ${amount}: {text:?}"
                );
            }
        }
    }

    #[test]
    fn the_currency_rule_leaves_real_inline_math_alone() {
        // A closing `$` followed by a digit is what the rule keys on, and none
        // of these has one: an expression's closing delimiter is followed by
        // prose, punctuation, or the end of the line.
        for source in [
            "Area is $x^2$ exactly.\n",
            "Twice is $2x$ exactly.\n",
            "$2$ then $3$ then $4$.\n",
            "Ends the line with $2n$\n",
            "$$2x$$ is display.\n",
        ] {
            let doc = Document::parse(source);
            assert!(
                doc.events()
                    .iter()
                    .any(|(e, _)| matches!(e, Event::InlineMath(_) | Event::DisplayMath(_))),
                "{source:?} lost its math"
            );
        }
    }

    #[test]
    fn a_demoted_currency_span_keeps_the_range_it_was_given() {
        // ADR-1's checkbox writes and ADR-2's patching both index the file
        // through these offsets, so the rewritten event must still describe
        // exactly the bytes it replaced.
        let src = "coffee $4.50 vs ~$7.\n";
        let doc = Document::parse(src);
        let demoted = doc
            .events()
            .iter()
            .find_map(|(event, range)| match event {
                Event::Text(text) if text.starts_with('$') => Some((text.clone(), range.clone())),
                _ => None,
            })
            .expect("the demoted span");

        assert_eq!(demoted.0.as_ref(), "$4.50 vs ~$");
        assert_eq!(&src[demoted.1], "$4.50 vs ~$");
    }

    #[test]
    fn plain_text_keeps_math_in_its_source_spelling() {
        // Headings, task labels, and `mark ls` titles all come through here.
        // Dropping the math would silently change a heading's anchor.
        let doc = Document::parse("## Area of $x^2$\n");
        assert_eq!(plain_text(doc.events()), "Area of $x^2$");
        assert_eq!(doc.headings()[0].anchor, "area-of-x2");

        let doc = Document::parse("$$a+b$$\n");
        assert_eq!(plain_text(doc.events()), "$$a+b$$");
    }

    #[test]
    fn headings_get_deduplicated_anchors() {
        let doc = Document::parse("# One\n\n## One\n\n## one\n");
        let anchors: Vec<_> = doc.headings().into_iter().map(|h| h.anchor).collect();
        assert_eq!(anchors, ["one", "one-1", "one-2"]);
    }

    #[test]
    fn heading_levels_and_lines() {
        let doc = Document::parse("# A\n\n### B\n");
        let headings = doc.headings();
        assert_eq!((headings[0].level, headings[0].line), (1, 1));
        assert_eq!((headings[1].level, headings[1].line), (3, 3));
    }

    #[test]
    fn tables_footnotes_and_strikethrough_are_enabled() {
        let doc = Document::parse("| a | b |\n|---|---|\n| 1 | 2 |\n");
        assert_eq!(doc.blocks()[0].kind.slug(), "table");
        let doc = Document::parse("text[^1]\n\n[^1]: note\n");
        assert!(doc.blocks().iter().any(|b| b.kind.slug() == "footnote"));
        let doc = Document::parse("~~gone~~\n");
        assert!(
            doc.events()
                .iter()
                .any(|(e, _)| matches!(e, Event::Start(Tag::Strikethrough)))
        );
    }

    #[test]
    fn line_index_maps_offsets_to_one_based_lines() {
        let source = "alpha\nbeta\n\ngamma";
        let index = LineIndex::new(source);
        assert_eq!(index.line_of(0), 1);
        assert_eq!(index.line_of(4), 1);
        assert_eq!(index.line_of(5), 1); // the newline itself ends line 1
        assert_eq!(index.line_of(6), 2);
        assert_eq!(index.line_of(11), 3); // the blank line
        assert_eq!(index.line_of(12), 4);
        assert_eq!(index.line_of(source.len()), 4);
        assert_eq!(index.len(), 4);
    }

    #[test]
    fn line_index_agrees_with_a_naive_count() {
        // The naive version is what this replaced; keeping it here as an
        // oracle is cheaper than trusting the binary search.
        let source = "a\n\nbb\nccc\n\n\nd";
        let index = LineIndex::new(source);
        for offset in 0..=source.len() {
            let naive = source[..offset].bytes().filter(|b| *b == b'\n').count() + 1;
            assert_eq!(index.line_of(offset), naive, "offset {offset}");
        }
    }

    #[test]
    fn slugify_drops_punctuation() {
        assert_eq!(slugify("Hello, World! (v2)"), "hello-world-v2");
    }
}
