import json
import sys

from docx import Document
from docx.enum.text import WD_LINE_SPACING
from docx.shared import Inches, Pt


def add_text_block(document, kind, text):
    parts = [part.strip() for part in text.split("\n") if part.strip()]
    if not parts:
        return
    if kind == "heading":
        for part in parts:
            document.add_heading(part.lstrip("# "), level=2)
    elif kind == "list":
        for part in parts:
            if part.startswith(("—", "–", "-", "•", "▪", "●")):
                part = part[1:].strip()
            document.add_paragraph(part, style="List Bullet")
    else:
        for part in parts:
            document.add_paragraph(part)


def main():
    destination = sys.argv[1]
    payload = json.load(sys.stdin)
    doc = Document()
    normal = doc.styles["Normal"]
    normal.font.name = "Aptos"
    normal.font.size = Pt(11)
    normal.paragraph_format.space_after = Pt(7)
    normal.paragraph_format.line_spacing_rule = WD_LINE_SPACING.SINGLE
    for page_index, page in enumerate(payload.get("pages", [])):
        if page_index:
            doc.add_page_break()
        doc.add_heading(page.get("name", f"Страница {page_index + 1}"), level=1)
        for block in page.get("blocks", []):
            add_text_block(doc, block.get("kind", "paragraph"), block.get("text", ""))
    doc.save(destination)


if __name__ == "__main__":
    main()
