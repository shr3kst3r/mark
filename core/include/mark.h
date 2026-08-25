/*
 * mark-core's C ABI.
 *
 * Hand-written, per ADR-1 (2026-08-24-rust-core-swift-appkit-shell): the
 * surface is small enough that a generator's configuration would be larger
 * than this file. Swift consumes it via -import-objc-header in M2.
 *
 * Rules that are not expressible in C and must be obeyed by every caller:
 *
 *   - Every non-NULL char* returned here is freed with mark_free(), and with
 *     nothing else. That includes mark_version() and mark_last_error().
 *   - No function unwinds. Failure is NULL (for pointers) or -1 (for ints),
 *     with the reason available from mark_last_error().
 *   - mark_last_error() is thread-local. Read it on the thread that failed.
 *
 * Growing this past roughly a dozen functions, or needing to pass a struct
 * across, is the signal ADR-1 names for reconsidering the design in a
 * superseding ADR.
 */

#ifndef MARK_H
#define MARK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Core version, e.g. "0.1.0". Free with mark_free(). */
char *mark_version(void);

/* Last error on this thread, or NULL. Free with mark_free(). */
char *mark_last_error(void);

/* The one deallocation path. NULL is a no-op. */
void mark_free(char *ptr);

/*
 * Markdown -> HTML, one <div class="mk-blk" data-blk="..."> per top-level
 * block, task markers carrying data-mk-idx / data-mk-start / data-mk-end.
 *
 * prefix_blocks emits only the first N blocks (ADR-2's first-paint tunable,
 * derived from viewport height by the caller); 0 emits the whole document.
 *
 * theme names a theme (mark_theme_json lists them), or is NULL for the
 * default. It is a parameter rather than process state because ADR-2 requires
 * highlighting to be a pure function of (language, code, theme). Code tokens
 * are emitted as palette *slots* -- <span class="t0B"> -- whose colours come
 * from CSS custom properties carrying both appearances, so the rendered HTML
 * does not change when the appearance does.
 *
 * A theme that does not exist, or that is missing a palette slot something
 * references, returns NULL with a named reason in mark_last_error(). It never
 * silently falls back to the default: invisible text is the failure this
 * refusal exists to prevent.
 *
 * Returns NULL on failure.
 */
char *mark_render_html(const char *source, size_t prefix_blocks, const char *theme);

/*
 * The same, for an arbitrary half-open block range [start, end).
 *
 * The companion to mark_render_html for ADR-2's background fill: without it a
 * caller must render the whole document and slice the prefix off the front to
 * obtain a tail.
 *
 * Both bounds are clamped to the document's block count, so a pump can walk
 * 0..n, n..2n, ... and stop when the result is the EMPTY STRING. Empty means
 * "past the end of the document" and is NOT a failure; failure is NULL. Pass
 * SIZE_MAX as `end` for "to the end of the document".
 *
 * A reversed range (end < start) is a caller bug, not an empty slice: it
 * returns NULL with the reason in mark_last_error().
 */
char *mark_render_range(const char *source, size_t start, size_t end,
                        const char *theme);

/*
 * Diff two versions of one document into ADR-2's minimal edit script, as JSON:
 *
 *   {"ops":[...], "old_blocks":N, "new_blocks":N,
 *    "kept":N, "inserted":N, "deleted":N, "replaced":N, "coarse":false}
 *
 * Each op is tagged "keep" | "delete" | "insert" | "replace" and carries
 * old_index / new_index. Blocks are named by the same data-blk values the
 * rendered HTML already carries: "delete" and "replace" list old_ids,
 * "insert" and "replace" list new_ids plus the rendered "html" of the blocks
 * they introduce, and "insert" carries "before" — the data-blk to insert in
 * front of, or null to append.
 *
 * "coarse":true means the edit distance exceeded the search budget and the
 * differing middle was replaced wholesale: still correct, no longer minimal.
 *
 * Returns NULL on failure.
 */
char *mark_diff_json(const char *old_source, const char *new_source,
                     const char *theme);

/*
 * JSON array of {index, checked, start, end, line, text}. NULL on failure.
 *
 * With MARK_TASKS_BLOCKS the answer is an object instead:
 *
 *   {"tasks":[...],
 *    "blocks":[{"id":"<hash>-<ordinal>","kind":"heading","level":1,
 *               "start":0,"end":8,"hash":...,"ordinal":0}, ...]}
 *
 * i.e. the top-level blocks and their byte ranges, from the same parse.
 *
 * A flag rather than a mark_blocks_json, for the reason M8 gave for
 * mark_tree_json's: ADR-1's ceiling is "roughly a dozen" functions and M9
 * spends the last slot on mark_write_json. The editor pane of
 * 2026-08-24-editing-pane-and-autosave drives markdown *source* highlighting
 * from these ranges, and must read them from a fresh parse of its buffer --
 * never off the DOM, where a kept block's data-mk-start/end go stale after a
 * patch (M5, DocumentPatchTests.blockByteSpansStayStaleOnKeptBlocks).
 */
#define MARK_TASKS_BLOCKS 1

char *mark_tasks_json(const char *source, int flags);

/* JSON array of {level, text, anchor, start, end, line, block}. NULL on failure. */
char *mark_toc_json(const char *source);

/*
 * Toggle task `index` in the file at `path`, in place: exactly one byte
 * changes, written via a temp file and a rename.
 *
 * Takes an exclusive, non-blocking flock(2) on the document first and fails if
 * another mark holds it (2026-08-25-flock-write-locking). The lock is released
 * before this returns; a caller that needs to *hold* one across several writes
 * takes its own -- see mark_write_json below.
 *
 * action: 0 = off, 1 = on, 2 = toggle.
 * Returns the new state (0 or 1), or -1 on failure.
 */
int mark_toggle(const char *path, size_t index, int action);

/*
 * The one write path for an edited document: save a buffer, toggle a task in
 * one, or both. JSON on success, NULL on failure -- and on failure nothing
 * has been written.
 *
 *   path      index          effect
 *   --------  -------------  ------------------------------------------------
 *   non-NULL  MARK_NO_TASK   `source` is written atomically
 *   NULL      a task index   `source` is toggled; nothing is written
 *   non-NULL  a task index   both, in that order
 *
 * Response: {"written":bool,"bytes":N,"path":"..."} for a save, plus
 * {"source":"...","index":N,"checked":bool,"offset":N,"text":"..."} when a
 * task was toggled. "path" is the CANONICALIZED target -- write_atomically
 * resolves symlinks before renaming, because rename(2) replaces the name and
 * not the file. 2026-08-24-editing-pane-and-autosave runs this every 800 ms.
 *
 * action is as mark_toggle's: 0 = off, 1 = on, 2 = toggle. Ignored when
 * index is MARK_NO_TASK.
 *
 * This is deliberately not a mode of mark_toggle, which re-reads the file for
 * itself -- exactly the wrong thing when an unsaved buffer is the source of
 * truth. A clean tab keeps calling mark_toggle, unchanged.
 *
 * LOCKING. When `path` is non-NULL this takes an exclusive, non-blocking
 * flock(2) on the document for the duration of the write and releases it
 * before returning; a document another mark holds is refused with NULL and a
 * mark_last_error() naming the holding pid. There is deliberately NO function
 * here to acquire or release that lock on its own: ADR-1's surface is full at
 * twelve, and 2026-08-25-flock-write-locking's "hold it for exactly as long as
 * the buffer is dirty" is a property of the *app*, which takes the same
 * flock(2) directly through Darwin (Editor/DocumentLock.swift).
 *
 * The consequence for such a holder, and it is not optional: the write below
 * renames a new inode over the target, so a lock taken before the call is held
 * on an orphan afterwards. RELEASE IT BEFORE CALLING AND RE-ACQUIRE AFTER.
 * Skipping the re-acquire is silent -- the document simply becomes writable
 * again while the buffer is still dirty.
 */
#define MARK_NO_TASK ((size_t)-1)

char *mark_write_json(const char *path, const char *source, size_t index,
                      int action);

/*
 * JSON array of {path, name, is_dir, depth, title?, tasks?}.
 *
 * depth counts levels below `dir` and is clamped to >= 1; there is no
 * unlimited walk. with_stats != 0 opens each markdown file for its title and
 * task counts.
 *
 * flags is a bitmask of MARK_TREE_*. Both options have always existed in the
 * core's tree::Options; before M7 this function hardcoded the defaults, so
 * neither was reachable from Swift and the app reimplemented them over
 * FileManager -- where a .gitignore'd non-markdown file could not be told
 * apart from a visible one, because the core drops those AFTER the ignore
 * test. A parameter rather than a second function, since ADR-1's ceiling is
 * "roughly a dozen".
 *
 * Returns NULL on failure.
 */
#define MARK_TREE_ALL_FILES 1 /* include non-markdown files */
#define MARK_TREE_HIDDEN    2 /* include dotfiles and dot-directories */

char *mark_tree_json(const char *dir, size_t depth, int with_stats, int flags);

/*
 * Themes: list them, or resolve one.
 *
 * flags & MARK_THEME_LIST ignores `name` and returns
 *
 *   {"themes":[{name,title,kind,pair?,author?,source}],
 *    "default":"...","dir":"...","problems":[...]}
 *
 * Otherwise `name` (NULL or "" for the default) resolves to a light/dark
 * *pair* and returns
 *
 *   {"name":"...","kind":"dark","paired":true,
 *    "light":{...},"dark":{...},"css":"...","codeStamp":"...",
 *    "code":[["keyword","base0E"],...]}
 *
 * "css" is the whole light/dark mechanism: custom properties for BOTH
 * appearances, the dark half inside @media (prefers-color-scheme: dark).
 * Inject it once per page and an appearance switch costs no IPC, no
 * re-render, and no DOM work.
 *
 * "codeStamp" identifies the scope -> slot map, which is the only part of a
 * theme the rendered HTML depends on. Equal stamps across a theme change mean
 * the document does not need re-rendering -- true for every theme we ship.
 *
 * Returns NULL on failure. Free with mark_free().
 */
#define MARK_THEME_LIST 1

char *mark_theme_json(const char *name, int flags);

#ifdef __cplusplus
}
#endif

#endif /* MARK_H */
