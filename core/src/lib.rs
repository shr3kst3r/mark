//! `mark`'s document core: parsing, block identity, highlighting, task
//! toggling, and directory queries — shared by the AppKit app and the CLI.
//!
//! # The C ABI
//!
//! This module is the **only** `pub extern` surface in the crate, per ADR-1
//! (`2026-08-24-rust-core-swift-appkit-shell`). Four constraints from that ADR
//! are load-bearing here, and none of them are checked by the compiler:
//!
//! 1. **The surface stays small and string-shaped.** Twelve flat functions
//!    taking and returning C strings and scalars. Growing past roughly a dozen,
//!    or needing to pass a struct, is a signal to reconsider via a superseding
//!    ADR — not to smuggle a struct across.
//!
//!    M9 spent the last slot, on [`mark_write_json`] — the one function that
//!    writes an edited document, covering both of
//!    `2026-08-24-editing-pane-and-autosave`'s new write paths (autosave, and
//!    a checkbox toggled against an unsaved buffer) because they are one verb
//!    over two substrates. Its third need, block byte ranges for the editor's
//!    source highlighting, is a **flag** on [`mark_tasks_json`] rather than
//!    the `mark_blocks_json` M5 sketched: the ceiling is reached, and the
//!    parameter answers the same question that function already answers.
//!    **The surface is now full.** Anything further is a superseding ADR.
//!
//!    M7 spent one of the two remaining slots and no more. Themes need two
//!    things from Swift — "what themes are there" and "resolve this one" — and
//!    they are one function, [`mark_theme_json`], discriminated by a flags
//!    bitmask. Selecting a theme for a *render* is a new **parameter** on the
//!    three functions that emit HTML rather than a mode switch, because
//!    ADR-2 requires highlighting to be a pure function of
//!    `(language, code, theme)` and ambient state set by a separate call is
//!    exactly what that forbids. `mark_tree_json` grew a flags parameter for
//!    the same reason: no new function.
//! 2. **Every pointer the core returns is freed with [`mark_free`].** There is
//!    no other deallocation path. That includes [`mark_version`] and
//!    [`mark_last_error`], which return owned copies precisely so the rule has
//!    no exceptions to remember.
//! 3. **No `extern "C"` function may unwind.** Every body runs inside
//!    [`catch_unwind`], and a panic becomes a null pointer or `-1` plus a
//!    message retrievable from [`mark_last_error`].
//! 4. **The core never imports AppKit and never assumes a GUI.** Everything
//!    here is equally callable from `mark-cli`.
//!
//! The Rust API in the sibling modules is the real interface; these functions
//! are a thin, panic-safe wrapper over it for Swift's benefit.

pub mod block;
pub mod diff;
pub mod highlight;
pub mod lock;
pub mod parse;
pub mod render;
pub mod rich;
pub mod tasks;
pub mod theme;
pub mod tree;

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use crate::parse::Document;
use crate::render::{RenderOptions, render};

/// The core's version, as reported by `mark doctor`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Record an error for [`mark_last_error`], and **never fail doing so**.
///
/// `try_with` and `try_borrow_mut` rather than the panicking forms, because
/// this is the one function [`guard`] calls on its recovery path: a panic here
/// would escape `guard` and unwind out of an `extern "C"` frame, which is
/// exactly the thing ADR-1 forbids. Both failure modes are pathological — a
/// re-entrant borrow, or a call during thread-local teardown — and in both the
/// right answer is to drop the message, not to take the process down.
fn set_last_error(message: impl Into<String>) {
    let _ = LAST_ERROR.try_with(|slot| {
        if let Ok(mut slot) = slot.try_borrow_mut() {
            *slot = Some(message.into());
        }
    });
}

fn clear_last_error() {
    let _ = LAST_ERROR.try_with(|slot| {
        if let Ok(mut slot) = slot.try_borrow_mut() {
            *slot = None;
        }
    });
}

/// Run `body`, converting a panic into `sentinel` plus a recorded error.
///
/// This is the mechanism behind ADR-1's "no `extern "C"` function may unwind".
/// It is a plain function rather than a macro so it can be unit-tested against
/// an actually-panicking closure, which is the only way to know it works.
fn guard<T>(sentinel: T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(payload) => {
            let detail = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "non-string panic payload".to_owned());
            set_last_error(format!("panic in mark-core: {detail}"));
            sentinel
        }
    }
}

/// Hand a `String` to the caller as an owned C string.
fn out(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(c) => c.into_raw(),
        Err(error) => {
            // An interior NUL means the document contained one; that is a
            // malformed input rather than a crash.
            set_last_error(format!("output contains an interior NUL byte: {error}"));
            std::ptr::null_mut()
        }
    }
}

/// Borrow a caller-provided C string as `&str`.
///
/// # Safety
/// `ptr` must be null or point to a NUL-terminated string valid for the call.
unsafe fn input<'a>(ptr: *const c_char, name: &str) -> Option<&'a str> {
    if ptr.is_null() {
        set_last_error(format!("{name} is null"));
        return None;
    }
    match unsafe { CStr::from_ptr(ptr) }.to_str() {
        Ok(text) => Some(text),
        Err(error) => {
            set_last_error(format!("{name} is not valid UTF-8: {error}"));
            None
        }
    }
}

/// The core's version string. Free with [`mark_free`].
#[unsafe(no_mangle)]
pub extern "C" fn mark_version() -> *mut c_char {
    guard(std::ptr::null_mut(), || out(VERSION.to_owned()))
}

/// The last error recorded **on this thread**, or null if there is none.
/// Free with [`mark_free`].
#[unsafe(no_mangle)]
pub extern "C" fn mark_last_error() -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        // Copy the message out and release the borrow *before* calling `out`.
        // `out` records an error of its own on failure, and doing that while a
        // shared borrow is still live is a `RefCell` double-borrow panic — in
        // the one function whose job is reporting failures.
        let message = LAST_ERROR
            .try_with(|slot| slot.try_borrow().ok().and_then(|slot| slot.clone()))
            .ok()
            .flatten();
        match message {
            Some(message) => out(message),
            None => std::ptr::null_mut(),
        }
    })
}

/// Free a pointer returned by any other `mark_*` function.
///
/// The single deallocation path (ADR-1). Null is a no-op.
///
/// # Safety
/// `ptr` must be null, or a pointer returned by this library and not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    guard((), || drop(unsafe { CString::from_raw(ptr) }));
}

/// Resolve a theme name to a pair, or record why it could not be.
///
/// Null or empty is the default theme, which is built in and cannot fail. A
/// name that does not resolve returns `None` **and records the reason**, so
/// every caller below can return its own failure sentinel rather than quietly
/// rendering in a theme the caller did not ask for. Plan §2 M7's gate is that a
/// broken theme is a named error rather than invisible text; silently
/// substituting the default here would be the invisible version.
fn theme_or_error(name: *const c_char) -> Option<std::sync::Arc<theme::ThemePair>> {
    if name.is_null() {
        return Some(theme::default_pair());
    }
    let name = unsafe { input(name, "theme") }?;
    match theme::resolve(name) {
        Ok(pair) => Some(pair),
        Err(error) => {
            set_last_error(error.to_string());
            None
        }
    }
}

/// Render markdown to HTML fragments, one `<div class="mk-blk">` per top-level
/// block.
///
/// `prefix_blocks` is ADR-2's first-paint tunable: emit only the first N
/// blocks, or all of them when 0. The shell derives N from viewport height and
/// appends the rest behind the paint; it is deliberately not a constant here.
///
/// `theme` names a theme, or is null for the default. It is a parameter rather
/// than process state because ADR-2 requires highlighting to be a pure function
/// of `(language, code, theme)`, and because the emitted HTML for a code block
/// carries the theme's palette *slots* — `<span class="t0B">` — whose colours
/// come from CSS. Two themes with the same scope map therefore produce the same
/// bytes, which is what makes a theme change need no re-render.
///
/// Returns null on failure. Free with [`mark_free`].
///
/// # Safety
/// `source` and `theme` must be null or NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_render_html(
    source: *const c_char,
    prefix_blocks: usize,
    theme: *const c_char,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(source) = (unsafe { input(source, "source") }) else {
            return std::ptr::null_mut();
        };
        clear_last_error();
        let Some(theme) = theme_or_error(theme) else {
            return std::ptr::null_mut();
        };
        let doc = Document::parse(source);
        let options = RenderOptions {
            prefix_blocks: (prefix_blocks > 0).then_some(prefix_blocks),
            theme,
            ..RenderOptions::default()
        };
        out(render(&doc, &options).html)
    })
}

/// Render an arbitrary half-open range of top-level blocks, `start..end`.
///
/// The companion to [`mark_render_html`], and the reason it exists is ADR-2's
/// background fill: without it the shell has to render the *whole* document to
/// obtain the tail after the prefix, then slice the result by string prefix.
///
/// Both bounds are clamped to the document's block count, so a pump can walk
/// `0..n`, `n..2n`, … and stop when the returned string is **empty** — an empty
/// string is "the range is past the end of the document", not a failure. Pass
/// `SIZE_MAX` as `end` for "to the end".
///
/// A reversed range (`end < start`) is a caller bug rather than an empty slice,
/// and returns null with the reason in [`mark_last_error`].
///
/// Returns null on failure. Free with [`mark_free`].
///
/// # Safety
/// `source` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_render_range(
    source: *const c_char,
    start: usize,
    end: usize,
    theme: *const c_char,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(source) = (unsafe { input(source, "source") }) else {
            return std::ptr::null_mut();
        };
        clear_last_error();
        if end < start {
            set_last_error(format!("block range {start}..{end} is reversed"));
            return std::ptr::null_mut();
        }
        let Some(theme) = theme_or_error(theme) else {
            return std::ptr::null_mut();
        };
        let doc = Document::parse(source);
        out(crate::render::render_range_themed(&doc, start..end, &theme).html)
    })
}

/// Diff two versions of a document into ADR-2's minimal edit script, as JSON.
///
/// `{"ops":[…],"old_blocks":n,"new_blocks":n,"kept":n,"inserted":n,
/// "deleted":n,"replaced":n,"coarse":false}`, where each op is one of
/// `keep` / `delete` / `insert` / `replace`, addressed by the `data-blk` ids
/// the rendered HTML already carries. `insert` and `replace` carry the HTML of
/// the blocks they introduce, so patching needs no second call.
///
/// Returns null on failure. Free with [`mark_free`].
///
/// # Safety
/// `old_source` and `new_source` must be NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_diff_json(
    old_source: *const c_char,
    new_source: *const c_char,
    theme: *const c_char,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(old_source) = (unsafe { input(old_source, "old_source") }) else {
            return std::ptr::null_mut();
        };
        let Some(new_source) = (unsafe { input(new_source, "new_source") }) else {
            return std::ptr::null_mut();
        };
        clear_last_error();
        // The script carries rendered HTML for every block it introduces, so
        // it needs the theme for the same reason a render does: an inserted
        // code block must arrive in the slot classes the page already uses.
        let Some(theme) = theme_or_error(theme) else {
            return std::ptr::null_mut();
        };
        let old = Document::parse(old_source);
        let new = Document::parse(new_source);
        json_out(&diff::diff_documents(&old, &new, &theme))
    })
}

/// Ask [`mark_tasks_json`] for the document's **blocks** as well as its tasks.
///
/// Set, the response becomes an object rather than a bare array. See that
/// function for why this is a flag and not a twelfth entry point.
pub const MARK_TASKS_BLOCKS: c_int = 1 << 0;

/// Every task in the document as a JSON array of
/// `{index, checked, start, end, line, text}`.
///
/// With [`MARK_TASKS_BLOCKS`] the answer is instead
/// `{"tasks":[…],"blocks":[{id, kind, start, end, hash, ordinal, …}]}` — the
/// top-level blocks and their byte ranges, from the same parse.
///
/// **Why a flag rather than a `mark_blocks_json`.** M5 recorded that a *kept*
/// block's `data-mk-start` / `data-mk-end` go stale after a patch and cannot
/// be refreshed over this ABI, and that
/// `2026-08-24-editing-pane-and-autosave`'s editor — which drives markdown
/// source highlighting from "the core's existing block byte ranges" — must
/// therefore take them from a fresh parse of the buffer and never from the
/// DOM. That is what this flag is for. ADR-1 caps the surface at *"roughly a
/// dozen"* functions and M7 and M8 have already spent their slots, so this
/// follows the precedent both of them set: a parameter on the function that
/// already answers "where is everything in this source", not a new function.
///
/// It also saves a parse. The editor needs blocks to highlight and tasks to
/// keep the preview's checkbox indices honest against a dirty buffer, and one
/// call answers both from one `Document::parse`.
///
/// Returns null on failure. Free with [`mark_free`].
///
/// # Safety
/// `source` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_tasks_json(source: *const c_char, flags: c_int) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(source) = (unsafe { input(source, "source") }) else {
            return std::ptr::null_mut();
        };
        clear_last_error();
        if flags & MARK_TASKS_BLOCKS == 0 {
            return json_out(&tasks::enumerate_source(source));
        }
        let doc = Document::parse(source);
        json_out(&serde_json::json!({
            "tasks": tasks::enumerate(&doc),
            "blocks": doc.blocks(),
        }))
    })
}

/// The heading tree as a JSON array of
/// `{level, text, anchor, start, end, line, block}`.
///
/// Returns null on failure. Free with [`mark_free`].
///
/// # Safety
/// `source` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_toc_json(source: *const c_char) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(source) = (unsafe { input(source, "source") }) else {
            return std::ptr::null_mut();
        };
        clear_last_error();
        json_out(&Document::parse(source).headings())
    })
}

/// `0 = off, 1 = on, 2 = toggle`, or `None` with the reason recorded.
///
/// Shared by [`mark_toggle`] and [`mark_write_json`] so the file path and the
/// buffer path cannot disagree about what an action means.
fn toggle_action(action: c_int) -> Option<tasks::Action> {
    match action {
        0 => Some(tasks::Action::Off),
        1 => Some(tasks::Action::On),
        2 => Some(tasks::Action::Toggle),
        other => {
            set_last_error(format!(
                "unknown toggle action {other}; expected 0, 1, or 2"
            ));
            None
        }
    }
}

/// Toggle task `index` in the file at `path`, in place.
///
/// `action` is 0 = off, 1 = on, 2 = toggle. Returns the new state (0 or 1), or
/// `-1` on failure with the reason in [`mark_last_error`]. Exactly one byte of
/// the file changes, and the write goes through a temp file and a rename.
///
/// # Safety
/// `path` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_toggle(path: *const c_char, index: usize, action: c_int) -> c_int {
    guard(-1, || {
        let Some(path) = (unsafe { input(path, "path") }) else {
            return -1;
        };
        let Some(action) = toggle_action(action) else {
            return -1;
        };
        clear_last_error();
        match tasks::toggle_file(Path::new(path), index, action) {
            Ok(toggled) => c_int::from(toggled.checked),
            Err(error) => {
                set_last_error(error.to_string());
                -1
            }
        }
    })
}

/// "This call is not a toggle" — see [`mark_write_json`].
pub const MARK_NO_TASK: usize = usize::MAX;

/// The one write path for an edited document: save a buffer, toggle a task in
/// one, or both.
///
/// `2026-08-24-editing-pane-and-autosave` puts two new demands on the core and
/// this function is both of them, because they are the same verb applied to
/// two substrates:
///
/// * *"Autosave writes 800 ms after typing stops, through
///   `core::tasks::write_atomically`"*, and *"every write goes through
///   `write_atomically`. No direct `fs::write` to a user's document, ever."*
///   Pass `source`, a `path`, and [`MARK_NO_TASK`].
/// * *"Checkbox clicks while dirty apply to the buffer, not the file. The
///   core's byte-range toggle runs against the buffer's bytes and the result
///   re-enters the buffer."* Pass `source` and an `index`, with `path` null.
///
/// | `path` | `index` | what happens |
/// |---|---|---|
/// | non-null | [`MARK_NO_TASK`] | `source` is written atomically |
/// | null | a task index | `source` is toggled, nothing is written |
/// | non-null | a task index | both, in that order |
///
/// The response is `{"written":bool,"bytes":n,"path":"…"}` for a save, and
/// additionally `{"source":"…","index":n,"checked":bool,"offset":n,"text":"…"}`
/// when a task was toggled. `path` in the response is the **canonicalized**
/// target, which is where the bytes actually landed: `write_atomically`
/// resolves symlinks before renaming, because `rename(2)` replaces the name
/// and not the file, and the M1 review found that destroying a symlinked note.
/// Autosave now runs that path every 800 ms.
///
/// Deliberately **not** a variant of [`mark_toggle`]: that one re-reads the
/// file for itself, which is exactly the wrong thing when the buffer is the
/// source of truth. A clean tab keeps using it, unchanged.
///
/// Returns null on failure, with the reason in [`mark_last_error`]. Nothing is
/// written when it fails. Free with [`mark_free`].
///
/// # Safety
/// `path` must be null or a NUL-terminated UTF-8 string; `source` must be a
/// NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_write_json(
    path: *const c_char,
    source: *const c_char,
    index: usize,
    action: c_int,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(source) = (unsafe { input(source, "source") }) else {
            return std::ptr::null_mut();
        };
        let path = if path.is_null() {
            None
        } else {
            match unsafe { input(path, "path") } {
                Some(path) => Some(path),
                None => return std::ptr::null_mut(),
            }
        };
        clear_last_error();

        let mut response = serde_json::Map::new();
        let mut contents = std::borrow::Cow::Borrowed(source);

        if index != MARK_NO_TASK {
            let Some(action) = toggle_action(action) else {
                return std::ptr::null_mut();
            };
            match tasks::toggle(source, index, action) {
                Ok(toggled) => {
                    response.insert("index".into(), toggled.index.into());
                    response.insert("checked".into(), toggled.checked.into());
                    response.insert("offset".into(), toggled.offset.into());
                    response.insert("text".into(), toggled.text.clone().into());
                    response.insert("source".into(), toggled.source.clone().into());
                    contents = std::borrow::Cow::Owned(toggled.source);
                }
                Err(error) => {
                    set_last_error(error.to_string());
                    return std::ptr::null_mut();
                }
            }
        } else if path.is_none() {
            set_last_error(
                "mark_write_json with no path and no task index would do nothing".to_owned(),
            );
            return std::ptr::null_mut();
        }

        match path {
            Some(path) => {
                let path = Path::new(path);
                // The message already names the path, and — when the write was
                // refused because another `mark` holds the document — the pid
                // holding it. Prefixing the path again would say it twice.
                if let Err(error) = tasks::write_atomically(path, &contents) {
                    set_last_error(error.to_string());
                    return std::ptr::null_mut();
                }
                let landed = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
                response.insert("written".into(), true.into());
                response.insert("bytes".into(), contents.len().into());
                response.insert("path".into(), landed.display().to_string().into());
            }
            None => {
                response.insert("written".into(), false.into());
            }
        }
        json_out(&serde_json::Value::Object(response))
    })
}

/// Include non-markdown files in a [`mark_tree_json`] listing.
///
/// Named constants rather than magic numbers, and `pub` so the Swift side can
/// assert against these values rather than restating them.
pub const MARK_TREE_ALL_FILES: c_int = 1 << 0;
/// Include dotfiles and dot-directories in a [`mark_tree_json`] listing.
pub const MARK_TREE_HIDDEN: c_int = 1 << 1;

/// List a directory as a JSON array of
/// `{path, name, is_dir, depth, title?, tasks?}`.
///
/// `depth` is levels below `dir`, minimum 1 — there is no unlimited walk, since
/// the user's real tree holds 608k files (research 2.8). `with_stats` non-zero
/// opens each markdown file for its title and task counts.
///
/// `flags` is [`MARK_TREE_ALL_FILES`] | [`MARK_TREE_HIDDEN`], reaching the two
/// options `tree::Options` has always modelled.
///
/// **Why a parameter and not a new function.** M8 needed both toggles, found
/// this function hardcoding `..Options::default()`, and reimplemented them in
/// Swift over `FileManager` — which left one gap it structurally could not
/// close: the core drops non-markdown files *after* the `.gitignore` test, so
/// it knows a `build.log` is ignored and had no way to say so, and a gitignored
/// non-markdown file appeared in the tree with the toggle on. A flags argument
/// closes that with no new ABI surface, which matters because ADR-1's ceiling
/// is "roughly a dozen" and M7 already spent a slot on themes.
///
/// Returns null on failure. Free with [`mark_free`].
///
/// # Safety
/// `dir` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_tree_json(
    dir: *const c_char,
    depth: usize,
    with_stats: c_int,
    flags: c_int,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let Some(dir) = (unsafe { input(dir, "dir") }) else {
            return std::ptr::null_mut();
        };
        clear_last_error();
        let options = tree::Options {
            max_depth: depth.max(1),
            with_stats: with_stats != 0,
            markdown_only: flags & MARK_TREE_ALL_FILES == 0,
            hidden: flags & MARK_TREE_HIDDEN != 0,
        };
        match tree::list_dir(Path::new(dir), &options) {
            Ok(entries) => json_out(&entries),
            Err(error) => {
                set_last_error(error.to_string());
                std::ptr::null_mut()
            }
        }
    })
}

/// List the available themes, or resolve one.
///
/// `flags` is [`MARK_THEME_LIST`] or 0. With it, `name` is ignored and the
/// answer is
/// `{"themes":[{name,title,kind,pair?,author?,source}],"default":"…","dir":"…","problems":[…]}`.
/// Without it, `name` (null or empty for the default) resolves to a **pair** —
/// a light theme and a dark one, chosen together — and the answer is
///
/// ```json
/// {"name":"dracula","kind":"dark","paired":false,
///  "light":{…},"dark":{…},"css":"…","codeStamp":"…",
///  "palette":{…},"document":{…},"code":[[scope,slot],…]}
/// ```
///
/// `css` is the whole light/dark mechanism: custom properties for **both**
/// appearances, the dark half inside `@media (prefers-color-scheme: dark)`. The
/// app injects it once per web view; an appearance switch after that costs no
/// IPC, no re-render, and no DOM work.
///
/// `codeStamp` identifies the scope → slot map, which is the only part of a
/// theme the rendered HTML depends on. A caller comparing stamps across a theme
/// change knows whether it must re-render (it must not, for any theme that
/// ships) or can simply swap the CSS.
///
/// Returns null on failure, with a named reason in [`mark_last_error`]. Free
/// with [`mark_free`].
///
/// # Safety
/// `name` must be null or a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mark_theme_json(name: *const c_char, flags: c_int) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        clear_last_error();
        if flags & MARK_THEME_LIST != 0 {
            let (themes, problems) = theme::list();
            return json_out(&serde_json::json!({
                "themes": themes,
                "default": theme::DEFAULT_THEME,
                "dir": theme::user_dir().map(|dir| dir.display().to_string()),
                // A user file that will not parse is *reported*, not dropped:
                // "my theme vanished" is the failure this whole module exists
                // to prevent.
                "problems": problems,
            }));
        }
        let Some(pair) = theme_or_error(name) else {
            return std::ptr::null_mut();
        };
        json_out(&theme_detail(&pair))
    })
}

/// [`mark_theme_json`]'s "list them" flag.
pub const MARK_THEME_LIST: c_int = 1 << 0;

/// The resolved-theme response, shared by the ABI and `mark theme --show`.
fn theme_detail(pair: &theme::ThemePair) -> serde_json::Value {
    let describe = |theme: &theme::Theme| {
        serde_json::json!({
            "name": theme.name(),
            "title": theme.title(),
            "kind": theme.kind(),
            "author": theme.author(),
            "source": theme.source(),
            "palette": theme
                .palette()
                .iter()
                .enumerate()
                .filter_map(|(index, color)| {
                    let slot = theme::Slot::parse(&format!("base{index:02X}"))?;
                    Some((slot.name(), (*color)?.hex()))
                })
                .collect::<std::collections::BTreeMap<_, _>>(),
            "document": theme
                .document()
                .iter()
                .map(|(key, slot)| {
                    (
                        key.clone(),
                        serde_json::json!({
                            "slot": slot.name(),
                            "color": theme.color(*slot).map(|color| color.hex()),
                        }),
                    )
                })
                .collect::<std::collections::BTreeMap<_, _>>(),
        })
    };
    serde_json::json!({
        "name": pair.name(),
        "kind": pair.primary().kind(),
        "paired": !pair.is_single(),
        "light": describe(pair.light()),
        "dark": describe(pair.dark()),
        "css": pair.css(),
        "codeStamp": format!("{:016x}", pair.code_stamp()),
        "code": pair
            .primary()
            .code()
            .iter()
            .map(|(scope, slot)| serde_json::json!([scope, slot.name()]))
            .collect::<Vec<_>>(),
    })
}

fn json_out<T: serde::Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(json) => out(json),
        Err(error) => {
            set_last_error(format!("serializing response failed: {error}"));
            std::ptr::null_mut()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Null is "the default theme" everywhere in the ABI, which is what the
    /// vast majority of these tests want to say.
    const THEME: *const c_char = std::ptr::null();

    /// Run `body` with the panic hook silenced, so a deliberately panicking
    /// test does not scribble a backtrace over the test output.
    fn without_panic_noise<T>(body: impl FnOnce() -> T) -> T {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = body();
        std::panic::set_hook(previous);
        result
    }

    fn take(ptr: *mut c_char) -> Option<String> {
        if ptr.is_null() {
            return None;
        }
        let text = unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe { mark_free(ptr) };
        Some(text)
    }

    fn c(text: &str) -> CString {
        CString::new(text).unwrap()
    }

    #[test]
    fn guard_turns_a_panic_into_the_sentinel() {
        let value = without_panic_noise(|| guard(-7, || panic!("boom")));
        assert_eq!(value, -7);
        let message = take(mark_last_error()).expect("panic recorded a message");
        assert_eq!(message, "panic in mark-core: boom");
    }

    #[test]
    fn guard_records_non_string_payloads_too() {
        let value = without_panic_noise(|| guard(0u8, || std::panic::panic_any(42u32)));
        assert_eq!(value, 0);
        let message = take(mark_last_error()).unwrap();
        assert_eq!(message, "panic in mark-core: non-string panic payload");
    }

    #[test]
    fn version_round_trips() {
        assert_eq!(take(mark_version()).as_deref(), Some(VERSION));
    }

    #[test]
    fn free_of_null_is_a_no_op() {
        unsafe { mark_free(std::ptr::null_mut()) };
    }

    #[test]
    fn render_emits_block_ids_and_task_spans() {
        let source = c("# T\n\n- [x] done\n");
        let html = take(unsafe { mark_render_html(source.as_ptr(), 0, THEME) }).unwrap();
        assert!(html.contains("data-blk="), "{html}");
        assert!(html.contains("class=\"mk-task\""), "{html}");
    }

    #[test]
    fn render_honours_the_prefix_tunable() {
        let source = c("a\n\nb\n\nc\n");
        let two = take(unsafe { mark_render_html(source.as_ptr(), 2, THEME) }).unwrap();
        assert_eq!(two.matches("mk-blk").count(), 2, "{two}");
        let all = take(unsafe { mark_render_html(source.as_ptr(), 0, THEME) }).unwrap();
        assert_eq!(all.matches("mk-blk").count(), 3, "{all}");
    }

    #[test]
    fn render_range_emits_exactly_the_requested_blocks() {
        let source = c("a\n\nb\n\nc\n");
        let middle = take(unsafe { mark_render_range(source.as_ptr(), 1, 2, THEME) }).unwrap();
        assert_eq!(middle.matches("mk-blk").count(), 1, "{middle}");
        assert!(middle.contains(">b</p>"), "{middle}");
        assert!(
            !middle.contains(">a</p>") && !middle.contains(">c</p>"),
            "{middle}"
        );
    }

    #[test]
    fn render_range_over_a_partition_equals_a_whole_render() {
        // The property M2 currently gets by rendering everything and slicing.
        let source = c("# H\n\n- [ ] t\n\n```rust\nfn f() {}\n```\n\npara\n");
        let whole = take(unsafe { mark_render_html(source.as_ptr(), 0, THEME) }).unwrap();
        let head = take(unsafe { mark_render_range(source.as_ptr(), 0, 2, THEME) }).unwrap();
        let tail =
            take(unsafe { mark_render_range(source.as_ptr(), 2, usize::MAX, THEME) }).unwrap();
        assert_eq!(whole, format!("{head}{tail}"));
    }

    #[test]
    fn an_empty_range_is_an_empty_string_not_a_failure() {
        let source = c("a\n\nb\n");
        for (start, end) in [(1usize, 1usize), (9, 9), (5, 12)] {
            let pointer = unsafe { mark_render_range(source.as_ptr(), start, end, THEME) };
            assert!(!pointer.is_null(), "{start}..{end} returned null");
            assert_eq!(take(pointer).as_deref(), Some(""), "{start}..{end}");
        }
    }

    #[test]
    fn a_reversed_range_is_an_error_not_a_wrong_slice() {
        let source = c("a\n\nb\n\nc\n");
        assert!(unsafe { mark_render_range(source.as_ptr(), 2, 1, THEME) }.is_null());
        assert_eq!(
            take(mark_last_error()).as_deref(),
            Some("block range 2..1 is reversed")
        );
    }

    #[test]
    fn diff_json_describes_an_inserted_paragraph() {
        let old = c("# H\n\nalpha\n");
        let new = c("# H\n\ninserted\n\nalpha\n");
        let json = take(unsafe { mark_diff_json(old.as_ptr(), new.as_ptr(), THEME) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["old_blocks"], 2);
        assert_eq!(parsed["new_blocks"], 3);
        assert_eq!(parsed["inserted"], 1);
        assert_eq!(parsed["deleted"], 0);
        assert_eq!(parsed["coarse"], false);

        let ops = parsed["ops"].as_array().unwrap();
        let kinds: Vec<&str> = ops.iter().map(|op| op["op"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["keep", "insert", "keep"], "{json}");
        let html = ops[1]["html"].as_str().unwrap();
        assert!(html.contains("inserted"), "{html}");
        assert!(html.contains("data-blk="), "{html}");
    }

    #[test]
    fn diff_json_of_an_unchanged_document_is_all_keep() {
        let source = c("# H\n\nalpha\n\n- [x] done\n");
        let json =
            take(unsafe { mark_diff_json(source.as_ptr(), source.as_ptr(), THEME) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        let ops = parsed["ops"].as_array().unwrap();
        assert_eq!(ops.len(), 1, "{json}");
        assert_eq!(ops[0]["op"], "keep");
        assert_eq!(ops[0]["count"], 3);
    }

    #[test]
    fn diff_json_rejects_a_null_source_on_either_side() {
        let source = c("a\n");
        assert!(unsafe { mark_diff_json(std::ptr::null(), source.as_ptr(), THEME) }.is_null());
        assert_eq!(
            take(mark_last_error()).as_deref(),
            Some("old_source is null")
        );
        assert!(unsafe { mark_diff_json(source.as_ptr(), std::ptr::null(), THEME) }.is_null());
        assert_eq!(
            take(mark_last_error()).as_deref(),
            Some("new_source is null")
        );
    }

    #[test]
    fn tasks_and_toc_are_json() {
        let source = c("# H\n\n- [ ] a\n");
        let tasks = take(unsafe { mark_tasks_json(source.as_ptr(), 0) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&tasks).unwrap();
        assert_eq!(parsed[0]["index"], 0);
        assert_eq!(parsed[0]["checked"], false);

        let toc = take(unsafe { mark_toc_json(source.as_ptr()) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&toc).unwrap();
        assert_eq!(parsed[0]["anchor"], "h");
    }

    #[test]
    fn tasks_json_can_carry_the_blocks_too() {
        let text = "# Title\n\npara\n\n- [ ] task\n";
        let source = c(text);
        // Flags 0 is the shape every caller before M9 gets, unchanged.
        let bare = take(unsafe { mark_tasks_json(source.as_ptr(), 0) }).unwrap();
        assert!(bare.starts_with('['), "flags 0 must still be a bare array");

        let both = take(unsafe { mark_tasks_json(source.as_ptr(), MARK_TASKS_BLOCKS) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&both).unwrap();
        assert_eq!(parsed["tasks"][0]["index"], 0);
        let blocks = parsed["blocks"].as_array().unwrap();
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0]["kind"], "heading");
        assert_eq!(blocks[0]["level"], 1);
        // The byte ranges are what the editor highlights from, so they are
        // asserted against the source rather than against each other.
        for block in blocks {
            let start = block["start"].as_u64().unwrap() as usize;
            let end = block["end"].as_u64().unwrap() as usize;
            assert!(start < end && end <= text.len());
        }
        let first = &blocks[0];
        let start = first["start"].as_u64().unwrap() as usize;
        let end = first["end"].as_u64().unwrap() as usize;
        assert_eq!(text[start..end].trim(), "# Title");
    }

    #[test]
    fn write_json_saves_a_buffer_atomically() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("note.md");
        std::fs::write(&file, "old\n").unwrap();

        let path = c(file.to_str().unwrap());
        let source = c("new contents\n");
        let response =
            take(unsafe { mark_write_json(path.as_ptr(), source.as_ptr(), MARK_NO_TASK, 2) })
                .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["written"], true);
        assert_eq!(parsed["bytes"], 13);
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "new contents\n");
        // No temp file left behind: a `.note.md.mark-*.tmp` surviving would
        // show up in the user's directory listing and in git status.
        let leftovers: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name != "note.md")
            .collect();
        assert!(leftovers.is_empty(), "left behind {leftovers:?}");
    }

    /// The M1 review's symlink bug, on the path autosave now runs every
    /// 800 ms: `rename(2)` replaces the *name*, so a naive save would delete
    /// the link and leave the real note holding the old bytes.
    #[test]
    fn write_json_through_a_symlink_writes_the_real_file() {
        let directory = tempfile::tempdir().unwrap();
        let real = directory.path().join("real.md");
        let link = directory.path().join("link.md");
        std::fs::write(&real, "old\n").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        let path = c(link.to_str().unwrap());
        let source = c("edited through the link\n");
        let response =
            take(unsafe { mark_write_json(path.as_ptr(), source.as_ptr(), MARK_NO_TASK, 2) })
                .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(
            std::fs::read_to_string(&real).unwrap(),
            "edited through the link\n"
        );
        assert!(
            std::fs::symlink_metadata(&link).unwrap().is_symlink(),
            "the link was replaced by a regular file"
        );
        // The response names where the bytes actually landed, not where the
        // caller pointed.
        assert_eq!(
            parsed["path"].as_str().unwrap(),
            std::fs::canonicalize(&real).unwrap().to_str().unwrap()
        );
    }

    #[test]
    fn write_json_toggles_a_buffer_without_touching_the_file() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("note.md");
        std::fs::write(&file, "- [ ] on disk\n").unwrap();

        let buffer = c("- [ ] in the buffer\n- [ ] second\n");
        let response =
            take(unsafe { mark_write_json(std::ptr::null(), buffer.as_ptr(), 1, 1) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["written"], false);
        assert_eq!(parsed["checked"], true);
        assert_eq!(parsed["index"], 1);
        assert_eq!(
            parsed["source"].as_str().unwrap(),
            "- [ ] in the buffer\n- [x] second\n"
        );
        // The file is untouched: a dirty tab's checkbox click must not write.
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "- [ ] on disk\n");
    }

    #[test]
    fn write_json_refuses_a_bad_index_and_writes_nothing() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("note.md");
        std::fs::write(&file, "unchanged\n").unwrap();

        let path = c(file.to_str().unwrap());
        let buffer = c("- [ ] only one task\n");
        assert!(unsafe { mark_write_json(path.as_ptr(), buffer.as_ptr(), 7, 1) }.is_null());
        assert!(take(mark_last_error()).unwrap().contains("7"));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "unchanged\n");
    }

    #[test]
    fn write_json_with_nothing_to_do_is_an_error() {
        let buffer = c("plain\n");
        assert!(
            unsafe { mark_write_json(std::ptr::null(), buffer.as_ptr(), MARK_NO_TASK, 2) }
                .is_null()
        );
        assert!(
            take(mark_last_error())
                .unwrap()
                .contains("would do nothing")
        );
    }

    #[test]
    fn write_json_can_toggle_and_save_in_one_call() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("note.md");
        std::fs::write(&file, "stale\n").unwrap();

        let path = c(file.to_str().unwrap());
        let buffer = c("- [x] done\n");
        let response =
            take(unsafe { mark_write_json(path.as_ptr(), buffer.as_ptr(), 0, 0) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(parsed["checked"], false);
        assert_eq!(parsed["written"], true);
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "- [ ] done\n");
    }

    #[test]
    fn null_input_is_an_error_not_a_crash() {
        assert!(unsafe { mark_render_html(std::ptr::null(), 0, THEME) }.is_null());
        assert_eq!(take(mark_last_error()).as_deref(), Some("source is null"));
        assert_eq!(unsafe { mark_toggle(std::ptr::null(), 0, 2) }, -1);
        assert_eq!(take(mark_last_error()).as_deref(), Some("path is null"));
    }

    #[test]
    fn an_unknown_toggle_action_is_refused() {
        let path = c("/tmp/does-not-matter.md");
        assert_eq!(unsafe { mark_toggle(path.as_ptr(), 0, 9) }, -1);
        assert_eq!(
            take(mark_last_error()).as_deref(),
            Some("unknown toggle action 9; expected 0, 1, or 2")
        );
    }

    #[test]
    fn toggle_reports_a_missing_file_rather_than_writing_one() {
        let path = c("/definitely/not/here.md");
        assert_eq!(unsafe { mark_toggle(path.as_ptr(), 0, 2) }, -1);
        let message = take(mark_last_error()).unwrap();
        assert!(message.starts_with("/definitely/not/here.md:"), "{message}");
        assert!(!Path::new("/definitely/not/here.md").exists());
    }

    #[test]
    fn last_error_is_null_when_nothing_failed() {
        clear_last_error();
        assert!(mark_last_error().is_null());
    }

    #[test]
    fn recording_an_error_from_inside_a_live_borrow_does_not_panic() {
        // `guard`'s recovery path calls `set_last_error`, so if that can panic
        // the panic escapes `guard` and unwinds out of an `extern "C"` frame —
        // the one thing ADR-1 forbids. Hold a borrow and prove it cannot.
        clear_last_error();
        LAST_ERROR.with(|slot| {
            let _held = slot.borrow_mut();
            set_last_error("dropped rather than panicking");
            clear_last_error();
        });
        // The message was dropped, not written, and nothing unwound.
        assert!(mark_last_error().is_null());
    }

    #[test]
    fn reading_the_error_twice_gives_two_independently_freeable_copies() {
        // ADR-1 has exactly one deallocation path, with no borrowed pointers
        // escaping. Two reads must therefore be two allocations, not one shared
        // buffer that the second `mark_free` would double-free.
        set_last_error("owned copy");
        let first = mark_last_error();
        let second = mark_last_error();
        assert!(!first.is_null() && !second.is_null());
        assert_ne!(first, second, "callers were handed the same allocation");
        assert_eq!(take(first).as_deref(), Some("owned copy"));
        assert_eq!(take(second).as_deref(), Some("owned copy"));
        clear_last_error();
    }

    #[test]
    fn version_is_an_owned_copy_not_a_static_pointer() {
        let first = mark_version();
        let second = mark_version();
        assert_ne!(first, second, "mark_version handed out a shared pointer");
        assert_ne!(first.cast_const().cast::<u8>(), VERSION.as_ptr());
        assert_eq!(take(first), take(second));
    }

    #[test]
    fn tree_json_lists_the_repository_root() {
        let dir = c(env!("CARGO_MANIFEST_DIR"));
        let json = take(unsafe { mark_tree_json(dir.as_ptr(), 1, 0, 0) }).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(parsed.as_array().is_some_and(|a| !a.is_empty()), "{json}");
    }
}
