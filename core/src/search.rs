//! Finding text across a directory of notes, and saying where each hit is.
//!
//! This was `cmd_grep` in the CLI, and it moved here for the reason ADR-1 gives
//! for the core existing at all: *"the CLI cannot drift from the GUI because
//! there is no second implementation to drift."* The window needs the same
//! answer `mark grep` gives, and the alternative — `NSRegularExpression` in
//! Swift — is a different regex dialect. `\d` and `(?i)` and a lookahead would
//! all behave differently depending on which half of the product you asked,
//! which is exactly the failure the single core is there to prevent.
//!
//! What makes this more than `grep`: **every hit knows which heading it is
//! under**. A search across a notes tree that answers `notes.md:412` is asking
//! the reader to go and look; one that answers `notes.md › Deploys › Rollback`
//! has told them what they wanted to know. That breadcrumb needs the parser, so
//! it needs to be here.
//!
//! Byte offsets, not just line numbers: the offset is what
//! `DocumentView.follow(sourceByte:)` scrolls to, and it is the same
//! authoritative-span discipline the rest of the crate keeps.

use std::ops::Range;
use std::path::{Path, PathBuf};

use regex::{Regex, RegexBuilder};
use serde::Serialize;

use crate::parse::{Document, Heading};
use crate::tree::{self, TreeError};

/// How a search is run.
#[derive(Debug, Clone)]
pub struct Options {
    /// Fold case.
    pub ignore_case: bool,
    /// Levels below the starting directory. 1 means "this directory only".
    pub max_depth: usize,
    /// Stop after this many hits, across all files.
    ///
    /// A cap rather than "all of them", because this runs while someone is
    /// typing: the window asks again on every keystroke, and a pattern like `e`
    /// over a real notes tree has more matches than anyone will read. Zero
    /// means no cap, which is what `mark grep` passes — a script piping to
    /// `wc -l` wants the truth.
    pub limit: usize,
    /// Include dotfiles and dot-directories.
    pub hidden: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            ignore_case: false,
            max_depth: tree::DEFAULT_RECURSIVE_DEPTH,
            limit: 0,
            hidden: false,
        }
    }
}

/// One hit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Match {
    pub path: PathBuf,
    /// 1-based, as every editor counts them.
    pub line: usize,
    /// Byte offset of the match in the file. What the window scrolls to, and
    /// the reason a line number alone is not enough.
    pub offset: usize,
    /// The matched text's span *within* [`text`], so the window can pick the
    /// hit out of the line without searching it a second time with a regex
    /// engine that might disagree.
    ///
    /// [`text`]: Match::text
    pub column: Range<usize>,
    /// Nearest enclosing headings, `>`-joined. Empty above the first heading.
    pub heading: String,
    /// The innermost heading's anchor, for `mark goto`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anchor: Option<String>,
    /// The whole line the match sits on, trimmed of its trailing newline.
    pub text: String,
}

/// Whether a search stopped early.
#[derive(Debug, Clone, Serialize)]
pub struct Results {
    pub matches: Vec<Match>,
    /// The pattern hit [`Options::limit`] and there are more.
    ///
    /// Reported rather than inferred from `matches.len() == limit`, which is
    /// ambiguous when a document happens to have exactly that many hits — and
    /// the window puts "showing the first 200" in front of the reader, so it
    /// must not say that when it found exactly 200 and no more.
    pub truncated: bool,
    /// Files opened. `mark grep`'s `MARK_TRACE` line, and the number that says
    /// whether a slow search is the walk or the regex.
    pub files: usize,
}

/// Compile a pattern.
///
/// Multi-line, so `^` and `$` anchor to lines — which is what anyone typing a
/// pattern into something called `grep` expects, and what the CLI has always
/// done.
pub fn compile(pattern: &str, ignore_case: bool) -> Result<Regex, regex::Error> {
    RegexBuilder::new(pattern)
        .case_insensitive(ignore_case)
        .multi_line(true)
        .build()
}

/// Search one already-parsed document.
///
/// Split out from [`search`] so a caller that already holds a `Document` — the
/// window, searching the file it is showing — does not parse it twice.
#[must_use]
pub fn matches_in(doc: &Document<'_>, path: &Path, regex: &Regex, limit: usize) -> Vec<Match> {
    let source = doc.source();
    let headings = doc.headings();
    let lines = doc.lines();
    let mut out = Vec::new();

    for found in regex.find_iter(source) {
        if limit > 0 && out.len() >= limit {
            break;
        }
        // An empty match — `a*` against text with no `a` — would report every
        // byte position in the file as a hit. Nobody typing a pattern means
        // that, and it is a fast way to produce a million-row table.
        if found.is_empty() {
            continue;
        }
        let bounds = line_bounds(source, found.start());
        let (heading, anchor) = heading_path(&headings, found.start());
        out.push(Match {
            path: path.to_path_buf(),
            line: lines.line_of(found.start()),
            offset: found.start(),
            column: (found.start() - bounds.start)..(found.end().min(bounds.end) - bounds.start),
            heading,
            anchor,
            text: source[bounds].trim_end().to_owned(),
        });
    }
    out
}

/// Search a file, or every markdown file below a directory.
pub fn search(root: &Path, pattern: &str, options: &Options) -> Result<Results, SearchError> {
    let regex = compile(pattern, options.ignore_case).map_err(SearchError::Pattern)?;
    let listing = tree::Options {
        max_depth: options.max_depth.max(1),
        hidden: options.hidden,
        ..tree::Options::default()
    };
    let targets = tree::markdown_files(root, &listing)?;

    let mut matches = Vec::new();
    let mut files = 0usize;

    // Collect **one more than asked for**. That extra hit is the only honest
    // way to answer "are there more?": stopping at exactly `limit` cannot tell
    // a tree with exactly that many matches from one with a thousand, which is
    // the ambiguity `Results::truncated` exists to remove — and the first
    // version of this got it wrong in precisely that way.
    let target = if options.limit > 0 {
        options.limit.saturating_add(1)
    } else {
        0
    };

    for file in targets {
        if target > 0 && matches.len() >= target {
            break;
        }
        // A file the caller *named* is theirs to hear about; one we found by
        // walking is not worth losing the rest of the results over. A notes
        // tree can hold a broken symlink or something that is not UTF-8, and
        // neither should mean "no matches" — but `mark grep pat broken.md`
        // saying nothing and exiting 0 would be a lie.
        let source = match std::fs::read_to_string(&file) {
            Ok(source) => source,
            Err(error) if file == root => {
                return Err(SearchError::Read {
                    path: file,
                    source: error,
                });
            }
            Err(_) => continue,
        };
        files += 1;
        let doc = Document::parse(&source);
        let remaining = if target > 0 {
            target - matches.len()
        } else {
            0
        };
        matches.extend(matches_in(&doc, &file, &regex, remaining));
    }

    // The extra hit, if we found one, is the evidence and not a result.
    let truncated = options.limit > 0 && matches.len() > options.limit;
    if truncated {
        matches.truncate(options.limit);
    }

    Ok(Results {
        matches,
        truncated,
        files,
    })
}

/// The `>`-joined heading path an offset sits under, plus the innermost anchor.
///
/// A match on a heading's own line is attributed to that heading, so `## Middle`
/// under `# Top` reports `Top > Middle` — the breadcrumb names where the match
/// is, not where it starts.
#[must_use]
pub fn heading_path(headings: &[Heading], offset: usize) -> (String, Option<String>) {
    let mut stack: Vec<&Heading> = Vec::new();
    for heading in headings {
        if heading.start > offset {
            break;
        }
        while stack.last().is_some_and(|open| open.level >= heading.level) {
            stack.pop();
        }
        stack.push(heading);
    }
    let anchor = stack.last().map(|h| h.anchor.clone());
    let path = stack
        .iter()
        .map(|h| h.text.as_str())
        .collect::<Vec<_>>()
        .join(" > ");
    (path, anchor)
}

/// Byte range of the line containing `offset`.
#[must_use]
pub fn line_bounds(source: &str, offset: usize) -> Range<usize> {
    let start = source[..offset].rfind('\n').map_or(0, |i| i + 1);
    let end = source[offset..]
        .find('\n')
        .map_or(source.len(), |i| offset + i);
    start..end
}

#[derive(Debug)]
pub enum SearchError {
    Pattern(regex::Error),
    Tree(TreeError),
    /// A file the caller named by hand could not be read. A file found by
    /// walking is skipped instead and never produces this.
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
}

impl From<TreeError> for SearchError {
    fn from(error: TreeError) -> Self {
        SearchError::Tree(error)
    }
}

impl std::fmt::Display for SearchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SearchError::Pattern(error) => write!(f, "{error}"),
            SearchError::Tree(error) => write!(f, "{error}"),
            SearchError::Read { path, source } => {
                write!(f, "{}: {source}", path.display())
            }
        }
    }
}

impl std::error::Error for SearchError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn find(source: &str, pattern: &str) -> Vec<Match> {
        let doc = Document::parse(source);
        let regex = compile(pattern, false).unwrap();
        matches_in(&doc, Path::new("notes.md"), &regex, 0)
    }

    const DOC: &str = "\
# Top

before any subheading

## Deploys

the deploy runbook

### Rollback

roll it back
";

    #[test]
    fn a_match_knows_which_heading_it_is_under() {
        let found = find(DOC, "roll it back");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].heading, "Top > Deploys > Rollback");
        assert_eq!(found[0].anchor.as_deref(), Some("rollback"));
    }

    #[test]
    fn a_match_above_the_first_heading_has_no_breadcrumb() {
        let found = find("no heading here\n", "heading");
        assert_eq!(found[0].heading, "");
        assert_eq!(found[0].anchor, None);
    }

    #[test]
    fn a_match_on_a_headings_own_line_belongs_to_that_heading() {
        // Not to its parent: the breadcrumb names where the match *is*.
        let found = find(DOC, "Deploys");
        assert_eq!(found[0].heading, "Top > Deploys");
    }

    #[test]
    fn a_match_carries_its_line_offset_and_column() {
        let found = find("alpha\nbeta gamma\n", "gamma");
        assert_eq!(found[0].line, 2);
        assert_eq!(found[0].text, "beta gamma");
        assert_eq!(found[0].offset, 11);
        // The span within the line, so the window need not re-search it.
        assert_eq!(found[0].column, 5..10);
        assert_eq!(&found[0].text[found[0].column.clone()], "gamma");
    }

    #[test]
    fn an_empty_match_is_not_a_hit() {
        // `a*` matches at every position. Reporting those is a million-row
        // table nobody asked for.
        assert!(find("bbb\n", "a*").is_empty());
        assert!(find("bbb\n", "").is_empty());
    }

    #[test]
    fn anchors_are_line_anchors_because_this_is_called_grep() {
        let found = find("alpha\nbeta\n", "^beta$");
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn a_match_spanning_a_newline_is_clipped_to_its_first_line() {
        // `column` indexes into `text`, which is one line, so an end past the
        // line's own bounds would panic when the window slices it.
        let found = find("alpha\nbeta\n", "(?s)alpha.beta");
        assert_eq!(found.len(), 1);
        assert!(found[0].column.end <= found[0].text.len());
        assert_eq!(&found[0].text[found[0].column.clone()], "alpha");
    }

    #[test]
    fn case_folding_is_a_choice() {
        let doc = Document::parse("Alpha\n");
        assert!(
            matches_in(
                &doc,
                Path::new("x.md"),
                &compile("alpha", false).unwrap(),
                0
            )
            .is_empty()
        );
        assert_eq!(
            matches_in(&doc, Path::new("x.md"), &compile("alpha", true).unwrap(), 0).len(),
            1
        );
    }

    #[test]
    fn a_limit_stops_early() {
        let doc = Document::parse("x\nx\nx\nx\nx\n");
        let regex = compile("x", false).unwrap();
        assert_eq!(matches_in(&doc, Path::new("x.md"), &regex, 2).len(), 2);
        assert_eq!(matches_in(&doc, Path::new("x.md"), &regex, 0).len(), 5);
    }

    #[test]
    fn a_limit_is_reported_only_when_there_really_was_more() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("many.md"), "hit\n".repeat(20)).unwrap();

        let capped = search(
            dir.path(),
            "hit",
            &Options {
                limit: 5,
                ..Options::default()
            },
        )
        .unwrap();
        assert_eq!(capped.matches.len(), 5);
        assert!(capped.truncated);

        // Exactly as many hits as the cap. Inferring truncation from
        // `len() == limit` would call this truncated, and the window would tell
        // the reader it was showing a prefix of a complete answer.
        let exact = search(
            dir.path(),
            "hit",
            &Options {
                limit: 20,
                ..Options::default()
            },
        )
        .unwrap();
        assert_eq!(exact.matches.len(), 20);
        assert!(!exact.truncated);

        let uncapped = search(dir.path(), "hit", &Options::default()).unwrap();
        assert_eq!(uncapped.matches.len(), 20);
        assert!(!uncapped.truncated);
    }

    #[test]
    fn a_named_file_that_cannot_be_read_is_an_error_but_a_walked_one_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("good.md"), "# Good\n\nvisible\n").unwrap();
        // Invalid UTF-8. Unreadable for our purposes, and needs no chmod to
        // behave the same when the suite runs as root.
        let bad = dir.path().join("bad.md");
        std::fs::write(&bad, b"# Bad\n\nvisible \xff\xfe\n").unwrap();

        // Named: the caller hears about it.
        let error = search(&bad, "visible", &Options::default()).unwrap_err();
        assert!(matches!(error, SearchError::Read { .. }), "{error:?}");

        // Walked: skipped, and the rest of the results survive.
        let results = search(dir.path(), "visible", &Options::default()).unwrap();
        assert_eq!(results.matches.len(), 1);
        assert_eq!(results.files, 1);
    }

    #[test]
    fn a_bad_pattern_is_a_named_error() {
        let error = search(Path::new("."), "(unclosed", &Options::default()).unwrap_err();
        assert!(matches!(error, SearchError::Pattern(_)));
    }
}
