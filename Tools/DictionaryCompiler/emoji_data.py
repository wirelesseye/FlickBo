"""rime-emoji word table compiled into the keyboard's emoji candidate file.

Upstream ``opencc/emoji_word.txt`` is an OpenCC text dictionary that maps a
word to itself followed by emoji (``笑<TAB>笑 😄️ 😸️``), so OpenCC's
conversion keeps the word and offers the emoji as alternatives. Keys are in
the Traditional Chinese forms Rime uses, which match the lexicon's OpenCC
Standard Traditional text.

The output is plain UTF-8, one line per word, sorted by key UTF-8 bytes:

    word<TAB>emoji<SPACE>emoji...

Compilation drops the leading copy of the word, repeated emoji and the
U+FE0F that upstream appends after skin tone modifiers (a modifier already
gives the sequence emoji presentation, and the extra selector is not part of
any valid emoji sequence). Every emoji must contain no letters or CJK
ideographs, so a malformed line fails the build instead of putting text into
the candidate list.
"""
from __future__ import annotations

import unicodedata

EMOJI_FORMAT_VERSION = 1
VARIATION_SELECTOR_16 = "️"
SKIN_TONE_MODIFIERS = frozenset(chr(code) for code in range(0x1F3FB, 0x1F400))
KEYCAP = "⃣"


class EmojiFormatError(ValueError):
    pass


def normalize_emoji(value: str) -> str:
    result: list[str] = []
    for character in value:
        if character == VARIATION_SELECTOR_16 and result and result[-1] in SKIN_TONE_MODIFIERS:
            continue
        result.append(character)
    return "".join(result)


def is_emoji_value(value: str) -> bool:
    if not value:
        return False
    has_pictograph = False
    for index, character in enumerate(value):
        category = unicodedata.category(character)
        if category.startswith("Z"):
            return False
        if category.startswith("L"):
            # Only a letter-like emoji with presentation selector (ℹ️) is allowed.
            if value[index + 1 : index + 2] != VARIATION_SELECTOR_16:
                return False
            has_pictograph = True
            continue
        # Joiners, selectors and flag tags are the only allowed control-like scalars.
        is_sequence_scalar = (
            character in ("‍", VARIATION_SELECTOR_16)
            or "\U000e0020" <= character <= "\U000e007f"
        )
        if category.startswith("C") and not is_sequence_scalar:
            return False
        if category[0] in "SP" or character == KEYCAP:
            has_pictograph = True
    return has_pictograph


def parse_emoji_words(text: str, source_label: str) -> dict[str, list[str]]:
    table: dict[str, list[str]] = {}
    errors: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or fields[0] != fields[0].strip():
            errors.append(f"{source_label}:{line_number}: expected word<TAB>values")
            continue
        word, values = fields
        if word in table:
            errors.append(f"{source_label}:{line_number}: duplicate word {word!r}")
            continue
        emoji: list[str] = []
        for value in values.split(" "):
            if value == word:
                continue
            normalized = normalize_emoji(value)
            if not is_emoji_value(normalized):
                errors.append(f"{source_label}:{line_number}: {value!r} is not an emoji")
                break
            if normalized not in emoji:
                emoji.append(normalized)
        else:
            if emoji:
                table[word] = emoji
    if errors:
        shown = "\n".join(errors[:8])
        raise EmojiFormatError(f"{len(errors)} format errors:\n{shown}")
    return table


def format_emoji_table(table: dict[str, list[str]]) -> str:
    keys = sorted(table, key=lambda key: key.encode("utf-8"))
    return "".join(f"{key}\t{' '.join(table[key])}\n" for key in keys)


# Unicode emoji-test.txt → emoji palette catalog
#
# The palette lists the fully-qualified emoji of emoji-test.txt in its CLDR
# order (recommended for keyboards), one line each:
#
#     group<TAB>emoji version<TAB>emoji<TAB>CLDR short name
#
# Skin tone variants are left out (the palette shows the default yellow
# form), as is the Component group. The emoji version lets the keyboard hide
# emoji newer than the system font can draw.

CATALOG_FORMAT_VERSION = 1
CATALOG_GROUPS = {
    "Smileys & Emotion": "smileys",
    "People & Body": "people",
    "Animals & Nature": "animals",
    "Food & Drink": "food",
    "Travel & Places": "travel",
    "Activities": "activities",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}
SKIPPED_GROUPS = frozenset({"Component"})


def parse_emoji_test(text: str, source_label: str) -> list[tuple[str, str, str, str]]:
    """Returns (group id, version, emoji, name) rows in file order."""
    rows: list[tuple[str, str, str, str]] = []
    errors: list[str] = []
    group: str | None = None
    seen: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("# group:"):
            name = line.removeprefix("# group:").strip()
            if name in SKIPPED_GROUPS:
                group = None
            elif name in CATALOG_GROUPS:
                group = CATALOG_GROUPS[name]
            else:
                errors.append(f"{source_label}:{line_number}: unknown group {name!r}")
                group = None
            continue
        if not line or line.startswith("#"):
            continue
        try:
            fields, comment = line.split("#", 1)
            code_points, status = (part.strip() for part in fields.split(";"))
            emoji = "".join(chr(int(value, 16)) for value in code_points.split())
            shown, version, name = comment.strip().split(" ", 2)
        except ValueError:
            errors.append(f"{source_label}:{line_number}: malformed line")
            continue
        if status != "fully-qualified" or group is None:
            continue
        if not version.startswith("E") or shown != emoji:
            errors.append(f"{source_label}:{line_number}: malformed comment")
            continue
        if any(character in SKIN_TONE_MODIFIERS for character in emoji):
            continue
        if emoji in seen:
            errors.append(f"{source_label}:{line_number}: duplicate emoji")
            continue
        seen.add(emoji)
        rows.append((group, version.removeprefix("E"), emoji, name))
    if errors:
        shown_errors = "\n".join(errors[:8])
        raise EmojiFormatError(f"{len(errors)} format errors:\n{shown_errors}")
    missing = set(CATALOG_GROUPS.values()) - {row[0] for row in rows}
    if missing:
        raise EmojiFormatError(f"{source_label}: no emoji in groups {sorted(missing)}")
    return rows


def format_emoji_catalog(rows: list[tuple[str, str, str, str]]) -> str:
    return "".join("\t".join(row) + "\n" for row in rows)
