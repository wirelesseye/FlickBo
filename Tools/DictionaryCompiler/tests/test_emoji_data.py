import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compile_dictionary import CompileFailure, build_emoji, emoji_source_files  # noqa: E402
from emoji_data import (  # noqa: E402
    EmojiFormatError,
    format_emoji_table,
    is_emoji_value,
    normalize_emoji,
    parse_emoji_words,
)

REPOSITORY = Path(__file__).resolve().parents[3]
SOURCE = REPOSITORY / "Vendor" / "rime-emoji"
MANIFEST = SOURCE / "SOURCE.json"
PRODUCTION_OUTPUT = REPOSITORY / "Generated" / "flickbo.emoji"


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


class ProductionArtifactTests(unittest.TestCase):
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
