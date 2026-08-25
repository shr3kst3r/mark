//! Two block-hash sequences → a minimal edit script.
//!
//! This is the mechanism ADR-2 (`2026-08-24-progressive-document-rendering`)
//! names outright:
//!
//! > On a file change the core re-parses, diffs the block-hash sequence, and
//! > emits a minimal edit script; the shell patches only the affected blocks by
//! > `data-blk` and leaves every other DOM node untouched.
//!
//! The same ADR records what makes this dangerous: a diff bug does not crash,
//! it leaves a subtly stale or duplicated document. So the module is built
//! around one property, and everything else is in service of it:
//!
//! > **Applying an [`EditScript`] to the old block list yields exactly the new
//! > block list.**
//!
//! [`EditScript::apply`] is that property made executable — it is the Rust twin
//! of what the shell's JavaScript does to the DOM, and it is what the property
//! tests in `core/tests/diff_apply.rs` assert against random document pairs.
//!
//! # Shape of the script
//!
//! Ops are a complete left-to-right traversal of the *old* sequence: every old
//! block is covered by exactly one [`Op`], and the ops' `old_index` /
//! `new_index` fields are checked on apply, so a script that has drifted out of
//! alignment fails loudly instead of producing a plausible-looking wrong
//! document.
//!
//! [`Op::Insert`] carries `before`: the `data-blk` of the old block it goes in
//! front of, or `null` to append. The shell therefore never has to convert an
//! index into a DOM position — which it could not do reliably anyway, since it
//! is mid-patch and the indices have already moved.
//!
//! [`Op::Insert`] and [`Op::Replace`] also carry the rendered HTML of the
//! blocks they introduce, when the script was built by [`diff_documents`].
//! Making the shell fetch that separately would mean one re-parse of the whole
//! document per changed run.
//!
//! # Algorithm
//!
//! Common prefix and suffix are trimmed first — a one-block edit in a 4,000
//! block document leaves a middle of one — and the middle goes through Myers'
//! greedy diff, which costs O((N+M)·D) in the *actual* edit distance rather
//! than in document size.
//!
//! `D` is capped at [`MAX_EDIT_DISTANCE`]. Past that the differing middle is
//! replaced wholesale and [`EditScript::coarse`] is set: still correct, no
//! longer minimal. The cap exists because ADR-6
//! (`2026-08-24-editing-pane-and-autosave`) will run this at typing cadence
//! behind an 800 ms debounce, and an unbounded search on two documents with
//! nothing in common is the one input that could blow that budget.

use std::fmt;
use std::ops::Range;

use serde::Serialize;

use crate::block::{Block, BlockId};
use crate::parse::Document;
use crate::render;

/// The largest edit distance Myers' search will explore before giving up and
/// replacing the differing middle wholesale.
///
/// Memory is O(D²) `isize`s and time O((N+M)·D), so 512 is ~2 MB and a few
/// million comparisons in the worst case — and the worst case only happens for
/// two documents that share almost nothing, where "replace the middle" is the
/// answer a minimal diff would converge on anyway.
pub const MAX_EDIT_DISTANCE: usize = 512;

/// One instruction in the edit script.
///
/// Serialized with an `"op"` tag, which is how the shell dispatches:
/// `{"op":"keep","old_index":0,"new_index":0,"count":12}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Op {
    /// `count` blocks are unchanged. The shell touches nothing — this is the
    /// op that makes already-rendered MathML and diagram SVG survive a
    /// re-render (ADR-2's "node-preserving patches").
    Keep {
        old_index: usize,
        new_index: usize,
        count: usize,
    },
    /// Remove the elements with these `data-blk` values.
    Delete {
        old_index: usize,
        new_index: usize,
        old_ids: Vec<BlockId>,
    },
    /// Insert these blocks before the element with `data-blk` = `before`, or
    /// append them when `before` is `null`.
    Insert {
        old_index: usize,
        new_index: usize,
        before: Option<BlockId>,
        new_ids: Vec<BlockId>,
        #[serde(skip_serializing_if = "Option::is_none")]
        html: Option<String>,
    },
    /// Swap `old_ids` for `new_ids` in place, one for one and in order. Always
    /// the same length on both sides.
    Replace {
        old_index: usize,
        new_index: usize,
        old_ids: Vec<BlockId>,
        new_ids: Vec<BlockId>,
        #[serde(skip_serializing_if = "Option::is_none")]
        html: Option<String>,
    },
}

impl Op {
    /// How many blocks of the old sequence this op consumes.
    #[must_use]
    pub fn old_len(&self) -> usize {
        match self {
            Op::Keep { count, .. } => *count,
            Op::Delete { old_ids, .. } | Op::Replace { old_ids, .. } => old_ids.len(),
            Op::Insert { .. } => 0,
        }
    }

    /// How many blocks of the new sequence this op produces.
    #[must_use]
    pub fn new_len(&self) -> usize {
        match self {
            Op::Keep { count, .. } => *count,
            Op::Insert { new_ids, .. } | Op::Replace { new_ids, .. } => new_ids.len(),
            Op::Delete { .. } => 0,
        }
    }

    /// Where this op starts in the old sequence.
    #[must_use]
    pub fn old_index(&self) -> usize {
        match self {
            Op::Keep { old_index, .. }
            | Op::Delete { old_index, .. }
            | Op::Insert { old_index, .. }
            | Op::Replace { old_index, .. } => *old_index,
        }
    }

    /// Where this op starts in the new sequence.
    #[must_use]
    pub fn new_index(&self) -> usize {
        match self {
            Op::Keep { new_index, .. }
            | Op::Delete { new_index, .. }
            | Op::Insert { new_index, .. }
            | Op::Replace { new_index, .. } => *new_index,
        }
    }

    /// The name used in the JSON `"op"` field, for logs and assertions.
    #[must_use]
    pub fn tag(&self) -> &'static str {
        match self {
            Op::Keep { .. } => "keep",
            Op::Delete { .. } => "delete",
            Op::Insert { .. } => "insert",
            Op::Replace { .. } => "replace",
        }
    }

    /// The range of the new block list whose HTML this op needs, if any.
    fn html_range(&self) -> Option<Range<usize>> {
        match self {
            Op::Insert {
                new_index, new_ids, ..
            }
            | Op::Replace {
                new_index, new_ids, ..
            } => Some(*new_index..*new_index + new_ids.len()),
            Op::Keep { .. } | Op::Delete { .. } => None,
        }
    }
}

/// A minimal edit script turning one block sequence into another.
///
/// The counters are not decoration: they are what the shell logs per patch, so
/// "the document flickered" can be answered from telemetry rather than from a
/// reproduction. `kept + deleted + replaced == old_blocks` and
/// `kept + inserted + replaced == new_blocks` always hold.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EditScript {
    pub ops: Vec<Op>,
    pub old_blocks: usize,
    pub new_blocks: usize,
    pub kept: usize,
    pub inserted: usize,
    pub deleted: usize,
    pub replaced: usize,
    /// The edit distance exceeded [`MAX_EDIT_DISTANCE`] and the differing
    /// middle was replaced wholesale. Correct, but not minimal — worth a log
    /// line, because a patch that is always coarse means the diff is not
    /// earning its keep.
    pub coarse: bool,
}

impl EditScript {
    /// True when nothing changed: the shell can skip the patch entirely.
    #[must_use]
    pub fn is_noop(&self) -> bool {
        self.inserted == 0 && self.deleted == 0 && self.replaced == 0
    }

    /// Apply this script to `old`, yielding what the new block sequence must
    /// be.
    ///
    /// The correctness property ADR-2 rests on, executable. It is deliberately
    /// strict — every id a [`Op::Delete`] or [`Op::Replace`] names is checked
    /// against the block actually sitting there, and the indices are checked
    /// too — because the alternative to failing here is a silently wrong
    /// document, which is the exact failure mode the ADR calls out.
    ///
    /// [`Op::Keep`] is the one exception: it carries a count and no ids, and is
    /// checked by length alone. Carrying every kept id would make the
    /// unchanged-document case — by far the most common one — the largest
    /// payload in the script.
    ///
    /// # Errors
    /// [`ApplyError`] when the script does not describe `old`.
    pub fn apply(&self, old: &[BlockId]) -> Result<Vec<BlockId>, ApplyError> {
        let mut out: Vec<BlockId> = Vec::with_capacity(self.new_blocks);
        let mut cursor = 0usize;

        for (op_index, op) in self.ops.iter().enumerate() {
            if op.old_index() != cursor || op.new_index() != out.len() {
                return Err(ApplyError::Misaligned {
                    op: op_index,
                    tag: op.tag(),
                    old_index: op.old_index(),
                    new_index: op.new_index(),
                    at_old: cursor,
                    at_new: out.len(),
                });
            }
            let consumed = op.old_len();
            if cursor + consumed > old.len() {
                return Err(ApplyError::OutOfRange {
                    op: op_index,
                    tag: op.tag(),
                    need: cursor + consumed,
                    have: old.len(),
                });
            }

            match op {
                Op::Keep { count, .. } => {
                    out.extend_from_slice(&old[cursor..cursor + count]);
                }
                Op::Delete { old_ids, .. } => {
                    check_ids(op_index, op.tag(), cursor, old, old_ids)?;
                }
                Op::Insert { new_ids, .. } => {
                    out.extend(new_ids.iter().cloned());
                }
                Op::Replace {
                    old_ids, new_ids, ..
                } => {
                    check_ids(op_index, op.tag(), cursor, old, old_ids)?;
                    out.extend(new_ids.iter().cloned());
                }
            }
            cursor += consumed;
        }

        if cursor != old.len() {
            return Err(ApplyError::Trailing {
                consumed: cursor,
                have: old.len(),
            });
        }
        Ok(out)
    }
}

fn check_ids(
    op: usize,
    tag: &'static str,
    cursor: usize,
    old: &[BlockId],
    ids: &[BlockId],
) -> Result<(), ApplyError> {
    for (offset, id) in ids.iter().enumerate() {
        let found = &old[cursor + offset];
        if found != id {
            return Err(ApplyError::Mismatch {
                op,
                tag,
                at: cursor + offset,
                expected: id.clone(),
                found: found.clone(),
            });
        }
    }
    Ok(())
}

/// Why an edit script could not be applied. Every variant means "the script
/// does not describe this document", never "the document is malformed".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyError {
    /// An op claims to start somewhere other than where the walk has reached.
    Misaligned {
        op: usize,
        tag: &'static str,
        old_index: usize,
        new_index: usize,
        at_old: usize,
        at_new: usize,
    },
    /// An op reaches past the end of the old sequence.
    OutOfRange {
        op: usize,
        tag: &'static str,
        need: usize,
        have: usize,
    },
    /// The block at an op's position is not the one the script named.
    Mismatch {
        op: usize,
        tag: &'static str,
        at: usize,
        expected: BlockId,
        found: BlockId,
    },
    /// The ops ran out before the old sequence did.
    Trailing { consumed: usize, have: usize },
}

impl fmt::Display for ApplyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApplyError::Misaligned {
                op,
                tag,
                old_index,
                new_index,
                at_old,
                at_new,
            } => write!(
                f,
                "op {op} ({tag}) claims old {old_index} / new {new_index}, \
                 but the walk is at old {at_old} / new {at_new}"
            ),
            ApplyError::OutOfRange {
                op,
                tag,
                need,
                have,
            } => write!(
                f,
                "op {op} ({tag}) needs {need} old blocks, but there are {have}"
            ),
            ApplyError::Mismatch {
                op,
                tag,
                at,
                expected,
                found,
            } => write!(
                f,
                "op {op} ({tag}) expected block {expected} at index {at}, found {found}"
            ),
            ApplyError::Trailing { consumed, have } => write!(
                f,
                "the script covers {consumed} old blocks, but there are {have}"
            ),
        }
    }
}

impl std::error::Error for ApplyError {}

/// Diff two parsed documents and attach the rendered HTML of every block the
/// new document introduces.
///
/// This is what the C ABI's `mark_diff_json` calls, and what the shell
/// consumes: one call, one parse of each side, everything needed to patch.
///
/// The theme is a parameter because the attached HTML is themed HTML: an
/// inserted code block has to arrive in the same slot classes as the blocks
/// around it, and an inserted diagram in the same palette.
#[must_use]
pub fn diff_documents(
    old: &Document<'_>,
    new: &Document<'_>,
    theme: &std::sync::Arc<crate::theme::ThemePair>,
) -> EditScript {
    let mut script = diff(old.blocks(), new.blocks());
    attach_html(&mut script, new, theme);
    script
}

/// Diff two block lists. The script carries no HTML; see [`diff_documents`].
#[must_use]
pub fn diff(old: &[Block], new: &[Block]) -> EditScript {
    let old_ids: Vec<BlockId> = old.iter().map(|block| block.id.clone()).collect();
    let new_ids: Vec<BlockId> = new.iter().map(|block| block.id.clone()).collect();
    diff_ids(&old_ids, &new_ids)
}

/// Diff two block-id sequences directly.
///
/// The identity-level entry point, which is the level the property tests work
/// at: everything below here treats an id as an opaque token, so a change to
/// how ids are *derived* cannot quietly change how they are *diffed*.
#[must_use]
pub fn diff_ids(old: &[BlockId], new: &[BlockId]) -> EditScript {
    let (runs, coarse) = edit_runs(old, new, MAX_EDIT_DISTANCE);
    let ops = merge_adjacent(ops_from_runs(old, new, &runs));

    let mut script = EditScript {
        ops,
        old_blocks: old.len(),
        new_blocks: new.len(),
        kept: 0,
        inserted: 0,
        deleted: 0,
        replaced: 0,
        coarse,
    };
    for op in &script.ops {
        match op {
            Op::Keep { count, .. } => script.kept += count,
            Op::Delete { old_ids, .. } => script.deleted += old_ids.len(),
            Op::Insert { new_ids, .. } => script.inserted += new_ids.len(),
            Op::Replace { new_ids, .. } => script.replaced += new_ids.len(),
        }
    }
    script
}

fn attach_html(
    script: &mut EditScript,
    new: &Document<'_>,
    theme: &std::sync::Arc<crate::theme::ThemePair>,
) {
    let ranges: Vec<Range<usize>> = script.ops.iter().filter_map(Op::html_range).collect();
    if ranges.is_empty() {
        return;
    }
    let mut rendered = render::render_ranges(new, &ranges, theme).into_iter();
    for op in &mut script.ops {
        let (Op::Insert { html, .. } | Op::Replace { html, .. }) = op else {
            continue;
        };
        // Same filter, same order, so this cannot desynchronize — but if it
        // ever did, leaving `html` as `None` is a visible hole rather than
        // HTML from the wrong block.
        if let Some(part) = rendered.next() {
            *html = Some(part.html);
        }
    }
}

/// A run of consecutive identical edit operations, in old/new order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Run {
    Keep(usize),
    Delete(usize),
    Insert(usize),
}

/// Trim the common prefix and suffix, diff the middle, and stitch the three
/// parts back together.
fn edit_runs(old: &[BlockId], new: &[BlockId], budget: usize) -> (Vec<Run>, bool) {
    let mut head = 0usize;
    while head < old.len() && head < new.len() && old[head] == new[head] {
        head += 1;
    }
    let mut tail = 0usize;
    while tail < old.len() - head
        && tail < new.len() - head
        && old[old.len() - 1 - tail] == new[new.len() - 1 - tail]
    {
        tail += 1;
    }

    let middle_old = &old[head..old.len() - tail];
    let middle_new = &new[head..new.len() - tail];

    let (middle, coarse) = match myers(middle_old, middle_new, budget) {
        Some(runs) => (runs, false),
        None => {
            let mut runs = Vec::with_capacity(2);
            if !middle_old.is_empty() {
                runs.push(Run::Delete(middle_old.len()));
            }
            if !middle_new.is_empty() {
                runs.push(Run::Insert(middle_new.len()));
            }
            (runs, true)
        }
    };

    let mut runs = Vec::with_capacity(middle.len() + 2);
    if head > 0 {
        runs.push(Run::Keep(head));
    }
    runs.extend(middle);
    if tail > 0 {
        runs.push(Run::Keep(tail));
    }
    (runs, coarse)
}

/// Myers' greedy shortest-edit-script search, capped at `budget`.
///
/// Returns `None` when the edit distance exceeds the cap, which the caller
/// turns into a wholesale replacement. The trace stores only the `-d..=d`
/// window of the frontier per round rather than the whole array, so memory is
/// O(D²) rather than O(D·(N+M)) — at D = 512 that is the difference between
/// 2 MB and 65 MB on a 1 MB document.
fn myers(old: &[BlockId], new: &[BlockId], budget: usize) -> Option<Vec<Run>> {
    let n = old.len();
    let m = new.len();
    if n == 0 && m == 0 {
        return Some(Vec::new());
    }
    if n == 0 {
        return Some(vec![Run::Insert(m)]);
    }
    if m == 0 {
        return Some(vec![Run::Delete(n)]);
    }

    let max = n + m;
    let limit = budget.min(max);
    let offset = max as isize;
    // Frontier: furthest `x` reached on each diagonal `k = x - y`.
    let mut frontier = vec![0isize; 2 * max + 1];
    let mut trace: Vec<Vec<isize>> = Vec::with_capacity(limit + 1);
    let mut distance: Option<usize> = None;

    'search: for d in 0..=limit {
        let d_signed = d as isize;
        trace.push(frontier[(offset - d_signed) as usize..=(offset + d_signed) as usize].to_vec());

        let mut k = -d_signed;
        while k <= d_signed {
            let down = k == -d_signed
                || (k != d_signed
                    && frontier[(k - 1 + offset) as usize] < frontier[(k + 1 + offset) as usize]);
            let mut x = if down {
                frontier[(k + 1 + offset) as usize]
            } else {
                frontier[(k - 1 + offset) as usize] + 1
            };
            let mut y = x - k;
            while (x as usize) < n && (y as usize) < m && old[x as usize] == new[y as usize] {
                x += 1;
                y += 1;
            }
            frontier[(k + offset) as usize] = x;
            if x as usize >= n && y as usize >= m {
                distance = Some(d);
                break 'search;
            }
            k += 2;
        }
    }

    let distance = distance?;
    Some(backtrack(&trace, distance, n, m))
}

/// Walk the recorded frontiers backwards into a forward-ordered run list.
fn backtrack(trace: &[Vec<isize>], distance: usize, n: usize, m: usize) -> Vec<Run> {
    let mut reversed: Vec<Run> = Vec::new();
    let mut x = n as isize;
    let mut y = m as isize;

    for d in (0..=distance).rev() {
        if d == 0 {
            // Whatever is left at distance zero is a pure diagonal.
            while x > 0 && y > 0 {
                push_run(&mut reversed, Run::Keep(1));
                x -= 1;
                y -= 1;
            }
            break;
        }
        let d_signed = d as isize;
        let window = &trace[d];
        let at = |k: isize| window[(k + d_signed) as usize];

        let k = x - y;
        let down = k == -d_signed || (k != d_signed && at(k - 1) < at(k + 1));
        let previous_k = if down { k + 1 } else { k - 1 };
        let previous_x = at(previous_k);
        let previous_y = previous_x - previous_k;

        while x > previous_x && y > previous_y {
            push_run(&mut reversed, Run::Keep(1));
            x -= 1;
            y -= 1;
        }
        if down {
            push_run(&mut reversed, Run::Insert(1));
        } else {
            push_run(&mut reversed, Run::Delete(1));
        }
        x = previous_x;
        y = previous_y;
    }

    reversed.reverse();
    reversed
}

/// Append one elementary step, coalescing it into the run being built.
fn push_run(runs: &mut Vec<Run>, step: Run) {
    match (runs.last_mut(), step) {
        (Some(Run::Keep(count)), Run::Keep(add))
        | (Some(Run::Delete(count)), Run::Delete(add))
        | (Some(Run::Insert(count)), Run::Insert(add)) => *count += add,
        _ => runs.push(step),
    }
}

/// Runs → ops, pairing an adjacent delete/insert into an in-place replace.
///
/// A replace matters to the shell: swapping a node keeps the block's position
/// and its neighbours' identity, where a remove followed by an insert makes
/// the browser reflow twice and loses anything the block owned.
fn ops_from_runs(old: &[BlockId], new: &[BlockId], runs: &[Run]) -> Vec<Op> {
    let mut ops: Vec<Op> = Vec::new();
    let mut old_index = 0usize;
    let mut new_index = 0usize;
    let mut cursor = 0usize;

    while cursor < runs.len() {
        match runs[cursor] {
            Run::Keep(count) => {
                ops.push(Op::Keep {
                    old_index,
                    new_index,
                    count,
                });
                old_index += count;
                new_index += count;
                cursor += 1;
            }
            Run::Delete(deleted) => {
                let inserted = match runs.get(cursor + 1) {
                    Some(Run::Insert(inserted)) => *inserted,
                    _ => 0,
                };
                emit_change(&mut ops, old, new, old_index, new_index, deleted, inserted);
                old_index += deleted;
                new_index += inserted;
                cursor += if inserted > 0 { 2 } else { 1 };
            }
            Run::Insert(inserted) => {
                let deleted = match runs.get(cursor + 1) {
                    Some(Run::Delete(deleted)) => *deleted,
                    _ => 0,
                };
                emit_change(&mut ops, old, new, old_index, new_index, deleted, inserted);
                old_index += deleted;
                new_index += inserted;
                cursor += if deleted > 0 { 2 } else { 1 };
            }
        }
    }
    ops
}

/// Emit the ops for `deleted` old blocks becoming `inserted` new ones at the
/// same position: as much of it as possible in place, then the remainder.
fn emit_change(
    ops: &mut Vec<Op>,
    old: &[BlockId],
    new: &[BlockId],
    old_index: usize,
    new_index: usize,
    deleted: usize,
    inserted: usize,
) {
    let paired = deleted.min(inserted);
    if paired > 0 {
        ops.push(Op::Replace {
            old_index,
            new_index,
            old_ids: old[old_index..old_index + paired].to_vec(),
            new_ids: new[new_index..new_index + paired].to_vec(),
            html: None,
        });
    }
    if deleted > paired {
        ops.push(Op::Delete {
            old_index: old_index + paired,
            new_index: new_index + paired,
            old_ids: old[old_index + paired..old_index + deleted].to_vec(),
        });
    }
    if inserted > paired {
        // The anchor is the first old block *after* everything this change
        // consumes, so it is still in the DOM when the shell gets here.
        let anchor = old_index + deleted;
        ops.push(Op::Insert {
            old_index: anchor,
            new_index: new_index + paired,
            before: old.get(anchor).cloned(),
            new_ids: new[new_index + paired..new_index + inserted].to_vec(),
            html: None,
        });
    }
}

/// Fuse neighbouring ops of the same kind.
///
/// Myers hands back an alternating delete/insert path for a run of changed
/// blocks, which [`emit_change`] turns into a string of one-block replaces.
/// They are contiguous in both sequences, so fusing them is free and turns
/// "every block changed" into a single op instead of N.
fn merge_adjacent(ops: Vec<Op>) -> Vec<Op> {
    let mut merged: Vec<Op> = Vec::with_capacity(ops.len());
    for op in ops {
        match (merged.last_mut(), op) {
            (Some(Op::Keep { count, .. }), Op::Keep { count: add, .. }) => *count += add,
            (
                Some(Op::Delete { old_ids, .. }),
                Op::Delete {
                    old_ids: more_old, ..
                },
            ) => old_ids.extend(more_old),
            (
                Some(Op::Insert { new_ids, .. }),
                Op::Insert {
                    new_ids: more_new, ..
                },
            ) => new_ids.extend(more_new),
            (
                Some(Op::Replace {
                    old_ids, new_ids, ..
                }),
                Op::Replace {
                    old_ids: more_old,
                    new_ids: more_new,
                    ..
                },
            ) => {
                old_ids.extend(more_old);
                new_ids.extend(more_new);
            }
            (_, op) => merged.push(op),
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Turn short names into block ids the way the parser does: content hash
    /// plus an ordinal counting earlier blocks with the same content. Repeats
    /// in `names` therefore behave exactly as repeated blocks do in a real
    /// document.
    fn ids(names: &[&str]) -> Vec<BlockId> {
        let mut ordinals: std::collections::HashMap<&str, u32> = std::collections::HashMap::new();
        names
            .iter()
            .map(|name| {
                let ordinal = ordinals.entry(name).or_insert(0);
                let id = BlockId::new(crate::block::content_hash(name.as_bytes()), *ordinal);
                *ordinal += 1;
                id
            })
            .collect()
    }

    fn tags(script: &EditScript) -> Vec<&'static str> {
        script.ops.iter().map(Op::tag).collect()
    }

    fn round_trip(old: &[&str], new: &[&str]) -> EditScript {
        let old_ids = ids(old);
        let new_ids = ids(new);
        let script = diff_ids(&old_ids, &new_ids);
        assert_eq!(
            script.apply(&old_ids).expect("script applies"),
            new_ids,
            "script did not reproduce the new sequence: {script:?}"
        );
        assert_eq!(
            script.kept + script.deleted + script.replaced,
            script.old_blocks
        );
        assert_eq!(
            script.kept + script.inserted + script.replaced,
            script.new_blocks
        );
        script
    }

    #[test]
    fn two_empty_documents_produce_an_empty_script() {
        let script = round_trip(&[], &[]);
        assert!(script.ops.is_empty());
        assert!(script.is_noop());
    }

    #[test]
    fn an_unchanged_document_is_one_keep() {
        let script = round_trip(&["a", "b", "c"], &["a", "b", "c"]);
        assert_eq!(tags(&script), ["keep"]);
        assert!(script.is_noop());
        assert_eq!(script.kept, 3);
    }

    #[test]
    fn a_single_block_document_round_trips() {
        assert_eq!(tags(&round_trip(&["a"], &["a"])), ["keep"]);
        assert_eq!(tags(&round_trip(&["a"], &["b"])), ["replace"]);
        assert_eq!(tags(&round_trip(&[], &["a"])), ["insert"]);
        assert_eq!(tags(&round_trip(&["a"], &[])), ["delete"]);
    }

    #[test]
    fn inserting_in_the_middle_touches_nothing_else() {
        let script = round_trip(&["a", "b", "c"], &["a", "x", "b", "c"]);
        assert_eq!(tags(&script), ["keep", "insert", "keep"]);
        assert_eq!(script.kept, 3);
        assert_eq!(script.inserted, 1);
    }

    #[test]
    fn an_insert_anchors_on_the_old_block_it_precedes() {
        let old = ids(&["a", "b"]);
        let new = ids(&["a", "x", "b"]);
        let script = diff_ids(&old, &new);
        let Some(Op::Insert { before, .. }) = script.ops.iter().find(|op| op.tag() == "insert")
        else {
            panic!("expected an insert: {script:?}");
        };
        assert_eq!(before.as_ref(), Some(&old[1]));
    }

    #[test]
    fn appending_at_the_end_has_no_anchor() {
        let script = round_trip(&["a"], &["a", "b"]);
        let Some(Op::Insert { before, .. }) = script.ops.iter().find(|op| op.tag() == "insert")
        else {
            panic!("expected an insert: {script:?}");
        };
        assert_eq!(*before, None);
    }

    #[test]
    fn deleting_in_the_middle_names_the_removed_ids() {
        let old = ids(&["a", "b", "c"]);
        let script = round_trip(&["a", "b", "c"], &["a", "c"]);
        assert_eq!(tags(&script), ["keep", "delete", "keep"]);
        let Some(Op::Delete { old_ids, .. }) = script.ops.iter().find(|op| op.tag() == "delete")
        else {
            panic!("expected a delete: {script:?}");
        };
        assert_eq!(old_ids, &[old[1].clone()]);
    }

    #[test]
    fn every_block_changing_is_one_replace() {
        let script = round_trip(&["a", "b", "c"], &["x", "y", "z"]);
        assert_eq!(tags(&script), ["replace"]);
        assert_eq!(script.replaced, 3);
        assert_eq!(script.kept, 0);
    }

    #[test]
    fn identical_blocks_are_distinguished_by_ordinal() {
        // The case content-hash-plus-ordinal identity is most likely to get
        // wrong: five identical blocks, one removed from the middle.
        let script = round_trip(&["a", "a", "a", "a", "a"], &["a", "a", "a", "a"]);
        assert_eq!(script.old_blocks, 5);
        assert_eq!(script.new_blocks, 4);
        assert_eq!(script.deleted, 1);
        // The *last* ordinal goes, because the earlier ones still match.
        let Some(Op::Delete { old_ids, .. }) = script.ops.iter().find(|op| op.tag() == "delete")
        else {
            panic!("expected a delete: {script:?}");
        };
        assert_eq!(old_ids, &ids(&["a", "a", "a", "a", "a"])[4..]);
    }

    #[test]
    fn inserting_before_a_run_of_identical_blocks() {
        round_trip(&["a", "a", "a"], &["x", "a", "a", "a"]);
        round_trip(&["a", "a", "a"], &["a", "x", "a", "a"]);
        round_trip(&["a", "a", "a"], &["a", "a", "a", "x"]);
    }

    #[test]
    fn a_swap_of_identical_blocks_still_reproduces_the_new_list() {
        round_trip(&["a", "b", "a"], &["b", "a", "a"]);
        round_trip(&["a", "b", "c", "b", "a"], &["b", "a", "c", "a", "b"]);
    }

    #[test]
    fn scattered_edits_stay_localized() {
        let script = round_trip(
            &["a", "b", "c", "d", "e", "f"],
            &["a", "B", "c", "d", "E", "f"],
        );
        assert_eq!(
            tags(&script),
            ["keep", "replace", "keep", "replace", "keep"]
        );
        assert_eq!(script.kept, 4);
        assert_eq!(script.replaced, 2);
    }

    #[test]
    fn exceeding_the_edit_budget_falls_back_to_a_coarse_replace() {
        let old: Vec<String> = (0..40).map(|n| format!("old-{n}")).collect();
        let new: Vec<String> = (0..40).map(|n| format!("new-{n}")).collect();
        let old_ids = ids(&old.iter().map(String::as_str).collect::<Vec<_>>());
        let new_ids = ids(&new.iter().map(String::as_str).collect::<Vec<_>>());

        let (runs, coarse) = edit_runs(&old_ids, &new_ids, 4);
        assert!(coarse, "a distance-80 edit should exceed a budget of 4");
        assert_eq!(runs, vec![Run::Delete(40), Run::Insert(40)]);

        // And the fallback is still correct, which is the whole point.
        let ops = merge_adjacent(ops_from_runs(&old_ids, &new_ids, &runs));
        let script = EditScript {
            ops,
            old_blocks: 40,
            new_blocks: 40,
            kept: 0,
            inserted: 0,
            deleted: 0,
            replaced: 40,
            coarse,
        };
        assert_eq!(script.apply(&old_ids).unwrap(), new_ids);
    }

    #[test]
    fn the_default_budget_is_generous_enough_for_a_whole_small_document() {
        let old: Vec<String> = (0..200).map(|n| format!("old-{n}")).collect();
        let new: Vec<String> = (0..200).map(|n| format!("new-{n}")).collect();
        let script = diff_ids(
            &ids(&old.iter().map(String::as_str).collect::<Vec<_>>()),
            &ids(&new.iter().map(String::as_str).collect::<Vec<_>>()),
        );
        assert!(!script.coarse, "400 edits is inside the 512 budget");
        assert_eq!(tags(&script), ["replace"]);
    }

    #[test]
    fn apply_refuses_a_script_written_for_another_document() {
        // Deleting "b" from [a, b, c], applied to a document whose middle
        // block is something else.
        let script = diff_ids(&ids(&["a", "b", "c"]), &ids(&["a", "c"]));
        let error = script.apply(&ids(&["a", "z", "c"])).unwrap_err();
        assert!(
            matches!(error, ApplyError::Mismatch { at: 1, .. }),
            "expected a mismatch at index 1, got {error}"
        );
        assert!(error.to_string().contains("expected block"), "{error}");
    }

    #[test]
    fn a_keep_is_checked_by_length_only() {
        // Stated as a test rather than left implicit: `Keep` carries a count
        // and no ids, so applying a script to a document that differs *only*
        // inside a kept run succeeds. Carrying every kept id would make the
        // unchanged-document case — the common one — the largest payload.
        let script = diff_ids(&ids(&["a", "b"]), &ids(&["a", "b", "c"]));
        let other = ids(&["z", "y"]);
        assert_eq!(script.apply(&other).unwrap(), [other, ids(&["c"])].concat());
    }

    #[test]
    fn apply_refuses_a_script_that_runs_off_the_end() {
        let script = diff_ids(&ids(&["a", "b", "c"]), &ids(&["a"]));
        let error = script.apply(&ids(&["a"])).unwrap_err();
        assert!(
            matches!(error, ApplyError::OutOfRange { .. }),
            "expected out of range, got {error}"
        );
    }

    #[test]
    fn apply_refuses_a_script_that_stops_short() {
        let script = diff_ids(&ids(&["a"]), &ids(&["a"]));
        let error = script.apply(&ids(&["a", "b"])).unwrap_err();
        assert_eq!(
            error,
            ApplyError::Trailing {
                consumed: 1,
                have: 2
            }
        );
    }

    #[test]
    fn ops_serialize_with_an_op_tag() {
        let script = diff_ids(&ids(&["a", "b"]), &ids(&["a", "x", "b"]));
        let json = serde_json::to_string(&script).unwrap();
        assert!(json.contains("\"op\":\"keep\""), "{json}");
        assert!(json.contains("\"op\":\"insert\""), "{json}");
        assert!(json.contains("\"before\":"), "{json}");
        assert!(json.contains("\"coarse\":false"), "{json}");
        // No HTML unless the script was built from documents.
        assert!(!json.contains("\"html\""), "{json}");
    }

    #[test]
    fn diff_documents_attaches_html_for_new_blocks_only() {
        let old = Document::parse("# H\n\nalpha\n");
        let new = Document::parse("# H\n\nalpha\n\n```rust\nfn f() {}\n```\n");
        let script = diff_documents(&old, &new, &crate::theme::default_pair());
        assert_eq!(tags(&script), ["keep", "insert"]);

        let Some(Op::Insert { html, new_ids, .. }) =
            script.ops.iter().find(|op| op.tag() == "insert")
        else {
            panic!("expected an insert: {script:?}");
        };
        let html = html.as_deref().expect("inserts carry their HTML");
        assert!(html.contains("mk-code"), "{html}");
        assert!(
            html.contains(&format!("data-blk=\"{}\"", new_ids[0])),
            "{html}"
        );
    }

    #[test]
    fn diffing_a_document_against_itself_is_a_noop() {
        let source = "# H\n\npara\n\n- [ ] task\n";
        let doc = Document::parse(source);
        let script = diff_documents(
            &doc,
            &Document::parse(source),
            &crate::theme::default_pair(),
        );
        assert!(script.is_noop(), "{script:?}");
        assert_eq!(tags(&script), ["keep"]);
        assert_eq!(script.kept, doc.blocks().len());
    }

    #[test]
    fn block_ids_are_unique_within_a_document() {
        // Anchoring an insert by `data-blk` is only sound because of this.
        // Five identical paragraphs is the shape that would break it.
        let doc = Document::parse("same\n\nsame\n\nsame\n\nsame\n\nsame\n");
        let mut seen = std::collections::HashSet::new();
        for block in doc.blocks() {
            assert!(seen.insert(block.id.clone()), "duplicate id {}", block.id);
        }
        assert_eq!(seen.len(), 5);
    }
}
