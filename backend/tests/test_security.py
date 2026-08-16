"""Security regression tests.

Validates security properties by inspecting source files directly.
This avoids runtime import issues with Python version mismatches
(codebase uses 3.10+ syntax) while still catching regressions.

Tests:
1. No hardcoded credentials in source files.
2. Admin token comparison uses constant-time equality.
3. Admin login logs do not leak token metadata.
4. Payload size limits are declared on request models.
5. Rate limit decorators on security-sensitive endpoints.
6. Auth dependencies on gateway/admin/analytics routers.
"""

import re
import unittest
from pathlib import Path

_BACKEND = Path(__file__).parent.parent
_APP = _BACKEND / "app"


def _read(rel_path: str) -> str:
    return (_BACKEND / rel_path).read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# 1. No hardcoded credentials
# ---------------------------------------------------------------------------


class TestNoHardcodedCredentials(unittest.TestCase):
    """Verify that no production tokens or API keys are hardcoded."""

    def test_load_test_has_no_hardcoded_token(self):
        path = _BACKEND / "load_test.py"
        if not path.exists():
            self.skipTest("load_test.py not found")
        content = path.read_text()
        hex_tokens = re.findall(r'["\'][0-9a-f]{64,}["\']', content)
        self.assertEqual(hex_tokens, [],
                         f"Hardcoded token(s) in load_test.py: {hex_tokens}")

    def test_load_test_reads_from_env(self):
        path = _BACKEND / "load_test.py"
        if not path.exists():
            self.skipTest("load_test.py not found")
        content = path.read_text()
        self.assertIn("os.environ", content,
                       "load_test.py must read TOKEN from environment")

    def test_no_api_keys_in_app_source(self):
        patterns = [
            re.compile(r'sk-ant-[a-zA-Z0-9_-]{20,}'),
            re.compile(r'sk-[a-zA-Z0-9]{20,}'),
            re.compile(r'gsk_[a-zA-Z0-9]{20,}'),
        ]
        for py_file in _APP.rglob("*.py"):
            content = py_file.read_text(encoding="utf-8", errors="replace")
            for pattern in patterns:
                matches = pattern.findall(content)
                self.assertEqual(matches, [],
                                 f"API key pattern in {py_file.name}: {matches}")


# ---------------------------------------------------------------------------
# 2. Admin token uses constant-time comparison
# ---------------------------------------------------------------------------


class TestAdminTokenSecurity(unittest.TestCase):
    """Verify require_admin uses secrets.compare_digest."""

    def setUp(self):
        self.source = _read("app/auth.py")

    def test_uses_constant_time_comparison(self):
        self.assertIn("secrets.compare_digest", self.source,
                       "require_admin must use secrets.compare_digest")

    def test_no_plain_inequality(self):
        # Extract the require_admin function body
        match = re.search(
            r'def require_admin\(.*?\n(?=\ndef |\Z)',
            self.source, re.DOTALL,
        )
        self.assertIsNotNone(match, "require_admin function not found")
        body = match.group(0)
        self.assertNotIn("credentials.credentials !=", body,
                         "require_admin must not use != for token comparison")
        self.assertNotIn("credentials.credentials ==", body,
                         "require_admin must not use == for token comparison")


# ---------------------------------------------------------------------------
# 3. Admin login logs don't leak token metadata
# ---------------------------------------------------------------------------


class TestAdminLogSecurity(unittest.TestCase):
    """Verify admin failure logs don't reveal token length."""

    def setUp(self):
        self.source = _read("app/auth.py")

    def test_no_length_in_log(self):
        # Extract require_admin body
        match = re.search(
            r'def require_admin\(.*?\n(?=\ndef |\Z)',
            self.source, re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group(0)
        self.assertNotIn("provided length", body,
                         "Must not log provided token length")
        self.assertNotIn("expected length", body,
                         "Must not log expected token length")
        self.assertNotIn("len(credentials", body,
                         "Must not log any token length")
        self.assertNotIn("len(settings.ADMIN_TOKEN)", body,
                         "Must not log admin token length")


# ---------------------------------------------------------------------------
# 4. Payload size limits on request models
# ---------------------------------------------------------------------------


class TestPayloadLimits(unittest.TestCase):
    """Verify that gateway request models have max_length constraints."""

    def setUp(self):
        self.source = _read("app/routers/gateway.py")

    def test_chat_message_content_has_max_length(self):
        # ChatMessage.content should have max_length
        match = re.search(r'class ChatMessage.*?(?=\nclass )', self.source, re.DOTALL)
        self.assertIsNotNone(match, "ChatMessage class not found")
        self.assertIn("max_length", match.group(0),
                       "ChatMessage.content must have max_length")

    def test_chat_request_messages_has_max_length(self):
        match = re.search(r'class ChatRequest.*?(?=\nclass )', self.source, re.DOTALL)
        self.assertIsNotNone(match, "ChatRequest class not found")
        self.assertIn("max_length", match.group(0),
                       "ChatRequest.messages must have max_length")

    def test_vision_image_data_has_max_length(self):
        match = re.search(r'class VisionRequest.*?(?=\nclass )', self.source, re.DOTALL)
        self.assertIsNotNone(match, "VisionRequest class not found")
        self.assertIn("max_length", match.group(0),
                       "VisionRequest.image_data must have max_length")

    def test_system_prompt_has_max_length(self):
        match = re.search(r'class ChatRequest.*?(?=\nclass )', self.source, re.DOTALL)
        self.assertIsNotNone(match)
        body = match.group(0)
        # system_prompt line should have max_length
        sp_line = [l for l in body.split("\n") if "system_prompt" in l]
        self.assertTrue(sp_line, "system_prompt field not found")
        self.assertIn("max_length", sp_line[0],
                       "system_prompt must have max_length")

    def test_profile_data_has_size_validation(self):
        # ProfileSyncRequest should have a validator or max_length on profile_data
        match = re.search(
            r'class ProfileSyncRequest.*?(?=\n(?:class |@router|# ----))',
            self.source, re.DOTALL,
        )
        self.assertIsNotNone(match, "ProfileSyncRequest class not found")
        body = match.group(0)
        has_validator = "field_validator" in body or "validator" in body or "max_length" in body
        self.assertTrue(has_validator,
                        "ProfileSyncRequest.profile_data must have size validation")

    def test_analytics_metadata_has_size_validation(self):
        match = re.search(
            r'class AnalyticsEventRequest.*?(?=\n(?:class |@router|# ----))',
            self.source, re.DOTALL,
        )
        self.assertIsNotNone(match, "AnalyticsEventRequest class not found")
        body = match.group(0)
        has_validator = "field_validator" in body or "validator" in body or "_cap_metadata" in body
        self.assertTrue(has_validator,
                        "AnalyticsEventRequest.metadata must have size validation")


# ---------------------------------------------------------------------------
# 5. Rate limit decorators on sensitive endpoints
# ---------------------------------------------------------------------------


class TestRateLimitDecorators(unittest.TestCase):
    """Verify that rate-limit decorators are present on expensive endpoints."""

    def _has_limiter_before(self, source: str, func_name: str) -> bool:
        """Check if @limiter.limit appears in the 3 lines before def func_name."""
        lines = source.split("\n")
        for i, line in enumerate(lines):
            if f"def {func_name}(" in line:
                context = "\n".join(lines[max(0, i - 3):i + 1])
                return "@limiter.limit" in context
        return False

    def test_chat_has_rate_limit(self):
        src = _read("app/routers/gateway.py")
        self.assertTrue(self._has_limiter_before(src, "chat"),
                        "chat endpoint must have @limiter.limit decorator")

    def test_chat_stream_has_rate_limit(self):
        src = _read("app/routers/gateway.py")
        self.assertTrue(self._has_limiter_before(src, "chat_stream"),
                        "chat_stream endpoint must have @limiter.limit decorator")

    def test_vision_has_rate_limit(self):
        src = _read("app/routers/gateway.py")
        self.assertTrue(self._has_limiter_before(src, "vision"),
                        "vision endpoint must have @limiter.limit decorator")

    def test_activate_has_rate_limit(self):
        src = _read("app/routers/auth.py")
        self.assertTrue(self._has_limiter_before(src, "activate_invite"),
                        "activate_invite must have @limiter.limit decorator")


# ---------------------------------------------------------------------------
# 6. Auth dependencies on routers
# ---------------------------------------------------------------------------


class TestRouterAuthDependencies(unittest.TestCase):
    """Verify router-level auth dependencies."""

    def test_gateway_endpoints_require_user_auth(self):
        src = _read("app/routers/gateway.py")
        self.assertIn("get_current_user", src,
                       "Gateway endpoints must use get_current_user")

    def test_admin_router_requires_admin(self):
        src = _read("app/routers/admin.py")
        self.assertIn("dependencies=[Depends(require_admin)]", src,
                       "Admin router must have require_admin dependency")

    def test_analytics_v2_router_requires_admin(self):
        src = _read("app/routers/analytics_v2.py")
        self.assertIn("dependencies=[Depends(require_admin)]", src,
                       "Analytics V2 router must have require_admin dependency")


# ---------------------------------------------------------------------------
# 7. Rate limit module exists
# ---------------------------------------------------------------------------


class TestRateLimitModule(unittest.TestCase):
    """Verify the rate limit module exists and is imported."""

    def test_rate_limit_module_exists(self):
        self.assertTrue((_APP / "rate_limit.py").exists(),
                        "app/rate_limit.py must exist")

    def test_main_imports_limiter(self):
        src = _read("app/main.py")
        self.assertIn("from app.rate_limit import limiter", src,
                       "main.py must import limiter from rate_limit module")

    def test_main_registers_rate_limit_handler(self):
        src = _read("app/main.py")
        self.assertIn("RateLimitExceeded", src,
                       "main.py must handle RateLimitExceeded")


if __name__ == "__main__":
    unittest.main()
