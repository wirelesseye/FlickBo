"""OpenCC dictionaries compiled into the FZOpenCC format.

The keyboard converts candidates from OpenCC Standard Traditional (the form
the Rime lexicon and grammar use) into the user's chosen region, and reads
the text before the cursor back the other way. This module reproduces the
parts of OpenCC 1.4 that those conversions need:

* text dictionaries (``key<TAB>value value ...``; only the first value is used
  for conversion, as OpenCC's ``DictEntry::GetDefault`` does);
* the generated ``*VariantsRev`` dictionaries, built like OpenCC's
  ``data/scripts/reverse.py`` including ``# @reverse-prefer:`` annotations;
* conversion chains whose steps are ``short_circuit`` dictionary groups: at
  each position the first dictionary of the group with any prefix match wins
  and contributes its longest matching key; unmatched characters are copied.

Not reproduced: segmentation (none of the configs used here declare one),
``may_output_tofu`` dictionaries (off by default in OpenCC), and
``STPhrases_GeneratedFromRegionalPhrases`` (only affects ``s2t``, which the
keyboard uses for grammar context, never for output).

FZOpenCC v1 layout (all integers little-endian ``u32``):

    header (32 bytes)
        magic "FZOPENCC", version, dict count, conversion count,
        dict table offset, conversion table offset, strings offset
    dict table: per dict (16 bytes)
        name offset, name length, entry count, entries offset
    entries: per entry (16 bytes), sorted by key UTF-8 bytes
        key offset, key length, value offset, value length
    conversion table: per conversion (16 bytes)
        name offset, name length, step count, steps offset
    steps: per step: dict count, then that many dict indices
    strings: UTF-8 bytes; all string offsets are relative to this section
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

FZOPENCC_MAGIC = b"FZOPENCC"
FZOPENCC_VERSION = 1
FZOPENCC_HEADER_SIZE = 32
REVERSE_PREFERENCE_PREFIX = "# @reverse-prefer:"

# Text dictionaries taken from OpenCC's data/dictionary directory.
SOURCE_DICTIONARIES = (
    "CJK_Compatibility_Ideographs",
    "HKVariants",
    "HKVariantsPhrases",
    "HKVariantsRevPhrases",
    "STCharacters",
    "STPhrases",
    "TSCharacters",
    "TSPhrases",
    # Not a conversion step: compile_dictionary.py turns it into Taiwan
    # vocabulary weights in the lexicon.
    "TWPhrases",
    "TWVariants",
    "TWVariantsPhrases",
    "TWVariantsRevPhrases",
)

# Generated dictionary -> source dictionary it reverses.
REVERSED_DICTIONARIES = {
    "TWVariantsRev": "TWVariants",
    "HKVariantsRev": "HKVariants",
}

NORMALIZATION = ("CJK_Compatibility_Ideographs",)

# Conversion name -> steps; each step is a short-circuit dictionary group.
# Mirrors data/config/<name>.json in OpenCC 1.4.2, normalization first.
CONVERSIONS: dict[str, tuple[tuple[str, ...], ...]] = {
    "t2tw": (NORMALIZATION, ("TWVariantsPhrases", "TWVariants")),
    "tw2t": (NORMALIZATION, ("TWVariantsRevPhrases", "TWVariantsRev")),
    "t2hk": (NORMALIZATION, ("HKVariantsPhrases", "HKVariants")),
    "hk2t": (NORMALIZATION, ("HKVariantsRevPhrases", "HKVariantsRev")),
    "t2s": (NORMALIZATION, ("TSPhrases", "TSCharacters")),
    "s2t": (NORMALIZATION, ("STPhrases", "STCharacters")),
}


class OpenCCFormatError(Exception):
    pass


@dataclass(frozen=True)
class TextDictionary:
    # key -> all values, in file order
    entries: dict[str, list[str]]
    # reversed key -> preferred value, from "# @reverse-prefer:" lines
    reverse_preferences: dict[str, str]


def parse_dictionary_text(text: str, label: str) -> TextDictionary:
    entries: dict[str, list[str]] = {}
    preferences: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.rstrip("\r\n")
        if line.startswith(REVERSE_PREFERENCE_PREFIX):
            fields = line[len(REVERSE_PREFERENCE_PREFIX):].split()
            if len(fields) not in (1, 2):
                raise OpenCCFormatError(f"{label}:{line_number}: invalid reverse preference")
            preferences[fields[0]] = fields[-1]
            continue
        if not line.strip() or line.startswith("#"):
            continue
        if "\t" not in line:
            raise OpenCCFormatError(f"{label}:{line_number}: missing tab")
        key, value_text = line.split("\t", 1)
        values = value_text.split(" ")
        if not key or not values or not all(values):
            raise OpenCCFormatError(f"{label}:{line_number}: empty key or value")
        if key in entries:
            raise OpenCCFormatError(f"{label}:{line_number}: duplicate key {key}")
        entries[key] = values
    return TextDictionary(entries=entries, reverse_preferences=preferences)


def reverse_dictionary(source: TextDictionary, label: str) -> dict[str, list[str]]:
    """Same result as OpenCC's ``Dict.swap`` (data/scripts/common.py)."""
    reversed_entries: dict[str, list[str]] = {}
    for key, values in source.entries.items():
        for value in values:
            reversed_entries.setdefault(value, []).append(key)
    for key, preferred in source.reverse_preferences.items():
        values = reversed_entries.get(key)
        if values is None or preferred not in values:
            raise OpenCCFormatError(f"{label}: reverse preference {key} -> {preferred} has no mapping")
        values.insert(0, values.pop(values.index(preferred)))
    return reversed_entries


def load_dictionaries(source_directory: Path) -> dict[str, dict[str, str]]:
    """Every dictionary the conversions use, as key -> default value."""
    parsed = {
        name: parse_dictionary_text(
            (source_directory / f"{name}.txt").read_text(encoding="utf-8"), f"{name}.txt"
        )
        for name in SOURCE_DICTIONARIES
    }
    dictionaries = {name: {key: values[0] for key, values in item.entries.items()} for name, item in parsed.items()}
    for name, source_name in REVERSED_DICTIONARIES.items():
        reversed_entries = reverse_dictionary(parsed[source_name], f"{source_name}.txt")
        dictionaries[name] = {key: values[0] for key, values in reversed_entries.items()}
    for conversion, steps in CONVERSIONS.items():
        for step in steps:
            for name in step:
                if name not in dictionaries:
                    raise OpenCCFormatError(f"{conversion}: unknown dictionary {name}")
    return dictionaries


class Converter:
    """Reference implementation of the conversion the Swift runtime performs."""

    def __init__(self, dictionaries: dict[str, dict[str, str]], steps: tuple[tuple[str, ...], ...]):
        self._steps = [
            [(dictionaries[name], max((len(key) for key in dictionaries[name]), default=0)) for name in step]
            for step in steps
        ]

    def convert(self, text: str) -> str:
        for group in self._steps:
            text = self._convert_step(text, group)
        return text

    @staticmethod
    def _convert_step(text: str, group: list[tuple[dict[str, str], int]]) -> str:
        output: list[str] = []
        position = 0
        while position < len(text):
            matched: tuple[int, str] | None = None
            for dictionary, longest in group:
                for length in range(min(longest, len(text) - position), 0, -1):
                    value = dictionary.get(text[position:position + length])
                    if value is not None:
                        matched = (length, value)
                        break
                if matched is not None:
                    break
            if matched is None:
                output.append(text[position])
                position += 1
            else:
                output.append(matched[1])
                position += matched[0]
        return "".join(output)


def converters(dictionaries: dict[str, dict[str, str]]) -> dict[str, Converter]:
    return {name: Converter(dictionaries, steps) for name, steps in CONVERSIONS.items()}


def write_fzopencc(dictionaries: dict[str, dict[str, str]]) -> bytes:
    names = sorted({name for steps in CONVERSIONS.values() for step in steps for name in step})
    index_of = {name: index for index, name in enumerate(names)}
    strings = bytearray()
    interned: dict[bytes, int] = {}

    def intern(value: str) -> tuple[int, int]:
        data = value.encode("utf-8")
        offset = interned.get(data)
        if offset is None:
            offset = len(strings)
            strings.extend(data)
            interned[data] = offset
        return offset, len(data)

    dict_table = bytearray()
    entry_sections: list[bytes] = []
    for name in names:
        entries = bytearray()
        for key, value in sorted(dictionaries[name].items(), key=lambda item: item[0].encode("utf-8")):
            entries += struct.pack("<4I", *intern(key), *intern(value))
        entry_sections.append(bytes(entries))

    conversion_names = sorted(CONVERSIONS)
    step_sections: list[bytes] = []
    for conversion in conversion_names:
        steps = bytearray()
        for step in CONVERSIONS[conversion]:
            steps += struct.pack(f"<{1 + len(step)}I", len(step), *(index_of[name] for name in step))
        step_sections.append(bytes(steps))

    dict_table_offset = FZOPENCC_HEADER_SIZE
    conversion_table_offset = dict_table_offset + 16 * len(names)
    cursor = conversion_table_offset + 16 * len(conversion_names)
    for name, entries in zip(names, entry_sections):
        name_offset, name_length = intern(name)
        dict_table += struct.pack("<4I", name_offset, name_length, len(entries) // 16, cursor)
        cursor += len(entries)
    conversion_table = bytearray()
    for conversion, steps in zip(conversion_names, step_sections):
        name_offset, name_length = intern(conversion)
        conversion_table += struct.pack(
            "<4I", name_offset, name_length, len(CONVERSIONS[conversion]), cursor
        )
        cursor += len(steps)
    strings_offset = cursor

    header = FZOPENCC_MAGIC + struct.pack(
        "<6I",
        FZOPENCC_VERSION,
        len(names),
        len(conversion_names),
        dict_table_offset,
        conversion_table_offset,
        strings_offset,
    )
    assert len(header) == FZOPENCC_HEADER_SIZE
    output = header + dict_table + conversion_table + b"".join(entry_sections) + b"".join(step_sections)
    assert len(output) == strings_offset
    return bytes(output + strings)


def read_fzopencc(data: bytes) -> tuple[dict[str, dict[str, str]], dict[str, tuple[tuple[str, ...], ...]]]:
    """Decode an FZOpenCC file; used by tests to check the writer round-trips."""
    if data[:8] != FZOPENCC_MAGIC:
        raise OpenCCFormatError("bad magic")
    version, dict_count, conversion_count, dict_table, conversion_table, strings_offset = struct.unpack_from(
        "<6I", data, 8
    )
    if version != FZOPENCC_VERSION:
        raise OpenCCFormatError(f"unsupported version {version}")

    def string(offset: int, length: int) -> str:
        start = strings_offset + offset
        return data[start:start + length].decode("utf-8")

    names: list[str] = []
    dictionaries: dict[str, dict[str, str]] = {}
    for index in range(dict_count):
        name_offset, name_length, entry_count, entries_offset = struct.unpack_from("<4I", data, dict_table + 16 * index)
        name = string(name_offset, name_length)
        names.append(name)
        entries = {}
        for entry in range(entry_count):
            key_offset, key_length, value_offset, value_length = struct.unpack_from(
                "<4I", data, entries_offset + 16 * entry
            )
            entries[string(key_offset, key_length)] = string(value_offset, value_length)
        dictionaries[name] = entries
    conversions: dict[str, tuple[tuple[str, ...], ...]] = {}
    for index in range(conversion_count):
        name_offset, name_length, step_count, steps_offset = struct.unpack_from(
            "<4I", data, conversion_table + 16 * index
        )
        steps = []
        cursor = steps_offset
        for _ in range(step_count):
            (count,) = struct.unpack_from("<I", data, cursor)
            indices = struct.unpack_from(f"<{count}I", data, cursor + 4)
            steps.append(tuple(names[i] for i in indices))
            cursor += 4 + 4 * count
        conversions[string(name_offset, name_length)] = tuple(steps)
    return dictionaries, conversions


# Upstream cases whose expected output needs OpenCC's opt-in
# ``may_output_tofu`` dictionary (TSCharactersExt), which is not compiled.
TOFU_DEPENDENT_CASES = frozenset({
    "BYVoid_OpenCC_PR_1228_existing_behaviors",
    "BYVoid_OpenCC_PR_1229_existing_behaviors",
    "BYVoid_OpenCC_PR_464_xi_vs_xi",
})

# Keyboard-level cases on top of the upstream ones (conversion, input).
EXTRA_GOLDEN_INPUTS = (
    ("t2tw", "爲什麼"),
    ("t2tw", "裏面"),
    ("t2tw", "着急"),
    ("t2tw", "衆人"),
    ("tw2t", "為什麼"),
    ("tw2t", "著作"),
    ("t2hk", "爲什麼"),
    ("t2s", "爲什麼"),
    ("s2t", "为什么"),
)


def load_upstream_cases(path: Path) -> list[dict]:
    """OpenCC's testcases.json allows trailing commas, which json rejects."""
    import json
    import re

    text = re.sub(r",(\s*[}\]])", r"\1", path.read_text(encoding="utf-8"))
    return json.loads(text)["cases"]


def golden_rows(dictionaries: dict[str, dict[str, str]], testcases_path: Path) -> list[tuple[str, str, str]]:
    """(conversion, input, expected) rows the Swift converter must reproduce."""
    by_name = converters(dictionaries)
    rows: list[tuple[str, str, str]] = []
    for case in load_upstream_cases(testcases_path):
        if case["id"] in TOFU_DEPENDENT_CASES:
            continue
        for name, expected in sorted(case["expected"].items()):
            if name in by_name:
                rows.append((name, case["input"], expected))
    for name, text in EXTRA_GOLDEN_INPUTS:
        rows.append((name, text, by_name[name].convert(text)))
    for name, text, expected in rows:
        if "\t" in text or "\n" in text or "\t" in expected or "\n" in expected:
            raise OpenCCFormatError(f"golden row for {name} cannot be stored as TSV: {text!r}")
    return rows


def format_golden(rows: list[tuple[str, str, str]]) -> str:
    return "".join(f"{name}\t{text}\t{expected}\n" for name, text, expected in rows)
