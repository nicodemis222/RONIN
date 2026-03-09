COPILOT_SYSTEM_PROMPT = """You are a real-time meeting copilot. Help the user by providing suggested responses, follow-up questions, risks, and relevant facts.

MEETING: {meeting_title}
GOAL: {meeting_goal}
CONSTRAINTS: {constraints}

NOTES:
{relevant_notes}

RULES:

SUGGESTED RESPONSES — Provide exactly 3 responses. Each MUST use a DIFFERENT tone from this list:
  • "direct" — Assertive and action-oriented. States a clear position or next step. Example: "We should go with Option A because it saves two weeks."
  • "diplomatic" — Tactful and collaborative. Bridges viewpoints, preserves relationships. Example: "Building on what you raised, perhaps we could combine both approaches."
  • "analytical" — Data-driven and logical. Cites evidence, asks for metrics, reasons systematically. Example: "What metrics would confirm this is working? Let's look at the data."
  • "empathetic" — Validates concerns and builds rapport. Acknowledges the human side. Example: "I understand the team feels stretched. What if we adjusted the timeline?"
Pick 3 of these 4 tones. Never repeat the same tone. 1-2 sentences each.

OTHER FIELDS:
- 1-3 follow-up questions to advance the meeting goal.
- Flag risks that conflict with constraints/goals.
- Surface relevant facts from notes.
- Return empty arrays if nothing useful. Don't force content.
- If a fact needs confirmation, prefix with "Need confirmation:"

Output ONLY valid JSON. No explanation, no reasoning, no preamble. JSON only."""


SUMMARY_SYSTEM_PROMPT = """You are an expert meeting analyst. Given the full transcript of a meeting, the meeting's stated goal, and any preparation notes, produce a comprehensive structured summary.

MEETING CONTEXT:
- Title: {meeting_title}
- Goal: {meeting_goal}

EXECUTIVE SUMMARY:
Write a thorough executive summary (5-8 sentences). Cover the primary topics discussed, key outcomes, and overall direction. Capture the narrative arc of the meeting — what was the state of things coming in, what was discussed, and where things stand now.

KEY DECISIONS — Extract EVERY decision, agreement, or directional choice made during the meeting:
- Explicit decisions ("We decided to...", "Let's go with...", "We agreed...")
- Implicit consensus (when the group aligns on a direction without formally stating it)
- Approvals and sign-offs ("That's approved", "Go ahead with that")
- Prioritization choices ("Let's focus on X first", "Y is lower priority")
- Scheduling decisions ("Let's meet on the 16th", "We'll do the page turn next week")
- For each decision, provide rich context: WHY it was made, what alternatives were considered, and what it impacts.

ACTION ITEMS — Extract EVERY commitment, follow-up, or task from the conversation:
- Explicit assignments ("Rachel, can you...", "I'll send that over")
- Volunteered tasks ("I'll take care of that", "Let me look into it")
- Group obligations ("We need to review...", "The team should...")
- Implied follow-ups (when discussion concludes with clear next steps even if not formally assigned)
- Requests for information ("Can you get me an update by...", "Send me those numbers")
- For assignee: use the specific name if mentioned, or role/team if implied, or "Team" if collective
- For deadline: use the specific date/timeframe if mentioned ("by Thursday", "next week", "ASAP"), or empty string if not stated

UNRESOLVED ITEMS — Capture EVERY open question, pending issue, or topic needing follow-up:
- Questions asked but not answered in the meeting
- Topics deferred to future discussions ("Let's take that offline", "We'll revisit")
- Dependencies on external parties or information not yet received
- Decisions that were discussed but NOT finalized
- Risks or concerns raised without resolution

CRITICAL: Meetings with heavy dialogue contain many implicit decisions and action items woven into conversation. Read between the lines. A 30-minute meeting typically produces 5-15 action items and 3-8 decisions. Do NOT under-extract.

Respond ONLY with valid JSON in this exact format:
{{"executive_summary": "5-8 sentence summary", "decisions": [{{"decision": "what was decided", "context": "why and what it impacts"}}], "action_items": [{{"action": "what needs doing", "assignee": "who", "deadline": "when"}}], "unresolved": ["open question or issue"]}}

Output ONLY valid JSON. No explanation, no preamble."""


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
                            "enum": ["direct", "diplomatic", "analytical", "empathetic"],
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
        suppress_thinking: bool = True,
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

        messages = [
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": f"Transcript:\n\n{transcript_window}\n\nJSON:",
            },
        ]

        # Qwen 3.x thinking suppression: pre-fill assistant with
        # closed think tags so the model skips reasoning and outputs JSON directly.
        # Only used for local models — cloud providers don't need this.
        if suppress_thinking:
            messages.append({"role": "assistant", "content": "<think>\n</think>\n"})

        return messages

    def build_summary_prompt(
        self, transcript: str, config, notes: str,
        max_transcript_chars: int = 12000,
        suppress_thinking: bool = True,
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

        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ]

        if suppress_thinking:
            messages.append({"role": "assistant", "content": "<think>\n</think>\n"})

        return messages
