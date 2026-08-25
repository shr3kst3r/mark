//! Math → MathML and Mermaid → SVG, rendered here in Rust.
//!
//! ADR-5 (`2026-08-24-rust-side-math-and-diagrams`) is the whole of this
//! module's brief, and five of its constraints are load-bearing:
//!
//! 1. **No JavaScript.** The WebView receives inline `<math>` and inline
//!    `<svg>` and nothing else — no KaTeX, no `mermaid.js`, no CDN. That is
//!    what lets `mark render --html` be genuinely self-contained and what
//!    keeps the CLI's capability identical to the GUI's.
//! 2. **Math failure is detected by looking for `<merror>` in the output, not
//!    just by checking the `Result`.** `pulldown-latex` returns `Ok` with an
//!    embedded `<merror>` node for input it cannot parse — `\newcommand` is
//!    the known case — so a naive success check reports a broken expression as
//!    working. This trap has already produced one false "13 ok, 0 failed".
//!    [`merror_message`] is the defence and [`math`] checks both.
//! 3. **Every `merman` call is wrapped in `catch_unwind`.** It is 0.8.0-alpha;
//!    no exceptions while it is pre-1.0.
//! 4. **On failure we emit our own styled badge** carrying the parser's
//!    message, with the raw source kept selectable next to it, and we suppress
//!    `pulldown-latex`'s own error markup — which is a bordered `<merror>`
//!    wrapping a multi-line context diagram, verbose enough to overflow the
//!    page width.
//! 5. **Both renderers are pure functions of their source** — a diagram also
//!    of the id it is asked to use — so their output can be memoized alongside
//!    highlighted code. The cache below is memoization and nothing else: drop
//!    it and not one byte of output changes.
//!
//! `RenderSvgError::NoDiagram` is deliberately *not* a failure: it means the
//! fence is not a diagram at all, and plan §3 says to render it as an ordinary
//! code block rather than as an error badge.
//!
//! # The white box on a dark page (M7)
//!
//! M6 shipped diagrams that were **unreadable on a dark theme**, found by
//! looking at a render rather than by a test. `merman` reproduces Mermaid's own
//! output faithfully, which means the SVG carries an inline `<style>` scoped by
//! `#id` holding Mermaid's stock light palette, plus
//! `style="background-color: white"` on the root element. Nothing in the page's
//! stylesheet can reach inside it, and `currentColor` is not involved anywhere.
//!
//! The fix is to hand `merman` the palette instead of trying to overrule it
//! afterwards: Mermaid's `theme: "base"` mode derives every colour it uses from
//! `themeVariables`, and `merman` implements that derivation in full. So a
//! diagram is rendered **once per appearance**, with
//! [`crate::theme::ThemePair::mermaid_config`] supplying the light and dark
//! variables, and both SVGs go into the page with `prefers-color-scheme`
//! choosing between them. An appearance switch stays free — no IPC, no
//! re-render, no re-layout of anything that was already visible — which is the
//! same bargain the chrome makes.
//!
//! The alternative considered and rejected was post-processing merman's style
//! block into `var()` references. Measured against the eight diagram families,
//! colours also appear in **presentation attributes** (`fill="#ECECFF"` on a
//! sequence diagram's actors, a pie chart's slices), and CSS custom properties
//! do not apply to those in WebKit — so a rewrite would have had to convert
//! attributes into inline styles as well, on markup a pre-1.0 library emits.
//! Two renders cost 0.23 ms each (ADR-5) and are memoized.
//!
//! When both halves of the pair are the same theme, the two renders are
//! byte-identical and only one is emitted.

use std::collections::{HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, OnceLock};

use pulldown_latex::config::{DisplayMode, MathStyle, RenderConfig};
use pulldown_latex::{Parser as LatexParser, Storage, push_mathml};

use crate::block::content_hash2;
use crate::highlight::CacheStats;
use crate::render::escape_html;
use crate::theme::{Kind, ThemePair};

/// Info string that marks a fenced block as a diagram. Compared
/// case-insensitively, the way `code_language` feeds syntect.
pub const MERMAID: &str = "mermaid";

/// Entries retained before the oldest is evicted.
///
/// Smaller than the highlight cache's 4096 because diagrams are 4–28 KB each
/// where a highlighted block is typically a few hundred bytes, and a document
/// with a thousand diagrams does not exist.
const CACHE_CAPACITY: usize = 1024;

/// Colour `pulldown-latex` draws its `<merror>` border in. We never emit that
/// markup, but the field is not optional, and a value that matches our badge
/// means a future reader diffing the two is not misled.
const ERROR_COLOR: (u8, u8, u8) = (0xbf, 0x61, 0x6a);

/// Whether an expression came from `$…$` or `$$…$$`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MathDisplay {
    /// `Event::InlineMath`. Sums and integrals are minimised to fit the line.
    Inline,
    /// `Event::DisplayMath`. Centred on its own line, `displaystyle` operators.
    Block,
}

impl MathDisplay {
    fn mode(self) -> DisplayMode {
        match self {
            MathDisplay::Inline => DisplayMode::Inline,
            MathDisplay::Block => DisplayMode::Block,
        }
    }

    fn tag(self) -> &'static str {
        match self {
            MathDisplay::Inline => "inline",
            MathDisplay::Block => "block",
        }
    }
}

/// What a rich renderer produced for one construct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    /// HTML ready to splice into the document: the `<math>` or `<svg>` on
    /// success, our badge on failure. Never empty, so a failed construct is
    /// never a silently blank region.
    pub html: String,
    /// The parser's message, when `html` is a badge.
    pub error: Option<String>,
    /// Whether this came from the memo cache.
    pub cached: bool,
}

impl Rendered {
    /// Whether this is a badge rather than rendered output.
    #[must_use]
    pub fn failed(&self) -> bool {
        self.error.is_some()
    }
}

/// The outcome of asking for a diagram.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Diagram {
    /// A Mermaid diagram: inline SVG, or a badge if it would not render.
    Rendered(Rendered),
    /// `RenderSvgError::NoDiagram` — the fence's contents are not a diagram.
    /// The caller renders it as an ordinary code block (plan §3), which is why
    /// this is a separate variant and not an error.
    NotADiagram,
}

/// Whether a fence's info string asks for a diagram.
#[must_use]
pub fn is_mermaid(language: Option<&str>) -> bool {
    language.is_some_and(|lang| lang.eq_ignore_ascii_case(MERMAID))
}

/// Render one `$…$` or `$$…$$` expression to inline MathML.
///
/// Never fails upward: an expression `pulldown-latex` cannot parse comes back
/// as a badge carrying the parser's message, with the LaTeX kept selectable.
#[must_use]
pub fn math(latex: &str, display: MathDisplay) -> Rendered {
    cache().math(latex, display)
}

/// Render one `mermaid` fence to inline SVG, in the theme's palette.
///
/// `block_id` is the enclosing block's `data-blk`. ADR-5 requires the SVG's id
/// to derive from it: `merman` scopes the diagram's own `<style>` rules by
/// `#id`, so two diagrams sharing an id would restyle each other, and a
/// positional id would move under ADR-2's incremental patching. A content
/// derived `data-blk` is unique within the document and stable across an edit
/// elsewhere in it. The dark half of a pair takes the same id with a `-d`
/// suffix, which keeps both of those properties.
#[must_use]
pub fn diagram(source: &str, block_id: &str, theme: &ThemePair) -> Diagram {
    cache().diagram(source, block_id, theme)
}

/// The SVG id for a block. Prefixed so it always starts with a letter, which
/// both HTML ids and `merman::svg::sanitize_svg_id` want.
#[must_use]
pub fn svg_id(block_id: &str) -> String {
    format!("mk-{block_id}")
}

/// The class that hides one appearance's copy of a diagram. Defined once here
/// so the stylesheet, the renderer, and the tests cannot drift.
pub const LIGHT_ONLY: &str = "mk-appear-light";
/// The dark counterpart of [`LIGHT_ONLY`].
pub const DARK_ONLY: &str = "mk-appear-dark";

/// Memo cache counters, surfaced by `mark stats --json` next to the
/// highlighter's.
#[must_use]
pub fn stats() -> CacheStats {
    cache().stats()
}

/// Drop every memoized entry. Only useful for benchmarking the cold path and
/// for asserting that the cache changes nothing but timing.
pub fn clear_cache() {
    cache().clear();
}

// --- the renderers ---------------------------------------------------------

/// LaTeX → MathML, or the parser's message.
fn render_math(latex: &str, display: MathDisplay) -> Result<String, String> {
    let config = RenderConfig {
        display_mode: display.mode(),
        // No `<annotation>`: it would carry a second copy of the source into
        // every expression for no consumer we have.
        annotation: None,
        error_color: ERROR_COLOR,
        // The namespace is unnecessary in WebKit and the terminal never sees
        // MathML, so it is bytes in the layout path for nothing.
        xml: false,
        math_style: MathStyle::TeX,
    };

    // `pulldown-latex` is not pre-1.0, so ADR-5 does not require this guard;
    // it costs nothing and makes "a rich renderer never takes the process
    // down" true of both renderers rather than only one.
    let mathml = guarded("pulldown-latex", || {
        let storage = Storage::new();
        let parser = LatexParser::new(latex, &storage);
        let mut mathml = String::new();
        // Writing into a `String` cannot fail in practice. ADR-5 says to check
        // the `Result` *as well as* the markup, and "cannot fail in practice"
        // is not the same as checked.
        push_mathml(&mut mathml, parser, config)
            .map(|()| mathml)
            .map_err(|error| format!("MathML writer failed: {error}"))
    })?;

    // **The trap.** `push_mathml` returned `Ok`; the failure is inside the
    // markup. Without this, `\newcommand` renders as a red-bordered box of
    // parser diagnostics and reports success.
    match merror_message(&mathml) {
        Some(message) => Err(message),
        None => Ok(mathml),
    }
}

/// Mermaid → SVG in the given palette. `Ok(None)` is `NoDiagram`: not a
/// diagram, not a failure.
///
/// `variables` is a JSON object of Mermaid `themeVariables`. It goes in as a
/// site config with `theme: "base"`, which is Mermaid's own "derive everything
/// from these colours" mode — the supported way to restyle a diagram, rather
/// than editing the SVG afterwards.
fn render_diagram(source: &str, id: &str, variables: &str) -> Result<Option<String>, String> {
    // ADR-5: **every** `merman` call is wrapped while it is pre-1.0.
    guarded("merman", || {
        let config = match serde_json::from_str::<serde_json::Value>(variables) {
            Ok(variables) => merman::MermaidConfig::from_value(serde_json::json!({
                "theme": "base",
                "themeVariables": variables,
            })),
            // A malformed variable set is our bug, not the user's; render in
            // merman's own palette rather than refusing to draw the diagram.
            Err(_) => merman::MermaidConfig::default(),
        };
        let rendered = merman::svg::HeadlessRenderer::new()
            .with_diagram_id(id)
            .with_site_config(config)
            .render_svg_sync(source);
        // The mapping `merman::render_svg_with_id` applies, restated because
        // its `finish_one_shot_svg` is private: "no diagram detected" is not a
        // failure, and must not become a badge (plan §3).
        match rendered {
            Ok(Some(svg)) => Ok(Some(neutral_background(&svg))),
            Ok(None) | Err(merman::svg::HeadlessError::Parse(merman::Error::DetectType(_))) => {
                Ok(None)
            }
            Err(error) => Err(merman::RenderSvgError::from(error).to_string()),
        }
    })
}

/// Drop the `background-color: white` `merman` writes onto the SVG root.
///
/// It is an **inline style**, so no rule in the page's stylesheet can override
/// it without `!important`, and it is not derived from `themeVariables` — it is
/// there unconditionally. Making it transparent lets the diagram sit on the
/// document's own background, which is what the rest of the page does.
fn neutral_background(svg: &str) -> String {
    svg.replacen(
        "background-color: white;",
        "background-color: transparent;",
        1,
    )
}

/// Run a renderer, turning a panic into a message the badge can carry.
///
/// ADR-5 mandates this around `merman` — "no exceptions while it is pre-1.0" —
/// and it is the reason the release profile keeps `panic = "unwind"`. Both
/// renderers go through it, so there is one place to look for the guarantee
/// rather than two call sites to keep in step, and one place to test it.
fn guarded<T>(who: &str, body: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(result) => result,
        Err(payload) => Err(format!("{who} panicked: {}", panic_text(&payload))),
    }
}

/// The message inside a `<merror>` node, if the MathML contains one.
///
/// This is ADR-5's mandated detection path. `pulldown-latex` writes
/// `<merror …><mtext>MESSAGE</mtext></merror>` when its parser yields an
/// `Err`, and returns `Ok` from `push_mathml` regardless — so this, and not
/// `Result::is_err`, is what tells us an expression failed.
///
/// A `<merror>` cannot arise from user text: the writer escapes `<` in
/// everything it copies from the source, so the only `<` in the output are
/// tags it wrote itself.
#[must_use]
fn merror_message(mathml: &str) -> Option<String> {
    const OPEN: &str = "<mtext>";
    const CLOSE: &str = "</mtext>";

    let after = &mathml[mathml.find("<merror")?..];
    let message = after
        .find(OPEN)
        .map(|at| &after[at + OPEN.len()..])
        .and_then(|text| text.find(CLOSE).map(|at| &text[..at]))
        .map_or_else(
            || "the expression could not be parsed".to_owned(),
            unescape_html,
        );

    // Only the first line. The rest is a box-drawn caret diagram pointing into
    // the source — genuinely useful in a terminal, and wider than the page in
    // a badge. The raw source sits next to the badge anyway.
    Some(
        message
            .lines()
            .next()
            .unwrap_or("the expression could not be parsed")
            .trim()
            .to_owned(),
    )
}

// --- badges ----------------------------------------------------------------

/// The badge for a failed expression.
///
/// An inline element, deliberately: `Event::DisplayMath` is an *inline* event
/// in `pulldown-cmark`, so both kinds of math can land inside a `<p>` and a
/// `<div>` here would be invalid HTML. `.mk-diagram-error` is the block one.
fn math_badge(message: &str, latex: &str, display: MathDisplay) -> String {
    format!(
        "<span class=\"mk-rich-error mk-math-error\" data-mk-display=\"{}\">\
         <span class=\"mk-rich-label\">math</span>\
         <code class=\"mk-rich-source\">{}</code>\
         <span class=\"mk-rich-message\">{}</span></span>",
        display.tag(),
        escape_html(latex),
        escape_html(message)
    )
}

/// The badge for a diagram that would not render.
fn diagram_badge(message: &str, source: &str) -> String {
    format!(
        "<div class=\"mk-rich-error mk-diagram-error\">\
         <span class=\"mk-rich-label\">mermaid</span>\
         <span class=\"mk-rich-message\">{}</span>\
         <pre class=\"mk-rich-source\"><code>{}</code></pre></div>",
        escape_html(message),
        escape_html(source)
    )
}

// --- helpers ---------------------------------------------------------------

/// Undo the three entities `pulldown-latex`'s writer produces. `&amp;` last,
/// or `&amp;lt;` would come back as `<`.
fn unescape_html(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

/// A panic payload as a message, matching the shape `lib.rs`'s ABI guard uses.
fn panic_text(payload: &Box<dyn std::any::Any + Send>) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "non-string panic payload".to_owned())
}

// --- the memo cache --------------------------------------------------------

static CACHE: OnceLock<Cache> = OnceLock::new();

fn cache() -> &'static Cache {
    CACHE.get_or_init(Cache::default)
}

#[derive(Clone, PartialEq, Eq)]
enum Entry {
    Ok(String),
    Failed { html: String, message: String },
    NotADiagram,
}

impl Entry {
    fn into_rendered(self, cached: bool) -> Rendered {
        match self {
            Entry::Ok(html) => Rendered {
                html,
                error: None,
                cached,
            },
            Entry::Failed { html, message } => Rendered {
                html,
                error: Some(message),
                cached,
            },
            // Only reachable for diagrams, and `diagram` peels that variant
            // off before calling this.
            Entry::NotADiagram => Rendered {
                html: String::new(),
                error: None,
                cached,
            },
        }
    }
}

#[derive(Default)]
struct Cache {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    entries: HashMap<u64, Entry>,
    order: VecDeque<u64>,
    hits: u64,
    misses: u64,
    evictions: u64,
}

impl Cache {
    /// [`math`], against this cache rather than the process-wide one.
    fn math(&self, latex: &str, display: MathDisplay) -> Rendered {
        let key = content_hash2(display.tag().as_bytes(), latex.as_bytes());
        let (entry, cached) = self.get_or_insert_entry(key, || match render_math(latex, display) {
            Ok(mathml) => Entry::Ok(mathml),
            Err(message) => Entry::Failed {
                html: math_badge(&message, latex, display),
                message,
            },
        });
        entry.into_rendered(cached)
    }

    /// [`diagram`], against this cache rather than the process-wide one.
    fn diagram(&self, source: &str, block_id: &str, theme: &ThemePair) -> Diagram {
        let id = svg_id(block_id);
        let light = theme.mermaid_config(Kind::Light);
        let dark = theme.mermaid_config(Kind::Dark);
        // The theme is part of the key, so the memo stays sound: ADR-5 requires
        // the renderer to be a pure function of its inputs, and the palette is
        // now one of them.
        let key = content_hash2(
            id.as_bytes(),
            format!("{light}\u{1e}{dark}\u{1e}{source}").as_bytes(),
        );
        let entry = self.get_or_insert_entry(key, || {
            let rendered = render_diagram(source, &id, &light).and_then(|light_svg| {
                match light_svg {
                    None => Ok(None),
                    Some(light_svg) if dark == light => Ok(Some(light_svg)),
                    Some(light_svg) => {
                        let dark_svg = render_diagram(source, &format!("{id}-d"), &dark)?;
                        Ok(Some(match dark_svg {
                            Some(dark_svg) => format!(
                                "<span class=\"{LIGHT_ONLY}\">{light_svg}</span>\
                                 <span class=\"{DARK_ONLY}\">{dark_svg}</span>"
                            ),
                            // The dark render disagreeing about whether this is
                            // a diagram is impossible — same source, same
                            // parser — but one legible appearance beats none.
                            None => light_svg,
                        }))
                    }
                }
            });
            match rendered {
                Ok(Some(html)) => Entry::Ok(format!("<div class=\"mk-diagram\">{html}</div>")),
                Ok(None) => Entry::NotADiagram,
                Err(message) => Entry::Failed {
                    html: diagram_badge(&message, source),
                    message,
                },
            }
        });
        match entry {
            (Entry::NotADiagram, _) => Diagram::NotADiagram,
            (entry, cached) => Diagram::Rendered(entry.into_rendered(cached)),
        }
    }

    /// Look `key` up, computing and storing it on a miss.
    ///
    /// `compute` runs outside the lock. Two threads racing on the same key
    /// therefore both render it and the second store is a no-op — wasteful but
    /// correct, because the renderers are pure. Holding the lock across a
    /// 0.34 ms diagram render would serialise every other cache user behind it.
    fn get_or_insert_entry(&self, key: u64, compute: impl FnOnce() -> Entry) -> (Entry, bool) {
        if let Some(entry) = self.lookup(key) {
            return (entry, true);
        }
        let entry = compute();
        self.store(key, entry.clone());
        (entry, false)
    }

    fn lookup(&self, key: u64) -> Option<Entry> {
        let mut inner = self.lock();
        match inner.entries.get(&key).cloned() {
            Some(entry) => {
                inner.hits += 1;
                Some(entry)
            }
            None => {
                inner.misses += 1;
                None
            }
        }
    }

    fn store(&self, key: u64, entry: Entry) {
        let mut inner = self.lock();
        if inner.entries.contains_key(&key) {
            return;
        }
        inner.entries.insert(key, entry);
        inner.order.push_back(key);
        while inner.order.len() > CACHE_CAPACITY {
            if let Some(oldest) = inner.order.pop_front() {
                inner.entries.remove(&oldest);
                inner.evictions += 1;
            }
        }
    }

    fn stats(&self) -> CacheStats {
        let inner = self.lock();
        CacheStats {
            hits: inner.hits,
            misses: inner.misses,
            entries: inner.entries.len(),
            evictions: inner.evictions,
        }
    }

    fn clear(&self) {
        let mut inner = self.lock();
        inner.entries.clear();
        inner.order.clear();
    }

    /// A poisoned cache mutex must not take the process down: the cache holds
    /// no invariant worth protecting, and the C ABI may not unwind (ADR-1).
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|poisoned| {
            self.inner.clear_poison();
            poisoned.into_inner()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The default theme pair, which every diagram test renders against
    /// unless it is specifically about a palette.
    fn pair() -> std::sync::Arc<ThemePair> {
        crate::theme::default_pair()
    }

    /// Run `body` with the panic hook silenced, so a deliberately panicking
    /// test does not scribble a backtrace over the test output. Same helper as
    /// `lib.rs` uses for the ABI guard.
    fn without_panic_noise<T>(body: impl FnOnce() -> T) -> T {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = body();
        std::panic::set_hook(previous);
        result
    }

    #[test]
    fn a_panicking_renderer_becomes_a_message_rather_than_a_crash() {
        // ADR-5 requires `catch_unwind` around merman because it is
        // 0.8.0-alpha. That the wrapper *exists* is visible in the source; that
        // it *works* is only knowable by panicking through it. A release
        // profile switched to `panic = "abort"` would fail here rather than in
        // a user's crash log.
        let caught: Result<(), String> =
            without_panic_noise(|| guarded("merman", || panic!("boom")));
        assert_eq!(caught.unwrap_err(), "merman panicked: boom");

        let owned: Result<(), String> = without_panic_noise(|| {
            guarded("pulldown-latex", || panic!("{}", "formatted".to_owned()))
        });
        assert_eq!(owned.unwrap_err(), "pulldown-latex panicked: formatted");

        let odd: Result<(), String> =
            without_panic_noise(|| guarded("merman", || std::panic::panic_any(42u32)));
        assert_eq!(
            odd.unwrap_err(),
            "merman panicked: non-string panic payload"
        );

        // And a body that simply fails is passed through untouched.
        let plain: Result<(), String> = guarded("merman", || Err("ordinary failure".to_owned()));
        assert_eq!(plain.unwrap_err(), "ordinary failure");
    }

    #[test]
    fn inline_math_becomes_mathml() {
        let out = math("x^2", MathDisplay::Inline);
        assert!(!out.failed(), "{out:?}");
        assert!(out.html.starts_with("<math display=\"inline\""), "{out:?}");
        assert!(out.html.contains("<msup>"), "{out:?}");
    }

    #[test]
    fn display_math_asks_for_block_layout() {
        let out = math("\\int_0^1 x\\,dx", MathDisplay::Block);
        assert!(!out.failed(), "{out:?}");
        assert!(out.html.contains("display=\"block\""), "{out:?}");
    }

    #[test]
    fn the_two_display_modes_do_not_share_a_cache_entry() {
        let inline = math("x", MathDisplay::Inline);
        let block = math("x", MathDisplay::Block);
        assert_ne!(inline.html, block.html);
    }

    #[test]
    fn newcommand_is_caught_by_merror_not_by_the_result() {
        // ADR-5's trap, asserted from both ends.
        let latex = "\\newcommand{\\R}{\\mathbb{R}} \\R";

        // 1. `push_mathml` reports success. If this ever starts failing, the
        //    detection below has become belt-and-braces rather than the only
        //    thing standing between us and a false pass — worth knowing.
        let storage = Storage::new();
        let mut raw = String::new();
        let result = push_mathml(
            &mut raw,
            LatexParser::new(latex, &storage),
            RenderConfig::default(),
        );
        assert!(
            result.is_ok(),
            "the premise of the merror check changed: push_mathml now returns Err"
        );
        assert!(raw.contains("<merror"), "{raw}");

        // 2. And we still report it as a failure, because we look at the markup.
        let out = math(latex, MathDisplay::Inline);
        assert!(out.failed(), "\\newcommand reported as rendered: {out:?}");
        assert_eq!(
            out.error.as_deref(),
            Some("parsing error: expected an argument")
        );
    }

    #[test]
    fn a_badge_suppresses_pulldown_latexs_own_error_markup() {
        let out = math("\\newcommand{\\R}{\\mathbb{R}}", MathDisplay::Inline);
        assert!(out.failed());
        assert!(!out.html.contains("<merror"), "{}", out.html);
        assert!(!out.html.contains("<math"), "{}", out.html);
        // The context diagram is what overflows the page; only its first line
        // survives, and the box-drawing never does.
        assert!(!out.html.contains('╭'), "{}", out.html);
        assert_eq!(out.html.lines().count(), 1, "{}", out.html);
    }

    #[test]
    fn a_badge_keeps_the_raw_source_and_the_message() {
        let out = math("\\frac{", MathDisplay::Inline);
        assert!(out.failed());
        assert!(out.html.contains("mk-rich-error"), "{}", out.html);
        assert!(
            out.html
                .contains("<code class=\"mk-rich-source\">\\frac{</code>"),
            "{}",
            out.html
        );
        assert!(
            out.html.contains("unbalanced group"),
            "the parser's message is missing: {}",
            out.html
        );
    }

    #[test]
    fn a_badge_escapes_its_source_and_message() {
        let out = math("\\text{<script>} & x", MathDisplay::Inline);
        assert!(!out.html.contains("<script>"), "{}", out.html);
        assert!(out.html.contains("&lt;script&gt;"), "{}", out.html);
    }

    #[test]
    fn merror_detection_reads_the_message_out_of_the_node() {
        assert_eq!(merror_message("<math><mi>x</mi></math>"), None);
        assert_eq!(
            merror_message("<math><merror style=\"x\"><mtext>boom</mtext></merror></math>")
                .as_deref(),
            Some("boom")
        );
        // Entities the writer produced come back as themselves.
        assert_eq!(
            merror_message("<merror><mtext>a &lt;b&gt; &amp; c</mtext></merror>").as_deref(),
            Some("a <b> & c")
        );
        // A `<merror>` with no `<mtext>` still counts as a failure.
        assert_eq!(
            merror_message("<merror></merror>").as_deref(),
            Some("the expression could not be parsed")
        );
    }

    #[test]
    fn a_flowchart_becomes_inline_svg() {
        let Diagram::Rendered(out) =
            diagram("flowchart TD\n  A[Start] --> B[Done]\n", "aa-0", &pair())
        else {
            panic!("a flowchart is a diagram");
        };
        assert!(!out.failed(), "{:?}", out.error);
        assert!(out.html.contains("<svg id=\"mk-aa-0\""), "{}", out.html);
        assert!(out.html.starts_with("<div class=\"mk-diagram\">"));
    }

    #[test]
    fn a_diagrams_svg_is_self_contained() {
        // ADR-5: `mark render --html` must need no network. The only URLs in
        // the output are XML namespaces, which are identifiers rather than
        // fetches.
        let Diagram::Rendered(out) = diagram("sequenceDiagram\n  A->>B: hi\n", "bb-0", &pair())
        else {
            panic!("a sequence diagram is a diagram");
        };
        for forbidden in ["<script", "<image", "xlink:href", "url(http", "@import"] {
            assert!(
                !out.html.contains(forbidden),
                "SVG references {forbidden}: {}",
                out.html
            );
        }
        for url in out.html.split("http").skip(1) {
            assert!(
                url.starts_with("://www.w3.org/"),
                "SVG references a non-namespace URL: http{}",
                &url[..url.len().min(60)]
            );
        }
    }

    #[test]
    fn prose_in_a_mermaid_fence_is_not_a_diagram() {
        // `NoDiagram` means "not a diagram", so the caller falls back to an
        // ordinary code block instead of showing a badge (plan §3).
        assert_eq!(
            diagram("fn main() {}\n", "cc-0", &pair()),
            Diagram::NotADiagram
        );
        assert_eq!(diagram("", "dd-0", &pair()), Diagram::NotADiagram);
    }

    #[test]
    fn a_malformed_diagram_becomes_a_badge_with_the_parser_message() {
        let Diagram::Rendered(out) = diagram("flowchart TD\n  A[[[Start --> B\n", "ee-0", &pair())
        else {
            panic!("a broken flowchart is still a diagram");
        };
        assert!(out.failed(), "{}", out.html);
        assert!(out.html.contains("mk-diagram-error"), "{}", out.html);
        assert!(
            out.error
                .as_deref()
                .is_some_and(|m| m.contains("parse error")),
            "{:?}",
            out.error
        );
        // The source stays selectable next to the message.
        assert!(out.html.contains("A[[[Start --&gt; B"), "{}", out.html);
    }

    #[test]
    fn diagram_ids_derive_from_the_block_id_and_survive_sanitising() {
        // ADR-5 requires the id to come from `data-blk`. merman normalises
        // whatever it is given, so ids that are distinct for us must stay
        // distinct for it: a `data-blk` is `<16 hex>-<ordinal>`, and the
        // `mk-` prefix makes it start with a letter, so normalisation is the
        // identity here rather than something we hope is injective.
        for block_id in [
            "0123456789abcdef-0",
            "0123456789abcdef-1",
            "ffffffffffffffff-27",
        ] {
            let id = svg_id(block_id);
            assert_eq!(merman::svg::sanitize_svg_id(&id), id, "{id} was rewritten");
        }
    }

    #[test]
    fn the_same_diagram_in_two_blocks_gets_two_ids() {
        let source = "flowchart TD\n  A --> B\n";
        let Diagram::Rendered(first) = diagram(source, "aaaa-0", &pair()) else {
            panic!()
        };
        let Diagram::Rendered(second) = diagram(source, "aaaa-1", &pair()) else {
            panic!()
        };
        assert!(first.html.contains("id=\"mk-aaaa-0\""));
        assert!(second.html.contains("id=\"mk-aaaa-1\""));
        assert_ne!(first.html, second.html);
    }

    #[test]
    fn renderers_are_pure_functions_of_their_source() {
        // ADR-5's memoization precondition, and the one property the cache is
        // only sound *because of*. A fresh cache per call is what makes this a
        // purity test rather than a cache test.
        let cases: [(&str, &str); 3] = [
            ("flowchart TD\n  A[One] --> B[Two]\n", "pure-0"),
            ("pie title X\n  \"a\" : 10\n  \"b\" : 20\n", "pure-1"),
            (
                "gantt\n  title G\n  section S\n  a :a1, 2014-01-01, 30d\n",
                "pure-2",
            ),
        ];
        for (source, id) in cases {
            let Diagram::Rendered(first) = Cache::default().diagram(source, id, &pair()) else {
                panic!("{source} should be a diagram");
            };
            let Diagram::Rendered(second) = Cache::default().diagram(source, id, &pair()) else {
                panic!()
            };
            assert!(!first.cached && !second.cached, "not a cold render");
            assert_eq!(first.html, second.html, "{source} is not deterministic");
        }

        for latex in ["x^2", "\\frac{a}{b}", "\\newcommand{\\R}{x}"] {
            let first = Cache::default().math(latex, MathDisplay::Inline);
            let second = Cache::default().math(latex, MathDisplay::Inline);
            assert_eq!(first.html, second.html, "{latex} is not deterministic");
        }
    }

    #[test]
    fn the_cache_returns_the_same_bytes_it_computed() {
        let cache = Cache::default();
        let cold = cache.math("\\sqrt{x+1}", MathDisplay::Inline);
        let warm = cache.math("\\sqrt{x+1}", MathDisplay::Inline);
        assert!(!cold.cached && warm.cached, "{cold:?} {warm:?}");
        assert_eq!(cold.html, warm.html);

        let source = "flowchart LR\n  A --> B\n";
        let Diagram::Rendered(cold) = cache.diagram(source, "warm-0", &pair()) else {
            panic!()
        };
        let Diagram::Rendered(warm) = cache.diagram(source, "warm-0", &pair()) else {
            panic!()
        };
        assert!(!cold.cached && warm.cached);
        assert_eq!(cold.html, warm.html);
    }

    #[test]
    fn a_not_a_diagram_verdict_is_memoized_too() {
        // Otherwise every re-render pays merman's detection pass for every
        // fence that is not a diagram.
        let cache = Cache::default();
        assert_eq!(
            cache.diagram("just prose\n", "nd-0", &pair()),
            Diagram::NotADiagram
        );
        assert_eq!(
            cache.diagram("just prose\n", "nd-0", &pair()),
            Diagram::NotADiagram
        );
        assert_eq!(cache.stats().hits, 1, "the second call re-rendered");
    }

    #[test]
    fn eviction_is_bounded() {
        let cache = Cache::default();
        for i in 0..CACHE_CAPACITY + 5 {
            cache.math(&format!("x_{{{i}}}"), MathDisplay::Inline);
        }
        let stats = cache.stats();
        assert_eq!(stats.entries, CACHE_CAPACITY);
        assert_eq!(stats.evictions, 5);
    }

    #[test]
    fn clearing_the_cache_changes_nothing_but_timing() {
        let cache = Cache::default();
        let before = cache.math("\\sum_{i=0}^n i", MathDisplay::Block).html;
        cache.clear();
        let after = cache.math("\\sum_{i=0}^n i", MathDisplay::Block);
        assert!(!after.cached, "cache was not actually cleared");
        assert_eq!(before, after.html);
    }

    #[test]
    fn a_mermaid_info_string_is_recognised_case_insensitively() {
        assert!(is_mermaid(Some("mermaid")));
        assert!(is_mermaid(Some("Mermaid")));
        assert!(!is_mermaid(Some("rust")));
        assert!(!is_mermaid(Some("mermaidish")));
        assert!(!is_mermaid(None));
    }
}
