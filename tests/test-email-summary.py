#!/usr/bin/env python3
"""Tests for email-summary.py auto-summary generation (t1053.7).

Tests the heuristic summariser with various email lengths and formats.
LLM (Ollama) tests are skipped when Ollama is not available.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add scripts directory to path for imports
SCRIPTS_DIR = Path(__file__).parent.parent / ".agents" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

# Dynamic import (filename has hyphens)
import importlib.util

spec = importlib.util.spec_from_file_location(
    "email_summary", SCRIPTS_DIR / "email-summary.py"
)
email_summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(email_summary)


class TestWordCount(unittest.TestCase):
    """Test word_count helper."""

    def test_empty(self):
        self.assertEqual(email_summary.word_count(""), 0)
        self.assertEqual(email_summary.word_count(None), 0)

    def test_short(self):
        self.assertEqual(email_summary.word_count("Hello world"), 2)

    def test_multiline(self):
        text = "Hello world\nThis is a test\nThird line"
        self.assertEqual(email_summary.word_count(text), 8)


class TestStripMarkdown(unittest.TestCase):
    """Test _strip_markdown helper."""

    def test_links(self):
        result = email_summary._strip_markdown("[Click here](https://example.com)")
        self.assertEqual(result, "Click here")

    def test_images(self):
        result = email_summary._strip_markdown("![Alt text](image.png)")
        self.assertEqual(result, "Alt text")

    def test_emphasis(self):
        result = email_summary._strip_markdown("This is **bold** and *italic*")
        self.assertNotIn("**", result)
        self.assertNotIn("*", result)

    def test_headings(self):
        result = email_summary._strip_markdown("## Heading\nContent here")
        self.assertNotIn("##", result)
        self.assertIn("Content here", result)

    def test_code_blocks(self):
        result = email_summary._strip_markdown("Before ```code block``` after")
        self.assertIn("Before", result)
        self.assertIn("after", result)


class TestStripSignature(unittest.TestCase):
    """Test _strip_signature helper."""

    def test_standard_delimiter(self):
        text = "Main content of the email here.\n\n--\nJohn Smith\nCEO, Acme Corp"
        result = email_summary._strip_signature(text)
        self.assertIn("Main content", result)
        self.assertNotIn("John Smith", result)

    def test_best_regards(self):
        text = "Please review the attached document and let me know your thoughts.\n\nBest regards,\nJane Doe"
        result = email_summary._strip_signature(text)
        self.assertIn("review the attached", result)
        self.assertNotIn("Jane Doe", result)

    def test_no_signature(self):
        text = "This is a short email with no signature."
        result = email_summary._strip_signature(text)
        self.assertEqual(result, text)

    def test_signature_only_stripped_if_in_last_40_percent(self):
        # Signature marker early in text should NOT be stripped
        text = "First line.\n\nBest regards,\nName\n\n" + "More content. " * 50
        result = email_summary._strip_signature(text)
        # The signature is in the first part, so it should be preserved
        self.assertIn("More content", result)


class TestExtractFirstSentences(unittest.TestCase):
    """Test _extract_first_sentences helper."""

    def test_single_sentence(self):
        text = "This is a single sentence."
        result = email_summary._extract_first_sentences(text, max_sentences=2)
        self.assertEqual(result, "This is a single sentence.")

    def test_two_sentences(self):
        text = "First sentence here. Second sentence follows. Third one too."
        result = email_summary._extract_first_sentences(text, max_sentences=2)
        self.assertIn("First sentence", result)
        self.assertIn("Second sentence", result)

    def test_abbreviations_not_split(self):
        text = "Dr. Smith visited the office. He brought documents."
        result = email_summary._extract_first_sentences(text, max_sentences=2)
        # Should not split at "Dr."
        self.assertIn("Dr. Smith", result)

    def test_truncation(self):
        text = "A " * 200  # Very long single "sentence"
        result = email_summary._extract_first_sentences(text, max_sentences=2)
        self.assertLessEqual(len(result), email_summary.MAX_DESCRIPTION_LEN + 3)  # +3 for "..."


class TestSummariseHeuristic(unittest.TestCase):
    """Test the heuristic summariser."""

    def test_short_email(self):
        body = "Hi team, the meeting is moved to 3pm tomorrow. Please update your calendars."
        result = email_summary.summarise_heuristic(body)
        self.assertIn("meeting", result)
        self.assertGreater(len(result), 10)

    def test_empty_body(self):
        self.assertEqual(email_summary.summarise_heuristic(""), "")
        self.assertEqual(email_summary.summarise_heuristic(None), "")

    def test_markdown_stripped(self):
        body = "**Important:** Please [review](https://example.com) the *attached* document."
        result = email_summary.summarise_heuristic(body)
        self.assertNotIn("**", result)
        self.assertNotIn("[", result)
        self.assertIn("review", result)

    def test_signature_stripped(self):
        body = "Please confirm the delivery date for order #12345.\n\nBest regards,\nJohn Smith\nSales Manager"
        result = email_summary.summarise_heuristic(body)
        self.assertIn("delivery date", result)
        self.assertNotIn("Sales Manager", result)


class TestGenerateSummary(unittest.TestCase):
    """Test the main generate_summary function."""

    def test_heuristic_method(self):
        body = "The quarterly report is ready for review."
        result = email_summary.generate_summary(body, method="heuristic")
        self.assertIn("quarterly report", result)

    def test_auto_short_email_uses_heuristic(self):
        # Under 100 words — should use heuristic
        body = "Please send me the invoice for last month."
        result = email_summary.generate_summary(body, method="auto")
        self.assertGreater(len(result), 0)

    def test_auto_long_email_falls_back_to_heuristic(self):
        # Over 100 words — would try LLM but falls back to heuristic
        body = "Word " * 150 + "Final sentence here."
        result = email_summary.generate_summary(body, method="auto")
        self.assertGreater(len(result), 0)

    def test_empty_body(self):
        self.assertEqual(email_summary.generate_summary(""), "")
        self.assertEqual(email_summary.generate_summary(None), "")


class TestUpdateDescription(unittest.TestCase):
    """Test frontmatter description update."""

    def test_update_existing_description(self):
        content = """---
title: Test Email
description: old description
from: test@example.com
---

This is the email body with important information about the project deadline."""

        with tempfile.NamedTemporaryFile(mode='w', suffix='.md',
                                          delete=False) as f:
            f.write(content)
            f.flush()
            tmp_path = f.name

        try:
            result = email_summary.update_description(tmp_path, method="heuristic")
            self.assertTrue(result)

            updated = Path(tmp_path).read_text()
            self.assertNotIn("old description", updated)
            self.assertIn("description:", updated)
            # Should contain something from the body
            self.assertIn("project deadline", updated.split("---")[1])
        finally:
            os.unlink(tmp_path)

    def test_add_description_when_missing(self):
        content = """---
title: Test Email
from: test@example.com
---

Short email body here."""

        with tempfile.NamedTemporaryFile(mode='w', suffix='.md',
                                          delete=False) as f:
            f.write(content)
            f.flush()
            tmp_path = f.name

        try:
            result = email_summary.update_description(tmp_path, method="heuristic")
            self.assertTrue(result)

            updated = Path(tmp_path).read_text()
            self.assertIn("description:", updated)
        finally:
            os.unlink(tmp_path)

    def test_no_frontmatter(self):
        content = "Just plain text, no frontmatter."

        with tempfile.NamedTemporaryFile(mode='w', suffix='.md',
                                          delete=False) as f:
            f.write(content)
            f.flush()
            tmp_path = f.name

        try:
            result = email_summary.update_description(tmp_path, method="heuristic")
            self.assertFalse(result)
        finally:
            os.unlink(tmp_path)


class TestYamlEscape(unittest.TestCase):
    """Test YAML escaping."""

    def test_simple_string(self):
        result = email_summary._yaml_escape("simple text")
        self.assertEqual(result, "simple text")

    def test_colon_in_string(self):
        result = email_summary._yaml_escape("key: value")
        self.assertTrue(result.startswith('"'))
        self.assertTrue(result.endswith('"'))

    def test_empty_string(self):
        self.assertEqual(email_summary._yaml_escape(""), '""')
        self.assertEqual(email_summary._yaml_escape(None), '""')

    def test_quotes_escaped(self):
        result = email_summary._yaml_escape('He said "hello"')
        self.assertIn('\\"', result)


class TestParseSummaryResponse(unittest.TestCase):
    """Test LLM response parsing."""

    def test_clean_response(self):
        result = email_summary._parse_summary_response(
            "The sender requests a meeting to discuss Q4 results."
        )
        self.assertEqual(result, "The sender requests a meeting to discuss Q4 results.")

    def test_quoted_response(self):
        result = email_summary._parse_summary_response(
            '"The sender requests a meeting."'
        )
        self.assertEqual(result, "The sender requests a meeting.")

    def test_preamble_stripped(self):
        result = email_summary._parse_summary_response(
            "Here is a summary: The project deadline has been extended."
        )
        self.assertEqual(result, "The project deadline has been extended.")

    def test_long_response_truncated(self):
        long_text = "Word " * 100
        result = email_summary._parse_summary_response(long_text)
        self.assertLessEqual(len(result), email_summary.MAX_DESCRIPTION_LEN + 3)


class TestIntegrationWithEmailToMarkdown(unittest.TestCase):
    """Test that email-to-markdown.py correctly uses auto-summary."""

    def test_run_auto_summary_import(self):
        """Verify run_auto_summary can import and use email-summary module."""
        # Import email-to-markdown dynamically
        spec2 = importlib.util.spec_from_file_location(
            "email_to_markdown", SCRIPTS_DIR / "email-to-markdown.py"
        )
        etm = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(etm)

        body = "Please review the attached contract and sign by Friday."
        result = etm.run_auto_summary(body, method="heuristic")
        self.assertIn("contract", result)
        self.assertGreater(len(result), 10)

    def test_make_description_still_works(self):
        """Verify backward compat: make_description unchanged."""
        spec2 = importlib.util.spec_from_file_location(
            "email_to_markdown_compat", SCRIPTS_DIR / "email-to-markdown.py"
        )
        etm = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(etm)

        body = "Short body text."
        result = etm.make_description(body)
        self.assertEqual(result, "Short body text.")


if __name__ == "__main__":
    unittest.main()
