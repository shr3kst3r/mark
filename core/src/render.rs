//! Blocks → HTML, carrying the two contracts the rest of the product is built
//! on.
//!
//! **ADR-1, the checkbox contract.** Every task marker is emitted as
//! `<input type="checkbox" class="mk-task" data-mk-idx=".." data-mk-start=".."
//! data-mk-end="..">`, so a DOM click knows its own byte span with no side
//! table to keep in sync.
//!
//! **ADR-2, block identity.** Every top-level block is wrapped in
//! `<div class="mk-blk" data-blk="<hash>-<ordinal>" data-mk-start=".."
//! data-mk-end="..">`, and the id is content-derived rather than positional.
//!
//! Blocks render independently of one another — [`render_range`] takes any
//! slice of the block list — which is what makes ADR-2's prefix-then-fill
//! possible without re-parsing. Task indices are looked up by byte offset
//! rather than counted as we go, precisely so that rendering block 40 first and
//! block 0 second cannot renumber a checkbox.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::ops::Range;
use std::sync::Arc;
use std::time::{Duration, Instant};

use pulldown_cmark::{CowStr, Event, Tag, TagEnd, html};

use crate::block::Block;
use crate::highlight::{self, Highlighter};
use crate::parse::{Document, code_language, slugify};
use crate::rich::{self, Diagram, MathDisplay};
use crate::sanitize;
use crate::tasks;
use crate::theme::{self, ThemePair};

/// How much of a document to emit, and in what shape.
#[derive(Debug, Clone)]
pub struct RenderOptions {
    /// Emit only the first N blocks. `None` emits all of them.
    ///
    /// ADR-2 calls the first-paint block count "a tunable, not a constant", to
    /// be derived from viewport height at runtime — hence a parameter here and
    /// no default baked into the core.
    pub prefix_blocks: Option<usize>,
    /// Wrap the output in a complete `<html>` document with the default
    /// stylesheet inline. The CLI's `--html` needs this; the app does not.
    pub standalone: bool,
    /// `<title>` for standalone output. Falls back to the first heading.
    pub title: Option<String>,
    /// The theme to render against.
    ///
    /// A *resolved* pair rather than a name, because rendering may not fail: a
    /// name that does not resolve is a named error at the boundary where the
    /// caller can report it (the C ABI, the CLI), not a blank document here.
    /// `Default` is the built-in pair, which no user file can break.
    pub theme: Arc<ThemePair>,
}

impl Default for RenderOptions {
    fn default() -> Self {
        RenderOptions {
            prefix_blocks: None,
            standalone: false,
            title: None,
            // `Arc<T>`'s own `Default` would build a second pair; this shares
            // the one the process already has.
            theme: theme::default_pair(),
        }
    }
}

/// Rendered HTML plus the counters `mark stats` reports.
#[derive(Debug, Clone)]
pub struct Render {
    pub html: String,
    pub blocks_emitted: usize,
    pub blocks_total: usize,
    pub code_bytes: usize,
    /// Code blocks that went through the highlighter. A `mermaid` fence that
    /// rendered as a diagram is counted in [`diagrams`] instead, not here.
    ///
    /// [`diagrams`]: Render::diagrams
    pub code_blocks: usize,
    pub highlight_time: Duration,
    /// `$…$` and `$$…$$` expressions rendered to MathML.
    pub math: usize,
    /// `mermaid` fences rendered to SVG, or badged. A fence `merman` reported
    /// as `NoDiagram` is a code block, so it is not counted here.
    pub diagrams: usize,
    /// Constructs that produced a badge instead of MathML or SVG. ADR-5's
    /// design is that a failure is *visible*; this is how it is also countable
    /// — `mark stats` on a real document says how much of its math we cannot
    /// render, without anyone having to read the page.
    pub rich_failures: usize,
    /// Time in [`crate::rich`], the counterpart to [`highlight_time`].
    ///
    /// [`highlight_time`]: Render::highlight_time
    pub rich_time: Duration,
}

/// Render a whole document, honouring [`RenderOptions::prefix_blocks`].
#[must_use]
pub fn render(doc: &Document<'_>, opts: &RenderOptions) -> Render {
    let end = opts
        .prefix_blocks
        .unwrap_or(usize::MAX)
        .min(doc.blocks().len());
    let mut render = with_context(
        doc,
        &Context::new(doc, &opts.theme),
        0..end,
        BlockMark::default(),
    );
    render.blocks_total = doc.blocks().len();

    if opts.standalone {
        let title = opts
            .title
            .clone()
            .or_else(|| doc.title())
            .unwrap_or_else(|| "mark".to_owned());
        render.html = standalone(&title, &render.html, &opts.theme);
    }
    render
}

/// Render an arbitrary slice of the block list, in the default theme.
/// Out-of-range indices are clamped rather than panicking: this is reachable
/// from the C ABI.
#[must_use]
pub fn render_range(doc: &Document<'_>, blocks: Range<usize>) -> Render {
    render_range_themed(doc, blocks, &theme::default_pair())
}

/// The same, against a chosen theme.
#[must_use]
pub fn render_range_themed(
    doc: &Document<'_>,
    blocks: Range<usize>,
    theme: &Arc<ThemePair>,
) -> Render {
    with_context(doc, &Context::new(doc, theme), blocks, BlockMark::default())
}

/// An extra class, and an origin, stamped onto every `mk-blk` div in a range.
///
/// This exists for one caller — [`crate::diff::diff_document`], which composes
/// a document out of runs taken from two different parses and has to say which
/// is which. The class goes **on the `mk-blk` div** rather than on a wrapper
/// element because ADR-2's shell addresses blocks by `data-blk` and anchors
/// scrolling on `.mk-blk`; an extra level of nesting would quietly break both.
#[derive(Debug, Clone, Copy, Default)]
pub struct BlockMark {
    /// Appended to the div's class list, e.g. `mk-diff-add`.
    pub class: Option<&'static str>,
    /// Emit `data-mk-side="old"`, meaning the byte offsets on this block refer
    /// to the *old* document.
    ///
    /// Load-bearing rather than informational: a checkbox click inside deleted
    /// content would otherwise write to a byte range in the current file that
    /// no longer means what the attribute says. The shell must treat such
    /// blocks as inert.
    pub old_side: bool,
}

/// Render several ranges of one document, building the per-document lookups
/// **once**.
///
/// [`Context::new`] walks every task and every heading in the document, so
/// calling [`render_range`] in a loop is O(ranges × document). ADR-2's edit
/// script has one range per changed run, and a document where every block
/// changed would otherwise be quadratic — which is the case a re-render after a
/// find-and-replace hits.
#[must_use]
pub fn render_ranges(
    doc: &Document<'_>,
    ranges: &[Range<usize>],
    theme: &Arc<ThemePair>,
) -> Vec<Render> {
    let ctx = Context::new(doc, theme);
    ranges
        .iter()
        .map(|blocks| with_context(doc, &ctx, blocks.clone(), BlockMark::default()))
        .collect()
}

/// [`render_ranges`], with a [`BlockMark`] per range.
///
/// One `Context` for the whole document, as above: `diff_document` has one
/// range per changed run, and rebuilding the task and heading lookups per run
/// would be quadratic on exactly the document where every block changed.
#[must_use]
pub fn render_marked_ranges(
    doc: &Document<'_>,
    ranges: &[(Range<usize>, BlockMark)],
    theme: &Arc<ThemePair>,
) -> Vec<Render> {
    let ctx = Context::new(doc, theme);
    ranges
        .iter()
        .map(|(blocks, mark)| with_context(doc, &ctx, blocks.clone(), *mark))
        .collect()
}

fn with_context(
    doc: &Document<'_>,
    ctx: &Context,
    blocks: Range<usize>,
    mark: BlockMark,
) -> Render {
    let start = blocks.start.min(doc.blocks().len());
    let end = blocks.end.clamp(start, doc.blocks().len());

    let mut out = Render {
        html: String::new(),
        blocks_emitted: end - start,
        blocks_total: doc.blocks().len(),
        code_bytes: 0,
        code_blocks: 0,
        highlight_time: Duration::ZERO,
        math: 0,
        diagrams: 0,
        rich_failures: 0,
        rich_time: Duration::ZERO,
    };

    for block in &doc.blocks()[start..end] {
        render_block(doc, block, ctx, mark, &mut out);
    }
    out
}

/// Per-document lookups shared by every block, built once.
struct Context {
    /// Task marker start offset → (document-order index, state).
    tasks: HashMap<usize, (usize, tasks::State)>,
    /// Every metadata token in the document, by source range, in document
    /// order. Read by offset for the same reason task indices are: a block
    /// rendered on its own must reach the same answer as the whole document.
    chips: Vec<tasks::Chip>,
    /// Heading block start offset → deduplicated anchor.
    anchors: HashMap<usize, String>,
    highlighter: &'static Highlighter,
    /// The theme every code block and diagram in this render uses. Carried
    /// here rather than read from anywhere ambient, because ADR-2 requires
    /// highlighting to be a pure function of `(language, code, theme)`.
    theme: Arc<ThemePair>,
}

impl Context {
    /// The chips inside a source range, which for a `Text` event is "the
    /// metadata tokens in this run of prose".
    fn chips_in(&self, span: &Range<usize>) -> &[tasks::Chip] {
        let first = self
            .chips
            .partition_point(|chip| chip.source.start < span.start);
        let last = self
            .chips
            .partition_point(|chip| chip.source.end <= span.end);
        self.chips.get(first..last.max(first)).unwrap_or(&[])
    }

    fn new(doc: &Document<'_>, theme: &Arc<ThemePair>) -> Context {
        let tasks = tasks::enumerate(doc);
        let chips: Vec<tasks::Chip> = tasks.iter().flat_map(|t| t.chips.clone()).collect();
        Context {
            tasks: tasks
                .into_iter()
                .map(|t| (t.start, (t.index, t.state)))
                .collect(),
            chips,
            anchors: doc
                .headings()
                .into_iter()
                .map(|h| (h.start, h.anchor))
                .collect(),
            highlighter: highlight::shared(),
            theme: Arc::clone(theme),
        }
    }
}

fn render_block(
    doc: &Document<'_>,
    block: &Block,
    ctx: &Context,
    mark: BlockMark,
    out: &mut Render,
) {
    let _ = write!(
        out.html,
        "<div class=\"mk-blk mk-{}{}\" data-blk=\"{}\" data-mk-start=\"{}\" data-mk-end=\"{}\"{}>",
        block.kind.slug(),
        mark.class.map(|c| format!(" {c}")).unwrap_or_default(),
        block.id,
        block.start,
        block.end,
        if mark.old_side {
            " data-mk-side=\"old\""
        } else {
            ""
        }
    );

    let events = doc.block_events(block);
    let mut index = 0usize;
    let mut run = 0usize;

    while index < events.len() {
        // An extended marker (`[/]`, `[-]`, `[?]`) is three `Text` events the
        // parser has no opinion about, so it is recognised here with the same
        // structural rule `tasks::enumerate` uses — never by looking at the
        // document's bytes — and the three events are replaced by one element.
        // Without this they would flush as the literal prose `[-]`.
        if let Some((state, span)) = tasks::extended_marker(events, index, doc.source()) {
            flush(events, run..index, &mut out.html);
            let idx = ctx
                .tasks
                .get(&span.start)
                .map_or_else(|| usize::MAX, |(i, _)| *i);
            write_task(&mut out.html, idx, &span, state);
            index += 3;
            run = index;
            continue;
        }
        // Metadata chips. A `Text` event carrying recognised tokens is written
        // here instead of being handed to `pulldown-cmark`'s writer, so the
        // token becomes a `<span class="mk-tag">` and the prose around it does
        // not change. Every other `Text` event takes the untouched fast path.
        if let (Event::Text(text), span) = (&events[index].0, &events[index].1) {
            let chips = ctx.chips_in(span);
            if !chips.is_empty() && span.len() == text.len() {
                flush(events, run..index, &mut out.html);
                write_chipped_text(&mut out.html, text, span, chips);
                index += 1;
                run = index;
                continue;
            }
        }
        match &events[index].0 {
            Event::TaskListMarker(checked) => {
                flush(events, run..index, &mut out.html);
                let span = &events[index].1;
                let (idx, state) = ctx.tasks.get(&span.start).copied().unwrap_or((
                    usize::MAX,
                    if *checked {
                        tasks::State::Done
                    } else {
                        tasks::State::Open
                    },
                ));
                write_task(&mut out.html, idx, span, state);
                index += 1;
                run = index;
            }
            Event::InlineMath(latex) => {
                flush(events, run..index, &mut out.html);
                write_math(out, latex, MathDisplay::Inline);
                index += 1;
                run = index;
            }
            Event::DisplayMath(latex) => {
                flush(events, run..index, &mut out.html);
                write_math(out, latex, MathDisplay::Block);
                index += 1;
                run = index;
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                flush(events, run..index, &mut out.html);
                let language = code_language(kind).map(str::to_owned);
                let close = find_end(events, index);
                let code = collect_text(&events[index + 1..close]);

                if !write_diagram(out, block, language.as_deref(), &code, ctx) {
                    let started = Instant::now();
                    let highlighted =
                        ctx.highlighter
                            .highlight(language.as_deref(), &code, &ctx.theme);
                    out.highlight_time += started.elapsed();
                    out.code_blocks += 1;
                    out.code_bytes += code.len();

                    write_code(&mut out.html, language.as_deref(), &highlighted);
                }
                index = close + 1;
                run = index;
            }
            Event::Start(Tag::Heading { level, .. }) => {
                flush(events, run..index, &mut out.html);
                let anchor = ctx
                    .anchors
                    .get(&block.start)
                    .cloned()
                    .unwrap_or_else(|| slugify(&block.id.to_string()));
                let _ = write!(
                    out.html,
                    "<{level} id=\"{}\" class=\"mk-h\">",
                    escape_attr(&anchor)
                );
                index += 1;
                run = index;
            }
            Event::End(TagEnd::Heading(level)) => {
                flush(events, run..index, &mut out.html);
                let _ = write!(out.html, "</{level}>");
                index += 1;
                run = index;
            }
            _ => index += 1,
        }
    }
    flush(events, run..events.len(), &mut out.html);

    out.html.push_str("</div>");
}

/// Hand a run of untouched events to `pulldown-cmark`'s own writer. Splitting
/// the stream this way keeps its correct handling of tables, footnotes, and
/// inline HTML while letting us own the three constructs that carry contracts.
///
/// **Raw HTML does not go through untouched.** `Event::Html` and
/// `Event::InlineHtml` carry whatever the document embedded, and
/// `pulldown-cmark` writes them verbatim — which is how a `<script>` in a
/// markdown file came to run in the shell page, with the bridge that writes to
/// the reader's files in reach. Each one is filtered by [`sanitize::fragment`]
/// first, and then handed on as `Event::Html` so the writer still sees the
/// event kind it expects and paragraph and block handling are unchanged.
///
/// The filter is applied here rather than in `Document::parse` on purpose:
/// parsing stays a faithful record of the document, spans keep pointing at the
/// bytes they came from, and only the thing that produces *HTML for a browser*
/// pays the cost or takes the opinion.
fn flush(events: &[(Event<'_>, Range<usize>)], range: Range<usize>, out: &mut String) {
    if range.is_empty() {
        return;
    }
    html::push_html(
        out,
        events[range].iter().map(|(event, _)| match event {
            Event::Html(raw) => Event::Html(sanitize::fragment(raw).into()),
            Event::InlineHtml(raw) => Event::InlineHtml(sanitize::fragment(raw).into()),
            // A destination markdown wrote, rather than one HTML wrote.
            // `[click](javascript:alert(1))` never reaches `sanitize::fragment`
            // — it is not raw HTML — and `push_html` would emit it as an
            // `href` verbatim. Two spellings of the same thing must not get
            // two answers.
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                id,
            }) if !sanitize::safe_url(dest_url) => Event::Start(Tag::Link {
                link_type: *link_type,
                // Emptied rather than dropped: the anchor stays, so the link
                // text is still read and still copyable, and it goes nowhere.
                dest_url: CowStr::Borrowed(""),
                title: title.clone(),
                id: id.clone(),
            }),
            Event::Start(Tag::Image {
                link_type,
                dest_url,
                title,
                id,
            }) if !sanitize::safe_url(dest_url) => Event::Start(Tag::Image {
                link_type: *link_type,
                dest_url: CowStr::Borrowed(""),
                title: title.clone(),
                id: id.clone(),
            }),
            other => other.clone(),
        }),
    );
}

/// One task marker, as the element ADR-1's checkbox contract fixes.
///
/// `2026-08-27-five-task-states` widens it rather than replacing it: the
/// element stays `<input type="checkbox" class="mk-task">`, because
/// `shell.js`'s restamp refuses when the DOM's checkbox count differs from the
/// source's task count and a marker rendered as anything else would break
/// incremental patching silently.
///
/// `data-mk-state` is what the app and the stylesheet read; `checked` is
/// emitted for `done` **only**, and stays last so ` checked>` remains the
/// spelling every existing test and selector matches. `aria-label` is emitted
/// because a five-state control announced as a two-state checkbox would lie to
/// VoiceOver.
fn write_task(out: &mut String, index: usize, span: &Range<usize>, state: tasks::State) {
    let _ = write!(
        out,
        "<input type=\"checkbox\" class=\"mk-task\" data-mk-idx=\"{index}\" \
         data-mk-start=\"{}\" data-mk-end=\"{}\" data-mk-state=\"{}\" \
         aria-label=\"{}\"{}>",
        span.start,
        span.end,
        state.as_str(),
        state.spoken(),
        if state == tasks::State::Done {
            " checked"
        } else {
            ""
        }
    );
}

/// One run of prose, with its recognised metadata tokens drawn as chips.
///
/// The chip carries its own data — `data-mk-due` and friends — and no colour
/// that depends on the date: `2026-08-27-inline-task-metadata` puts overdue
/// styling in the app's `shell.js`, precisely so `mark render --html` stays a
/// pure function of its source and stays reproducible.
fn write_chipped_text(out: &mut String, text: &str, span: &Range<usize>, chips: &[tasks::Chip]) {
    let mut cursor = span.start;
    for chip in chips {
        if chip.source.start < cursor {
            continue;
        }
        out.push_str(&escape_html(
            &text[cursor - span.start..chip.source.start - span.start],
        ));
        let token = &text[chip.source.start - span.start..chip.source.end - span.start];
        let _ = match &chip.kind {
            tasks::ChipKind::Priority(level) => write!(
                out,
                "<span class=\"mk-tag\" data-mk-priority=\"{level}\">{}</span>",
                escape_html(token)
            ),
            tasks::ChipKind::Tag { name, value } => write!(
                out,
                "<span class=\"mk-tag\" data-mk-tag=\"{}\"{}>{}</span>",
                escape_attr(name),
                chip_data(name, value.as_deref()),
                escape_html(token)
            ),
        };
        cursor = chip.source.end;
    }
    out.push_str(&escape_html(&text[cursor - span.start..]));
}

/// The typed attribute a known key adds to its chip, if any.
///
/// `@start(…)` becomes `data-mk-start-date` rather than `data-mk-start`,
/// because `data-mk-start` is already ADR-1's byte offset on task and block
/// elements and reusing the name on a chip would make the two impossible to
/// tell apart in a selector.
fn chip_data(name: &str, value: Option<&str>) -> String {
    match (name, value) {
        ("due" | "start" | "done", Some(value)) if tasks::parse_iso_date(value).is_some() => {
            let attribute = if name == "start" { "start-date" } else { name };
            format!(" data-mk-{attribute}=\"{}\"", escape_attr(value))
        }
        (_, Some(value)) => format!(" data-mk-value=\"{}\"", escape_attr(value)),
        (_, None) => String::new(),
    }
}

/// Append one math expression, rendered to inline MathML by [`crate::rich`].
///
/// ADR-5: no KaTeX, no JavaScript. A failure becomes a badge here rather than
/// propagating, because the surrounding paragraph still has to render.
fn write_math(out: &mut Render, latex: &str, display: MathDisplay) {
    let started = Instant::now();
    let rendered = rich::math(latex, display);
    out.rich_time += started.elapsed();
    out.math += 1;
    out.rich_failures += usize::from(rendered.failed());
    out.html.push_str(&rendered.html);
}

/// Append a `mermaid` fence as inline SVG, returning whether it was one.
///
/// `false` means "render this as an ordinary code block": either the info
/// string was not `mermaid`, or `merman` reported `NoDiagram` — which per
/// plan §3 means the fence's contents are not a diagram, and is deliberately
/// *not* a reason to show an error badge.
fn write_diagram(
    out: &mut Render,
    block: &Block,
    language: Option<&str>,
    code: &str,
    ctx: &Context,
) -> bool {
    if !rich::is_mermaid(language) {
        return false;
    }

    let started = Instant::now();
    // ADR-5: the id derives from the block's `data-blk`, so it is unique in
    // the document and survives ADR-2's incremental patching unchanged.
    let diagram = rich::diagram(code, block.id.as_str(), &ctx.theme);
    out.rich_time += started.elapsed();

    let Diagram::Rendered(rendered) = diagram else {
        return false;
    };
    out.diagrams += 1;
    out.rich_failures += usize::from(rendered.failed());
    out.html.push_str(&rendered.html);
    true
}

fn write_code(out: &mut String, language: Option<&str>, highlighted: &highlight::Highlighted) {
    out.push_str("<pre class=\"mk-code\"");
    if let Some(language) = language {
        let _ = write!(out, " data-lang=\"{}\"", escape_attr(language));
    }
    if highlighted.syntax.is_none() {
        // Says plainly that this block is unhighlighted rather than leaving a
        // reader to guess whether the theme is broken.
        out.push_str(" data-plain=\"1\"");
    }
    out.push_str("><code>");
    out.push_str(&highlighted.html);
    out.push_str("</code></pre>");
}

/// Index of the `End` event matching the `Start` at `start`.
fn find_end(events: &[(Event<'_>, Range<usize>)], start: usize) -> usize {
    let mut depth = 0usize;
    for (offset, (event, _)) in events[start..].iter().enumerate() {
        match event {
            Event::Start(_) => depth += 1,
            Event::End(_) => {
                depth -= 1;
                if depth == 0 {
                    return start + offset;
                }
            }
            _ => {}
        }
    }
    events.len().saturating_sub(1)
}

fn collect_text(events: &[(Event<'_>, Range<usize>)]) -> String {
    let mut out = String::new();
    for (event, _) in events {
        if let Event::Text(text) | Event::Code(text) = event {
            out.push_str(text);
        }
    }
    out
}

/// Escape for HTML text content.
#[must_use]
pub fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Escape for a double-quoted HTML attribute value.
#[must_use]
pub fn escape_attr(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// The rules that turn a theme's custom properties into a page.
///
/// Every colour here is `var(--mk-…)`, supplied by [`theme_css`] for **both**
/// appearances at once. Nothing in this string changes when the theme or the
/// system appearance does, which is the point: an appearance switch re-resolves
/// variables and repaints, with no IPC, no re-render, and no DOM work.
///
/// `app/Resources/shell.css` is the same rules for the app, which loads them
/// once per web view rather than per document. The two are deliberately not
/// generated from one source — the shell's copy carries the layout rules the
/// standalone page does not need (and the `content-visibility` warning ADR-2
/// requires) — but the colour rules must agree, and
/// `ShellAssetsTests` pins them together.
#[must_use]
pub fn document_css() -> String {
    let mut css = String::from(
        "\
html { background: var(--mk-background); color: var(--mk-foreground); }
/* `--mk-measure` is the widest a line of prose gets: the 46rem this used to
   cap the body at, less its 1.5rem gutters, so a paragraph keeps the width it
   has always had. It caps each block rather than the body, because a cap on
   the body is a cap on the widest table too -- see `.mk-blk.mk-table`. */
body.mk-doc { --mk-measure: 43rem; margin: 0; padding: 2rem 1.5rem;
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
.mk-blk { margin: 0 auto 1rem; max-width: var(--mk-measure); }
.mk-h { line-height: 1.25; margin: 1.8rem 0 0.6rem; color: var(--mk-heading); }
a { color: var(--mk-link); }
pre.mk-code { background: var(--mk-surface); border-radius: 6px; padding: 0.8rem 1rem;
  overflow-x: auto; font: 13px/1.5 'SF Mono', ui-monospace, monospace; }
code { font-family: 'SF Mono', ui-monospace, monospace; }
:not(pre) > code { background: var(--mk-surface); border-radius: 4px; padding: 0.1em 0.35em; }
blockquote { margin: 0; padding-left: 1rem; border-left: 3px solid var(--mk-accent);
  color: var(--mk-subtle); }
/* A table that is a block of its own is the one block allowed past the
   measure: the block drops the cap and becomes the scroll container, and the
   table takes what its columns need -- floored at the measure so a small
   table still lines up with the prose, with scrolling inside the block as the
   last resort. The scroll container has to be the block, because a table can
   only scroll if it is `display: block` and a block-level table fills its
   parent rather than sizing to its columns; that is what left a twelve-column
   table stuck in a 43rem column however wide the page was. The bare rule
   keeps that older behaviour for a table nested in a blockquote or a list
   item, which is not a block of its own and has nothing to be handed. */
table { border-collapse: collapse; display: block; overflow-x: auto; }
.mk-blk.mk-table { max-width: none; overflow-x: auto; }
.mk-blk.mk-table > table { display: table; overflow-x: visible; margin: 0 auto;
  min-width: min(var(--mk-measure), 100%); }
th, td { border: 1px solid var(--mk-rule); padding: 0.35rem 0.7rem; }
th { background: var(--mk-surface); }
hr { border: none; border-top: 1px solid var(--mk-rule); }
/* Task lists. `2026-08-27-five-task-states`: every checkbox is drawn here
   rather than by the platform, because a half-filled box is impossible from a
   native control without JavaScript (`indeterminate` is a JS-only IDL
   property) and ADR-5 forbids JavaScript in the emitted document. The cost is
   named in that ADR: every existing document's checkboxes change appearance.
   The done tick is a background image rather than a `::before`, because
   pseudo-elements do not render on a replaced element. */
input.mk-task {
  appearance: none; -webkit-appearance: none;
  width: 0.95em; height: 0.95em; margin-right: 0.4rem;
  border: 1px solid var(--mk-rule); border-radius: 3px;
  background-color: transparent; background-repeat: no-repeat;
  background-position: center; background-size: 0.8em 0.8em;
  vertical-align: -0.1em; cursor: pointer; }
input.mk-task:focus-visible { outline: 2px solid var(--mk-accent); outline-offset: 1px; }
input.mk-task[data-mk-state='done'] {
  background-color: var(--mk-accent); border-color: var(--mk-accent);
  background-image: url('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 \
viewBox=%220 0 16 16%22%3E%3Cpath d=%22M3.5 8.5 6.5 11.5 12.5 4.5%22 fill=%22none%22 \
stroke=%22%23fff%22 stroke-width=%222.2%22 stroke-linecap=%22round%22 \
stroke-linejoin=%22round%22/%3E%3C/svg%3E'); }
input.mk-task[data-mk-state='in-progress'] {
  border-color: var(--mk-accent);
  background-image: linear-gradient(90deg, var(--mk-accent) 50%, transparent 50%); }
input.mk-task[data-mk-state='blocked'] {
  border-color: var(--mk-warning); background-color: var(--mk-warning); }
input.mk-task[data-mk-state='cancelled'] { border-color: var(--mk-muted); }
/* Deliberate, and named in the ADR: a cancelled parent strikes its whole
   subtree, because `line-through` propagates and a child cannot cancel it. */
li:has(> input.mk-task[data-mk-state='cancelled']) {
  text-decoration: line-through; color: var(--mk-muted); }
/* Metadata chips (2026-08-27-inline-task-metadata). Neutral: the renderer
   never reads a clock, so nothing here can depend on today's date. Overdue
   colouring is the app's job, from `data-mk-due`, in its injected shell
   script -- which is not JavaScript in *this* document. (Spelling that file's
   name here would trip the rendered-page test that forbids a script
   reference, which is the check doing its job.) */
.mk-tag { color: var(--mk-subtle); background: var(--mk-surface);
  border-radius: 4px; padding: 0.05em 0.35em; margin-left: 0.25em;
  font-size: 0.85em; white-space: nowrap; }
.mk-tag[data-mk-priority='1'] { color: var(--mk-subtle);
  background: color-mix(in srgb, var(--mk-subtle) 14%, transparent); }
.mk-tag[data-mk-priority='2'] { color: var(--mk-s09);
  background: color-mix(in srgb, var(--mk-s09) 14%, transparent); }
.mk-tag[data-mk-priority='3'] { color: var(--mk-error);
  background: color-mix(in srgb, var(--mk-error) 14%, transparent); }
mark { background-color: var(--mk-s0A); color: var(--mk-s00);
  border-radius: 2px; padding: 0.05em 0.2em; }
::selection { background: var(--mk-selection); }
/* ADR-5. No font or stylesheet is fetched for either: MathML resolves to the
   system `math` font and inherits `currentColor`, and merman's SVG carries its
   own scoped <style> — which is why a diagram is rendered once per appearance
   and switched here rather than re-coloured. */
.mk-diagram { overflow-x: auto; }
.mk-diagram svg { max-width: 100%; height: auto; }
.mk-appear-dark { display: none; }
@media (prefers-color-scheme: dark) {
  .mk-appear-light { display: none; }
  .mk-appear-dark { display: inline; }
}
math { font-size: 1.05em; }
math[display='block'] { display: block; margin: 0.6rem 0; overflow-x: auto; }
.mk-rich-error { display: inline-block; max-width: 100%; vertical-align: middle;
  border: 1px solid var(--mk-error); border-radius: 4px;
  background: color-mix(in srgb, var(--mk-error) 12%, transparent);
  padding: 0.1em 0.4em; font-size: 0.9em; }
.mk-diagram-error { display: block; }
.mk-rich-label { color: var(--mk-error); font-weight: 600; text-transform: uppercase;
  font-size: 0.75em; letter-spacing: 0.04em; margin-right: 0.4em; }
.mk-rich-message { color: var(--mk-subtle); }
/* The raw source stays selectable next to the badge — that is the whole point
   of failing visibly rather than blanking the construct. */
.mk-rich-source { user-select: text; white-space: pre-wrap; margin: 0 0.4em 0 0; }
.mk-diagram-error .mk-rich-source { display: block; margin: 0.4em 0 0; }
/* 2026-08-28-git-differences-by-running-git. No new theme slot: additions take
   `success`, removals `error`, and the gutter bar `muted` -- so a theme change
   stays a CSS swap and `codeStamp` is untouched. `color-mix` keeps the tint a
   wash rather than a fill, because these blocks contain running prose that
   still has to be readable. */
.mk-blk.mk-diff-add, .mk-blk.mk-diff-mod, .mk-blk.mk-diff-del {
  position: relative; padding-left: 0.9rem; border-radius: 3px; }
.mk-blk.mk-diff-add::before, .mk-blk.mk-diff-mod::before, .mk-blk.mk-diff-del::before {
  content: ''; position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
  border-radius: 2px; }
.mk-blk.mk-diff-add {
  background: color-mix(in srgb, var(--mk-success) 10%, transparent); }
.mk-blk.mk-diff-add::before { background: var(--mk-success); }
.mk-blk.mk-diff-mod {
  background: color-mix(in srgb, var(--mk-success) 10%, transparent); }
.mk-blk.mk-diff-mod::before { background: var(--mk-warning); }
.mk-blk.mk-diff-del {
  background: color-mix(in srgb, var(--mk-error) 10%, transparent);
  color: var(--mk-subtle); }
.mk-blk.mk-diff-del::before { background: var(--mk-error); }
/* Deleted content reads as deleted, not merely tinted -- a reader scanning a
   diff should not have to consult the colour to know which half is gone.
   Applied to the block's text rather than to the block, so a struck heading
   does not strike its own rule. */
.mk-blk.mk-diff-del > * { text-decoration: line-through; }
/* Except code and diagrams, where a line through every glyph is unreadable.
   They carry the tint and the bar and nothing else. */
.mk-blk.mk-diff-del > pre, .mk-blk.mk-diff-del > .mk-diagram { text-decoration: none; }
/* A removed block is inert: its byte offsets point into a version of the file
   that is not on disk. The shell refuses the click; this makes the refusal
   visible rather than mysterious. */
.mk-blk[data-mk-side='old'] input.mk-task { pointer-events: none; opacity: 0.5; }
/*
 * Paper.
 *
 * A theme is a screen decision: sixteen of them exist because a reader picks
 * one for the room they are in, and none of that survives a printer. So the
 * palette is overridden wholesale here rather than each rule being adjusted —
 * ink on white, and every rule below keeps working because they all read the
 * same custom properties.
 *
 * Backgrounds are the specific thing that has to go. A dark theme printed as
 * laid out is a page of toner, and the reader who pressed Print did not ask for
 * one.
 */
@media print {
  :root, :root[data-theme='dark'] {
    --mk-background: #ffffff; --mk-surface: #f4f4f4;
    --mk-foreground: #000000; --mk-heading: #000000;
    --mk-muted: #444444; --mk-subtle: #666666;
    --mk-border: #cccccc; --mk-link: #0000ee;
  }
  html, body.mk-doc { background: #ffffff; color: #000000; }
  body.mk-doc { padding: 0; font-size: 11pt; }
  /* The measure is a screen decision as well: paper has margins of its own,
     and a 43rem column inside them leaves a third of the sheet empty.
     `min-width` goes with it -- on a sheet narrower than the measure it would
     push a small table off the edge -- and so does the centring, since on
     paper there is no wide window to centre a table in. */
  .mk-blk { max-width: none; }
  .mk-blk.mk-table > table { min-width: 0; margin-inline: 0; }
  /* Page breaks. A heading at the foot of a page, or a code block or table
     split down the middle, is the difference between a printout someone can
     read and one they reprint. */
  .mk-h { break-after: avoid-page; break-inside: avoid; }
  pre, table, .mk-diagram, blockquote, li { break-inside: avoid; }
  img, svg { max-width: 100%; break-inside: avoid; }
  /* Screen-only affordances. The find highlight is a reading aid, and a
     deleted-block tint is a page of grey. */
  ::highlight(mk-find), ::highlight(mk-find-current) { background: transparent; }
  /* An attribute match rather than the three class selectors spelled out.
     `ShellAssetsTests` pins those by substring, and repeating one here
     would be found ahead of the real rule in whichever stylesheet carries
     this block first. */
  .mk-blk[class*='mk-diff-'] { background: transparent; }
}
",
    );
    css.push_str(&token_css());
    css
}

/// `.t0B { color: var(--mk-s0B) }` for every palette slot.
///
/// The slot classes are **constant** — the theme supplies the colours, not the
/// class names — so this is static CSS that no theme change invalidates. That
/// is the whole reason highlighted HTML re-themes without being re-rendered.
#[must_use]
pub fn token_css() -> String {
    let mut css = String::new();
    for index in 0..24u8 {
        let suffix = theme::Slot::parse(&format!("base{index:02X}"))
            .expect("index < 24 is a slot")
            .suffix();
        let _ = writeln!(css, ".t{suffix} {{ color: var(--mk-s{suffix}); }}");
    }
    css
}

/// The theme's own custom properties, light and dark.
#[must_use]
pub fn theme_css(theme: &ThemePair) -> String {
    theme.css()
}

/// Wrap pre-rendered block HTML in a complete, self-contained document.
///
/// [`render`] does this for itself via [`RenderOptions::standalone`], but the
/// merged diff document ([`crate::diff::diff_document`]) is assembled out of two
/// parses and so arrives as bare block HTML with no `RenderOptions` behind it.
/// `mark diff --html` needs the same page furniture around it, including the
/// diff rules in [`document_css`].
#[must_use]
pub fn standalone_document(title: &str, body: &str, theme: &Arc<ThemePair>) -> String {
    standalone(title, body, theme)
}

fn standalone(title: &str, body: &str, theme: &Arc<ThemePair>) -> String {
    format!(
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <title>{}</title>\n<style>\n{}{}</style>\n</head>\n<body class=\"mk-doc\">\n{}\n</body>\n</html>\n",
        escape_html(title),
        theme_css(theme),
        document_css(),
        body
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn html_of(src: &str) -> String {
        render(&Document::parse(src), &RenderOptions::default()).html
    }

    #[test]
    fn every_block_is_wrapped_with_its_id_and_span() {
        let html = html_of("# A\n\npara\n");
        let doc_src = "# A\n\npara\n";
        let doc = Document::parse(doc_src);
        for block in doc.blocks() {
            assert!(
                html.contains(&format!("data-blk=\"{}\"", block.id)),
                "missing data-blk for {block:?} in {html}"
            );
            assert!(html.contains(&format!("data-mk-start=\"{}\"", block.start)));
        }
    }

    #[test]
    fn task_markers_carry_index_and_byte_span() {
        let src = "- [ ] one\n- [x] two\n";
        let html = html_of(src);
        assert!(
            html.contains("<input type=\"checkbox\" class=\"mk-task\" data-mk-idx=\"0\""),
            "{html}"
        );
        assert!(html.contains("data-mk-idx=\"1\""), "{html}");
        // ADR-1's shape: the checked one, and only it, carries `checked`.
        assert_eq!(html.matches(" checked>").count(), 1);
        // And the spans point at the literal markers.
        let first = src.find("[ ]").unwrap();
        assert!(html.contains(&format!(
            "data-mk-start=\"{first}\" data-mk-end=\"{}\"",
            first + 3
        )));
    }

    /// The five-state element. `data-mk-state` is the new contract; `checked`
    /// is still emitted for done, and only for done.
    #[test]
    fn every_state_renders_one_checkbox_carrying_its_state() {
        let src = "- [ ] a\n- [/] b\n- [x] c\n- [-] d\n- [?] e\n";
        let html = html_of(src);
        assert_eq!(html.matches("class=\"mk-task\"").count(), 5, "{html}");
        for (index, state) in ["open", "in-progress", "done", "cancelled", "blocked"]
            .into_iter()
            .enumerate()
        {
            let start = src.find(&format!("[{}]", "  /x-?".chars().nth(index + 1).unwrap()));
            assert!(
                html.contains(&format!(
                    "data-mk-idx=\"{index}\" data-mk-start=\"{}\" data-mk-end=\"{}\" \
                     data-mk-state=\"{state}\"",
                    start.unwrap(),
                    start.unwrap() + 3
                )),
                "missing the {state} element in\n{html}"
            );
        }
        // ADR-1's shape survives: exactly the done one carries `checked`, and
        // it is still spelled ` checked>` so every existing selector matches.
        assert_eq!(html.matches(" checked>").count(), 1, "{html}");
        assert!(html.contains("aria-label=\"in progress\""), "{html}");
        // The extended markers are elements, not the literal prose they used
        // to render as.
        assert!(!html.contains("[-]"), "{html}");
        assert!(!html.contains("[?]"), "{html}");
    }

    #[test]
    fn an_unrecognised_bracket_in_an_item_is_still_prose() {
        let html = html_of("- [>] deferred\n- [ab] two\n");
        assert!(!html.contains("mk-task"), "{html}");
        assert!(html.contains("[&gt;] deferred"), "{html}");
    }

    /// Metadata renders as chips carrying their own data — and **no** date
    /// comparison, so the output cannot vary by the day it was rendered.
    #[test]
    fn metadata_renders_as_neutral_chips() {
        let html = html_of("- [ ] ship it @due(2026-09-01) @work !! @start(2026-08-01)\n");
        assert!(
            html.contains(
                "<span class=\"mk-tag\" data-mk-tag=\"due\" data-mk-due=\"2026-09-01\">\
                 @due(2026-09-01)</span>"
            ),
            "{html}"
        );
        assert!(
            html.contains("<span class=\"mk-tag\" data-mk-tag=\"work\">@work</span>"),
            "{html}"
        );
        assert!(
            html.contains("<span class=\"mk-tag\" data-mk-priority=\"2\">!!</span>"),
            "{html}"
        );
        // `data-mk-start` is ADR-1's byte offset; the start *date* gets its own
        // attribute rather than shadowing it.
        assert!(html.contains("data-mk-start-date=\"2026-08-01\""), "{html}");
        // The prose either side is untouched and still escaped.
        assert!(html.contains("ship it "), "{html}");
    }

    /// The prose either side of a chip is escaped exactly as
    /// `pulldown-cmark`'s own writer escapes it, since half of the item goes
    /// through each path and a reader must not be able to tell where the seam
    /// is.
    #[test]
    fn prose_around_a_chip_is_escaped_like_every_other_run() {
        let html = html_of("- [ ] don't a < b & c @work\n");
        assert!(html.contains("don't a &lt; b &amp; c "), "{html}");
        assert!(html.contains(">@work</span>"), "{html}");
        // ...and the same text without metadata, which never enters this path,
        // is escaped identically.
        let plain = html_of("- [ ] don't a < b & c now\n");
        assert!(plain.contains("don't a &lt; b &amp; c now"), "{plain}");
    }

    #[test]
    fn a_chip_is_never_drawn_inside_a_code_span() {
        let html = html_of("- [ ] see `@due(2026-09-01)` for the syntax\n");
        assert!(!html.contains("mk-tag"), "{html}");
        assert!(html.contains("<code>@due(2026-09-01)</code>"), "{html}");
    }

    #[test]
    fn the_stylesheet_paints_five_states_and_reads_no_clock() {
        let css = document_css();
        for state in ["done", "in-progress", "blocked", "cancelled"] {
            assert!(
                css.contains(&format!("input.mk-task[data-mk-state='{state}']")),
                "no rule for {state}"
            );
        }
        assert!(css.contains("appearance: none"), "{css}");
        assert!(css.contains(".mk-tag"), "no chip styling");
        // Nothing here can be date-dependent: there is no such selector.
        assert!(!css.contains("overdue"), "{css}");
    }

    #[test]
    fn a_prose_bracket_is_not_a_checkbox() {
        let html = html_of("A literal [ ] in prose.\n");
        assert!(!html.contains("mk-task"), "{html}");
    }

    #[test]
    fn code_blocks_are_highlighted_and_labelled() {
        let html = html_of("```rust\nfn main() {}\n```\n");
        assert!(
            html.contains("<pre class=\"mk-code\" data-lang=\"rust\">"),
            "{html}"
        );
        assert!(html.contains("<span"), "{html}");
        assert!(!html.contains("data-plain"), "{html}");
    }

    #[test]
    fn unknown_language_still_renders_as_a_code_block() {
        let html = html_of("```nosuchlang\na < b\n```\n");
        assert!(html.contains("data-plain=\"1\""), "{html}");
        assert!(html.contains("a &lt; b"), "{html}");
    }

    #[test]
    fn a_mermaid_fence_renders_as_inline_svg_for_both_appearances() {
        let html = html_of("```mermaid\nflowchart TD\n  A[Start] --> B[Done]\n```\n");
        assert!(html.contains("<div class=\"mk-diagram\">"), "{html}");
        assert!(!html.contains("<pre"), "{html}");
        // ADR-5: no JavaScript reaches the WebView for this.
        assert!(!html.contains("<script"), "{html}");

        // M7's inherited defect: merman bakes Mermaid's light palette into a
        // scoped <style> and paints the SVG root white, so a diagram was a
        // white box on a dark page. Both appearances are now rendered, and
        // `prefers-color-scheme` picks — so the switch stays free.
        assert!(html.contains("class=\"mk-appear-light\""), "{html}");
        assert!(html.contains("class=\"mk-appear-dark\""), "{html}");
        assert!(!html.contains("background-color: white"), "{html}");
        let theme = crate::theme::default_pair();
        let light = theme.light().chrome("foreground").unwrap().hex();
        let dark = theme.dark().chrome("foreground").unwrap().hex();
        assert_ne!(light, dark);
        let (before, after) = html.split_once("mk-appear-dark").unwrap();
        assert!(before.contains(&format!("fill:{light}")), "{before}");
        assert!(after.contains(&format!("fill:{dark}")), "{after}");
        // Nothing left of Mermaid's stock lavender node fill.
        assert!(!html.contains("#ECECFF"), "{html}");
    }

    #[test]
    fn a_diagram_under_an_unpaired_theme_is_emitted_once() {
        // Dracula has no base16 light counterpart, so it is used for both
        // appearances — and then a second copy of the SVG would be bytes in
        // the layout path for nothing.
        let source = "```mermaid\nflowchart TD\n  A --> B\n```\n";
        let doc = Document::parse(source);
        let html = render(
            &doc,
            &RenderOptions {
                theme: crate::theme::resolve("dracula").unwrap(),
                ..RenderOptions::default()
            },
        )
        .html;
        assert!(html.contains("<div class=\"mk-diagram\"><svg"), "{html}");
        assert!(!html.contains("mk-appear-"), "{html}");
        assert!(
            html.contains("#282a36") || html.contains("#21222c"),
            "{html}"
        );
    }

    #[test]
    fn a_diagrams_svg_id_comes_from_its_block_id() {
        // ADR-5's stability constraint: the id is content-derived, so the same
        // diagram in a document with a paragraph inserted above it keeps it.
        let source = "```mermaid\nflowchart TD\n  A --> B\n```\n";
        let doc = Document::parse(source);
        let id = doc.blocks()[0].id.to_string();
        let html = html_of(source);
        assert!(html.contains(&format!("<svg id=\"mk-{id}\"")), "{html}");

        let moved = html_of(&format!("inserted above\n\n{source}"));
        assert!(moved.contains(&format!("<svg id=\"mk-{id}\"")), "{moved}");
    }

    #[test]
    fn two_diagrams_in_one_document_get_distinct_ids() {
        // merman scopes the diagram's own <style> by `#id`, so a shared id is
        // not cosmetic — the second diagram would restyle the first.
        let html = html_of(
            "```mermaid\nflowchart TD\n  A --> B\n```\n\n```mermaid\nflowchart LR\n  C --> D\n```\n",
        );
        let ids: Vec<&str> = html
            .match_indices("<svg id=\"")
            .map(|(at, marker)| {
                let rest = &html[at + marker.len()..];
                &rest[..rest.find('"').expect("a closed attribute")]
            })
            .collect();
        // Two diagrams, two appearances each.
        assert_eq!(ids.len(), 4, "{html}");
        let unique: std::collections::HashSet<&&str> = ids.iter().collect();
        assert_eq!(unique.len(), 4, "{ids:?}");
    }

    #[test]
    fn a_mermaid_fence_that_is_not_a_diagram_stays_a_code_block() {
        // `RenderSvgError::NoDiagram` means "not a diagram" (plan §3), which
        // is a code block and not a badge.
        let html = html_of("```mermaid\nnot a diagram at all\n```\n");
        assert!(
            html.contains("<pre class=\"mk-code\" data-lang=\"mermaid\""),
            "{html}"
        );
        assert!(!html.contains("<svg"), "{html}");
        assert!(!html.contains("mk-rich-error"), "{html}");
    }

    #[test]
    fn a_malformed_diagram_becomes_a_badge_and_keeps_its_source() {
        let html = html_of("```mermaid\nflowchart TD\n  A[[[Start --> B\n```\n");
        assert!(html.contains("mk-diagram-error"), "{html}");
        assert!(html.contains("A[[[Start"), "{html}");
        assert!(!html.contains("<svg"), "{html}");
    }

    #[test]
    fn a_rust_fence_is_never_treated_as_a_diagram() {
        let html = html_of("```rust\nfn main() {}\n```\n");
        assert!(!html.contains("<svg"), "{html}");
        assert!(!html.contains("mk-diagram"), "{html}");
        assert!(html.contains("data-lang=\"rust\""), "{html}");
    }

    #[test]
    fn inline_and_display_math_become_mathml() {
        let html = html_of("Let $x^2$ be, and $$\\int_0^1 f$$ too.\n");
        assert!(html.contains("<math display=\"inline\""), "{html}");
        assert!(html.contains("<math display=\"block\""), "{html}");
        assert!(!html.contains("$"), "the delimiters leaked: {html}");
        assert!(!html.contains("<script"), "{html}");
    }

    #[test]
    fn math_inside_a_task_item_renders_and_leaves_the_checkbox_alone() {
        let html = html_of("- [ ] prove $a^2 + b^2 = c^2$\n");
        assert!(
            html.contains("class=\"mk-task\" data-mk-idx=\"0\""),
            "{html}"
        );
        assert!(html.contains("<math display=\"inline\""), "{html}");
    }

    #[test]
    fn a_broken_expression_becomes_a_badge_rather_than_merror_markup() {
        // ADR-5: `\newcommand` returns `Ok` with an embedded `<merror>`, so a
        // `Result`-only check renders the parser's verbose diagnostics into
        // the page and calls it a success.
        let html = html_of("Define $\\newcommand{\\R}{\\mathbb{R}}$ here.\n");
        assert!(html.contains("mk-math-error"), "{html}");
        assert!(!html.contains("<merror"), "{html}");
        assert!(html.contains("expected an argument"), "{html}");
        // The raw LaTeX is still on the page, and still selectable.
        assert!(html.contains("\\newcommand{\\R}{\\mathbb{R}}"), "{html}");
    }

    #[test]
    fn a_badge_inside_a_paragraph_stays_an_inline_element() {
        // `Event::DisplayMath` is an inline event, so a `<div>` badge would be
        // a `<div>` inside a `<p>` — invalid, and WebKit closes the paragraph
        // around it.
        //
        // The broken expression is `\newcommand` rather than something like
        // `\frac{`: `pulldown-cmark` requires the braces inside `$…$` to
        // balance, so an unclosed one never becomes a math event at all and
        // stays literal text.
        let html = html_of("before $$\\newcommand{\\R}{x}$$ after\n");
        let paragraph = html
            .split("<p>")
            .nth(1)
            .expect("a paragraph")
            .split("</p>")
            .next()
            .expect("a closed paragraph");
        assert!(paragraph.contains("mk-math-error"), "{html}");
        assert!(!paragraph.contains("<div"), "{html}");
    }

    #[test]
    fn dollar_signs_in_prose_are_left_alone() {
        let html = html_of("It costs $5 and $10.\n");
        assert!(html.contains("It costs $5 and $10."), "{html}");
        assert!(!html.contains("<math"), "{html}");
    }

    #[test]
    fn two_amounts_hugging_their_delimiters_are_left_alone_too() {
        // The reported sentence. Before the currency rule this rendered as one
        // `<math>` element holding a row of `<mi>` nodes, which read on
        // screen as "Coffee is 4.50vsa fancy latte at 7".
        let html = html_of("Coffee is $4.50 vs\na fancy latte at ~$7).\n");
        assert!(!html.contains("<math"), "{html}");
        assert!(html.contains("$4.50"), "{html}");
        assert!(html.contains("~$7)"), "{html}");
        assert!(html.contains("a fancy latte at"), "{html}");
    }

    #[test]
    fn rich_counters_separate_diagrams_from_code_blocks() {
        let source = "$x$ and $$y$$\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\n\
                      ```rust\nfn f() {}\n```\n\n```mermaid\nnot a diagram\n```\n";
        let out = render(&Document::parse(source), &RenderOptions::default());
        assert_eq!(out.math, 2);
        assert_eq!(out.diagrams, 1);
        assert_eq!(out.rich_failures, 0);
        // The rust fence and the mermaid fence that was not a diagram.
        assert_eq!(out.code_blocks, 2);
    }

    #[test]
    fn rich_failures_are_counted() {
        let out = render(
            &Document::parse("$\\newcommand{\\R}{x}$\n\n```mermaid\nflowchart TD\n  A[[[B\n```\n"),
            &RenderOptions::default(),
        );
        assert_eq!(out.rich_failures, 2);
    }

    #[test]
    fn headings_get_anchors() {
        let html = html_of("## Hello World\n");
        assert!(
            html.contains("<h2 id=\"hello-world\" class=\"mk-h\">Hello World</h2>"),
            "{html}"
        );
    }

    #[test]
    fn tables_still_go_through_pulldowns_writer() {
        let html = html_of("| a | b |\n|---|---|\n| 1 | 2 |\n");
        assert!(html.contains("<table>"), "{html}");
        assert!(html.contains("<th>a</th>"), "{html}");
    }

    #[test]
    fn prefix_rendering_emits_only_the_first_n_blocks() {
        let src = "a\n\nb\n\nc\n";
        let doc = Document::parse(src);
        let out = render(
            &doc,
            &RenderOptions {
                prefix_blocks: Some(2),
                ..RenderOptions::default()
            },
        );
        assert_eq!((out.blocks_emitted, out.blocks_total), (2, 3));
        assert!(out.html.contains(">a</p>"), "{}", out.html);
        assert!(!out.html.contains(">c</p>"), "{}", out.html);
    }

    #[test]
    fn prefix_then_tail_equals_a_full_render() {
        let src = "# H\n\n- [ ] t\n\n```rust\nfn f() {}\n```\n\npara\n";
        let doc = Document::parse(src);
        let whole = render(&doc, &RenderOptions::default()).html;
        let prefix = render_range(&doc, 0..2).html;
        let tail = render_range(&doc, 2..doc.blocks().len()).html;
        assert_eq!(whole, format!("{prefix}{tail}"));
    }

    #[test]
    fn render_range_clamps_instead_of_panicking() {
        let doc = Document::parse("a\n");
        assert_eq!(render_range(&doc, 5..9).html, "");
        assert_eq!(render_range(&doc, 0..99).blocks_emitted, 1);
    }

    #[test]
    fn standalone_is_self_contained() {
        let doc = Document::parse("# Title\n\ntext\n");
        let out = render(
            &doc,
            &RenderOptions {
                standalone: true,
                ..RenderOptions::default()
            },
        );
        assert!(out.html.starts_with("<!DOCTYPE html>"), "{}", out.html);
        assert!(out.html.contains("<title>Title</title>"), "{}", out.html);
        assert!(out.html.contains("<style>"), "{}", out.html);
        assert!(
            !out.html.contains("<script"),
            "no JS ships in rendered output"
        );
    }

    #[test]
    fn escaping_covers_text_and_attributes() {
        assert_eq!(escape_html("a<b&c>d"), "a&lt;b&amp;c&gt;d");
        assert_eq!(escape_attr("a\"b'c"), "a&quot;b&#39;c");
    }
}
