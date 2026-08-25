//! `syntect` wrapped in a memo cache keyed on `(format, theme, language, code-hash)`.
//!
//! ADR-2 makes two binding demands of this module:
//!
//! * Highlighted output is cached by content hash, so highlighting must stay a
//!   **pure function** of `(language, code, theme)` — no ambient state. The
//!   cache below is therefore memoization and nothing else: it can be dropped
//!   entirely without changing a single byte of output.
//! * The cache is what turns 98.15 ms into 0.074 ms on the re-render path
//!   (research 2.10), so it needs an eviction policy rather than unbounded
//!   growth.
//!
//! # Slot classes, not inline colours
//!
//! HTML output is `<span class="t0B">`, naming the **palette slot** rather than
//! a colour, with the colour supplied by a CSS custom property that carries
//! both appearances (see [`crate::theme`]). So an appearance switch re-colours
//! code with no re-highlight, no re-render, and no DOM work — the same
//! mechanism the chrome uses.
//!
//! This is the question ADR-2 deferred and M2 measured. syntect's own
//! `ClassedHTMLGenerator` emits the whole scope stack per span and measured
//! **1.59× the bytes and 1.51× the inject+layout time** of inline styles, which
//! is why plan §2 M7's "syntect emits `class="tok-*"`" is not what shipped. A
//! slot class is four characters, so it is *smaller* than the inline style it
//! replaces — runs of the same slot are coalesced, and the default slot emits
//! no span at all — and it still re-themes for free.
//!
//! The theme is therefore in the cache key twice over: as
//! [`ThemePair::code_stamp`] for HTML, where only the scope → slot map can
//! change the bytes, and as [`ThemePair::color_stamp`] for ANSI, where a
//! terminal gets no chance to defer a colour.
//!
//! Highlighting never fails upward: an unknown language, or a syntect error,
//! falls back to escaped plain text (plan §3). Rendering a document must not be
//! blocked by a code block we cannot colour.

use std::collections::HashMap;
use std::collections::VecDeque;
use std::fmt::Write as _;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use syntect::easy::HighlightLines;
use syntect::highlighting::Theme as SyntectTheme;
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

use crate::block::content_hash2;
use crate::render::escape_html;
use crate::theme::{self, Rgb, Slot, ThemePair};

/// Entries retained before the oldest is evicted. A 1 MB document has ~400 code
/// blocks (research 2.10), so this holds roughly ten documents' worth.
const CACHE_CAPACITY: usize = 4096;

static SHARED: OnceLock<Highlighter> = OnceLock::new();

/// The process-wide highlighter. Assets load once, lazily, on first use.
pub fn shared() -> &'static Highlighter {
    SHARED.get_or_init(Highlighter::new)
}

/// Which markup the highlighter emits.
///
/// Both formats are pure functions of `(language, code, theme)` and share one
/// cache, discriminated by this tag — so `mark render --html` and
/// `mark render --ansi` can never serve each other's bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    /// `<span class="t0B">` runs, for the WebView and `--html`.
    Html,
    /// 24-bit SGR sequences, for `--ansi`.
    Ansi,
}

impl Format {
    fn tag(self) -> &'static str {
        match self {
            Format::Html => "html",
            Format::Ansi => "ansi",
        }
    }
}

/// Result of one highlight request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Highlighted {
    /// Inner HTML for a `<pre><code>` — spans only, no wrapper element.
    pub html: String,
    /// The syntax syntect actually used, or `None` when we fell back to plain
    /// text. Rendered into `data-lang` so a reader can tell the difference.
    pub syntax: Option<String>,
    /// Whether this came from the memo cache.
    pub cached: bool,
}

/// Cache counters, surfaced by `mark stats --json`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize)]
pub struct CacheStats {
    pub hits: u64,
    pub misses: u64,
    pub entries: usize,
    pub evictions: u64,
}

struct Cache {
    entries: HashMap<u64, (String, Option<String>)>,
    order: VecDeque<u64>,
    hits: u64,
    misses: u64,
    evictions: u64,
}

/// A theme compiled to the two things highlighting needs: syntect's own
/// matcher, and the slot each match stands for.
///
/// Built once per distinct theme and cached, because
/// `Highlighter::new` walks every selector in the theme.
struct Compiled {
    /// The probe theme: same selectors, sentinel colours encoding slot indices.
    probe: SyntectTheme,
    /// Slot → colour, for ANSI.
    colors: [Option<Rgb>; 24],
    /// The slot unmatched text takes, emitted as no span at all.
    default_slot: Slot,
}

pub struct Highlighter {
    syntaxes: SyntaxSet,
    asset_load: Duration,
    cache: Mutex<Cache>,
    compiled: Mutex<HashMap<u64, std::sync::Arc<Compiled>>>,
}

impl Highlighter {
    /// A highlighter with its own empty cache.
    ///
    /// [`shared`] is what production uses; this exists so a test can assert
    /// hit/miss behaviour without another test's cache entries in the way.
    #[must_use]
    pub fn new() -> Highlighter {
        let started = Instant::now();
        let syntaxes = SyntaxSet::load_defaults_newlines();
        let asset_load = started.elapsed();

        Highlighter {
            syntaxes,
            asset_load,
            cache: Mutex::new(Cache {
                entries: HashMap::new(),
                order: VecDeque::new(),
                hits: 0,
                misses: 0,
                evictions: 0,
            }),
            compiled: Mutex::new(HashMap::new()),
        }
    }

    /// Time spent loading syntect assets, reported by `mark doctor`. Research
    /// 2.10 measured 0.33-1.4 ms and concluded no lazy loading is needed; this
    /// is here so that claim stays checkable on someone else's machine.
    #[must_use]
    pub fn asset_load(&self) -> Duration {
        self.asset_load
    }

    #[must_use]
    pub fn stats(&self) -> CacheStats {
        let cache = self.lock();
        CacheStats {
            hits: cache.hits,
            misses: cache.misses,
            entries: cache.entries.len(),
            evictions: cache.evictions,
        }
    }

    /// Drop every memoized entry. Only useful for benchmarking the cold path.
    pub fn clear_cache(&self) {
        let mut cache = self.lock();
        cache.entries.clear();
        cache.order.clear();
    }

    /// Highlight one code block as HTML. Never fails: an unknown language or a
    /// syntect error yields escaped plain text.
    pub fn highlight(&self, language: Option<&str>, code: &str, theme: &ThemePair) -> Highlighted {
        self.highlight_as(Format::Html, language, code, theme)
    }

    /// Highlight one code block as 24-bit terminal escapes.
    pub fn highlight_ansi(
        &self,
        language: Option<&str>,
        code: &str,
        theme: &ThemePair,
    ) -> Highlighted {
        self.highlight_as(Format::Ansi, language, code, theme)
    }

    /// Highlight in a given format, going through the memo cache.
    pub fn highlight_as(
        &self,
        format: Format,
        language: Option<&str>,
        code: &str,
        theme: &ThemePair,
    ) -> Highlighted {
        let key = cache_key(format, theme, language, code);

        if let Some((html, syntax)) = self.lookup(key) {
            return Highlighted {
                html,
                syntax,
                cached: true,
            };
        }

        let (html, syntax) = self.compute(format, language, code, theme);
        self.store(key, &html, syntax.as_deref());
        Highlighted {
            html,
            syntax,
            cached: false,
        }
    }

    /// The uncached path, exposed so tests can assert the cache changes nothing
    /// but timing.
    #[must_use]
    pub fn highlight_uncached(
        &self,
        format: Format,
        language: Option<&str>,
        code: &str,
        theme: &ThemePair,
    ) -> Highlighted {
        let (html, syntax) = self.compute(format, language, code, theme);
        Highlighted {
            html,
            syntax,
            cached: false,
        }
    }

    /// The compiled form of `theme`, built once per distinct scope map.
    fn compiled(&self, theme: &ThemePair) -> std::sync::Arc<Compiled> {
        // Keyed on both stamps: the probe theme depends on the scope map, the
        // colours on the palette.
        let key = content_hash2(
            &theme.code_stamp().to_le_bytes(),
            &theme.color_stamp().to_le_bytes(),
        );
        let mut compiled = self.compiled.lock().unwrap_or_else(|poisoned| {
            self.compiled.clear_poison();
            poisoned.into_inner()
        });
        if let Some(found) = compiled.get(&key) {
            return std::sync::Arc::clone(found);
        }
        let primary = theme.primary();
        let built = std::sync::Arc::new(Compiled {
            probe: primary.slot_probe(),
            colors: *primary.palette(),
            default_slot: primary.default_code_slot(),
        });
        compiled.insert(key, std::sync::Arc::clone(&built));
        built
    }

    fn compute(
        &self,
        format: Format,
        language: Option<&str>,
        code: &str,
        theme: &ThemePair,
    ) -> (String, Option<String>) {
        let fallback = || match format {
            Format::Html => escape_html(code),
            Format::Ansi => code.to_owned(),
        };

        let Some(syntax) = language.and_then(|lang| self.syntaxes.find_syntax_by_token(lang))
        else {
            return (fallback(), None);
        };

        let compiled = self.compiled(theme);
        let mut highlighter = HighlightLines::new(syntax, &compiled.probe);
        let mut out = String::with_capacity(code.len() * 2);
        // The slot the current run is in. Runs are coalesced across lines,
        // which is most of the byte saving: syntect emits a separate range per
        // token even when consecutive tokens share a slot.
        let mut current: Option<Slot> = None;
        let mut span_open = false;

        for line in LinesWithEndings::from(code) {
            let Ok(ranges) = highlighter.highlight_line(line, &self.syntaxes) else {
                // Partial output plus an escaped remainder would be worse than
                // a clean fallback, so discard and start over as plain text.
                return (fallback(), None);
            };
            for (style, text) in ranges {
                if text.is_empty() {
                    continue;
                }
                let slot = theme::slot_of(style.foreground).unwrap_or(compiled.default_slot);
                if current != Some(slot) {
                    if span_open {
                        out.push_str("</span>");
                        span_open = false;
                    }
                    current = Some(slot);
                    match format {
                        Format::Html => {
                            // The default slot emits no span at all: the
                            // `<pre>` already carries that colour, and this is
                            // worth roughly a fifth of the output.
                            if slot != compiled.default_slot {
                                let _ = write!(out, "<span class=\"t{}\">", slot.suffix());
                                span_open = true;
                            }
                        }
                        Format::Ansi => {
                            if let Some(color) = compiled.colors[slot.index()] {
                                let _ =
                                    write!(out, "\x1b[38;2;{};{};{}m", color.r, color.g, color.b);
                            }
                        }
                    }
                }
                match format {
                    Format::Html => out.push_str(&escape_html(text)),
                    Format::Ansi => out.push_str(text),
                }
            }
        }
        if span_open {
            out.push_str("</span>");
        }
        if format == Format::Ansi {
            // syntect leaves the terminal in the last span's colour.
            out.push_str("\x1b[0m");
        }
        (out, Some(syntax.name.clone()))
    }

    fn lookup(&self, key: u64) -> Option<(String, Option<String>)> {
        let mut cache = self.lock();
        match cache.entries.get(&key) {
            Some((html, syntax)) => {
                let hit = (html.clone(), syntax.clone());
                cache.hits += 1;
                Some(hit)
            }
            None => {
                cache.misses += 1;
                None
            }
        }
    }

    fn store(&self, key: u64, html: &str, syntax: Option<&str>) {
        let mut cache = self.lock();
        if cache.entries.contains_key(&key) {
            return;
        }
        cache
            .entries
            .insert(key, (html.to_owned(), syntax.map(str::to_owned)));
        cache.order.push_back(key);
        while cache.order.len() > CACHE_CAPACITY {
            if let Some(oldest) = cache.order.pop_front() {
                cache.entries.remove(&oldest);
                cache.evictions += 1;
            }
        }
    }

    /// A poisoned cache mutex must not take the process down: the cache holds
    /// no invariant worth protecting, and the C ABI may not unwind (ADR-1).
    fn lock(&self) -> std::sync::MutexGuard<'_, Cache> {
        self.cache.lock().unwrap_or_else(|poisoned| {
            self.cache.clear_poison();
            poisoned.into_inner()
        })
    }
}

impl Default for Highlighter {
    fn default() -> Self {
        Highlighter::new()
    }
}

fn cache_key(format: Format, theme: &ThemePair, language: Option<&str>, code: &str) -> u64 {
    // HTML depends only on the scope → slot map, so two themes that share one
    // — every theme this ships — share cache entries and a theme switch
    // re-highlights nothing. ANSI has no CSS to defer to, so it keys on the
    // colours themselves.
    let stamp = match format {
        Format::Html => theme.code_stamp(),
        Format::Ansi => theme.color_stamp(),
    };
    let mut prefix = String::with_capacity(32);
    prefix.push_str(format.tag());
    prefix.push('\u{1f}');
    let _ = write!(prefix, "{stamp:016x}");
    prefix.push('\u{1f}');
    prefix.push_str(language.unwrap_or(""));
    content_hash2(prefix.as_bytes(), code.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn theme() -> std::sync::Arc<ThemePair> {
        theme::default_pair()
    }

    #[test]
    fn unknown_language_falls_back_to_escaped_plain_text() {
        let out = shared().highlight(Some("no-such-language"), "a < b & c\n", &theme());
        assert_eq!(out.syntax, None);
        assert_eq!(out.html, "a &lt; b &amp; c\n");
    }

    #[test]
    fn missing_language_falls_back_to_escaped_plain_text() {
        let out = shared().highlight(None, "<script>\n", &theme());
        assert_eq!(out.syntax, None);
        assert_eq!(out.html, "&lt;script&gt;\n");
    }

    #[test]
    fn known_language_produces_slot_classes_and_no_inline_colours() {
        let out = shared().highlight(Some("rust"), "fn main() {}\n", &theme());
        assert_eq!(out.syntax.as_deref(), Some("Rust"));
        assert!(out.html.contains("<span class=\"t"), "{}", out.html);
        assert!(
            !out.html.contains("style="),
            "an inline colour survived: {}",
            out.html
        );
        assert_eq!(
            out.html.matches("<span").count(),
            out.html.matches("</span>").count(),
            "unbalanced spans: {}",
            out.html
        );
    }

    #[test]
    fn every_class_names_a_slot_the_theme_defines() {
        let out = shared().highlight(
            Some("rust"),
            "// a comment\nfn f(x: u32) -> String { \"s\".into() }\n",
            &theme(),
        );
        let theme = theme();
        let mut seen = 0;
        for (at, _) in out.html.match_indices("<span class=\"t") {
            let rest = &out.html[at + "<span class=\"t".len()..];
            let name = &rest[..rest.find('"').expect("a closed attribute")];
            let slot = Slot::parse(&format!("base{name}"))
                .unwrap_or_else(|| panic!("class t{name} is not a slot"));
            assert!(
                theme.primary().color(slot).is_some(),
                "class t{name} names an undefined slot"
            );
            seen += 1;
        }
        assert!(seen >= 3, "expected several coloured runs: {}", out.html);
    }

    #[test]
    fn default_coloured_text_carries_no_span_at_all() {
        // The byte saving that makes slot classes smaller than inline styles:
        // punctuation and whitespace take the code block's own colour, so they
        // are emitted bare rather than wrapped in a span that says so.
        let out = shared().highlight(Some("rust"), "fn f() {}\n", &theme());
        assert!(out.html.contains("() {}"), "{}", out.html);
        assert!(
            !out.html.contains("<span class=\"t05\">"),
            "the default slot emitted a span: {}",
            out.html
        );
    }

    #[test]
    fn runs_of_one_slot_are_coalesced() {
        // Two adjacent keywords are one span, not two.
        let out =
            shared().highlight_uncached(Format::Html, Some("rust"), "pub fn f() {}\n", &theme());
        let keywords = out.html.matches("<span class=\"t0E\">").count();
        assert_eq!(keywords, 1, "`pub fn` should be one run: {}", out.html);
    }

    #[test]
    fn the_same_code_under_two_themes_with_one_map_is_byte_identical() {
        // The property that makes a theme switch free.
        let code = "fn main() { let x = 1; }\n";
        let dark = theme::resolve("dracula").unwrap();
        let light = theme::resolve("github").unwrap();
        let a = shared().highlight_uncached(Format::Html, Some("rust"), code, &dark);
        let b = shared().highlight_uncached(Format::Html, Some("rust"), code, &light);
        assert_eq!(a.html, b.html);
        // And they share a cache entry, so switching re-highlights nothing.
        assert_eq!(
            cache_key(Format::Html, &dark, Some("rust"), code),
            cache_key(Format::Html, &light, Some("rust"), code)
        );
    }

    #[test]
    fn ansi_output_uses_the_selected_theme_s_colours() {
        let dracula = theme::resolve("dracula").unwrap();
        let out = shared().highlight_ansi(Some("rust"), "fn main() {}\n", &dracula);
        assert_eq!(out.syntax.as_deref(), Some("Rust"));
        assert!(out.html.contains('\x1b'), "expected SGR escapes");
        assert!(out.html.ends_with("\x1b[0m"));
        // `fn` is `storage.type` in syntect's Rust syntax, which the base16
        // map puts in base0A — dracula's #f1fa8c.
        assert!(
            out.html.contains("\x1b[38;2;241;250;140m"),
            "{:?}",
            out.html
        );
        // And a different palette gives different escapes for the same code.
        let other = shared().highlight_ansi(Some("rust"), "fn main() {}\n", &theme());
        assert_ne!(out.html, other.html);
    }

    #[test]
    fn ansi_fallback_is_the_code_verbatim_not_html_escaped() {
        let out = shared().highlight_ansi(Some("nosuchlang"), "a < b\n", &theme());
        assert_eq!(out.syntax, None);
        assert_eq!(out.html, "a < b\n");
    }

    #[test]
    fn cache_key_separates_language_from_code() {
        assert_ne!(
            cache_key(Format::Html, &theme(), Some("rs"), "x"),
            cache_key(Format::Html, &theme(), Some("r"), "sx")
        );
    }

    #[test]
    fn cache_key_separates_the_two_output_formats() {
        assert_ne!(
            cache_key(Format::Html, &theme(), Some("rust"), "fn f() {}"),
            cache_key(Format::Ansi, &theme(), Some("rust"), "fn f() {}")
        );
    }

    #[test]
    fn eviction_is_bounded() {
        let highlighter = Highlighter::new();
        for i in 0..CACHE_CAPACITY + 10 {
            highlighter.highlight(Some("rust"), &format!("fn f{i}() {{}}\n"), &theme());
        }
        let stats = highlighter.stats();
        assert_eq!(stats.entries, CACHE_CAPACITY);
        assert_eq!(stats.evictions, 10);
    }
}
