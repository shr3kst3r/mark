//! Top-level blocks and their content-derived identity.
//!
//! ADR-2 (`2026-08-24-progressive-document-rendering`) makes block identity
//! load-bearing: ids are `<content-hash>-<ordinal>` where the ordinal
//! disambiguates blocks with *identical content*, never position. Inserting a
//! paragraph must therefore leave every id below it untouched, which is what
//! makes incremental patching worth having.

use std::fmt;
use std::ops::Range;

use serde::Serialize;

/// FNV-1a, 64-bit. Chosen over `DefaultHasher` because that one is seeded with
/// a per-process random key, and a block id must be identical across processes
/// and across runs (the CLI, the app, and a golden test all have to agree).
#[must_use]
pub fn content_hash(bytes: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

/// Hash of two parts, so a code block's `(language, code)` key cannot collide
/// with a different split of the same concatenated bytes.
#[must_use]
pub fn content_hash2(a: &[u8], b: &[u8]) -> u64 {
    let mut buf = Vec::with_capacity(a.len() + b.len() + 1);
    buf.extend_from_slice(a);
    buf.push(0x1f);
    buf.extend_from_slice(b);
    content_hash(&buf)
}

/// What kind of top-level construct a block is. Coarse on purpose: this drives
/// a CSS class and the table of contents, not rendering decisions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum BlockKind {
    Heading { level: u8 },
    Paragraph,
    CodeBlock { language: Option<String> },
    List { ordered: bool },
    BlockQuote,
    Table,
    ThematicBreak,
    Html,
    FootnoteDefinition,
    DefinitionList,
    Other,
}

impl BlockKind {
    /// CSS class suffix, also used in `--json` output.
    #[must_use]
    pub fn slug(&self) -> &'static str {
        match self {
            BlockKind::Heading { .. } => "heading",
            BlockKind::Paragraph => "paragraph",
            BlockKind::CodeBlock { .. } => "code",
            BlockKind::List { .. } => "list",
            BlockKind::BlockQuote => "quote",
            BlockKind::Table => "table",
            BlockKind::ThematicBreak => "rule",
            BlockKind::Html => "html",
            BlockKind::FootnoteDefinition => "footnote",
            BlockKind::DefinitionList => "deflist",
            BlockKind::Other => "other",
        }
    }
}

/// A block's stable identity: `<content-hash>-<ordinal>`.
///
/// Rendered into `data-blk`. The ordinal counts previous blocks with the *same*
/// hash, so two identical `---` rules are distinguishable while a paragraph
/// inserted above them changes neither.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(transparent)]
pub struct BlockId(String);

impl BlockId {
    #[must_use]
    pub fn new(hash: u64, ordinal: u32) -> Self {
        BlockId(format!("{hash:016x}-{ordinal}"))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for BlockId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// One top-level block of a document.
#[derive(Debug, Clone, Serialize)]
pub struct Block {
    pub id: BlockId,
    #[serde(flatten)]
    pub kind: BlockKind,
    /// Byte range of the block in the source document.
    pub start: usize,
    pub end: usize,
    /// Content hash of the source bytes plus the kind slug.
    pub hash: u64,
    /// Count of preceding blocks sharing `hash`.
    pub ordinal: u32,
    /// Index of the first event belonging to this block, into
    /// [`crate::parse::Document::events`].
    #[serde(skip)]
    pub event_range: Range<usize>,
}

impl Block {
    #[must_use]
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }
}

/// Assigns ordinals as blocks are built, so callers cannot forget to.
#[derive(Default)]
pub(crate) struct OrdinalCounter {
    seen: std::collections::HashMap<u64, u32>,
}

impl OrdinalCounter {
    pub(crate) fn next(&mut self, hash: u64) -> u32 {
        let slot = self.seen.entry(hash).or_insert(0);
        let ordinal = *slot;
        *slot += 1;
        ordinal
    }
}

/// Hash a block from its source bytes and kind. The kind is folded in so a
/// paragraph reading `foo` and a code block reading `foo` are distinct.
#[must_use]
pub fn block_hash(kind: &BlockKind, source: &str) -> u64 {
    content_hash2(kind.slug().as_bytes(), source.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_hash_is_stable_across_calls() {
        assert_eq!(content_hash(b"hello"), content_hash(b"hello"));
        assert_ne!(content_hash(b"hello"), content_hash(b"hell0"));
    }

    #[test]
    fn content_hash_matches_known_fnv1a_vector() {
        // FNV-1a 64 of "a" and "foobar", from the reference test vectors.
        assert_eq!(content_hash(b"a"), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(content_hash(b"foobar"), 0x8594_4171_f739_67e8);
    }

    #[test]
    fn two_part_hash_is_not_concatenation() {
        assert_ne!(content_hash2(b"ab", b"c"), content_hash2(b"a", b"bc"));
    }

    #[test]
    fn kind_participates_in_the_hash() {
        assert_ne!(
            block_hash(&BlockKind::Paragraph, "foo"),
            block_hash(&BlockKind::CodeBlock { language: None }, "foo")
        );
    }

    #[test]
    fn ordinals_count_only_identical_hashes() {
        let mut counter = OrdinalCounter::default();
        assert_eq!(counter.next(7), 0);
        assert_eq!(counter.next(9), 0);
        assert_eq!(counter.next(7), 1);
    }

    #[test]
    fn block_id_is_zero_padded_hex_plus_ordinal() {
        assert_eq!(BlockId::new(0x2a, 3).as_str(), "000000000000002a-3");
    }
}
