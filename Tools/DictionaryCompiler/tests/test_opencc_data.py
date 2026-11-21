import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compile_dictionary import CompileFailure, build_opencc  # noqa: E402
from opencc_data import (  # noqa: E402
    CONVERSIONS,
    Converter,
    OpenCCFormatError,
    TOFU_DEPENDENT_CASES,
    converters,
    format_golden,
    golden_rows,
    load_dictionaries,
    load_upstream_cases,
    parse_dictionary_text,
    read_fzopencc,
    reverse_dictionary,
    write_fzopencc,
)

REPOSITORY = Path(__file__).resolve().parents[3]
SOURCE = REPOSITORY / "Vendor" / "opencc"
MANIFEST = SOURCE / "SOURCE.json"
PRODUCTION_OUTPUT = REPOSITORY / "Generated" / "flickbo.opencc"
SWIFT_GOLDEN = REPOSITORY / "FlickBoTests" / "Fixtures" / "opencc-cases.tsv"


class ParsingTests(unittest.TestCase):
    def test_parses_entries_comments_and_reverse_preferences(self):
        parsed = parse_dictionary_text(
            "# comment\n# @reverse-prefer: 才\n纔\t才\n才\t才 纔\n\n", "test"
        )
        self.assertEqual(parsed.entries, {"纔": ["才"], "才": ["才", "纔"]})
        self.assertEqual(parsed.reverse_preferences, {"才": "才"})

    def test_rejects_malformed_lines(self):
        for text in ("沒有分隔\n", "\t值\n", "鍵\t\n", "鍵\t值\n鍵\t值\n"):
            with self.subTest(text=text), self.assertRaises(OpenCCFormatError):
                parse_dictionary_text(text, "test")

    def test_reverse_keeps_file_order_and_applies_preferences(self):
        parsed = parse_dictionary_text("# @reverse-prefer: 才\n纔\t才\n才\t才\n", "test")
        self.assertEqual(reverse_dictionary(parsed, "test"), {"才": ["才", "纔"]})
        unpreferred = parse_dictionary_text("纔\t才\n才\t才\n", "test")
        self.assertEqual(reverse_dictionary(unpreferred, "test"), {"才": ["纔", "才"]})

    def test_reverse_preference_without_mapping_fails(self):
        parsed = parse_dictionary_text("# @reverse-prefer: 甲\n乙\t丙\n", "test")
        with self.assertRaises(OpenCCFormatError):
            reverse_dictionary(parsed, "test")


class ConverterTests(unittest.TestCase):
    def test_short_circuit_group_prefers_first_dictionary_with_any_match(self):
        dictionaries = {"phrases": {"ab": "X"}, "characters": {"a": "1", "abc": "Y", "b": "2"}}
        converter = Converter(dictionaries, (("phrases", "characters"),))
        # "abc" in the second dictionary is longer, but the first dictionary matched.
        self.assertEqual(converter.convert("abc"), "Xc")
        self.assertEqual(converter.convert("ba"), "21")

    def test_steps_apply_in_order_and_unmatched_text_is_copied(self):
        dictionaries = {"first": {"甲": "乙"}, "second": {"乙": "丙"}}
        converter = Converter(dictionaries, (("first",), ("second",)))
        self.assertEqual(converter.convert("甲 x乙"), "丙 x丙")


class FormatTests(unittest.TestCase):
    def test_round_trips_dictionaries_and_conversions(self):
        dictionaries = load_dictionaries(SOURCE)
        decoded, conversions = read_fzopencc(write_fzopencc(dictionaries))
        self.assertEqual(conversions, CONVERSIONS)
        for name, entries in decoded.items():
            self.assertEqual(entries, dictionaries[name], name)

    def test_output_is_deterministic(self):
        dictionaries = load_dictionaries(SOURCE)
        self.assertEqual(write_fzopencc(dictionaries), write_fzopencc(dictionaries))


class UpstreamCaseTests(unittest.TestCase):
    def test_matches_opencc_test_cases(self):
        by_name = converters(load_dictionaries(SOURCE))
        checked = 0
        for case in load_upstream_cases(SOURCE / "testcases.json"):
            if case["id"] in TOFU_DEPENDENT_CASES:
                continue
            for name, expected in case["expected"].items():
                if name not in by_name:
                    continue
                with self.subTest(case=case["id"], conversion=name):
                    self.assertEqual(by_name[name].convert(case["input"]), expected)
                checked += 1
        self.assertGreater(checked, 200)

    def test_keyboard_level_conversions(self):
        by_name = converters(load_dictionaries(SOURCE))
        expectations = {
            ("t2tw", "爲什麼裏面着急"): "為什麼裡面著急",
            ("t2hk", "爲什麼"): "為什麼",
            ("t2s", "爲什麼"): "为什么",
            ("tw2t", "為什麼"): "爲什麼",
            ("tw2t", "著作"): "著作",
        }
        for (name, text), expected in expectations.items():
            with self.subTest(conversion=name, text=text):
                self.assertEqual(by_name[name].convert(text), expected)


class ProductionArtifactTests(unittest.TestCase):
    def test_committed_artifacts_match_vendored_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "flickbo.opencc"
            golden = Path(directory) / "opencc-cases.tsv"
            build_opencc(SOURCE, MANIFEST, output, golden)
            self.assertEqual(output.read_bytes(), PRODUCTION_OUTPUT.read_bytes())
            self.assertEqual(golden.read_text(encoding="utf-8"), SWIFT_GOLDEN.read_text(encoding="utf-8"))

    def test_golden_rows_include_upstream_and_extra_cases(self):
        rows = golden_rows(load_dictionaries(SOURCE), SOURCE / "testcases.json")
        self.assertEqual(format_golden(rows), SWIFT_GOLDEN.read_text(encoding="utf-8"))
        self.assertTrue({name for name, _, _ in rows} >= set(CONVERSIONS))

    def test_build_rejects_modified_source(self):
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory)
            for path in SOURCE.iterdir():
                (copy / path.name).write_bytes(path.read_bytes())
            with (copy / "TWVariants.txt").open("a", encoding="utf-8") as handle:
                handle.write("甲\t乙\n")
            with self.assertRaises(CompileFailure):
                build_opencc(copy, copy / "SOURCE.json", copy / "out.opencc")

    def test_manifest_lists_every_vendored_file(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        vendored = {path.name for path in SOURCE.iterdir() if path.name != "SOURCE.json"}
        self.assertEqual(set(manifest["files"]), vendored)


if __name__ == "__main__":
    unittest.main()
