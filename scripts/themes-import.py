#!/usr/bin/env python3
"""Convert tinted-theming base16 schemes into `mark`'s own theme TOML.

Run with `just themes-import`. Output lands in `core/themes/`, which
`core/build.rs` embeds into the binary, so the shipped themes cost no file I/O
at runtime and the CLI has them with no bundle to look in.

Licensing, which is the reason this script exists at all
--------------------------------------------------------
`tinted-theming/schemes` is **MIT**, so parsing its YAML and redistributing the
converted palettes is fine. `tinted-builder`, the crate that would otherwise do
this conversion, is **GPL-3.0-only** — linking it would relicense `mark`. So we
parse the YAML here instead. It is four keys and sixteen colours; a dependency
would be the expensive way to do it even without the licence.

The YAML subset
---------------
A base16 scheme file is `key: "value"` at the top level plus a `palette:` block
of two-space-indented `baseNN: "#rrggbb"` entries, with `#` comments. That is
all this parses, and anything else is a hard error rather than a guess — a
scheme that silently half-converted would ship as a theme with missing slots.

Sources, in order of preference:

  * `--schemes <dir>` or `$MARK_SCHEMES_DIR`, a local clone. Offline, and what
    to use if you want to audit exactly what was converted.
  * GitHub raw at the pinned ref below. Pinned rather than `main` so a rerun
    two years from now produces the same bytes.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Pinned: `main` does not exist in this repository — its default branch is the
# spec tag — and a floating ref would make regenerated themes differ from the
# committed ones for reasons nobody could see in the diff.
REF = "spec-0.11"
RAW = f"https://raw.githubusercontent.com/tinted-theming/schemes/{REF}/base16"

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "core" / "themes"

# The v1 roster: 8 light/dark pairs, plus Dracula, which base16 has no light
# counterpart for. An unpaired theme is used for **both** appearances — you
# asked for Dracula, you get Dracula — and `mark theme --show` says so.
#
# Upstream file names are kept as theme names on purpose, even where that is
# asymmetric (`github` is the light one, `nord` is the dark one): they are the
# names people already know from tinted-theming, and inventing our own would
# make every scheme list on the internet wrong about us.
PAIRS: list[tuple[str, str | None]] = [
    ("default-dark", "default-light"),
    ("gruvbox-dark", "gruvbox-light"),
    ("solarized-dark", "solarized-light"),
    ("nord", "nord-light"),
    ("catppuccin-mocha", "catppuccin-latte"),
    ("tokyo-night-dark", "tokyo-night-light"),
    ("rose-pine", "rose-pine-dawn"),
    ("github-dark", "github"),
    ("dracula", None),
]

SLOTS = [f"base{n:02X}" for n in range(16)]

# base16's own styling guidelines, restated as document chrome. Every value is
# a palette slot, never a literal, which is the whole point of the format:
# change `base0D` and links, headings, and the table header rule all move
# together.
DOCUMENT = [
    ("background", "base00", "page background"),
    ("surface", "base01", "code blocks, inline code, table headers"),
    ("selection", "base02", "selection background"),
    ("muted", "base03", "comments, dimmed rows, rules"),
    ("subtle", "base04", "secondary text"),
    ("foreground", "base05", "body text"),
    ("heading", "base0D", "headings"),
    ("link", "base0D", "links"),
    ("accent", "base0E", "blockquote rule, checkbox tint"),
    ("rule", "base02", "table and horizontal rules"),
    ("error", "base08", "failed-construct badges"),
    ("warning", "base0A", None),
    ("success", "base0B", None),
]

HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


class SchemeError(Exception):
    """A scheme file we refuse to convert, with the reason."""


def parse_scheme(text: str, origin: str) -> dict:
    """The base16 YAML subset. Anything outside it is an error, not a guess."""
    top: dict[str, str] = {}
    palette: dict[str, str] = {}
    in_palette = False

    for number, raw in enumerate(text.splitlines(), start=1):
        line = strip_comment(raw)
        if not line.strip():
            continue
        indented = line[:1] in (" ", "\t")
        line = line.strip()

        if not indented:
            in_palette = False
            if line == "palette:":
                in_palette = True
                continue
            key, value = split_pair(line, origin, number)
            top[key] = value
            continue

        if not in_palette:
            raise SchemeError(f"{origin}:{number}: indented line outside palette: {line!r}")
        key, value = split_pair(line, origin, number)
        if key not in SLOTS:
            raise SchemeError(f"{origin}:{number}: {key} is not a base16 slot")
        if not HEX.match(value):
            raise SchemeError(f"{origin}:{number}: {key} is {value!r}, not #rrggbb")
        palette[key] = value.lower()

    missing = [slot for slot in SLOTS if slot not in palette]
    if missing:
        raise SchemeError(f"{origin}: palette is missing {', '.join(missing)}")
    for key in ("name", "variant"):
        if key not in top:
            raise SchemeError(f"{origin}: no {key}")
    if top["variant"] not in ("light", "dark"):
        raise SchemeError(f"{origin}: variant is {top['variant']!r}, not light or dark")
    return {"top": top, "palette": palette}


def strip_comment(line: str) -> str:
    """Drop a trailing `#` comment that is not inside quotes."""
    out = []
    quote = None
    for index, char in enumerate(line):
        if quote:
            out.append(char)
            if char == quote:
                quote = None
            continue
        if char in "\"'":
            quote = char
            out.append(char)
            continue
        if char == "#" and (index == 0 or line[index - 1] in " \t"):
            break
        out.append(char)
    return "".join(out)


def split_pair(line: str, origin: str, number: int) -> tuple[str, str]:
    if ":" not in line:
        raise SchemeError(f"{origin}:{number}: not a `key: value` line: {line!r}")
    key, _, value = line.partition(":")
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return key.strip(), value


def fetch(name: str, local: Path | None) -> str:
    if local is not None:
        for suffix in (".yaml", ".yml"):
            candidate = local / "base16" / f"{name}{suffix}"
            if candidate.exists():
                return candidate.read_text(encoding="utf-8")
        raise SchemeError(f"{name}: not in {local / 'base16'}")
    for suffix in (".yaml", ".yml"):
        url = f"{RAW}/{name}{suffix}"
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise SchemeError(f"{url}: HTTP {error.code}") from error
    raise SchemeError(f"{name}: not found at {RAW} ({REF})")


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_toml(name: str, scheme: dict, pair: str | None) -> str:
    top, palette = scheme["top"], scheme["palette"]
    lines = [
        "# Generated by `just themes-import`. Do not edit by hand — edit",
        "# scripts/themes-import.py and re-run, or copy this file into",
        "# ~/.config/mark/themes/ and edit it there.",
        "#",
        f"# Source: tinted-theming/schemes {REF} base16/{name}.yaml (MIT).",
        "#",
        "# There is no [code] section here: every base16 scheme uses the same",
        "# scope -> slot mapping, which is the default in core/src/theme.rs.",
        "# `mark theme --show " + name + "` prints the resolved mapping, and a",
        "# [code] section in a file overrides it entry by entry.",
        "",
        f"name = {toml_string(name)}",
        f"kind = {toml_string(top['variant'])}",
    ]
    if pair:
        lines.append(f"pair = {toml_string(pair)}")
    lines.append(f"title = {toml_string(top['name'])}")
    if "author" in top:
        lines.append(f"author = {toml_string(top['author'])}")
    lines += ["", "[palette]"]
    for slot in SLOTS:
        lines.append(f"{slot} = {toml_string(palette[slot])}")
    lines += ["", "# Chrome, as palette slots. Change base0D here and links,", "# headings, and the table header rule all move together.", "[document]"]
    width = max(len(key) for key, _, _ in DOCUMENT)
    for key, slot, note in DOCUMENT:
        comment = f"  # {note}" if note else ""
        lines.append(f"{key.ljust(width)} = {toml_string(slot)}{comment}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--schemes",
        default=os.environ.get("MARK_SCHEMES_DIR"),
        help="a local clone of tinted-theming/schemes (offline)",
    )
    parser.add_argument("--check", action="store_true", help="fail if the output would change")
    args = parser.parse_args()

    local = Path(args.schemes).expanduser() if args.schemes else None
    if local is not None and not (local / "base16").is_dir():
        print(f"themes-import: {local}/base16 is not a directory", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    written, changed = 0, 0
    manifest = []
    for dark, light in PAIRS:
        for name, partner in ((dark, light), (light, dark)):
            if name is None:
                continue
            try:
                scheme = parse_scheme(fetch(name, local), f"base16/{name}.yaml")
            except SchemeError as error:
                print(f"themes-import: {error}", file=sys.stderr)
                return 1
            body = render_toml(name, scheme, partner)
            path = OUT / f"{name}.toml"
            previous = path.read_text(encoding="utf-8") if path.exists() else None
            if previous != body:
                changed += 1
                if args.check:
                    print(f"themes-import: {path.relative_to(ROOT)} is out of date", file=sys.stderr)
                else:
                    path.write_text(body, encoding="utf-8")
            written += 1
            manifest.append({"name": name, "kind": scheme["top"]["variant"], "pair": partner})

    if args.check:
        if changed:
            return 1
        print(f"themes-import: {written} themes up to date")
        return 0

    print(f"themes-import: {written} themes in {OUT.relative_to(ROOT)} ({changed} changed)")
    print(json.dumps(manifest, indent=2)[:0] or "", end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
