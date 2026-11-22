#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sqlite3
import sys
import urllib.request
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

from opencc_data import (
    CONVERSIONS as OPENCC_CONVERSIONS,
    SOURCE_DICTIONARIES as OPENCC_SOURCE_DICTIONARIES,
    OpenCCFormatError,
    format_golden as format_opencc_golden,
    golden_rows as opencc_golden_rows,
    load_dictionaries as load_opencc_dictionaries,
    parse_dictionary_text as parse_opencc_dictionary_text,
    write_fzopencc,
)
from emoji_data import (
    CATALOG_FORMAT_VERSION,
    EMOJI_FORMAT_VERSION,
    KEYWORDS_FORMAT_VERSION,
    EmojiFormatError,
    format_emoji_catalog,
    format_emoji_keywords,
    format_emoji_table,
    merge_emoji_keywords,
    parse_cldr_annotations,
    parse_emoji_test,
    parse_emoji_words,
)
from symbol_data import (
    KAOMOJI_CATEGORIES,
    PALETTE_FORMAT_VERSION,
    PaletteFormatError,
    format_palettes,
    parse_mozc_categorized,
    parse_rime_symbols,
    symbol_palette,
)
from octagram import FZGRAM_DEFAULT_BLOCK_SIZE, FZGram, GramFormatError, read_gram, write_fzgram
from pinyin_to_zhuyin import PinyinError, convert_syllable, strip_tone

TERRA_REPOSITORY = "https://github.com/rime/rime-terra-pinyin"
TERRA_RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-terra-pinyin"
TERRA_DICTIONARY_PATH = "terra_pinyin.dict.yaml"
ESSAY_REPOSITORY = "https://github.com/rime/rime-essay"
ESSAY_RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-essay"
ESSAY_PATH = "essay.txt"
ESSAY_FORMAT_VERSION = 1
OCTAGRAM_REPOSITORY = "https://github.com/lotem/rime-octagram-data"
OCTAGRAM_RAW_BASE_URL = "https://raw.githubusercontent.com/lotem/rime-octagram-data"
OCTAGRAM_GRAM_PATH = "zh-hant-t-essay-bgw.gram"
OCTAGRAM_FORMAT_VERSION = 1
GRAMMAR_COMPILER_VERSION = 1
OPENCC_REPOSITORY = "https://github.com/BYVoid/OpenCC"
OPENCC_RAW_BASE_URL = "https://raw.githubusercontent.com/BYVoid/OpenCC"
OPENCC_DICTIONARY_DIRECTORY = "data/dictionary"
OPENCC_TESTCASES_PATH = "test/testcases/testcases.json"
OPENCC_COMPILER_VERSION = 1
EMOJI_REPOSITORY = "https://github.com/rime/rime-emoji"
EMOJI_RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-emoji"
EMOJI_WORD_PATH = "opencc/emoji_word.txt"
MAXIMUM_EMOJI_BYTES = 1024 * 1024
UNICODE_EMOJI_BASE_URL = "https://www.unicode.org/Public/{version}/emoji"
UNICODE_LICENSE_URL = "https://www.unicode.org/license.txt"
UNICODE_VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
CLDR_REPOSITORY = "https://github.com/unicode-org/cldr"
CLDR_RAW_BASE_URL = "https://raw.githubusercontent.com/unicode-org/cldr"
RIME_PRELUDE_REPOSITORY = "https://github.com/rime/rime-prelude"
RIME_PRELUDE_RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-prelude"
MOZC_REPOSITORY = "https://github.com/google/mozc"
MOZC_RAW_BASE_URL = "https://raw.githubusercontent.com/google/mozc"
MAXIMUM_PALETTE_BYTES = 256 * 1024
MAXIMUM_OPENCC_BYTES = 8 * 1024 * 1024
MAXIMUM_GRAMMAR_BYTES = 64 * 1024 * 1024
MAXIMUM_GRAMMAR_KEY_CHARACTERS = 8
SENTENCE_BOUNDARY = "$"
COMPILER_VERSION = "8"
SCHEMA_VERSION = 5
REQUIRED_HEADER_KEYS = ("name", "version")
REQUIRED_METADATA_KEYS = (
    "schema_version",
    "terra_source_repository",
    "terra_source_commit",
    "terra_source_sha256",
    "essay_source_repository",
    "essay_source_commit",
    "essay_source_sha256",
    "dictionary_name",
    "dictionary_version",
    "compiler_version",
    "entry_count",
    "max_syllable_count",
    "essay_entry_count",
    "essay_annotated_entry_count",
    "essay_frequency_max",
    "weight_normalization",
)
WEIGHT_PATTERN = re.compile(r"^(\d+(?:\.\d+)?)%$")
INTEGER_PATTERN = re.compile(r"^\d+$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SEPARATOR = "\u001f"
MAXIMUM_PRONUNCIATIONS_PER_WORD = 16
MAXIMUM_ESSAY_WORD_LENGTH = 16
# Terra words up to this length whose alternative readings spread to longer entries.
MAXIMUM_PROPAGATED_WORD_LENGTH = 4
# Propagated readings come from explicit Terra words, so they may go past the
# per-word limit that bounds character-by-character composition, up to this.
MAXIMUM_PRONUNCIATIONS_WITH_PROPAGATION = 2 * MAXIMUM_PRONUNCIATIONS_PER_WORD
MINIMUM_SINGLE_CHARACTER_PRONUNCIATION_WEIGHT = 0.05
READING_PRIOR_EXAMPLE_CHARACTERS = "長爲了的一子都中好要重樂識"
# Characters whose tone changes by rule inside words (一個 is yí gè), so the
# readings Terra gives them in words say nothing about the one users type.
TONE_SANDHI_CHARACTERS = frozenset("一不")
NEUTRAL_TONE = 5
MAXIMUM_DATABASE_BYTES = 256 * 1024 * 1024
MAXIMUM_STORED_INTEGER = 9_223_372_036_854_775_807
REPORT_EXAMPLE_LIMIT = 8
WEIGHT_NORMALIZATION = "log1p(frequency)/log1p(max_frequency)"
SOURCE_KIND_TERRA = "terra"
SOURCE_KIND_ESSAY = "essay"
SOURCE_KIND_MERGED = "terra+essay"
SOURCE_KIND_OPENCC_TAIWAN = "opencc-tw"
TAIWAN_PHRASES_FILE = "TWPhrases.txt"

SCHEMA = """
CREATE TABLE metadata (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE syllable_inventory (
    base TEXT PRIMARY KEY NOT NULL
) WITHOUT ROWID;

CREATE TABLE pronunciation (
    id                INTEGER PRIMARY KEY,
    text              TEXT NOT NULL,
    syllable_count    INTEGER NOT NULL,
    base_key          TEXT NOT NULL,
    tone_key          TEXT NOT NULL,
    initial_key       TEXT NOT NULL,
    source_weight     REAL,
    pronunciation_weight REAL,
    source_kind       TEXT NOT NULL CHECK (source_kind IN ('terra', 'essay', 'terra+essay', 'opencc-tw')),
    terra_source_line INTEGER,
    terra_source_lines TEXT NOT NULL,
    essay_source_line INTEGER,
    raw_frequency     INTEGER,
    taiwan_source_weight REAL,
    UNIQUE(text, base_key, tone_key)
);

CREATE INDEX pronunciation_base_key
ON pronunciation(base_key, syllable_count);

CREATE INDEX pronunciation_initial_key
ON pronunciation(
    initial_key,
    syllable_count,
    COALESCE(source_weight, pronunciation_weight) DESC
);

CREATE INDEX pronunciation_taiwan_initial_key
ON pronunciation(initial_key, syllable_count)
WHERE taiwan_source_weight IS NOT NULL;
"""


@dataclass(frozen=True)
class SourceEntry:
    text: str
    pinyin_syllables: tuple[str, ...]
    source_weight: float | None
    source_line: int


@dataclass(frozen=True)
class CompiledEntry:
    text: str
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    source_weight: float | None
    source_line: int

    @property
    def base_key(self) -> str:
        return SEPARATOR.join(self.base_syllables)

    @property
    def tone_key(self) -> str:
        return "".join(str(tone) for tone in self.tones)

    @property
    def syllable_count(self) -> int:
        return len(self.base_syllables)


@dataclass(frozen=True)
class ParsedDictionary:
    header: dict[str, str]
    entries: tuple[SourceEntry, ...]
    errors: tuple[str, ...]


@dataclass(frozen=True)
class EssayEntry:
    text: str
    frequency: int
    source_line: int


@dataclass(frozen=True)
class ParsedEssay:
    entries: tuple[EssayEntry, ...]
    errors: tuple[str, ...]


@dataclass(frozen=True)
class TerraReading:
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    source_weight: float | None
    pronunciation_weight: float | None
    source_line: int


@dataclass(frozen=True)
class TerraIndex:
    words: dict[str, tuple[TerraReading, ...]]
    characters: dict[str, tuple[TerraReading, ...]]


@dataclass(frozen=True)
class AnnotatedReading:
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    explicit: bool
    terra_lines: tuple[int, ...]
    pronunciation_weight: float | None


@dataclass(frozen=True)
class AnnotatedEssayEntry:
    text: str
    frequency: int
    source_line: int
    readings: tuple[AnnotatedReading, ...]
    truncated: bool


@dataclass(frozen=True)
class EssayAnnotation:
    entries: tuple[AnnotatedEssayEntry, ...]
    annotated_entries: int
    explicit_entries: int
    composed_entries: int
    unannotated_entries: int
    oversized_entries: int
    truncated_entries: int
    generated_pronunciations: int
    excluded_zero_weight_readings: int
    unannotated_examples: tuple[dict, ...]
    truncated_examples: tuple[dict, ...]
    oversized_examples: tuple[dict, ...]


@dataclass(frozen=True)
class MergedEntry:
    text: str
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    source_weight: float | None
    pronunciation_weight: float | None
    source_kind: str
    terra_source_line: int | None
    terra_source_lines: tuple[int, ...]
    essay_source_line: int | None
    raw_frequency: int | None
    # Weight used when candidates are shown in Taiwan forms; see
    # integrate_taiwan_phrases. None means source_weight applies.
    taiwan_source_weight: float | None = None

    @property
    def base_key(self) -> str:
        return SEPARATOR.join(self.base_syllables)

    @property
    def tone_key(self) -> str:
        return "".join(str(tone) for tone in self.tones)

    @property
    def initial_key(self) -> str:
        return SEPARATOR.join(base[0] for base in self.base_syllables)

    @property
    def syllable_count(self) -> int:
        return len(self.base_syllables)


@dataclass(frozen=True)
class BuildOutput:
    compiled_entries: int
    duplicate_entries: int
    merged_terra_essay_entries: int
    essay_entries: int
    essay_annotated_entries: int
    essay_unannotated_entries: int
    essay_truncated_entries: int
    database_bytes: int


class CompileFailure(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_header(text: str) -> tuple[dict[str, str], int]:
    lines = text.splitlines()
    header: dict[str, str] = {}
    start = None
    end = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if start is None:
            if stripped == "---":
                start = index
            continue
        if stripped == "...":
            end = index
            break
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, value = stripped.partition(":")
        if not separator:
            continue
        header[key.strip()] = value.strip().strip('"').strip("'")
    if start is None:
        raise CompileFailure("missing '---' header opener")
    if end is None:
        raise CompileFailure("missing '...' header terminator")
    return header, end + 1


def parse_weight(raw: str, line_number: int) -> float:
    match = WEIGHT_PATTERN.match(raw)
    if match is None:
        raise CompileFailure(f"line {line_number}: invalid weight {raw!r}")
    value = float(match.group(1)) / 100.0
    if not 0.0 <= value <= 1.0:
        raise CompileFailure(f"line {line_number}: weight out of range {raw!r}")
    return value


def parse_body_line(line: str, line_number: int, errors: list[str]) -> SourceEntry | None:
    columns = line.split("\t")
    if len(columns) not in (2, 3):
        errors.append(f"line {line_number}: expected 2 or 3 tab-separated columns, got {len(columns)}")
        return None
    text = columns[0]
    code = columns[1]
    if not text:
        errors.append(f"line {line_number}: empty text")
        return None
    if not code:
        errors.append(f"line {line_number}: empty code")
        return None
    syllables = code.split(" ")
    if any(not syllable for syllable in syllables):
        errors.append(f"line {line_number}: code {code!r} contains an empty pinyin syllable")
        return None
    weight = None
    if len(columns) == 3:
        try:
            weight = parse_weight(columns[2], line_number)
        except CompileFailure as failure:
            errors.append(str(failure))
            return None
    return SourceEntry(text, tuple(syllables), weight, line_number)


def parse_dictionary(path: Path) -> ParsedDictionary:
    text = Path(path).read_text(encoding="utf-8")
    try:
        header, body_start = read_header(text)
    except CompileFailure as failure:
        return ParsedDictionary({}, (), (f"{path}: {failure}",))
    errors: list[str] = []
    for key in REQUIRED_HEADER_KEYS:
        if not header.get(key):
            errors.append(f"{path}: header: missing required key {key!r}")
    entries: list[SourceEntry] = []
    lines = text.splitlines()
    for index in range(body_start, len(lines)):
        line = lines[index]
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        entry = parse_body_line(line, index + 1, errors)
        if entry is not None:
            entries.append(entry)
    return ParsedDictionary(header, tuple(entries), tuple(errors))


def parse_essay_text(text: str, source_label: str) -> ParsedEssay:
    errors: list[str] = []
    entries: list[EssayEntry] = []
    for index, raw in enumerate(text.splitlines(), start=1):
        if not raw.strip():
            continue
        if raw.lstrip().startswith("#"):
            continue
        columns = raw.split("\t")
        if len(columns) != 2:
            errors.append(f"{source_label}:{index}: expected 2 tab-separated columns, got {len(columns)}")
            continue
        word = columns[0]
        if not word:
            errors.append(f"{source_label}:{index}: empty text")
            continue
        raw_frequency = columns[1]
        if INTEGER_PATTERN.match(raw_frequency) is None:
            errors.append(f"{source_label}:{index}: invalid frequency {raw_frequency!r}")
            continue
        frequency = int(raw_frequency)
        if frequency > MAXIMUM_STORED_INTEGER:
            errors.append(f"{source_label}:{index}: frequency out of range {raw_frequency!r}")
            continue
        entries.append(EssayEntry(word, frequency, index))
    return ParsedEssay(tuple(entries), tuple(errors))


def parse_essay(path: Path) -> ParsedEssay:
    path = Path(path)
    return parse_essay_text(path.read_text(encoding="utf-8"), str(path))


def compile_terra_entries(
    entries: tuple[SourceEntry, ...],
    source_path: Path,
) -> tuple[list[CompiledEntry], list[str], list[dict], int, list[str]]:
    errors: list[str] = []
    converted: list[CompiledEntry] = []
    distinct_pinyin: set[str] = set()
    for entry in entries:
        bases: list[str] = []
        tones: list[int] = []
        failed = False
        for syllable in entry.pinyin_syllables:
            if strip_tone(syllable):
                distinct_pinyin.add(strip_tone(syllable))
            try:
                zhuyin = convert_syllable(syllable)
            except PinyinError as error:
                errors.append(f"{source_path}:{entry.source_line}: {error}")
                failed = True
                continue
            bases.append(zhuyin.base)
            tones.append(zhuyin.tone)
        if failed:
            continue
        converted.append(
            CompiledEntry(entry.text, tuple(bases), tuple(tones), entry.source_weight, entry.source_line)
        )

    unique: dict[tuple[str, str, str], CompiledEntry] = {}
    conflicts: list[dict] = []
    duplicates = 0
    for entry in converted:
        key = (entry.text, entry.base_key, entry.tone_key)
        existing = unique.get(key)
        if existing is None:
            unique[key] = entry
            continue
        duplicates += 1
        if entry.source_weight is None:
            continue
        if existing.source_weight is None:
            unique[key] = entry
            continue
        if entry.source_weight == existing.source_weight:
            continue
        if entry.source_weight > existing.source_weight:
            kept, discarded = entry, existing
            unique[key] = entry
        else:
            kept, discarded = existing, entry
        conflicts.append(
            {
                "text": kept.text,
                "baseKey": kept.base_key,
                "toneKey": kept.tone_key,
                "keptWeight": kept.source_weight,
                "discardedWeight": discarded.source_weight,
                "keptLine": kept.source_line,
                "discardedLine": discarded.source_line,
            }
        )
    rows = sorted(unique.values(), key=lambda e: (e.base_key, e.tone_key, e.text, e.source_line))
    return rows, errors, conflicts, duplicates, sorted(distinct_pinyin)


ReadingPriorKey = tuple[str, str, int]


@dataclass(frozen=True)
class ReadingPriors:
    weights: dict[ReadingPriorKey, float]
    adjusted_characters: int
    examples: tuple[dict, ...]


def terra_pronunciation_weight(
    text: str,
    source_weight: float | None,
    base_syllables: tuple[str, ...] = (),
    tones: tuple[int, ...] = (),
    priors: dict[ReadingPriorKey, float] | None = None,
) -> float | None:
    if len(text) == 1 and priors and base_syllables:
        prior = priors.get((text, base_syllables[0], tones[0]))
        if prior is not None:
            source_weight = prior
    if source_weight is None:
        return None
    if len(text) == 1:
        return max(source_weight, MINIMUM_SINGLE_CHARACTER_PRONUNCIATION_WEIGHT)
    return source_weight


def normalized_terra_priors(readings: tuple[TerraReading, ...]) -> list[float]:
    """Terra's percentages for one character as a distribution.

    Unweighted readings share what the weighted ones leave; the result is
    renormalized because Terra's percentages do not always sum to one.
    """
    known = sum(reading.source_weight for reading in readings if reading.source_weight is not None)
    unweighted = sum(1 for reading in readings if reading.source_weight is None)
    remainder = max(0.0, 1.0 - known) / unweighted if unweighted else 0.0
    priors = [reading.source_weight if reading.source_weight is not None else remainder for reading in readings]
    total = sum(priors)
    if total <= 0.0:
        return [1.0 / len(readings)] * len(readings)
    return [prior / total for prior in priors]


def estimate_reading_priors(index: TerraIndex, essay_entries: list[EssayEntry]) -> ReadingPriors:
    """Raise readings that Essay usage shows to be more common than Terra says.

    Terra's per-character percentages are rough editorial guesses (長 is 90%
    cháng, 10% zhǎng). Essay counts how often each word is used, and Terra
    gives the reading of every listed word, so the frequency of 成長, 長大 and
    校長 is evidence for zhǎng. A word listed with several readings splits its
    frequency equally among them. The character's own Essay frequency counts
    standalone uses, whose readings Essay cannot tell apart; it keeps Terra's
    percentages:

        usage(r) = (words(r) + standalone * terra(r)) / (words + standalone)
        prior(r) = max(terra(r), usage(r)), renormalized

    Word readings are not always the reading typed for the character alone:
    neutral tones (桌子), tone sandhi (一個) and mainland word readings (知識
    as zhīshi) would otherwise demote the citation reading. So usage only
    raises readings, never lowers Terra's, and neutral-tone word evidence
    counts only for characters whose main Terra reading is neutral (了, 的).
    Only characters with several readings and at least one Terra percentage
    are adjusted, so readings without percentages still carry no prior.
    """
    frequencies = {entry.text: entry.frequency for entry in essay_entries}
    evidence: dict[ReadingPriorKey, float] = {}
    for text, readings in index.words.items():
        frequency = frequencies.get(text, 0)
        if len(text) < 2 or frequency <= 0:
            continue
        distinct = {(reading.base_syllables, reading.tones) for reading in readings}
        share = frequency / len(distinct)
        for bases, tones in distinct:
            for character, base, tone in zip(text, bases, tones):
                key = (character, base, tone)
                evidence[key] = evidence.get(key, 0.0) + share

    weights: dict[ReadingPriorKey, float] = {}
    examples: list[dict] = []
    adjusted = 0
    for character, readings in index.characters.items():
        readings = deduplicate_terra_readings(readings)
        if (
            len(readings) < 2
            or character in TONE_SANDHI_CHARACTERS
            or all(reading.source_weight is None for reading in readings)
        ):
            continue
        keys = [(character, reading.base_syllables[0], reading.tones[0]) for reading in readings]
        terra = normalized_terra_priors(readings)
        main_tone = keys[max(range(len(keys)), key=lambda position: terra[position])][2]
        word_evidence = [
            evidence.get(key, 0.0) if key[2] != NEUTRAL_TONE or main_tone == NEUTRAL_TONE else 0.0
            for key in keys
        ]
        standalone = float(frequencies.get(character, 0))
        total = sum(word_evidence) + standalone
        if total <= 0.0:
            continue
        raised = [
            max(prior, (words + standalone * prior) / total)
            for prior, words in zip(terra, word_evidence)
        ]
        normalizer = sum(raised)
        adjusted += 1
        for key, value in zip(keys, raised):
            weights[key] = value / normalizer
        if character in READING_PRIOR_EXAMPLE_CHARACTERS:
            examples.append(
                {
                    "text": character,
                    "readings": [
                        {
                            "baseKey": key[1],
                            "tone": key[2],
                            "terra": round(prior, 4),
                            "estimated": round(weights[key], 4),
                        }
                        for key, prior in zip(keys, terra)
                    ],
                }
            )
    examples.sort(key=lambda example: READING_PRIOR_EXAMPLE_CHARACTERS.index(example["text"]))
    return ReadingPriors(weights, adjusted, tuple(examples))


def terra_reading_sort_key(reading: TerraReading) -> tuple:
    return (
        0 if reading.source_weight is not None else 1,
        -(reading.source_weight or 0.0),
        reading.source_line,
        reading.base_syllables,
        reading.tones,
    )


def build_terra_index(
    rows: list[CompiledEntry],
    priors: dict[ReadingPriorKey, float] | None = None,
) -> TerraIndex:
    words: dict[str, list[TerraReading]] = {}
    characters: dict[str, list[TerraReading]] = {}
    for row in rows:
        reading = TerraReading(
            row.base_syllables,
            row.tones,
            row.source_weight,
            terra_pronunciation_weight(row.text, row.source_weight, row.base_syllables, row.tones, priors),
            row.source_line,
        )
        words.setdefault(row.text, []).append(reading)
        if len(row.text) == 1:
            characters.setdefault(row.text, []).append(reading)
    return TerraIndex(
        words={text: tuple(sorted(readings, key=terra_reading_sort_key)) for text, readings in words.items()},
        characters={
            text: tuple(sorted(readings, key=terra_reading_sort_key)) for text, readings in characters.items()
        },
    )


def merge_essay_entries(entries: tuple[EssayEntry, ...]) -> tuple[list[EssayEntry], int]:
    merged: dict[str, EssayEntry] = {}
    duplicates = 0
    for entry in entries:
        existing = merged.get(entry.text)
        if existing is None:
            merged[entry.text] = entry
            continue
        duplicates += 1
        if entry.frequency > existing.frequency:
            merged[entry.text] = entry
    return list(merged.values()), duplicates


def readings_for_composition(readings: tuple[TerraReading, ...]) -> tuple[TerraReading, ...]:
    has_positive_weight = any(
        reading.source_weight is not None and reading.source_weight > 0.0
        for reading in readings
    )
    if not has_positive_weight:
        return readings
    return tuple(
        reading
        for reading in readings
        if reading.source_weight is None or reading.source_weight > 0.0
    )


def compose_readings(
    reading_lists: list[tuple[TerraReading, ...]],
    limit: int,
) -> list[AnnotatedReading]:
    results: list[AnnotatedReading] = []
    bases: list[tuple[str, ...]] = []
    tones: list[tuple[int, ...]] = []
    lines: list[tuple[int, ...]] = []
    weights: list[float | None] = []

    def visit(position: int) -> None:
        if len(results) >= limit:
            return
        if position == len(reading_lists):
            pronunciation_weight: float | None = None
            for weight in weights:
                if weight is None:
                    continue
                pronunciation_weight = weight if pronunciation_weight is None else pronunciation_weight * weight
            results.append(
                AnnotatedReading(
                    tuple(base for part in bases for base in part),
                    tuple(tone for part in tones for tone in part),
                    False,
                    tuple(line for part in lines for line in part),
                    pronunciation_weight,
                )
            )
            return
        for reading in reading_lists[position]:
            if len(results) >= limit:
                return
            bases.append(reading.base_syllables)
            tones.append(reading.tones)
            lines.append((reading.source_line,))
            weights.append(reading.pronunciation_weight)
            visit(position + 1)
            bases.pop()
            tones.pop()
            lines.pop()
            weights.pop()

    visit(0)
    return results


def deduplicate_readings(readings: list[AnnotatedReading]) -> list[AnnotatedReading]:
    unique: list[AnnotatedReading] = []
    seen: set[tuple[tuple[str, ...], tuple[int, ...]]] = set()
    for reading in readings:
        key = (reading.base_syllables, reading.tones)
        if key in seen:
            continue
        seen.add(key)
        unique.append(reading)
    return unique


def annotate_essay(entries: list[EssayEntry], index: TerraIndex) -> EssayAnnotation:
    annotated: list[AnnotatedEssayEntry] = []
    explicit_entries = 0
    composed_entries = 0
    unannotated_entries = 0
    oversized_entries = 0
    truncated_entries = 0
    generated_pronunciations = 0
    excluded_zero_weight_readings = 0
    unannotated_examples: list[dict] = []
    truncated_examples: list[dict] = []
    oversized_examples: list[dict] = []

    for entry in entries:
        if len(entry.text) > MAXIMUM_ESSAY_WORD_LENGTH:
            oversized_entries += 1
            if len(oversized_examples) < REPORT_EXAMPLE_LIMIT:
                oversized_examples.append(
                    {"text": entry.text, "essaySourceLine": entry.source_line, "length": len(entry.text)}
                )
            continue

        explicit = index.words.get(entry.text)
        if explicit is not None:
            readings = [
                AnnotatedReading(
                    reading.base_syllables,
                    reading.tones,
                    True,
                    (reading.source_line,),
                    reading.pronunciation_weight,
                )
                for reading in explicit
            ]
            truncated = len(readings) > MAXIMUM_PRONUNCIATIONS_PER_WORD
            readings = deduplicate_readings(readings)[:MAXIMUM_PRONUNCIATIONS_PER_WORD]
            explicit_entries += 1
        else:
            missing = "".join(character for character in entry.text if character not in index.characters)
            if missing:
                unannotated_entries += 1
                if len(unannotated_examples) < REPORT_EXAMPLE_LIMIT:
                    unannotated_examples.append(
                        {
                            "text": entry.text,
                            "essaySourceLine": entry.source_line,
                            "missingCharacters": missing,
                        }
                    )
                continue
            reading_lists = []
            for character in entry.text:
                character_readings = index.characters[character]
                composed_readings = readings_for_composition(character_readings)
                excluded_zero_weight_readings += len(character_readings) - len(composed_readings)
                reading_lists.append(composed_readings)
            combinations = math.prod(len(readings) for readings in reading_lists)
            truncated = combinations > MAXIMUM_PRONUNCIATIONS_PER_WORD
            readings = compose_readings(reading_lists, MAXIMUM_PRONUNCIATIONS_PER_WORD + 1)
            readings = deduplicate_readings(readings)[:MAXIMUM_PRONUNCIATIONS_PER_WORD]
            composed_entries += 1

        if truncated:
            truncated_entries += 1
            if len(truncated_examples) < REPORT_EXAMPLE_LIMIT:
                truncated_examples.append(
                    {
                        "text": entry.text,
                        "essaySourceLine": entry.source_line,
                        "retained": len(readings),
                        "limit": MAXIMUM_PRONUNCIATIONS_PER_WORD,
                    }
                )
        generated_pronunciations += len(readings)
        annotated.append(
            AnnotatedEssayEntry(entry.text, entry.frequency, entry.source_line, tuple(readings), truncated)
        )

    return EssayAnnotation(
        entries=tuple(annotated),
        annotated_entries=explicit_entries + composed_entries,
        explicit_entries=explicit_entries,
        composed_entries=composed_entries,
        unannotated_entries=unannotated_entries,
        oversized_entries=oversized_entries,
        truncated_entries=truncated_entries,
        generated_pronunciations=generated_pronunciations,
        excluded_zero_weight_readings=excluded_zero_weight_readings,
        unannotated_examples=tuple(unannotated_examples),
        truncated_examples=tuple(truncated_examples),
        oversized_examples=tuple(oversized_examples),
    )


def normalize_frequency(frequency: int, maximum_frequency: int) -> float:
    if frequency <= 0 or maximum_frequency <= 0:
        return 0.0
    return min(1.0, math.log1p(frequency) / math.log1p(maximum_frequency))


def merge_rows(
    terra_rows: list[CompiledEntry],
    annotated_entries: tuple[AnnotatedEssayEntry, ...],
    maximum_frequency: int,
    priors: dict[ReadingPriorKey, float] | None = None,
) -> tuple[list[MergedEntry], int, int]:
    rows: dict[tuple[str, str, str], MergedEntry] = {}
    for row in terra_rows:
        entry = MergedEntry(
            row.text,
            row.base_syllables,
            row.tones,
            None,
            terra_pronunciation_weight(row.text, row.source_weight, row.base_syllables, row.tones, priors),
            SOURCE_KIND_TERRA,
            row.source_line,
            (row.source_line,),
            None,
            None,
        )
        rows[(entry.text, entry.base_key, entry.tone_key)] = entry
    merged_count = 0
    duplicate_pronunciations = 0
    for entry in annotated_entries:
        weight = normalize_frequency(entry.frequency, maximum_frequency)
        for reading in entry.readings:
            base_key = SEPARATOR.join(reading.base_syllables)
            tone_key = "".join(str(tone) for tone in reading.tones)
            key = (entry.text, base_key, tone_key)
            existing = rows.get(key)
            if existing is None:
                rows[key] = MergedEntry(
                    entry.text,
                    reading.base_syllables,
                    reading.tones,
                    weight,
                    reading.pronunciation_weight,
                    SOURCE_KIND_ESSAY,
                    None,
                    reading.terra_lines,
                    entry.source_line,
                    entry.frequency,
                )
                continue
            pronunciation_weight = (
                existing.pronunciation_weight
                if existing.pronunciation_weight is not None
                else reading.pronunciation_weight
            )
            if existing.essay_source_line is not None:
                duplicate_pronunciations += 1
                if entry.frequency <= (existing.raw_frequency or 0):
                    continue
                rows[key] = replace(
                    existing,
                    source_weight=weight,
                    pronunciation_weight=pronunciation_weight,
                    essay_source_line=entry.source_line,
                    raw_frequency=entry.frequency,
                )
                continue
            merged_count += 1
            rows[key] = replace(
                existing,
                source_weight=weight,
                pronunciation_weight=pronunciation_weight,
                source_kind=SOURCE_KIND_MERGED,
                essay_source_line=entry.source_line,
                raw_frequency=entry.frequency,
            )
    ordered = sorted(
        rows.values(),
        key=lambda entry: (
            entry.base_key,
            entry.tone_key,
            entry.text,
            entry.source_kind,
            entry.terra_source_line or 0,
            entry.essay_source_line or 0,
        ),
    )
    return ordered, merged_count, duplicate_pronunciations


@dataclass(frozen=True)
class ReadingPropagation:
    rows: list[MergedEntry]
    source_words: int
    added_readings: int
    capped_entries: int
    examples: tuple[dict, ...]


@dataclass(frozen=True)
class TaiwanPhraseIntegration:
    rows: list[MergedEntry]
    pairs: int
    weighted_words: int
    added_words: int
    added_readings: int
    unweighted_sources: int
    untypable_words: int
    examples: tuple[dict, ...]
    untypable_examples: tuple[dict, ...]


def parse_taiwan_phrases(path: Path) -> list[tuple[str, str]]:
    """(OpenCC Standard Traditional word, Taiwan word) pairs from TWPhrases."""
    try:
        dictionary = parse_opencc_dictionary_text(path.read_text(encoding="utf-8"), str(path))
    except OpenCCFormatError as error:
        raise CompileFailure(str(error)) from error
    return [
        (source, taiwan)
        for source, values in dictionary.entries.items()
        for taiwan in values
        if taiwan != source
    ]


def integrate_taiwan_phrases(
    rows: list[MergedEntry],
    index: TerraIndex,
    pairs: list[tuple[str, str]],
) -> TaiwanPhraseIntegration:
    """Give Taiwan vocabulary the frequency of the word it replaces.

    Essay counts mostly mainland usage, so 軟體 (0.44) trails 軟件 (0.71)
    although Taiwan writers use 軟體. For each OpenCC TWPhrases pair the Taiwan
    word gets ``taiwan_source_weight = max(its own weight, the source word's)``,
    which the keyboard uses in place of ``source_weight`` only when showing
    Taiwan forms. The two words are read differently (ㄖㄨㄢˇ ㄊㄧˇ, ㄖㄨㄢˇ
    ㄐㄧㄢˋ), so each keeps its own pronunciation. Taiwan words missing from the
    lexicon are added with readings composed from Terra's characters, like
    composed Essay entries; their ``source_weight`` is 0 so they stay last in
    other variants. Words with characters Terra cannot read (C肝) are skipped.
    TWPhrases values use OpenCC Standard Traditional characters, the lexicon's
    own form, so no conversion is needed.
    """
    rows = list(rows)
    positions: dict[str, list[int]] = {}
    for position, row in enumerate(rows):
        positions.setdefault(row.text, []).append(position)

    def weight_of(text: str) -> float | None:
        weights = [
            rows[position].source_weight
            for position in positions.get(text, ())
            if rows[position].source_weight is not None
        ]
        return max(weights, default=None)

    targets: dict[str, tuple[float | None, str]] = {}
    for source, taiwan in pairs:
        weight = weight_of(source)
        previous = targets.get(taiwan)
        if previous is None or (weight is not None and (previous[0] is None or weight > previous[0])):
            targets[taiwan] = (weight, source)

    added: list[MergedEntry] = []
    weighted_words = 0
    added_words = 0
    unweighted_sources = 0
    untypable_words = 0
    examples: list[dict] = []
    untypable_examples: list[dict] = []
    for taiwan, (weight, source) in sorted(targets.items()):
        if weight is None:
            unweighted_sources += 1
        existing = positions.get(taiwan)
        if existing:
            own = weight_of(taiwan)
            if weight is None or (own is not None and own >= weight):
                continue
            for position in existing:
                rows[position] = replace(rows[position], taiwan_source_weight=weight)
            weighted_words += 1
            if len(examples) < REPORT_EXAMPLE_LIMIT:
                examples.append(
                    {"text": taiwan, "source": source, "weight": own, "taiwanWeight": weight}
                )
            continue
        if len(taiwan) > MAXIMUM_ESSAY_WORD_LENGTH or any(
            character not in index.characters for character in taiwan
        ):
            untypable_words += 1
            if len(untypable_examples) < REPORT_EXAMPLE_LIMIT:
                untypable_examples.append({"text": taiwan, "source": source})
            continue
        reading_lists = [readings_for_composition(index.characters[character]) for character in taiwan]
        readings = deduplicate_readings(
            compose_readings(reading_lists, MAXIMUM_PRONUNCIATIONS_PER_WORD + 1)
        )[:MAXIMUM_PRONUNCIATIONS_PER_WORD]
        for reading in readings:
            added.append(
                MergedEntry(
                    taiwan,
                    reading.base_syllables,
                    reading.tones,
                    0.0,
                    reading.pronunciation_weight,
                    SOURCE_KIND_OPENCC_TAIWAN,
                    None,
                    reading.terra_lines,
                    None,
                    None,
                    taiwan_source_weight=weight,
                )
            )
        added_words += 1
        if len(examples) < REPORT_EXAMPLE_LIMIT:
            examples.append({"text": taiwan, "source": source, "weight": None, "taiwanWeight": weight})
    return TaiwanPhraseIntegration(
        rows=rows + added,
        pairs=len(pairs),
        weighted_words=weighted_words,
        added_words=added_words,
        added_readings=len(added),
        unweighted_sources=unweighted_sources,
        untypable_words=untypable_words,
        examples=tuple(examples),
        untypable_examples=tuple(untypable_examples),
    )


def propagate_word_readings(rows: list[MergedEntry], index: TerraIndex) -> ReadingPropagation:
    """Spread Terra's alternative readings of short words to entries containing them.

    Terra often records a reading only on the short word: 什麼 has both
    ``she2 me5`` (Taiwan) and ``shen2 me5``, but 爲什麼 and 沒什麼 only list
    ``shen2``, and composed Essay entries skip the 0% ``she2`` of 什. For every
    entry whose reading of an embedded word matches one of that word's Terra
    readings, the other readings are added with the entry's own weights, so
    the longer word can be typed with either reading. Entries Terra does not
    list (composed character by character) take the embedded word's readings
    whatever their own reading of it is.
    """
    alternatives: dict[str, tuple[TerraReading, ...]] = {}
    for text, readings in index.words.items():
        if not 2 <= len(text) <= MAXIMUM_PROPAGATED_WORD_LENGTH:
            continue
        distinct = deduplicate_terra_readings(readings)
        if len(distinct) >= 2:
            alternatives[text] = distinct

    readings_by_text: dict[str, set[tuple[tuple[str, ...], tuple[int, ...]]]] = {}
    for row in rows:
        readings_by_text.setdefault(row.text, set()).add((row.base_syllables, row.tones))

    added: list[MergedEntry] = []
    capped = 0
    capped_texts: set[str] = set()
    examples: list[dict] = []
    for row in rows:
        spans = embedded_alternative_spans(row, alternatives, composed=row.text not in index.words)
        if not spans:
            continue
        existing = readings_by_text[row.text]
        for bases, tones, lines in expand_spans(row, spans):
            key = (bases, tones)
            if key in existing:
                continue
            if len(existing) >= MAXIMUM_PRONUNCIATIONS_WITH_PROPAGATION:
                if row.text not in capped_texts:
                    capped_texts.add(row.text)
                    capped += 1
                break
            existing.add(key)
            added.append(
                replace(
                    row,
                    base_syllables=bases,
                    tones=tones,
                    terra_source_lines=tuple(sorted(set(row.terra_source_lines) | set(lines))),
                )
            )
            if len(examples) < REPORT_EXAMPLE_LIMIT:
                examples.append(
                    {
                        "text": row.text,
                        "from": row.base_key.replace(SEPARATOR, " ") + " " + row.tone_key,
                        "added": SEPARATOR.join(bases).replace(SEPARATOR, " ")
                        + " "
                        + "".join(str(tone) for tone in tones),
                    }
                )
    ordered = sorted(
        rows + added,
        key=lambda entry: (
            entry.base_key,
            entry.tone_key,
            entry.text,
            entry.source_kind,
            entry.terra_source_line or 0,
            entry.essay_source_line or 0,
        ),
    )
    return ReadingPropagation(
        rows=ordered,
        source_words=len(alternatives),
        added_readings=len(added),
        capped_entries=capped,
        examples=tuple(examples),
    )


def deduplicate_terra_readings(readings: tuple[TerraReading, ...]) -> tuple[TerraReading, ...]:
    seen: set[tuple[tuple[str, ...], tuple[int, ...]]] = set()
    unique: list[TerraReading] = []
    for reading in readings:
        key = (reading.base_syllables, reading.tones)
        if key not in seen:
            seen.add(key)
            unique.append(reading)
    return tuple(unique)


def embedded_alternative_spans(
    row: MergedEntry, alternatives: dict[str, tuple[TerraReading, ...]], composed: bool = False
) -> list[tuple[int, tuple[TerraReading, ...]]]:
    """Non-overlapping embedded words (longest first, left to right) whose
    reading in ``row`` is one of their Terra readings, or any embedded word
    when the row's reading was ``composed`` from single characters."""
    text = row.text
    if len(text) != row.syllable_count:
        return []
    spans: list[tuple[int, tuple[TerraReading, ...]]] = []
    position = 0
    while position < len(text):
        matched = 0
        longest = min(MAXIMUM_PROPAGATED_WORD_LENGTH, len(text) - position)
        for length in range(longest, 1, -1):
            if length == len(text):
                continue
            readings = alternatives.get(text[position:position + length])
            if readings is None:
                continue
            current = (
                row.base_syllables[position:position + length],
                row.tones[position:position + length],
            )
            if composed or any((reading.base_syllables, reading.tones) == current for reading in readings):
                spans.append((position, readings))
                matched = length
                break
        position += matched or 1
    return spans


def expand_spans(row: MergedEntry, spans: list[tuple[int, tuple[TerraReading, ...]]]):
    """Every combination of span readings, original combination excluded by the caller."""
    def visit(index: int, bases: list[str], tones: list[int], lines: tuple[int, ...]):
        if index == len(spans):
            yield tuple(bases), tuple(tones), lines
            return
        position, readings = spans[index]
        for reading in readings:
            length = len(reading.base_syllables)
            next_bases = bases[:position] + list(reading.base_syllables) + bases[position + length:]
            next_tones = tones[:position] + list(reading.tones) + tones[position + length:]
            yield from visit(index + 1, next_bases, next_tones, lines + (reading.source_line,))

    yield from visit(0, list(row.base_syllables), list(row.tones), ())


def load_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise CompileFailure(f"{path}: invalid JSON manifest ({error})") from error
    if not isinstance(manifest, dict):
        raise CompileFailure(f"{path}: manifest must be a JSON object")
    commit = manifest.get("commit")
    if not isinstance(commit, str) or COMMIT_PATTERN.fullmatch(commit) is None:
        raise CompileFailure(f"{path}: commit must be a full 40-character lowercase hex string")
    return manifest


def verify_manifest_contract(
    manifest: dict,
    manifest_path: Path,
    source_path: Path,
    source_path_key: str,
) -> None:
    repository = manifest.get("repository")
    if not isinstance(repository, str) or not repository:
        raise CompileFailure(f"{manifest_path}: missing repository")
    declared_path = manifest.get(source_path_key)
    if declared_path != Path(source_path).name:
        raise CompileFailure(
            f"{manifest_path}: {source_path_key} is {declared_path!r}, "
            f"expected {Path(source_path).name!r}"
        )
    license_path = manifest.get("licensePath")
    if not isinstance(license_path, str) or not license_path:
        raise CompileFailure(f"{manifest_path}: missing licensePath")
    license_sha256 = manifest.get("licenseSha256")
    if not isinstance(license_sha256, str) or SHA256_PATTERN.fullmatch(license_sha256) is None:
        raise CompileFailure(f"{manifest_path}: licenseSha256 must be a lowercase SHA-256")


def verify_essay_format(manifest: dict, manifest_path: Path) -> None:
    format_version = manifest.get("formatVersion")
    if format_version != ESSAY_FORMAT_VERSION:
        raise CompileFailure(
            f"{manifest_path}: unsupported essay formatVersion {format_version!r}, "
            f"expected {ESSAY_FORMAT_VERSION}"
        )


def verify_source_hash(manifest: dict, manifest_path: Path, source_path: Path) -> str:
    expected = manifest.get("sha256")
    if not isinstance(expected, str) or SHA256_PATTERN.fullmatch(expected) is None:
        raise CompileFailure(f"{manifest_path}: sha256 must be a lowercase SHA-256")
    source_bytes = Path(source_path).read_bytes()
    actual = sha256_bytes(source_bytes)
    if expected != actual:
        raise CompileFailure(
            f"{manifest_path}: sha256 mismatch: manifest has {expected!r}, source is {actual!r}"
        )
    return actual


def verify_license_hash(manifest: dict, manifest_path: Path, source_path: Path) -> None:
    expected = manifest.get("licenseSha256")
    license_path = Path(source_path).parent / manifest["licensePath"]
    if not license_path.exists():
        raise CompileFailure(f"{manifest_path}: license not found: {license_path}")
    actual = sha256_bytes(license_path.read_bytes())
    if expected != actual:
        raise CompileFailure(
            f"{manifest_path}: license sha256 mismatch: manifest has {expected!r}, license is {actual!r}"
        )


def make_metadata(
    terra_manifest: dict,
    terra_header: dict[str, str],
    terra_sha256: str,
    essay_manifest: dict,
    essay_sha256: str,
    essay_entry_count: int,
    essay_annotated_entry_count: int,
    essay_frequency_max: int,
    entry_count: int,
    max_syllable_count: int,
) -> dict[str, str]:
    metadata = {
        "schema_version": str(SCHEMA_VERSION),
        "terra_source_repository": str(terra_manifest.get("repository", "")),
        "terra_source_commit": str(terra_manifest.get("commit", "")),
        "terra_source_sha256": terra_sha256,
        "essay_source_repository": str(essay_manifest.get("repository", "")),
        "essay_source_commit": str(essay_manifest.get("commit", "")),
        "essay_source_sha256": essay_sha256,
        "dictionary_name": terra_header.get("name", ""),
        "dictionary_version": terra_header.get("version", ""),
        "compiler_version": COMPILER_VERSION,
        "entry_count": str(entry_count),
        "max_syllable_count": str(max_syllable_count),
        "essay_entry_count": str(essay_entry_count),
        "essay_annotated_entry_count": str(essay_annotated_entry_count),
        "essay_frequency_max": str(essay_frequency_max),
        "weight_normalization": WEIGHT_NORMALIZATION,
    }
    missing = [key for key in REQUIRED_METADATA_KEYS if not metadata.get(key)]
    if missing:
        raise CompileFailure(f"missing metadata: {', '.join(missing)}")
    return metadata


def validate_initial_keys(rows: list[MergedEntry]) -> int:
    for row in rows:
        if any(not base for base in row.base_syllables):
            raise CompileFailure(f"entry {row.text!r} has an empty base syllable")
        segments = row.initial_key.split(SEPARATOR)
        if len(segments) != row.syllable_count or any(len(segment) != 1 for segment in segments):
            raise CompileFailure(
                f"entry {row.text!r} initial_key {row.initial_key!r} does not match "
                f"{row.syllable_count} syllable(s)"
            )
    return len(rows)


def write_database(
    path: Path,
    rows: list[MergedEntry],
    inventory: list[str],
    metadata: dict[str, str],
) -> bytes:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    connection = sqlite3.connect(path, isolation_level=None)
    try:
        connection.execute("PRAGMA page_size = 4096")
        connection.execute("PRAGMA journal_mode = DELETE")
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.executescript(SCHEMA)
        connection.execute("BEGIN")
        connection.executemany(
            "INSERT INTO metadata (key, value) VALUES (?, ?)",
            sorted(metadata.items()),
        )
        connection.executemany(
            "INSERT INTO syllable_inventory (base) VALUES (?)",
            [(base,) for base in inventory],
        )
        connection.executemany(
            "INSERT INTO pronunciation ("
            "text, syllable_count, base_key, tone_key, initial_key, source_weight, pronunciation_weight,"
            " source_kind, terra_source_line, terra_source_lines, essay_source_line, raw_frequency,"
            " taiwan_source_weight"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    row.text,
                    row.syllable_count,
                    row.base_key,
                    row.tone_key,
                    row.initial_key,
                    row.source_weight,
                    row.pronunciation_weight,
                    row.source_kind,
                    row.terra_source_line,
                    json.dumps(row.terra_source_lines, separators=(",", ":")),
                    row.essay_source_line,
                    row.raw_frequency,
                    row.taiwan_source_weight,
                )
                for row in rows
            ],
        )
        connection.execute("COMMIT")
        connection.execute("VACUUM")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if integrity is None or integrity[0] != "ok":
            raise CompileFailure(f"integrity_check failed: {integrity!r}")
    finally:
        connection.close()
    for suffix in ("-journal", "-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    return path.read_bytes()


def build_database(
    terra_source_path: Path,
    terra_manifest_path: Path,
    essay_source_path: Path,
    essay_manifest_path: Path,
    output_path: Path,
    report_path: Path,
    opencc_source_directory: Path | None = None,
    opencc_manifest_path: Path | None = None,
) -> BuildOutput:
    terra_manifest = load_manifest(terra_manifest_path)
    taiwan_phrases: list[tuple[str, str]] | None = None
    taiwan_phrases_sha256 = ""
    opencc_commit = ""
    if (opencc_source_directory is None) != (opencc_manifest_path is None):
        raise CompileFailure("OpenCC source directory and manifest must be given together")
    if opencc_source_directory is not None and opencc_manifest_path is not None:
        opencc_manifest = load_manifest(opencc_manifest_path)
        opencc_commit = str(opencc_manifest.get("commit", ""))
        record = (opencc_manifest.get("files") or {}).get(TAIWAN_PHRASES_FILE)
        if not validate_commit(opencc_commit) or not isinstance(record, dict):
            raise CompileFailure(f"{opencc_manifest_path}: missing commit or {TAIWAN_PHRASES_FILE}")
        phrases_path = opencc_source_directory / TAIWAN_PHRASES_FILE
        taiwan_phrases_sha256 = sha256_bytes(phrases_path.read_bytes())
        if taiwan_phrases_sha256 != record.get("sha256"):
            raise CompileFailure(
                f"{phrases_path}: sha256 {taiwan_phrases_sha256} does not match manifest {record.get('sha256')}"
            )
        taiwan_phrases = parse_taiwan_phrases(phrases_path)
    essay_manifest = load_manifest(essay_manifest_path)
    verify_manifest_contract(
        terra_manifest, terra_manifest_path, terra_source_path, "dictionaryPath"
    )
    verify_manifest_contract(
        essay_manifest, essay_manifest_path, essay_source_path, "essayPath"
    )
    verify_essay_format(essay_manifest, essay_manifest_path)
    terra_sha256 = verify_source_hash(terra_manifest, terra_manifest_path, terra_source_path)
    essay_sha256 = verify_source_hash(essay_manifest, essay_manifest_path, essay_source_path)
    verify_license_hash(terra_manifest, terra_manifest_path, terra_source_path)
    verify_license_hash(essay_manifest, essay_manifest_path, essay_source_path)

    parsed_terra = parse_dictionary(terra_source_path)
    parsed_essay = parse_essay(essay_source_path)
    errors = list(parsed_terra.errors) + list(parsed_essay.errors)
    terra_rows: list[CompiledEntry] = []
    terra_conflicts: list[dict] = []
    terra_duplicates = 0
    distinct_pinyin: list[str] = []
    if not errors:
        terra_rows, errors, terra_conflicts, terra_duplicates, distinct_pinyin = compile_terra_entries(
            parsed_terra.entries, terra_source_path
        )
    if errors:
        raise CompileFailure("\n".join(errors))

    if terra_manifest.get("dictionaryVersion") != parsed_terra.header.get("version"):
        raise CompileFailure(
            f"{terra_manifest_path}: dictionaryVersion does not match the Terra header"
        )
    essay_entry_count = len(parsed_essay.entries)
    essay_frequency_max = max((entry.frequency for entry in parsed_essay.entries), default=0)
    if essay_manifest.get("entryCount") != essay_entry_count:
        raise CompileFailure(
            f"{essay_manifest_path}: entryCount is {essay_manifest.get('entryCount')!r}, "
            f"expected {essay_entry_count}"
        )
    if essay_manifest.get("frequencyMax") != essay_frequency_max:
        raise CompileFailure(
            f"{essay_manifest_path}: frequencyMax is {essay_manifest.get('frequencyMax')!r}, "
            f"expected {essay_frequency_max}"
        )

    merged_essay, essay_duplicates = merge_essay_entries(parsed_essay.entries)
    maximum_frequency = max((entry.frequency for entry in merged_essay), default=0)
    reading_priors = estimate_reading_priors(build_terra_index(terra_rows), merged_essay)
    index = build_terra_index(terra_rows, reading_priors.weights)
    annotation = annotate_essay(merged_essay, index)
    rows, merged_count, duplicate_pronunciations = merge_rows(
        terra_rows, annotation.entries, maximum_frequency, reading_priors.weights
    )
    taiwan = None
    if taiwan_phrases is not None:
        taiwan = integrate_taiwan_phrases(rows, index, taiwan_phrases)
        rows = taiwan.rows
    propagation = propagate_word_readings(rows, index)
    rows = propagation.rows

    inventory = sorted({base for row in rows for base in row.base_syllables})
    max_syllables = max((row.syllable_count for row in rows), default=0)
    checked_initial_keys = validate_initial_keys(rows)
    metadata = make_metadata(
        terra_manifest,
        parsed_terra.header,
        terra_sha256,
        essay_manifest,
        essay_sha256,
        len(parsed_essay.entries),
        annotation.annotated_entries,
        maximum_frequency,
        len(rows),
        max_syllables,
    )
    if taiwan is not None:
        metadata["opencc_source_commit"] = opencc_commit
        metadata["taiwan_phrases_sha256"] = taiwan_phrases_sha256
    database_bytes = write_database(output_path, rows, inventory, metadata)
    if len(database_bytes) > MAXIMUM_DATABASE_BYTES:
        Path(output_path).unlink(missing_ok=True)
        raise CompileFailure(
            f"database size {len(database_bytes)} bytes exceeds limit {MAXIMUM_DATABASE_BYTES} bytes"
        )

    report = {
        "sourceEntries": len(parsed_terra.entries),
        "compiledEntries": len(rows),
        "terraCompiledEntries": len(terra_rows),
        "duplicateEntries": terra_duplicates,
        "duplicateEssayEntries": essay_duplicates,
        "duplicatePronunciations": duplicate_pronunciations,
        "mergedTerraEssayEntries": merged_count,
        "essayEntries": len(parsed_essay.entries),
        "essayMergedEntries": len(merged_essay),
        "essayAnnotatedEntries": annotation.annotated_entries,
        "essayExplicitEntries": annotation.explicit_entries,
        "essayComposedEntries": annotation.composed_entries,
        "essayUnannotatedEntries": annotation.unannotated_entries,
        "essayOversizedEntries": annotation.oversized_entries,
        "essayTruncatedEntries": annotation.truncated_entries,
        "generatedPronunciations": annotation.generated_pronunciations,
        "excludedZeroWeightReadings": annotation.excluded_zero_weight_readings,
        "readingPriors": {
            "adjustedCharacters": reading_priors.adjusted_characters,
            "examples": list(reading_priors.examples),
        },
        "taiwanPhrases": None
        if taiwan is None
        else {
            "pairs": taiwan.pairs,
            "weightedWords": taiwan.weighted_words,
            "addedWords": taiwan.added_words,
            "addedReadings": taiwan.added_readings,
            "unweightedSources": taiwan.unweighted_sources,
            "untypableWords": taiwan.untypable_words,
            "examples": list(taiwan.examples),
            "untypableExamples": list(taiwan.untypable_examples),
        },
        "taiwanWeightedEntries": sum(1 for row in rows if row.taiwan_source_weight is not None),
        "propagatedReadings": {
            "sourceWords": propagation.source_words,
            "addedReadings": propagation.added_readings,
            "cappedEntries": propagation.capped_entries,
            "examples": list(propagation.examples),
        },
        "distinctWords": len({row.text for row in rows}),
        "distinctPinyinSyllables": len(distinct_pinyin),
        "distinctZhuyinSyllables": len(inventory),
        "distinctInitialKeys": len({row.initial_key for row in rows}),
        "initialKeyIntegrity": {
            "checkedEntries": checked_initial_keys,
            "syllableCountMismatches": 0,
        },
        "maxSyllableCount": max_syllables,
        "weightedEntries": sum(1 for row in rows if row.source_weight is not None),
        "pronunciationWeightedEntries": sum(1 for row in rows if row.pronunciation_weight is not None),
        "essayWeightedEntries": sum(1 for row in rows if row.raw_frequency is not None),
        "normalization": {
            "formula": WEIGHT_NORMALIZATION,
            "maximumFrequency": maximum_frequency,
        },
        "database": {
            "bytes": len(database_bytes),
            "limitBytes": MAXIMUM_DATABASE_BYTES,
        },
        "errors": [],
        "duplicateWeightConflicts": terra_conflicts,
        "unannotatedExamples": list(annotation.unannotated_examples),
        "truncatedExamples": list(annotation.truncated_examples),
        "oversizedExamples": list(annotation.oversized_examples),
        "sources": {
            "terra": {
                "path": str(terra_manifest["dictionaryPath"]),
                "sha256": terra_sha256,
                "repository": str(terra_manifest.get("repository", "")),
                "commit": str(terra_manifest.get("commit", "")),
                "dictionaryName": parsed_terra.header.get("name", ""),
                "dictionaryVersion": parsed_terra.header.get("version", ""),
                "sort": parsed_terra.header.get("sort", ""),
                "usePresetVocabulary": parsed_terra.header.get("use_preset_vocabulary", ""),
            },
            "essay": {
                "path": str(essay_manifest["essayPath"]),
                "sha256": essay_sha256,
                "repository": str(essay_manifest.get("repository", "")),
                "commit": str(essay_manifest.get("commit", "")),
                "formatVersion": str(essay_manifest.get("formatVersion", "")),
                "entryCount": len(parsed_essay.entries),
                "frequencyMax": maximum_frequency,
            },
        },
        "compilerVersion": COMPILER_VERSION,
        "schemaVersion": SCHEMA_VERSION,
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return BuildOutput(
        compiled_entries=len(rows),
        duplicate_entries=terra_duplicates,
        merged_terra_essay_entries=merged_count,
        essay_entries=len(parsed_essay.entries),
        essay_annotated_entries=annotation.annotated_entries,
        essay_unannotated_entries=annotation.unannotated_entries,
        essay_truncated_entries=annotation.truncated_entries,
        database_bytes=len(database_bytes),
    )


@dataclass(frozen=True)
class GrammarBuildOutput:
    key_count: int
    dropped_keys: int
    grammar_bytes: int


def parse_grammar_text(path: Path) -> list[tuple[str, int]]:
    """Parse `key<TAB>value` lines, where value is an octagram-scaled integer."""
    entries = []
    errors = []
    for line_number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or INTEGER_PATTERN.fullmatch(fields[1]) is None:
            errors.append(f"{path}:{line_number}: expected key<TAB>integer")
            continue
        entries.append((fields[0], int(fields[1])))
    if errors:
        raise CompileFailure("\n".join(errors))
    return entries


def build_grammar(
    output_path: Path,
    report_path: Path,
    source_path: Path | None = None,
    manifest_path: Path | None = None,
    text_source_path: Path | None = None,
    block_size: int = FZGRAM_DEFAULT_BLOCK_SIZE,
) -> GrammarBuildOutput:
    if (source_path is None) == (text_source_path is None):
        raise CompileFailure("build-grammar: pass exactly one of --source or --text-source")
    if source_path is not None:
        if manifest_path is None:
            raise CompileFailure("build-grammar: --source requires --manifest")
        manifest = load_manifest(manifest_path)
        verify_manifest_contract(manifest, manifest_path, source_path, "gramPath")
        if manifest.get("formatVersion") != OCTAGRAM_FORMAT_VERSION:
            raise CompileFailure(
                f"{manifest_path}: unsupported octagram formatVersion "
                f"{manifest.get('formatVersion')!r}, expected {OCTAGRAM_FORMAT_VERSION}"
            )
        source_sha256 = verify_source_hash(manifest, manifest_path, source_path)
        verify_license_hash(manifest, manifest_path, source_path)
        try:
            entries = read_gram(source_path)
        except GramFormatError as error:
            raise CompileFailure(f"{source_path}: {error}") from error
        source = {
            "path": str(manifest["gramPath"]),
            "sha256": source_sha256,
            "repository": str(manifest.get("repository", "")),
            "commit": str(manifest.get("commit", "")),
            "formatVersion": str(manifest.get("formatVersion", "")),
        }
    else:
        entries = parse_grammar_text(text_source_path)
        source = {
            "path": Path(text_source_path).name,
            "sha256": sha256_bytes(Path(text_source_path).read_bytes()),
        }

    # Octagram only queries context+word keys and `word$`; `$word` keys are
    # sentence-start statistics it never reads. Entries stream through so the
    # multi-million-key source is never held as Python tuples.
    stats = {"kept": 0, "dropped": 0, "minimum": None, "maximum": None}
    length_histogram: dict[str, int] = {}
    samples: list[tuple[str, int]] = []

    def kept_entries():
        for key, value in entries:
            if key.startswith(SENTENCE_BOUNDARY) or len(key) > MAXIMUM_GRAMMAR_KEY_CHARACTERS:
                stats["dropped"] += 1
                continue
            if stats["kept"] % 1000 == 0:
                samples.append((key, value))
            stats["kept"] += 1
            length = str(len(key))
            length_histogram[length] = length_histogram.get(length, 0) + 1
            if stats["minimum"] is None or value < stats["minimum"]:
                stats["minimum"] = value
            if stats["maximum"] is None or value > stats["maximum"]:
                stats["maximum"] = value
            yield key, value

    try:
        grammar_bytes = write_fzgram(kept_entries(), GRAMMAR_COMPILER_VERSION, block_size)
    except GramFormatError as error:
        raise CompileFailure(f"build-grammar: {error}") from error
    if len(grammar_bytes) > MAXIMUM_GRAMMAR_BYTES:
        raise CompileFailure(
            f"build-grammar: output is {len(grammar_bytes)} bytes, "
            f"limit is {MAXIMUM_GRAMMAR_BYTES}"
        )
    reader = FZGram(grammar_bytes)
    for key, value in samples:
        decoded = reader.value(key)
        if decoded is None or (value - decoded) >> reader.value_shift:
            raise CompileFailure(f"build-grammar: round-trip failed for {key!r}")

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(grammar_bytes)

    report = {
        "keyCount": stats["kept"],
        "droppedKeys": stats["dropped"],
        "keyLengthHistogram": dict(sorted(length_histogram.items(), key=lambda item: int(item[0]))),
        "valueRange": {"minimum": stats["minimum"], "maximum": stats["maximum"]},
        "format": {
            "formatVersion": 1,
            "blockSize": reader.block_size,
            "valueBase": reader.value_base,
            "valueShift": reader.value_shift,
        },
        "output": {
            "bytes": len(grammar_bytes),
            "sha256": sha256_bytes(grammar_bytes),
            "limitBytes": MAXIMUM_GRAMMAR_BYTES,
        },
        "source": source,
        "compilerVersion": GRAMMAR_COMPILER_VERSION,
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return GrammarBuildOutput(
        key_count=stats["kept"], dropped_keys=stats["dropped"], grammar_bytes=len(grammar_bytes)
    )


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def validate_commit(commit: str) -> bool:
    return COMMIT_PATTERN.fullmatch(commit) is not None


def command_fetch_terra(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-terra: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{TERRA_RAW_BASE_URL}/{args.commit}/{name}")
        for name in (TERRA_DICTIONARY_PATH, "LICENSE")
    }
    try:
        header, _ = read_header(files[TERRA_DICTIONARY_PATH].decode("utf-8"))
    except CompileFailure as failure:
        print(f"fetch-terra: invalid dictionary: {failure}", file=sys.stderr)
        return 1
    manifest = {
        "repository": TERRA_REPOSITORY,
        "commit": args.commit,
        "dictionaryPath": TERRA_DICTIONARY_PATH,
        "sha256": sha256_bytes(files[TERRA_DICTIONARY_PATH]),
        "licensePath": "LICENSE",
        "licenseSha256": sha256_bytes(files["LICENSE"]),
        "dictionaryVersion": header.get("version", ""),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch-terra: wrote {destination / TERRA_DICTIONARY_PATH} ({manifest['sha256']})")
    return 0


def command_fetch_essay(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-essay: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{ESSAY_RAW_BASE_URL}/{args.commit}/{name}")
        for name in (ESSAY_PATH, "LICENSE")
    }
    essay_text = files[ESSAY_PATH].decode("utf-8")
    parsed = parse_essay_text(essay_text, f"{ESSAY_REPOSITORY}/{args.commit}/{ESSAY_PATH}")
    if parsed.errors:
        print("fetch-essay: invalid essay data:", file=sys.stderr)
        for line in parsed.errors[:REPORT_EXAMPLE_LIMIT]:
            print(f"  {line}", file=sys.stderr)
        print(f"fetch-essay: {len(parsed.errors)} format errors", file=sys.stderr)
        return 1
    maximum_frequency = max((entry.frequency for entry in parsed.entries), default=0)
    manifest = {
        "repository": ESSAY_REPOSITORY,
        "commit": args.commit,
        "essayPath": ESSAY_PATH,
        "sha256": sha256_bytes(files[ESSAY_PATH]),
        "licensePath": "LICENSE",
        "licenseSha256": sha256_bytes(files["LICENSE"]),
        "formatVersion": ESSAY_FORMAT_VERSION,
        "entryCount": len(parsed.entries),
        "frequencyMax": maximum_frequency,
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"fetch-essay: wrote {destination / ESSAY_PATH} "
        f"({manifest['sha256']}, {len(parsed.entries)} entries)"
    )
    return 0


def command_build(args: argparse.Namespace) -> int:
    required_paths = {
        "terra source": args.terra_source,
        "terra manifest": args.terra_manifest,
        "essay source": args.essay_source,
        "essay manifest": args.essay_manifest,
    }
    for label, path in required_paths.items():
        if not Path(path).exists():
            print(f"build: {label} not found: {path}", file=sys.stderr)
            return 2
    try:
        result = build_database(
            Path(args.terra_source),
            Path(args.terra_manifest),
            Path(args.essay_source),
            Path(args.essay_manifest),
            Path(args.output),
            Path(args.report),
            Path(args.opencc_source) if args.opencc_source else None,
            Path(args.opencc_manifest) if args.opencc_manifest else None,
        )
    except CompileFailure as failure:
        print("build: failed:", file=sys.stderr)
        for line in str(failure).splitlines():
            print(f"  {line}", file=sys.stderr)
        return 1
    print(
        f"build: {result.compiled_entries} entries compiled, "
        f"{result.essay_annotated_entries}/{result.essay_entries} essay entries annotated, "
        f"{result.merged_terra_essay_entries} terra+essay merges, "
        f"{result.database_bytes} bytes"
    )
    return 0


def command_fetch_octagram(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-octagram: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{OCTAGRAM_RAW_BASE_URL}/{args.commit}/{name}")
        for name in (OCTAGRAM_GRAM_PATH, "LICENSE")
    }
    if not files[OCTAGRAM_GRAM_PATH].startswith(b"Rime::Grammar/"):
        print("fetch-octagram: downloaded file is not a Rime::Grammar database", file=sys.stderr)
        return 1
    manifest = {
        "repository": OCTAGRAM_REPOSITORY,
        "commit": args.commit,
        "gramPath": OCTAGRAM_GRAM_PATH,
        "sha256": sha256_bytes(files[OCTAGRAM_GRAM_PATH]),
        "licensePath": "LICENSE",
        "licenseSha256": sha256_bytes(files["LICENSE"]),
        "formatVersion": OCTAGRAM_FORMAT_VERSION,
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    manifest_path = destination / "SOURCE.json"
    if manifest_path.exists():
        existing = load_manifest(manifest_path)
        if existing.get("commit") == args.commit and existing.get("sha256") != manifest["sha256"]:
            print("fetch-octagram: download does not match the committed SOURCE.json", file=sys.stderr)
            return 1
        if existing.get("commit") == args.commit:
            print(f"fetch-octagram: wrote {destination / OCTAGRAM_GRAM_PATH} ({manifest['sha256']})")
            return 0
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"fetch-octagram: wrote {destination / OCTAGRAM_GRAM_PATH} ({manifest['sha256']})")
    return 0


def command_build_grammar(args: argparse.Namespace) -> int:
    for label, path in (("source", args.source), ("manifest", args.manifest), ("text source", args.text_source)):
        if path is not None and not Path(path).exists():
            print(f"build-grammar: {label} not found: {path}", file=sys.stderr)
            return 2
    try:
        result = build_grammar(
            Path(args.output),
            Path(args.report),
            source_path=Path(args.source) if args.source else None,
            manifest_path=Path(args.manifest) if args.manifest else None,
            text_source_path=Path(args.text_source) if args.text_source else None,
            block_size=args.block_size,
        )
    except CompileFailure as failure:
        print("build-grammar: failed:", file=sys.stderr)
        for line in str(failure).splitlines():
            print(f"  {line}", file=sys.stderr)
        return 1
    print(
        f"build-grammar: {result.key_count} keys "
        f"({result.dropped_keys} dropped), {result.grammar_bytes} bytes"
    )
    return 0


def opencc_source_files() -> dict[str, str]:
    """Local file name -> path inside the OpenCC repository."""
    files = {
        f"{name}.txt": f"{OPENCC_DICTIONARY_DIRECTORY}/{name}.txt" for name in OPENCC_SOURCE_DICTIONARIES
    }
    # Renamed so it does not collide with other LICENSE files in the app bundle.
    files["OpenCC-LICENSE.txt"] = "LICENSE"
    files["testcases.json"] = OPENCC_TESTCASES_PATH
    return files


def command_fetch_opencc(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-opencc: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{OPENCC_RAW_BASE_URL}/{args.commit}/{path}")
        for name, path in opencc_source_files().items()
    }
    manifest = {
        "repository": OPENCC_REPOSITORY,
        "commit": args.commit,
        "tag": args.tag or "",
        "files": {
            name: {"path": path, "sha256": sha256_bytes(files[name])}
            for name, path in opencc_source_files().items()
        },
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch-opencc: wrote {len(files)} files to {destination}")
    return 0


def build_opencc(
    source_directory: Path, manifest_path: Path, output_path: Path, golden_path: Path | None = None
) -> int:
    manifest = load_manifest(manifest_path)
    expected = manifest.get("files")
    if not isinstance(expected, dict) or not validate_commit(str(manifest.get("commit", ""))):
        raise CompileFailure(f"{manifest_path}: missing commit or files")
    for name in opencc_source_files():
        record = expected.get(name)
        if not isinstance(record, dict) or not SHA256_PATTERN.fullmatch(str(record.get("sha256", ""))):
            raise CompileFailure(f"{manifest_path}: missing sha256 for {name}")
        actual = sha256_bytes((source_directory / name).read_bytes())
        if actual != record["sha256"]:
            raise CompileFailure(f"{name}: sha256 {actual} does not match manifest {record['sha256']}")
    try:
        dictionaries = load_opencc_dictionaries(source_directory)
        data = write_fzopencc(dictionaries)
        golden = (
            format_opencc_golden(opencc_golden_rows(dictionaries, source_directory / "testcases.json"))
            if golden_path is not None
            else None
        )
    except OpenCCFormatError as error:
        raise CompileFailure(str(error)) from error
    if len(data) > MAXIMUM_OPENCC_BYTES:
        raise CompileFailure(f"FZOpenCC output is {len(data)} bytes, above {MAXIMUM_OPENCC_BYTES}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    if golden_path is not None and golden is not None:
        golden_path.parent.mkdir(parents=True, exist_ok=True)
        golden_path.write_text(golden, encoding="utf-8")
    return len(data)


def command_build_opencc(args: argparse.Namespace) -> int:
    try:
        size = build_opencc(
            Path(args.source_dir),
            Path(args.manifest),
            Path(args.output),
            Path(args.golden) if args.golden else None,
        )
    except (CompileFailure, OSError) as failure:
        print(f"build-opencc: failed: {failure}", file=sys.stderr)
        return 1
    print(f"build-opencc: {len(OPENCC_CONVERSIONS)} conversions, {size} bytes")
    return 0


def emoji_source_files() -> dict[str, str]:
    """Local file name -> path inside the rime-emoji repository."""
    return {"emoji_word.txt": EMOJI_WORD_PATH, "LICENSE": "LICENSE"}


def command_fetch_emoji(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-emoji: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{EMOJI_RAW_BASE_URL}/{args.commit}/{path}")
        for name, path in emoji_source_files().items()
    }
    try:
        table = parse_emoji_words(files["emoji_word.txt"].decode("utf-8"), EMOJI_WORD_PATH)
    except (EmojiFormatError, UnicodeDecodeError) as error:
        print(f"fetch-emoji: invalid emoji data: {error}", file=sys.stderr)
        return 1
    manifest = {
        "repository": EMOJI_REPOSITORY,
        "commit": args.commit,
        "formatVersion": EMOJI_FORMAT_VERSION,
        "files": {
            name: {"path": path, "sha256": sha256_bytes(files[name])}
            for name, path in emoji_source_files().items()
        },
        "wordCount": len(table),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch-emoji: wrote {len(files)} files to {destination} ({len(table)} words)")
    return 0


def build_emoji(source_directory: Path, manifest_path: Path, output_path: Path) -> tuple[int, int]:
    """Returns the word count and output size."""
    manifest = load_manifest(manifest_path)
    if manifest.get("formatVersion") != EMOJI_FORMAT_VERSION:
        raise CompileFailure(
            f"{manifest_path}: unsupported emoji formatVersion {manifest.get('formatVersion')!r}, "
            f"expected {EMOJI_FORMAT_VERSION}"
        )
    expected = manifest.get("files")
    if not isinstance(expected, dict):
        raise CompileFailure(f"{manifest_path}: missing files")
    for name in emoji_source_files():
        record = expected.get(name)
        if not isinstance(record, dict) or not SHA256_PATTERN.fullmatch(str(record.get("sha256", ""))):
            raise CompileFailure(f"{manifest_path}: missing sha256 for {name}")
        actual = sha256_bytes((source_directory / name).read_bytes())
        if actual != record["sha256"]:
            raise CompileFailure(f"{name}: sha256 {actual} does not match manifest {record['sha256']}")
    try:
        table = parse_emoji_words(
            (source_directory / "emoji_word.txt").read_text(encoding="utf-8"), EMOJI_WORD_PATH
        )
    except EmojiFormatError as error:
        raise CompileFailure(str(error)) from error
    data = format_emoji_table(table).encode("utf-8")
    if len(data) > MAXIMUM_EMOJI_BYTES:
        raise CompileFailure(f"emoji output is {len(data)} bytes, above {MAXIMUM_EMOJI_BYTES}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    return len(table), len(data)


def command_build_emoji(args: argparse.Namespace) -> int:
    try:
        words, size = build_emoji(Path(args.source_dir), Path(args.manifest), Path(args.output))
    except (CompileFailure, OSError) as failure:
        print(f"build-emoji: failed: {failure}", file=sys.stderr)
        return 1
    print(f"build-emoji: {words} words, {size} bytes")
    return 0


def unicode_emoji_source_urls(version: str) -> dict[str, str]:
    """Local file name -> download URL."""
    return {
        "emoji-test.txt": f"{UNICODE_EMOJI_BASE_URL.format(version=version)}/emoji-test.txt",
        "Unicode-LICENSE.txt": UNICODE_LICENSE_URL,
    }


def command_fetch_unicode_emoji(args: argparse.Namespace) -> int:
    if UNICODE_VERSION_PATTERN.fullmatch(args.version) is None:
        print("fetch-unicode-emoji: --version must look like 17.0.0", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    urls = unicode_emoji_source_urls(args.version)
    files = {name: download(url) for name, url in urls.items()}
    try:
        rows = parse_emoji_test(files["emoji-test.txt"].decode("utf-8"), "emoji-test.txt")
    except (EmojiFormatError, UnicodeDecodeError) as error:
        print(f"fetch-unicode-emoji: invalid emoji-test.txt: {error}", file=sys.stderr)
        return 1
    manifest = {
        "source": "Unicode emoji data (UTS #51)",
        "version": args.version,
        "formatVersion": CATALOG_FORMAT_VERSION,
        "files": {
            name: {"url": url, "sha256": sha256_bytes(files[name])} for name, url in urls.items()
        },
        "emojiCount": len(rows),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch-unicode-emoji: wrote {len(files)} files to {destination} ({len(rows)} emoji)")
    return 0


def build_emoji_catalog(source_directory: Path, manifest_path: Path, output_path: Path) -> tuple[int, int]:
    """Returns the emoji count and output size."""
    try:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise CompileFailure(f"{manifest_path}: invalid JSON manifest ({error})") from error
    if manifest.get("formatVersion") != CATALOG_FORMAT_VERSION:
        raise CompileFailure(f"{manifest_path}: unsupported formatVersion {manifest.get('formatVersion')!r}")
    if UNICODE_VERSION_PATTERN.fullmatch(str(manifest.get("version", ""))) is None:
        raise CompileFailure(f"{manifest_path}: missing Unicode version")
    expected = manifest.get("files")
    if not isinstance(expected, dict):
        raise CompileFailure(f"{manifest_path}: missing files")
    for name in unicode_emoji_source_files():
        record = expected.get(name)
        if not isinstance(record, dict) or not SHA256_PATTERN.fullmatch(str(record.get("sha256", ""))):
            raise CompileFailure(f"{manifest_path}: missing sha256 for {name}")
        actual = sha256_bytes((source_directory / name).read_bytes())
        if actual != record["sha256"]:
            raise CompileFailure(f"{name}: sha256 {actual} does not match manifest {record['sha256']}")
    try:
        rows = parse_emoji_test(
            (source_directory / "emoji-test.txt").read_text(encoding="utf-8"), "emoji-test.txt"
        )
    except EmojiFormatError as error:
        raise CompileFailure(str(error)) from error
    data = format_emoji_catalog(rows).encode("utf-8")
    if len(data) > MAXIMUM_EMOJI_BYTES:
        raise CompileFailure(f"emoji catalog is {len(data)} bytes, above {MAXIMUM_EMOJI_BYTES}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    return len(rows), len(data)


def unicode_emoji_source_files() -> tuple[str, ...]:
    return tuple(unicode_emoji_source_urls("0.0.0"))


def command_build_emoji_catalog(args: argparse.Namespace) -> int:
    try:
        count, size = build_emoji_catalog(Path(args.source_dir), Path(args.manifest), Path(args.output))
    except (CompileFailure, OSError) as failure:
        print(f"build-emoji-catalog: failed: {failure}", file=sys.stderr)
        return 1
    print(f"build-emoji-catalog: {count} emoji, {size} bytes")
    return 0


def cldr_annotation_source_files() -> dict[str, str]:
    """Local file name -> path inside the CLDR repository."""
    return {
        "annotations-zh_Hant.xml": "common/annotations/zh_Hant.xml",
        "annotationsDerived-zh_Hant.xml": "common/annotationsDerived/zh_Hant.xml",
        "CLDR-LICENSE.txt": "LICENSE",
    }


def command_fetch_cldr_annotations(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-cldr-annotations: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{CLDR_RAW_BASE_URL}/{args.commit}/{path}")
        for name, path in cldr_annotation_source_files().items()
    }
    try:
        annotations = parse_cldr_annotations(files["annotations-zh_Hant.xml"], "annotations/zh_Hant.xml")
        derived = parse_cldr_annotations(files["annotationsDerived-zh_Hant.xml"], "annotationsDerived/zh_Hant.xml")
    except EmojiFormatError as error:
        print(f"fetch-cldr-annotations: invalid annotations: {error}", file=sys.stderr)
        return 1
    manifest = {
        "repository": CLDR_REPOSITORY,
        "release": args.release,
        "commit": args.commit,
        "formatVersion": KEYWORDS_FORMAT_VERSION,
        "files": {
            name: {"path": path, "sha256": sha256_bytes(files[name])}
            for name, path in cldr_annotation_source_files().items()
        },
        "annotationCount": len(annotations),
        "derivedAnnotationCount": len(derived),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch-cldr-annotations: wrote {len(files)} files to {destination}")
    return 0


def verify_source_hashes(manifest: dict, manifest_path: Path, source_directory: Path, names) -> None:
    expected = manifest.get("files")
    if not isinstance(expected, dict):
        raise CompileFailure(f"{manifest_path}: missing files")
    for name in names:
        record = expected.get(name)
        if not isinstance(record, dict) or not SHA256_PATTERN.fullmatch(str(record.get("sha256", ""))):
            raise CompileFailure(f"{manifest_path}: missing sha256 for {name}")
        actual = sha256_bytes((source_directory / name).read_bytes())
        if actual != record["sha256"]:
            raise CompileFailure(f"{name}: sha256 {actual} does not match manifest {record['sha256']}")


def build_emoji_keywords(
    unicode_directory: Path,
    unicode_manifest_path: Path,
    cldr_directory: Path,
    cldr_manifest_path: Path,
    output_path: Path,
) -> tuple[int, int]:
    """Returns the emoji count and output size."""
    unicode_manifest = json.loads(Path(unicode_manifest_path).read_text(encoding="utf-8"))
    verify_source_hashes(unicode_manifest, unicode_manifest_path, unicode_directory, unicode_emoji_source_files())
    cldr_manifest = load_manifest(cldr_manifest_path)
    if cldr_manifest.get("formatVersion") != KEYWORDS_FORMAT_VERSION:
        raise CompileFailure(
            f"{cldr_manifest_path}: unsupported formatVersion {cldr_manifest.get('formatVersion')!r}"
        )
    verify_source_hashes(cldr_manifest, cldr_manifest_path, cldr_directory, cldr_annotation_source_files())
    try:
        rows = parse_emoji_test(
            (unicode_directory / "emoji-test.txt").read_text(encoding="utf-8"), "emoji-test.txt"
        )
        entries = merge_emoji_keywords(
            rows,
            parse_cldr_annotations(
                (cldr_directory / "annotations-zh_Hant.xml").read_bytes(), "annotations/zh_Hant.xml"
            ),
            parse_cldr_annotations(
                (cldr_directory / "annotationsDerived-zh_Hant.xml").read_bytes(),
                "annotationsDerived/zh_Hant.xml",
            ),
        )
    except EmojiFormatError as error:
        raise CompileFailure(str(error)) from error
    data = format_emoji_keywords(entries).encode("utf-8")
    if len(data) > MAXIMUM_EMOJI_BYTES:
        raise CompileFailure(f"emoji keywords are {len(data)} bytes, above {MAXIMUM_EMOJI_BYTES}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    return len(entries), len(data)


def command_build_emoji_keywords(args: argparse.Namespace) -> int:
    try:
        count, size = build_emoji_keywords(
            Path(args.unicode_dir),
            Path(args.unicode_manifest),
            Path(args.cldr_dir),
            Path(args.cldr_manifest),
            Path(args.output),
        )
    except (CompileFailure, OSError, json.JSONDecodeError) as failure:
        print(f"build-emoji-keywords: failed: {failure}", file=sys.stderr)
        return 1
    print(f"build-emoji-keywords: {count} emoji, {size} bytes")
    return 0


def rime_symbol_source_files() -> dict[str, str]:
    """Local file name -> path inside the rime-prelude repository."""
    return {"symbols.yaml": "symbols.yaml", "LICENSE": "LICENSE"}


def mozc_kaomoji_source_files() -> dict[str, str]:
    """Local file name -> path inside the Mozc repository."""
    return {
        "emoticon-categorized.tsv": "src/data/emoticon/categorized.tsv",
        "Mozc-LICENSE.txt": "LICENSE",
    }


def parse_symbol_source(text: str) -> dict[str, list[str]]:
    return symbol_palette(parse_rime_symbols(text, "symbols.yaml"), "symbols.yaml")


def parse_kaomoji_source(text: str) -> dict[str, list[str]]:
    return parse_mozc_categorized(text, "src/data/emoticon/categorized.tsv", KAOMOJI_CATEGORIES)


def fetch_palette_source(
    command: str,
    args: argparse.Namespace,
    repository: str,
    raw_base_url: str,
    source_files: dict[str, str],
    parse,
    data_name: str,
    count_key: str,
) -> int:
    if not validate_commit(args.commit):
        print(f"{command}: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {name: download(f"{raw_base_url}/{args.commit}/{path}") for name, path in source_files.items()}
    try:
        palette = parse(files[data_name].decode("utf-8"))
    except (PaletteFormatError, UnicodeDecodeError) as error:
        print(f"{command}: invalid palette data: {error}", file=sys.stderr)
        return 1
    manifest = {
        "repository": repository,
        "commit": args.commit,
        "formatVersion": PALETTE_FORMAT_VERSION,
        "files": {
            name: {"path": path, "sha256": sha256_bytes(files[name])}
            for name, path in source_files.items()
        },
        count_key: sum(len(values) for values in palette.values()),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"{command}: wrote {len(files)} files to {destination}")
    return 0


def command_fetch_rime_symbols(args: argparse.Namespace) -> int:
    return fetch_palette_source(
        "fetch-rime-symbols", args, RIME_PRELUDE_REPOSITORY, RIME_PRELUDE_RAW_BASE_URL,
        rime_symbol_source_files(), parse_symbol_source, "symbols.yaml", "symbolCount",
    )


def command_fetch_mozc_kaomoji(args: argparse.Namespace) -> int:
    return fetch_palette_source(
        "fetch-mozc-kaomoji", args, MOZC_REPOSITORY, MOZC_RAW_BASE_URL,
        mozc_kaomoji_source_files(), parse_kaomoji_source, "emoticon-categorized.tsv", "kaomojiCount",
    )


def verify_palette_source(directory: Path, manifest_path: Path, source_files: dict[str, str]) -> None:
    manifest = load_manifest(manifest_path)
    if manifest.get("formatVersion") != PALETTE_FORMAT_VERSION:
        raise CompileFailure(f"{manifest_path}: unsupported formatVersion {manifest.get('formatVersion')!r}")
    verify_source_hashes(manifest, manifest_path, directory, source_files)


def build_symbol_palettes(
    symbol_directory: Path,
    symbol_manifest_path: Path,
    kaomoji_directory: Path,
    kaomoji_manifest_path: Path,
    output_path: Path,
) -> tuple[int, int]:
    """Returns the entry count and output size."""
    verify_palette_source(symbol_directory, symbol_manifest_path, rime_symbol_source_files())
    verify_palette_source(kaomoji_directory, kaomoji_manifest_path, mozc_kaomoji_source_files())
    try:
        palettes = {
            "symbol": parse_symbol_source((symbol_directory / "symbols.yaml").read_text(encoding="utf-8")),
            "kaomoji": parse_kaomoji_source(
                (kaomoji_directory / "emoticon-categorized.tsv").read_text(encoding="utf-8")
            ),
        }
    except PaletteFormatError as error:
        raise CompileFailure(str(error)) from error
    text = format_palettes(palettes)
    data = text.encode("utf-8")
    if len(data) > MAXIMUM_PALETTE_BYTES:
        raise CompileFailure(f"palettes are {len(data)} bytes, above {MAXIMUM_PALETTE_BYTES}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    return text.count("\n"), len(data)


def command_build_symbol_palettes(args: argparse.Namespace) -> int:
    try:
        count, size = build_symbol_palettes(
            Path(args.symbols_dir),
            Path(args.symbols_manifest),
            Path(args.kaomoji_dir),
            Path(args.kaomoji_manifest),
            Path(args.output),
        )
    except (CompileFailure, OSError, UnicodeDecodeError) as failure:
        print(f"build-symbol-palettes: failed: {failure}", file=sys.stderr)
        return 1
    print(f"build-symbol-palettes: {count} entries, {size} bytes")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compile the pinned Rime sources into the SQLite dictionary and FZGram grammar"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch_terra = subparsers.add_parser(
        "fetch-terra", help="download the pinned Terra dictionary and license"
    )
    fetch_terra.add_argument("--commit", required=True)
    fetch_terra.add_argument("--dest", default="Vendor/rime-terra-pinyin")
    fetch_terra.set_defaults(func=command_fetch_terra)

    fetch_essay = subparsers.add_parser(
        "fetch-essay", help="download the pinned Essay vocabulary and license"
    )
    fetch_essay.add_argument("--commit", required=True)
    fetch_essay.add_argument("--dest", default="Vendor/rime-essay")
    fetch_essay.set_defaults(func=command_fetch_essay)

    build = subparsers.add_parser("build", help="build the SQLite dictionary without network access")
    build.add_argument("--terra-source", required=True)
    build.add_argument("--terra-manifest", required=True)
    build.add_argument("--essay-source", required=True)
    build.add_argument("--essay-manifest", required=True)
    build.add_argument("--output", required=True)
    build.add_argument("--report", required=True)
    build.add_argument("--opencc-source", help="OpenCC dictionary directory, for Taiwan vocabulary weights")
    build.add_argument("--opencc-manifest", help="OpenCC SOURCE.json listing TWPhrases.txt")
    build.set_defaults(func=command_build)

    fetch_octagram = subparsers.add_parser(
        "fetch-octagram", help="download the pinned octagram grammar and license"
    )
    fetch_octagram.add_argument("--commit", required=True)
    fetch_octagram.add_argument("--dest", default="Vendor/rime-octagram-data")
    fetch_octagram.set_defaults(func=command_fetch_octagram)

    build_grammar_parser = subparsers.add_parser(
        "build-grammar", help="convert the octagram grammar to FZGram without network access"
    )
    build_grammar_parser.add_argument("--source")
    build_grammar_parser.add_argument("--manifest")
    build_grammar_parser.add_argument("--text-source", help="key<TAB>value lines, for test fixtures")
    build_grammar_parser.add_argument(
        "--block-size", type=int, default=FZGRAM_DEFAULT_BLOCK_SIZE, help=argparse.SUPPRESS
    )
    build_grammar_parser.add_argument("--output", required=True)
    build_grammar_parser.add_argument("--report", required=True)
    build_grammar_parser.set_defaults(func=command_build_grammar)

    fetch_opencc = subparsers.add_parser(
        "fetch-opencc", help="download the pinned OpenCC dictionaries, license and test cases"
    )
    fetch_opencc.add_argument("--commit", required=True)
    fetch_opencc.add_argument("--tag", help="release tag the commit belongs to, recorded in SOURCE.json")
    fetch_opencc.add_argument("--dest", default="Vendor/opencc")
    fetch_opencc.set_defaults(func=command_fetch_opencc)

    build_opencc_parser = subparsers.add_parser(
        "build-opencc", help="compile the OpenCC dictionaries to FZOpenCC without network access"
    )
    build_opencc_parser.add_argument("--source-dir", default="Vendor/opencc")
    build_opencc_parser.add_argument("--manifest", default="Vendor/opencc/SOURCE.json")
    build_opencc_parser.add_argument("--output", default="Generated/flickbo.opencc")
    build_opencc_parser.add_argument(
        "--golden", help="also write conversion<TAB>input<TAB>expected rows for the Swift tests"
    )
    build_opencc_parser.set_defaults(func=command_build_opencc)

    fetch_emoji = subparsers.add_parser(
        "fetch-emoji", help="download the pinned rime-emoji word table and license"
    )
    fetch_emoji.add_argument("--commit", required=True)
    fetch_emoji.add_argument("--dest", default="Vendor/rime-emoji")
    fetch_emoji.set_defaults(func=command_fetch_emoji)

    build_emoji_parser = subparsers.add_parser(
        "build-emoji", help="compile the rime-emoji word table without network access"
    )
    build_emoji_parser.add_argument("--source-dir", default="Vendor/rime-emoji")
    build_emoji_parser.add_argument("--manifest", default="Vendor/rime-emoji/SOURCE.json")
    build_emoji_parser.add_argument("--output", default="Generated/flickbo.emoji")
    build_emoji_parser.set_defaults(func=command_build_emoji)

    fetch_unicode_emoji = subparsers.add_parser(
        "fetch-unicode-emoji", help="download a Unicode emoji-test.txt and the Unicode license"
    )
    fetch_unicode_emoji.add_argument("--version", required=True, help="Unicode version, e.g. 17.0.0")
    fetch_unicode_emoji.add_argument("--dest", default="Vendor/unicode-emoji")
    fetch_unicode_emoji.set_defaults(func=command_fetch_unicode_emoji)

    build_emoji_catalog_parser = subparsers.add_parser(
        "build-emoji-catalog", help="compile the emoji palette catalog without network access"
    )
    build_emoji_catalog_parser.add_argument("--source-dir", default="Vendor/unicode-emoji")
    build_emoji_catalog_parser.add_argument("--manifest", default="Vendor/unicode-emoji/SOURCE.json")
    build_emoji_catalog_parser.add_argument("--output", default="Generated/flickbo.emojicatalog")
    build_emoji_catalog_parser.set_defaults(func=command_build_emoji_catalog)

    fetch_cldr = subparsers.add_parser(
        "fetch-cldr-annotations", help="download CLDR zh_Hant emoji annotations at a pinned commit"
    )
    fetch_cldr.add_argument("--commit", required=True, help="full CLDR commit hash")
    fetch_cldr.add_argument("--release", required=True, help="CLDR release tag, e.g. release-49")
    fetch_cldr.add_argument("--dest", default="Vendor/cldr-annotations")
    fetch_cldr.set_defaults(func=command_fetch_cldr_annotations)

    build_keywords = subparsers.add_parser(
        "build-emoji-keywords", help="compile CLDR emoji search keywords without network access"
    )
    build_keywords.add_argument("--unicode-dir", default="Vendor/unicode-emoji")
    build_keywords.add_argument("--unicode-manifest", default="Vendor/unicode-emoji/SOURCE.json")
    build_keywords.add_argument("--cldr-dir", default="Vendor/cldr-annotations")
    build_keywords.add_argument("--cldr-manifest", default="Vendor/cldr-annotations/SOURCE.json")
    build_keywords.add_argument("--output", default="Generated/flickbo.emojikeywords")
    build_keywords.set_defaults(func=command_build_emoji_keywords)

    fetch_rime_symbols = subparsers.add_parser(
        "fetch-rime-symbols", help="download rime-prelude's symbols.yaml and license at a pinned commit"
    )
    fetch_rime_symbols.add_argument("--commit", required=True, help="full rime-prelude commit hash")
    fetch_rime_symbols.add_argument("--dest", default="Vendor/rime-prelude")
    fetch_rime_symbols.set_defaults(func=command_fetch_rime_symbols)

    fetch_mozc = subparsers.add_parser(
        "fetch-mozc-kaomoji", help="download Mozc's kaomoji palette and license at a pinned commit"
    )
    fetch_mozc.add_argument("--commit", required=True, help="full Mozc commit hash")
    fetch_mozc.add_argument("--dest", default="Vendor/mozc-kaomoji")
    fetch_mozc.set_defaults(func=command_fetch_mozc_kaomoji)

    build_palettes = subparsers.add_parser(
        "build-symbol-palettes", help="compile the symbol and kaomoji palettes without network access"
    )
    build_palettes.add_argument("--symbols-dir", default="Vendor/rime-prelude")
    build_palettes.add_argument("--symbols-manifest", default="Vendor/rime-prelude/SOURCE.json")
    build_palettes.add_argument("--kaomoji-dir", default="Vendor/mozc-kaomoji")
    build_palettes.add_argument("--kaomoji-manifest", default="Vendor/mozc-kaomoji/SOURCE.json")
    build_palettes.add_argument("--output", default="Generated/flickbo.symbols")
    build_palettes.set_defaults(func=command_build_symbol_palettes)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
