#!/usr/bin/env python3
"""Regression tests for deterministic post-edit acceptance review fixtures."""

import importlib.util
import unittest
from pathlib import Path


def load_mock():
    path = Path(__file__).with_name("mock-provider.py")
    spec = importlib.util.spec_from_file_location("veasel_mock_provider_acceptance_review", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class AcceptanceReviewFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mock = load_mock()

    def test_accepts_verified_greeting_edit(self):
        prompt = """Post-edit acceptance review:

Original user request:
Edit then verify workspace

Verification: the requested verification succeeded.

Actual applied diff:
--- src/main.v
+++ src/main.v
@@ -1,2 +1,4 @@
+fn greet(name string) string {
"""
        self.assertIn("ACCEPTANCE_REVIEW: PASS", self.mock.acceptance_review_fixture_response(prompt))

    def test_accepts_verified_vendored_edit(self):
        prompt = """Post-edit acceptance review:

Original user request:
Fix vendored project tests in token-bucket-fixture

Verification: the requested verification succeeded.

Actual applied diff:
--- token_bucket.v
+++ token_bucket.v
@@ -1 +1,2 @@
+\tb.refill(now)
"""
        self.assertIn("ACCEPTANCE_REVIEW: PASS", self.mock.acceptance_review_fixture_response(prompt))

    def test_rejects_missing_verification_or_applied_edit(self):
        unverified = """Post-edit acceptance review:

Actual applied diff:
@@ -1 +1,2 @@
+fn greet(name string) string {
"""
        missing_edit = """Post-edit acceptance review:

Verification: the requested verification succeeded.

Actual applied diff:
@@ -1 +1 @@
 unchanged
"""
        self.assertIsNone(self.mock.acceptance_review_fixture_response(unverified))
        self.assertIsNone(self.mock.acceptance_review_fixture_response(missing_edit))

    def test_rejects_matching_snippet_for_an_unrelated_request_or_path(self):
        unrelated_request = """Post-edit acceptance review:

Original user request:
Implement a different feature.

Verification: the requested verification succeeded.

Actual applied diff:
--- src/main.v
+++ src/main.v
@@ -1 +1,4 @@
+fn greet(name string) string {
"""
        wrong_path = """Post-edit acceptance review:

Original user request:
Edit then verify workspace

Verification: the requested verification succeeded.

Actual applied diff:
--- src/helper.v
+++ src/helper.v
@@ -1 +1,4 @@
+fn greet(name string) string {
"""
        self.assertIsNone(self.mock.acceptance_review_fixture_response(unrelated_request))
        self.assertIsNone(self.mock.acceptance_review_fixture_response(wrong_path))

    def test_ignores_other_user_prompts(self):
        self.assertIsNone(self.mock.acceptance_review_fixture_response("Say hello"))


if __name__ == "__main__":
    unittest.main()
