/*
 * There is no C code in this target. It exists only to expose
 * `core/include/mark.h` — symlinked into `include/`, not copied, so the ABI
 * contract has exactly one committed source of truth — as a Clang module that
 * Swift can `import`, and to carry the `-lmark_core` linker settings.
 *
 * SwiftPM requires a C target to have at least one compilable source, hence
 * this file. ADR-1 forbids a binding generator; a symlink and an empty
 * translation unit are the whole binding layer.
 */

#include "mark.h"

/* Silences the "empty translation unit" pedantic warning. */
typedef int mark_shim_translation_unit_is_not_empty;
