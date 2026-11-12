import hashlib
import json
import unittest
from pathlib import Path


CASES = Path(__file__).with_name("cases")


class CaseCorpusTests(unittest.TestCase):
    def test_case_ids_are_unique_and_prompts_match_their_pins(self):
        case_files = sorted(CASES.glob("*/case.json"))
        self.assertGreaterEqual(len(case_files), 2)
        case_ids: set[str] = set()
        for case_file in case_files:
            case = json.loads(case_file.read_text())
            with self.subTest(case=case_file.parent.name):
                self.assertEqual(case["schema"], "veasel.real-task-case.v1")
                self.assertNotIn(case["id"], case_ids)
                case_ids.add(case["id"])
                prompt = (case_file.parent / case["prompt_file"]).read_bytes()
                self.assertEqual(hashlib.sha256(prompt).hexdigest(), case["prompt_sha256"])
                self.assertEqual(case["model"]["name"], case["comparators"]["opencode_model"].removeprefix("ollama/"))
                self.assertGreater(case["budgets"]["wall_seconds"], 0)
                self.assertTrue(case["oracle"])


if __name__ == "__main__":
    unittest.main()
