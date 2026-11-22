"""Symbol and kaomoji palettes compiled into the keyboard's palette file.

Symbols come from rime-prelude's ``symbols.yaml``. Its ``punctuator/symbols``
block maps Rime's ``/xx`` shortcuts to lists of symbols, one shortcut per
line:

    '/jt': [ ↑, ↓, ←, →, ... ]

Each palette category below collects several shortcuts in order; the
punctuation category starts with the full-width punctuation Rime commits for
each key (``punctuator/full_shape``). Shortcuts
that hold Chinese words (卦名, 干支, 節氣), single Latin letters with
accents, ligatures, radicals and the per-row kana lists are left out.

Kaomoji come from Mozc's ``src/data/emoticon/categorized.tsv``, written for
the emoticon palette of Google Japanese Input for Android. Each line is

    value<TAB>category[ category...]<TAB>Japanese readings

with ``#`` comment lines and blank lines in between. An entry listed under
several categories appears in each of them; the readings are dropped.

The output is plain UTF-8, one line per palette entry, grouped by palette
and category in the order below and otherwise in source order:

    palette<TAB>category<TAB>value

Repeats within a category are dropped.
"""
from __future__ import annotations

import re
import unicodedata

PALETTE_FORMAT_VERSION = 2

# Stands for the values of every key in ``punctuator/full_shape``, in key order.
FULL_SHAPE = "full_shape"
# Palette category -> rime-prelude shortcuts, in palette order.
SYMBOL_CATEGORIES = {
    "punctuation": [FULL_SHAPE, "/bd", "/bdz"],
    "shapes": ["/xh", "/jh", "/fk", "/fh", "/pk", "/yy", "/tq", "/bq", "/lx", "/xq", "/sz", "/mj", "/bg", "/tt", "/xz", "/dn"],
    "arrows": ["/jt"],
    "math": ["/sx", "/fs", "/sb", "/xb"],
    "numbers": ["/szq", "/szh", "/szd", "/lmd", "/lm", "/zmq", "/zmh", "/hzq", "/hzh", "/szm"],
    "units": ["/dw", "/hb", "/sj", "/yf", "/rq"],
    "letters": ["/zy", "/sd", "/py", "/pyd", "/xl", "/xld", "/ey", "/eyd", "/jm", "/pjm", "/jmbj", "/hw"],
}
# Mozc category -> palette category, in palette order.
KAOMOJI_CATEGORIES = {
    "SMILE": "smile",
    "SWEAT": "sweat",
    "SURPRISE": "surprise",
    "SADNESS": "sadness",
    "DISPLEASURE": "displeasure",
}

SHORTCUT_LINE = re.compile(r"^\s+'(/[^']+)'\s*:\s*\[(.*)\]\s*$")
KEY_LINE = re.compile(r"^    ('(?:[^']|'')*')\s*:\s*(.+?)\s*$")


class PaletteFormatError(ValueError):
    pass


def is_palette_value(value: str) -> bool:
    # The full-width space is kept on its own; the keyboard shows it by name.
    if value == "\u3000":
        return True
    return bool(value) and not any(
        unicodedata.category(character) in ("Cc", "Zs", "Zl", "Zp") for character in value
    )


def parse_flow_sequence(text: str) -> list[str]:
    """Parses the inside of a one-line YAML flow sequence of plain or
    single-quoted scalars."""
    items: list[str] = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index] == " ":
            index += 1
        if index == len(text):
            break
        if text[index] == "'":
            value = []
            index += 1
            while True:
                if index >= len(text):
                    raise PaletteFormatError("unterminated quoted scalar")
                if text[index] == "'":
                    if text[index + 1 : index + 2] == "'":
                        value.append("'")
                        index += 2
                        continue
                    index += 1
                    break
                value.append(text[index])
                index += 1
            items.append("".join(value))
            while index < len(text) and text[index] == " ":
                index += 1
        elif text[index] in "\"[]{}":
            raise PaletteFormatError(f"unsupported flow syntax {text[index]!r}")
        else:
            end = text.find(",", index)
            end = len(text) if end < 0 else end
            items.append(text[index:end].strip())
            index = end
        if index < len(text):
            if text[index] != ",":
                raise PaletteFormatError(f"expected ',' at column {index + 1}")
            index += 1
    return items


def parse_key_value(text: str) -> list[str]:
    """Parses a ``full_shape`` value: a scalar, a list, ``{ commit: x }`` or
    ``{ pair: [ a, b ] }``."""
    if text.startswith("{") and text.endswith("}"):
        name, _, value = text[1:-1].strip().partition(":")
        value = value.strip()
        if name.strip() == "commit":
            return parse_flow_sequence(value)
        if name.strip() == "pair" and value.startswith("[") and value.endswith("]"):
            return parse_flow_sequence(value[1:-1])
        raise PaletteFormatError(f"unsupported mapping {text!r}")
    if text.startswith("[") and text.endswith("]"):
        return parse_flow_sequence(text[1:-1])
    return parse_flow_sequence(text)


def parse_rime_full_shape(text: str, source_label: str) -> list[str]:
    """Returns the values of ``punctuator/full_shape``, in key order."""
    values: list[str] = []
    errors: list[str] = []
    in_block = False
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("  full_shape:"):
            in_block = True
            continue
        if not in_block or line.startswith("#") or not line.strip():
            continue
        if not line.startswith("    "):
            break
        match = KEY_LINE.match(line)
        try:
            if match is None:
                raise PaletteFormatError("malformed key line")
            values.extend(parse_key_value(match.group(2)))
        except PaletteFormatError as error:
            errors.append(f"{source_label}:{line_number}: {error}")
    if not values:
        errors.append(f"{source_label}: no punctuator/full_shape block")
    if errors:
        shown_errors = "\n".join(errors[:8])
        raise PaletteFormatError(f"{len(errors)} format errors:\n{shown_errors}")
    return values


def parse_rime_symbols(text: str, source_label: str) -> dict[str, list[str]]:
    """Returns shortcut -> symbols from the ``punctuator/symbols`` block, plus
    the ``full_shape`` punctuation under ``FULL_SHAPE``."""
    symbols: dict[str, list[str]] = {FULL_SHAPE: parse_rime_full_shape(text, source_label)}
    errors: list[str] = []
    in_block = False
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("  symbols:"):
            in_block = True
            continue
        if not in_block or line.startswith("#") or not line.strip():
            continue
        if not line.startswith("    "):
            break
        match = SHORTCUT_LINE.match(line)
        if match is None:
            errors.append(f"{source_label}:{line_number}: malformed shortcut line")
            continue
        try:
            values = parse_flow_sequence(match.group(2))
        except PaletteFormatError as error:
            errors.append(f"{source_label}:{line_number}: {error}")
            continue
        if match.group(1) in symbols:
            errors.append(f"{source_label}:{line_number}: duplicate shortcut {match.group(1)}")
            continue
        symbols[match.group(1)] = values
    if not symbols:
        errors.append(f"{source_label}: no punctuator/symbols block")
    if errors:
        shown_errors = "\n".join(errors[:8])
        raise PaletteFormatError(f"{len(errors)} format errors:\n{shown_errors}")
    return symbols


def symbol_palette(symbols: dict[str, list[str]], source_label: str) -> dict[str, list[str]]:
    """Collects the shortcuts of each palette category, without repeats."""
    result: dict[str, list[str]] = {}
    errors: list[str] = []
    for category, shortcuts in SYMBOL_CATEGORIES.items():
        values: list[str] = []
        for shortcut in shortcuts:
            if shortcut not in symbols:
                errors.append(f"{source_label}: missing shortcut {shortcut}")
                continue
            for value in symbols[shortcut]:
                if not is_palette_value(value):
                    errors.append(f"{source_label}: invalid value {value!r} in {shortcut}")
                elif value not in values:
                    values.append(value)
        result[category] = values
    if errors:
        shown_errors = "\n".join(errors[:8])
        raise PaletteFormatError(f"{len(errors)} format errors:\n{shown_errors}")
    return result


def parse_mozc_categorized(
    text: str, source_label: str, categories: dict[str, str]
) -> dict[str, list[str]]:
    """Returns palette category -> values in source order, without repeats."""
    result: dict[str, list[str]] = {category: [] for category in categories.values()}
    seen: dict[str, set[str]] = {category: set() for category in categories.values()}
    errors: list[str] = []
    for line_number, line in enumerate(text.split("\n"), start=1):
        line = line.removesuffix("\r")
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 2 or not fields[0]:
            errors.append(f"{source_label}:{line_number}: malformed line")
            continue
        value = fields[0]
        if any(unicodedata.category(character) in ("Cc", "Zl", "Zp") for character in value):
            errors.append(f"{source_label}:{line_number}: control character in value")
            continue
        names = fields[1].split()
        if not names:
            errors.append(f"{source_label}:{line_number}: no category")
            continue
        for name in names:
            category = categories.get(name)
            if category is None:
                errors.append(f"{source_label}:{line_number}: unknown category {name!r}")
                continue
            if value not in seen[category]:
                seen[category].add(value)
                result[category].append(value)
    if errors:
        shown_errors = "\n".join(errors[:8])
        raise PaletteFormatError(f"{len(errors)} format errors:\n{shown_errors}")
    empty = [category for category, values in result.items() if not values]
    if empty:
        raise PaletteFormatError(f"{source_label}: no entries in categories {empty}")
    return result


def format_palettes(palettes: dict[str, dict[str, list[str]]]) -> str:
    return "".join(
        f"{palette}\t{category}\t{value}\n"
        for palette, categories in palettes.items()
        for category, values in categories.items()
        for value in values
    )
