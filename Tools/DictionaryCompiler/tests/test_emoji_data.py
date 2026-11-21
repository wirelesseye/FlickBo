import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compile_dictionary import (  # noqa: E402
    CompileFailure,
    build_emoji,
    build_emoji_catalog,
    build_emoji_keywords,
    cldr_annotation_source_files,
    emoji_source_files,
    unicode_emoji_source_files,
)
from emoji_data import (  # noqa: E402
    EmojiFormatError,
    format_emoji_catalog,
    format_emoji_keywords,
    format_emoji_table,
    is_emoji_value,
    merge_emoji_keywords,
    normalize_emoji,
    parse_cldr_annotations,
    parse_emoji_test,
    parse_emoji_words,
)

REPOSITORY = Path(__file__).resolve().parents[3]
SOURCE = REPOSITORY / "Vendor" / "rime-emoji"
MANIFEST = SOURCE / "SOURCE.json"
PRODUCTION_OUTPUT = REPOSITORY / "Generated" / "flickbo.emoji"
UNICODE_SOURCE = REPOSITORY / "Vendor" / "unicode-emoji"
UNICODE_MANIFEST = UNICODE_SOURCE / "SOURCE.json"
PRODUCTION_CATALOG = REPOSITORY / "Generated" / "flickbo.emojicatalog"
CLDR_SOURCE = REPOSITORY / "Vendor" / "cldr-annotations"
CLDR_MANIFEST = CLDR_SOURCE / "SOURCE.json"
PRODUCTION_KEYWORDS = REPOSITORY / "Generated" / "flickbo.emojikeywords"

ANNOTATIONS_SAMPLE = '''<?xml version="1.0" encoding="UTF-8" ?>
<ldml><annotations>
    <annotation cp="☺">微笑 | 臉 | 微笑</annotation>
    <annotation cp="☺" type="tts">微笑的臉</annotation>
    <annotation cp="🐈">貓 | 小貓</annotation>
    <annotation cp="🐈" type="tts">貓</annotation>
</annotations></ldml>
'''.encode("utf-8")

EMOJI_TEST_SAMPLE = """# group: Smileys & Emotion
# subgroup: face-smiling
1F600 ; fully-qualified # 😀 E1.0 grinning face
263A FE0F ; fully-qualified # ☺️ E0.6 smiling face
263A ; unqualified # ☺ E0.6 smiling face
# group: People & Body
1F44B ; fully-qualified # 👋 E0.6 waving hand
1F44B 1F3FB ; fully-qualified # 👋🏻 E1.0 waving hand: light skin tone
# group: Component
1F3FB ; component # 🏻 E1.0 light skin tone
# group: Animals & Nature
1F408 ; fully-qualified # 🐈 E0.7 cat
# group: Food & Drink
1F34E ; fully-qualified # 🍎 E0.6 red apple
# group: Travel & Places
1F3E0 ; fully-qualified # 🏠 E0.6 house
# group: Activities
1F389 ; fully-qualified # 🎉 E0.6 party popper
# group: Objects
1F4F1 ; fully-qualified # 📱 E0.6 mobile phone
# group: Symbols
2764 FE0F ; fully-qualified # ❤️ E0.6 red heart
# group: Flags
1F1F9 1F1FC ; fully-qualified # 🇹🇼 E2.0 flag: Taiwan
"""


class ParsingTests(unittest.TestCase):
    def test_drops_word_copy_and_repeated_emoji(self):
        table = parse_emoji_words("笑\t笑 😄️ 😸️ 😄️\n# comment\n\n", "test")
        self.assertEqual(table, {"笑": ["😄️", "😸️"]})

    def test_words_without_emoji_are_left_out(self):
        self.assertEqual(parse_emoji_words("笑\t笑\n", "test"), {})

    def test_removes_selector_after_skin_tone_modifier(self):
        self.assertEqual(normalize_emoji("👍🏻️"), "👍🏻")
        self.assertEqual(normalize_emoji("☺️"), "☺️")

    def test_accepts_emoji_sequences(self):
        for value in ["😄", "1️⃣", "ℹ️", "🙂‍↕️", "🏴\U000e0067\U000e0062\U000e007f", "〰️"]:
            with self.subTest(value=value):
                self.assertTrue(is_emoji_value(value))

    def test_rejects_text(self):
        for value in ["", "笑", "ok", "ℹ", "😄 😸", "1"]:
            with self.subTest(value=value):
                self.assertFalse(is_emoji_value(value))

    def test_rejects_malformed_lines(self):
        for text in ["笑 😄\n", "笑\t笑 好\n", "笑\t😄\n笑\t😸\n"]:
            with self.subTest(text=text), self.assertRaises(EmojiFormatError):
                parse_emoji_words(text, "test")

    def test_format_sorts_by_utf8_bytes(self):
        text = format_emoji_table({"笑": ["😄"], "A": ["🅰️"], "心": ["🫀", "💗"]})
        self.assertEqual(text, "A\t🅰️\n心\t🫀 💗\n笑\t😄\n")


class CatalogTests(unittest.TestCase):
    def test_keeps_fully_qualified_default_tone_emoji_in_order(self):
        rows = parse_emoji_test(EMOJI_TEST_SAMPLE, "test")
        self.assertEqual(
            [row[2] for row in rows], ["😀", "☺️", "👋", "🐈", "🍎", "🏠", "🎉", "📱", "❤️", "🇹🇼"]
        )
        self.assertEqual(rows[0], ("smileys", "1.0", "😀", "grinning face"))
        self.assertEqual(rows[-1], ("flags", "2.0", "🇹🇼", "flag: Taiwan"))

    def test_rejects_unknown_group_and_missing_groups(self):
        with self.assertRaises(EmojiFormatError):
            parse_emoji_test(EMOJI_TEST_SAMPLE.replace("# group: Objects", "# group: Gadgets"), "test")
        with self.assertRaises(EmojiFormatError):
            parse_emoji_test("# group: Smileys & Emotion\n1F600 ; fully-qualified # 😀 E1.0 grinning face\n", "t")

    def test_format_writes_tab_separated_rows(self):
        self.assertEqual(format_emoji_catalog([("smileys", "1.0", "😀", "grinning face")]), "smileys\t1.0\t😀\tgrinning face\n")


class KeywordTests(unittest.TestCase):
    def test_name_comes_first_and_repeats_are_dropped(self):
        annotations = parse_cldr_annotations(ANNOTATIONS_SAMPLE, "test")
        self.assertEqual(annotations["☺"], ["微笑的臉", "微笑", "臉"])
        self.assertEqual(annotations["🐈"], ["貓", "小貓"])

    def test_merge_uses_catalog_emoji_and_falls_back_to_derived(self):
        rows = [("smileys", "0.6", "☺️", "smiling face"), ("flags", "2.0", "🇹🇼", "flag: Taiwan")]
        entries = merge_emoji_keywords(
            rows, parse_cldr_annotations(ANNOTATIONS_SAMPLE, "test"), {"🇹🇼": ["旗子：台灣", "旗子"]}
        )
        self.assertEqual(entries, [("☺️", ["微笑的臉", "微笑", "臉"]), ("🇹🇼", ["旗子：台灣", "旗子"])])
        self.assertEqual(format_emoji_keywords(entries[:1]), "☺️\t微笑的臉\t微笑\t臉\n")

    def test_rejects_low_coverage_and_malformed_xml(self):
        rows = [("animals", "0.7", "🐈", "cat"), ("animals", "0.6", "🐕", "dog")]
        with self.assertRaises(EmojiFormatError):
            merge_emoji_keywords(rows, {"🐈": ["貓"]}, {})
        with self.assertRaises(EmojiFormatError):
            parse_cldr_annotations(b"<ldml><annotation cp='x'>", "test")


class ProductionArtifactTests(unittest.TestCase):
    def test_committed_keywords_match_vendored_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "flickbo.emojikeywords"
            build_emoji_keywords(UNICODE_SOURCE, UNICODE_MANIFEST, CLDR_SOURCE, CLDR_MANIFEST, output)
            self.assertEqual(output.read_bytes(), PRODUCTION_KEYWORDS.read_bytes())

    def test_keywords_manifest_lists_every_vendored_file(self):
        manifest = json.loads(CLDR_MANIFEST.read_text(encoding="utf-8"))
        vendored = {path.name for path in CLDR_SOURCE.iterdir() if path.name != "SOURCE.json"}
        self.assertEqual(set(manifest["files"]), vendored)
        self.assertEqual(set(manifest["files"]), set(cldr_annotation_source_files()))

    def test_representative_keywords(self):
        table = {line.split("\t")[0]: line.split("\t")[1:] for line in PRODUCTION_KEYWORDS.read_text(encoding="utf-8").splitlines()}
        self.assertEqual(table["🐈"][0], "貓")
        self.assertIn("笑臉", table["😸"])

    def test_committed_catalog_matches_vendored_source(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "flickbo.emojicatalog"
            build_emoji_catalog(UNICODE_SOURCE, UNICODE_MANIFEST, output)
            self.assertEqual(output.read_bytes(), PRODUCTION_CATALOG.read_bytes())

    def test_catalog_manifest_lists_every_vendored_file(self):
        manifest = json.loads(UNICODE_MANIFEST.read_text(encoding="utf-8"))
        vendored = {path.name for path in UNICODE_SOURCE.iterdir() if path.name != "SOURCE.json"}
        self.assertEqual(set(manifest["files"]), vendored)
        self.assertEqual(set(manifest["files"]), set(unicode_emoji_source_files()))

    def test_committed_artifact_matches_vendored_source(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "flickbo.emoji"
            build_emoji(SOURCE, MANIFEST, output)
            self.assertEqual(output.read_bytes(), PRODUCTION_OUTPUT.read_bytes())

    def test_representative_words(self):
        lines = PRODUCTION_OUTPUT.read_text(encoding="utf-8").splitlines()
        table = dict(line.split("\t") for line in lines)
        self.assertEqual(table["笑"].split(" "), ["😄️", "😸️"])
        self.assertIn("😊️", table["高興"].split(" "))

    def test_build_rejects_modified_source(self):
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory)
            for path in SOURCE.iterdir():
                (copy / path.name).write_bytes(path.read_bytes())
            with (copy / "emoji_word.txt").open("a", encoding="utf-8") as handle:
                handle.write("甲\t甲 😄\n")
            with self.assertRaises(CompileFailure):
                build_emoji(copy, copy / "SOURCE.json", copy / "out.emoji")

    def test_manifest_lists_every_vendored_file(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        vendored = {path.name for path in SOURCE.iterdir() if path.name != "SOURCE.json"}
        self.assertEqual(set(manifest["files"]), vendored)
        self.assertEqual(set(manifest["files"]), set(emoji_source_files()))


if __name__ == "__main__":
    unittest.main()
