from dataclasses import dataclass, field

from app.config import settings


@dataclass
class NoteChunk:
    text: str
    source_file: str
    index: int
    keywords: set = field(default_factory=set)


class NotesManager:
    MAX_CHUNK_CHARS = 500
    MAX_CONTEXT_CHARS = settings.notes_max_context_chars

    def __init__(self):
        self.chunks: list[NoteChunk] = []
        self.all_text: str = ""

    def load_notes(self, notes: list[dict]):
        self.chunks = []
        all_parts = []

        for note in notes:
            content = note["content"]
            name = note["name"]
            all_parts.append(f"--- {name} ---\n{content}")

            paragraphs = content.split("\n\n")
            current_chunk = ""
            chunk_index = 0

            for para in paragraphs:
                para = para.strip()
                if not para:
                    continue
                if len(current_chunk) + len(para) + 2 > self.MAX_CHUNK_CHARS:
                    if current_chunk:
                        self._add_chunk(current_chunk, name, chunk_index)
                        chunk_index += 1
                    current_chunk = para
                else:
                    current_chunk = f"{current_chunk}\n\n{para}" if current_chunk else para

            if current_chunk:
                self._add_chunk(current_chunk, name, chunk_index)

        self.all_text = "\n\n".join(all_parts)

    def _add_chunk(self, text: str, source: str, index: int):
        words = set(
            w.lower().strip(".,!?;:\"'()[]{}") for w in text.split() if len(w) > 3
        )
        self.chunks.append(
            NoteChunk(text=text, source_file=source, index=index, keywords=words)
        )

    def get_relevant(self, recent_transcript: str, max_chars: int | None = None) -> str:
        if not self.chunks:
            return ""

        # If total notes fit in budget, return all
        if len(self.all_text) <= (max_chars or self.MAX_CONTEXT_CHARS):
            return self.all_text

        max_chars = max_chars or self.MAX_CONTEXT_CHARS

        transcript_keywords = set(
            w.lower().strip(".,!?;:\"'()[]{}") for w in recent_transcript.split() if len(w) > 3
        )

        scored = []
        for chunk in self.chunks:
            overlap = len(chunk.keywords & transcript_keywords)
            scored.append((overlap, chunk))

        scored.sort(key=lambda x: x[0], reverse=True)

        selected = []
        total_chars = 0
        for score, chunk in scored:
            if score == 0 and selected:
                break
            if total_chars + len(chunk.text) > max_chars:
                continue
            selected.append(chunk)
            total_chars += len(chunk.text)

        result_parts = []
        for chunk in selected:
            result_parts.append(f"[From: {chunk.source_file}]\n{chunk.text}")
        return "\n\n".join(result_parts)

    def get_all_text(self) -> str:
        return self.all_text
