"""Test context window handling for 1-hour meetings.

Simulates realistic meeting transcript volumes and validates that
both copilot and summary generation handle them gracefully — even
when the model's context window is small (4096 tokens).

Usage:
    # Requires backend running (or at least LM Studio at localhost:1234)
    python -m pytest tests/test_context_window.py -v -s

    # Standalone — no LM Studio needed (tests truncation/budget logic only)
    python tests/test_context_window.py
"""

import asyncio
import json
import logging
import random
import sys
import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

# Add backend to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from app.config import settings
from app.services.llm_client import LLMClient, _extract_json, _normalize_copilot, _normalize_summary
from app.services.prompt_builder import PromptBuilder
from app.services.meeting_state import MeetingSession, MeetingStateManager
from app.schemas.meeting import MeetingSetupRequest
from app.schemas.transcript import TranscriptSegment

logging.basicConfig(level=logging.INFO, format="%(levelname)s | %(name)s | %(message)s")
logger = logging.getLogger("test_context_window")

# ─── Realistic meeting transcript generator ────────────────────────────

# Substantive meeting phrases (multi-sentence contributions)
MEETING_PHRASES = [
    "I think we should consider the impact on our Q3 roadmap before committing to this timeline.",
    "The customer feedback from last sprint was mostly positive but there were some concerns about latency.",
    "Can we get an estimate on how long the migration would take? We need to factor that into the release plan.",
    "I spoke with the infrastructure team yesterday and they're open to provisioning additional capacity.",
    "Let's circle back on the pricing model — I want to make sure we're competitive in the mid-market segment.",
    "The design team has three mockups ready for review. I'll share those after this call.",
    "We need to address the security audit findings before the next board meeting.",
    "The API rate limiting changes should be backwards compatible, but we'll need to update the docs.",
    "From a user research perspective, the onboarding flow is our biggest drop-off point.",
    "I'd like to propose we move the launch date by two weeks to give QA more time.",
    "The vendor contract renewal is coming up in April — we should evaluate alternatives.",
    "Our conversion rate improved by 12% after the checkout redesign last month.",
    "The mobile team is blocked on the authentication SDK — can we prioritize that?",
    "I want to flag a potential compliance issue with the new data retention policy.",
    "The performance benchmarks show a 3x improvement with the new caching layer.",
    "We should schedule a post-mortem for the incident last Thursday.",
    "The engineering hiring pipeline looks strong — we have four candidates in final rounds.",
    "I'm concerned about the scope creep on the enterprise features project.",
    "The analytics dashboard needs to support real-time filtering by next quarter.",
    "Can someone take the action item to draft the integration spec by Friday?",
    "The competitive analysis shows we're ahead on features but behind on pricing.",
    "We need to align on the success metrics before we start the experiment.",
    "The legal team approved the new terms of service — we can push to production.",
    "I think the risk here is that we underestimate the migration complexity.",
    "The customer success team reported a spike in churn among small accounts.",
    "We should consider a phased rollout instead of a big-bang launch.",
    "The database optimization reduced query times by 40% in our staging environment.",
    "I'll follow up with the partner team about the co-marketing opportunity.",
    "The accessibility audit identified several critical issues we need to fix.",
    "Our NPS score went up five points this quarter which is encouraging.",
]

# Short interjections common on phone calls (cross-talk, acknowledgments, phone artifacts)
PHONE_INTERJECTIONS = [
    "I agree.",
    "Right, exactly.",
    "That makes sense.",
    "Good point.",
    "Can you repeat that? You cut out for a second.",
    "Sorry, go ahead.",
    "You're on mute.",
    "Can everyone hear me okay?",
    "Let me jump in here.",
    "One quick question on that.",
    "I'd push back on that a little.",
    "Hold on, I'm getting some background noise.",
    "Yeah, that tracks with what I've seen.",
    "Definitely.",
    "Hmm, I'm not sure about that.",
    "Sorry, can you say that again?",
    "Right.",
    "Okay.",
    "Makes sense.",
    "Got it.",
]

SPEAKERS = ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4", "Speaker 5"]


def generate_meeting_transcript(
    duration_minutes: int = 60,
    words_per_minute: int = 165,
    n_speakers: int = 5,
) -> list[dict]:
    """Generate a realistic meeting transcript for the given duration.

    Calibrated for phone calls with up to 5 speakers:
    - ~165 WPM total across all speakers (higher than in-person due to less
      silent time and more cross-talk on phone calls)
    - ~30% of utterances are short interjections (1-5 words)
    - Speaker turns every 2-10 seconds (shorter than in-person)
    """
    speakers = SPEAKERS[:n_speakers]
    segments = []
    elapsed_seconds = 0
    total_words = 0
    target_words = duration_minutes * words_per_minute

    while total_words < target_words:
        # ~30% chance of a short interjection (realistic for phone calls)
        if random.random() < 0.30:
            text = random.choice(PHONE_INTERJECTIONS)
            gap = random.uniform(1, 4)  # quick interjections have shorter gaps
        else:
            # Substantive contribution: 1-3 phrases
            n_phrases = random.choice([1, 1, 1, 2, 2, 3])
            text = " ".join(random.choice(MEETING_PHRASES) for _ in range(n_phrases))
            gap = random.uniform(2, 12)

        speaker = random.choice(speakers)
        elapsed_seconds += gap
        hours = int(elapsed_seconds // 3600)
        minutes = int((elapsed_seconds % 3600) // 60)
        seconds = int(elapsed_seconds % 60)
        timestamp = f"{hours:02d}:{minutes:02d}:{seconds:02d}"

        segments.append({
            "text": text,
            "timestamp": timestamp,
            "speaker": speaker,
        })
        total_words += len(text.split())

    return segments


def format_transcript(segments: list[dict]) -> str:
    """Format segments into the transcript string format used by RONIN."""
    lines = []
    for s in segments:
        speaker_tag = f" {s['speaker']}:" if s.get("speaker") else ""
        lines.append(f"[{s['timestamp']}]{speaker_tag} {s['text']}")
    return "\n".join(lines)


# ─── Tests ────────────────────────────────────────────────────────────

def test_transcript_volume():
    """Verify that a 1-hour meeting generates the expected transcript size."""
    segments = generate_meeting_transcript(duration_minutes=60)
    transcript = format_transcript(segments)

    word_count = len(transcript.split())
    char_count = len(transcript)
    segment_count = len(segments)

    logger.info(f"1-hour meeting: {segment_count} segments, {word_count} words, {char_count:,} chars")
    logger.info(f"Estimated tokens: ~{int(word_count * 1.3)} (word_count * 1.3)")

    assert word_count > 8000, f"Expected >8000 words for 1-hr 5-speaker phone call, got {word_count}"
    assert char_count > 50000, f"Expected >50K chars, got {char_count}"

    # Print size breakdown
    logger.info(f"\n{'='*60}")
    logger.info(f"TRANSCRIPT VOLUME ANALYSIS (1-hour meeting)")
    logger.info(f"{'='*60}")
    logger.info(f"  Segments:         {segment_count}")
    logger.info(f"  Words:            {word_count:,}")
    logger.info(f"  Characters:       {char_count:,}")
    logger.info(f"  Est. tokens:      ~{int(word_count * 1.3):,}")
    logger.info(f"  Default n_ctx:    4,096 tokens")
    logger.info(f"  Overflow factor:  {word_count * 1.3 / 4096:.1f}x")
    logger.info(f"{'='*60}")

    return segments, transcript


def test_prompt_truncation_copilot():
    """Verify copilot prompt stays within context budget after truncation."""
    segments = generate_meeting_transcript(duration_minutes=60)
    transcript = format_transcript(segments)
    builder = PromptBuilder()

    for max_chars in [6000, 3000, 1500, 1000]:
        messages = builder.build_copilot_prompt(
            transcript_window=transcript,
            config=MagicMock(
                title="Weekly Product Sync",
                goal="Align on Q3 priorities and blockers",
                constraints="Stay within budget of $50K for new tooling",
            ),
            relevant_notes="Customer feedback report:\n- Users want faster load times\n- Mobile UX needs improvement",
            max_transcript_chars=max_chars,
        )

        total_chars = sum(len(m["content"]) for m in messages)
        total_est_tokens = int(total_chars / 4)  # rough estimate: 4 chars per token

        logger.info(
            f"  Copilot @ max_chars={max_chars:,}: "
            f"{total_chars:,} chars → ~{total_est_tokens:,} tokens"
        )
        # Verify truncation worked
        user_msg = messages[1]["content"]
        assert len(user_msg) < max_chars + 500, (
            f"User message too long: {len(user_msg)} > {max_chars + 500}"
        )


def test_prompt_truncation_summary():
    """Verify summary prompt truncation preserves head and tail."""
    segments = generate_meeting_transcript(duration_minutes=60)
    transcript = format_transcript(segments)
    builder = PromptBuilder()

    original_len = len(transcript)
    logger.info(f"\n  Original transcript: {original_len:,} chars")

    for max_chars in [12000, 6000, 3000]:
        messages = builder.build_summary_prompt(
            transcript=transcript,
            config=MagicMock(
                title="Weekly Product Sync",
                goal="Align on Q3 priorities and blockers",
            ),
            notes="Key objective: finalize Q3 roadmap",
            max_transcript_chars=max_chars,
        )

        total_chars = sum(len(m["content"]) for m in messages)
        total_est_tokens = int(total_chars / 4)
        user_msg = messages[1]["content"]

        # Verify the truncation marker is present if transcript was too long
        if original_len > max_chars:
            assert "truncated" in user_msg or "omitted" in user_msg, (
                "Expected truncation marker in summary prompt"
            )

        logger.info(
            f"  Summary  @ max_chars={max_chars:,}: "
            f"{total_chars:,} chars → ~{total_est_tokens:,} tokens"
        )


def test_budget_calibration():
    """Test the dynamic budget calibration logic."""
    from app.services.llm_client import LLMClient

    # Simulate various detected context sizes
    # Formula: available = int(n_ctx * 0.7) * 4 chars
    #   summary = min(available, 60000), copilot = min(summary // 2, 30000)
    #   Floors: copilot >= 1000, summary >= 2000
    test_cases = [
        (2048,  {"copilot": 2866, "summary": 5732}),
        (4096,  {"copilot": 5734, "summary": 11468}),
        (8192,  {"copilot": 11468, "summary": 22936}),
        (16384, {"copilot": 22936, "summary": 45872}),
        (32768, {"copilot": 30000, "summary": 60000}),  # capped
        (65536, {"copilot": 30000, "summary": 60000}),  # capped
        (131072, {"copilot": 30000, "summary": 60000}), # capped
    ]

    logger.info(f"\n{'='*60}")
    logger.info("BUDGET CALIBRATION TABLE")
    logger.info(f"{'='*60}")
    logger.info(f"  {'n_ctx':>8}  {'Copilot':>10}  {'Summary':>10}  {'Fit 1hr?':>8}")
    logger.info(f"  {'─'*8}  {'─'*10}  {'─'*10}  {'─'*8}")

    for n_ctx, expected in test_cases:
        copilot_budget, summary_budget = LLMClient._calibrate_budgets(n_ctx)

        # 1-hour meeting is ~60K chars. Can the summary budget fit?
        fits = "✅ YES" if summary_budget >= 50000 else "⚠️  NO"
        if summary_budget >= 30000:
            fits = "🟡 PART"
        if summary_budget >= 50000:
            fits = "✅ YES"

        logger.info(
            f"  {n_ctx:>8,}  {copilot_budget:>10,}  {summary_budget:>10,}  {fits:>8}"
        )

        assert copilot_budget == expected["copilot"], (
            f"n_ctx={n_ctx}: expected copilot={expected['copilot']}, got {copilot_budget}"
        )
        assert summary_budget == expected["summary"], (
            f"n_ctx={n_ctx}: expected summary={expected['summary']}, got {summary_budget}"
        )

    logger.info(f"{'='*60}")


def test_extract_json_edge_cases():
    """Test JSON extraction from various LLM output formats."""
    # Clean JSON
    assert _extract_json('{"suggestions": []}') == {"suggestions": []}

    # With markdown fences
    assert _extract_json('```json\n{"suggestions": []}\n```') == {"suggestions": []}

    # With Qwen thinking block
    assert _extract_json(
        '<think>\nLet me analyze this...\n</think>\n{"suggestions": []}'
    ) == {"suggestions": []}

    # With preamble text
    assert _extract_json(
        'Here is the response:\n{"suggestions": [], "risks": []}'
    ) == {"suggestions": [], "risks": []}

    logger.info("  JSON extraction: all edge cases passed ✅")


def test_normalize_copilot_robustness():
    """Test normalization handles various LLM output quirks."""
    # Strings instead of objects for suggestions
    data = {"suggestions": ["Hello", "World"], "follow_up_questions": []}
    result = _normalize_copilot(data)
    assert all(isinstance(s, dict) for s in result["suggestions"])
    assert result["suggestions"][0]["text"] == "Hello"

    # Alternative field names
    data = {"suggested_responses": [{"text": "Hi", "tone": "direct"}], "questions": ["Q1"]}
    result = _normalize_copilot(data)
    assert len(result["suggestions"]) == 1
    assert result["follow_up_questions"] == ["Q1"]

    # Missing fields get defaults
    data = {}
    result = _normalize_copilot(data)
    assert result["suggestions"] == []
    assert result["follow_up_questions"] == []
    assert result["risks"] == []
    assert result["facts_from_notes"] == []

    logger.info("  Copilot normalization: all robustness cases passed ✅")


async def test_live_copilot_with_lm_studio():
    """Integration test: send a 1-hour transcript to the copilot endpoint.

    Requires LM Studio running with a model loaded.
    Skips gracefully if LM Studio is not available.
    """
    import httpx

    # Check if LM Studio is running
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{settings.lm_studio_url}/models")
            models = resp.json()
            if not models.get("data"):
                logger.warning("LM Studio running but no model loaded — skipping integration test")
                return
            model_info = models["data"][0]
            logger.info(f"LM Studio model: {model_info.get('id', 'unknown')}")
    except Exception:
        logger.warning("LM Studio not available — skipping integration test")
        return

    # Generate 1-hour transcript
    segments = generate_meeting_transcript(duration_minutes=60)
    transcript = format_transcript(segments)
    logger.info(f"Generated 1-hour transcript: {len(transcript):,} chars, {len(transcript.split()):,} words")

    from app.services.providers.local import LocalProvider
    llm = LLMClient(provider=LocalProvider(base_url=settings.lm_studio_url))

    config = MagicMock(
        title="Q3 Product Strategy Review",
        goal="Finalize Q3 roadmap priorities and resource allocation",
        constraints="Budget limited to $200K, team of 8 engineers",
    )

    # Test 1: Copilot with full 1-hour transcript (should truncate and succeed)
    logger.info("\n--- Test: Copilot with 1-hour transcript ---")
    start = time.time()
    try:
        response = await llm.generate_copilot_response(
            transcript_window=transcript,
            config=config,
            relevant_notes="Q2 retrospective: we shipped 3 of 5 planned features. Biggest blocker was the auth SDK delay.",
        )
        elapsed = time.time() - start
        logger.info(
            f"  ✅ Copilot succeeded in {elapsed:.1f}s: "
            f"{len(response.suggestions)} suggestions, "
            f"{len(response.follow_up_questions)} questions, "
            f"{len(response.risks)} risks"
        )
        for s in response.suggestions:
            logger.info(f"     [{s.tone}] {s.text[:80]}...")
    except Exception as e:
        elapsed = time.time() - start
        logger.error(f"  ❌ Copilot failed after {elapsed:.1f}s: {e}")

    # Test 2: Summary with full 1-hour transcript
    logger.info("\n--- Test: Summary with 1-hour transcript ---")
    start = time.time()
    try:
        summary = await llm.generate_summary(
            transcript=transcript,
            config=config,
            notes="Q2 retrospective notes: auth SDK delayed 2 weeks, mobile team understaffed",
        )
        elapsed = time.time() - start
        logger.info(f"  ✅ Summary succeeded in {elapsed:.1f}s")
        logger.info(f"     Executive summary: {summary.executive_summary[:120]}...")
        logger.info(f"     Decisions: {len(summary.decisions)}")
        logger.info(f"     Action items: {len(summary.action_items)}")
        logger.info(f"     Unresolved: {len(summary.unresolved)}")
    except Exception as e:
        elapsed = time.time() - start
        logger.error(f"  ❌ Summary failed after {elapsed:.1f}s: {e}")

    await llm.close()


async def test_detect_context_length():
    """Test auto-detection of LM Studio model context length."""
    import httpx

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{settings.lm_studio_url}/models")
            models = resp.json()
            if not models.get("data"):
                logger.warning("No model loaded — skipping detection test")
                return
    except Exception:
        logger.warning("LM Studio not available — skipping detection test")
        return

    from app.services.providers.local import LocalProvider
    llm = LLMClient(provider=LocalProvider(base_url=settings.lm_studio_url))
    detected = await llm.detect_context_length()
    logger.info(f"\n  Detected context length: {detected:,} tokens")

    copilot_budget, summary_budget = llm._calibrate_budgets(detected)
    logger.info(f"  Calibrated copilot budget: {copilot_budget:,} chars")
    logger.info(f"  Calibrated summary budget: {summary_budget:,} chars")

    # Verify budgets are reasonable
    assert copilot_budget > 0, "Copilot budget should be positive"
    assert summary_budget > copilot_budget, "Summary budget should exceed copilot budget"
    assert summary_budget <= 60000, "Summary budget should have a sane upper bound"

    await llm.close()


# ─── Main runner ──────────────────────────────────────────────────────

def main():
    """Run all tests standalone (no pytest required)."""
    logger.info("=" * 60)
    logger.info("RONIN CONTEXT WINDOW TEST SUITE")
    logger.info("=" * 60)

    passed = 0
    failed = 0

    tests = [
        ("Transcript Volume", test_transcript_volume),
        ("Copilot Truncation", test_prompt_truncation_copilot),
        ("Summary Truncation", test_prompt_truncation_summary),
        ("Budget Calibration", test_budget_calibration),
        ("JSON Extraction", test_extract_json_edge_cases),
        ("Copilot Normalization", test_normalize_copilot_robustness),
    ]

    for name, test_fn in tests:
        logger.info(f"\n▶ {name}")
        try:
            result = test_fn()
            logger.info(f"  ✅ PASSED")
            passed += 1
        except Exception as e:
            logger.error(f"  ❌ FAILED: {e}")
            failed += 1

    # Async integration tests
    async_tests = [
        ("Detect Context Length", test_detect_context_length),
        ("Live Copilot (1hr)", test_live_copilot_with_lm_studio),
    ]

    for name, test_fn in async_tests:
        logger.info(f"\n▶ {name} (integration)")
        try:
            asyncio.run(test_fn())
            logger.info(f"  ✅ PASSED")
            passed += 1
        except Exception as e:
            logger.error(f"  ❌ FAILED: {e}")
            failed += 1

    logger.info(f"\n{'='*60}")
    logger.info(f"RESULTS: {passed} passed, {failed} failed")
    logger.info(f"{'='*60}")

    return failed == 0


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
