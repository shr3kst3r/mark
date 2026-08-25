//! Themes: one file, one palette, both layers.
//!
//! # Why not just use `.tmTheme`
//!
//! A `.tmTheme` — and a VS Code `tokenColors` block — describes **code token
//! colours only**. It says nothing about document background, body text,
//! heading colour, link colour, table borders, blockquote rules, or callout
//! accents. That split is exactly why `delta` users end up with chrome that
//! clashes with their syntax colours. So a `mark` theme is one file with a
//! **base16 palette as the single source of truth**, and both layers —
//! `[document]` chrome and `[code]` scope → slot — reference palette slots
//! rather than raw hex. Change `base0D` and links, function names, headings,
//! and the table header rule all move together.
//!
//! `.tmTheme` import stays as an escape hatch (see [`import`]) for "make it
//! look exactly like VS Code's X". It derives chrome from the tmTheme's global
//! `background` / `foreground` / `caret` / `selection`, and the result is less
//! coherent than a palette-derived theme. That is inherent, not a bug.
//!
//! # Light and dark, for free
//!
//! A [`ThemePair`] carries a light theme and a dark one, and [`ThemePair::css`]
//! emits custom properties for **both**, with the dark half behind
//! `@media (prefers-color-scheme: dark)`. Switching macOS appearance therefore
//! costs zero IPC, zero re-render, and zero DOM work: WebKit re-resolves the
//! variables and repaints. Nothing in Swift is involved at all.
//!
//! Code tokens ride the same mechanism. `syntect` gives us a *colour* per
//! token; what we emit is `class="t0B"`, the **palette slot**, whose colour is
//! a custom property. Two consequences worth stating:
//!
//! * An appearance switch re-colours code with no re-highlight and no
//!   re-render, exactly like chrome.
//! * The emitted HTML depends only on the scope → slot map, not on the
//!   colours. Every base16 theme shares the default map, so switching *themes*
//!   also needs no re-render — [`ThemePair::code_stamp`] is what lets a caller
//!   know when that stops being true (a hand-written `[code]` section, or a
//!   `.tmTheme` import).
//!
//! This is the measurement M2 left for M7. `ClassedHTMLGenerator`, syntect's
//! own class mode, emits the full scope stack per span — `class="source rust
//! meta function-call"` — and measured **1.59× the bytes and 1.51× the
//! inject+layout time** of inline styles on the 1 MB corpus. That is why plan
//! §2 M7's "syntect emits `class="tok-*"`" is not what shipped. A slot class is
//! four characters, so it is *smaller* than the inline style it replaces and
//! still re-themes for free. `bench/highlight-format` measures all three.
//!
//! # The file format
//!
//! ```toml
//! name = "dracula"
//! kind = "dark"            # light | dark
//! pair = "dracula-light"   # optional; absent means "use me for both"
//!
//! [palette]
//! base00 = "#282a36"       # ... through base0F, all sixteen required
//!
//! [document]               # optional; these are the defaults
//! background = "base00"
//! foreground = "base05"
//!
//! [code]                   # optional; these are the defaults
//! keyword = "base0E"
//! string = "base0B"
//! ```
//!
//! Only that subset of TOML parses — sections, `key = "string"`, comments.
//! Anything fancier is **rejected with a line number** rather than
//! misinterpreted, because a theme that parses differently than it reads is
//! worse than one that refuses to parse.

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

use serde::Serialize;
use syntect::highlighting::{
    Color, FontStyle, ScopeSelectors, StyleModifier, Theme as SyntectTheme, ThemeItem,
    ThemeSettings,
};

use crate::block::content_hash2;

// `BUILTIN`: the themes `just themes-import` converted, embedded at build
// time as `(name, toml)` pairs. Embedded rather than read from disk so
// `mark render --html` works from any directory with no bundle to find, and so
// a shipped theme cannot be half-deleted by an installer. (The doc comment
// lives in build.rs, because rustdoc does not read through an `include!`.)
include!(concat!(env!("OUT_DIR"), "/themes.rs"));

/// The theme used when nothing else is asked for.
pub const DEFAULT_THEME: &str = "default-dark";

/// base16 slot count. base24 adds eight more; the format accepts them and
/// nothing in v1 requires them.
const BASE16: usize = 16;
const MAX_SLOTS: usize = 24;

// ---------------------------------------------------------------------------
// Colours and slots
// ---------------------------------------------------------------------------

/// One palette slot, `base00` … `base17`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Slot(u8);

impl Slot {
    /// `"base0D"` → `Slot(13)`. Case-insensitive in the hex digit, because
    /// upstream scheme files are not consistent about it.
    #[must_use]
    pub fn parse(text: &str) -> Option<Slot> {
        let rest = text.strip_prefix("base")?;
        if rest.len() != 2 {
            return None;
        }
        let value = u8::from_str_radix(rest, 16).ok()?;
        (usize::from(value) < MAX_SLOTS).then_some(Slot(value))
    }

    /// The two-character suffix, e.g. `"0D"`. This is the CSS class (`t0D`)
    /// and the custom-property suffix (`--mk-s0D`).
    #[must_use]
    pub fn suffix(self) -> String {
        format!("{:02X}", self.0)
    }

    #[must_use]
    pub fn name(self) -> String {
        format!("base{}", self.suffix())
    }

    #[must_use]
    pub fn index(self) -> usize {
        usize::from(self.0)
    }
}

impl fmt::Display for Slot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.name())
    }
}

/// A 24-bit colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    /// `#rrggbb` or `#rgb`, with or without the `#`.
    #[must_use]
    pub fn parse(text: &str) -> Option<Rgb> {
        let hex = text.trim().strip_prefix('#').unwrap_or(text.trim());
        let bytes = hex.as_bytes();
        let pair = |a: u8, b: u8| -> Option<u8> {
            u8::from_str_radix(std::str::from_utf8(&[a, b]).ok()?, 16).ok()
        };
        match bytes.len() {
            6 | 8 => Some(Rgb {
                r: pair(bytes[0], bytes[1])?,
                g: pair(bytes[2], bytes[3])?,
                b: pair(bytes[4], bytes[5])?,
            }),
            3 => Some(Rgb {
                r: pair(bytes[0], bytes[0])?,
                g: pair(bytes[1], bytes[1])?,
                b: pair(bytes[2], bytes[2])?,
            }),
            _ => None,
        }
    }

    #[must_use]
    pub fn hex(self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }

    /// Perceived brightness, 0.0–1.0. Used only to decide whether an imported
    /// `.tmTheme` is light or dark.
    #[must_use]
    pub fn luminance(self) -> f32 {
        (0.2126 * f32::from(self.r) + 0.7152 * f32::from(self.g) + 0.0722 * f32::from(self.b))
            / 255.0
    }

    /// `self` mixed towards `other` by `amount` (0.0 = self, 1.0 = other).
    #[must_use]
    pub fn mix(self, other: Rgb, amount: f32) -> Rgb {
        let blend = |a: u8, b: u8| -> u8 {
            let a = f32::from(a);
            let b = f32::from(b);
            (a + (b - a) * amount).round().clamp(0.0, 255.0) as u8
        };
        Rgb {
            r: blend(self.r, other.r),
            g: blend(self.g, other.g),
            b: blend(self.b, other.b),
        }
    }

    fn syntect(self) -> Color {
        Color {
            r: self.r,
            g: self.g,
            b: self.b,
            a: 0xFF,
        }
    }
}

impl fmt::Display for Rgb {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hex())
    }
}

impl Serialize for Rgb {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.hex())
    }
}

/// Whether a theme is for a light or a dark appearance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Light,
    Dark,
}

impl Kind {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Light => "light",
            Kind::Dark => "dark",
        }
    }

    /// The appearance this one is not.
    #[must_use]
    pub fn other(self) -> Kind {
        match self {
            Kind::Light => Kind::Dark,
            Kind::Dark => Kind::Light,
        }
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Why a theme could not be loaded.
///
/// Every variant names the theme and the thing that was wrong with it. Plan §2
/// M7's gate is precisely this: *"a theme with a deliberately missing slot
/// fails with a named error rather than rendering invisible text"* — so no
/// variant here is allowed to be a shrug, and nothing silently substitutes a
/// colour for one the file did not define.
#[derive(Debug)]
pub enum ThemeError {
    /// No theme by that name, built in or in the user directory.
    NotFound {
        name: String,
        /// The closest names we do have, for the "did you mean" line.
        near: Vec<String>,
    },
    /// The file could not be read.
    Io {
        path: PathBuf,
        source: std::io::Error,
    },
    /// The file is not the TOML subset this format is.
    Syntax {
        origin: String,
        line: usize,
        message: String,
    },
    /// A required top-level key is absent.
    MissingKey { theme: String, key: &'static str },
    /// `kind` was neither `light` nor `dark`.
    BadKind { theme: String, value: String },
    /// A palette entry was not `#rrggbb`.
    BadColor {
        theme: String,
        key: String,
        value: String,
    },
    /// The palette does not define a slot the theme needs. **This is the
    /// invisible-text failure, caught.**
    MissingSlot {
        theme: String,
        section: &'static str,
        key: String,
        slot: String,
    },
    /// A `[document]` or `[code]` entry named something that is not a slot.
    UnknownSlot {
        theme: String,
        section: &'static str,
        key: String,
        value: String,
    },
    /// A `[code]` key is not a scope selector syntect understands.
    BadScope {
        theme: String,
        key: String,
        message: String,
    },
    /// A `.tmTheme` or scheme file could not be converted.
    Import { path: PathBuf, message: String },
}

impl fmt::Display for ThemeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ThemeError::NotFound { name, near } => {
                write!(f, "no theme named \"{name}\"")?;
                if !near.is_empty() {
                    write!(f, "; did you mean {}?", near.join(", "))?;
                }
                Ok(())
            }
            ThemeError::Io { path, source } => write!(f, "{}: {source}", path.display()),
            ThemeError::Syntax {
                origin,
                line,
                message,
            } => write!(f, "{origin}:{line}: {message}"),
            ThemeError::MissingKey { theme, key } => {
                write!(f, "theme \"{theme}\" has no {key}")
            }
            ThemeError::BadKind { theme, value } => write!(
                f,
                "theme \"{theme}\": kind is \"{value}\", expected \"light\" or \"dark\""
            ),
            ThemeError::BadColor { theme, key, value } => write!(
                f,
                "theme \"{theme}\": {key} is \"{value}\", expected #rrggbb"
            ),
            // Two shapes, because the two failures read very differently: an
            // incomplete palette, and a layer pointing at a slot the palette
            // does not have.
            ThemeError::MissingSlot {
                theme,
                section: "palette",
                slot,
                ..
            } => write!(
                f,
                "theme \"{theme}\": the palette does not define {slot}, and base16 requires base00-base0F"
            ),
            ThemeError::MissingSlot {
                theme,
                section,
                key,
                slot,
            } => write!(
                f,
                "theme \"{theme}\": [{section}] {key} needs palette slot {slot}, which the palette does not define"
            ),
            ThemeError::UnknownSlot {
                theme,
                section,
                key,
                value,
            } => write!(
                f,
                "theme \"{theme}\": [{section}] {key} = \"{value}\" is not a palette slot (base00-base17)"
            ),
            ThemeError::BadScope {
                theme,
                key,
                message,
            } => write!(
                f,
                "theme \"{theme}\": [code] \"{key}\" is not a scope selector: {message}"
            ),
            ThemeError::Import { path, message } => {
                write!(f, "{}: {message}", path.display())
            }
        }
    }
}

impl std::error::Error for ThemeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ThemeError::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// The TOML subset
// ---------------------------------------------------------------------------

/// One `key = "value"` from a theme file, with where it came from.
#[derive(Debug, Clone)]
struct Entry {
    section: String,
    key: String,
    value: String,
}

/// Parse the TOML subset this format is: `[section]` headers, `key = "value"`
/// pairs, `#` comments, blank lines.
///
/// Deliberately not the `toml` crate. The format needs strings in sections and
/// nothing else, the error messages here can name the theme and the slot, and
/// a scope key like `entity.name.function` is a *dotted key* in real TOML —
/// which would silently nest into `entity.name.function` tables rather than
/// meaning what its author meant. Quoting is required for those, and that is
/// checked below rather than misread.
fn parse_toml(text: &str, origin: &str) -> Result<Vec<Entry>, ThemeError> {
    let mut entries = Vec::new();
    let mut section = String::new();

    for (index, raw) in text.lines().enumerate() {
        let line = strip_comment(raw).trim().to_owned();
        let number = index + 1;
        if line.is_empty() {
            continue;
        }
        let syntax = |message: &str| ThemeError::Syntax {
            origin: origin.to_owned(),
            line: number,
            message: message.to_owned(),
        };

        if let Some(rest) = line.strip_prefix('[') {
            let Some(name) = rest.strip_suffix(']') else {
                return Err(syntax("unterminated [section] header"));
            };
            let name = name.trim();
            if name.is_empty() || name.starts_with('[') {
                return Err(syntax(
                    "only simple [section] headers are supported in a theme file",
                ));
            }
            section = name.to_owned();
            continue;
        }

        let Some((key, value)) = line.split_once('=') else {
            return Err(syntax("expected `key = \"value\"`"));
        };
        let key = key.trim();
        let value = value.trim();

        let key = if let Some(quoted) = unquote(key) {
            quoted
        } else {
            if !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            {
                return Err(syntax(&format!(
                    "key `{key}` must be quoted: a bare key may only hold letters, digits, `_`, and `-` (a `.` in TOML means a nested table)"
                )));
            }
            key.to_owned()
        };

        let Some(value) = unquote(value) else {
            return Err(syntax(&format!(
                "the value for `{key}` must be a double-quoted string; this format has no numbers, arrays, or tables"
            )));
        };

        entries.push(Entry {
            section: section.clone(),
            key,
            value,
        });
    }
    Ok(entries)
}

/// Drop a `#` comment that is not inside a string.
fn strip_comment(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut quoted = false;
    let mut escaped = false;
    for ch in line.chars() {
        if quoted {
            out.push(ch);
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                quoted = false;
            }
            continue;
        }
        match ch {
            '"' => {
                quoted = true;
                out.push(ch);
            }
            '#' => break,
            _ => out.push(ch),
        }
    }
    out
}

/// A double-quoted string with `\"` and `\\` escapes, or `None` if `text` is
/// not one.
fn unquote(text: &str) -> Option<String> {
    let inner = text.strip_prefix('"')?;
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    let mut closed = false;
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => return None,
            },
            '"' => {
                closed = true;
                break;
            }
            _ => out.push(ch),
        }
    }
    // Anything after the closing quote is a construct this subset does not
    // have, so it is a refusal rather than a silent truncation.
    (closed && chars.as_str().trim().is_empty()).then_some(out)
}

// ---------------------------------------------------------------------------
// The defaults
// ---------------------------------------------------------------------------

/// Document chrome, as slot names. base16's own styling guidelines.
const DEFAULT_DOCUMENT: &[(&str, &str)] = &[
    ("background", "base00"),
    ("surface", "base01"),
    ("selection", "base02"),
    ("muted", "base03"),
    ("subtle", "base04"),
    ("foreground", "base05"),
    ("heading", "base0D"),
    ("link", "base0D"),
    ("accent", "base0E"),
    ("rule", "base02"),
    ("error", "base08"),
    ("warning", "base0A"),
    ("success", "base0B"),
];

/// Scope → slot, the base16 styling guidelines' mapping.
///
/// Order is emission order, not precedence: precedence is syntect's, by
/// selector specificity, exactly as it is for a `.tmTheme`.
const DEFAULT_CODE: &[(&str, &str)] = &[
    ("comment", "base03"),
    ("punctuation.definition.comment", "base03"),
    ("string", "base0B"),
    ("constant.character.escape", "base0C"),
    ("string.regexp", "base0C"),
    ("constant.numeric", "base09"),
    ("constant.language", "base09"),
    ("constant.character", "base09"),
    ("constant.other", "base09"),
    ("variable", "base08"),
    ("variable.parameter", "base08"),
    ("entity.name.tag", "base08"),
    ("entity.other.attribute-name", "base09"),
    ("entity.name.function", "base0D"),
    ("entity.name.method", "base0D"),
    ("support.function", "base0D"),
    ("meta.function-call", "base0D"),
    ("entity.name.class", "base0A"),
    ("entity.name.struct", "base0A"),
    ("entity.name.enum", "base0A"),
    ("entity.name.type", "base0A"),
    ("entity.name.namespace", "base0A"),
    ("support.type", "base0A"),
    ("support.class", "base0A"),
    ("storage.type", "base0A"),
    ("keyword", "base0E"),
    ("storage", "base0E"),
    ("storage.modifier", "base0E"),
    ("keyword.operator", "base05"),
    ("punctuation", "base05"),
    ("support.constant", "base09"),
    ("support.variable", "base08"),
    ("invalid", "base08"),
    ("invalid.deprecated", "base0F"),
    ("markup.inserted", "base0B"),
    ("markup.deleted", "base08"),
    ("markup.changed", "base0E"),
    ("markup.heading", "base0D"),
    ("markup.link", "base09"),
    ("markup.raw", "base0B"),
    ("meta.tag", "base08"),
    ("meta.preprocessor", "base0F"),
];

// ---------------------------------------------------------------------------
// A theme
// ---------------------------------------------------------------------------

/// Where a theme came from. Reported by `mark theme --list` so "why is my
/// edit not showing up" has an answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Source {
    /// Converted by `just themes-import` and embedded in the binary.
    Builtin,
    /// A file in `~/.config/mark/themes`.
    User { path: PathBuf },
}

/// One resolved theme: a palette, plus both layers pointing into it.
#[derive(Debug, Clone)]
pub struct Theme {
    name: String,
    title: Option<String>,
    author: Option<String>,
    kind: Kind,
    pair: Option<String>,
    source: Source,
    palette: [Option<Rgb>; MAX_SLOTS],
    document: Vec<(String, Slot)>,
    code: Vec<(String, Slot)>,
}

impl Theme {
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }
    #[must_use]
    pub fn title(&self) -> &str {
        self.title.as_deref().unwrap_or(&self.name)
    }
    #[must_use]
    pub fn author(&self) -> Option<&str> {
        self.author.as_deref()
    }
    #[must_use]
    pub fn kind(&self) -> Kind {
        self.kind
    }
    #[must_use]
    pub fn pair(&self) -> Option<&str> {
        self.pair.as_deref()
    }
    #[must_use]
    pub fn source(&self) -> &Source {
        &self.source
    }

    /// The palette, `base00` first. `None` for a slot the file did not define,
    /// which for base24 slots is normal and for base16 slots is impossible —
    /// [`Theme::parse`] refuses a palette missing any of the first sixteen.
    #[must_use]
    pub fn palette(&self) -> &[Option<Rgb>; MAX_SLOTS] {
        &self.palette
    }

    /// The colour in `slot`. Only `None` for an undefined base24 slot, which
    /// nothing can reference — a reference to one is a load-time error.
    #[must_use]
    pub fn color(&self, slot: Slot) -> Option<Rgb> {
        self.palette[slot.index()]
    }

    /// A chrome colour by key, e.g. `"background"`.
    #[must_use]
    pub fn chrome(&self, key: &str) -> Option<Rgb> {
        self.document
            .iter()
            .find(|(name, _)| name == key)
            .and_then(|(_, slot)| self.color(*slot))
    }

    /// The chrome layer as `(key, slot)`, in emission order.
    #[must_use]
    pub fn document(&self) -> &[(String, Slot)] {
        &self.document
    }

    /// The code layer as `(scope, slot)`.
    #[must_use]
    pub fn code(&self) -> &[(String, Slot)] {
        &self.code
    }

    /// The slot unmatched code text takes, i.e. the body colour of a code
    /// block. Emitted as no span at all, which is where a good part of the
    /// byte saving over inline styles comes from.
    #[must_use]
    pub fn default_code_slot(&self) -> Slot {
        self.document
            .iter()
            .find(|(name, _)| name == "foreground")
            .map_or(Slot(5), |(_, slot)| *slot)
    }

    /// Parse one theme file.
    ///
    /// `origin` appears in syntax errors; `source` records where it came from.
    pub fn parse(text: &str, origin: &str, source: Source) -> Result<Theme, ThemeError> {
        let entries = parse_toml(text, origin)?;
        let top = |key: &str| {
            entries
                .iter()
                .find(|entry| entry.section.is_empty() && entry.key == key)
                .map(|entry| entry.value.clone())
        };

        let name = top("name").ok_or(ThemeError::MissingKey {
            theme: origin.to_owned(),
            key: "name",
        })?;
        let kind = match top("kind").as_deref() {
            Some("light") => Kind::Light,
            Some("dark") => Kind::Dark,
            Some(other) => {
                return Err(ThemeError::BadKind {
                    theme: name,
                    value: other.to_owned(),
                });
            }
            None => {
                return Err(ThemeError::MissingKey {
                    theme: name,
                    key: "kind",
                });
            }
        };

        let mut palette: [Option<Rgb>; MAX_SLOTS] = [None; MAX_SLOTS];
        for entry in entries.iter().filter(|entry| entry.section == "palette") {
            let Some(slot) = Slot::parse(&entry.key) else {
                return Err(ThemeError::UnknownSlot {
                    theme: name.clone(),
                    section: "palette",
                    key: entry.key.clone(),
                    value: entry.key.clone(),
                });
            };
            let Some(color) = Rgb::parse(&entry.value) else {
                return Err(ThemeError::BadColor {
                    theme: name.clone(),
                    key: entry.key.clone(),
                    value: entry.value.clone(),
                });
            };
            palette[slot.index()] = Some(color);
        }
        for (index, slot) in palette.iter().enumerate().take(BASE16) {
            if slot.is_none() {
                return Err(ThemeError::MissingSlot {
                    theme: name.clone(),
                    section: "palette",
                    key: "palette".to_owned(),
                    slot: Slot(index as u8).name(),
                });
            }
        }

        let layer = |section: &'static str,
                     defaults: &[(&str, &str)]|
         -> Result<Vec<(String, Slot)>, ThemeError> {
            let mut resolved: Vec<(String, Slot)> = Vec::with_capacity(defaults.len());
            let mut overrides: Vec<&Entry> = entries
                .iter()
                .filter(|entry| entry.section == section)
                .collect();
            // A theme's own entries win over the default for the same key, and
            // keys the defaults do not have are appended in file order.
            for (key, slot) in defaults {
                let value = overrides
                    .iter()
                    .rev()
                    .find(|entry| entry.key == *key)
                    .map_or((*slot).to_owned(), |entry| entry.value.clone());
                resolved.push((
                    (*key).to_owned(),
                    resolve_slot(&name, section, key, &value, &palette)?,
                ));
            }
            overrides.retain(|entry| !defaults.iter().any(|(key, _)| *key == entry.key));
            for entry in overrides {
                resolved.push((
                    entry.key.clone(),
                    resolve_slot(&name, section, &entry.key, &entry.value, &palette)?,
                ));
            }
            Ok(resolved)
        };

        let document = layer("document", DEFAULT_DOCUMENT)?;
        let code = layer("code", DEFAULT_CODE)?;

        // Refuse a scope selector syntect cannot compile now, rather than
        // dropping it silently at highlight time.
        for (scope, _) in &code {
            if let Err(error) = scope.parse::<ScopeSelectors>() {
                return Err(ThemeError::BadScope {
                    theme: name.clone(),
                    key: scope.clone(),
                    message: error.to_string(),
                });
            }
        }

        Ok(Theme {
            title: top("title"),
            author: top("author"),
            pair: top("pair"),
            name,
            kind,
            source,
            palette,
            document,
            code,
        })
    }

    /// A `syntect::highlighting::Theme` carrying this theme's real colours.
    ///
    /// Plan §2 M7: *"synthesize a syntect `Theme` in memory from the palette so
    /// code colors stay coherent with chrome by construction"*. It is used for
    /// anything that wants concrete colours — and, in the form below, for slot
    /// resolution.
    #[must_use]
    pub fn syntect(&self) -> SyntectTheme {
        self.build_syntect(|slot| self.color(slot).map(Rgb::syntect))
    }

    /// The same theme with each slot's colour replaced by a **sentinel that
    /// encodes the slot index**.
    ///
    /// This is how class emission and colour emission stay the same code path.
    /// syntect owns scope-selector matching and precedence; asking it a second
    /// time with our own reimplementation would be a second, subtly different
    /// answer. So we ask *it*, and make the answer a slot number.
    #[must_use]
    pub fn slot_probe(&self) -> SyntectTheme {
        self.build_syntect(|slot| Some(sentinel(slot)))
    }

    fn build_syntect(&self, color_of: impl Fn(Slot) -> Option<Color>) -> SyntectTheme {
        let chrome = |key: &str| {
            self.document
                .iter()
                .find(|(name, _)| name == key)
                .and_then(|(_, slot)| color_of(*slot))
        };
        SyntectTheme {
            name: Some(self.name.clone()),
            author: self.author.clone(),
            settings: ThemeSettings {
                foreground: chrome("foreground"),
                background: chrome("background"),
                caret: chrome("foreground"),
                selection: chrome("selection"),
                ..ThemeSettings::default()
            },
            scopes: self
                .code
                .iter()
                .filter_map(|(scope, slot)| {
                    Some(ThemeItem {
                        scope: scope.parse::<ScopeSelectors>().ok()?,
                        style: StyleModifier {
                            foreground: color_of(*slot),
                            background: None,
                            font_style: Some(FontStyle::empty()),
                        },
                    })
                })
                .collect(),
        }
    }
}

fn resolve_slot(
    theme: &str,
    section: &'static str,
    key: &str,
    value: &str,
    palette: &[Option<Rgb>; MAX_SLOTS],
) -> Result<Slot, ThemeError> {
    let Some(slot) = Slot::parse(value) else {
        return Err(ThemeError::UnknownSlot {
            theme: theme.to_owned(),
            section,
            key: key.to_owned(),
            value: value.to_owned(),
        });
    };
    if palette[slot.index()].is_none() {
        return Err(ThemeError::MissingSlot {
            theme: theme.to_owned(),
            section,
            key: key.to_owned(),
            slot: slot.name(),
        });
    }
    Ok(slot)
}

/// The sentinel colour for `slot`. `0xFE 0xED <slot>` — recognisable in a hex
/// dump, and impossible to reach from a palette because we never put one there.
fn sentinel(slot: Slot) -> Color {
    Color {
        r: 0xFE,
        g: 0xED,
        b: slot.index() as u8,
        a: 0xFF,
    }
}

/// The slot a sentinel encodes, or `None` if this is a real colour.
#[must_use]
pub fn slot_of(color: Color) -> Option<Slot> {
    (color.r == 0xFE && color.g == 0xED && usize::from(color.b) < MAX_SLOTS)
        .then_some(Slot(color.b))
}

// ---------------------------------------------------------------------------
// A pair
// ---------------------------------------------------------------------------

/// The unit of selection: a light theme and a dark one, chosen together.
///
/// `mark theme dracula` selects a pair, because the page carries both variants
/// and `prefers-color-scheme` picks between them with no involvement from us.
/// A theme with no `pair` is used for **both** halves — you asked for Dracula,
/// you get Dracula in either appearance — and `mark theme --show` says so.
#[derive(Debug, Clone)]
pub struct ThemePair {
    light: Arc<Theme>,
    dark: Arc<Theme>,
    /// The one the user named. Its `[code]` map is the pair's, and its name is
    /// the pair's name.
    primary: Kind,
    /// Computed once, here, rather than per call.
    ///
    /// Not premature: these are in the **memo cache key**, so a lazy version
    /// runs once per code block. Hashing the whole scope map there took the
    /// 1 MB cached-highlight path from 0.4 ms to 3.2 ms and blew `just bench`'s
    /// committed 1 ms ceiling — which is exactly what that threshold is for.
    code_stamp: u64,
    color_stamp: u64,
}

impl ThemePair {
    #[must_use]
    pub fn new(light: Arc<Theme>, dark: Arc<Theme>, primary: Kind) -> ThemePair {
        let code_stamp = code_stamp_of(match primary {
            Kind::Light => &light,
            Kind::Dark => &dark,
        });
        let color_stamp = color_stamp_of(&light, &dark, primary);
        ThemePair {
            light,
            dark,
            primary,
            code_stamp,
            color_stamp,
        }
    }

    #[must_use]
    pub fn light(&self) -> &Theme {
        &self.light
    }
    #[must_use]
    pub fn dark(&self) -> &Theme {
        &self.dark
    }

    /// The theme the user named.
    #[must_use]
    pub fn primary(&self) -> &Theme {
        match self.primary {
            Kind::Light => &self.light,
            Kind::Dark => &self.dark,
        }
    }

    /// The other half.
    #[must_use]
    pub fn partner(&self) -> &Theme {
        match self.primary {
            Kind::Light => &self.dark,
            Kind::Dark => &self.light,
        }
    }

    /// Whether both halves are the same theme.
    #[must_use]
    pub fn is_single(&self) -> bool {
        self.light.name == self.dark.name
    }

    #[must_use]
    pub fn name(&self) -> &str {
        self.primary().name()
    }

    #[must_use]
    pub fn theme(&self, kind: Kind) -> &Theme {
        match kind {
            Kind::Light => &self.light,
            Kind::Dark => &self.dark,
        }
    }

    /// Identity of the **scope → slot map**, which is the only part of a theme
    /// the emitted HTML depends on.
    ///
    /// Two themes with the same stamp produce byte-identical highlighted HTML,
    /// so switching between them needs no re-render and their cache entries are
    /// shared. The app compares stamps across a theme change and re-renders
    /// only when they differ — which, for every theme this ships, they do not.
    #[must_use]
    pub fn code_stamp(&self) -> u64 {
        self.code_stamp
    }

    /// Identity of the **colours**, for the ANSI cache, which does not get to
    /// defer its colours to CSS.
    #[must_use]
    pub fn color_stamp(&self) -> u64 {
        self.color_stamp
    }

    /// CSS custom properties for **both** appearances.
    ///
    /// This is the whole light/dark mechanism. The page gets one `<style>`
    /// whose contents are this string; `prefers-color-scheme` does the rest,
    /// with no IPC, no re-render, and no DOM work on an appearance switch.
    #[must_use]
    pub fn css(&self) -> String {
        let mut css = String::with_capacity(1024);
        css.push_str(":root{");
        variables(&mut css, &self.light, self.light.kind);
        css.push('}');
        if !self.is_single() {
            css.push_str("@media (prefers-color-scheme: dark){:root{");
            variables(&mut css, &self.dark, self.dark.kind);
            css.push_str("}}");
        }
        css.push('\n');
        css
    }

    /// The mermaid `themeVariables` for one appearance. See
    /// [`crate::rich::diagram`] for why a diagram is rendered twice.
    #[must_use]
    pub fn mermaid_config(&self, kind: Kind) -> String {
        mermaid_variables(self.theme(kind))
    }
}

impl Default for ThemePair {
    fn default() -> Self {
        (*default_pair()).clone()
    }
}

fn code_stamp_of(theme: &Theme) -> u64 {
    let mut joined = String::new();
    for (scope, slot) in &theme.code {
        joined.push_str(scope);
        joined.push('\u{1f}');
        joined.push_str(&slot.suffix());
        joined.push('\u{1e}');
    }
    content_hash2(
        theme.default_code_slot().suffix().as_bytes(),
        joined.as_bytes(),
    )
}

fn color_stamp_of(light: &Theme, dark: &Theme, primary: Kind) -> u64 {
    let ordered = match primary {
        Kind::Light => [light, dark],
        Kind::Dark => [dark, light],
    };
    let mut joined = String::new();
    for theme in ordered {
        joined.push_str(theme.name());
        for color in theme.palette.iter().flatten() {
            joined.push_str(&color.hex());
        }
    }
    content_hash2(b"ansi", joined.as_bytes())
}

fn variables(css: &mut String, theme: &Theme, kind: Kind) {
    use std::fmt::Write as _;
    // `color-scheme` is what makes the *form controls* — the task checkboxes —
    // follow the theme. Without it a dark page draws light checkboxes.
    let _ = write!(css, "color-scheme:{};", kind.as_str());
    for (key, slot) in &theme.document {
        if let Some(color) = theme.color(*slot) {
            let _ = write!(css, "--mk-{key}:{};", color.hex());
        }
    }
    for (index, color) in theme.palette.iter().enumerate() {
        if let Some(color) = color {
            let _ = write!(css, "--mk-s{}:{};", Slot(index as u8).suffix(), color.hex());
        }
    }
}

/// Mermaid's own theme variables, derived from the palette.
///
/// `theme: "base"` is Mermaid's "derive everything from these" mode, which
/// `merman` implements in full — so a diagram comes out in the document's
/// palette rather than in Mermaid's stock lavender. The font family is
/// deliberately **not** set: `merman` measures label boxes with a vendored
/// metric table, and a family it has no metrics for would lay out at the wrong
/// width.
fn mermaid_variables(theme: &Theme) -> String {
    let slot = |key: &str, fallback: Slot| {
        theme
            .chrome(key)
            .or_else(|| theme.color(fallback))
            .unwrap_or(Rgb { r: 0, g: 0, b: 0 })
            .hex()
    };
    let base = |index: u8| {
        theme
            .color(Slot(index))
            .unwrap_or(Rgb { r: 0, g: 0, b: 0 })
            .hex()
    };
    let dark = theme.kind == Kind::Dark;
    let mut json = serde_json::Map::new();
    let mut set = |key: &str, value: String| {
        json.insert(key.to_owned(), serde_json::Value::String(value));
    };

    set("background", slot("background", Slot(0)));
    set("primaryColor", slot("surface", Slot(1)));
    set("primaryTextColor", slot("foreground", Slot(5)));
    set("primaryBorderColor", slot("heading", Slot(13)));
    set("secondaryColor", base(2));
    set("secondaryTextColor", slot("foreground", Slot(5)));
    set("secondaryBorderColor", base(12));
    set("tertiaryColor", base(2));
    set("tertiaryTextColor", slot("foreground", Slot(5)));
    set("tertiaryBorderColor", base(14));
    set("lineColor", slot("subtle", Slot(4)));
    set("textColor", slot("foreground", Slot(5)));
    set("mainBkg", slot("surface", Slot(1)));
    set("nodeBorder", slot("heading", Slot(13)));
    set("nodeTextColor", slot("foreground", Slot(5)));
    set("clusterBkg", base(1));
    set("clusterBorder", base(3));
    set("titleColor", slot("heading", Slot(13)));
    set("edgeLabelBackground", slot("background", Slot(0)));
    set("labelBackground", slot("background", Slot(0)));
    set("labelTextColor", slot("foreground", Slot(5)));
    set("noteBkgColor", base(2));
    set("noteTextColor", slot("foreground", Slot(5)));
    set("noteBorderColor", base(10));
    set("actorBkg", slot("surface", Slot(1)));
    set("actorBorder", slot("heading", Slot(13)));
    set("actorTextColor", slot("foreground", Slot(5)));
    set("actorLineColor", slot("subtle", Slot(4)));
    set("signalColor", slot("foreground", Slot(5)));
    set("signalTextColor", slot("foreground", Slot(5)));
    set("labelBoxBkgColor", slot("surface", Slot(1)));
    set("labelBoxBorderColor", slot("heading", Slot(13)));
    set("loopTextColor", slot("foreground", Slot(5)));
    set("activationBkgColor", base(2));
    set("activationBorderColor", slot("heading", Slot(13)));
    set("sequenceNumberColor", slot("background", Slot(0)));
    set("altBackground", base(1));
    set("errorBkgColor", slot("error", Slot(8)));
    set("errorTextColor", slot("background", Slot(0)));
    // The categorical scales pie, journey, gantt, and radar draw from. Left to
    // Mermaid's own derivation these are hue rotations of one colour; taken
    // from the palette they are the eight colours the theme's author chose.
    for (index, slot_index) in [8u8, 13, 11, 10, 14, 12, 9, 15].iter().enumerate() {
        let color = base(*slot_index);
        set(&format!("cScale{index}"), color.clone());
        set(&format!("cScaleLabel{index}"), slot("background", Slot(0)));
        set(&format!("pie{}", index + 1), color);
    }
    json.insert("darkMode".to_owned(), serde_json::Value::Bool(dark));
    serde_json::Value::Object(json).to_string()
}

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

/// `~/.config/mark/themes`, where a user's own themes go.
///
/// Plan §2 M7: they are *"picked up without a rebuild"*. They are also picked
/// up without a **restart**: the registry stamps each file's mtime and re-reads
/// when it moves, so editing a theme and pressing reload is enough.
#[must_use]
pub fn user_dir() -> Option<PathBuf> {
    let base = std::env::var_os("MARK_THEME_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .map(|dir| dir.join("mark").join("themes"))
        })
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .map(|dir| dir.join(".config").join("mark").join("themes"))
        })?;
    Some(base)
}

/// One line of `mark theme --list`.
#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub name: String,
    pub title: String,
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pair: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub source: Source,
}

/// Every theme that can be named, built-in and user, user first.
///
/// A user file shadows a built-in of the same name — that is how you tweak a
/// shipped theme — and a file that will not parse is listed with the parse
/// error rather than being dropped, because a theme that silently vanishes is
/// the failure this whole module is trying to avoid.
#[must_use]
pub fn list() -> (Vec<Summary>, Vec<String>) {
    let mut summaries: Vec<Summary> = Vec::new();
    let mut problems: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();

    for (path, text) in user_files() {
        let origin = path.display().to_string();
        match Theme::parse(&text, &origin, Source::User { path: path.clone() }) {
            Ok(theme) => {
                seen.push(theme.name.clone());
                summaries.push(summary(&theme));
            }
            Err(error) => problems.push(error.to_string()),
        }
    }
    for (name, text) in BUILTIN {
        if seen.iter().any(|seen| seen == name) {
            continue;
        }
        match Theme::parse(text, name, Source::Builtin) {
            Ok(theme) => summaries.push(summary(&theme)),
            Err(error) => problems.push(error.to_string()),
        }
    }
    summaries.sort_by(|a, b| a.name.cmp(&b.name));
    (summaries, problems)
}

fn summary(theme: &Theme) -> Summary {
    Summary {
        name: theme.name.clone(),
        title: theme.title().to_owned(),
        kind: theme.kind,
        pair: theme.pair.clone(),
        author: theme.author.clone(),
        source: theme.source.clone(),
    }
}

/// Every readable `*.toml` in the user directory.
fn user_files() -> Vec<(PathBuf, String)> {
    let Some(dir) = user_dir() else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut files: Vec<(PathBuf, String)> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "toml"))
        .filter_map(|path| fs::read_to_string(&path).ok().map(|text| (path, text)))
        .collect();
    files.sort_by(|a, b| a.0.cmp(&b.0));
    files
}

struct Cached {
    pair: Arc<ThemePair>,
    /// The files this pair was built from, and their mtimes. Empty for a pair
    /// built entirely from built-ins, which cannot go stale.
    watches: Vec<(PathBuf, Option<SystemTime>)>,
}

static CACHE: OnceLock<Mutex<HashMap<String, Cached>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<String, Cached>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A poisoned cache must not take the process down: it holds no invariant, and
/// the C ABI may not unwind (ADR-1). Same policy as the highlight cache.
fn lock() -> std::sync::MutexGuard<'static, HashMap<String, Cached>> {
    cache().lock().unwrap_or_else(|poisoned| {
        cache().clear_poison();
        poisoned.into_inner()
    })
}

/// The pair for `name`, resolving its partner too.
///
/// Cached, with each contributing file's mtime checked on the way in — so a
/// user editing `~/.config/mark/themes/mine.toml` sees the change on the next
/// render, with no rebuild and no restart.
pub fn resolve(name: &str) -> Result<Arc<ThemePair>, ThemeError> {
    let name = if name.trim().is_empty() {
        DEFAULT_THEME
    } else {
        name.trim()
    };

    if let Some(cached) = lock().get(name)
        && cached
            .watches
            .iter()
            .all(|(path, stamp)| modified(path) == *stamp)
    {
        return Ok(Arc::clone(&cached.pair));
    }

    let (primary, primary_path) = load(name)?;
    let partner = match primary.pair.as_deref() {
        // A dangling `pair` is a broken theme, not a missing one: `?` says so
        // rather than quietly using the primary for both appearances, which
        // would look like the pair never existed.
        Some(partner) if partner != primary.name => Some(load(partner)?),
        _ => None,
    };

    let primary = Arc::new(primary);
    let mut watches = Vec::new();
    if let Some(path) = primary_path.clone() {
        watches.push((path.clone(), modified(&path)));
    }

    let pair = match partner {
        Some((partner, partner_path)) => {
            if let Some(path) = partner_path {
                watches.push((path.clone(), modified(&path)));
            }
            let partner = Arc::new(partner);
            match primary.kind {
                Kind::Light => ThemePair::new(Arc::clone(&primary), partner, Kind::Light),
                Kind::Dark => ThemePair::new(partner, Arc::clone(&primary), Kind::Dark),
            }
        }
        None => ThemePair::new(Arc::clone(&primary), Arc::clone(&primary), primary.kind),
    };

    let pair = Arc::new(pair);
    lock().insert(
        name.to_owned(),
        Cached {
            pair: Arc::clone(&pair),
            watches,
        },
    );
    Ok(pair)
}

/// Drop every cached pair. For tests, and for a CLI that has just written a
/// theme file.
pub fn clear_cache() {
    lock().clear();
}

fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path)
        .ok()
        .and_then(|meta| meta.modified().ok())
}

/// One theme by name, user directory first.
fn load(name: &str) -> Result<(Theme, Option<PathBuf>), ThemeError> {
    if let Some(dir) = user_dir() {
        let path = dir.join(format!("{name}.toml"));
        if path.is_file() {
            let text = fs::read_to_string(&path).map_err(|source| ThemeError::Io {
                path: path.clone(),
                source,
            })?;
            let origin = path.display().to_string();
            let theme = Theme::parse(&text, &origin, Source::User { path: path.clone() })?;
            return Ok((theme, Some(path)));
        }
    }
    if let Some((_, text)) = BUILTIN.iter().find(|(builtin, _)| *builtin == name) {
        return Ok((Theme::parse(text, name, Source::Builtin)?, None));
    }
    Err(ThemeError::NotFound {
        name: name.to_owned(),
        near: near(name),
    })
}

/// Names close enough to `name` to be worth suggesting.
///
/// Three cheap rules rather than a fuzzy-matching dependency: one name contains
/// the other, they share a `-`-separated head, or they are within two edits.
/// "did you mean" is a convenience, and a wrong suggestion costs nothing while
/// a missing one costs a round trip to `--list`.
fn near(name: &str) -> Vec<String> {
    let needle = name.to_lowercase();
    let (summaries, _) = list();
    let mut near: Vec<String> = summaries
        .into_iter()
        .map(|summary| summary.name)
        .filter(|candidate| {
            let candidate = candidate.to_lowercase();
            candidate.contains(&needle)
                || needle.contains(&candidate)
                || candidate
                    .split('-')
                    .next()
                    .is_some_and(|head| needle.starts_with(head))
                || edits_within(&candidate, &needle, 2)
        })
        .collect();
    near.truncate(4);
    near
}

/// Whether `a` and `b` are within `budget` single-character edits.
///
/// Full Levenshtein over two short names; the length gate keeps it from being
/// run at all in the common case.
fn edits_within(a: &str, b: &str, budget: usize) -> bool {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if a.len().abs_diff(b.len()) > budget {
        return false;
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    let mut current = vec![0usize; b.len() + 1];
    for (i, left) in a.iter().enumerate() {
        current[0] = i + 1;
        for (j, right) in b.iter().enumerate() {
            let cost = usize::from(left != right);
            current[j + 1] = (previous[j] + cost)
                .min(previous[j + 1] + 1)
                .min(current[j] + 1);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[b.len()] <= budget
}

/// The built-in default, which no user file can break.
///
/// Deliberately *not* routed through [`resolve`]: a user's own
/// `default-dark.toml` shadows the built-in everywhere else, and if it failed
/// to parse there would be nothing left to render with. This is the floor.
#[must_use]
pub fn default_pair() -> Arc<ThemePair> {
    static DEFAULT: OnceLock<Arc<ThemePair>> = OnceLock::new();
    Arc::clone(DEFAULT.get_or_init(|| {
        let builtin = |name: &str| {
            BUILTIN
                .iter()
                .find(|(builtin, _)| *builtin == name)
                .and_then(|(name, text)| Theme::parse(text, name, Source::Builtin).ok())
                .map(Arc::new)
        };
        let dark = builtin(DEFAULT_THEME).expect("the built-in default theme parses");
        let light = dark
            .pair
            .as_deref()
            .and_then(builtin)
            .unwrap_or_else(|| Arc::clone(&dark));
        Arc::new(ThemePair::new(light, dark, Kind::Dark))
    }))
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// Convert a `.tmTheme` or a base16 scheme YAML into a theme file.
///
/// Returns the TOML text and the name it should be saved under. The caller
/// decides where it lands, because `mark theme --import` writes into the user
/// directory and a test writes into a temporary one.
///
/// A `.tmTheme` carries **code colours only**, so chrome is derived from its
/// global `background` / `foreground` / `caret` / `selection` and the rest of
/// the palette is interpolated between background and foreground. The result is
/// less coherent than a palette-derived theme. That is inherent to the source
/// format, not a defect in the conversion — it is exactly the split this
/// format exists to avoid.
pub fn import(path: &Path) -> Result<(String, String), ThemeError> {
    let name = path
        .file_stem()
        .map(|stem| slug(&stem.to_string_lossy()))
        .filter(|stem| !stem.is_empty())
        .unwrap_or_else(|| "imported".to_owned());

    let extension = path
        .extension()
        .map(|ext| ext.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    match extension.as_str() {
        "yaml" | "yml" => import_scheme(path, &name),
        "tmtheme" => import_tm_theme(path, &name),
        other => Err(ThemeError::Import {
            path: path.to_path_buf(),
            message: format!(
                "don't know how to import a \"{other}\" file; expected .tmTheme or a base16 scheme .yaml"
            ),
        }),
    }
}

/// A base16 scheme YAML — the same subset `scripts/themes-import.py` parses,
/// so a scheme this accepts is one `just themes-import` would have accepted.
fn import_scheme(path: &Path, name: &str) -> Result<(String, String), ThemeError> {
    let text = fs::read_to_string(path).map_err(|source| ThemeError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let fail = |message: String| ThemeError::Import {
        path: path.to_path_buf(),
        message,
    };

    let mut top: HashMap<String, String> = HashMap::new();
    let mut palette: [Option<Rgb>; MAX_SLOTS] = [None; MAX_SLOTS];
    let mut in_palette = false;
    for raw in text.lines() {
        let line = strip_yaml_comment(raw);
        if line.trim().is_empty() {
            continue;
        }
        let indented = line.starts_with(' ') || line.starts_with('\t');
        let line = line.trim().to_owned();
        if !indented {
            in_palette = line == "palette:";
            if in_palette {
                continue;
            }
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim().to_owned();
        let value = value.trim().trim_matches(['"', '\'']).to_owned();
        if indented && in_palette {
            let Some(slot) = Slot::parse(&key) else {
                return Err(fail(format!("{key} is not a base16 palette slot")));
            };
            let Some(color) = Rgb::parse(&value) else {
                return Err(fail(format!("{key} is \"{value}\", expected #rrggbb")));
            };
            palette[slot.index()] = Some(color);
        } else if !indented {
            top.insert(key, value);
        }
    }

    for (index, slot) in palette.iter().enumerate().take(BASE16) {
        if slot.is_none() {
            return Err(fail(format!(
                "palette is missing {}",
                Slot(index as u8).name()
            )));
        }
    }
    let kind = match top.get("variant").map(String::as_str) {
        Some("light") => Kind::Light,
        Some("dark") => Kind::Dark,
        // Older scheme files predate `variant`; brightness is a reliable
        // answer for a palette whose base00 is the background by definition.
        _ => {
            if palette[0].is_some_and(|color| color.luminance() > 0.5) {
                Kind::Light
            } else {
                Kind::Dark
            }
        }
    };

    Ok((
        write_theme(
            name,
            kind,
            None,
            top.get("name").map(String::as_str),
            top.get("author").map(String::as_str),
            &format!("imported from {}", path.display()),
            &palette,
            &[],
        ),
        name.to_owned(),
    ))
}

/// A TextMate/Sublime `.tmTheme`, through syntect's own plist loader.
fn import_tm_theme(path: &Path, name: &str) -> Result<(String, String), ThemeError> {
    let theme =
        syntect::highlighting::ThemeSet::get_theme(path).map_err(|error| ThemeError::Import {
            path: path.to_path_buf(),
            message: error.to_string(),
        })?;
    let settings = &theme.settings;
    let color = |value: Option<Color>| {
        value.map(|c| Rgb {
            r: c.r,
            g: c.g,
            b: c.b,
        })
    };

    let background = color(settings.background).ok_or_else(|| ThemeError::Import {
        path: path.to_path_buf(),
        message: "the tmTheme has no global background colour, so there is no chrome to derive"
            .to_owned(),
    })?;
    let foreground = color(settings.foreground).ok_or_else(|| ThemeError::Import {
        path: path.to_path_buf(),
        message: "the tmTheme has no global foreground colour, so there is no chrome to derive"
            .to_owned(),
    })?;
    let kind = if background.luminance() > 0.5 {
        Kind::Light
    } else {
        Kind::Dark
    };

    let mut palette: [Option<Rgb>; MAX_SLOTS] = [None; MAX_SLOTS];
    palette[0] = Some(background);
    palette[5] = Some(foreground);
    // The four greys between background and foreground. A tmTheme has no
    // opinion about them, so they are interpolated — which is why an imported
    // theme's chrome is coherent with itself even though its source said
    // nothing about chrome at all.
    palette[1] = Some(background.mix(foreground, 0.08));
    palette[2] = Some(
        color(settings.selection)
            .filter(|selection| *selection != background)
            .unwrap_or_else(|| background.mix(foreground, 0.20)),
    );
    palette[3] = Some(background.mix(foreground, 0.45));
    palette[4] = Some(background.mix(foreground, 0.75));
    palette[6] = Some(foreground.mix(background, 0.10));
    palette[7] = Some(foreground.mix(background, 0.20));

    // Ask the tmTheme what it paints each of our default scopes, and file the
    // answer under the slot our default map assigns to that scope. A slot with
    // no opinion falls back to the caret colour, then to the foreground.
    let highlighter = syntect::highlighting::Highlighter::new(&theme);
    let caret = color(settings.caret).unwrap_or(foreground);
    for (scope, slot) in DEFAULT_CODE {
        let Some(slot) = Slot::parse(slot) else {
            continue;
        };
        if slot.index() < 8 || palette[slot.index()].is_some() {
            continue;
        }
        let Ok(parsed) = scope.parse::<syntect::parsing::Scope>() else {
            continue;
        };
        let style = highlighter.style_for_stack(&[parsed]);
        let Some(found) = color(Some(style.foreground)) else {
            continue;
        };
        if found != foreground {
            palette[slot.index()] = Some(found);
        }
    }
    for slot in palette.iter_mut().take(BASE16).skip(8) {
        if slot.is_none() {
            *slot = Some(if caret == foreground {
                foreground
            } else {
                caret
            });
        }
    }

    Ok((
        write_theme(
            name,
            kind,
            None,
            theme.name.as_deref(),
            theme.author.as_deref(),
            &format!("imported from {}", path.display()),
            &palette,
            &[],
        ),
        name.to_owned(),
    ))
}

fn strip_yaml_comment(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut quote: Option<char> = None;
    for (index, ch) in line.char_indices() {
        if let Some(open) = quote {
            out.push(ch);
            if ch == open {
                quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' => {
                quote = Some(ch);
                out.push(ch);
            }
            '#' if index == 0 || line[..index].ends_with([' ', '\t']) => break,
            _ => out.push(ch),
        }
    }
    out
}

/// Emit a theme file. The same shape `scripts/themes-import.py` writes, so an
/// imported theme and a shipped one are the same kind of object.
#[allow(clippy::too_many_arguments)]
fn write_theme(
    name: &str,
    kind: Kind,
    pair: Option<&str>,
    title: Option<&str>,
    author: Option<&str>,
    provenance: &str,
    palette: &[Option<Rgb>; MAX_SLOTS],
    document: &[(&str, &str)],
) -> String {
    use std::fmt::Write as _;
    let mut out = String::new();
    let _ = writeln!(out, "# {provenance}");
    let _ = writeln!(out, "#");
    let _ = writeln!(
        out,
        "# Edit freely: this is a user theme, and `mark` re-reads it when its"
    );
    let _ = writeln!(out, "# mtime moves — no rebuild and no restart.");
    let _ = writeln!(out);
    let _ = writeln!(out, "name = \"{name}\"");
    let _ = writeln!(out, "kind = \"{}\"", kind.as_str());
    if let Some(pair) = pair {
        let _ = writeln!(out, "pair = \"{pair}\"");
    }
    if let Some(title) = title {
        let _ = writeln!(out, "title = \"{}\"", title.replace('"', "'"));
    }
    if let Some(author) = author {
        let _ = writeln!(out, "author = \"{}\"", author.replace('"', "'"));
    }
    let _ = writeln!(out, "\n[palette]");
    for (index, color) in palette.iter().enumerate() {
        if let Some(color) = color {
            let _ = writeln!(out, "{} = \"{}\"", Slot(index as u8).name(), color.hex());
        }
    }
    if !document.is_empty() {
        let _ = writeln!(out, "\n[document]");
        for (key, slot) in document {
            let _ = writeln!(out, "{key} = \"{slot}\"");
        }
    }
    out
}

/// A file name reduced to something that can be a theme name.
fn slug(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL: &str = r##"
name = "probe"
kind = "dark"
[palette]
base00 = "#101010"
base01 = "#202020"
base02 = "#303030"
base03 = "#404040"
base04 = "#505050"
base05 = "#d0d0d0"
base06 = "#e0e0e0"
base07 = "#f0f0f0"
base08 = "#ff0000"
base09 = "#ff8800"
base0A = "#ffff00"
base0B = "#00ff00"
base0C = "#00ffff"
base0D = "#0000ff"
base0E = "#ff00ff"
base0F = "#884400"
"##;

    fn probe() -> Theme {
        Theme::parse(MINIMAL, "probe", Source::Builtin).expect("the probe theme parses")
    }

    #[test]
    fn every_shipped_theme_parses() {
        assert!(BUILTIN.len() >= 16, "only {} themes shipped", BUILTIN.len());
        for (name, text) in BUILTIN {
            let theme = Theme::parse(text, name, Source::Builtin)
                .unwrap_or_else(|error| panic!("{name}: {error}"));
            assert_eq!(theme.name(), *name, "{name} names itself something else");
            for index in 0..BASE16 {
                assert!(
                    theme.palette[index].is_some(),
                    "{name} has no base{index:02X}"
                );
            }
        }
    }

    #[test]
    fn every_declared_pair_exists_and_points_back() {
        for (name, text) in BUILTIN {
            let theme = Theme::parse(text, name, Source::Builtin).unwrap();
            let Some(partner_name) = theme.pair() else {
                continue;
            };
            let (partner, _) = load(partner_name).unwrap_or_else(|error| panic!("{name}: {error}"));
            assert_eq!(
                partner.pair(),
                Some(*name),
                "{name} pairs with {partner_name}, which does not pair back"
            );
            assert_ne!(
                partner.kind(),
                theme.kind(),
                "{name} and {partner_name} are both {:?}",
                theme.kind()
            );
        }
    }

    #[test]
    fn a_missing_palette_slot_is_a_named_error() {
        // Plan §2 M7's gate: a theme with a deliberately missing slot fails
        // with a **named** error rather than rendering invisible text.
        let broken = MINIMAL.replace("base0D = \"#0000ff\"\n", "");
        let error = Theme::parse(&broken, "probe", Source::Builtin).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("probe"), "{message}");
        assert!(message.contains("base0D"), "{message}");
        assert!(matches!(error, ThemeError::MissingSlot { .. }), "{error:?}");
    }

    #[test]
    fn a_document_key_pointing_at_an_undefined_slot_is_named_too() {
        let broken = format!("{MINIMAL}\n[document]\nlink = \"base14\"\n");
        let error = Theme::parse(&broken, "probe", Source::Builtin).unwrap_err();
        assert!(matches!(error, ThemeError::MissingSlot { .. }), "{error:?}");
        let message = error.to_string();
        assert!(message.contains("[document] link"), "{message}");
        assert!(message.contains("base14"), "{message}");
    }

    #[test]
    fn a_document_key_pointing_at_a_non_slot_is_named_too() {
        let broken = format!("{MINIMAL}\n[document]\nlink = \"#ff0000\"\n");
        let error = Theme::parse(&broken, "probe", Source::Builtin).unwrap_err();
        assert!(matches!(error, ThemeError::UnknownSlot { .. }), "{error:?}");
        // The whole point of the format: chrome references slots, never hex.
        assert!(
            error.to_string().contains("is not a palette slot"),
            "{error}"
        );
    }

    #[test]
    fn overriding_one_chrome_key_leaves_the_rest_at_their_defaults() {
        let tweaked = format!("{MINIMAL}\n[document]\nlink = \"base0B\"\n");
        let theme = Theme::parse(&tweaked, "probe", Source::Builtin).unwrap();
        assert_eq!(theme.chrome("link"), Rgb::parse("#00ff00"));
        assert_eq!(theme.chrome("heading"), Rgb::parse("#0000ff"));
        assert_eq!(theme.document().len(), DEFAULT_DOCUMENT.len());
    }

    #[test]
    fn the_toml_subset_refuses_what_it_cannot_read() {
        for (text, expected) in [
            ("name = probe\n", "must be a double-quoted string"),
            ("[palette\nbase00 = \"#000000\"\n", "unterminated"),
            ("entity.name = \"base05\"\n", "must be quoted"),
            ("name = \"probe\" trailing\n", "double-quoted string"),
            ("name\n", "expected `key = \"value\"`"),
        ] {
            let error = parse_toml(text, "probe").unwrap_err();
            let message = error.to_string();
            assert!(
                message.contains(expected),
                "{text:?} produced {message:?}, expected {expected:?}"
            );
            assert!(message.starts_with("probe:"), "{message} has no location");
        }
    }

    #[test]
    fn a_quoted_scope_key_survives_with_its_dots() {
        let text = format!("{MINIMAL}\n[code]\n\"entity.name.function\" = \"base0B\"\n");
        let theme = Theme::parse(&text, "probe", Source::Builtin).unwrap();
        let found = theme
            .code()
            .iter()
            .find(|(scope, _)| scope == "entity.name.function")
            .expect("the scope survived");
        assert_eq!(theme.color(found.1), Rgb::parse("#00ff00"));
    }

    #[test]
    fn comments_and_hashes_inside_strings_are_told_apart() {
        let text =
            "name = \"probe\"  # trailing\nkind = \"dark\"\n[palette]\nbase00 = \"#101010\"\n";
        let entries = parse_toml(text, "probe").unwrap();
        assert_eq!(entries[0].value, "probe");
        assert_eq!(entries[2].value, "#101010");
    }

    #[test]
    fn slots_round_trip() {
        for name in ["base00", "base0d", "base0D", "base17"] {
            let slot = Slot::parse(name).unwrap_or_else(|| panic!("{name}"));
            assert_eq!(slot.name().to_lowercase(), name.to_lowercase());
        }
        assert_eq!(Slot::parse("base18"), None);
        assert_eq!(Slot::parse("base0"), None);
        assert_eq!(Slot::parse("bass00"), None);
    }

    #[test]
    fn the_probe_theme_hands_syntect_a_slot_index() {
        let theme = probe();
        let syntect = theme.slot_probe();
        let highlighter = syntect::highlighting::Highlighter::new(&syntect);
        let scope = "keyword".parse::<syntect::parsing::Scope>().unwrap();
        let style = highlighter.style_for_stack(&[scope]);
        assert_eq!(slot_of(style.foreground), Slot::parse("base0E"));
        // And the real theme hands back the real colour for the same scope.
        let colored = theme.syntect();
        let real = syntect::highlighting::Highlighter::new(&colored);
        assert_eq!(
            real.style_for_stack(&[scope]).foreground,
            Rgb::parse("#ff00ff").unwrap().syntect()
        );
    }

    #[test]
    fn a_real_colour_is_not_mistaken_for_a_sentinel() {
        assert_eq!(
            slot_of(Color {
                r: 0xFE,
                g: 0xED,
                b: 0xFA,
                a: 0xFF
            }),
            None
        );
        assert_eq!(
            slot_of(Rgb::parse("#282a36").unwrap().syntect()),
            None,
            "dracula's background reads as a slot sentinel"
        );
    }

    #[test]
    fn css_carries_both_appearances() {
        let pair = resolve("default-dark").expect("a shipped theme");
        let css = pair.css();
        assert!(css.starts_with(":root{color-scheme:light;"), "{css}");
        assert!(css.contains("@media (prefers-color-scheme: dark)"), "{css}");
        // The custom property is named after the chrome key it carries, so
        // there is no translation table between the theme file and the CSS.
        assert!(css.contains("--mk-background:"), "{css}");
        assert!(css.contains("--mk-foreground:"), "{css}");
        assert!(css.contains("--mk-s0D:"), "{css}");
        // The light half is the one outside the media query.
        let light = pair.light().chrome("background").unwrap().hex();
        let dark = pair.dark().chrome("background").unwrap().hex();
        assert_ne!(light, dark);
        let (before, after) = css.split_once("@media").unwrap();
        assert!(before.contains(&light), "{before}");
        assert!(after.contains(&dark), "{after}");
    }

    #[test]
    fn an_unpaired_theme_is_used_for_both_appearances() {
        let pair = resolve("dracula").expect("dracula ships");
        assert!(pair.is_single());
        assert_eq!(pair.light().name(), "dracula");
        assert_eq!(pair.dark().name(), "dracula");
        let css = pair.css();
        assert!(
            !css.contains("prefers-color-scheme"),
            "one theme for both appearances needs no media query: {css}"
        );
        assert!(css.contains("color-scheme:dark;"), "{css}");
    }

    #[test]
    fn selecting_either_half_of_a_pair_gives_the_same_two_themes() {
        let dark = resolve("default-dark").unwrap();
        let light = resolve("default-light").unwrap();
        assert_eq!(dark.light().name(), light.light().name());
        assert_eq!(dark.dark().name(), light.dark().name());
        // What differs is which one is primary, and therefore whose code map
        // and name the pair carries.
        assert_eq!(dark.name(), "default-dark");
        assert_eq!(light.name(), "default-light");
    }

    #[test]
    fn every_shipped_theme_shares_one_code_map() {
        // The property that makes a theme switch free: same map, same emitted
        // HTML, so no re-render. If a future theme carries its own `[code]`
        // section this test fails, which is the signal to check that the app's
        // stamp comparison still re-renders when it must.
        let stamps: Vec<u64> = BUILTIN
            .iter()
            .map(|(name, _)| resolve(name).unwrap().code_stamp())
            .collect();
        assert!(
            stamps.windows(2).all(|pair| pair[0] == pair[1]),
            "shipped themes disagree about the scope map"
        );
    }

    #[test]
    fn a_different_code_map_is_a_different_stamp() {
        let plain = Theme::parse(MINIMAL, "probe", Source::Builtin).unwrap();
        let tweaked = Theme::parse(
            &format!("{MINIMAL}\n[code]\nkeyword = \"base0B\"\n"),
            "probe",
            Source::Builtin,
        )
        .unwrap();
        let plain = ThemePair::new(Arc::new(plain.clone()), Arc::new(plain), Kind::Dark);
        let tweaked = ThemePair::new(Arc::new(tweaked.clone()), Arc::new(tweaked), Kind::Dark);
        assert_ne!(plain.code_stamp(), tweaked.code_stamp());
    }

    #[test]
    fn an_unknown_name_suggests_what_we_do_have() {
        let error = resolve("dracola").unwrap_err();
        let message = error.to_string();
        assert!(message.contains("no theme named \"dracola\""), "{message}");
        assert!(message.contains("dracula"), "{message}");
    }

    #[test]
    fn the_default_pair_is_the_documented_one() {
        let pair = default_pair();
        assert_eq!(pair.name(), DEFAULT_THEME);
        assert_eq!(pair.dark().name(), "default-dark");
        assert_eq!(pair.light().name(), "default-light");
    }

    #[test]
    fn mermaid_variables_come_from_the_palette() {
        let pair = resolve("dracula").unwrap();
        let config = pair.mermaid_config(Kind::Dark);
        assert!(config.contains("\"darkMode\":true"), "{config}");
        assert!(config.contains("#282a36"), "{config}");
        assert!(config.contains("\"pie1\":\"#ff5555\""), "{config}");
        let light = resolve("github").unwrap().mermaid_config(Kind::Light);
        assert!(light.contains("\"darkMode\":false"), "{light}");
    }

    #[test]
    fn importing_a_scheme_yaml_produces_a_theme_that_parses() {
        let dir = std::env::temp_dir().join(format!("mark-import-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("probe-scheme.yaml");
        let mut yaml =
            String::from("system: \"base16\"\nname: \"Probe\"\nvariant: \"light\"\npalette:\n");
        for index in 0..BASE16 {
            yaml.push_str(&format!(
                "  {}: \"#0{index:01x}0{index:01x}0{index:01x}\"\n",
                Slot(index as u8).name()
            ));
        }
        std::fs::write(&path, yaml).unwrap();
        let (toml, name) = import(&path).expect("the scheme imports");
        assert_eq!(name, "probe-scheme");
        let theme = Theme::parse(&toml, &name, Source::Builtin).expect("the output parses");
        assert_eq!(theme.kind(), Kind::Light);
        assert_eq!(theme.name(), "probe-scheme");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn importing_a_scheme_missing_a_slot_is_refused_by_name() {
        let dir = std::env::temp_dir().join(format!("mark-import-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("half.yaml");
        std::fs::write(
            &path,
            "name: \"Half\"\nvariant: \"dark\"\npalette:\n  base00: \"#000000\"\n",
        )
        .unwrap();
        let error = import(&path).unwrap_err();
        assert!(error.to_string().contains("base01"), "{error}");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn colours_parse_and_round_trip() {
        assert_eq!(Rgb::parse("#ff8800").unwrap().hex(), "#ff8800");
        assert_eq!(Rgb::parse("f80").unwrap().hex(), "#ff8800");
        assert_eq!(Rgb::parse("#zzzzzz"), None);
        assert!(Rgb::parse("#ffffff").unwrap().luminance() > 0.9);
        assert!(Rgb::parse("#000000").unwrap().luminance() < 0.1);
    }
}
