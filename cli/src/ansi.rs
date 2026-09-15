//! Terminal rendering for `mark render --ansi` and `--plain`.
//!
//! This lives in the CLI rather than the core because it is a presentation
//! choice for one consumer; the core stays free of anything the app cannot use
//! (ADR-1). It walks the same event stream the HTML renderer does, so the two
//! cannot disagree about what the document says — only about how it looks.
//!
//! `--plain` is the same walk with every escape sequence suppressed, which is
//! what makes it usable as a diffable, pipe-safe representation.
//!
//! Prose is not hard-wrapped: the terminal soft-wraps it, and rewrapping a
//! piped stdout produces ragged output in the common `mark render | less` case.
//! **Tables are**, because a table cannot soft-wrap — a row wider than the
//! terminal wraps mid-cell and destroys the alignment of everything after it.
//!
//! Everything laid out against the terminal is measured in **display width**,
//! not characters. `文` and `🙂` are one `char` each and two cells each, so
//! `chars().count()` under-measures them and a table containing either loses
//! its alignment and overruns `COLUMNS`. See [`display_width`].

use std::fmt::Write as _;

use mark_core::highlight;
use mark_core::parse::{Document, code_language};
use mark_core::tasks;
use mark_core::theme;
use pulldown_cmark::{Alignment, Event, HeadingLevel, Tag, TagEnd};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Assumed terminal width when stdout is not a terminal.
pub const DEFAULT_WIDTH: usize = 80;

/// Narrowest a table column is allowed to get before we stop shrinking and
/// accept a hard truncation. Below this, wrapping produces one letter per line
/// and reads worse than a cut-off cell.
///
/// The consequence, stated so it is not mistaken for a bug: a table with more
/// than `(width + COLUMN_GAP) / (MIN_COLUMN_WIDTH + COLUMN_GAP)` columns cannot
/// fit — 13 columns at 80 — and overflows rather than degrading further.
const MIN_COLUMN_WIDTH: usize = 3;

/// Widest a `---` rule is drawn, when the terminal has room for it.
const MAX_RULE_WIDTH: usize = 60;

/// `" │ "` between columns.
const COLUMN_GAP: usize = 3;

/// Terminal cells `text` occupies.
///
/// The one measurement every layout decision in this file goes through. East
/// Asian wide and fullwidth characters and emoji are two cells; combining
/// marks and control characters are zero.
///
/// It is an approximation for the same reason every terminal's is: a
/// grapheme cluster joined with ZWJ (`👨‍👩‍👧`) is drawn as one glyph by some
/// terminals and as its parts by others, and no width table can be right for
/// both. Where it is wrong it over-estimates, which pads a column rather than
/// overflowing it.
#[must_use]
fn display_width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

/// Terminal cells one character occupies. `None` — a control character — is
/// counted as zero rather than one.
fn char_width(ch: char) -> usize {
    UnicodeWidthChar::width(ch).unwrap_or(0)
}

/// SGR sequences, or empty strings in `--plain` mode.
struct Sgr {
    color: bool,
}

impl Sgr {
    fn on(&self, code: &str) -> String {
        if self.color {
            format!("\x1b[{code}m")
        } else {
            String::new()
        }
    }

    fn reset(&self) -> String {
        self.on("0")
    }
}

/// Render a parsed document for a terminal `width` columns wide.
///
/// `color` false yields plain text with no escape sequences at all.
///
/// `prefix_blocks` is ADR-2's first-paint tunable, applied here for the same
/// reason `--html` honours it: `mark render --prefix N` must mean the same
/// thing in every format, and the terminal formats are the ones an agent reads.
///
/// `theme` supplies the code colours. A terminal has no CSS to defer them to,
/// so unlike the HTML path these are real 24-bit colours from the theme's
/// palette — which is why `--ansi` output changes when the theme does and the
/// HTML output does not.
#[must_use]
pub fn render(
    doc: &Document<'_>,
    color: bool,
    width: usize,
    prefix_blocks: Option<usize>,
    theme: &std::sync::Arc<theme::ThemePair>,
) -> String {
    let mut writer = Writer::new(color, width, theme);
    writer.run(doc, prefix_blocks);
    writer.finish()
}

#[derive(Default)]
struct Table {
    rows: Vec<Vec<String>>,
    alignments: Vec<Alignment>,
    cell: String,
    in_cell: bool,
    header_rows: usize,
}

struct Writer {
    out: String,
    sgr: Sgr,
    /// Prefix written at the start of each line: list indents, quote bars.
    prefix: String,
    /// True when the next character must be preceded by the prefix.
    fresh_line: bool,
    /// Ordered-list counters, innermost last. `None` for bullet lists.
    lists: Vec<Option<u64>>,
    /// Prefix width each open item added, so it can be removed exactly.
    item_indents: Vec<usize>,
    table: Option<Table>,
    link: Option<String>,
    /// Code fence being collected: the language, then its text.
    code: Option<(Option<String>, String)>,
    /// Terminal width in columns. Only tables are laid out against it.
    width: usize,
    /// The palette code blocks are coloured from.
    theme: std::sync::Arc<theme::ThemePair>,
}

impl Writer {
    fn new(color: bool, width: usize, theme: &std::sync::Arc<theme::ThemePair>) -> Writer {
        Writer {
            out: String::new(),
            sgr: Sgr { color },
            prefix: String::new(),
            fresh_line: true,
            lists: Vec::new(),
            item_indents: Vec::new(),
            table: None,
            link: None,
            code: None,
            width: width.max(MIN_COLUMN_WIDTH),
            theme: std::sync::Arc::clone(theme),
        }
    }

    fn finish(mut self) -> String {
        while self.out.ends_with('\n') {
            self.out.pop();
        }
        if !self.out.is_empty() {
            self.out.push('\n');
        }
        self.out
    }

    /// Walk the document one block at a time rather than over the raw event
    /// stream.
    ///
    /// This is what keeps the terminal and HTML renderers honest with each
    /// other: anything the core excludes from the block list — frontmatter, for
    /// one — is excluded from both, instead of each renderer having to remember
    /// to skip it. Blocks being independently renderable is also what lets
    /// `prefix_blocks` stop after N of them without re-parsing.
    fn run(&mut self, doc: &Document<'_>, prefix_blocks: Option<usize>) {
        let end = prefix_blocks.unwrap_or(usize::MAX).min(doc.blocks().len());
        for block in &doc.blocks()[..end] {
            let events = doc.block_events(block);
            let mut index = 0;
            while index < events.len() {
                // `[/]`, `[-]` and `[?]` are three `Text` events the parser has
                // no opinion about, so they are recognised with the core's own
                // structural rule and drawn as one marker — otherwise they
                // would print as prose and the terminal formats would be the
                // only ones that disagreed about what a task is.
                if let Some((state, _)) = tasks::extended_marker(events, index, doc.source()) {
                    self.task_marker(state, false);
                    index += 3;
                    continue;
                }
                self.event(&events[index].0);
                index += 1;
            }
        }
    }

    /// One task marker, in the same five spellings the document uses.
    ///
    /// `--plain` emits the marker bytes and no styling at all, which is what
    /// makes it a byte-for-byte round trip of the source.
    ///
    /// `spaced` distinguishes the two shapes the parser hands us: a GFM marker
    /// arrives with the following space consumed, an extended one does not, and
    /// re-emitting the wrong one would move a byte.
    fn task_marker(&mut self, state: tasks::State, spaced: bool) {
        self.style(match state {
            tasks::State::Open => "33",
            tasks::State::InProgress => "36",
            tasks::State::Done => "32",
            // Dim and struck: the terminal's version of what the HTML does to a
            // cancelled item.
            tasks::State::Cancelled => "2;9",
            tasks::State::Blocked => "35",
        });
        let marker = format!("[{}]", char::from(state.byte()));
        self.text(&marker);
        self.reset();
        if spaced {
            self.text(" ");
        }
    }

    /// Write text, honouring the current line prefix and any active capture
    /// (table cell or code fence).
    fn text(&mut self, text: &str) {
        if let Some((_, code)) = &mut self.code {
            code.push_str(text);
            return;
        }
        if let Some(table) = &mut self.table
            && table.in_cell
        {
            table.cell.push_str(text);
            return;
        }
        for ch in text.chars() {
            if ch == '\n' {
                self.out.push('\n');
                self.fresh_line = true;
                continue;
            }
            if self.fresh_line {
                let prefix = self.prefix.clone();
                self.out.push_str(&prefix);
                self.fresh_line = false;
            }
            self.out.push(ch);
        }
    }

    /// Escape sequences bypass the prefix logic: they occupy no columns.
    fn style(&mut self, code: &str) {
        if !self.sgr.color {
            return;
        }
        if self.table.as_ref().is_some_and(|t| t.in_cell) || self.code.is_some() {
            return;
        }
        let sequence = self.sgr.on(code);
        self.out.push_str(&sequence);
    }

    fn reset(&mut self) {
        self.style("0");
    }

    fn newline(&mut self) {
        if !self.fresh_line {
            self.out.push('\n');
            self.fresh_line = true;
        }
    }

    /// Blank line between top-level blocks, but never at the very top and never
    /// two in a row.
    fn blank_line(&mut self) {
        self.newline();
        if !self.out.is_empty() && !self.out.ends_with("\n\n") {
            self.out.push('\n');
        }
    }

    /// One event.
    ///
    /// There is no catch-all arm: with math handled, every `Event` variant is
    /// covered, and the compiler rejects an unreachable one. A future
    /// `pulldown-cmark` that adds a variant therefore fails the build here
    /// rather than silently dropping it from `--plain` — which is exactly the
    /// failure mode math itself had until this milestone.
    fn event(&mut self, event: &Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(*tag),
            Event::Text(text) => self.text(text),
            Event::Code(text) => {
                self.style("7");
                self.text(text);
                self.reset();
            }
            // A terminal has no MathML, so math goes back to the spelling the
            // author wrote. Dropping it — which is what an unhandled event
            // does — would silently delete content from `--plain`, the format
            // an agent reads.
            Event::InlineMath(tex) => {
                self.style("3");
                self.text(&format!("${tex}$"));
                self.reset();
            }
            Event::DisplayMath(tex) => {
                self.style("3");
                self.text(&format!("$${tex}$$"));
                self.reset();
            }
            Event::SoftBreak | Event::HardBreak => self.newline(),
            Event::Rule => {
                self.blank_line();
                self.style("2");
                // A rule is layout, not prose: it cannot soft-wrap gracefully,
                // so it is drawn to fit what is left of the terminal rather
                // than at a fixed 60 that spills over a narrow one.
                let room = self
                    .width
                    .saturating_sub(display_width(&self.prefix))
                    .clamp(1, MAX_RULE_WIDTH);
                self.text(&"─".repeat(room));
                self.reset();
                self.newline();
            }
            Event::TaskListMarker(checked) => self.task_marker(
                if *checked {
                    tasks::State::Done
                } else {
                    tasks::State::Open
                },
                true,
            ),
            Event::Html(html) | Event::InlineHtml(html) => {
                if html.as_ref() == "<mark>" {
                    self.style("7");
                } else if html.as_ref() == "</mark>" {
                    self.reset();
                } else {
                    self.style("2");
                    self.text(html.trim_end());
                    self.reset();
                }
            }
            Event::FootnoteReference(name) => {
                self.style("2");
                self.text(&format!("[^{name}]"));
                self.reset();
            }
        }
    }

    fn start(&mut self, tag: &Tag<'_>) {
        match tag {
            Tag::Paragraph => self.blank_line(),
            Tag::Heading { level, .. } => {
                self.blank_line();
                self.style("1;36");
                self.text(&format!("{} ", "#".repeat(heading_level(*level))));
            }
            Tag::BlockQuote(_) => {
                self.blank_line();
                self.prefix.push_str("│ ");
            }
            Tag::CodeBlock(kind) => {
                self.blank_line();
                self.code = Some((code_language(kind).map(str::to_owned), String::new()));
            }
            Tag::List(start) => {
                if self.lists.is_empty() {
                    self.blank_line();
                }
                self.lists.push(*start);
            }
            Tag::Item => {
                self.newline();
                let marker = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        let marker = format!("{n}. ");
                        *n += 1;
                        marker
                    }
                    _ => "- ".to_owned(),
                };
                // Nesting comes from the enclosing item's continuation prefix,
                // so the marker carries no indent of its own.
                self.text(&marker);
                self.item_indents.push(display_width(&marker));
                self.prefix.push_str(&" ".repeat(display_width(&marker)));
            }
            Tag::Emphasis => self.style("3"),
            Tag::Strong => self.style("1"),
            Tag::Strikethrough => self.style("9"),
            Tag::Link { dest_url, .. } => {
                self.link = Some(dest_url.to_string());
                self.style("4;34");
            }
            Tag::Image { dest_url, .. } => {
                self.link = Some(dest_url.to_string());
                self.style("2");
                self.text("image: ");
            }
            Tag::Table(alignments) => {
                self.blank_line();
                self.table = Some(Table {
                    alignments: alignments.clone(),
                    ..Table::default()
                });
            }
            Tag::TableHead | Tag::TableRow => {
                if let Some(table) = &mut self.table {
                    table.rows.push(Vec::new());
                }
            }
            Tag::TableCell => {
                if let Some(table) = &mut self.table {
                    table.cell.clear();
                    table.in_cell = true;
                }
            }
            Tag::FootnoteDefinition(name) => {
                self.blank_line();
                self.style("2");
                self.text(&format!("[^{name}]: "));
                self.reset();
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => self.newline(),
            TagEnd::Heading(_) => {
                self.reset();
                self.newline();
            }
            TagEnd::BlockQuote(_) => {
                self.trim_prefix(2);
                self.newline();
            }
            TagEnd::CodeBlock => self.flush_code(),
            TagEnd::List(_) => {
                self.lists.pop();
                self.newline();
            }
            TagEnd::Item => {
                let width = self.item_indents.pop().unwrap_or(2);
                self.trim_prefix(width);
                self.newline();
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => self.reset(),
            TagEnd::Link | TagEnd::Image => {
                self.reset();
                if let Some(url) = self.link.take() {
                    self.style("2");
                    self.text(&format!(" ({url})"));
                    self.reset();
                }
            }
            TagEnd::TableCell => {
                if let Some(table) = &mut self.table {
                    table.in_cell = false;
                    let cell = table.cell.trim().to_owned();
                    if let Some(row) = table.rows.last_mut() {
                        row.push(cell);
                    }
                }
            }
            TagEnd::TableHead => {
                if let Some(table) = &mut self.table {
                    table.header_rows = table.rows.len();
                }
            }
            TagEnd::Table => self.flush_table(),
            TagEnd::FootnoteDefinition => self.newline(),
            _ => {}
        }
    }

    /// Drop `count` characters from the end of the line prefix.
    fn trim_prefix(&mut self, count: usize) {
        let keep = self.prefix.chars().count().saturating_sub(count);
        self.prefix = self.prefix.chars().take(keep).collect();
    }

    fn flush_code(&mut self) {
        let Some((language, code)) = self.code.take() else {
            return;
        };
        let highlighted = if self.sgr.color {
            let text = highlight::shared()
                .highlight_ansi(language.as_deref(), &code, &self.theme)
                .html;
            // `highlight_ansi` appends a final reset *after* the code's trailing
            // newline, so splitting on lines would emit it as an extra line of
            // pure escape sequences — an indented blank line in `--ansi` that
            // `--plain` does not have. We add our own reset below anyway.
            text.strip_suffix("\x1b[0m")
                .map_or(text.clone(), str::to_owned)
        } else {
            code
        };

        // Indent by four so a fence is visibly a fence even without colour.
        self.prefix.push_str("    ");
        self.newline();
        for line in highlighted.lines() {
            self.text(line);
            self.newline();
        }
        self.trim_prefix(4);
        if self.sgr.color {
            self.out.push_str(&self.sgr.reset());
        }
    }

    fn flush_table(&mut self) {
        let Some(table) = self.table.take() else {
            return;
        };
        let columns = table.rows.iter().map(Vec::len).max().unwrap_or(0);
        if columns == 0 {
            return;
        }

        // The line prefix (list indent, quote bar) is already spent, so the
        // table gets what is left of the terminal, not the whole of it.
        let budget = self
            .width
            .saturating_sub(display_width(&self.prefix))
            .max(MIN_COLUMN_WIDTH);
        let widths = column_widths(&table.rows, columns, budget);

        for (index, row) in table.rows.iter().enumerate() {
            let header = index < table.header_rows;
            for line in wrap_row(row, &widths, &table.alignments) {
                if header {
                    self.style("1");
                }
                self.text(&line);
                if header {
                    self.reset();
                }
                self.newline();
            }

            if index + 1 == table.header_rows {
                self.style("2");
                self.text(&separator(&widths));
                self.reset();
                self.newline();
            }
        }
    }
}

/// Fit `columns` columns into `budget` characters.
///
/// Shrinking only the widest column would starve it while a neighbour keeps
/// slack it does not need, so this water-fills instead: find the largest cap
/// `c` such that `sum(min(natural, c))` fits, and clamp every column to it.
/// Columns naturally narrower than `c` keep their own width.
fn column_widths(rows: &[Vec<String>], columns: usize, budget: usize) -> Vec<usize> {
    let mut natural = vec![0usize; columns];
    for row in rows {
        for (index, cell) in row.iter().enumerate().take(columns) {
            natural[index] = natural[index].max(display_width(cell));
        }
    }

    let gaps = COLUMN_GAP * columns.saturating_sub(1);
    let available = budget.saturating_sub(gaps);
    let total: usize = natural.iter().sum();
    if total <= available && available > 0 {
        return natural;
    }

    // `cap` never needs to exceed the widest column, and never drops below the
    // floor at which wrapping stops being readable.
    let ceiling = natural.iter().copied().max().unwrap_or(0);
    let mut cap = MIN_COLUMN_WIDTH;
    for candidate in MIN_COLUMN_WIDTH..=ceiling {
        let fitted: usize = natural.iter().map(|w| (*w).min(candidate)).sum();
        if fitted > available {
            break;
        }
        cap = candidate;
    }
    natural.iter().map(|w| (*w).min(cap)).collect()
}

/// One logical row as one or more physical lines, wrapping each cell into its
/// column and padding shorter cells so the columns stay aligned.
fn wrap_row(row: &[String], widths: &[usize], alignments: &[Alignment]) -> Vec<String> {
    let wrapped: Vec<Vec<String>> = widths
        .iter()
        .enumerate()
        .map(|(column, width)| wrap(row.get(column).map_or("", String::as_str), *width))
        .collect();
    let height = wrapped.iter().map(Vec::len).max().unwrap_or(1).max(1);

    (0..height)
        .map(|line| {
            let mut out = String::new();
            for (column, width) in widths.iter().enumerate() {
                let cell = wrapped[column].get(line).map_or("", String::as_str);
                let alignment = alignments.get(column).copied().unwrap_or(Alignment::None);
                let _ = write!(out, "{} ", pad(cell, *width, alignment));
                if column + 1 < widths.len() {
                    out.push_str("│ ");
                }
            }
            out.trim_end().to_owned()
        })
        .collect()
}

/// The `───┼───` rule, built to exactly the width the rows above it occupy.
///
/// It used to be assembled independently of the row layout, which happened to
/// agree for two columns and diverged for every other count.
fn separator(widths: &[usize]) -> String {
    widths
        .iter()
        .map(|width| "─".repeat(*width))
        .collect::<Vec<_>>()
        // Exactly as wide as the `" │ "` it sits under, so a row and its rule
        // are the same length by construction rather than by coincidence.
        .join("─┼─")
}

/// Break `text` into lines of at most `width` characters, preferring
/// whitespace. A single word longer than the column is split rather than
/// allowed to overhang, since overhang is the bug being fixed.
fn wrap(text: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return vec![String::new()];
    }
    if display_width(text) <= width {
        return vec![text.to_owned()];
    }

    let mut lines: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut current_width = 0usize;

    for word in text.split_whitespace() {
        let word_width = display_width(word);

        if current_width > 0 && current_width + 1 + word_width > width {
            lines.push(std::mem::take(&mut current));
            current_width = 0;
        }
        if word_width > width {
            // Hard-split an over-long word across as many lines as it needs.
            // The flush above has already run: a word wider than the column
            // cannot fit after anything.
            //
            // The test is `>` rather than `==` because a two-cell character
            // can step over the boundary rather than landing on it, which is
            // how a CJK cell used to overhang its column by one.
            let mut chunk = String::new();
            let mut chunk_width = 0usize;
            for ch in word.chars() {
                let ch_width = char_width(ch);
                if chunk_width + ch_width > width && !chunk.is_empty() {
                    lines.push(std::mem::take(&mut chunk));
                    chunk_width = 0;
                }
                chunk.push(ch);
                chunk_width += ch_width;
            }
            current = chunk;
            current_width = chunk_width;
            continue;
        }
        if current_width > 0 {
            current.push(' ');
            current_width += 1;
        }
        current.push_str(word);
        current_width += word_width;
    }
    if !current.is_empty() || lines.is_empty() {
        lines.push(current);
    }
    lines
}

fn pad(cell: &str, width: usize, alignment: Alignment) -> String {
    let slack = width.saturating_sub(display_width(cell));
    match alignment {
        Alignment::Right => format!("{}{cell}", " ".repeat(slack)),
        Alignment::Center => {
            let left = slack / 2;
            format!("{}{cell}{}", " ".repeat(left), " ".repeat(slack - left))
        }
        _ => format!("{cell}{}", " ".repeat(slack)),
    }
}

fn heading_level(level: HeadingLevel) -> usize {
    level as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Wide enough that width is not a factor unless a test asks for it.
    const WIDE: usize = 200;

    fn plain(source: &str) -> String {
        render(
            &Document::parse(source),
            false,
            WIDE,
            None,
            &theme::default_pair(),
        )
    }

    fn plain_at(source: &str, width: usize) -> String {
        render(
            &Document::parse(source),
            false,
            width,
            None,
            &theme::default_pair(),
        )
    }

    fn colored(source: &str) -> String {
        render(
            &Document::parse(source),
            true,
            WIDE,
            None,
            &theme::default_pair(),
        )
    }

    /// Longest line, in characters, ignoring SGR escapes.
    fn widest(text: &str) -> usize {
        text.lines()
            .map(|line| display_width(&strip_escapes(line)))
            .max()
            .unwrap_or(0)
    }

    #[test]
    fn plain_output_has_no_escape_sequences() {
        let source = "# H\n\n**bold** and `code` and [link](http://x)\n\n- [ ] task\n\n\
                      ```rust\nfn main() {}\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n";
        let out = plain(source);
        assert!(!out.contains('\x1b'), "found an escape in --plain:\n{out}");
    }

    #[test]
    fn headings_keep_their_level() {
        assert_eq!(plain("### Deep\n"), "### Deep\n");
    }

    #[test]
    fn task_markers_render_as_brackets() {
        let out = plain("- [ ] open\n- [x] done\n");
        assert_eq!(out, "- [ ] open\n- [x] done\n");
    }

    /// All five markers survive `--plain` byte for byte, which is what makes it
    /// a diffable representation of the source. The extended three arrive as
    /// three `Text` events rather than as a `TaskListMarker`, so this is really
    /// asserting that the terminal renderer recognises them the same way the
    /// core does — including that `- [-]nospace` is *not* a marker and is
    /// therefore reproduced as the prose it is.
    #[test]
    fn five_state_markers_round_trip_through_plain() {
        let source = "- [ ] open\n- [/] doing\n- [x] done\n- [-] dropped\n- [?] stuck\n";
        assert_eq!(plain(source), source);

        let literal = "- [-]nospace\n- [!] not a marker\n";
        assert_eq!(plain(literal), literal);

        // A bare marker at end of line keeps its shape too, with no space
        // invented after it.
        assert_eq!(plain("- [-]\n"), "- [-]\n");
    }

    /// ...and `--ansi` colours each of them differently, with cancelled struck.
    #[test]
    fn each_state_gets_its_own_colour() {
        let out = colored("- [ ] a\n- [/] b\n- [x] c\n- [-] d\n- [?] e\n");
        for code in [
            "\x1b[33m[ ]",
            "\x1b[36m[/]",
            "\x1b[32m[x]",
            "\x1b[2;9m[-]",
            "\x1b[35m[?]",
        ] {
            assert!(out.contains(code), "missing {code:?} in {out:?}");
        }
        // The words themselves are untouched by the styling.
        assert_eq!(
            strip_escapes(&out),
            "- [ ] a\n- [/] b\n- [x] c\n- [-] d\n- [?] e\n"
        );
    }

    #[test]
    fn ordered_lists_number_themselves() {
        let out = plain("1. one\n2. two\n");
        assert_eq!(out, "1. one\n2. two\n");
    }

    #[test]
    fn nested_lists_indent() {
        let out = plain("- a\n  - b\n");
        assert_eq!(out, "- a\n  - b\n");
    }

    #[test]
    fn blockquotes_get_a_bar() {
        let out = plain("> quoted\n");
        assert_eq!(out, "│ quoted\n");
    }

    #[test]
    fn code_fences_are_indented() {
        let out = plain("```\nlet x = 1;\n```\n");
        assert_eq!(out, "    let x = 1;\n");
    }

    #[test]
    fn links_show_their_target() {
        assert_eq!(
            plain("[docs](http://example.com)\n"),
            "docs (http://example.com)\n"
        );
    }

    #[test]
    fn tables_align_into_columns() {
        let out = plain("| name | n |\n|---|--:|\n| ab | 1 |\n");
        assert_eq!(out, "name │ n\n─────┼──\nab   │ 1\n");
    }

    #[test]
    fn ansi_mode_emits_escapes_and_ends_reset() {
        let out = colored("# H\n\ntext\n");
        assert!(out.contains("\x1b[1;36m"), "{out:?}");
        assert!(out.contains("\x1b[0m"), "{out:?}");
    }

    #[test]
    fn ansi_and_plain_carry_the_same_words() {
        // The fence and the table are here deliberately. `--plain` is defined
        // as `--ansi` with the escapes suppressed, and the regression this
        // caught was `--ansi` emitting an extra indented line after every code
        // fence, because syntect's trailing reset lands after the final newline
        // and `.lines()` then reports it as a line of its own.
        let source = "\
# Title

Some *text* with `code`.

- [x] done

```rust
fn main() {}
```

| a | b |
|---|---|
| 1 | 2 |

> quoted

---

after
";
        let stripped = strip_escapes(&colored(source));
        assert_eq!(stripped, plain(source));
    }

    #[test]
    fn a_rule_is_drawn_to_fit_the_terminal() {
        // It used to be a fixed 60 columns, which soft-wraps into two lines on
        // anything narrower and is the one layout element that cannot recover.
        for width in [20usize, 40, 80, 200] {
            let out = plain_at("a\n\n---\n\nb\n", width);
            let rule = out.lines().find(|line| line.contains('─')).expect("a rule");
            let drawn = rule.chars().count();
            assert!(drawn <= width, "rule is {drawn} chars at width {width}");
            assert_eq!(drawn, width.min(MAX_RULE_WIDTH));
        }
    }

    #[test]
    fn a_rule_inside_a_blockquote_leaves_room_for_the_bar() {
        let out = plain_at("> a\n>\n> ---\n", 20);
        let rule = out.lines().find(|line| line.contains('─')).expect("a rule");
        assert!(rule.starts_with("│ "), "{out}");
        assert_eq!(rule.chars().count(), 20);
    }

    #[test]
    fn the_prefix_tunable_stops_after_n_blocks() {
        // ADR-2's first-paint count is a parameter in every format, not just
        // `--html`: `--prefix` used to be accepted and silently ignored here.
        let doc = Document::parse("# One\n\ntwo\n\nthree\n");
        assert_eq!(doc.blocks().len(), 3);

        let two = render(&doc, false, WIDE, Some(2), &theme::default_pair());
        assert!(two.contains("# One"), "{two}");
        assert!(two.contains("two"), "{two}");
        assert!(!two.contains("three"), "{two}");

        let all = render(&doc, false, WIDE, None, &theme::default_pair());
        assert!(all.contains("three"), "{all}");

        // Out of range clamps rather than panicking; zero emits nothing.
        assert_eq!(
            render(&doc, false, WIDE, Some(99), &theme::default_pair()),
            all
        );
        assert_eq!(
            render(&doc, false, WIDE, Some(0), &theme::default_pair()),
            ""
        );
    }

    #[test]
    fn output_ends_with_exactly_one_newline() {
        let out = plain("# H\n\n\n\npara\n\n\n");
        assert!(out.ends_with("para\n"));
        assert!(!out.ends_with("\n\n"));
    }

    #[test]
    fn an_empty_document_renders_nothing() {
        assert_eq!(plain(""), "");
    }

    // --- frontmatter -------------------------------------------------

    #[test]
    fn yaml_frontmatter_is_not_rendered_as_content() {
        // The regression: without the metadata options the closing `---`
        // parses as a setext H2 underline, so this rendered as a heading
        // reading "title: Test tags: [a, b]".
        let source = "---\ntitle: Test\ntags: [a, b]\n---\n\n# Real heading\n\nBody.\n";
        let out = plain(source);
        assert_eq!(out, "# Real heading\n\nBody.\n");
        assert!(!out.contains("title:"), "{out}");
        assert!(!out.contains("tags:"), "{out}");
    }

    #[test]
    fn toml_frontmatter_is_not_rendered_as_content() {
        let out = plain("+++\ntitle = \"Hugo Doc\"\n+++\n\n# Body heading\n");
        assert_eq!(out, "# Body heading\n");
    }

    #[test]
    fn a_thematic_break_is_still_a_thematic_break() {
        // Frontmatter only opens at byte 0. A `---` further down must keep
        // meaning "horizontal rule", and a `---` after a paragraph must keep
        // meaning "setext heading".
        assert!(plain("intro\n\n---\n\nafter\n").contains('─'));
        assert_eq!(plain("Setext\n---\n\nbody\n"), "## Setext\n\nbody\n");
    }

    // --- table width -------------------------------------------------

    /// A table whose cells are far wider than any sane terminal.
    const WIDE_TABLE: &str = "\
| command | description | notes |
|---|---|---|
| mark render a-really-long-path/that/keeps/going.md | Renders the document to stdout with syntax highlighting applied to every fenced code block | Honours --html, --ansi and --plain, defaulting to plain when stdout is not a terminal |
| mark check | Flips exactly one checkbox by rewriting a single byte in place | Refuses to write when the byte at the recorded span is no longer a task marker |
";

    #[test]
    fn a_wide_table_is_wrapped_to_the_terminal_width() {
        for width in [40usize, 60, 80, 120] {
            let out = plain_at(WIDE_TABLE, width);
            assert!(
                widest(&out) <= width,
                "at width {width} the longest line was {} chars:\n{out}",
                widest(&out)
            );
        }
    }

    #[test]
    fn the_separator_never_outruns_the_rows_it_rules_off() {
        // The old separator was computed with a different formula from the
        // rows: `sum(w + 1)` joined by one character, which happens to equal
        // the row width for two columns and is too long for every other count.
        // At 80 columns on a real ADR that produced an 810-character line.
        for source in [
            "| a | b |\n|---|---|\n| 1 | 2 |\n",
            "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n",
            "| a | b | c | d |\n|---|---|---|---|\n| 1 | 2 | 3 | 4 |\n",
            WIDE_TABLE,
        ] {
            for width in [40usize, 80, 200] {
                let out = plain_at(source, width);
                let rule = out
                    .lines()
                    .find(|line| line.contains('┼'))
                    .expect("a separator row");
                let rule_width = rule.chars().count();

                assert!(rule_width <= width, "rule {rule_width} > terminal {width}");
                for line in out.lines() {
                    assert!(
                        line.chars().count() <= rule_width,
                        "line wider than its rule ({rule_width}):\n{out}"
                    );
                }
            }
        }
    }

    #[test]
    fn the_separator_is_exactly_as_wide_as_an_untrimmed_row() {
        // Row width is `sum(widths) + 3 * (columns - 1)`; rows are then
        // right-trimmed, so this is the only place the full width is visible.
        for widths in [vec![4, 1], vec![3, 4, 5], vec![7, 7, 7, 7]] {
            let expected = widths.iter().sum::<usize>() + COLUMN_GAP * (widths.len() - 1);
            assert_eq!(separator(&widths).chars().count(), expected);
        }
    }

    #[test]
    fn wrapping_keeps_every_character_of_every_cell() {
        // A word wider than its column is hard-split across lines, so the
        // contiguous string is legitimately gone. What must survive is the
        // content: strip the layout and every word is still there, in order.
        let out = plain_at(WIDE_TABLE, 60);

        // Reassemble one column by taking its field from every physical line,
        // then drop the whitespace the wrapping introduced.
        let column = |index: usize| -> String {
            out.lines()
                .filter(|line| !line.contains('┼'))
                .filter_map(|line| line.split('│').nth(index))
                .flat_map(str::chars)
                .filter(|ch| !ch.is_whitespace())
                .collect()
        };

        assert!(
            column(0).contains("a-really-long-path/that/keeps/going.md"),
            "column 0 lost the long path:\n{out}"
        );
        assert!(
            column(1).contains("syntaxhighlightingapplied"),
            "column 1 lost text:\n{out}"
        );
        assert!(
            column(2).contains("nolongerataskmarker"),
            "column 2 lost text:\n{out}"
        );
    }

    #[test]
    fn ansi_tables_respect_the_width_too() {
        let out = render(
            &Document::parse(WIDE_TABLE),
            true,
            80,
            None,
            &theme::default_pair(),
        );
        assert!(out.contains('\x1b'), "expected colour");
        assert!(widest(&out) <= 80, "longest line {}:\n{out}", widest(&out));
    }

    #[test]
    fn a_table_inside_a_blockquote_accounts_for_the_prefix() {
        // The quote bar is two columns the table cannot use.
        let quoted = format!("> {}", WIDE_TABLE.trim_end().replace('\n', "\n> "));
        let out = plain_at(&format!("{quoted}\n"), 60);
        assert!(widest(&out) <= 60, "longest line {}:\n{out}", widest(&out));
        assert!(out.lines().all(|line| line.starts_with('│')), "{out}");
    }

    #[test]
    fn a_narrow_table_keeps_its_natural_width() {
        // Wrapping must not kick in when there is room; this is the layout
        // every small table in the ADR corpus gets.
        let out = plain_at("| name | n |\n|---|--:|\n| ab | 1 |\n", 80);
        assert_eq!(out, "name │ n\n─────┼──\nab   │ 1\n");
    }

    #[test]
    fn column_widths_water_fill_rather_than_starving_one_column() {
        // Natural widths 30 and 4 in a 24-column budget: the wide column is
        // capped, the narrow one keeps all 4 rather than being cut in half.
        let rows = vec![vec!["x".repeat(30), "abcd".to_owned()]];
        let widths = column_widths(&rows, 2, 24);
        assert_eq!(widths[1], 4);
        assert!(widths[0] >= MIN_COLUMN_WIDTH);
        assert!(widths.iter().sum::<usize>() + COLUMN_GAP <= 24);
    }

    #[test]
    fn wrap_breaks_on_whitespace_and_splits_over_long_words() {
        assert_eq!(wrap("one two three", 9), vec!["one two", "three"]);
        assert_eq!(wrap("short", 10), vec!["short"]);
        assert_eq!(wrap("aaaaaaa", 3), vec!["aaa", "aaa", "a"]);
        assert_eq!(wrap("", 5), vec![""]);
        assert_eq!(wrap("anything", 0), vec![""]);
    }

    // --- math ---------------------------------------------------------

    #[test]
    fn math_keeps_its_source_spelling_in_the_terminal() {
        // A terminal cannot lay out MathML, and an unhandled event is a
        // *dropped* event — the failure mode here is content vanishing from
        // `--plain`, not looking wrong.
        assert_eq!(
            plain("Let $x^2$ be, and $$\\int_0^1 f$$ too.\n"),
            "Let $x^2$ be, and $$\\int_0^1 f$$ too.\n"
        );
        assert_eq!(
            plain("- [ ] prove $a^2 + b^2 = c^2$\n"),
            "- [ ] prove $a^2 + b^2 = c^2$\n"
        );
    }

    #[test]
    fn math_in_a_table_cell_is_measured_like_any_other_text() {
        let out = plain("| formula | n |\n|---|---|\n| $x^2$ | 1 |\n");
        assert_eq!(out, "formula │ n\n────────┼──\n$x^2$   │ 1\n");
    }

    #[test]
    fn ansi_math_carries_the_same_words_as_plain() {
        let source = "Inline $x^2$ and display $$\\sum_i a_i$$.\n";
        assert_eq!(strip_escapes(&colored(source)), plain(source));
    }

    // --- display width ------------------------------------------------

    /// Every cell in this table is two terminal columns per character.
    const WIDE_CHARS: &str = "\
| 名前 | 説明 |
|---|---|
| 日本語 | 全角文字の列 |
| 絵文字 | 🙂🙂🙂 |
";

    #[test]
    fn display_width_counts_cells_not_characters() {
        assert_eq!(display_width("abc"), 3);
        assert_eq!(display_width("日本語"), 6);
        assert_eq!(display_width("🙂"), 2);
        // A combining mark rides along on the character before it.
        assert_eq!(display_width("e\u{301}"), 1);
    }

    #[test]
    fn a_table_of_wide_characters_stays_aligned() {
        // The M1 reviewer left this: `chars().count()` measured `日本語` as 3
        // where the terminal draws 6, so every column after it slid left by
        // the difference and the separator no longer matched its rows.
        let out = plain_at(WIDE_CHARS, 80);
        let rule = out
            .lines()
            .find(|line| line.contains('┼'))
            .expect("a separator row");
        let rule_width = display_width(rule);

        for line in out.lines() {
            let line_width = display_width(line);
            assert!(
                line_width <= rule_width,
                "line is {line_width} cells against a {rule_width}-cell rule:\n{out}"
            );
        }
        // And the separator sits exactly under the column break.
        let bar = |line: &str| display_width(line.split('│').next().unwrap_or(""));
        let cross = display_width(rule.split('┼').next().unwrap_or(""));
        for line in out.lines().filter(|line| line.contains('│')) {
            assert_eq!(bar(line), cross, "column break moved:\n{out}");
        }
    }

    #[test]
    fn the_columns_bound_holds_for_wide_characters() {
        // The guarantee `--ansi` makes: never wider than the terminal.
        for width in [20usize, 40, 60, 80] {
            let out = plain_at(WIDE_CHARS, width);
            assert!(
                widest(&out) <= width,
                "at width {width} the widest line was {} cells:\n{out}",
                widest(&out)
            );
        }
    }

    #[test]
    fn a_wide_word_is_split_without_overhanging_its_column() {
        // The off-by-one this fixes: a two-cell character cannot land exactly
        // on an odd boundary, so a `== width` check stepped over it.
        for width in [3usize, 4, 5] {
            for line in wrap("日本語日本語日本語", width) {
                assert!(
                    display_width(&line) <= width,
                    "{line:?} is {} cells at width {width}",
                    display_width(&line)
                );
            }
        }
        assert_eq!(wrap("日本語", 4), vec!["日本", "語"]);
        // Every character survives the split.
        let joined: String = wrap("日本語日本語", 3).concat();
        assert_eq!(joined, "日本語日本語");
    }

    #[test]
    fn padding_pays_in_cells() {
        assert_eq!(pad("日本", 6, Alignment::None), "日本  ");
        assert_eq!(pad("日本", 6, Alignment::Right), "  日本");
        assert_eq!(display_width(&pad("🙂", 5, Alignment::Center)), 5);
    }

    #[test]
    fn a_table_inside_a_wide_character_list_item_keeps_the_bound() {
        // The list indent is spent before the table gets its budget, and both
        // are measured in cells. A wide-character table nested in a list is
        // where an under-measured prefix and an under-measured cell compound.
        let quoted = format!(
            "- 日本語\n\n  {}",
            WIDE_CHARS.trim_end().replace('\n', "\n  ")
        );
        let out = plain_at(&format!("{quoted}\n"), 40);
        assert!(
            widest(&out) <= 40,
            "widest line {} cells:\n{out}",
            widest(&out)
        );
    }

    fn strip_escapes(text: &str) -> String {
        let mut out = String::new();
        let mut chars = text.chars();
        while let Some(ch) = chars.next() {
            if ch != '\x1b' {
                out.push(ch);
                continue;
            }
            for ch in chars.by_ref() {
                if ch.is_ascii_alphabetic() {
                    break;
                }
            }
        }
        out
    }
}
