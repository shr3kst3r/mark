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
 *
 * 2026-09-01-search-in-the-core retires the function *count* and keeps the rule
 * it was a proxy for:
 *
 *   Every function here takes and returns NUL-terminated UTF-8 strings and C
 *   scalars, and nothing else. No struct crosses this boundary, no pointer to
 *   one, no callback, no ownership mark_free does not describe. A capability
 *   whose answer does not fit that shape is the signal to reconsider the
 *   design in a superseding ADR -- not the number of functions that have.
 *
 *   A new capability is a new function when no existing function's NAME covers
 *   the answer, and a flag on an existing one when it does. mark_links_json is
 *   a function because "tasks" does not cover "links"; MARK_RENDER_STANDALONE
 *   is a flag because "render this document to HTML" covers "as a whole page".
 */

#ifndef MARK_H
#define MARK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Core version, e.g. "0.2.0". Free with mark_free(). */
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
/*
 * With MARK_RENDER_STANDALONE the answer is a complete <html> document with
 * both palettes inline, rather than the bare mk-blk fragments the shell
 * injects -- what File > Export as HTML... writes, and the same path
 * `mark render --html` takes, so the two cannot disagree.
 *
 * A flag rather than a fifteenth function:
 * 2026-09-01-document-images-over-a-scoped-scheme sets the ceiling at fourteen
 * and says the next capability spends a flag on a function whose name already
 * covers the answer. "Render this document to HTML" does.
 */
#define MARK_RENDER_STANDALONE 1

char *mark_render_html(const char *source, size_t prefix_blocks, const char *theme,
                       int flags);

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
 * flags of 0 returns exactly the bytes it always did. MARK_DIFF_LINES adds
 * "lines": the LINE-level diff, which the block diff cannot supply -- a block
 * spans many lines, so it cannot put a bar against line 41, which is what the
 * editor's change gutter draws. MARK_DIFF_DOCUMENT adds "document": the merged
 * diff document's HTML, plus diffAdded / diffRemoved / diffChanged block
 * counts.
 *
 * Returns NULL on failure.
 */
#define MARK_DIFF_LINES    (1 << 0)
#define MARK_DIFF_DOCUMENT (1 << 1)

char *mark_diff_json(const char *old_source, const char *new_source,
                     const char *theme, int flags);

/*
 * What git says about `path`. The thirteenth and last function here.
 *
 * flags of 0: `path` is a file or a directory, and the answer describes its
 * whole REPOSITORY --
 *
 *   {"repo":{"root":"/Users/x/notes", "gitDir":"...", "indexPath":"...",
 *            "headPath":"...", "head":"a1b2c3d", "branch":"main"},
 *    "changes":[{"path":"weekly.md","status":"modified","added":12,"removed":3},
 *               {"path":"ideas.md","status":"untracked","added":null,"removed":0},
 *               {"path":"logo.png","status":"modified","added":null,"removed":null}]}
 *
 * A path outside any repository answers {"repo":null,"changes":[]}, and that is
 * a SUCCESS -- not NULL. So is a machine with no usable git. The two are
 * indistinguishable on purpose: the reader sees an unbadged row either way.
 *
 * indexPath and headPath exist so the caller can stat the poll gate itself
 * (2026-08-28-git-badges-ride-the-sidebar-poll) without spending a git process
 * per tick. They come from `rev-parse --git-path`, NOT from gitDir joined with
 * a name: a linked worktree, a shared index, or $GIT_INDEX_FILE each put them
 * somewhere else.
 *
 * Paths in "changes" are repository-relative. Join them onto repo.root once.
 *
 * added/removed are null when the lines cannot be counted -- a binary file,
 * per git's own `-` `-`. NEVER RENDER null AS 0: "+0 -0" on a changed binary
 * is a lie about a file that did change. An untracked file carries
 * removed:0 (it removed nothing, which is known) and added:null (its
 * additions are the caller's to count, on its own screen-bounded queue).
 *
 * MARK_GIT_NO_UNTRACKED leaves untracked files out, saving the second git
 * invocation they cost (22.5 ms, against the first one's 11.6 ms).
 *
 * MARK_GIT_BASE: `path` is a FILE, and the answer is its committed bytes --
 *
 *   {"repo":"...", "head":"a1b2c3d", "tracked":true, "base":"# Weekly...\n"}
 *
 * tracked:false with base:null for a file HEAD does not have (a new note --
 * ordinary), and for a blob that is binary or not UTF-8. Cache the result
 * against (repo, path, head): the read costs ~7 ms and cannot change while the
 * oid does not.
 *
 * Returns NULL only on a genuine failure.
 */
#define MARK_GIT_BASE         (1 << 0)
#define MARK_GIT_NO_UNTRACKED (1 << 1)

char *mark_git_json(const char *path, int flags);

/*
 * JSON array of {index, state, checked, start, end, line, text, label, tags,
 * due, start_date, done, priority}. NULL on failure.
 *
 * "state" is one of "open", "in-progress", "done", "cancelled", "blocked" --
 * the five one-byte markers of 2026-08-27-five-task-states ([ ], [/], [x],
 * [-], [?]).
 *
 * "checked" IS RETAINED AND MEANS "THE STATE IS TERMINAL": true for done AND
 * for cancelled. Every existing consumer is asking "is this still
 * outstanding?", and this keeps answering that correctly; read "state" when the
 * difference matters. It is never removed from this object.
 *
 * "text" is unchanged -- the full flattened item text, metadata included.
 * "label" is the same text with the recognised @tag / @key(value) / !!! tokens
 * removed (2026-08-27-inline-task-metadata), which is what a human-facing list
 * should show. "tags" is [{"name":"work"},{"name":"owner","value":"ana"}];
 * "due", "start_date" and "done" are ISO YYYY-MM-DD or null; "priority" is
 * 0..3. The start DATE is "start_date" because "start" is already this
 * object's marker byte offset, and shadowing it would silently change what
 * every existing caller reads.
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
 * Every link and image in a document, as a JSON array:
 *
 *   [{"kind":"image","span":{"start":12,"end":40},"dest":"assets/x.png",
 *     "text":"alt","title":"","target":{"kind":"local","path":"assets/x.png",
 *     "fragment":null},"path":"/abs/assets/x.png","exists":true}, ...]
 *
 * "base" is the directory holding the document, since a parsed document has no
 * path of its own. NULL skips resolution: "path" and "exists" are then absent,
 * which is a different answer from "checked and missing" and must not be read
 * as one.
 *
 * This is the fourteenth function, and 2026-08-28-git-differences-by-running-git
 * set the ceiling at thirteen. 2026-09-01-document-images-over-a-scoped-scheme
 * is the ADR that raises it, and the reason it is a function rather than a flag
 * on mark_tasks_json is stated there: an allowlist a WKURLSchemeHandler serves
 * from must not be reachable only through a call whose name says "tasks".
 */
#define MARK_LINKS_BROKEN 1
#define MARK_LINKS_IMAGES 2

char *mark_links_json(const char *source, const char *base, int flags);

/*
 * Search a file, or every markdown file below a directory, reporting the
 * heading each hit sits under:
 *
 *   {"matches":[{"path":"notes.md","line":412,"offset":9130,
 *                "column":{"start":5,"end":10},"heading":"Deploys > Rollback",
 *                "anchor":"rollback","text":"roll it back"}],
 *    "truncated":false,"files":37}
 *
 * depth of 0 means the default recursive depth. limit caps the hits and 0 means
 * no cap -- the window passes one because it searches on every keystroke,
 * `mark grep` passes 0 because a script piping to wc -l wants the truth.
 * "truncated" says the cap was reached, and is reported rather than inferred
 * from the count, which is ambiguous when a tree holds exactly limit matches.
 *
 * NULL on an invalid pattern, or on a file the caller NAMED that cannot be
 * read. A file found by WALKING that cannot be read is skipped, not an error:
 * `mark grep pat broken.md` exits 2, and a walk past the same file keeps its
 * other results.
 */
/*
 * How long a document is, in the units a writer cares about:
 *
 *   {"words":412,"characters":2380,"characters_no_spaces":2001,"lines":58,
 *    "blocks":22,"headings":4,"code_bytes":190,"reading_minutes":2}
 *
 * Counted from the event stream, so frontmatter, fenced and inline code, math,
 * diagrams, an image's alt text, and a link's URL are all excluded -- which is
 * why this is here rather than a whitespace split in Swift, and why the
 * editor's status line and `mark stats` cannot disagree.
 */
char *mark_wordcount_json(const char *source);

/*
 * Every reference below "root" that points at "target" -- the other direction
 * from mark_links_json, and the question a notes directory is navigated by:
 *
 *   [{"path":"notes/index.md","line":7,"offset":112,"text":"the runbook",
 *     "heading":"Index > Ops","fragment":"install","kind":"link"}]
 *
 * Matching is on the RESOLVED path, so `../notes/runbook.md` from a sibling
 * directory and `runbook.md` from beside it both count. A document never links
 * to itself. depth of 0 means the default recursive depth.
 *
 * One parse per markdown file below root: call this off the main thread.
 */
char *mark_backlinks_json(const char *root, const char *target, size_t depth);

#define MARK_SEARCH_IGNORE_CASE 1
#define MARK_SEARCH_HIDDEN 2

char *mark_search_json(const char *root, const char *pattern, size_t depth,
                       size_t limit, int flags);

/*
 * Toggle task `index` in the file at `path`, in place: exactly one byte
 * changes, written via a temp file and a rename.
 *
 * Takes an exclusive, non-blocking flock(2) on the document first and fails if
 * another mark holds it (2026-08-25-flock-write-locking). The lock is released
 * before this returns; a caller that needs to *hold* one across several writes
 * takes its own -- see mark_write_json below.
 *
 * action: 0 = off, 1 = on, 2 = toggle, 3 = in progress, 4 = cancelled,
 * 5 = blocked.
 *
 * Returns the RESULTING STATE: 0 open, 1 done, 2 in progress, 3 cancelled,
 * 4 blocked -- or -1 on failure.
 *
 * 2026-08-27-five-task-states widens this signature rather than adding a
 * thirteenth function, and the old encoding is a prefix of the new one: an
 * existing caller passing 0/1/2 is unaffected, and one testing `result == 1`
 * still correctly reads "done" and reads every other state as not-done.
 *
 * Note the deliberate asymmetry with the JSON above: this integer reads
 * cancelled as NOT done, while mark_tasks_json's "checked" reads it as
 * terminal. The two answer different questions.
 *
 * Toggle (2) is open->done, done->open, and every other state -> done: ticking
 * a box ticks it, so toggle is a one-way exit from the extended states.
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
 * {"source":"...","index":N,"state":"...","checked":bool,"offset":N,
 * "text":"..."} when a task was toggled -- "state" and "checked" as
 * mark_tasks_json defines them. "path" is the CANONICALIZED target -- write_atomically
 * resolves symlinks before renaming, because rename(2) replaces the name and
 * not the file. 2026-08-24-editing-pane-and-autosave runs this every 800 ms.
 *
 * action is as mark_toggle's: 0 = off, 1 = on, 2 = toggle, 3 = in progress,
 * 4 = cancelled, 5 = blocked. Ignored when index is MARK_NO_TASK.
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

/*
 * depth of 0 means the default recursive depth, as it does for
 * mark_search_json; 1 means this directory only, which is what the sidebar
 * asks for (it must never walk ahead of what the reader expanded).
 */
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
