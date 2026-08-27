/*
 * The C ABI, exercised from real C.
 *
 * A Rust test calling a Rust `extern "C"` function proves the body works; it
 * does not prove the *header* describes it, that the symbols survive into
 * libmark_core.a, or that a C caller linking against the staticlib gets what
 * ADR-1 promises. This program is compiled by `core/tests/abi_c.rs` against
 * core/include/mark.h and the built staticlib, then run.
 *
 * It concentrates on the M5 additions — mark_render_range and mark_diff_json —
 * and re-checks the ADR-1 rules that apply to every function: NULL or -1 on
 * failure with a message in mark_last_error(), one deallocation path, and no
 * unwinding out of an extern "C" frame.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "mark.h"

static int failures = 0;
static int checks = 0;

static void ok(int condition, const char *what) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", what);
    }
}

/* Number of non-overlapping occurrences of `needle` in `haystack`. */
static int count(const char *haystack, const char *needle) {
    int found = 0;
    size_t width = strlen(needle);
    const char *at = haystack;
    while ((at = strstr(at, needle)) != NULL) {
        found++;
        at += width;
    }
    return found;
}

/* Drain mark_last_error() into a caller-owned buffer; "" when there is none. */
static void take_error(char *into, size_t size) {
    char *message = mark_last_error();
    if (message == NULL) {
        into[0] = '\0';
        return;
    }
    snprintf(into, size, "%s", message);
    mark_free(message);
}

static const char *const DOC = "# Title\n\n- [ ] task\n\nalpha\n\nbravo\n";

static void version_round_trips(void) {
    char *version = mark_version();
    ok(version != NULL, "mark_version returned NULL");
    if (version != NULL) {
        ok(strlen(version) > 0, "mark_version returned an empty string");
        printf("  core version: %s\n", version);
        mark_free(version);
    }
    mark_free(NULL); /* ADR-1: NULL is a no-op, not a crash. */
}

static void render_html_still_works(void) {
    char *html = mark_render_html(DOC, 0, NULL);
    ok(html != NULL, "mark_render_html returned NULL");
    if (html == NULL) {
        return;
    }
    ok(count(html, "class=\"mk-blk") == 4, "mark_render_html block count");
    ok(count(html, "class=\"mk-task\"") == 1, "mark_render_html task count");
    mark_free(html);
}

static void render_range_emits_one_block(void) {
    char *middle = mark_render_range(DOC, 2, 3, NULL);
    ok(middle != NULL, "mark_render_range(2,3) returned NULL");
    if (middle == NULL) {
        return;
    }
    ok(count(middle, "class=\"mk-blk") == 1, "mark_render_range(2,3) block count");
    ok(strstr(middle, ">alpha</p>") != NULL, "mark_render_range(2,3) content");
    ok(strstr(middle, ">bravo</p>") == NULL, "mark_render_range(2,3) leaked a later block");
    ok(strstr(middle, "mk-task") == NULL, "mark_render_range(2,3) leaked an earlier block");
    mark_free(middle);
}

static void a_partition_reassembles_the_document(void) {
    char *whole = mark_render_html(DOC, 0, NULL);
    char *head = mark_render_range(DOC, 0, 2, NULL);
    char *tail = mark_render_range(DOC, 2, (size_t)-1, NULL); /* SIZE_MAX: to the end */
    ok(whole != NULL && head != NULL && tail != NULL, "partition renders are non-NULL");
    if (whole == NULL || head == NULL || tail == NULL) {
        mark_free(whole);
        mark_free(head);
        mark_free(tail);
        return;
    }

    size_t joined_len = strlen(head) + strlen(tail) + 1;
    char *joined = malloc(joined_len);
    ok(joined != NULL, "malloc for the joined render");
    if (joined != NULL) {
        snprintf(joined, joined_len, "%s%s", head, tail);
        ok(strcmp(joined, whole) == 0, "head ++ tail == whole");
        free(joined);
    }
    mark_free(whole);
    mark_free(head);
    mark_free(tail);
}

static void an_empty_range_is_an_empty_string(void) {
    /* A pump walking off the end must see "", not NULL, and not an error. */
    size_t bounds[][2] = {{1, 1}, {4, 4}, {9, 12}, {(size_t)-2, (size_t)-1}};
    for (size_t i = 0; i < sizeof(bounds) / sizeof(bounds[0]); i++) {
        char *empty = mark_render_range(DOC, bounds[i][0], bounds[i][1], NULL);
        ok(empty != NULL, "an empty range returned NULL");
        if (empty != NULL) {
            ok(strcmp(empty, "") == 0, "an empty range returned content");
            mark_free(empty);
        }
    }
}

static void a_reversed_range_is_an_error(void) {
    char message[256];
    char *refused = mark_render_range(DOC, 3, 1, NULL);
    ok(refused == NULL, "a reversed range returned a slice instead of NULL");
    mark_free(refused);
    take_error(message, sizeof message);
    ok(strcmp(message, "block range 3..1 is reversed") == 0, "reversed range message");
    if (failures > 0) {
        fprintf(stderr, "  last_error was: %s\n", message);
    }
}

static void a_null_source_is_an_error_not_a_crash(void) {
    char message[256];
    ok(mark_render_range(NULL, 0, 1, NULL) == NULL, "mark_render_range(NULL) returned non-NULL");
    take_error(message, sizeof message);
    ok(strcmp(message, "source is null") == 0, "mark_render_range(NULL) message");

    ok(mark_diff_json(NULL, DOC, NULL) == NULL, "mark_diff_json(NULL, _) returned non-NULL");
    take_error(message, sizeof message);
    ok(strcmp(message, "old_source is null") == 0, "mark_diff_json(NULL, _) message");

    ok(mark_diff_json(DOC, NULL, NULL) == NULL, "mark_diff_json(_, NULL) returned non-NULL");
    take_error(message, sizeof message);
    ok(strcmp(message, "new_source is null") == 0, "mark_diff_json(_, NULL) message");
}

static void diff_of_an_unchanged_document_is_all_keep(void) {
    char *json = mark_diff_json(DOC, DOC, NULL);
    ok(json != NULL, "mark_diff_json(same, same) returned NULL");
    if (json == NULL) {
        return;
    }
    ok(count(json, "\"op\":") == 1, "an unchanged document is one op");
    ok(strstr(json, "\"op\":\"keep\"") != NULL, "the one op is a keep");
    ok(strstr(json, "\"count\":4") != NULL, "the keep covers every block");
    ok(strstr(json, "\"inserted\":0") != NULL, "nothing inserted");
    ok(strstr(json, "\"deleted\":0") != NULL, "nothing deleted");
    ok(strstr(json, "\"replaced\":0") != NULL, "nothing replaced");
    ok(strstr(json, "\"coarse\":false") != NULL, "not coarse");
    ok(strstr(json, "\"html\"") == NULL, "an all-keep script carries no HTML");
    mark_free(json);
}

static void diff_of_an_edited_document_names_the_changed_block(void) {
    static const char *const EDITED = "# Title\n\n- [x] task\n\nalpha\n\nbravo\n";
    char *json = mark_diff_json(DOC, EDITED, NULL);
    ok(json != NULL, "mark_diff_json(doc, edited) returned NULL");
    if (json == NULL) {
        return;
    }
    ok(strstr(json, "\"op\":\"replace\"") != NULL, "the edit is a replace");
    ok(count(json, "\"op\":\"keep\"") == 2, "the untouched blocks are kept");
    ok(strstr(json, "\"replaced\":1") != NULL, "exactly one block replaced");
    ok(strstr(json, "\"kept\":3") != NULL, "three blocks kept");
    ok(strstr(json, "\"old_ids\":") != NULL, "the replace names the old data-blk");
    ok(strstr(json, "\"new_ids\":") != NULL, "the replace names the new data-blk");
    ok(strstr(json, "\"html\":") != NULL, "the replace carries its HTML");
    ok(strstr(json, "checked") != NULL, "the replacement HTML is the checked one");
    mark_free(json);
}

static void diff_of_an_insert_carries_an_anchor(void) {
    static const char *const INSERTED = "# Title\n\n- [ ] task\n\nalpha\n\ninserted\n\nbravo\n";
    char *json = mark_diff_json(DOC, INSERTED, NULL);
    ok(json != NULL, "mark_diff_json(doc, inserted) returned NULL");
    if (json == NULL) {
        return;
    }
    ok(strstr(json, "\"op\":\"insert\"") != NULL, "the edit is an insert");
    ok(strstr(json, "\"inserted\":1") != NULL, "exactly one block inserted");
    ok(strstr(json, "\"before\":\"") != NULL, "the insert anchors on a data-blk");
    ok(strstr(json, ">inserted</p>") != NULL, "the insert carries its HTML");
    mark_free(json);
}

static void a_document_with_identical_blocks_diffs_by_ordinal(void) {
    static const char *const FIVE = "same\n\nsame\n\nsame\n\nsame\n\nsame\n";
    static const char *const FOUR = "same\n\nsame\n\nsame\n\nsame\n";
    char *json = mark_diff_json(FIVE, FOUR, NULL);
    ok(json != NULL, "mark_diff_json over identical blocks returned NULL");
    if (json == NULL) {
        return;
    }
    ok(strstr(json, "\"kept\":4") != NULL, "four identical blocks kept");
    ok(strstr(json, "\"deleted\":1") != NULL, "one identical block deleted");
    ok(strstr(json, "\"old_blocks\":5") != NULL, "old block count");
    ok(strstr(json, "\"new_blocks\":4") != NULL, "new block count");
    mark_free(json);
}

static void an_empty_document_diffs(void) {
    char *json = mark_diff_json("", "", NULL);
    ok(json != NULL, "mark_diff_json(\"\", \"\") returned NULL");
    if (json == NULL) {
        return;
    }
    ok(strstr(json, "\"ops\":[]") != NULL, "two empty documents produce no ops");
    mark_free(json);

    char *empty = mark_render_range("", 0, (size_t)-1, NULL);
    ok(empty != NULL, "rendering an empty document returned NULL");
    if (empty != NULL) {
        ok(strcmp(empty, "") == 0, "an empty document renders to an empty string");
        mark_free(empty);
    }
}

/*
 * ADR-5's constructs, seen from the other side of the boundary.
 *
 * No new function: math and diagrams are rendering, so they arrive through
 * mark_render_html like everything else. What is worth checking from C is that
 * they arrive *whole* — the SVG in particular is 10 KB of a string that must
 * survive CString conversion — and that a construct that fails to render comes
 * back as a badge rather than as a NULL, an empty region, or a panic crossing
 * an extern "C" frame.
 */
static const char *const RICH =
    "Inline $x^2$ and display $$\\int_0^1 f$$.\n"
    "\n"
    "```mermaid\n"
    "flowchart TD\n"
    "    A[Start] --> B[Done]\n"
    "```\n";

static void math_and_diagrams_cross_the_boundary(void) {
    char *html = mark_render_html(RICH, 0, NULL);
    ok(html != NULL, "mark_render_html(rich) returned NULL");
    if (html == NULL) {
        return;
    }
    ok(strstr(html, "<math display=\"inline\"") != NULL, "inline MathML is present");
    ok(strstr(html, "<math display=\"block\"") != NULL, "display MathML is present");
    /* M7: one SVG per appearance, chosen by prefers-color-scheme. */
    ok(strstr(html, "<div class=\"mk-diagram\">") != NULL, "the diagram is inline SVG");
    ok(strstr(html, "mk-appear-light\"><svg") != NULL, "the light diagram is present");
    ok(strstr(html, "mk-appear-dark\"><svg") != NULL, "the dark diagram is present");
    /* The SVG is the largest single string the ABI hands out; a truncation
     * would show as a missing closing tag rather than as a NULL. */
    ok(strstr(html, "</svg>") != NULL, "the SVG is not truncated");
    ok(strlen(html) > 4000, "the SVG did not survive the boundary");
    /* ADR-5: no JavaScript reaches the WebView for either feature. */
    ok(strstr(html, "<script") == NULL, "no JavaScript in rendered output");
    mark_free(html);
}

static void a_failed_construct_arrives_as_a_badge(void) {
    /* `\newcommand` is the case pulldown-latex reports as Ok with an embedded
     * <merror>; a malformed diagram is the case merman reports as Err. Both
     * must arrive as our own badge, and neither may take the process down. */
    static const char *const BROKEN =
        "Defining $\\newcommand{\\R}{\\mathbb{R}}$ fails.\n"
        "\n"
        "```mermaid\n"
        "flowchart TD\n"
        "    A[[[Start --> B\n"
        "```\n";

    char *html = mark_render_html(BROKEN, 0, NULL);
    ok(html != NULL, "mark_render_html(broken) returned NULL");
    if (html == NULL) {
        return;
    }
    ok(count(html, "mk-rich-error") == 2, "two badges");
    ok(strstr(html, "mk-math-error") != NULL, "the math badge");
    ok(strstr(html, "mk-diagram-error") != NULL, "the diagram badge");
    /* pulldown-latex's own error markup is suppressed. */
    ok(strstr(html, "<merror") == NULL, "merror markup leaked into the page");
    /* And the raw source is still there to select. */
    ok(strstr(html, "\\newcommand") != NULL, "the LaTeX source was dropped");
    ok(strstr(html, "A[[[Start") != NULL, "the diagram source was dropped");
    mark_free(html);
}

static void a_prose_mermaid_fence_is_still_a_code_block(void) {
    /* RenderSvgError::NoDiagram means "not a diagram", not "error". */
    static const char *const PROSE = "```mermaid\nnot a diagram at all\n```\n";
    char *html = mark_render_html(PROSE, 0, NULL);
    ok(html != NULL, "mark_render_html(prose fence) returned NULL");
    if (html == NULL) {
        return;
    }
    ok(strstr(html, "data-lang=\"mermaid\"") != NULL, "it is a code block");
    ok(strstr(html, "<svg") == NULL, "it is not an SVG");
    ok(strstr(html, "mk-rich-error") == NULL, "it is not a badge");
    mark_free(html);
}

/*
 * M7. The two things Swift asks the theme layer for, and the refusal that
 * makes a broken theme visible rather than invisible.
 */
static void themes_cross_the_boundary(void) {
    char *list = mark_theme_json(NULL, MARK_THEME_LIST);
    ok(list != NULL, "mark_theme_json(list) returned NULL");
    if (list != NULL) {
        ok(strstr(list, "\"dracula\"") != NULL, "the list has dracula in it");
        ok(strstr(list, "\"default\":\"default-dark\"") != NULL, "the list names a default");
        mark_free(list);
    }

    char *resolved = mark_theme_json("dracula", 0);
    ok(resolved != NULL, "mark_theme_json(dracula) returned NULL");
    if (resolved != NULL) {
        ok(strstr(resolved, "--mk-background:#282a36") != NULL, "the css carries the palette");
        ok(strstr(resolved, "\"codeStamp\"") != NULL, "the response carries a code stamp");
        mark_free(resolved);
    }

    /* Both appearances in one string, so a switch needs no round trip. */
    char *paired = mark_theme_json("default-dark", 0);
    ok(paired != NULL, "mark_theme_json(default-dark) returned NULL");
    if (paired != NULL) {
        ok(strstr(paired, "prefers-color-scheme: dark") != NULL,
           "the css carries a dark media query");
        ok(strstr(paired, "\"paired\":true") != NULL, "default-dark reports as paired");
        mark_free(paired);
    }

    /* A name that does not resolve is a named error, never a silent default. */
    char message[512];
    ok(mark_theme_json("no-such-theme", 0) == NULL, "an unknown theme returned non-NULL");
    take_error(message, sizeof message);
    ok(strstr(message, "no theme named \"no-such-theme\"") != NULL, message);

    ok(mark_render_html(DOC, 0, "no-such-theme") == NULL,
       "rendering in an unknown theme returned non-NULL");
    take_error(message, sizeof message);
    ok(strstr(message, "no theme named") != NULL, message);
}

/*
 * M7. Code tokens carry palette slots, not colours, which is what lets an
 * appearance switch re-colour them with no re-render.
 */
static void code_carries_slots_not_colours(void) {
    static const char *const CODE = "```rust\nfn main() {}\n```\n";
    char *dark = mark_render_html(CODE, 0, "dracula");
    char *light = mark_render_html(CODE, 0, "github");
    ok(dark != NULL && light != NULL, "themed render returned NULL");
    if (dark == NULL || light == NULL) {
        return;
    }
    ok(strstr(dark, "<span class=\"t") != NULL, "no slot class in the output");
    ok(strstr(dark, "style=\"color") == NULL, "an inline colour survived");
    /* Same scope map, so the bytes are identical whatever the palette. */
    ok(strcmp(dark, light) == 0, "two themes produced different HTML");
    mark_free(dark);
    mark_free(light);
}

/* M7. The flags M8 could not reach. */
static void tree_flags_reach_the_core(void) {
    char *markdown_only = mark_tree_json(".", 1, 0, 0);
    char *everything = mark_tree_json(".", 1, 0, MARK_TREE_ALL_FILES);
    ok(markdown_only != NULL && everything != NULL, "mark_tree_json returned NULL");
    if (markdown_only == NULL || everything == NULL) {
        return;
    }
    /* core/ holds Cargo.toml and build.rs, neither of which is markdown. */
    ok(strstr(markdown_only, "build.rs") == NULL, "markdown_only listed build.rs");
    ok(strstr(everything, "build.rs") != NULL, "MARK_TREE_ALL_FILES did not list build.rs");
    mark_free(markdown_only);
    mark_free(everything);
}

/*
 * M9. The editor's block byte ranges, and the one write path for an edited
 * document -- both of which a C caller must reach through this header.
 */
static void tasks_json_carries_blocks_on_request(void) {
    char *bare = mark_tasks_json(DOC, 0);
    char *both = mark_tasks_json(DOC, MARK_TASKS_BLOCKS);
    ok(bare != NULL && both != NULL, "mark_tasks_json returned NULL");
    if (bare == NULL || both == NULL) {
        return;
    }
    ok(bare[0] == '[', "flags 0 stopped being a bare array");
    ok(strstr(both, "\"blocks\"") != NULL, "MARK_TASKS_BLOCKS produced no blocks");
    ok(strstr(both, "\"kind\":\"heading\"") != NULL, "no heading block");
    mark_free(bare);
    mark_free(both);
}

/*
 * 2026-08-27-five-task-states and -inline-task-metadata, from C: the widened
 * `action` domain, the state code mark_toggle returns, and the new JSON fields.
 * This file is the only thing that compiles mark.h, so the header's promises
 * are checked here or nowhere.
 */
static void tasks_json_carries_state_and_metadata(void) {
    char *json = mark_tasks_json("- [-] dropped @due(2026-09-01) !!\n", 0);
    ok(json != NULL, "mark_tasks_json returned NULL");
    if (json == NULL) {
        return;
    }
    ok(strstr(json, "\"state\":\"cancelled\"") != NULL, "no state field");
    /* Retained, and "terminal": cancelled reads as checked. */
    ok(strstr(json, "\"checked\":true") != NULL, "cancelled is not terminal");
    ok(strstr(json, "\"text\":\"dropped @due(2026-09-01) !!\"") != NULL, "text changed meaning");
    ok(strstr(json, "\"label\":\"dropped\"") != NULL, "no stripped label");
    ok(strstr(json, "\"due\":\"2026-09-01\"") != NULL, "no typed due date");
    ok(strstr(json, "\"priority\":2") != NULL, "no priority");
    mark_free(json);
}

static void toggle_returns_a_state_code(void) {
    char path[] = "/tmp/mark-abi-state-XXXXXX";
    int fd = mkstemp(path);
    ok(fd >= 0, "could not make a temp file");
    if (fd < 0) {
        return;
    }
    (void)write(fd, "- [ ] one\n", 10);
    close(fd);

    /* 1 = on -> 1 done: what an existing caller testing `== 1` reads. */
    ok(mark_toggle(path, 0, 1) == 1, "action 1 did not return done");
    /* 4 = cancelled -> 3, and 5 = blocked -> 4. */
    ok(mark_toggle(path, 0, 4) == 3, "action 4 did not return cancelled");
    ok(mark_toggle(path, 0, 5) == 4, "action 5 did not return blocked");
    /* 3 = in progress -> 2. */
    ok(mark_toggle(path, 0, 3) == 2, "action 3 did not return in progress");
    /* Toggling an extended marker ticks it. */
    ok(mark_toggle(path, 0, 2) == 1, "toggle did not tick the box");
    /* And the domain still ends at 5. */
    ok(mark_toggle(path, 0, 6) == -1, "action 6 was accepted");

    char *receipt = mark_write_json(NULL, "- [ ] one\n", 0, 4);
    ok(receipt != NULL, "mark_write_json returned NULL");
    if (receipt != NULL) {
        ok(strstr(receipt, "\"state\":\"cancelled\"") != NULL, "no state in the receipt");
        ok(strstr(receipt, "- [-] one") != NULL, "the wrong byte was written");
        mark_free(receipt);
    }
    remove(path);
}

static void write_json_saves_and_toggles(void) {
    char path[] = "/tmp/mark-abi-smoke-XXXXXX";
    int fd = mkstemp(path);
    ok(fd >= 0, "could not make a temp file");
    if (fd < 0) {
        return;
    }
    (void)write(fd, "- [ ] one\n", 10);
    close(fd);

    /* A toggle against a buffer writes nothing. */
    char *toggled = mark_write_json(NULL, "- [ ] one\n- [ ] two\n", 1, 1);
    ok(toggled != NULL, "buffer toggle returned NULL");
    if (toggled != NULL) {
        ok(strstr(toggled, "\"written\":false") != NULL, "a buffer toggle claimed to write");
        ok(strstr(toggled, "- [x] two") != NULL, "the toggled source is wrong");
        mark_free(toggled);
    }

    /* A save with no toggle writes the buffer as it is. */
    char *saved = mark_write_json(path, "saved from C\n", MARK_NO_TASK, 2);
    ok(saved != NULL, "save returned NULL");
    if (saved != NULL) {
        ok(strstr(saved, "\"written\":true") != NULL, "the save did not report writing");
        mark_free(saved);
    }
    FILE *check = fopen(path, "r");
    char buffer[64] = {0};
    if (check != NULL) {
        (void)fread(buffer, 1, sizeof(buffer) - 1, check);
        fclose(check);
    }
    ok(strcmp(buffer, "saved from C\n") == 0, "the file does not hold what was saved");
    remove(path);
}

int main(void) {
    printf("mark C ABI smoke test\n");

    version_round_trips();
    render_html_still_works();
    render_range_emits_one_block();
    a_partition_reassembles_the_document();
    an_empty_range_is_an_empty_string();
    a_reversed_range_is_an_error();
    a_null_source_is_an_error_not_a_crash();
    diff_of_an_unchanged_document_is_all_keep();
    diff_of_an_edited_document_names_the_changed_block();
    diff_of_an_insert_carries_an_anchor();
    a_document_with_identical_blocks_diffs_by_ordinal();
    an_empty_document_diffs();
    math_and_diagrams_cross_the_boundary();
    a_failed_construct_arrives_as_a_badge();
    a_prose_mermaid_fence_is_still_a_code_block();
    themes_cross_the_boundary();
    code_carries_slots_not_colours();
    tree_flags_reach_the_core();
    tasks_json_carries_blocks_on_request();
    tasks_json_carries_state_and_metadata();
    toggle_returns_a_state_code();
    write_json_saves_and_toggles();

    printf("  %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
