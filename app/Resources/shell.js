/*
 * The shell's renderer: ADR-2's prefix-then-fill, the setTimeout pump, and the
 * manual scroll anchor.
 *
 * Three WebKit facts this file is shaped around, each verified rather than
 * assumed (ADR-2 Context, research §2.5):
 *
 *   1. `requestIdleCallback` DOES NOT EXIST in WKWebView. The background fill
 *      is pumped with `setTimeout`. Do not "modernize" this.
 *   2. `overflow-anchor` is unsupported in WebKit, so there is no automatic
 *      scroll anchoring. `captureAnchor` / `restoreAnchor` below are it.
 *   3. `document.body.scrollTop` returns 0 in WKWebView. Scroll position is
 *      read from `window.pageYOffset` everywhere in this file.
 *
 * And one Swift-side fact: `evaluateJavaScript` cannot return a Promise, so
 * everything async here is called from `callAsyncJavaScript`, with document
 * HTML passed as an *argument* rather than interpolated into a script string.
 */

(function () {
  "use strict";

  var container = document.getElementById("mk-doc");

  /* Nodes parsed but not yet in the document: the tail of the current
   * document, waiting on the pump. ADR-2's "the document exists in two states"
   * lives here, and `ensureFullyRendered` is the one way out of it. */
  var pending = null;
  var pendingRemaining = 0;
  var fillTimer = null;
  var fillResolve = null;
  var fillStartedAt = 0;

  /* One tick of the pump moves children until this budget is spent. 6 ms
   * leaves room inside a 16.7 ms frame for the layout the append triggers. */
  var TICK_BUDGET_MS = 6;
  /* Never move fewer than this per tick, so a pathologically expensive single
   * block cannot stall the fill into never finishing. */
  var MIN_PER_TICK = 8;

  var mark = {};

  /*
   * How many whole documents have been injected, how many block patches have
   * been applied, and how many blocks those patches touched — since the page
   * loaded.
   *
   * The M5 gate "a GUI toggle is one visible change, not two" is otherwise
   * unfalsifiable from outside the page: a write that patches *and* then
   * re-renders looks identical in a screenshot to one that patches once. These
   * counters make it a subtraction. Read with `mark.stats()`.
   */
  var stats = { documents: 0, patches: 0, patchedBlocks: 0, replacements: 0, themes: 0 };

  /* ---------------------------------------------------------------- probe */

  /* Reports the three WebKit capabilities above, so the assumptions this file
   * is built on stay checkable on a future WebKit instead of being folklore.
   * `mark-bench` asserts on this. */
  mark.probe = function () {
    return {
      requestIdleCallback: typeof window.requestIdleCallback === "function",
      overflowAnchor: window.CSS && CSS.supports("overflow-anchor", "auto"),
      contentVisibility: window.CSS && CSS.supports("content-visibility", "auto"),
      userAgent: navigator.userAgent
    };
  };

  /* --------------------------------------------------- due-date colouring */

  /*
   * Mark the `@due(...)` chips that are overdue or due today.
   *
   * This is the app's half of `2026-08-27-inline-task-metadata`, and the reason
   * it is here rather than in the renderer is the whole point of that ADR's
   * "the renderer never reads a clock": `mark render --html` has to be a pure
   * function of its source so its output can be memoized and so the same
   * document does not render differently tomorrow. The core therefore emits a
   * neutral chip carrying its own date — `<span class="mk-tag"
   * data-mk-due="2026-09-01">` — and the comparison happens once, here, in a
   * script that is injected into the shell and is *not* JavaScript in the
   * emitted document.
   *
   * `root` is whatever has just arrived: the injected prefix, the detached tail
   * before the pump moves it, or a patch's parsed blocks. Never the whole
   * document — ADR-2 forbids assuming it is all in the DOM, and a walk per
   * chunk is bounded by the chunk.
   */
  function today() {
    var now = new Date();
    var month = now.getMonth() + 1;
    var day = now.getDate();
    return (
      now.getFullYear() + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
    );
  }

  function paintDue(root) {
    if (!root || !root.querySelectorAll) return 0;
    var chips = root.querySelectorAll(".mk-tag[data-mk-due]");
    if (chips.length === 0) return 0;
    /* Read once per chunk, not once per chip: a document can carry thousands,
     * and the answer cannot change inside one pass. */
    var now = today();
    for (var i = 0; i < chips.length; i++) {
      var due = chips[i].getAttribute("data-mk-due");
      /* ISO dates compare lexicographically, which is the whole reason the
       * core validates the format and refuses to type anything else as a
       * date. */
      if (due < now) {
        chips[i].classList.add("mk-overdue");
      } else if (due === now) {
        chips[i].classList.add("mk-due-today");
      }
    }
    return chips.length;
  }

  mark.paintDue = function () {
    return paintDue(container);
  };

  /* -------------------------------------------------------------- painting */

  /*
   * Paint the first-paint prefix. `html` is the core's `mark_render_html`
   * output for the first N blocks, where N is derived from viewport height by
   * ProgressiveRenderer on the Swift side — not a constant (ADR-2).
   *
   * Returns the timings the benchmark gate measures. `layoutMs` reads only the
   * *first* block's geometry, which is the measurement research §2.5 settled
   * on; `prefixLayoutMs` additionally forces layout of the whole injected
   * prefix, which is the honest "what the user can see" number since the
   * prefix is sized to about 1.5 viewports.
   */
  mark.setDocument = function (html, meta) {
    cancelFill();
    // Every find range points into the nodes about to be thrown away.
    findReset();
    container.scrollTop = 0;
    window.scrollTo(0, 0);

    var t0 = performance.now();
    container.innerHTML = html;
    var t1 = performance.now();
    stats.documents += 1;
    /* After the injection is timed, because it is the app's own decoration
     * rather than part of what ADR-2's first-paint budget is measuring. */
    paintDue(container);

    var first = container.firstElementChild;
    var firstHeight = first ? first.getBoundingClientRect().height : 0;
    var t2 = performance.now();

    var last = container.lastElementChild;
    var prefixHeight = last && first
      ? last.getBoundingClientRect().bottom - first.getBoundingClientRect().top
      : 0;
    var t3 = performance.now();

    var blocks = container.childElementCount;
    return {
      path: (meta && meta.path) || "",
      blocks: blocks,
      injectMs: t1 - t0,
      layoutMs: t2 - t1,
      prefixLayoutMs: t3 - t1,
      totalMs: t3 - t0,
      firstBlockHeight: firstHeight,
      prefixHeight: prefixHeight,
      /* Feeds ProgressiveRenderer's estimate for the next document, so the
       * block count converges on this document's real geometry instead of
       * staying at a guess. */
      meanBlockHeight: blocks > 0 ? prefixHeight / blocks : 0,
      viewportHeight: window.innerHeight
    };
  };

  /*
   * Hand the rest of the document to the background pump.
   *
   * `template.innerHTML` parses the tail while it is *detached*, so WebKit does
   * the HTML parse but no layout; the pump then moves nodes into the document
   * in slices, and each slice pays only its own layout. Splitting the tail is
   * left to WebKit's parser rather than done by string-slicing in Swift, which
   * would break the moment a document contained raw inline HTML that looked
   * like a block boundary.
   *
   * Resolves when the document is fully populated.
   */
  mark.appendTail = function (html) {
    cancelFill();
    if (!html) {
      return Promise.resolve({ parseMs: 0, fillMs: 0, appended: 0 });
    }

    var t0 = performance.now();
    var template = document.createElement("template");
    template.innerHTML = html;
    pending = template.content;
    pendingRemaining = pending.childElementCount;
    /* While still detached: adding a class here costs a tree walk and no
     * layout, where doing it after the pump has moved a slice in would
     * invalidate style on nodes the reader is already looking at. */
    paintDue(pending);
    var parseMs = performance.now() - t0;

    fillStartedAt = performance.now();
    var appended = pendingRemaining;
    return new Promise(function (resolve) {
      fillResolve = function () {
        resolve({
          parseMs: parseMs,
          fillMs: performance.now() - fillStartedAt,
          appended: appended,
          blocks: container.childElementCount
        });
      };
      schedule();
    });
  };

  /*
   * ADR-2's mandated escape hatch: "Nothing may depend on the whole document
   * being in the DOM without first awaiting or forcing completion of the
   * background fill. Provide one explicit ensureFullyRendered() path and route
   * such features through it."
   *
   * In-page search, "scroll to heading", and print are the callers this exists
   * for. It drains synchronously rather than waiting for the pump.
   */
  mark.ensureFullyRendered = function () {
    if (!pending) {
      return Promise.resolve({ forced: false, blocks: container.childElementCount });
    }
    var t0 = performance.now();
    drain(Infinity);
    var forcedMs = performance.now() - t0;
    finishFill();
    return Promise.resolve({
      forced: true,
      forcedMs: forcedMs,
      blocks: container.childElementCount
    });
  };

  /* Whether the tail is still landing. Anything querying the DOM must tolerate
   * `true` here, or go through `ensureFullyRendered` first. */
  mark.isFilling = function () {
    return pending !== null;
  };

  /* ----------------------------------------------------------- re-render */

  /*
   * Replace the document while holding the reader's place.
   *
   * WebKit gives us no automatic mechanism (`overflow-anchor` is unsupported),
   * so ADR-2 specifies this by hand: record the first block crossing the
   * viewport top and its offset, patch, then `scrollBy` the delta — with the
   * read, the patch, and the correction all inside **one**
   * `requestAnimationFrame` so no intermediate state is painted, and
   * `scroll-behavior: smooth` disabled for the duration.
   *
   * M2 replaces the whole document; M5 turns this into a block-level patch
   * driven by the core's edit script. The anchor machinery is the part that
   * carries over.
   *
   * `tail` may be null. If the anchor block is not in `prefix`, the tail is
   * appended synchronously before the correction — a reload while scrolled
   * deep pays the full injection cost rather than losing the reader's place.
   */
  /*
   * Run `work` before the next paint, and run it even if there is no next
   * paint.
   *
   * WebKit **suspends `requestAnimationFrame` entirely for an occluded
   * window**, and a document driven from the CLI (ADR-3) is routinely
   * occluded: `mark open` launches with `open -g` so focus is not stolen, and
   * the window then sits behind the terminal. Without the timer, `mark reload`
   * on a background window never resolves — measured as a 30 s CLI timeout
   * before this existed, not as a theory.
   *
   * This keeps ADR-2's rule and its reason intact:
   *
   *   > Read, patch, and correct all happen inside **one**
   *   > `requestAnimationFrame` so no intermediate state is painted
   *
   * A visible window still does exactly that — rAF fires in ~16 ms and the
   * timer never runs. An occluded window paints nothing at all, so there is no
   * intermediate state to paint, and the whole read-patch-correct sequence
   * still happens in a single, uninterrupted turn of the event loop.
   */
  var PAINT_FALLBACK_MS = 100;

  function beforeNextPaint(work) {
    var ran = false;
    function once() {
      if (ran) return;
      ran = true;
      work();
    }
    requestAnimationFrame(once);
    setTimeout(once, PAINT_FALLBACK_MS);
  }

  mark.replaceDocument = function (prefix, tail) {
    return new Promise(function (resolve) {
      beforeNextPaint(function () {
        var root = document.documentElement;
        var previousBehavior = root.style.scrollBehavior;
        root.style.scrollBehavior = "auto";

        var t0 = performance.now();
        var anchor = captureAnchor();
        cancelFill();
        findReset();

        container.innerHTML = prefix;
        stats.replacements += 1;

        var synchronousTail = false;
        if (tail && anchor && !blockElement(anchor.blk)) {
          /* The reader is past the prefix, so the block they were looking at
           * only exists in the tail. Correctness beats latency here. */
          var template = document.createElement("template");
          template.innerHTML = tail;
          container.appendChild(template.content);
          synchronousTail = true;
          tail = null;
        }

        var restored = restoreAnchor(anchor);
        var elapsed = performance.now() - t0;
        root.style.scrollBehavior = previousBehavior;

        if (tail) {
          mark.appendTail(tail);
        }

        resolve({
          patchMs: elapsed,
          anchored: restored,
          synchronousTail: synchronousTail,
          scrollTop: window.pageYOffset,
          blocks: container.childElementCount
        });
      });
    });
  };

  /* -------------------------------------------------- incremental patching */

  /*
   * ADR-2's block patch: apply the core's edit script by `data-blk`, then
   * re-stamp the attributes that a node-preserving patch necessarily leaves
   * stale.
   *
   * The second half is the whole reason this is more than twenty lines, and it
   * is the trap M5 exists to close. Rendered HTML encodes **absolute** byte
   * positions — `data-mk-start` / `data-mk-end` on every block and on every
   * task input, plus `data-mk-idx` and a heading's deduplicated `id`. ADR-2
   * requires block ids to be content-derived, so a block *below* an edit keeps
   * its id and is correctly kept by the diff — but its byte offsets have moved,
   * and if a task was inserted above it, its `data-mk-idx` now names a
   * different task.
   *
   * The checkbox click handler at the bottom of this file reads exactly those
   * three attributes. So a patch that stopped here would mean **clicking a
   * checkbox in an untouched block writes the wrong task** — silent corruption
   * of the user's file, in the feature the app is named for. The core pins this
   * as `core/tests/diff_apply.rs::
   * stale_position_attributes_are_the_one_thing_a_patch_cannot_fix`, whose
   * proptest asserts patched == fresh *modulo those four attributes*. Closing
   * that gap is this function's job.
   *
   * `script` and `stamps` arrive as JSON **text**, parsed here: they come
   * straight from `mark_diff_json`, `mark_tasks_json` and `mark_toc_json` with
   * no Swift-side model in between, so there is nothing to drift.
   *
   * Returns `{ok: false, reason}` rather than throwing, and rather than
   * limping on, whenever the script does not describe the DOM it was handed.
   * The caller re-renders the document wholesale on a false — correct but
   * slower beats plausible but wrong, which is the failure mode ADR-2 names.
   */
  mark.applyEditScript = function (script, stamps) {
    return new Promise(function (resolve) {
      beforeNextPaint(function () {
        resolve(patchNow(script, stamps));
      });
    });
  };

  /* The same, without waiting for a paint. Exposed for the regression test
   * that has to observe a patch attempted *while the pump is still filling* —
   * going through `applyEditScript` would give the pump a turn first, and the
   * refusal being asserted would never happen. Same reason `_captureAnchor`
   * and `_restoreAnchor` below are exposed. */
  mark._patchNow = patchNow;

  function patchNow(scriptJSON, stampsJSON) {
    // A patch replaces block elements, so any range into one of them is stale.
    // The window controller re-runs the search afterwards if the bar is open.
    findReset();
    var script, stamps;
    try {
      script = JSON.parse(scriptJSON);
      stamps = stampsJSON ? JSON.parse(stampsJSON) : null;
    } catch (error) {
      return { ok: false, reason: "unreadable edit script: " + error };
    }

    /* The script addresses every block of the old document, and half of them
     * may still be sitting in `pending`. ADR-2: nothing may depend on the whole
     * document being in the DOM without forcing the fill first. Swift does that
     * before calling; this is the backstop. */
    if (pending) {
      return { ok: false, reason: "the background fill is still running" };
    }

    var root = document.documentElement;
    var previousBehavior = root.style.scrollBehavior;
    root.style.scrollBehavior = "auto";

    var started = performance.now();
    var anchor = captureAnchor();
    var applied = applyOps(script);
    if (!applied.ok) {
      root.style.scrollBehavior = previousBehavior;
      return applied;
    }
    var stamped = restamp(stamps);
    if (!stamped.ok) {
      root.style.scrollBehavior = previousBehavior;
      return stamped;
    }
    var restored = restoreAnchor(anchor);
    var elapsed = performance.now() - started;
    root.style.scrollBehavior = previousBehavior;

    stats.patches += 1;
    stats.patchedBlocks += applied.touched;

    return {
      ok: true,
      patchMs: elapsed,
      anchored: restored,
      synchronousTail: false,
      scrollTop: window.pageYOffset,
      blocks: container.childElementCount,
      touched: applied.touched,
      tasksStamped: stamped.tasks,
      headingsStamped: stamped.headings
    };
  }

  /*
   * The edit script, applied to the DOM.
   *
   * `ops` is a complete left-to-right traversal of the *old* block sequence, so
   * the children of `#mk-doc` are exactly that sequence — the snapshot below is
   * taken once and indexed by `old_index`, which stays valid however much the
   * live child list is spliced underneath it.
   *
   * Every id the script names is checked against the element actually sitting
   * there, the same way `EditScript::apply` does in Rust. A diff bug shows up
   * as a stale or duplicated document rather than a crash (ADR-2), so the only
   * defence is to refuse loudly the moment the script and the DOM disagree.
   */
  function applyOps(script) {
    var ops = script.ops || [];
    var old = Array.prototype.slice.call(container.children);
    if (old.length !== script.old_blocks) {
      return {
        ok: false,
        reason:
          "the DOM holds " + old.length + " blocks, the script describes " +
          script.old_blocks
      };
    }

    var cursor = 0;
    var touched = 0;

    for (var i = 0; i < ops.length; i++) {
      var op = ops[i];
      if (op.old_index !== cursor) {
        return {
          ok: false,
          reason:
            "op " + i + " (" + op.op + ") starts at " + op.old_index +
            ", the walk is at " + cursor
        };
      }

      if (op.op === "keep") {
        cursor += op.count;
      } else if (op.op === "delete") {
        for (var d = 0; d < op.old_ids.length; d++) {
          var doomed = old[cursor];
          if (!doomed || blkOf(doomed) !== op.old_ids[d]) {
            return { ok: false, reason: mismatch(i, op.op, cursor, op.old_ids[d], doomed) };
          }
          doomed.parentNode.removeChild(doomed);
          touched += 1;
          cursor += 1;
        }
      } else if (op.op === "insert") {
        var before = null;
        if (op.before === null || op.before === undefined) {
          /* Appending. The core only emits a null anchor at the end of the old
           * document, so anything else here means the script has drifted. */
          if (cursor !== old.length) {
            return {
              ok: false,
              reason: "op " + i + " appends from the middle (at " + cursor + " of " + old.length + ")"
            };
          }
        } else {
          before = old[cursor];
          if (!before || blkOf(before) !== op.before) {
            return { ok: false, reason: mismatch(i, op.op, cursor, op.before, before) };
          }
        }
        var inserted = parseBlocks(op.html);
        if (!inserted) {
          return { ok: false, reason: "op " + i + " (insert) carries no HTML" };
        }
        touched += inserted.childElementCount;
        container.insertBefore(inserted, before);
      } else if (op.op === "replace") {
        for (var r = 0; r < op.old_ids.length; r++) {
          var going = old[cursor + r];
          if (!going || blkOf(going) !== op.old_ids[r]) {
            return { ok: false, reason: mismatch(i, op.op, cursor + r, op.old_ids[r], going) };
          }
        }
        var replacement = parseBlocks(op.html);
        if (!replacement) {
          return { ok: false, reason: "op " + i + " (replace) carries no HTML" };
        }
        touched += replacement.childElementCount + op.old_ids.length;
        container.insertBefore(replacement, old[cursor]);
        for (var g = 0; g < op.old_ids.length; g++) {
          old[cursor + g].parentNode.removeChild(old[cursor + g]);
        }
        cursor += op.old_ids.length;
      } else {
        return { ok: false, reason: "op " + i + " has unknown kind " + op.op };
      }
    }

    if (cursor !== old.length) {
      return {
        ok: false,
        reason: "the script covered " + cursor + " of " + old.length + " old blocks"
      };
    }
    if (container.childElementCount !== script.new_blocks) {
      return {
        ok: false,
        reason:
          "patched to " + container.childElementCount + " blocks, the script promised " +
          script.new_blocks
      };
    }
    return { ok: true, touched: touched };
  }

  function mismatch(index, kind, at, expected, found) {
    return (
      "op " + index + " (" + kind + ") expected data-blk " + expected + " at " + at +
      ", found " + (found ? blkOf(found) : "nothing")
    );
  }

  function blkOf(element) {
    return element.getAttribute ? element.getAttribute("data-blk") : null;
  }

  /* Parse a run of blocks while detached, so WebKit does the HTML parse but no
   * layout until the fragment is spliced in. */
  function parseBlocks(html) {
    if (typeof html !== "string") return null;
    var template = document.createElement("template");
    template.innerHTML = html;
    paintDue(template.content);
    return template.content;
  }

  /*
   * Re-stamp everything whose value is an absolute position in the source.
   *
   * `stamps.tasks` is `mark_tasks_json(new_source)` verbatim and is the
   * authority for the three attributes the click handler reads. `stamps.headings`
   * is `mark_toc_json(new_source)`: a heading's `id` is deduplicated across the
   * document (`notes`, `notes-1`), so inserting a second "Notes" above one that
   * the diff kept leaves the kept heading answering to an id that now belongs
   * to its new neighbour — which is `mark goto` scrolling to the wrong place.
   *
   * A count that does not line up is not repaired, it is refused: if the DOM
   * holds a different number of checkboxes than the new source does, the patch
   * did not produce the new document and stamping it would only make the
   * damage harder to see.
   */
  function restamp(stamps) {
    if (!stamps) return { ok: true, tasks: 0, headings: 0 };

    var tasks = stamps.tasks || [];
    var inputs = container.querySelectorAll("input.mk-task");
    if (inputs.length !== tasks.length) {
      return {
        ok: false,
        reason:
          "the patched document holds " + inputs.length + " checkboxes, the source has " +
          tasks.length
      };
    }
    for (var i = 0; i < inputs.length; i++) {
      var input = inputs[i];
      var task = tasks[i];
      if (task.index !== i) {
        return {
          ok: false,
          reason: "task " + i + " in document order reports index " + task.index
        };
      }
      input.setAttribute("data-mk-idx", String(task.index));
      input.setAttribute("data-mk-start", String(task.start));
      input.setAttribute("data-mk-end", String(task.end));
      /* `data-mk-state` is the authority: it is what the stylesheet paints from
       * and what a click reports as the rendered state. Five states, one per
       * marker byte (2026-08-27-five-task-states). */
      input.setAttribute("data-mk-state", task.state);
      input.setAttribute("aria-label", task.state === "in-progress" ? "in progress" : task.state);
      /* Content attribute *and* property, for `done` only — which is exactly
       * what a fresh render emits. `checked` is the *terminal* question in the
       * core's JSON and cancelled answers it yes, so the box would draw ticked
       * from `task.checked`; it must come from the state instead. */
      if (task.state === "done") {
        input.setAttribute("checked", "");
        input.checked = true;
      } else {
        input.removeAttribute("checked");
        input.checked = false;
      }
    }

    var headings = stamps.headings || [];
    var stampedHeadings = 0;
    for (var h = 0; h < headings.length; h++) {
      var block = blockElement(headings[h].block);
      if (!block) continue;
      var element = block.querySelector(".mk-h");
      if (!element) continue;
      if (element.id !== headings[h].anchor) {
        element.id = headings[h].anchor;
      }
      stampedHeadings += 1;
    }

    return { ok: true, tasks: inputs.length, headings: stampedHeadings };
  }

  mark.stats = function () {
    return {
      documents: stats.documents,
      patches: stats.patches,
      patchedBlocks: stats.patchedBlocks,
      replacements: stats.replacements,
      themes: stats.themes,
      blocks: container.childElementCount
    };
  };

  /* ------------------------------------------------------------- scrolling */

  mark.scrollTo = function (y) {
    window.scrollTo(0, y);
    return window.pageYOffset;
  };

  /*
   * Put the reader back where they were, for a tab being rehydrated (ADR-4).
   *
   * The offset may be past the end of the prefix that has just painted, since
   * a dehydrated tab could have been scrolled anywhere. That is exactly ADR-2's
   * hazard — "nothing may depend on the whole document being in the DOM
   * without first awaiting or forcing completion of the background fill" — so
   * the deep case routes through `ensureFullyRendered`, which is the one
   * sanctioned way out of it. The shallow case, which is the common one,
   * scrolls immediately and never forces anything.
   */
  mark.restoreScroll = function (y) {
    if (!y || y <= 0) {
      return Promise.resolve({ restored: true, y: window.pageYOffset, forced: false });
    }
    var reachable =
      document.documentElement.scrollHeight - window.innerHeight;
    if (y <= reachable) {
      window.scrollTo(0, y);
      return Promise.resolve({ restored: true, y: window.pageYOffset, forced: false });
    }
    return mark.ensureFullyRendered().then(function () {
      window.scrollTo(0, y);
      return {
        restored: Math.abs(window.pageYOffset - y) <= 2,
        y: window.pageYOffset,
        forced: true
      };
    });
  };

  /*
   * Where the top of the viewport is in the *source*, as a UTF-8 byte offset,
   * or `null` if this document cannot say.
   *
   * The editor pane follows the preview by this number and by nothing else.
   * Pixels do not survive the trip: a 40-line table and a one-line image are
   * the same height on screen and nothing alike in the source, so any mapping
   * built on scroll fractions drifts the moment a document stops being uniform
   * prose. Every block already carries the byte span the core rendered it from
   * (`data-mk-start` / `data-mk-end`), so the mapping is in the DOM already and
   * this only has to read it.
   *
   * Binary search rather than the linear walk `captureAnchor` does. Blocks are
   * laid out in document order, so their tops ascend, and a 1 MB document costs
   * ~12 rect reads instead of thousands — this runs on every scroll report,
   * where `captureAnchor` runs once per patch.
   *
   * The block *containing* the viewport top, not the first one below it, and
   * interpolated through its byte span by how far into it the viewport has
   * travelled: without that, a long code fence would hold the editor still for
   * a screenful and then jump it.
   */
  function sourceTop() {
    var blocks = container.children;
    var count = blocks.length;
    if (!count) return null;
    var low = 0;
    var high = count - 1;
    /* 0 when every block is still below the viewport top, which is the top of
     * the document — where the reader is before the first scroll. */
    var found = 0;
    while (low <= high) {
      var mid = (low + high) >> 1;
      if (blocks[mid].getBoundingClientRect().top <= 0) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    var block = blocks[found];
    /* An error page (`mk-error`) is a child of the container and carries no
     * span. Reporting nothing is right: `Number(null)` is 0, and syncing the
     * editor to the top of the document would be worse than not syncing it. */
    if (!block.hasAttribute("data-mk-start")) return null;
    var start = Number(block.getAttribute("data-mk-start"));
    var end = Number(block.getAttribute("data-mk-end"));
    if (!isFinite(start) || start < 0) return null;
    if (!isFinite(end) || end < start) end = start;
    var rect = block.getBoundingClientRect();
    var into = rect.height > 0 ? -rect.top / rect.height : 0;
    if (!(into > 0)) into = 0;
    if (into > 1) into = 1;
    return Math.round(start + (end - start) * into);
  }

  /* Exposed for the bench gate, which asserts on the mapping itself and not
   * only on where the editor ended up. */
  mark.sourceTop = sourceTop;

  mark.scrollPosition = function () {
    /* NOT document.body.scrollTop: that returns 0 in WKWebView. */
    return {
      y: window.pageYOffset,
      height: document.documentElement.scrollHeight,
      viewport: window.innerHeight
    };
  };

  /* Scroll to a heading anchor. Routed through ensureFullyRendered because the
   * heading may not be in the DOM yet — exactly the hazard ADR-2 names. */
  mark.scrollToAnchor = function (anchor) {
    return mark.ensureFullyRendered().then(function () {
      var el = document.getElementById(anchor);
      if (!el) return false;
      el.scrollIntoView({ block: "start", behavior: "auto" });
      return true;
    });
  };

  /*
   * Scroll to a task — the sidebar's Tasks tab clicking through to the item.
   *
   * Two identities, tried in this order, and the order is the decision
   * (2026-08-28-tabbed-document-pane):
   *
   *   1. `start`, the marker's byte offset. What the write path re-verifies
   *      before it changes a byte, and stable when the task set grows.
   *   2. `index`, the `data-mk-idx` ordinal. The fallback, because the pane's
   *      list is the core's parse of the bytes and these attributes are the last
   *      render of them — for the moment between a metadata refresh and a
   *      re-render those are two different sets of bytes, and an index alone
   *      lands on the wrong item exactly then.
   *
   * Scrolls the *item*, not the checkbox: a reader clicking a task wants to see
   * its text, and `li` is where the text is. Centred rather than aligned to the
   * top, because a task is one line and a line pinned to the top of the viewport
   * reads as having nothing after it.
   *
   * Routed through ensureFullyRendered for ADR-2's reason: a task three quarters
   * of the way down the document is not in the DOM until it is.
   */
  mark.scrollToTask = function (index, start) {
    return mark.ensureFullyRendered().then(function () {
      var input = null;
      if (start !== null && start !== undefined) {
        input = document.querySelector('.mk-task[data-mk-start="' + String(start) + '"]');
      }
      if (!input && index !== null && index !== undefined) {
        input = document.querySelector('.mk-task[data-mk-idx="' + String(index) + '"]');
      }
      if (!input) return false;
      var item = input.closest("li") || input;
      item.scrollIntoView({ block: "center", behavior: "auto" });
      return true;
    });
  };

  /* ---------------------------------------------------------------- finding */

  /*
   * Find-in-document, with every match highlighted at once.
   *
   * **Not `WKWebView.find`.** WebKit's own find highlights one match, has no
   * notion of "3 of 12", and reports only whether it landed on something — so
   * a bar that cycles and highlights all of them cannot be built on it.
   *
   * **And not `<mark>` elements either**, which is the other obvious way to
   * highlight many matches and is the one ADR-2 forbids: the patcher diffs the
   * block elements against the core's render, so wrapping matched text in new
   * nodes would make the next keystroke diff a document against a highlighted
   * copy of itself. The CSS Custom Highlight API paints ranges without
   * touching the DOM at all, which is exactly the property needed here.
   *
   * Where that API is missing (it is Safari 17.2, so a macOS 14.0 or 14.1
   * machine has none) the search still works and still cycles; only the
   * highlight narrows to the current match, drawn as a selection. That is
   * reported back as `highlightsAll: false` rather than being papered over.
   */

  var findRanges = [];
  var findIndex = -1;

  var findSupportsHighlights =
    typeof CSS !== "undefined" &&
    CSS.highlights &&
    typeof window.Highlight === "function";

  function findClearHighlights() {
    if (!findSupportsHighlights) return;
    CSS.highlights.delete("mk-find");
    CSS.highlights.delete("mk-find-current");
  }

  /* Throw the ranges away. Called on every document change as well as by
   * `clearFind`: a `Range` into a block the patcher has just replaced points at
   * a node that is no longer in the tree, and painting it is undefined. */
  function findReset() {
    findRanges = [];
    findIndex = -1;
    findClearHighlights();
  }

  mark._findReset = findReset;

  function findState() {
    return {
      total: findRanges.length,
      index: findIndex,
      highlightsAll: findSupportsHighlights
    };
  }

  /*
   * The container's text, flattened, with an index back to the nodes it came
   * from.
   *
   * `innerText` would be simpler and is not usable: it is the *rendered* text
   * with no way back to a node and offset, and a `Range` needs both.
   */
  function findTextIndex() {
    var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
        var parent = node.parentElement;
        if (!parent) return NodeFilter.FILTER_REJECT;
        var tag = parent.tagName;
        /* A diagram's `<style>` and any `<script>` are text nodes that are not
         * text the reader can see. */
        if (tag === "STYLE" || tag === "SCRIPT") return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = [];
    var starts = [];
    var parts = [];
    var length = 0;
    var node;
    while ((node = walker.nextNode())) {
      nodes.push(node);
      starts.push(length);
      parts.push(node.nodeValue);
      length += node.nodeValue.length;
    }
    return { nodes: nodes, starts: starts, text: parts.join("") };
  }

  /* The node and offset a position in the flattened text came from. */
  function findLocate(map, position) {
    var low = 0;
    var high = map.starts.length - 1;
    var found = 0;
    while (low <= high) {
      var mid = (low + high) >> 1;
      if (map.starts[mid] <= position) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return { node: map.nodes[found], offset: position - map.starts[found] };
  }

  function findBuildRanges(needle, caseSensitive) {
    var map = findTextIndex();
    var hay = caseSensitive ? map.text : map.text.toLowerCase();
    var pin = caseSensitive ? needle : needle.toLowerCase();
    var ranges = [];
    var from = 0;
    for (;;) {
      var at = hay.indexOf(pin, from);
      if (at < 0) break;
      var start = findLocate(map, at);
      /* The end is located from the last character *inside* the match, so a
       * match ending exactly on a node boundary does not resolve to offset 0
       * of the next node. */
      var last = findLocate(map, at + pin.length - 1);
      var range = document.createRange();
      range.setStart(start.node, start.offset);
      range.setEnd(last.node, last.offset + 1);
      ranges.push(range);
      /* Non-overlapping, which is how every find bar counts: "aa" occurs once
       * in "aaa", not twice. */
      from = at + pin.length;
    }
    return ranges;
  }

  function findPaint() {
    if (!findSupportsHighlights) {
      var selection = window.getSelection();
      if (!selection) return;
      selection.removeAllRanges();
      if (findIndex >= 0) selection.addRange(findRanges[findIndex]);
      return;
    }
    if (!findRanges.length) {
      findClearHighlights();
      return;
    }
    var all = new Highlight();
    for (var i = 0; i < findRanges.length; i++) all.add(findRanges[i]);
    CSS.highlights.set("mk-find", all);
    if (findIndex < 0) {
      CSS.highlights.delete("mk-find-current");
      return;
    }
    var current = new Highlight(findRanges[findIndex]);
    /* Painted over the "all matches" highlight rather than under it. */
    current.priority = 1;
    CSS.highlights.set("mk-find-current", current);
  }

  function findReveal() {
    if (findIndex < 0) return;
    var range = findRanges[findIndex];
    var rect = range.getBoundingClientRect();
    if (!rect || (!rect.width && !rect.height)) {
      var element = range.startContainer.parentElement;
      if (element) element.scrollIntoView({ block: "center", behavior: "auto" });
      return;
    }
    /* Left where it is when it is comfortably on screen already — a bar that
     * re-centred the page on every keystroke would make typing feel like the
     * document was sliding around. */
    var margin = Math.min(120, window.innerHeight * 0.2);
    if (rect.top >= margin && rect.bottom <= window.innerHeight - margin) return;
    window.scrollBy(0, rect.top - window.innerHeight / 2);
  }

  /* The match a browser would start on: the first one at or below the top of
   * the viewport, so "find" continues from where the reader is reading rather
   * than jumping to the top of the document. */
  function findNearestToViewport() {
    for (var i = 0; i < findRanges.length; i++) {
      var rect = findRanges[i].getBoundingClientRect();
      if (rect && rect.bottom > 0) return i;
    }
    return 0;
  }

  mark.find = function (needle, options) {
    var caseSensitive = !!(options && options.caseSensitive);
    return mark.ensureFullyRendered().then(function () {
      findReset();
      if (!needle) return findState();
      findRanges = findBuildRanges(needle, caseSensitive);
      findIndex = findRanges.length ? findNearestToViewport() : -1;
      findPaint();
      findReveal();
      return findState();
    });
  };

  /* Next (`+1`) or previous (`-1`) match, wrapping in both directions. */
  mark.findStep = function (delta) {
    if (!findRanges.length) return findState();
    var count = findRanges.length;
    findIndex = ((findIndex + delta) % count + count) % count;
    findPaint();
    findReveal();
    return findState();
  };

  mark.findState = findState;

  /* What the reader has selected, for "Use Selection for Find". */
  mark.selectedText = function () {
    var selection = window.getSelection();
    return selection ? String(selection) : "";
  };

  /* Drop the highlights and any selection they left behind. */
  mark.clearFind = function () {
    findReset();
    var selection = window.getSelection();
    if (selection) selection.removeAllRanges();
    return true;
  };

  /* Exposed for the scroll-anchor regression test, which needs to assert on
   * the anchor itself and not only on the position it produces. */
  mark._captureAnchor = captureAnchor;
  mark._restoreAnchor = restoreAnchor;

  function captureAnchor() {
    var blocks = container.children;
    for (var i = 0; i < blocks.length; i++) {
      var rect = blocks[i].getBoundingClientRect();
      if (rect.bottom > 0) {
        return {
          blk: blocks[i].getAttribute("data-blk"),
          /* Negative once the block has scrolled partly off the top; that sign
           * is what makes the correction exact rather than approximate. */
          offset: rect.top,
          scroll: window.pageYOffset
        };
      }
    }
    return null;
  }

  /* Set when the page moved itself to keep the reader still, and read by the
   * next scroll report. See `reportScroll`. */
  var heldPlace = false;

  function restoreAnchor(anchor) {
    if (!anchor) return false;
    var el = blockElement(anchor.blk);
    if (!el) {
      heldPlace = true;
      window.scrollTo(0, anchor.scroll);
      return false;
    }
    var delta = el.getBoundingClientRect().top - anchor.offset;
    if (delta !== 0) {
      heldPlace = true;
      window.scrollBy(0, delta);
    }
    return true;
  }

  function blockElement(blk) {
    if (!blk) return null;
    /* Block ids are `<content-hash>-<ordinal>` (ADR-2), so they are safe in an
     * attribute selector; the escape is belt-and-braces against a future id
     * shape rather than a live hazard. */
    var escaped = window.CSS && CSS.escape ? CSS.escape(blk) : blk;
    return container.querySelector('[data-blk="' + escaped + '"]');
  }

  /* ------------------------------------------------------------- the pump */

  function schedule() {
    /* setTimeout, not requestIdleCallback: it does not exist here (ADR-2). */
    fillTimer = window.setTimeout(tick, 0);
  }

  function tick() {
    fillTimer = null;
    if (!pending) return;
    drain(TICK_BUDGET_MS);
    if (pending && pending.firstChild) {
      schedule();
    } else {
      finishFill();
    }
  }

  /* Move children into the document until `budgetMs` is spent. Each slice goes
   * through a DocumentFragment so a slice costs one insertion, not N. */
  function drain(budgetMs) {
    if (!pending) return;
    var started = performance.now();
    var moved = 0;
    while (pending.firstChild) {
      var batch = document.createDocumentFragment();
      var inBatch = 0;
      while (pending.firstChild && inBatch < MIN_PER_TICK) {
        batch.appendChild(pending.firstChild);
        inBatch++;
      }
      container.appendChild(batch);
      moved += inBatch;
      if (moved >= MIN_PER_TICK && performance.now() - started >= budgetMs) break;
    }
    pendingRemaining = pending.childElementCount;
  }

  function finishFill() {
    pending = null;
    pendingRemaining = 0;
    var resolve = fillResolve;
    fillResolve = null;
    if (resolve) resolve();
  }

  function cancelFill() {
    if (fillTimer !== null) {
      window.clearTimeout(fillTimer);
      fillTimer = null;
    }
    if (pending) {
      pending = null;
      pendingRemaining = 0;
      var resolve = fillResolve;
      fillResolve = null;
      if (resolve) resolve();
    }
  }

  /* -------------------------------------------------------------- theming */

  /*
   * Install a theme: one element's text, and nothing else.
   *
   * `css` is what the core's `mark_theme_json` returned — custom properties for
   * BOTH appearances, with the dark half inside
   * `@media (prefers-color-scheme: dark)`. So this runs when the *theme*
   * changes and never when the *appearance* does: an appearance switch is
   * WebKit re-resolving variables and repainting, with no JavaScript, no
   * message to Swift, and no DOM mutation at all.
   *
   * The document is untouched. Code tokens are `<span class="t0B">` — a palette
   * slot, not a colour — and `shell.css` maps every slot to a variable, so the
   * whole page re-colours without a single node being rewritten.
   *
   * Returns the counters a test asserts on, because "no re-render happened" is
   * otherwise unfalsifiable from outside the page.
   */
  mark.setTheme = function (css) {
    var style = document.getElementById("mk-theme");
    if (!style) {
      style = document.createElement("style");
      style.id = "mk-theme";
      /* **After** `shell.css`, not before it. The stylesheet carries a
       * `:root` block of fallback values so the few milliseconds between the
       * page loading and the first `setTheme` are not black-on-transparent —
       * and two `:root` blocks setting the same custom property are the same
       * specificity, so the later one wins. Inserting this first made every
       * theme resolve to the fallback palette, which looked exactly like
       * theming not working at all. Caught by reading the colours back out of
       * `getComputedStyle` rather than by asserting we had set them. */
      document.head.appendChild(style);
    }
    var changed = style.textContent !== css;
    if (changed) {
      style.textContent = css;
      stats.themes += 1;
    }
    return {
      applied: changed,
      themes: stats.themes,
      documents: stats.documents,
      /* What the page actually resolved, read back rather than assumed: a
       * variable that failed to parse reads as "". */
      background: readVariable("--mk-background"),
      foreground: readVariable("--mk-foreground"),
      /* Whether the *system* is currently dark, which is the half of the pair
       * in force. Nothing here decides it; the media query does. */
      dark: window.matchMedia("(prefers-color-scheme: dark)").matches,
      blocks: container.childElementCount
    };
  };

  /* The theme CSS currently installed, for a test that wants to compare. */
  mark.themeCSS = function () {
    var style = document.getElementById("mk-theme");
    return style ? style.textContent : "";
  };

  /*
   * What one element resolves a property to right now — the colour a reader
   * actually sees, after the cascade and the media query, rather than the one
   * we hoped we set.
   */
  mark.resolvedColors = function (selector) {
    /* `documentElement`, not `body`: `html` is what carries the background,
     * and reading it off `body` reports rgba(0,0,0,0) whatever the theme
     * says. */
    var element = selector ? container.querySelector(selector) : document.documentElement;
    if (!element) return null;
    var style = window.getComputedStyle(element);
    return {
      color: style.color,
      background: style.backgroundColor,
      dark: window.matchMedia("(prefers-color-scheme: dark)").matches
    };
  };

  function readVariable(name) {
    return window
      .getComputedStyle(document.documentElement)
      .getPropertyValue(name)
      .trim();
  }

  /* ------------------------------------------------------------- the bridge */

  function post(message) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.mark
    ) {
      window.webkit.messageHandlers.mark.postMessage(message);
    }
  }

  mark.post = post;

  /*
   * Checkbox clicks: ADR-1's contract, straight off the element.
   *
   * `preventDefault` keeps the box drawing whatever the *file* says. Swift
   * writes the byte, the file watcher notices, and the resulting block patch is
   * what flips the box on screen — one visible change, sourced from disk,
   * rather than an optimistic flip that has to be undone when the write is
   * refused.
   *
   * Two states are reported, both by name, and the difference matters.
   * `renderedState` is the `data-mk-state` **content attribute**, which a click
   * never touches: it is what the core emitted, and therefore what the page
   * believes the file says. Swift compares it against the file to tell a stale
   * page from a fresh one. `state` is what the user is asking for.
   *
   * The requested state is derived **here** rather than read off the element.
   * With five states (2026-08-27-five-task-states) there is no longer a
   * property the browser can have flipped for us during the pre-click
   * activation steps: `target.checked` cannot express in-progress, blocked or
   * cancelled, and for a cancelled box it is false where the core's own
   * `checked` — "the state is terminal" — is true. So the rule lives in one
   * place in each language: a plain click toggles open<->done and ticks
   * anything else, and Alt-click cancels.
   */
  function desiredStateFor(rendered, event) {
    if (event.altKey) return "cancelled";
    return rendered === "done" ? "open" : "done";
  }

  function taskPayload(target) {
    return {
      index: Number(target.getAttribute("data-mk-idx")),
      start: Number(target.getAttribute("data-mk-start")),
      end: Number(target.getAttribute("data-mk-end")),
      renderedState: target.getAttribute("data-mk-state") || "open"
    };
  }

  document.addEventListener(
    "click",
    function (event) {
      var target = event.target;
      if (target && target.classList && target.classList.contains("mk-task")) {
        event.preventDefault();
        var message = taskPayload(target);
        message.kind = "toggle";
        message.state = desiredStateFor(message.renderedState, event);
        post(message);
        return;
      }
      var link = target && target.closest ? target.closest("a[href]") : null;
      if (link) {
        event.preventDefault();
        post({ kind: "link", href: link.getAttribute("href") });
      }
    },
    true
  );

  /*
   * Right-click on a checkbox: the state picker.
   *
   * The menu itself is an `NSMenu` in Swift. It cannot be markup in the page —
   * ADR-5 allows the emitted document no JavaScript of its own, and a menu
   * drawn in the document would need some — and it should not be, because a
   * five-item AppKit menu is what a right-click on macOS is supposed to
   * produce. So this reports the position and lets Swift put it there.
   *
   * `preventDefault` suppresses WebKit's own menu for this one element only;
   * a right-click anywhere else in the document keeps Copy, Look Up, and
   * Services.
   */
  document.addEventListener(
    "contextmenu",
    function (event) {
      var target = event.target;
      if (!target || !target.classList || !target.classList.contains("mk-task")) return;
      event.preventDefault();
      var message = taskPayload(target);
      message.kind = "taskMenu";
      message.x = event.clientX;
      message.y = event.clientY;
      post(message);
    },
    true
  );

  /*
   * Scroll reporting, for ADR-4's session file, for dehydration, and for the
   * editor pane, which follows the `src` this carries.
   *
   * Pushed rather than pulled. The first two need the offset at a moment when
   * an async round trip to the page is not available — the web view is being
   * torn down, or `applicationWillTerminate` is running — so Swift keeps the
   * last reported value and reads it synchronously. The third needs it to
   * arrive without one: a query per scroll would be a round trip between the
   * reader's trackpad and the pane trying to keep up with it.
   *
   * Throttled to one message per 120 ms and only on a change worth recording,
   * because a fling scroll on a 1 MB document fires this hundreds of times and
   * every message is an IPC hop into the app process.
   */
  var scrollTimer = null;
  var lastReportedScroll = -1;

  function reportScroll() {
    scrollTimer = null;
    /* Read and cleared here rather than where it is set, so that a correction
     * whose delta was too small to report does not leave the flag standing for
     * a later scroll that the reader really did make. */
    var held = heldPlace;
    heldPlace = false;
    /* NOT document.body.scrollTop: that returns 0 in WKWebView. */
    var y = window.pageYOffset;
    if (Math.abs(y - lastReportedScroll) < 2) return;
    lastReportedScroll = y;
    /* The source position rides along on the message that already exists
     * rather than being asked for over a second round trip: the editor pane
     * follows it, and a query per scroll would put a `callAsyncJavaScript` hop
     * between the reader's trackpad and the pane that is meant to keep up with
     * it. Absent on a document that cannot be mapped; never zero as a stand-in
     * for absent.
     *
     * Absent, too, on a re-render that held the reader's place: that moved
     * `pageYOffset` without the reader going anywhere — the same block is under
     * the same pixel. The offset still has to be reported, because dehydration
     * and the session file are about pixels, but the source position must not
     * be, or typing above the viewport would drag an editor the reader had
     * scrolled somewhere else back to whatever line the preview is showing. */
    var source = held ? null : sourceTop();
    if (source === null) {
      post({ kind: "scroll", y: y });
    } else {
      post({ kind: "scroll", y: y, src: source });
    }
  }

  window.addEventListener(
    "scroll",
    function () {
      if (scrollTimer !== null) return;
      scrollTimer = window.setTimeout(reportScroll, 120);
    },
    { passive: true }
  );

  window.mark = mark;
  post({ kind: "ready" });
})();
