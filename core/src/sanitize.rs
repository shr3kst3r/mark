//! What happens to the HTML a markdown document embeds.
//!
//! Markdown lets a document contain raw HTML, and `pulldown-cmark` passes it
//! through untouched. For a *viewer* that is a hole rather than a feature: a
//! `.md` file is something you clone, download, or are sent, and until this
//! module existed a `<script>` in one ran in the shell page — where it could
//! reach `window.webkit.messageHandlers.mark`, the bridge that writes bytes to
//! the reader's files, and could send anything it read to a server. It also
//! made `mark render --html`'s "no JavaScript and no network access" untrue of
//! any document that embedded some.
//!
//! ## Why this is written by hand rather than handed to `ammonia`
//!
//! Not thrift — `ammonia` cannot do this job. It sanitizes a *fragment* by
//! parsing it into a tree and re-serializing, which means balancing tags. But
//! `pulldown-cmark` does not emit balanced fragments. It emits lines:
//!
//! ```text
//! Start(HtmlBlock)  Html("<details>\n")  Html("<summary>hi</summary>\n")  End(HtmlBlock)
//! Start(Paragraph)  …the markdown in between, parsed as markdown…  End(Paragraph)
//! Start(HtmlBlock)  Html("</details>\n")  End(HtmlBlock)
//! ```
//!
//! A tree sanitizer handed the first block closes `<details>` at the end of it,
//! and the document's structure is destroyed. So the filter here is
//! **streaming and tag-at-a-time**: it never balances anything, never holds
//! state across events, and is therefore correct on a fragment that opens an
//! element it will not close.
//!
//! ## The rules
//!
//! 1. **An allowed tag is re-serialized, never passed through.** The tag is
//!    parsed into a name and attributes, and a fresh one is written from the
//!    parts that survive, with every value escaped. Nothing from the document
//!    reaches the output as markup. That is what closes off the whole family of
//!    attacks that work by confusing a filter about where a quoted value ends:
//!    there is no passthrough to confuse.
//! 2. **Everything else is escaped to visible text.** A `<script>` becomes
//!    `&lt;script&gt;` and its body shows as the text it is. Escaping rather
//!    than deleting is deliberate — dropping the body of a disallowed element
//!    would need the cross-event state that rule 1 exists to avoid, and a
//!    reader who embedded an `<iframe>` should be able to see *why* it is not
//!    playing rather than find a blank space.
//! 3. **`style` is not an attribute and `<style>` is not a tag.** Both are
//!    dropped rather than filtered. CSS is a second language with its own
//!    injection surface, and a viewer with sixteen themes has no reason to let
//!    a document restyle itself.
//! 4. **URL attributes carry a scheme we allow, or they are dropped.**
//!
//! There is deliberately **no way to turn this off.** ADR-5's rule is that the
//! CLI and the GUI must not diverge, and a `--allow-html` flag is a divergence
//! with a security boundary on one side of it.

use std::fmt::Write as _;

use crate::render::{escape_attr, escape_html};

/// Elements a document may use.
///
/// Chosen as "things a note legitimately contains that markdown cannot
/// express": `<kbd>`, `<details>`, `<sub>`, alignment on a table cell. Every
/// element that loads a subresource, runs code, or navigates on its own is
/// absent — `script`, `style`, `iframe`, `object`, `embed`, `applet`, `form`,
/// `input`, `button`, `link`, `meta`, `base`, `svg`, `math`.
///
/// `svg` and `math` are worth a word, because they look harmless and are not:
/// both are namespaces with their own parsing rules, and both can carry
/// scripted content. The core renders `$…$` to MathML and ```mermaid to SVG
/// itself (ADR-5), so a document has no reason to hand-write either.
const ALLOWED_TAGS: &[&str] = &[
    // inline
    "a",
    "abbr",
    "b",
    "bdi",
    "bdo",
    "br",
    "cite",
    "code",
    "data",
    "dfn",
    "em",
    "i",
    "kbd",
    "mark",
    "q",
    "rp",
    "rt",
    "ruby",
    "s",
    "samp",
    "small",
    "span",
    "strong",
    "sub",
    "sup",
    "time",
    "u",
    "var",
    "wbr", // block
    "article",
    "aside",
    "blockquote",
    "caption",
    "col",
    "colgroup",
    "dd",
    "details",
    "div",
    "dl",
    "dt",
    "figcaption",
    "figure",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "ol",
    "p",
    "pre",
    "section",
    "summary",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "tr",
    "ul", // the one that loads something, and is why `mark-doc` is an allowlist
    "img",
];

/// Attributes allowed on any element.
///
/// `id` is here and is the one with a caveat: a document can collide with an
/// anchor the renderer generated for a heading. That is a cosmetic problem —
/// `mark goto` may land on the wrong element — and not a safety one, so it is
/// allowed rather than stripped.
const GLOBAL_ATTRIBUTES: &[&str] = &["class", "id", "title", "dir", "lang"];

/// Attributes allowed on one specific element.
const TAG_ATTRIBUTES: &[(&str, &[&str])] = &[
    ("a", &["href"]),
    ("img", &["src", "alt", "width", "height"]),
    ("ol", &["start", "reversed"]),
    ("li", &["value"]),
    ("td", &["colspan", "rowspan", "align", "valign"]),
    ("th", &["colspan", "rowspan", "align", "valign", "scope"]),
    ("col", &["span"]),
    ("colgroup", &["span"]),
    ("time", &["datetime"]),
    ("data", &["value"]),
    ("details", &["open"]),
    ("q", &["cite"]),
    ("blockquote", &["cite"]),
];

/// Attributes whose value is a URL, and therefore needs its scheme checked.
const URL_ATTRIBUTES: &[&str] = &["href", "src", "cite"];

/// Schemes a URL attribute may name.
///
/// A destination with *no* scheme is relative and is fine — that is how
/// `![alt](assets/x.png)` and `[other](notes.md)` work, and it is the common
/// case. `data:` is absent: it is how a small image is smuggled in, and also
/// how `data:text/html` is.
const ALLOWED_SCHEMES: &[&str] = &["http", "https", "mailto", "tel"];

/// Filter one raw-HTML fragment from the event stream.
///
/// The fragment is whatever `Event::Html` or `Event::InlineHtml` carried: one
/// or more tags, text between them, or a fragment of either. Output is safe to
/// concatenate with the rest of the rendered document.
#[must_use]
pub fn fragment(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut index = 0;
    // Where the current run of ordinary text began. Text is escaped in one go
    // rather than character by character.
    let mut text = 0;

    while index < bytes.len() {
        if bytes[index] != b'<' {
            index += 1;
            continue;
        }
        // A `<` that begins something we recognise as markup. Anything else —
        // `a < b` in prose, a stray bracket — falls through and is escaped
        // with the surrounding text.
        let Some((rewritten, after)) = markup_at(html, index) else {
            index += 1;
            continue;
        };
        out.push_str(&escape_html(&html[text..index]));
        out.push_str(&rewritten);
        index = after;
        text = after;
    }
    out.push_str(&escape_html(&html[text..]));
    out
}

/// Parse the markup beginning at `start`, returning what to emit for it and
/// where it ends. `None` means "this `<` does not begin markup", and the
/// character is treated as text.
fn markup_at(html: &str, start: usize) -> Option<(String, usize)> {
    let rest = &html[start..];

    // Comments, doctypes, and processing instructions. Dropped outright rather
    // than escaped: none of them renders anything, and a conditional comment is
    // markup that only some parsers see — exactly the ambiguity to remove. An
    // unterminated comment swallows the rest of the fragment, which is what a
    // browser does with it too.
    if let Some(body) = rest.strip_prefix("<!--") {
        let end = body.find("-->").map_or(html.len(), |i| start + 4 + i + 3);
        return Some((String::new(), end));
    }
    if rest.starts_with("<!") || rest.starts_with("<?") {
        let end = rest.find('>').map_or(html.len(), |i| start + i + 1);
        return Some((String::new(), end));
    }

    let closing = rest.starts_with("</");
    let name_at = if closing { start + 2 } else { start + 1 };
    let name_end = html[name_at..]
        .find(|c: char| !c.is_ascii_alphanumeric())
        .map_or(html.len(), |i| name_at + i);
    let name = html[name_at..name_end].to_ascii_lowercase();
    if name.is_empty() {
        return None;
    }

    // The tag's extent. An unterminated tag runs to the end of the fragment,
    // which matters: `<img src=x` with no `>` must not fall through to the
    // text path, where the `<` would be escaped and the rest emitted as
    // markup by a later concatenation.
    let close = tag_end(html, name_end);
    let (inside, after) = match close {
        Some(at) => (&html[name_end..at], at + 1),
        None => (&html[name_end..], html.len()),
    };

    if !ALLOWED_TAGS.contains(&name.as_str()) {
        // Rule 2: visible text, not silence.
        return Some((escape_html(&html[start..after]), after));
    }
    if closing {
        return Some((format!("</{name}>"), after));
    }

    // Rule 1: rebuilt from parts, never passed through.
    let mut tag = format!("<{name}");
    for (attribute, value) in attributes(inside) {
        if !allowed_attribute(&name, &attribute) {
            continue;
        }
        if URL_ATTRIBUTES.contains(&attribute.as_str()) && !safe_url(&value) {
            continue;
        }
        let _ = write!(tag, " {attribute}=\"{}\"", escape_attr(&value));
    }
    // Self-closing is preserved for the void elements, and harmless on the
    // rest: the parser decides what is void, not this marker.
    if inside.trim_end().ends_with('/') {
        tag.push_str(" /");
    }
    tag.push('>');
    Some((tag, after))
}

/// Where the tag whose name ends at `from` closes: the first `>` that is not
/// inside a quoted attribute value. `None` for an unterminated tag.
///
/// Quote-aware because `>` is legal inside a value — `title="a > b"` — and a
/// filter that stopped at the first one would drop every attribute after it
/// and emit the remainder as text, which is what this used to do. A quote
/// that is never closed swallows the rest of the fragment, exactly as a
/// browser's tokenizer treats it, and the caller then handles the tag as
/// unterminated.
fn tag_end(html: &str, from: usize) -> Option<usize> {
    let bytes = html.as_bytes();
    let mut quote: Option<u8> = None;
    for (offset, byte) in bytes[from..].iter().enumerate() {
        match (quote, *byte) {
            (Some(open), byte) if byte == open => quote = None,
            (Some(_), _) => {}
            (None, b'"' | b'\'') => quote = Some(*byte),
            (None, b'>') => return Some(from + offset),
            (None, _) => {}
        }
    }
    None
}

/// Whether `attribute` may appear on `tag`.
///
/// `on*` never survives this: it is not in either list, and the check is an
/// allowlist rather than a denylist, so an event handler nobody has heard of
/// is refused for the same reason `onclick` is.
fn allowed_attribute(tag: &str, attribute: &str) -> bool {
    if GLOBAL_ATTRIBUTES.contains(&attribute) {
        return true;
    }
    TAG_ATTRIBUTES
        .iter()
        .find(|(name, _)| *name == tag)
        .is_some_and(|(_, allowed)| allowed.contains(&attribute))
}

/// Split a tag's interior into `(lowercased name, raw value)` pairs.
///
/// Handles single quotes, double quotes, and unquoted values, because all
/// three are legal and a filter that understands only one of them can be
/// walked past. A bare attribute (`open`, `reversed`) gets its own name as its
/// value, which is what HTML means by it.
fn attributes(inside: &str) -> Vec<(String, String)> {
    let bytes = inside.as_bytes();
    let mut out = Vec::new();
    let mut index = 0;

    while index < bytes.len() {
        while index < bytes.len() && (bytes[index].is_ascii_whitespace() || bytes[index] == b'/') {
            index += 1;
        }
        let name_start = index;
        while index < bytes.len()
            && !bytes[index].is_ascii_whitespace()
            && bytes[index] != b'='
            && bytes[index] != b'/'
        {
            index += 1;
        }
        if index == name_start {
            break;
        }
        let name = inside[name_start..index].to_ascii_lowercase();

        while index < bytes.len() && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= bytes.len() || bytes[index] != b'=' {
            out.push((name.clone(), name));
            continue;
        }
        index += 1; // the '='
        while index < bytes.len() && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= bytes.len() {
            out.push((name, String::new()));
            break;
        }

        let value = match bytes[index] {
            quote @ (b'"' | b'\'') => {
                index += 1;
                let start = index;
                while index < bytes.len() && bytes[index] != quote {
                    index += 1;
                }
                let value = inside[start..index].to_owned();
                if index < bytes.len() {
                    index += 1; // the closing quote
                }
                value
            }
            _ => {
                let start = index;
                while index < bytes.len() && !bytes[index].is_ascii_whitespace() {
                    index += 1;
                }
                inside[start..index].to_owned()
            }
        };
        out.push((name, value));
    }
    out
}

/// Whether a URL may be kept, by its scheme.
///
/// Public because markdown has its own way of writing a destination —
/// `[click](javascript:alert(1))` is not raw HTML and never reaches
/// [`fragment`] — and the two spellings must not get two answers. The render
/// path applies this to `Tag::Link` and `Tag::Image` as well.
///
/// The obfuscations this has to survive are all about hiding the scheme:
/// `JaVaScRiPt:`, a leading space, an embedded tab or newline, a NUL. So the
/// value is stripped of every ASCII control and space *before* the scheme is
/// looked for, rather than trimmed.
///
/// Entity-encoded attempts — `java&#9;script:` — need no special handling and
/// deliberately get none. The value is re-serialized through
/// [`escape_attr`], so its `&` becomes `&amp;` and the browser sees a literal
/// string that is not a scheme at all. That is a property of rule 1, and it is
/// why rule 1 is written the way it is.
pub fn safe_url(value: &str) -> bool {
    let stripped: String = value
        .chars()
        .filter(|c| !c.is_ascii_control() && *c != ' ')
        .collect();
    let lower = stripped.to_ascii_lowercase();

    // Find the scheme, if there is one: everything before the first `:`, so
    // long as no `/`, `?`, or `#` comes first. `notes/a:b.md` is a relative
    // path, not a scheme called `notes/a`.
    let colon = match lower.find(':') {
        None => return true,
        Some(at) => at,
    };
    if lower[..colon].contains(['/', '?', '#']) {
        return true;
    }
    // A scheme is a letter followed by letters, digits, `+`, `-`, `.`. Anything
    // else before the colon is not a scheme, so the value is relative.
    let scheme = &lower[..colon];
    let mut chars = scheme.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() => {}
        _ => return true,
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.') {
        return true;
    }
    ALLOWED_SCHEMES.contains(&scheme)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- the hole this module exists to close ---------------------------

    #[test]
    fn a_script_becomes_visible_text() {
        let out = fragment("<script>alert(1)</script>");
        assert!(!out.contains("<script"), "{out}");
        assert!(out.contains("&lt;script&gt;"), "{out}");
    }

    #[test]
    fn an_event_handler_is_dropped_and_the_element_survives() {
        let out = fragment(r#"<img src="x.png" onerror="alert(1)">"#);
        assert!(!out.contains("onerror"), "{out}");
        assert!(out.contains("src=\"x.png\""), "{out}");
    }

    #[test]
    fn every_on_attribute_goes_not_just_the_ones_we_thought_of() {
        for handler in ["onclick", "onload", "onanimationstart", "onmadeuptomorrow"] {
            let out = fragment(&format!("<div {handler}=\"x\">hi</div>"));
            assert!(!out.contains(handler), "{handler} survived: {out}");
        }
    }

    #[test]
    fn an_iframe_is_not_rendered() {
        let out = fragment(r#"<iframe src="https://example.com"></iframe>"#);
        assert!(!out.contains("<iframe"), "{out}");
    }

    #[test]
    fn a_javascript_url_is_dropped_however_it_is_spelled() {
        for href in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "  javascript:alert(1)",
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            "java\0script:alert(1)",
            "\u{1}javascript:alert(1)",
        ] {
            let out = fragment(&format!("<a href=\"{href}\">x</a>"));
            assert!(
                !out.to_ascii_lowercase().contains("href"),
                "{href:?} survived as: {out}"
            );
        }
    }

    #[test]
    fn an_entity_encoded_scheme_is_neutralised_by_escaping() {
        // Not dropped — it is not a scheme until the browser decodes it, and
        // it never gets decoded, because the `&` is escaped on the way out.
        let out = fragment(r#"<a href="java&#9;script:alert(1)">x</a>"#);
        assert!(out.contains("&amp;#9;"), "the & must be escaped: {out}");
        assert!(!out.contains("&#9;s"), "{out}");
    }

    #[test]
    fn a_data_url_is_dropped() {
        let out = fragment(r#"<a href="data:text/html,<script>alert(1)</script>">x</a>"#);
        assert!(!out.contains("href"), "{out}");
    }

    #[test]
    fn quoting_tricks_do_not_escape_the_attribute() {
        // The classic: end the value early and start an attribute of your own.
        // Re-serializing makes it impossible — whatever the parse decides the
        // value is, it is emitted escaped and inside quotes we wrote.
        let out = fragment(r#"<img src=x onerror=alert(1)>"#);
        assert!(!out.contains("onerror"), "{out}");
        let out = fragment(r#"<a href='x' onclick='alert(1)'>x</a>"#);
        assert!(!out.contains("onclick"), "{out}");
    }

    #[test]
    fn a_closing_bracket_inside_a_quoted_value_does_not_end_the_tag() {
        let out = fragment(r#"<a title="a > b" href="https://e.com">x</a>"#);
        assert_eq!(out, r#"<a title="a &gt; b" href="https://e.com">x</a>"#);
        let out = fragment(r#"<span title='1 > 0'>x</span>"#);
        assert_eq!(out, r#"<span title="1 &gt; 0">x</span>"#);
    }

    #[test]
    fn an_unclosed_quote_runs_to_the_end_and_is_still_rebuilt() {
        // The tokenizer never finds the closing quote, so the tag runs to the
        // end of the fragment. It is rebuilt from what parsed, never copied.
        let out = fragment(r#"<b class="x>bold</b>"#);
        assert!(out.starts_with("<b"), "{out}");
        assert!(!out.contains("</b>"), "{out}");
    }

    #[test]
    fn a_style_attribute_and_a_style_element_both_go() {
        let out = fragment(r#"<div style="position:fixed;top:0">x</div>"#);
        assert!(!out.contains("style"), "{out}");
        let out = fragment("<style>body{display:none}</style>");
        assert!(!out.contains("<style"), "{out}");
    }

    #[test]
    fn an_unterminated_tag_does_not_leak_through_as_markup() {
        // If this fell through to the text path the `<` would be escaped and
        // the rest left alone, and concatenating the next fragment could
        // reassemble a tag.
        let out = fragment("<img src=x onerror=alert(1)");
        assert!(!out.contains("onerror"), "{out}");
    }

    #[test]
    fn a_comment_is_dropped_including_an_unterminated_one() {
        assert_eq!(fragment("<!-- <script>alert(1)</script> -->"), "");
        assert_eq!(fragment("<!-- unterminated"), "");
    }

    #[test]
    fn a_doctype_or_processing_instruction_is_dropped() {
        assert_eq!(fragment("<!DOCTYPE html>"), "");
        assert_eq!(fragment("<?xml version=\"1.0\"?>"), "");
    }

    #[test]
    fn svg_and_math_are_not_allowed_even_though_they_look_harmless() {
        for tag in ["svg", "math", "object", "embed", "form", "input", "base"] {
            let out = fragment(&format!("<{tag}>x</{tag}>"));
            assert!(!out.contains(&format!("<{tag}")), "{tag} survived: {out}");
        }
    }

    // ---- a destination markdown wrote, not HTML --------------------------

    /// The gap the CLI test found: `sanitize::fragment` never sees these,
    /// because `[click](javascript:…)` is not raw HTML. The render path applies
    /// `safe_url` to `Tag::Link` and `Tag::Image` for exactly this.
    #[test]
    fn a_markdown_link_destination_is_judged_by_the_same_rule() {
        assert!(!safe_url("javascript:alert(1)"));
        assert!(!safe_url("JaVaScRiPt:alert(1)"));
        assert!(!safe_url("data:text/html,<script>alert(1)</script>"));
        assert!(safe_url("notes.md"));
        assert!(safe_url("#anchor"));
        assert!(safe_url("../up/a.md"));
        assert!(safe_url("https://x.test"));
    }

    // ---- what a note is allowed to keep ----------------------------------

    #[test]
    fn the_constructs_markdown_cannot_express_survive() {
        assert_eq!(fragment("<kbd>"), "<kbd>");
        assert_eq!(fragment("</kbd>"), "</kbd>");
        assert_eq!(fragment("<sub>"), "<sub>");
        assert_eq!(fragment("<br>"), "<br>");
        assert_eq!(fragment("<br />"), "<br />");
    }

    #[test]
    fn an_unbalanced_fragment_is_left_unbalanced() {
        // The whole reason this is not `ammonia`: `<details>` opens in one
        // event and closes three blocks later, and nothing here may try to
        // close it.
        assert_eq!(fragment("<details>\n"), "<details>\n");
        assert_eq!(fragment("</details>\n"), "</details>\n");
    }

    #[test]
    fn a_relative_link_and_an_anchor_survive() {
        assert!(fragment(r#"<a href="notes.md">x</a>"#).contains(r#"href="notes.md""#));
        assert!(fragment(r##"<a href="#install">x</a>"##).contains(r##"href="#install""##));
        assert!(fragment(r#"<a href="../up/a.md">x</a>"#).contains("href="));
        // A colon that is not a scheme.
        assert!(fragment(r#"<a href="notes/a:b.md">x</a>"#).contains("href="));
    }

    #[test]
    fn the_schemes_a_note_legitimately_uses_survive() {
        for href in [
            "https://x.test/a",
            "http://x.test",
            "mailto:a@b.test",
            "tel:+15551234",
        ] {
            let out = fragment(&format!("<a href=\"{href}\">x</a>"));
            assert!(out.contains("href="), "{href} was dropped: {out}");
        }
    }

    #[test]
    fn a_table_cell_keeps_its_alignment_and_spans() {
        let out = fragment(r#"<td colspan="2" align="right" scope="row">"#);
        assert!(out.contains("colspan=\"2\""), "{out}");
        assert!(out.contains("align=\"right\""), "{out}");
        // `scope` is a `th` attribute, not a `td` one.
        assert!(!out.contains("scope"), "{out}");
    }

    #[test]
    fn a_bare_attribute_keeps_its_meaning() {
        assert_eq!(fragment("<details open>"), "<details open=\"open\">");
    }

    #[test]
    fn text_around_markup_is_escaped_and_kept() {
        let out = fragment("a < b and <kbd>C</kbd> & more");
        assert!(out.contains("a &lt; b"), "{out}");
        assert!(out.contains("<kbd>C</kbd>"), "{out}");
        assert!(out.contains("&amp; more"), "{out}");
    }

    #[test]
    fn an_image_keeps_the_attributes_the_renderer_relies_on() {
        let out = fragment(r#"<img src="a.png" alt="x" width="10" height="20" srcset="evil">"#);
        assert!(out.contains("src=\"a.png\""), "{out}");
        assert!(out.contains("width=\"10\""), "{out}");
        assert!(!out.contains("srcset"), "{out}");
    }

    #[test]
    fn nothing_from_the_document_reaches_the_output_unescaped() {
        // A quote in a kept value must not be able to close the attribute we
        // are writing.
        let out = fragment(r#"<div class='a" onclick="alert(1)'>x</div>"#);
        assert!(!out.contains("onclick=\""), "{out}");
        assert!(out.contains("&quot;"), "the quote must be escaped: {out}");
    }
}
