import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compile_dictionary import (  # noqa: E402
    CompileFailure,
    build_symbol_palettes,
    mozc_kaomoji_source_files,
    rime_symbol_source_files,
)
from symbol_data import (  # noqa: E402
    FULL_SHAPE,
    KAOMOJI_CATEGORIES,
    SYMBOL_CATEGORIES,
    PaletteFormatError,
    format_palettes,
    parse_flow_sequence,
    parse_mozc_categorized,
    parse_rime_symbols,
    symbol_palette,
)

REPOSITORY = Path(__file__).resolve().parents[3]
SYMBOL_SOURCE = REPOSITORY / "Vendor" / "rime-prelude"
SYMBOL_MANIFEST = SYMBOL_SOURCE / "SOURCE.json"
KAOMOJI_SOURCE = REPOSITORY / "Vendor" / "mozc-kaomoji"
KAOMOJI_MANIFEST = KAOMOJI_SOURCE / "SOURCE.json"
PRODUCTION_OUTPUT = REPOSITORY / "Generated" / "flickbo.symbols"

RIME_SAMPLE = """\
punctuator:
  full_shape:
    ' ' : { commit: '　' }
    ',' : { commit: ， }
    '''' : { pair: [ '‘', '’' ] }
    '<' : [ 《, 〈 ]
    '&' : ＆
  half_shape:
    ',' : { commit: ， }
  symbols:
#箭頭
    '/jt': [ ↑, ↓, ',' ]
    '/sx': [ ±, 'it''s', ↓ ]
"""

CATEGORIES = {"A": "alpha", "B": "beta"}


class RimeSymbolTests(unittest.TestCase):
    def test_parses_plain_and_quoted_scalars(self):
        self.assertEqual(parse_flow_sequence(" ↑, '↓', 'it''s', ⓿ , ０"), ["↑", "↓", "it's", "⓿", "０"])

    def test_rejects_unsupported_flow_syntax(self):
        for text in (' "x", y', " [a], b", " 'open"):
            with self.subTest(text=text), self.assertRaises(PaletteFormatError):
                parse_flow_sequence(text)

    def test_reads_full_shape_values_and_shortcuts(self):
        symbols = parse_rime_symbols(RIME_SAMPLE, "test")
        self.assertEqual(symbols[FULL_SHAPE], ["　", "，", "‘", "’", "《", "〈", "＆"])
        self.assertEqual(symbols["/jt"], ["↑", "↓", ","])
        self.assertEqual(symbols["/sx"], ["±", "it's", "↓"])

    def test_rejects_a_malformed_shortcut_line(self):
        with self.assertRaises(PaletteFormatError):
            parse_rime_symbols(RIME_SAMPLE + "    '/zz': ↑\n", "test")

    def test_palette_collects_shortcuts_without_repeats(self):
        symbols = {name: [] for shortcuts in SYMBOL_CATEGORIES.values() for name in shortcuts}
        symbols.update({FULL_SHAPE: ["，", "　"], "/bd": ["、", "，"], "/jt": ["↑"]})
        palette = symbol_palette(symbols, "test")
        self.assertEqual(list(palette), list(SYMBOL_CATEGORIES))
        self.assertEqual(palette["punctuation"], ["，", "　", "、"])
        self.assertEqual(palette["arrows"], ["↑"])

    def test_palette_rejects_missing_shortcuts_and_spaces(self):
        symbols = {name: [] for shortcuts in SYMBOL_CATEGORIES.values() for name in shortcuts}
        with self.assertRaises(PaletteFormatError):
            symbol_palette({k: v for k, v in symbols.items() if k != "/jt"}, "test")
        with self.assertRaises(PaletteFormatError):
            symbol_palette({**symbols, "/jt": ["a b"]}, "test")


class MozcKaomojiTests(unittest.TestCase):
    def test_keeps_source_order_and_lists_multi_category_entries_in_each(self):
        text = "# value\tcategory\tdescription\n(^^)\tA\tにこ\n\n(-_-;)\tA B\tあせ\n(T_T)\tB\tなき\n"
        self.assertEqual(
            parse_mozc_categorized(text, "test", CATEGORIES),
            {"alpha": ["(^^)", "(-_-;)"], "beta": ["(-_-;)", "(T_T)"]},
        )

    def test_drops_repeats_within_a_category(self):
        text = "(^^)\tA\tにこ\n(^^)\tA\tえがお\n(T_T)\tB\t\n"
        self.assertEqual(parse_mozc_categorized(text, "test", CATEGORIES), {"alpha": ["(^^)"], "beta": ["(T_T)"]})

    def test_rejects_malformed_lines(self):
        for text in (
            "(^^)\n(T_T)\tB\t\n",
            "(^^)\tC\t\n(T_T)\tB\t\n",
            "(^^)\t\t\n(T_T)\tB\t\n",
            "\tA\t\n(T_T)\tB\t\n",
            "a\u0007\tA\t\n(T_T)\tB\t\n",
            "(^^)\tA\t\n",
        ):
            with self.subTest(text=text), self.assertRaises(PaletteFormatError):
                parse_mozc_categorized(text, "test", CATEGORIES)

    def test_formats_palette_lines_in_order(self):
        palettes = {"symbol": {"arrows": ["↑", "↓"]}, "kaomoji": {"smile": ["(^^)"]}}
        self.assertEqual(
            format_palettes(palettes),
            "symbol\tarrows\t↑\nsymbol\tarrows\t↓\nkaomoji\tsmile\t(^^)\n",
        )


class ProductionArtifactTests(unittest.TestCase):
    def build(self, directory, symbol_source=SYMBOL_SOURCE):
        output = Path(directory) / "flickbo.symbols"
        build_symbol_palettes(
            symbol_source, symbol_source / "SOURCE.json", KAOMOJI_SOURCE, KAOMOJI_MANIFEST, output
        )
        return output

    def test_committed_palettes_match_vendored_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.build(directory).read_bytes(), PRODUCTION_OUTPUT.read_bytes())

    def test_manifests_list_every_vendored_file(self):
        for source, files in ((SYMBOL_SOURCE, rime_symbol_source_files()), (KAOMOJI_SOURCE, mozc_kaomoji_source_files())):
            manifest = json.loads((source / "SOURCE.json").read_text(encoding="utf-8"))
            vendored = {path.name for path in source.iterdir() if path.name != "SOURCE.json"}
            self.assertEqual(set(manifest["files"]), vendored)
            self.assertEqual(set(manifest["files"]), set(files))

    def test_every_category_is_present_in_palette_order(self):
        rows = [line.split("\t") for line in PRODUCTION_OUTPUT.read_text(encoding="utf-8").split("\n")[:-1]]
        self.assertTrue(all(len(row) == 3 for row in rows))
        order = list(dict.fromkeys((row[0], row[1]) for row in rows))
        expected = [("symbol", name) for name in SYMBOL_CATEGORIES]
        expected += [("kaomoji", name) for name in KAOMOJI_CATEGORIES.values()]
        self.assertEqual(order, expected)
        punctuation = [row[2] for row in rows if row[:2] == ["symbol", "punctuation"]]
        self.assertEqual(punctuation[:3], ["　", "，", "。"])
        for symbol in ("！", "？", "（", "「", "、"):
            self.assertIn(symbol, punctuation)
        self.assertIn("ㄅ", [row[2] for row in rows if row[:2] == ["symbol", "letters"]])
        self.assertIn("(^_^;)", [row[2] for row in rows if row[:2] == ["kaomoji", "sweat"]])

    def test_build_rejects_modified_source(self):
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / "rime-prelude"
            copy.mkdir()
            for path in SYMBOL_SOURCE.iterdir():
                (copy / path.name).write_bytes(path.read_bytes())
            with (copy / "symbols.yaml").open("a", encoding="utf-8") as handle:
                handle.write("    '/zz': [ ♪ ]\n")
            with self.assertRaises(CompileFailure):
                self.build(directory, copy)


if __name__ == "__main__":
    unittest.main()
