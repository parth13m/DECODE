"""Gateway error transport contract tests.

Validates that the gateway router forwards GatewayError.error_type
through to the client in both streaming (SSE) and non-streaming (HTTP)
error responses.

Tests inspect source code directly to avoid Python version import issues,
following the same pattern as test_security.py.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

_BACKEND = Path(__file__).parent.parent
_GATEWAY_PY = (_BACKEND / "app" / "routers" / "gateway.py").read_text(
    encoding="utf-8", errors="replace"
)
_GATEWAY_SERVICE_PY = (_BACKEND / "app" / "gateway_service.py").read_text(
    encoding="utf-8", errors="replace"
)


class TestStreamingErrorContract(unittest.TestCase):
    """Verify SSE error events include error_type."""

    def test_sse_error_includes_error_type(self):
        """The streaming GatewayError catch block must include error_type in SSE JSON."""
        sse_error_lines = [
            line.strip()
            for line in _GATEWAY_PY.splitlines()
            if "error_type" in line and "yield" in line and "json.dumps" in line
        ]
        self.assertTrue(
            len(sse_error_lines) >= 1,
            "Expected at least one SSE yield line with error_type in gateway.py"
        )
        for line in sse_error_lines:
            self.assertIn("exc.error_type", line,
                          f"SSE error yield must use exc.error_type: {line}")

    def test_sse_error_format(self):
        """The SSE error event must contain type, error_type, and message fields."""
        error_dumps = re.findall(
            r"json\.dumps\(\{[^}]*'type':\s*'error'[^}]*\}\)",
            _GATEWAY_PY,
        )
        self.assertTrue(
            len(error_dumps) >= 1,
            "Expected at least one json.dumps with type='error'"
        )
        for dump in error_dumps:
            self.assertIn("'error_type'", dump,
                          f"SSE error JSON must include 'error_type' key: {dump}")
            self.assertIn("'message'", dump,
                          f"SSE error JSON must include 'message' key: {dump}")

    def test_sse_does_not_leak_raw_provider_body(self):
        """SSE error events must not forward raw provider response bodies."""
        error_dumps = re.findall(
            r"json\.dumps\(\{[^}]*'type':\s*'error'[^}]*\}\)",
            _GATEWAY_PY,
        )
        for dump in error_dumps:
            self.assertNotIn("response.text", dump,
                             "SSE error must not include raw provider response body")
            self.assertNotIn("response.json", dump,
                             "SSE error must not include raw provider response JSON")


class TestNonStreamingErrorContract(unittest.TestCase):
    """Verify HTTP error responses include error_type."""

    def test_chat_error_includes_error_type(self):
        """The /chat GatewayError handler must forward exc.error_type."""
        self.assertIn("exc.error_type", _GATEWAY_PY,
                       "gateway.py must reference exc.error_type")

    def test_non_streaming_detail_is_dict(self):
        """HTTPException detail must be a dict (not a plain string) for gateway errors."""
        # Find all HTTPException raises within GatewayError handlers
        gateway_error_blocks = re.findall(
            r'except GatewayError.*?raise HTTPException\([^)]+\)',
            _GATEWAY_PY,
            re.DOTALL,
        )
        self.assertTrue(
            len(gateway_error_blocks) >= 2,
            "Expected at least 2 GatewayError->HTTPException blocks (chat + vision)"
        )
        for block in gateway_error_blocks:
            detail_match = re.search(r'detail=(\{[^}]+\}|"[^"]+")', block)
            self.assertIsNotNone(detail_match,
                                f"Could not find detail= in block")
            detail_val = detail_match.group(1)
            self.assertTrue(
                detail_val.startswith("{"),
                f"HTTPException detail must be a dict, not a string: {detail_val}"
            )

    def test_no_plain_string_detail_in_gateway_errors(self):
        """Gateway error responses must not use plain string detail."""
        # Ensure the old pattern detail="AI service unavailable" is gone
        old_patterns = [
            'detail="AI service unavailable"',
            "detail='AI service unavailable'",
            'detail="Vision service unavailable"',
            "detail='Vision service unavailable'",
        ]
        for pattern in old_patterns:
            self.assertNotIn(pattern, _GATEWAY_PY,
                             f"Old plain-string detail found: {pattern}")


class TestErrorTypePreservation(unittest.TestCase):
    """Verify that error_type values flow from GatewayError to transport."""

    def test_error_type_values_in_gateway_service(self):
        """gateway_service.py must classify errors with known error_type values."""
        expected_types = [
            "api_error", "auth_error", "rate_limit", "server_error",
            "timeout", "network_error", "config_error", "empty_response",
            "stream_error",
        ]
        for error_type in expected_types:
            # Match both keyword arg (error_type="x") and assignment (error_type = "x")
            found = (
                f'"{error_type}"' in _GATEWAY_SERVICE_PY
                and "error_type" in _GATEWAY_SERVICE_PY
            )
            self.assertTrue(
                found,
                f"gateway_service.py must produce error_type '{error_type}'"
            )

    def test_sse_docstring_documents_error_type(self):
        """The SSE event format docstring must document error_type."""
        self.assertIn('"error_type"', _GATEWAY_PY,
                       "gateway.py must document error_type in SSE format")


if __name__ == "__main__":
    unittest.main()
