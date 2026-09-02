//! Every link and image a document points at, classified by its own syntax.
//!
//! Three features want this list and none of them wants the same half of it:
//!
//! * **Images that load.** The shell serves the document's pictures over a
//!   scheme of its own, and to do that it has to know which files on disk the
//!   document actually names. Nothing else in the core resolves a destination
//!   to a path, so it lives here rather than being open-coded in `render`.
//! * **`mark links`.** "Which of my notes point at a file that is no longer
//!   there" is the question a notes directory decays by, and it is one `stat`
//!   per destination once the destinations are enumerated.
//! * **Backlinks.** "What points *here*" is [`references`] run over every file
//!   in a tree, filtered by target. The core supplies the per-document half;
//!   fanning it out over a directory is the caller's business.
//!
//! **Classification never touches the disk.** [`Destination`] is decided from
//! the destination string alone, so enumerating a document is as cheap as
//! walking its events, and the render path — which needs to rewrite an image
//! `src` on every paint — pays no `stat`. Existence is a separate step
//! ([`check`]), because only one of the three callers wants it.
//!
//! Destinations are **percent-decoded** before they become paths. A markdown
//! destination is a URL, so a file whose name has a space in it is written
//! `my%20note.md` by every tool that generates markdown, and a resolver that
//! skips the decode looks for a file with a literal `%20` in its name and
//! reports a working link as broken.

use std::ops::Range;
use std::path::{Component, Path, PathBuf};

use pulldown_cmark::{Event, Tag, TagEnd};
use serde::Serialize;

use crate::parse::Document;

/// Whether a reference was written as a link or as an image.
///
/// The distinction is not cosmetic: an image's destination is fetched and
/// displayed whether or not the reader asks, so the shell's scheme handler
/// serves images and refuses everything else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RefKind {
    Link,
    Image,
}

/// What a destination points at, decided from the string alone.
///
/// No disk access and no network access: this is a syntactic classification,
/// and it is what keeps [`references`] cheap enough to run on the render path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Destination {
    /// `#anchor` — a jump inside this document. `mark goto`'s target.
    Fragment { anchor: String },
    /// A destination carrying a scheme we do not resolve — `http`, `https`,
    /// `mailto`, and anything else with a `scheme:` prefix.
    ///
    /// Deliberately not fetched by anything in this crate. `mark links` reports
    /// these as unchecked rather than reaching for the network: a link checker
    /// that makes HTTP requests is a different tool with different failure
    /// modes, and this one runs on a laptop against private notes.
    External { url: String },
    /// A path relative to the document, or absolute on this machine, with any
    /// `#fragment` split off.
    ///
    /// `path` is percent-decoded and is exactly what a `Path` should be built
    /// from; it has **not** been joined to a base directory, because the base
    /// is the caller's (a document has no path of its own — see
    /// [`crate::parse::Document`], which is parsed from a string).
    Local {
        path: String,
        fragment: Option<String>,
    },
}

/// One `[text](dest)` or `![alt](dest)` in a document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Reference {
    pub kind: RefKind,
    /// The whole construct's byte span in the source, brackets included.
    ///
    /// Authoritative, like every other span in this crate: a caller that wants
    /// to rewrite a destination edits these bytes rather than searching for the
    /// text again.
    pub span: Range<usize>,
    /// The destination exactly as the document wrote it, before decoding.
    pub dest: String,
    /// The link text, or the image's alt text, with inline markup flattened.
    pub text: String,
    /// The `"title"` after the destination, or empty.
    pub title: String,
    pub target: Destination,
}

/// Every link and image in the document, in source order.
///
/// Nested constructs are flattened: an image inside a link — `[![alt](a.png)](b.md)`
/// — yields both, because both have a destination that can rot.
#[must_use]
pub fn references(doc: &Document<'_>) -> Vec<Reference> {
    let events = doc.events();
    let mut out = Vec::new();
    // A stack rather than a scalar, because a link may contain an image and
    // the inner one closes first. Each frame collects its own text, and text
    // inside an inner construct belongs to both — `[see ![x](a.png)](b.md)`
    // has link text "see x" — so a `Text` event is appended to every open
    // frame, not only the innermost.
    let mut open: Vec<(RefKind, String, String, Range<usize>, String)> = Vec::new();

    for (event, span) in events {
        match event {
            Event::Start(Tag::Link {
                dest_url, title, ..
            }) => open.push((
                RefKind::Link,
                dest_url.to_string(),
                title.to_string(),
                span.clone(),
                String::new(),
            )),
            Event::Start(Tag::Image {
                dest_url, title, ..
            }) => open.push((
                RefKind::Image,
                dest_url.to_string(),
                title.to_string(),
                span.clone(),
                String::new(),
            )),
            Event::End(TagEnd::Link) | Event::End(TagEnd::Image) => {
                // `End` without a matching `Start` cannot happen — the parser
                // balances the stream — but popping an empty stack must not
                // panic: this is reachable from the C ABI.
                if let Some((kind, dest, title, span, text)) = open.pop() {
                    let target = classify(&dest);
                    out.push(Reference {
                        kind,
                        span,
                        dest,
                        text,
                        title,
                        target,
                    });
                }
            }
            Event::Text(text) | Event::Code(text) => {
                for frame in &mut open {
                    frame.4.push_str(text);
                }
            }
            _ => {}
        }
    }

    // The stack pops innermost-first, so an inner image is pushed to `out`
    // before the link containing it. Source order is what every caller wants —
    // `mark links` prints in it, and a rewriter must not walk spans backwards.
    out.sort_by_key(|reference| reference.span.start);
    out
}

/// Classify one destination string. Public because the shell's link-following
/// path asks the same question of an `href` it was handed by the page, and
/// answering it twice in two languages is how the two drift apart.
#[must_use]
pub fn classify(dest: &str) -> Destination {
    if let Some(anchor) = dest.strip_prefix('#') {
        return Destination::Fragment {
            anchor: decode(anchor),
        };
    }
    if has_scheme(dest) {
        return Destination::External {
            url: dest.to_owned(),
        };
    }
    // A `#` in a path splits it: `notes.md#install` is a file *and* a jump
    // within it. Split before decoding, so a literal `%23` in a filename stays
    // part of the name rather than becoming a fragment separator.
    let (path, fragment) = match dest.split_once('#') {
        Some((path, fragment)) => (path, Some(decode(fragment))),
        None => (dest, None),
    };
    Destination::Local {
        path: decode(path),
        fragment,
    }
}

/// Whether a destination begins with a URL scheme.
///
/// RFC 3986's rule, not a list of schemes we happen to have thought of: a
/// scheme is a letter followed by letters, digits, `+`, `-`, or `.`, then a
/// colon. Checking against `["http", "https", "mailto"]` instead would classify
/// `obsidian://open?…` as a relative path and then try to `stat` it.
///
/// A Windows drive letter (`C:\notes`) matches this shape and is deliberately
/// treated as a scheme: this is an arm64-macOS-only product (ADR-1), so such a
/// destination is a foreign path that we cannot resolve either way.
fn has_scheme(dest: &str) -> bool {
    let mut chars = dest.char_indices();
    match chars.next() {
        Some((_, first)) if first.is_ascii_alphabetic() => {}
        _ => return false,
    }
    for (index, ch) in chars {
        match ch {
            ':' => return index > 0,
            c if c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.' => {}
            _ => return false,
        }
    }
    false
}

/// Percent-decode a URL component.
///
/// Hand-written rather than a dependency: it is this function, the rules are
/// fixed, and `mark` justifies every crate it pulls in. Invalid escapes are
/// **left alone** rather than dropped — a filename containing a bare `%` is
/// legal on this filesystem, and a decoder that ate it would turn a working
/// link into a broken one. Bytes are decoded before UTF-8 is re-validated, so
/// a multi-byte character split across several escapes (`%E2%9C%93`) survives.
fn decode(text: &str) -> String {
    if !text.contains('%') {
        return text.to_owned();
    }
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hi = (bytes[index + 1] as char).to_digit(16);
            let lo = (bytes[index + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    // A decode that does not produce UTF-8 means the escapes named bytes that
    // are not text. Returning the original is the honest answer: we cannot
    // build a `String` from them, and a lossy replacement would name a file
    // that does not exist.
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// Resolve a [`Destination::Local`] path against the directory holding the
/// document, and normalise it without touching the disk.
///
/// `..` is folded lexically rather than by `canonicalize`, deliberately: a
/// symlinked notes directory should resolve the way the reader sees it, and
/// `canonicalize` also fails outright on a path that does not exist — which is
/// exactly the case `mark links --broken` is looking for.
#[must_use]
pub fn resolve(path: &str, base: &Path) -> PathBuf {
    let joined = if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        base.join(path)
    };
    let mut out = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::ParentDir => match out.components().next_back() {
                // Nothing to pop yet, or what is there is itself a `..`: the
                // segment has to be *kept*. Dropping it is the bug this arm
                // exists for — with a relative base, folding `../x` down to
                // `x` names a sibling of the wrong directory, and every link
                // in a note that reaches upwards is then reported broken.
                None | Some(Component::ParentDir) => out.push(".."),
                // Popping past the root leaves the root, matching how the
                // filesystem resolves `/..`.
                Some(Component::RootDir) => {}
                _ => {
                    out.pop();
                }
            },
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// A reference with the disk consulted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Checked {
    #[serde(flatten)]
    pub reference: Reference,
    /// The resolved path, for a [`Destination::Local`]. Absolute.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    /// Whether the target is there. `None` means "not checked": an external
    /// URL, or a fragment, neither of which this crate resolves.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exists: Option<bool>,
}

/// Resolve and `stat` every local destination. One `stat` per local reference,
/// and none for fragments or external URLs.
#[must_use]
pub fn check(references: Vec<Reference>, base: &Path) -> Vec<Checked> {
    references
        .into_iter()
        .map(|reference| match &reference.target {
            Destination::Local { path, .. } => {
                let resolved = resolve(path, base);
                let exists = resolved.exists();
                Checked {
                    reference,
                    path: Some(resolved),
                    exists: Some(exists),
                }
            }
            _ => Checked {
                reference,
                path: None,
                exists: None,
            },
        })
        .collect()
}

/// One document pointing at another.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Backlink {
    /// The file that holds the reference.
    pub path: PathBuf,
    /// 1-based line of the reference in that file.
    pub line: usize,
    /// Byte offset of the reference, for scrolling to it.
    pub offset: usize,
    /// The link's own text — what the other document *calls* this one, which
    /// is often more useful than the filename.
    pub text: String,
    /// The `>`-joined headings the reference sits under.
    pub heading: String,
    /// A `#fragment` on the reference, when it points at a section.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fragment: Option<String>,
    pub kind: RefKind,
}

/// Every reference in `root` that points at `target`.
///
/// The other direction from [`references`], and the question a notes directory
/// is actually navigated by: not "what does this note point at" but "what
/// points *here*". Answering it needs the whole tree, so it costs one parse per
/// markdown file below `root` — the same shape and the same caveat as
/// [`crate::search::search`].
///
/// Matching is on the **resolved path**, so `../notes/runbook.md` from a
/// sibling directory and `runbook.md` from beside it are both found. A
/// reference carrying a `#fragment` still counts: it points at this document,
/// at a particular place in it.
///
/// **Set `options.max_depth` yourself.** [`crate::tree::Options`] defaults to
/// 1 — one directory — because that is what the sidebar needs, and "what points
/// here" over a single directory misses most of the answer. Callers want
/// [`crate::tree::DEFAULT_RECURSIVE_DEPTH`].
pub fn backlinks(
    root: &Path,
    target: &Path,
    options: &crate::tree::Options,
) -> Result<Vec<Backlink>, crate::tree::TreeError> {
    let target = std::path::absolute(target).unwrap_or_else(|_| target.to_path_buf());
    let target = resolve(&target.to_string_lossy(), Path::new("/"));

    let mut out = Vec::new();
    for file in crate::tree::markdown_files(root, options)? {
        let absolute = std::path::absolute(&file).unwrap_or_else(|_| file.clone());
        // A document does not link to itself, and a self-reference in a table
        // of contents would otherwise fill the list.
        if absolute == target {
            continue;
        }
        let Ok(source) = std::fs::read_to_string(&file) else {
            continue;
        };
        let doc = Document::parse(&source);
        let base = absolute
            .parent()
            .map_or_else(|| PathBuf::from("."), Path::to_path_buf);
        let lines = doc.lines();

        for reference in references(&doc) {
            let Destination::Local { path, fragment } = &reference.target else {
                continue;
            };
            if resolve(path, &base) != target {
                continue;
            }
            let (heading, _) = crate::search::heading_path(&doc.headings(), reference.span.start);
            out.push(Backlink {
                path: file.clone(),
                line: lines.line_of(reference.span.start),
                offset: reference.span.start,
                text: reference.text.clone(),
                heading,
                fragment: fragment.clone(),
                kind: reference.kind,
            });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refs(source: &str) -> Vec<Reference> {
        references(&Document::parse(source))
    }

    /// A walk that actually descends. `tree::Options` defaults to one level.
    fn recursive() -> crate::tree::Options {
        crate::tree::Options {
            max_depth: crate::tree::DEFAULT_RECURSIVE_DEPTH,
            ..crate::tree::Options::default()
        }
    }

    #[test]
    fn backlinks_find_what_points_here() {
        let dir = tempfile::tempdir().unwrap();
        let notes = dir.path().join("notes");
        std::fs::create_dir_all(&notes).unwrap();
        std::fs::write(notes.join("runbook.md"), "# Runbook\n").unwrap();
        // From beside it, and from a sibling directory, and neither should be
        // missed: matching is on the resolved path.
        std::fs::write(
            notes.join("index.md"),
            "# Index\n\n## Ops\n\nsee [the runbook](runbook.md)\n",
        )
        .unwrap();
        std::fs::write(
            dir.path().join("top.md"),
            "# Top\n\n[deploy steps](notes/runbook.md#install)\n",
        )
        .unwrap();
        // A document that mentions it in prose but does not link is not a
        // backlink.
        std::fs::write(
            dir.path().join("other.md"),
            "# Other\n\nthe runbook.md file\n",
        )
        .unwrap();

        let found = backlinks(dir.path(), &notes.join("runbook.md"), &recursive()).unwrap();

        assert_eq!(found.len(), 2, "{found:#?}");
        let texts: Vec<&str> = found.iter().map(|b| b.text.as_str()).collect();
        assert!(texts.contains(&"the runbook"));
        assert!(texts.contains(&"deploy steps"));

        let with_fragment = found.iter().find(|b| b.text == "deploy steps").unwrap();
        assert_eq!(with_fragment.fragment.as_deref(), Some("install"));

        let from_index = found.iter().find(|b| b.text == "the runbook").unwrap();
        assert_eq!(from_index.heading, "Index > Ops", "the breadcrumb is wrong");
    }

    #[test]
    fn a_document_does_not_link_to_itself() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("notes.md");
        std::fs::write(&target, "# Notes\n\n[back to the top](notes.md)\n").unwrap();

        let found = backlinks(dir.path(), &target, &recursive()).unwrap();
        assert!(found.is_empty(), "{found:#?}");
    }

    #[test]
    fn an_image_pointing_here_is_a_backlink_too() {
        let dir = tempfile::tempdir().unwrap();
        let picture = dir.path().join("diagram.png");
        std::fs::write(&picture, b"x").unwrap();
        std::fs::write(dir.path().join("a.md"), "![the diagram](diagram.png)\n").unwrap();

        let found = backlinks(dir.path(), &picture, &recursive()).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, RefKind::Image);
    }

    #[test]
    fn a_link_and_an_image_are_told_apart() {
        let found = refs("[text](a.md) and ![alt](b.png)");
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].kind, RefKind::Link);
        assert_eq!(found[0].text, "text");
        assert_eq!(found[1].kind, RefKind::Image);
        assert_eq!(found[1].text, "alt");
    }

    #[test]
    fn references_come_back_in_source_order() {
        // The image is nested inside the link, so the stack pops it first.
        let found = refs("[see ![x](a.png)](b.md)");
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].kind, RefKind::Link, "the outer link starts first");
        assert_eq!(found[0].text, "see x");
        assert_eq!(found[1].kind, RefKind::Image);
    }

    #[test]
    fn a_fragment_is_not_a_path() {
        assert_eq!(
            classify("#install"),
            Destination::Fragment {
                anchor: "install".to_owned()
            }
        );
    }

    #[test]
    fn schemes_are_recognised_by_shape_not_by_a_list() {
        for url in ["http://x", "https://x", "mailto:a@b", "obsidian://open"] {
            assert!(
                matches!(classify(url), Destination::External { .. }),
                "{url} should be external"
            );
        }
        for path in ["notes.md", "./a/b.md", "../up.md", "/abs/x.md", "a-b.md"] {
            assert!(
                matches!(classify(path), Destination::Local { .. }),
                "{path} should be local"
            );
        }
    }

    #[test]
    fn a_fragment_splits_off_a_path() {
        assert_eq!(
            classify("notes.md#install"),
            Destination::Local {
                path: "notes.md".to_owned(),
                fragment: Some("install".to_owned())
            }
        );
    }

    #[test]
    fn destinations_are_percent_decoded() {
        assert_eq!(
            classify("my%20note.md"),
            Destination::Local {
                path: "my note.md".to_owned(),
                fragment: None
            }
        );
    }

    #[test]
    fn a_multi_byte_character_survives_being_split_across_escapes() {
        assert_eq!(
            classify("%E2%9C%93.md"),
            Destination::Local {
                path: "\u{2713}.md".to_owned(),
                fragment: None
            }
        );
    }

    #[test]
    fn a_bare_percent_is_left_alone() {
        // A filename may legally contain one. Eating it would turn a working
        // link into a broken one.
        assert_eq!(
            classify("100%.md"),
            Destination::Local {
                path: "100%.md".to_owned(),
                fragment: None
            }
        );
        assert_eq!(
            classify("%zz.md"),
            Destination::Local {
                path: "%zz.md".to_owned(),
                fragment: None
            }
        );
    }

    #[test]
    fn parent_segments_fold_lexically() {
        let base = Path::new("/notes/2026/08");
        assert_eq!(
            resolve("../assets/x.png", base),
            PathBuf::from("/notes/2026/assets/x.png")
        );
        assert_eq!(
            resolve("./x.png", base),
            PathBuf::from("/notes/2026/08/x.png")
        );
        assert_eq!(resolve("/abs/x.png", base), PathBuf::from("/abs/x.png"));
    }

    #[test]
    fn parent_segments_past_a_relative_base_are_kept() {
        // Folding these away turns `../sibling/x.png` into `sibling/x.png`,
        // which names a different directory — and every upward link in the
        // document is then reported broken.
        assert_eq!(
            resolve("../x.png", Path::new("")),
            PathBuf::from("../x.png")
        );
        assert_eq!(
            resolve("../../x.png", Path::new("a")),
            PathBuf::from("../x.png")
        );
        assert_eq!(
            resolve("../../x.png", Path::new("")),
            PathBuf::from("../../x.png")
        );
    }

    #[test]
    fn parent_segments_cannot_climb_above_the_root() {
        assert_eq!(resolve("../../x", Path::new("/")), PathBuf::from("/x"));
    }

    #[test]
    fn spans_point_at_the_construct() {
        let source = "before [text](a.md) after";
        let found = refs(source);
        assert_eq!(&source[found[0].span.clone()], "[text](a.md)");
    }

    #[test]
    fn a_title_is_carried() {
        let found = refs("![alt](b.png \"A title\")");
        assert_eq!(found[0].title, "A title");
    }

    #[test]
    fn code_inside_link_text_is_part_of_the_text() {
        let found = refs("[the `mark` cli](a.md)");
        assert_eq!(found[0].text, "the mark cli");
    }
}
