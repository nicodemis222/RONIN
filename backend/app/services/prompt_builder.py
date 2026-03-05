COPILOT_SYSTEM_PROMPT = """You are a real-time meeting copilot. Help the user by providing suggested responses, follow-up questions, risks, and relevant facts.

MEETING: {meeting_title}
GOAL: {meeting_goal}
CONSTRAINTS: {constraints}

NOTES:
{relevant_notes}

RULES:
- 2-3 suggested responses (tone: direct, diplomatic, or curious). 1-2 sentences each.
- 1-3 follow-up questions to advance the meeting goal.
- Flag risks that conflict with constraints/goals.
- Surface relevant facts from notes.
- Return empty arrays if nothing useful. Don't force content.
- If a fact needs confirmation, prefix with "Need confirmation:"

Output ONLY valid JSON. No explanation, no reasoning, no preamble. JSON only."""


SUMMARY_SYSTEM_PROMPT = """You are a meeting summarizer. Given the full transcript of a meeting, the meeting's stated goal, and any preparation notes, produce a structured summary.

MEETING CONTEXT:
- Title: {meeting_title}
- Goal: {meeting_goal}

INSTRUCTIONS:
1. Write a concise executive summary (3-5 sentences).
2. List all key decisions made during the meeting.
3. Extract all action items with assignee (if mentioned) and deadline (if mentioned).
4. Note any unresolved questions or topics that need follow-up.

Respond ONLY with valid JSON matching the required schema."""


COPILOT_RESPONSE_SCHEMA = {
    "name": "copilot_response",
    "strict": True,
    "schema": {
        "type": "object",
        "properties": {
            "suggestions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "tone": {
                            "type": "string",
                            "enum": ["direct", "diplomatic", "curious"],
                        },
                        "text": {
                            "type": "string",
                        },
                    },
                    "required": ["tone", "text"],
                    "additionalProperties": False,
                },
            },
            "follow_up_questions": {
                "type": "array",
                "items": {"type": "string"},
            },
            "risks": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "warning": {"type": "string"},
                        "context": {"type": "string"},
                    },
                    "required": ["warning", "context"],
                    "additionalProperties": False,
                },
            },
            "facts_from_notes": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "fact": {"type": "string"},
                        "source": {"type": "string"},
                    },
                    "required": ["fact", "source"],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["suggestions", "follow_up_questions", "risks", "facts_from_notes"],
        "additionalProperties": False,
    },
}


SUMMARY_RESPONSE_SCHEMA = {
    "name": "meeting_summary",
    "strict": True,
    "schema": {
        "type": "object",
        "properties": {
            "executive_summary": {"type": "string"},
            "decisions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "decision": {"type": "string"},
                        "context": {"type": "string"},
                    },
                    "required": ["decision", "context"],
                    "additionalProperties": False,
                },
            },
            "action_items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "action": {"type": "string"},
                        "assignee": {"type": "string"},
                        "deadline": {"type": "string"},
                    },
                    "required": ["action", "assignee", "deadline"],
                    "additionalProperties": False,
                },
            },
            "unresolved": {
                "type": "array",
                "items": {"type": "string"},
            },
        },
        "required": ["executive_summary", "decisions", "action_items", "unresolved"],
        "additionalProperties": False,
    },
}


class PromptBuilder:
    def build_copilot_prompt(
        self, transcript_window: str, config, relevant_notes: str,
        max_transcript_chars: int = 6000,
    ) -> list[dict]:
        system = COPILOT_SYSTEM_PROMPT.format(
            meeting_title=config.title,
            meeting_goal=config.goal,
            constraints=config.constraints or "None specified",
            relevant_notes=relevant_notes or "No notes loaded",
        )

        # Truncate transcript to fit model context.
        # For copilot, keep only the tail (most recent conversation).
        if len(transcript_window) > max_transcript_chars:
            transcript_window = (
                "[... earlier transcript omitted ...]\n\n"
                + transcript_window[-max_transcript_chars:]
            )

        return [
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": f"Transcript:\n\n{transcript_window}\n\nJSON:",
            },
            # Qwen 3.x thinking suppression: pre-fill assistant with
            # closed think tags so the model skips reasoning and outputs JSON directly.
            # This dramatically reduces output tokens and speeds up inference.
            {"role": "assistant", "content": "<think>\n</think>\n"},
        ]

    def build_summary_prompt(
        self, transcript: str, config, notes: str,
        max_transcript_chars: int = 12000,
    ) -> list[dict]:
        system = SUMMARY_SYSTEM_PROMPT.format(
            meeting_title=config.title,
            meeting_goal=config.goal,
        )

        # Truncate transcript if it exceeds context budget.
        # Keep the start (context/intros) and the end (decisions/wrap-up),
        # which are typically the most valuable for a summary.
        if len(transcript) > max_transcript_chars:
            head_chars = max_transcript_chars // 4          # 25% from start
            tail_chars = max_transcript_chars - head_chars  # 75% from end
            transcript = (
                transcript[:head_chars]
                + "\n\n[... transcript truncated for context length ...]\n\n"
                + transcript[-tail_chars:]
            )

        user_content = f"Full meeting transcript:\n\n{transcript}"
        if notes:
            user_content += f"\n\nPreparation notes:\n{notes}"
        return [
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
            # Qwen 3.x thinking suppression — skip reasoning, output JSON directly
            {"role": "assistant", "content": "<think>\n</think>\n"},
        ]
