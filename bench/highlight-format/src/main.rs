//! Emit the same document **three** ways — slot classes, inline styles, and
//! syntect's scope classes — so `mark-bench` can measure all of them in a real
//! `WKWebView`.
//!
//! ADR-2 left this open: *"class-based highlighting (`ClassedHTMLGenerator`)
//! re-themes with zero re-render but emits 2.7x more HTML into the layout path
//! that is already our bottleneck. Inline styles are the opposite trade. We
//! will measure both during implementation rather than guess now; whichever
//! wins is an implementation detail under this ADR, not a new decision."*
//!
//! M2 measured two of the three and found `ClassedHTMLGenerator` **1.59x the
//! bytes and 1.51x the inject+layout time** of inline styles, so inline won and
//! free re-theming looked unaffordable. M7 found a third option and it beats
//! both: emit the **palette slot** as the class — `class="t0B"`, four
//! characters — rather than the whole scope stack. That is smaller than the
//! inline style it replaces *and* re-themes for free, which is why this crate
//! now emits three files instead of two.
//!
//! `mark-core` emits the slot variant. The other two are reconstructed here:
//! take the core's own rendered HTML, find each `<pre class="mk-code">` body,
//! and swap in the alternative rendering of the same `(language, code)`.
//! Everything outside the code blocks is byte-identical across all three, so
//! the measured difference is attributable to the highlighting markup and
//! nothing else.
//!
//!     cargo run --release -- ../corpus/1mb.md ../corpus/format
//!
//! writes `<out>.slot.html`, `<out>.slot.css`, `<out>.inline.html`,
//! `<out>.classed.html`, and `<out>.classed.css`.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use mark_core::parse::{Document, code_language};
use mark_core::render::{RenderOptions, render, token_css};
use mark_core::theme;
use pulldown_cmark::{Event, Tag};
use syntect::easy::HighlightLines;
use syntect::highlighting::ThemeSet;
use syntect::html::{
    ClassStyle, ClassedHTMLGenerator, IncludeBackground, css_for_theme_with_class_style,
    styled_line_to_highlighted_html,
};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

/// The syntect theme the inline and scope-class variants render with. All three
/// variants must produce the same colours or the comparison is meaningless, so
/// this is the *same palette* the core's default theme uses, synthesized from
/// it rather than a lookalike.
const THEME: &str = "base16-ocean.dark";

/// `ClassStyle::Spaced` is what a re-themable build would use: one class per
/// scope component, so a stylesheet swap re-colours without touching the DOM.
/// That is the whole benefit being weighed, so measuring the cheaper
/// `SpacedPrefixed` variant would stack the deck.
const CLASS_STYLE: ClassStyle = ClassStyle::Spaced;

fn main() -> ExitCode {
    let mut args = env::args_os().skip(1);
    let Some(input) = args.next() else {
        eprintln!("usage: mark-highlight-format <input.md> <output-prefix>");
        return ExitCode::from(1);
    };
    let Some(output) = args.next() else {
        eprintln!("usage: mark-highlight-format <input.md> <output-prefix>");
        return ExitCode::from(1);
    };
    let input = PathBuf::from(input);
    let output = PathBuf::from(output);

    let source = match fs::read_to_string(&input) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("{}: {error}", input.display());
            return ExitCode::from(2);
        }
    };

    let doc = Document::parse(&source);
    // What the core emits today: `<span class="t0B">`, the palette slot.
    let slot = render(&doc, &RenderOptions::default()).html;
    let codes = code_blocks(&doc);
    let syntaxes = SyntaxSet::load_defaults_newlines();

    // The core's own default palette, as a syntect theme, so the inline and
    // scope-class variants paint exactly the colours the slot variant resolves
    // to. `base16-ocean.dark` is kept only as a fallback for a build where the
    // default theme is unavailable.
    let synthesized = theme::default_pair().primary().syntect();
    let themes = ThemeSet::load_defaults();
    let fallback = &themes.themes[THEME];

    let inline = match substitute(&slot, &codes, |language, code| {
        inline_styled(language, code, &syntaxes, &synthesized)
    }) {
        Ok(html) => html,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(3);
        }
    };
    let classed = match substitute(&slot, &codes, |language, code| {
        classed(language, code, &syntaxes)
    }) {
        Ok(html) => html,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(3);
        }
    };

    let classed_css = css_for_theme_with_class_style(fallback, CLASS_STYLE)
        .expect("syntect can always emit CSS for a loaded theme");
    // The slot variant's stylesheet: sixteen rules, constant across every
    // theme, which is the other half of why it re-themes for nothing.
    let slot_css = format!("{}{}", theme::default_pair().css(), token_css());

    write(&output.with_extension("slot.html"), &slot);
    write(&output.with_extension("slot.css"), &slot_css);
    write(&output.with_extension("inline.html"), &inline);
    write(&output.with_extension("classed.html"), &classed);
    write(&output.with_extension("classed.css"), &classed_css);

    println!("blocks          {}", doc.blocks().len());
    println!("code blocks     {}", codes.len());
    println!("slot bytes      {}", slot.len());
    println!("inline bytes    {}", inline.len());
    println!("classed bytes   {}", classed.len());
    println!("slot css        {} bytes", slot_css.len());
    println!("classed css     {} bytes", classed_css.len());
    println!(
        "slot / inline   {:.2}x",
        slot.len() as f64 / inline.len() as f64
    );
    println!(
        "classed / inline {:.2}x",
        classed.len() as f64 / inline.len() as f64
    );
    ExitCode::SUCCESS
}

/// Every fenced/indented code block's `(language, code)`, in document order —
/// the same order they appear in the rendered HTML, which is what makes the
/// sequential substitution below sound.
fn code_blocks(doc: &Document<'_>) -> Vec<(Option<String>, String)> {
    let mut out = Vec::new();
    let mut current: Option<(Option<String>, String)> = None;

    for (event, _) in doc.events() {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                current = Some((code_language(kind).map(str::to_owned), String::new()));
            }
            Event::Text(text) | Event::Code(text) => {
                if let Some((_, code)) = current.as_mut() {
                    code.push_str(text);
                }
            }
            Event::End(pulldown_cmark::TagEnd::CodeBlock) => {
                if let Some(block) = current.take() {
                    out.push(block);
                }
            }
            _ => {}
        }
    }
    out
}

/// Replace each `<pre class="mk-code" …><code>…</code></pre>` body with an
/// alternative rendering of the same code.
fn substitute(
    html: &str,
    codes: &[(Option<String>, String)],
    mut render_one: impl FnMut(Option<&str>, &str) -> String,
) -> Result<String, String> {
    const OPEN: &str = "<pre class=\"mk-code\"";
    const BODY: &str = "><code>";
    const CLOSE: &str = "</code></pre>";

    let mut out = String::with_capacity(html.len() * 3);
    let mut rest = html;
    let mut index = 0usize;

    while let Some(at) = rest.find(OPEN) {
        let after_open = &rest[at..];
        let body_at = after_open
            .find(BODY)
            .ok_or_else(|| format!("code block {index}: no <code> after {OPEN}"))?;
        let body_start = at + body_at + BODY.len();
        let close_at = rest[body_start..]
            .find(CLOSE)
            .ok_or_else(|| format!("code block {index}: unterminated"))?;
        let body_end = body_start + close_at;

        let (language, code) = codes
            .get(index)
            .ok_or_else(|| format!("rendered HTML has more code blocks than the event stream"))?;

        out.push_str(&rest[..body_start]);
        out.push_str(&render_one(language.as_deref(), code));
        rest = &rest[body_end..];
        index += 1;
    }
    out.push_str(rest);

    if index != codes.len() {
        return Err(format!(
            "substituted {index} code blocks but the document has {}",
            codes.len()
        ));
    }
    Ok(out)
}

/// One code block, class-based.
///
/// Falls back to escaped plain text exactly as `core/src/highlight.rs` does, so
/// an unknown language produces the same bytes in both variants.
fn classed(language: Option<&str>, code: &str, syntaxes: &SyntaxSet) -> String {
    let Some(syntax) = language.and_then(|lang| syntaxes.find_syntax_by_token(lang)) else {
        return escape(code);
    };
    let mut generator = ClassedHTMLGenerator::new_with_class_style(syntax, syntaxes, CLASS_STYLE);
    for line in LinesWithEndings::from(code) {
        if generator.parse_html_for_line_which_includes_newline(line).is_err() {
            return escape(code);
        }
    }
    generator.finalize()
}

/// One code block, inline-styled — what the core emitted through M6.
fn inline_styled(
    language: Option<&str>,
    code: &str,
    syntaxes: &SyntaxSet,
    theme: &syntect::highlighting::Theme,
) -> String {
    let Some(syntax) = language.and_then(|lang| syntaxes.find_syntax_by_token(lang)) else {
        return escape(code);
    };
    let mut highlighter = HighlightLines::new(syntax, theme);
    let mut out = String::with_capacity(code.len() * 2);
    for line in LinesWithEndings::from(code) {
        let Ok(ranges) = highlighter.highlight_line(line, syntaxes) else {
            return escape(code);
        };
        match styled_line_to_highlighted_html(&ranges, IncludeBackground::No) {
            Ok(html) => out.push_str(&html),
            Err(_) => return escape(code),
        }
    }
    out
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn write(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    fs::write(path, contents).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
}
