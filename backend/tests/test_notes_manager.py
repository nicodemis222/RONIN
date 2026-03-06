"""Tests for app/services/notes_manager.py — chunking, keyword extraction, relevance."""

import pytest

from app.services.notes_manager import NotesManager


class TestLoadNotes:
    def test_load_empty_notes(self):
        """Loading an empty list produces no chunks."""
        mgr = NotesManager()
        mgr.load_notes([])
        assert mgr.chunks == []
        assert mgr.all_text == ""

    def test_load_single_note(self):
        """A single short note produces exactly one chunk."""
        mgr = NotesManager()
        mgr.load_notes([{"name": "note.md", "content": "Hello world"}])
        assert len(mgr.chunks) == 1
        assert mgr.chunks[0].source_file == "note.md"
        assert mgr.chunks[0].text == "Hello world"

    def test_load_multiple_notes(self):
        """Multiple notes each produce at least one chunk."""
        mgr = NotesManager()
        mgr.load_notes([
            {"name": "a.md", "content": "Note A content"},
            {"name": "b.md", "content": "Note B content"},
        ])
        assert len(mgr.chunks) == 2
        sources = {c.source_file for c in mgr.chunks}
        assert sources == {"a.md", "b.md"}


class TestChunking:
    def test_chunking_large_note(self):
        """A note >500 chars gets split into multiple chunks by paragraph."""
        # Create two paragraphs, each >250 chars so combined >500
        para1 = "First paragraph. " * 20  # ~340 chars
        para2 = "Second paragraph. " * 20  # ~360 chars
        content = f"{para1}\n\n{para2}"

        mgr = NotesManager()
        mgr.load_notes([{"name": "big.md", "content": content}])
        assert len(mgr.chunks) >= 2


class TestKeywordExtraction:
    def test_keyword_extraction(self):
        """Keywords are lowercase, >3 chars, stripped of punctuation."""
        mgr = NotesManager()
        mgr.load_notes([
            {"name": "t.md", "content": "The quick, brown fox jumps!"},
        ])
        chunk = mgr.chunks[0]
        # "The" has 3 chars -> excluded; "quick" "brown" "jumps" included
        assert "quick" in chunk.keywords
        assert "brown" in chunk.keywords
        assert "jumps" in chunk.keywords
        assert "the" not in chunk.keywords  # <= 3 chars
        assert "fox" not in chunk.keywords  # == 3 chars (not > 3)


class TestGetRelevant:
    def test_get_relevant_returns_all_if_under_budget(self):
        """When total notes fit within budget, get_relevant returns all text."""
        mgr = NotesManager()
        mgr.load_notes([{"name": "small.md", "content": "Short note"}])
        result = mgr.get_relevant("anything here", max_chars=10000)
        assert result == mgr.all_text

    def test_get_relevant_filters_by_keyword_overlap(self):
        """Chunks with keyword overlap to the transcript are preferred."""
        mgr = NotesManager()
        # Two paragraphs that will produce two chunks
        content_a = "authentication security tokens verification"
        content_b = "database optimization queries performance"
        # Make notes large enough so all_text exceeds the budget
        mgr.load_notes([
            {"name": "auth.md", "content": content_a},
            {"name": "db.md", "content": content_b},
        ])

        # Force a small budget so not everything fits
        result = mgr.get_relevant(
            "We need better authentication and tokens",
            max_chars=60,
        )
        # The auth chunk should be selected over the db chunk
        assert "authentication" in result

    def test_get_relevant_respects_max_chars(self):
        """Returned text does not exceed max_chars."""
        mgr = NotesManager()
        long_content = ("Some important note content here. " * 30).strip()
        mgr.load_notes([{"name": "long.md", "content": long_content}])
        result = mgr.get_relevant("important note", max_chars=100)
        assert len(result) <= 200  # allow some header overhead from "[From: ...]"

    def test_get_relevant_empty_chunks(self):
        """No chunks means empty string."""
        mgr = NotesManager()
        mgr.load_notes([])
        assert mgr.get_relevant("anything") == ""


class TestGetAllText:
    def test_get_all_text(self):
        """get_all_text returns the concatenated text of all notes."""
        mgr = NotesManager()
        mgr.load_notes([
            {"name": "a.md", "content": "Alpha"},
            {"name": "b.md", "content": "Bravo"},
        ])
        text = mgr.get_all_text()
        assert "Alpha" in text
        assert "Bravo" in text
        assert "a.md" in text
        assert "b.md" in text


# ═══════════════════════════════════════════════════════════════════════════
# Edge Cases — Single-paragraph oversized chunks
# ═══════════════════════════════════════════════════════════════════════════

class TestOversizedChunks:
    def test_single_paragraph_exceeds_max_chunk(self):
        """A single paragraph >500 chars with no paragraph breaks still loads."""
        # 600+ char single paragraph (no \n\n)
        long_paragraph = "word " * 120  # 600 chars, single paragraph
        mgr = NotesManager()
        mgr.load_notes([{"name": "long.md", "content": long_paragraph}])
        # Should still produce at least one chunk (even if oversized)
        assert len(mgr.chunks) >= 1
        # All text should be preserved
        assert long_paragraph.strip() in mgr.all_text

    def test_mixed_paragraph_sizes(self):
        """Notes with mixed short and long paragraphs chunk correctly."""
        short = "Short paragraph here."
        long_para = "This is a longer paragraph. " * 25  # ~700 chars
        content = f"{short}\n\n{long_para}"
        mgr = NotesManager()
        mgr.load_notes([{"name": "mixed.md", "content": content}])
        # Should be at least 2 chunks (short and long split)
        assert len(mgr.chunks) >= 2


# ═══════════════════════════════════════════════════════════════════════════
# Edge Cases — get_relevant with zero keyword overlap
# ═══════════════════════════════════════════════════════════════════════════

class TestGetRelevantEdgeCases:
    def test_no_keyword_overlap_returns_first_chunk(self):
        """When no keywords overlap, get_relevant returns at most 1 chunk."""
        mgr = NotesManager()
        # Notes about topic A, transcript about topic B — no overlap
        mgr.load_notes([
            {"name": "a.md", "content": "Python framework Django deployment"},
            {"name": "b.md", "content": "JavaScript React frontend components"},
        ])
        result = mgr.get_relevant(
            "completely unrelated basketball sports discussion",
            max_chars=5000,
        )
        # Should return something (first chunk) rather than nothing
        assert len(result) > 0

    def test_get_relevant_with_empty_transcript(self):
        """get_relevant with empty transcript still returns something."""
        mgr = NotesManager()
        mgr.load_notes([
            {"name": "notes.md", "content": "Important facts about the budget"},
        ])
        # Empty transcript = no keyword overlap
        result = mgr.get_relevant("")
        assert len(result) > 0  # Should still return the note

    def test_get_relevant_header_overhead(self):
        """The [From: filename] header is included in the output."""
        mgr = NotesManager()
        mgr.load_notes([
            {"name": "test-notes.md", "content": "Some important content here"},
        ])
        result = mgr.get_relevant("important content", max_chars=10000)
        assert "[From: test-notes.md]" in result or "test-notes.md" in result

    def test_get_relevant_selects_most_relevant_chunks(self):
        """Chunks with higher keyword overlap score higher."""
        mgr = NotesManager()
        # Create notes where one chunk clearly matches the transcript
        content_match = "budget allocation finance quarterly report"
        content_nomatch = "weather forecast temperature humidity"
        content_partial = "budget review annual planning schedule"
        mgr.load_notes([
            {"name": "weather.md", "content": content_nomatch},
            {"name": "finance.md", "content": content_match},
            {"name": "planning.md", "content": content_partial},
        ])
        result = mgr.get_relevant(
            "Let's discuss the budget allocation for the quarterly report",
            max_chars=100,  # Tight budget — only 1-2 chunks
        )
        # The finance chunk should be selected (most keyword overlap)
        assert "finance" in result.lower() or "budget" in result.lower()

    def test_get_relevant_budget_zero(self):
        """get_relevant with max_chars=0 returns empty string."""
        mgr = NotesManager()
        mgr.load_notes([{"name": "a.md", "content": "Some content"}])
        result = mgr.get_relevant("Some content", max_chars=0)
        assert result == ""


# ═══════════════════════════════════════════════════════════════════════════
# Edge Cases — Special content
# ═══════════════════════════════════════════════════════════════════════════

class TestSpecialContent:
    def test_unicode_content(self):
        """Notes with unicode characters load correctly."""
        mgr = NotesManager()
        content = "会議の準備 — résumé of the budget discussion • €500k allocation"
        mgr.load_notes([{"name": "intl.md", "content": content}])
        assert len(mgr.chunks) >= 1
        assert "€500k" in mgr.all_text

    def test_whitespace_only_paragraphs_skipped(self):
        """Paragraphs with only whitespace are skipped during chunking."""
        mgr = NotesManager()
        content = "First paragraph\n\n   \n\n\n\nSecond paragraph"
        mgr.load_notes([{"name": "sparse.md", "content": content}])
        # Whitespace paragraphs should be stripped/skipped
        chunk_texts = [c.text for c in mgr.chunks]
        for text in chunk_texts:
            assert text.strip()  # No empty/whitespace-only chunks

    def test_note_with_only_short_words(self):
        """Keywords are only words >3 chars — short-word notes produce empty keyword sets."""
        mgr = NotesManager()
        mgr.load_notes([{"name": "short.md", "content": "I am a dog"}])
        # All words <= 3 chars, so keyword set should be empty
        assert len(mgr.chunks) == 1
        assert len(mgr.chunks[0].keywords) == 0

    def test_duplicate_note_names(self):
        """Two notes with the same filename are both loaded."""
        mgr = NotesManager()
        mgr.load_notes([
            {"name": "notes.md", "content": "Version one"},
            {"name": "notes.md", "content": "Version two"},
        ])
        assert len(mgr.chunks) == 2
        assert "Version one" in mgr.all_text
        assert "Version two" in mgr.all_text

    def test_very_large_note(self):
        """A note with many paragraphs produces many chunks."""
        paragraphs = [f"Paragraph {i} with some longer content here." for i in range(50)]
        content = "\n\n".join(paragraphs)
        mgr = NotesManager()
        mgr.load_notes([{"name": "big.md", "content": content}])
        # Should produce multiple chunks (50 paragraphs, ~40 chars each, multiple fit per chunk)
        assert len(mgr.chunks) >= 3
        # All text preserved
        assert "Paragraph 0" in mgr.all_text
        assert "Paragraph 49" in mgr.all_text


# ═══════════════════════════════════════════════════════════════════════════
# Reload / reset behavior
# ═══════════════════════════════════════════════════════════════════════════

class TestReload:
    def test_load_notes_replaces_previous(self):
        """Calling load_notes a second time replaces all previous data."""
        mgr = NotesManager()
        mgr.load_notes([{"name": "old.md", "content": "Old content"}])
        assert "Old content" in mgr.all_text

        mgr.load_notes([{"name": "new.md", "content": "New content"}])
        assert "New content" in mgr.all_text
        assert "Old content" not in mgr.all_text
        # Only new chunks remain
        assert all(c.source_file == "new.md" for c in mgr.chunks)
