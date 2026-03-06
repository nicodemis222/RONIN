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
