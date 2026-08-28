//! Line-level diffing, for the editor gutter and for `mark diff`.
//!
//! **This is not [`crate::diff`], and the two are not derivable from each
//! other.** `2026-08-28-git-differences-by-running-git`:
//!
//! > The core carries two diff granularities, and they are not
//! > interchangeable. `core/src/diff.rs`'s block diff drives the rendered
//! > display; a new line diff drives the editor gutter, `mark diff`, and the
//! > added-line count for untracked files.
//!
//! The block diff answers "which rendered blocks moved", which is what ADR-2's
//! DOM patcher needs and what a rendered diff view shows. It cannot put a bar
//! against line 41, because a block spans many lines and its identity is a
//! content hash rather than a position. That is the whole reason this module
//! exists, and confusing the two is the likeliest maintenance error in this
//! area — hence the same warning at the top of both files.
//!
//! # Algorithm, and why it is the boring one
//!
//! Hash lines, trim the common prefix and suffix, then LCS by dynamic
//! programming over what is left, then coalesce the edit script into hunks.
//!
//! Myers' `O(ND)` algorithm is the usual answer and is rejected here on memory
//! rather than time: recording the trace needed to backtrack costs
//! `O(D × (N+M))`, which for a 2,000-line changed region is hundreds of
//! megabytes. The linear-space divide-and-conquer variant fixes that and is
//! four times the code. Neither is worth it, because **trimming does the real
//! work**: a 119,000-line document with one edited line trims to a region of
//! one line on each side. The pathological case that survives trimming is two
//! genuinely unrelated documents, and the honest answer there is not a
//! finer diff — it is [`LineDiff::coarse`], "all of it changed".
//!
//! [`BUDGET`] is where that judgment is written down.

use std::collections::HashMap;
use std::ops::Range;

use serde::Serialize;

use crate::block::content_hash;

/// Largest LCS table we will build, in cells. 1,000,000 cells is 4 MB at
/// `u32`, and allows a changed region of 1,000 × 1,000 lines — far past
/// anything a note produces once the prefix and suffix are trimmed off.
///
/// Beyond it, [`diff`] returns one coarse hunk rather than allocating. ADR-2
/// made the same call for the block diff, and for the same reason: the 8 MB /
/// 119k-line document is a known ceiling, and the failure mode has to be a
/// worse answer rather than a hang.
const BUDGET: usize = 1_000_000;

/// Lines in `text`.
///
/// A trailing newline does not open a new line: `"a\nb\n"` is two lines, and
/// so is `"a\nb"`. That matches what every editor's status bar says, and it is
/// what makes an untracked file's `+N` equal the number a reader counts.
#[must_use]
pub fn count(text: &str) -> usize {
    if text.is_empty() {
        return 0;
    }
    let newlines = text.bytes().filter(|b| *b == b'\n').count();
    if text.ends_with('\n') {
        newlines
    } else {
        newlines + 1
    }
}

/// What happened to a run of lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HunkKind {
    /// Lines exist in the new document and not in the old.
    Added,
    /// Lines existed in the old document and are gone. Its `new` range is
    /// **empty**, and marks where the removal happened.
    Removed,
    /// Lines were replaced: both ranges are non-empty.
    Changed,
}

/// One run of changed lines.
///
/// Ranges are half-open and **zero-based**, because every other offset in this
/// core is (`data-mk-start`, `Block::range`, `Task::start`). A gutter that
/// wants to print "42" adds one at the point of display, which is the only
/// place that convention belongs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Hunk {
    /// Lines in the old document. Empty for [`HunkKind::Added`].
    pub old: Range<u32>,
    /// Lines in the new document. Empty for [`HunkKind::Removed`].
    pub new: Range<u32>,
    /// Byte range of `new` in the new document, so the editor can reach
    /// `NSTextStorage` through the `SourceOffsets` walk it already does rather
    /// than counting newlines a second time in Swift.
    ///
    /// For [`HunkKind::Removed`] this is the empty range at the insertion
    /// point, which is where a gutter draws the marker.
    #[serde(rename = "newBytes")]
    pub new_bytes: Range<u32>,
    pub kind: HunkKind,
}

/// A line diff of two documents.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LineDiff {
    pub hunks: Vec<Hunk>,
    /// Lines the new document has and the old did not.
    pub added: u32,
    /// Lines the old document had and the new does not.
    pub removed: u32,
    /// The changed region was past [`BUDGET`], so `hunks` is one span covering
    /// everything that is not common prefix or suffix. The counts are still
    /// exact.
    pub coarse: bool,
}

/// Diff `old` against `new`, by line.
#[must_use]
pub fn diff(old: &str, new: &str) -> LineDiff {
    let old_lines = split(old);
    let new_lines = split(new);
    let old_hashes: Vec<u64> = old_lines
        .iter()
        .map(|l| content_hash(l.as_bytes()))
        .collect();
    let new_hashes: Vec<u64> = new_lines
        .iter()
        .map(|l| content_hash(l.as_bytes()))
        .collect();

    // Byte offset of the start of each new line, plus a terminal entry, so a
    // hunk's byte range is two lookups rather than a scan.
    let new_offsets = offsets(new, &new_lines);

    // Trimming is what makes the table affordable. Hashes only — two lines with
    // the same hash and different bytes would be a 2^-64 event, and the block
    // diff already accepts the same risk for the same reason.
    let mut prefix = 0;
    while prefix < old_hashes.len()
        && prefix < new_hashes.len()
        && old_hashes[prefix] == new_hashes[prefix]
    {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < old_hashes.len() - prefix
        && suffix < new_hashes.len() - prefix
        && old_hashes[old_hashes.len() - 1 - suffix] == new_hashes[new_hashes.len() - 1 - suffix]
    {
        suffix += 1;
    }

    let old_mid = prefix..old_hashes.len() - suffix;
    let new_mid = prefix..new_hashes.len() - suffix;
    let old_len = old_mid.len();
    let new_len = new_mid.len();

    if old_len == 0 && new_len == 0 {
        return LineDiff {
            hunks: Vec::new(),
            added: 0,
            removed: 0,
            coarse: false,
        };
    }

    // One side empty is a pure insert or a pure delete, and needs no table.
    if old_len == 0 || new_len == 0 {
        let kind = if old_len == 0 {
            HunkKind::Added
        } else {
            HunkKind::Removed
        };
        return LineDiff {
            hunks: vec![Hunk {
                old: to_u32(old_mid.clone()),
                new: to_u32(new_mid.clone()),
                new_bytes: byte_range(&new_offsets, &new_mid),
                kind,
            }],
            added: u32::try_from(new_len).unwrap_or(u32::MAX),
            removed: u32::try_from(old_len).unwrap_or(u32::MAX),
            coarse: false,
        };
    }

    if old_len.saturating_add(1).saturating_mul(new_len + 1) > BUDGET {
        return LineDiff {
            hunks: vec![Hunk {
                old: to_u32(old_mid.clone()),
                new: to_u32(new_mid.clone()),
                new_bytes: byte_range(&new_offsets, &new_mid),
                kind: HunkKind::Changed,
            }],
            added: u32::try_from(new_len).unwrap_or(u32::MAX),
            removed: u32::try_from(old_len).unwrap_or(u32::MAX),
            coarse: true,
        };
    }

    let script = lcs_script(&old_hashes[old_mid.clone()], &new_hashes[new_mid.clone()]);
    let (hunks, added, removed) = coalesce(&script, prefix, &new_offsets);

    LineDiff {
        hunks,
        added,
        removed,
        coarse: false,
    }
}

/// Split into lines without allocating them, and **without** a phantom empty
/// line after a trailing newline. `str::lines` already does this; it is spelled
/// out because [`count`] has to agree with it exactly.
fn split(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    text.lines().collect()
}

/// Byte offset where each line starts, with a terminal entry equal to the
/// document length. `lines()` strips the terminator, so the offsets are
/// recovered by walking rather than by summing lengths.
fn offsets(text: &str, lines: &[&str]) -> Vec<u32> {
    let mut out = Vec::with_capacity(lines.len() + 1);
    let mut at = 0usize;
    for line in lines {
        out.push(u32::try_from(at).unwrap_or(u32::MAX));
        at += line.len();
        // Step over whichever terminator was there, or stop at the end.
        if text[at..].starts_with("\r\n") {
            at += 2;
        } else if text[at..].starts_with('\n') {
            at += 1;
        }
    }
    out.push(u32::try_from(text.len()).unwrap_or(u32::MAX));
    out
}

fn byte_range(offsets: &[u32], lines: &Range<usize>) -> Range<u32> {
    let start = offsets
        .get(lines.start)
        .copied()
        .unwrap_or(offsets.last().copied().unwrap_or(0));
    let end = offsets
        .get(lines.end)
        .copied()
        .unwrap_or(offsets.last().copied().unwrap_or(0));
    start..end.max(start)
}

fn to_u32(range: Range<usize>) -> Range<u32> {
    let start = u32::try_from(range.start).unwrap_or(u32::MAX);
    let end = u32::try_from(range.end).unwrap_or(u32::MAX);
    start..end.max(start)
}

/// One step of the edit script, in old-then-new traversal order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Keep,
    Delete,
    Insert,
}

/// LCS by dynamic programming, then backtracked into a script.
///
/// Guarded by [`BUDGET`] at the only call site, so the table allocation here is
/// bounded before it is reached.
fn lcs_script(old: &[u64], new: &[u64]) -> Vec<Step> {
    let n = old.len();
    let m = new.len();
    let width = m + 1;
    // Length of the LCS of `old[i..]` and `new[j..]`, filled from the end so
    // the backtrack runs forwards and produces the script in traversal order.
    let mut table = vec![0u32; (n + 1) * width];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i * width + j] = if old[i] == new[j] {
                table[(i + 1) * width + (j + 1)] + 1
            } else {
                table[(i + 1) * width + j].max(table[i * width + (j + 1)])
            };
        }
    }

    let mut script = Vec::with_capacity(n + m);
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if old[i] == new[j] {
            script.push(Step::Keep);
            i += 1;
            j += 1;
        } else if table[(i + 1) * width + j] >= table[i * width + (j + 1)] {
            script.push(Step::Delete);
            i += 1;
        } else {
            script.push(Step::Insert);
            j += 1;
        }
    }
    script.extend(std::iter::repeat_n(Step::Delete, n - i));
    script.extend(std::iter::repeat_n(Step::Insert, m - j));
    script
}

/// Turn a step script into hunks, merging an adjacent delete run and insert run
/// into one [`HunkKind::Changed`] — which is what a reader means by "this line
/// changed", and what a gutter draws as one bar rather than two.
fn coalesce(script: &[Step], prefix: usize, new_offsets: &[u32]) -> (Vec<Hunk>, u32, u32) {
    let mut hunks = Vec::new();
    let mut added = 0u32;
    let mut removed = 0u32;
    let mut old_at = prefix;
    let mut new_at = prefix;
    let mut index = 0;

    while index < script.len() {
        match script[index] {
            Step::Keep => {
                old_at += 1;
                new_at += 1;
                index += 1;
            }
            _ => {
                let old_start = old_at;
                let new_start = new_at;
                // One run covers every consecutive delete *and* insert, in
                // whichever order the script produced them.
                while index < script.len() && script[index] != Step::Keep {
                    match script[index] {
                        Step::Delete => old_at += 1,
                        Step::Insert => new_at += 1,
                        Step::Keep => unreachable!("guarded by the loop condition"),
                    }
                    index += 1;
                }
                let old_run = old_start..old_at;
                let new_run = new_start..new_at;
                removed += u32::try_from(old_run.len()).unwrap_or(0);
                added += u32::try_from(new_run.len()).unwrap_or(0);
                let kind = match (old_run.is_empty(), new_run.is_empty()) {
                    (true, false) => HunkKind::Added,
                    (false, true) => HunkKind::Removed,
                    _ => HunkKind::Changed,
                };
                hunks.push(Hunk {
                    old: to_u32(old_run),
                    new: to_u32(new_run.clone()),
                    new_bytes: byte_range(new_offsets, &new_run),
                    kind,
                });
            }
        }
    }

    (hunks, added, removed)
}

/// Apply `hunks` to `old`'s lines, for the property test in
/// `core/tests/lines_diff.rs`.
///
/// This is the executable form of the property that matters — *applying the
/// hunks to the old lines yields the new lines* — and it is the twin of
/// [`crate::diff::EditScript::apply`], which ADR-2 required for exactly the
/// same reason: a diff bug here does not crash, it draws a bar in the wrong
/// place or counts the wrong number, which nobody notices.
///
/// Returns `None` for a [`LineDiff::coarse`] result, which by construction does
/// not describe the edit precisely enough to replay.
#[must_use]
pub fn apply(diff: &LineDiff, old: &str, new: &str) -> Option<Vec<String>> {
    if diff.coarse {
        return None;
    }
    let old_lines = split(old);
    let new_lines = split(new);

    let mut out: Vec<String> = Vec::new();
    let mut old_at = 0usize;
    for hunk in &diff.hunks {
        let until = hunk.old.start as usize;
        if until < old_at || until > old_lines.len() {
            return None;
        }
        out.extend(old_lines[old_at..until].iter().map(|l| (*l).to_owned()));
        let new_range = hunk.new.start as usize..hunk.new.end as usize;
        if new_range.end > new_lines.len() {
            return None;
        }
        out.extend(new_lines[new_range].iter().map(|l| (*l).to_owned()));
        old_at = hunk.old.end as usize;
    }
    if old_at > old_lines.len() {
        return None;
    }
    out.extend(old_lines[old_at..].iter().map(|l| (*l).to_owned()));
    Some(out)
}

/// Which lines in the *new* document a caller should mark, flattened.
///
/// The gutter wants this rather than the hunks: `NSRulerView` draws per line,
/// and asking "is line 41 changed" of a hunk list is a search the ruler would
/// repeat for every visible line on every redraw.
#[must_use]
pub fn marks(diff: &LineDiff) -> HashMap<u32, HunkKind> {
    let mut out = HashMap::new();
    for hunk in &diff.hunks {
        if hunk.new.is_empty() {
            // A removal has no line of its own. Mark the line it sits in front
            // of, so the gutter has somewhere to draw; at end of document that
            // is one past the last line and the ruler clamps it.
            out.entry(hunk.new.start).or_insert(HunkKind::Removed);
        } else {
            for line in hunk.new.clone() {
                out.insert(line, hunk.kind);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counting_agrees_with_what_a_reader_counts() {
        assert_eq!(count(""), 0);
        assert_eq!(count("a"), 1);
        assert_eq!(count("a\n"), 1, "a trailing newline does not open a line");
        assert_eq!(count("a\nb"), 2);
        assert_eq!(count("a\nb\n"), 2);
        assert_eq!(count("\n"), 1);
        assert_eq!(count("\n\n"), 2);
    }

    #[test]
    fn an_identical_document_has_no_hunks() {
        let diff = diff("a\nb\nc\n", "a\nb\nc\n");
        assert!(diff.hunks.is_empty());
        assert_eq!((diff.added, diff.removed), (0, 0));
        assert!(!diff.coarse);
    }

    #[test]
    fn one_changed_line_is_one_changed_hunk() {
        let diff = diff("a\nb\nc\n", "a\nZ\nc\n");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!(diff.hunks[0].kind, HunkKind::Changed);
        assert_eq!(diff.hunks[0].old, 1..2);
        assert_eq!(diff.hunks[0].new, 1..2);
        assert_eq!((diff.added, diff.removed), (1, 1));
    }

    #[test]
    fn a_pure_insertion_is_added_with_an_empty_old_range() {
        let diff = diff("a\nc\n", "a\nb\nc\n");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!(diff.hunks[0].kind, HunkKind::Added);
        assert!(diff.hunks[0].old.is_empty());
        assert_eq!(diff.hunks[0].new, 1..2);
        assert_eq!((diff.added, diff.removed), (1, 0));
    }

    #[test]
    fn a_pure_deletion_is_removed_with_an_empty_new_range() {
        let diff = diff("a\nb\nc\n", "a\nc\n");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!(diff.hunks[0].kind, HunkKind::Removed);
        assert_eq!(diff.hunks[0].old, 1..2);
        assert!(diff.hunks[0].new.is_empty());
        assert_eq!((diff.added, diff.removed), (0, 1));
    }

    #[test]
    fn byte_ranges_point_at_the_new_lines() {
        let new = "alpha\nbeta\ngamma\n";
        let diff = diff("alpha\nbeta\n", new);
        let hunk = &diff.hunks[0];
        let span = &new[hunk.new_bytes.start as usize..hunk.new_bytes.end as usize];
        assert_eq!(span, "gamma\n");
    }

    #[test]
    fn byte_ranges_are_utf8_offsets_not_character_counts() {
        // The core speaks UTF-8 byte offsets everywhere (ADR-1), and the editor
        // converts once. An emoji before the change must move the offset.
        let new = "🎉 party\nsecond\n";
        let diff = diff("🎉 party\n", new);
        let hunk = &diff.hunks[0];
        assert_eq!(
            &new[hunk.new_bytes.start as usize..hunk.new_bytes.end as usize],
            "second\n"
        );
    }

    #[test]
    fn from_empty_to_content_is_all_added() {
        let diff = diff("", "a\nb\n");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!(diff.hunks[0].kind, HunkKind::Added);
        assert_eq!((diff.added, diff.removed), (2, 0));
    }

    #[test]
    fn to_empty_from_content_is_all_removed() {
        let diff = diff("a\nb\n", "");
        assert_eq!(diff.hunks[0].kind, HunkKind::Removed);
        assert_eq!((diff.added, diff.removed), (0, 2));
    }

    #[test]
    fn two_separate_edits_are_two_hunks() {
        let diff = diff("a\nb\nc\nd\ne\n", "a\nB\nc\nd\nE\n");
        assert_eq!(diff.hunks.len(), 2);
        assert_eq!(diff.hunks[0].new, 1..2);
        assert_eq!(diff.hunks[1].new, 4..5);
    }

    #[test]
    fn a_delete_and_insert_touching_become_one_changed_hunk() {
        // Not two hunks: a reader sees one edit, and a gutter should draw one
        // bar.
        let diff = diff("a\nold1\nold2\nz\n", "a\nnew1\nnew2\nnew3\nz\n");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!(diff.hunks[0].kind, HunkKind::Changed);
        assert_eq!(diff.hunks[0].old, 1..3);
        assert_eq!(diff.hunks[0].new, 1..4);
        assert_eq!((diff.added, diff.removed), (3, 2));
    }

    #[test]
    fn a_huge_unrelated_pair_goes_coarse_rather_than_allocating() {
        let old: String = (0..2000).map(|i| format!("old line {i}\n")).collect();
        let new: String = (0..2000).map(|i| format!("new line {i}\n")).collect();
        let diff = diff(&old, &new);
        assert!(diff.coarse, "2000x2000 is past BUDGET");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!((diff.added, diff.removed), (2000, 2000));
        assert!(apply(&diff, &old, &new).is_none(), "coarse cannot replay");
    }

    #[test]
    fn trimming_keeps_a_huge_document_with_one_edit_precise() {
        // The case that makes the boring algorithm the right one: 60,000 lines,
        // one edit, and the table never sees more than a couple of rows.
        let mut old = String::new();
        let mut new = String::new();
        for i in 0..60_000 {
            old.push_str(&format!("line {i}\n"));
            if i == 30_000 {
                new.push_str("EDITED\n");
            } else {
                new.push_str(&format!("line {i}\n"));
            }
        }
        let diff = diff(&old, &new);
        assert!(!diff.coarse, "trimming should have made this precise");
        assert_eq!(diff.hunks.len(), 1);
        assert_eq!(diff.hunks[0].new, 30_000..30_001);
    }

    #[test]
    fn applying_the_hunks_reproduces_the_new_document() {
        for (old, new) in [
            ("a\nb\nc\n", "a\nZ\nc\n"),
            ("a\nc\n", "a\nb\nc\n"),
            ("a\nb\nc\n", "a\nc\n"),
            ("", "x\n"),
            ("x\n", ""),
            ("a\nb\nc\nd\ne\n", "e\nd\nc\nb\na\n"),
            ("same\n", "same\n"),
        ] {
            let diff = diff(old, new);
            let replayed = apply(&diff, old, new).expect("not coarse");
            assert_eq!(
                replayed,
                split(new)
                    .iter()
                    .map(|l| (*l).to_owned())
                    .collect::<Vec<_>>(),
                "old={old:?} new={new:?}"
            );
        }
    }

    #[test]
    fn marks_give_the_gutter_one_entry_per_line() {
        let diff = diff("a\nb\nc\n", "a\nB\nC\n");
        let marks = marks(&diff);
        assert_eq!(marks.get(&1), Some(&HunkKind::Changed));
        assert_eq!(marks.get(&2), Some(&HunkKind::Changed));
        assert_eq!(marks.get(&0), None, "the unchanged first line is unmarked");
    }

    #[test]
    fn a_removal_marks_the_line_it_sits_in_front_of() {
        let diff = diff("a\nb\nc\n", "a\nc\n");
        let marks = marks(&diff);
        assert_eq!(marks.get(&1), Some(&HunkKind::Removed));
    }

    #[test]
    fn crlf_lines_get_correct_byte_ranges() {
        let new = "a\r\nb\r\nc\r\n";
        let diff = diff("a\r\nc\r\n", new);
        let hunk = &diff.hunks[0];
        assert_eq!(
            &new[hunk.new_bytes.start as usize..hunk.new_bytes.end as usize],
            "b\r\n"
        );
    }
}
