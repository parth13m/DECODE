#!/usr/bin/env python3
"""Load test for Decode backend after optimization.

Tests concurrent AI requests through the Railway gateway with realistic
request patterns across all modes (explain, followup, improve, enrichment,
compression).
"""

import asyncio
import json
import statistics
import sys
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional

import httpx

BASE_URL = "https://decode-production-9eba.up.railway.app"
TOKEN = "3caa9b9e51d62702ba194fb48b69111d030fda9583af675575bfbbba6c4f87ae"
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

TIMEOUT = 90.0  # seconds per request


# ---------------------------------------------------------------------------
# Request templates — realistic payloads for each mode
# ---------------------------------------------------------------------------

def _chat_payload(mode: str, prompt: str, system: str = "You are a helpful assistant. Reply in 1-2 sentences.") -> dict:
    return {
        "messages": [{"role": "user", "content": prompt}],
        "system_prompt": system,
        "mode": mode,
    }


REQUESTS = [
    # Anthropic-routed (explain, followup, improve, selection, session, screenshot)
    ("explain/selection", _chat_payload("selection", "Explain what this Swift function does: func viewDidLoad() { super.viewDidLoad(); setupUI() }")),
    ("explain/session", _chat_payload("session", "What does this Python class do? class UserService: def get_user(self, id): return self.db.query(User).get(id)")),
    ("followup/selection", _chat_payload("selection_followup", "Can you explain the error handling in more detail?")),
    ("followup/session", _chat_payload("session_followup", "How does the caching work in this function?")),
    ("improve/selection", _chat_payload("selection_improve", "How can I improve this code? def process(data): result = []; for item in data: result.append(item * 2); return result")),
    ("improve/session", _chat_payload("session_improve", "Suggest improvements for this database query pattern.")),
    # Groq-routed (enrichment, compression)
    ("enrichment", _chat_payload("enrichment", "Analyze the purpose and behavior of this module: class AuthService with methods login(), logout(), refresh_token().")),
    ("compression", _chat_payload("compression", "Compress the following investigation into a concise summary: The user explored the authentication flow across three files.")),
]


@dataclass
class RequestResult:
    mode: str
    success: bool
    status_code: int
    latency_ms: float
    error: Optional[str] = None


@dataclass
class TestResults:
    concurrency: int
    results: List[RequestResult] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.results)

    @property
    def successes(self) -> int:
        return sum(1 for r in self.results if r.success)

    @property
    def failures(self) -> int:
        return self.total - self.successes

    @property
    def success_rate(self) -> float:
        return (self.successes / self.total * 100) if self.total else 0

    @property
    def latencies(self) -> List[float]:
        return sorted(r.latency_ms for r in self.results if r.success)

    @property
    def p50(self) -> float:
        lats = self.latencies
        return lats[len(lats) // 2] if lats else 0

    @property
    def p95(self) -> float:
        lats = self.latencies
        idx = int(len(lats) * 0.95)
        return lats[min(idx, len(lats) - 1)] if lats else 0

    @property
    def p99(self) -> float:
        lats = self.latencies
        idx = int(len(lats) * 0.99)
        return lats[min(idx, len(lats) - 1)] if lats else 0

    @property
    def mean(self) -> float:
        lats = self.latencies
        return statistics.mean(lats) if lats else 0

    def error_summary(self) -> Dict[str, int]:
        errors: Dict[str, int] = {}
        for r in self.results:
            if not r.success and r.error:
                errors[r.error] = errors.get(r.error, 0) + 1
        return errors

    def mode_summary(self) -> Dict[str, dict]:
        modes: Dict[str, List[RequestResult]] = {}
        for r in self.results:
            modes.setdefault(r.mode, []).append(r)
        summary = {}
        for mode, results in sorted(modes.items()):
            successes = [r for r in results if r.success]
            lats = sorted(r.latency_ms for r in successes)
            summary[mode] = {
                "total": len(results),
                "success": len(successes),
                "fail": len(results) - len(successes),
                "p50": lats[len(lats) // 2] if lats else 0,
                "p95": lats[int(len(lats) * 0.95)] if lats else 0,
                "errors": [r.error for r in results if not r.success],
            }
        return summary


async def send_request(client: httpx.AsyncClient, mode: str, payload: dict) -> RequestResult:
    """Send a single chat request and measure latency."""
    start = time.monotonic()
    try:
        resp = await client.post(
            f"{BASE_URL}/api/gateway/chat",
            headers=HEADERS,
            json=payload,
            timeout=TIMEOUT,
        )
        latency_ms = (time.monotonic() - start) * 1000
        if resp.status_code == 200:
            return RequestResult(mode=mode, success=True, status_code=200, latency_ms=latency_ms)
        else:
            body = resp.text[:200]
            return RequestResult(
                mode=mode, success=False, status_code=resp.status_code,
                latency_ms=latency_ms, error=f"HTTP {resp.status_code}: {body}",
            )
    except httpx.TimeoutException:
        latency_ms = (time.monotonic() - start) * 1000
        return RequestResult(mode=mode, success=False, status_code=0, latency_ms=latency_ms, error="TIMEOUT")
    except Exception as e:
        latency_ms = (time.monotonic() - start) * 1000
        return RequestResult(mode=mode, success=False, status_code=0, latency_ms=latency_ms, error=str(e)[:200])


async def run_load_test(concurrency: int) -> TestResults:
    """Run load test with N concurrent users, each making one request."""
    print(f"\n{'='*60}")
    print(f"  LOAD TEST: {concurrency} concurrent users")
    print(f"{'='*60}")

    # Each "user" picks a request type in round-robin
    tasks_spec = []
    for i in range(concurrency):
        mode, payload = REQUESTS[i % len(REQUESTS)]
        tasks_spec.append((mode, payload))

    results = TestResults(concurrency=concurrency)

    async with httpx.AsyncClient() as client:
        # Launch all requests simultaneously
        start = time.monotonic()
        tasks = [send_request(client, mode, payload) for mode, payload in tasks_spec]
        completed = await asyncio.gather(*tasks)
        wall_time = time.monotonic() - start

    results.results = list(completed)

    # Print results
    throughput = results.successes / wall_time if wall_time > 0 else 0

    print(f"\n  Results ({wall_time:.1f}s wall time):")
    print(f"  ├── Success rate: {results.success_rate:.1f}% ({results.successes}/{results.total})")
    print(f"  ├── Throughput:   {throughput:.1f} req/s")
    print(f"  ├── p50 latency:  {results.p50:.0f} ms")
    print(f"  ├── p95 latency:  {results.p95:.0f} ms")
    print(f"  ├── p99 latency:  {results.p99:.0f} ms")
    print(f"  └── mean latency: {results.mean:.0f} ms")

    if results.failures > 0:
        print(f"\n  Errors ({results.failures}):")
        for err, count in results.error_summary().items():
            print(f"    • {err} (×{count})")

    print(f"\n  Per-mode breakdown:")
    for mode, stats in results.mode_summary().items():
        status = "✓" if stats["fail"] == 0 else "✗"
        print(f"    {status} {mode:25s}  {stats['success']}/{stats['total']}  p50={stats['p50']:.0f}ms  p95={stats['p95']:.0f}ms")
        if stats["errors"]:
            for e in stats["errors"][:2]:
                print(f"      └── {e[:100]}")

    return results


async def main():
    levels = [20, 30]

    all_results = {}

    for n in levels:
        result = await run_load_test(n)
        all_results[n] = result
        # Brief pause between test levels
        if n != levels[-1]:
            print(f"\n  ⏳ Cooling down 10s before next test level...")
            await asyncio.sleep(10)

    # If 30-user test passed comfortably (≥95% success, p95 < 30s), run 40
    r30 = all_results.get(30)
    if r30 and r30.success_rate >= 95 and r30.p95 < 30000:
        print(f"\n  ⏳ 30-user test passed comfortably. Cooling down 10s before 40-user test...")
        await asyncio.sleep(10)
        result = await run_load_test(40)
        all_results[40] = result
    else:
        print(f"\n  ⚠️  30-user test did not pass comfortably (success={r30.success_rate:.0f}%, p95={r30.p95:.0f}ms). Skipping 40-user test.")

    # Final summary
    print(f"\n{'='*60}")
    print(f"  FINAL SUMMARY")
    print(f"{'='*60}")
    for n, r in sorted(all_results.items()):
        # Separate Groq failures from capacity failures
        groq_modes = {"enrichment", "compression"}
        groq_fails = sum(1 for res in r.results if not res.success and res.mode in groq_modes)
        anthropic_fails = sum(1 for res in r.results if not res.success and res.mode not in groq_modes)
        total_groq = sum(1 for res in r.results if res.mode in groq_modes)
        total_anthropic = r.total - total_groq

        # Anthropic success rate (the real capacity metric)
        anthropic_success = total_anthropic - anthropic_fails
        anthropic_rate = (anthropic_success / total_anthropic * 100) if total_anthropic else 0

        verdict = "PASS" if anthropic_rate >= 95 and r.p95 < 30000 else "FAIL"
        if groq_fails > 0:
            groq_note = f" [Groq: {total_groq - groq_fails}/{total_groq}]"
        else:
            groq_note = ""

        print(f"  {n:2d} users → {verdict}  (success={r.success_rate:.0f}%, anthropic={anthropic_rate:.0f}%, p95={r.p95:.0f}ms){groq_note}")


if __name__ == "__main__":
    asyncio.run(main())
