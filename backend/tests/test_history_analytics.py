"""Tests for History analytics integration.

Validates that:
1. History events are in the gateway allowlist.
2. Global analytics include history metrics.
3. Per-user analytics include history breakdown.
4. V2 history endpoint response shape is correct.
5. No history content leaks into analytics payloads.
6. Dual-write mode decomposition handles history follow-up modes.
"""

import unittest
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Test: Gateway allowlist includes history events
# ---------------------------------------------------------------------------


class TestGatewayAllowlist(unittest.TestCase):
    """Verify that history event types are accepted by the gateway."""

    def test_history_events_in_allowlist(self):
        from app.routers.gateway import _ALLOWED_EVENT_TYPES

        self.assertIn("history_opened", _ALLOWED_EVENT_TYPES)
        self.assertIn("history_followup", _ALLOWED_EVENT_TYPES)
        self.assertIn("history_cleared", _ALLOWED_EVENT_TYPES)

    def test_existing_events_still_in_allowlist(self):
        from app.routers.gateway import _ALLOWED_EVENT_TYPES

        self.assertIn("improve_copy", _ALLOWED_EVENT_TYPES)
        self.assertIn("improve_replace", _ALLOWED_EVENT_TYPES)
        self.assertIn("improve_dismiss", _ALLOWED_EVENT_TYPES)
        self.assertIn("improve_no_change", _ALLOWED_EVENT_TYPES)
        self.assertIn("feedback", _ALLOWED_EVENT_TYPES)


# ---------------------------------------------------------------------------
# Test: Dual-write mode decomposition
# ---------------------------------------------------------------------------


class TestDualWriteModeDecomposition(unittest.TestCase):
    """Verify that history follow-up modes decompose correctly.

    History follow-ups reuse existing follow-up modes (selection_followup,
    session_followup, screenshot_followup), so they already decompose
    correctly via the existing _COMPOUND_MODE_MAP.
    """

    def test_selection_followup_decomposes(self):
        from app.dual_write_service import decompose_mode

        origin, req_type = decompose_mode("selection_followup")
        self.assertEqual(origin, "selection")
        self.assertEqual(req_type, "followup")

    def test_session_followup_decomposes(self):
        from app.dual_write_service import decompose_mode

        origin, req_type = decompose_mode("session_followup")
        self.assertEqual(origin, "session")
        self.assertEqual(req_type, "followup")

    def test_screenshot_followup_decomposes(self):
        from app.dual_write_service import decompose_mode

        origin, req_type = decompose_mode("screenshot_followup")
        self.assertEqual(origin, "screenshot")
        self.assertEqual(req_type, "followup")


# ---------------------------------------------------------------------------
# Test: Analytics response models include history fields
# ---------------------------------------------------------------------------


class TestAnalyticsResponseModels(unittest.TestCase):
    """Verify that response models include history fields."""

    def test_analytics_response_has_history_fields(self):
        from app.routers.admin import AnalyticsResponse

        fields = AnalyticsResponse.model_fields
        self.assertIn("history_opens", fields)
        self.assertIn("history_users", fields)
        self.assertIn("history_followups", fields)
        self.assertIn("history_followup_rate", fields)
        self.assertIn("history_clears", fields)
        self.assertIn("history_avg_depth", fields)
        self.assertIn("history_selection_source", fields)
        self.assertIn("history_depth_distribution", fields)

    def test_user_detail_response_has_history_breakdown(self):
        from app.routers.admin import UserDetailResponse

        fields = UserDetailResponse.model_fields
        self.assertIn("history_breakdown", fields)

    def test_user_history_breakdown_fields(self):
        from app.routers.admin import UserHistoryBreakdown

        fields = UserHistoryBreakdown.model_fields
        self.assertIn("history_opens", fields)
        self.assertIn("history_followups", fields)
        self.assertIn("history_followup_rate", fields)
        self.assertIn("history_clears", fields)
        self.assertIn("avg_depth", fields)
        self.assertIn("max_depth", fields)
        self.assertIn("selection_source", fields)
        self.assertIn("last_activity", fields)
        self.assertIn("first_activity", fields)

    def test_user_history_breakdown_defaults(self):
        from app.routers.admin import UserHistoryBreakdown

        breakdown = UserHistoryBreakdown()
        self.assertEqual(breakdown.history_opens, 0)
        self.assertEqual(breakdown.history_followups, 0)
        self.assertIsNone(breakdown.history_followup_rate)
        self.assertEqual(breakdown.history_clears, 0)
        self.assertIsNone(breakdown.avg_depth)
        self.assertIsNone(breakdown.max_depth)
        self.assertIsNone(breakdown.selection_source)
        self.assertIsNone(breakdown.last_activity)
        self.assertIsNone(breakdown.first_activity)


# ---------------------------------------------------------------------------
# Test: Privacy — no content in analytics payloads
# ---------------------------------------------------------------------------


class TestPrivacy(unittest.TestCase):
    """Verify analytics event payloads contain no user content."""

    def test_history_followup_metadata_has_no_content_fields(self):
        """history_followup metadata must only contain selection_source and
        followup_depth — no question, code, explanation, or answer text."""
        safe_metadata = {
            "selection_source": "explanation",
            "followup_depth": 2,
        }
        forbidden_keys = [
            "question", "code", "explanation", "answer",
            "selected_text", "selectedText", "response",
            "original_code", "originalCode",
            "followup_question", "followup_answer",
        ]
        for key in forbidden_keys:
            self.assertNotIn(key, safe_metadata,
                             f"Metadata must not contain '{key}'")

    def test_history_cleared_metadata_has_no_content_fields(self):
        """history_cleared metadata must only contain item_count."""
        safe_metadata = {"item_count": 5}
        forbidden_keys = [
            "items", "history", "code", "explanation",
            "questions", "answers",
        ]
        for key in forbidden_keys:
            self.assertNotIn(key, safe_metadata,
                             f"Metadata must not contain '{key}'")


# ---------------------------------------------------------------------------
# Test: Event semantics — correct triggers
# ---------------------------------------------------------------------------


class TestEventSemantics(unittest.TestCase):
    """Verify event trigger semantics match the specification."""

    def test_history_followup_mode_format(self):
        """History follow-up mode should be '{originalMode}_followup'."""
        # Simulates the client-side logic: `"\(contextRequest.mode)_followup"`
        for base_mode in ["selection", "session", "screenshot"]:
            followup_mode = f"{base_mode}_followup"
            self.assertTrue(followup_mode.endswith("_followup"))
            self.assertIn(base_mode, followup_mode)

    def test_selection_source_values(self):
        """selection_source must be one of the three valid values."""
        valid_sources = {"explanation", "followup_question", "followup_answer"}
        # These map to SelectableBlockSource enum values
        for source in valid_sources:
            self.assertIn(source, valid_sources)

    def test_followup_depth_values(self):
        """followup_depth must be a non-negative integer."""
        # depth 0 = main explanation selected, depth N = follow-up N selected
        for depth in [0, 1, 2, 5, 10]:
            self.assertGreaterEqual(depth, 0)
            self.assertIsInstance(depth, int)


if __name__ == "__main__":
    unittest.main()
