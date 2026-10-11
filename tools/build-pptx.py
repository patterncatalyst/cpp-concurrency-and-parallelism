#!/usr/bin/env python3
"""
build-pptx.py — shared deck engine for the cpp-concurrency-and-parallelism decks.

A pure library (no main()): design tokens, slide primitives, slide builders, and
a render_slide() dispatcher. The three decks each have their own entry script
(build-conc-100-pptx.py / build-conc-101-pptx.py / build-conc-201-pptx.py) that
loads this module via importlib (the filename is hyphenated), supplies its own
title / agenda / closing slides, and feeds its SECTIONS from a sections_conc_*.py
content module.

Ported from the cpp-statelessness deck engine; the footer label is parameterized
(set build_pptx.FOOTER_LABEL from the entry script) so each book brands its own
footer. Visual style is the lgtm-presentation Red Hat house brand (Red Hat
Display / Text / Mono, red #EE0000 accent) — this is the deck brand, distinct
from the book's bespoke diagram palette.

Diagrams: each deck's build shell converts diagrams/*.svg into
/tmp/diagrams-png/<name>.jpg before the Python build runs; build_diagram_slide
and the 'image' right-content read those JPGs.

Prerequisites:
    pip install python-pptx Pillow
    LibreOffice (soffice) + poppler (pdftoppm) for the SVG→JPG step (build shell)
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.oxml.ns import qn
from lxml import etree


# ============================================================================
# Design tokens — lgtm-presentation house style (Red Hat brand)
#
# Fonts: Red Hat Display (titles) / Red Hat Text (body) / Red Hat Mono (code).
# Palette: house red #EE0000 accent + the documented role colors (svc blue,
# data purple, platform teal, govern amber, danger deep-red) mapped onto this
# deck's six existing accent slots, plus ink/body/caption/panel/grid/code
# neutrals. See ~/.claude/skills/lgtm-presentation/references/theme.md.
# ============================================================================

class C:
    """Color palette — Red Hat house style (red accent + documented tokens)."""
    # Backgrounds
    BG_TITLE_DARK    = RGBColor(0x15, 0x15, 0x15)   # title/closing bg — house "ink"
    BG_SECTION_DARK  = RGBColor(0xAB, 0x00, 0x00)   # section divider bg — house "redDark"
    BG_HEADER_BAR    = RGBColor(0xEE, 0x00, 0x00)   # content slide header bar — house red
    BG_CODE_BLOCK    = RGBColor(0x15, 0x15, 0x15)   # code block bg — house "codeBg"
    BG_CARD_LIGHT    = RGBColor(0xF4, 0xF4, 0xF4)   # neutral light card — house "panel"
    BG_CARD_SOFT     = RGBColor(0xD2, 0xD2, 0xD2)   # soft card — house "grid"

    # Text
    TEXT_DARK        = RGBColor(0x15, 0x15, 0x15)   # body text on light bg — house "ink"
    TEXT_LIGHT       = RGBColor(0xF4, 0xF4, 0xF4)   # body text on dark bg — house "panel"
    TEXT_WHITE       = RGBColor(0xFF, 0xFF, 0xFF)   # pure white
    TEXT_MUTED       = RGBColor(0x8A, 0x8A, 0x8A)   # muted secondary — house "pageNum"

    # Accents — the deck's six accent slots mapped onto the house role palette
    ACCENT_CYAN      = RGBColor(0xEE, 0x00, 0x00)   # primary accent — house red/rest
    ACCENT_BLUE      = RGBColor(0x00, 0x66, 0xCC)   # house "svc" blue
    ACCENT_GREEN     = RGBColor(0x00, 0x6E, 0x6E)   # house "platform" teal
    ACCENT_RED       = RGBColor(0xB7, 0x1C, 0x1C)   # "before" / negative — house "danger" deep-red
    ACCENT_ORANGE    = RGBColor(0xB3, 0x6B, 0x00)   # warnings — house "govern" amber
    ACCENT_PURPLE    = RGBColor(0x6A, 0x1B, 0x9A)   # house "data" purple

    # Demo cue color (distinctive — matches the "DEMO" pill style)
    BG_DEMO_PILL     = RGBColor(0xFF, 0xA0, 0x00)   # house "amber" perf-callout accent


class F:
    """Font sizes."""
    TITLE_HUGE     = Pt(44)   # title slide
    TITLE_LARGE    = Pt(36)   # section divider
    TITLE_MED      = Pt(28)   # slide title
    SECTION_LABEL  = Pt(14)   # "Section 02" pill
    BODY_LARGE     = Pt(20)   # large body
    BODY           = Pt(16)   # standard body
    BODY_SMALL     = Pt(14)   # small body
    CAPTION        = Pt(11)   # captions, footer
    CODE           = Pt(12)   # code blocks
    CODE_SMALL     = Pt(11)   # long code blocks
    STAT_HUGE      = Pt(72)   # big-number callouts
    STAT_LARGE     = Pt(48)


class FontFam:
    HEADER = "Red Hat Display"
    BODY   = "Red Hat Text"
    CODE   = "Red Hat Mono"


# Slide dimensions: 16:9, 13.333" x 7.5"
SLIDE_W = Inches(13.333)
SLIDE_H = Inches(7.5)
MARGIN  = Inches(0.5)


# ============================================================================
# Project paths
# ============================================================================

ROOT = Path(__file__).resolve().parent.parent
DIAGRAMS_DIR = Path("/tmp/diagrams-png")   # converted JPGs (build shell fills this)
BIBLIO_URL = "https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/bibliography/"
REPO_URL = "github.com/patterncatalyst/cpp-concurrency-and-parallelism"

# Footer label — entry scripts may override: build_pptx.FOOTER_LABEL = "..."
FOOTER_LABEL = "C++ Concurrency & Parallelism"


# ============================================================================
# Helpers — slide building primitives
# ============================================================================

def set_slide_bg(slide, color: RGBColor) -> None:
    """Set a solid background fill on a slide."""
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_rect(slide, left, top, width, height, fill_color: RGBColor,
             line_color: Optional[RGBColor] = None):
    """Add a rectangle shape. Returns the shape."""
    shape = slide.shapes.add_shape(
        MSO_SHAPE.RECTANGLE, left, top, width, height
    )
    shape.fill.solid()
    shape.fill.fore_color.rgb = fill_color
    if line_color is None:
        shape.line.fill.background()
    else:
        shape.line.color.rgb = line_color
        shape.line.width = Pt(0.5)
    return shape


def add_pill(slide, left, top, width, height, fill_color: RGBColor):
    """Add a rounded-rectangle 'pill' shape."""
    shape = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE, left, top, width, height
    )
    shape.fill.solid()
    shape.fill.fore_color.rgb = fill_color
    shape.line.fill.background()
    # Tight corner radius
    try:
        shape.adjustments[0] = 0.5
    except Exception:
        pass
    return shape


def add_text(slide, left, top, width, height, text: str,
             size: Pt = F.BODY,
             color: RGBColor = C.TEXT_DARK,
             bold: bool = False,
             italic: bool = False,
             align: PP_ALIGN = PP_ALIGN.LEFT,
             anchor: MSO_ANCHOR = MSO_ANCHOR.TOP,
             font: str = FontFam.BODY):
    """Add a text box with single paragraph of styled text."""
    tb = slide.shapes.add_textbox(left, top, width, height)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_top = Inches(0.05)
    tf.margin_bottom = Inches(0.05)
    tf.margin_left = Inches(0.05)
    tf.margin_right = Inches(0.05)

    p = tf.paragraphs[0]
    p.alignment = align
    run = p.add_run()
    run.text = text
    run.font.size = size
    run.font.bold = bold
    run.font.italic = italic
    run.font.color.rgb = color
    run.font.name = font
    return tb


def add_multi_text(slide, left, top, width, height,
                   paragraphs: list[dict],
                   anchor: MSO_ANCHOR = MSO_ANCHOR.TOP,
                   line_spacing: float = 1.15):
    """Add a text box with multiple styled paragraphs.

    Each paragraph dict: {text, size, color, bold, italic, align, font, bullet}
    """
    tb = slide.shapes.add_textbox(left, top, width, height)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_top = Inches(0.05)
    tf.margin_bottom = Inches(0.05)
    tf.margin_left = Inches(0.05)
    tf.margin_right = Inches(0.05)

    for i, para in enumerate(paragraphs):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = para.get("align", PP_ALIGN.LEFT)
        p.line_spacing = line_spacing
        if para.get("space_before"):
            p.space_before = para["space_before"]

        text = para["text"]
        # Bullet handling: prefix with • if requested
        if para.get("bullet"):
            text = "•  " + text

        run = p.add_run()
        run.text = text
        run.font.size = para.get("size", F.BODY)
        run.font.bold = para.get("bold", False)
        run.font.italic = para.get("italic", False)
        run.font.color.rgb = para.get("color", C.TEXT_DARK)
        run.font.name = para.get("font", FontFam.BODY)
    return tb


def add_header_bar(slide, section_label: str, page_no: int, total_pages: int,
                   section_title: str = ""):
    """Add the standard navy header bar across the top of content slides."""
    # Full-width header bar
    add_rect(slide, 0, 0, SLIDE_W, Inches(0.7), C.BG_HEADER_BAR)

    # Section label on left
    add_text(slide, Inches(0.4), Inches(0.15), Inches(7), Inches(0.4),
             section_title or section_label,
             size=F.TITLE_MED, color=C.TEXT_WHITE,
             bold=True, align=PP_ALIGN.LEFT,
             font=FontFam.HEADER)

    # Section pill on right
    pill_w = Inches(1.6)
    pill = add_pill(slide,
                    SLIDE_W - pill_w - Inches(0.3),
                    Inches(0.18),
                    pill_w, Inches(0.35),
                    C.BG_TITLE_DARK)
    add_text(slide, SLIDE_W - pill_w - Inches(0.3), Inches(0.18),
             pill_w, Inches(0.35),
             section_label,
             size=F.SECTION_LABEL, color=C.TEXT_WHITE,
             bold=True, align=PP_ALIGN.CENTER,
             anchor=MSO_ANCHOR.MIDDLE, font=FontFam.HEADER)


def add_footer(slide, section_title: str, page_no: int, total_pages: int):
    """Add the standard footer bar — house footer convention (caption text,
    page number in the house "pageNum" tone)."""
    footer_top = SLIDE_H - Inches(0.35)
    add_text(slide, Inches(0.4), footer_top,
             Inches(9), Inches(0.3),
             f"{FOOTER_LABEL}   |   {section_title}",
             size=F.CAPTION, color=C.TEXT_MUTED,
             align=PP_ALIGN.LEFT, font=FontFam.BODY)
    add_text(slide, SLIDE_W - Inches(1.5), footer_top,
             Inches(1.1), Inches(0.3),
             f"{page_no} / {total_pages}",
             size=F.CAPTION, color=C.TEXT_MUTED,
             align=PP_ALIGN.RIGHT, font=FontFam.BODY)


def write_deck_notes(notes_path: Path, deck_label: str, lines: list[str]) -> None:
    """Merge this deck's build-notes block into a shared build-notes markdown
    file, preserving any existing block for the *other* decks.

    The three decks build via separate entry-point scripts that each run this
    function independently, so a rebuild of one deck must not clobber another
    deck's documented block. Blocks are keyed by an HTML comment marker; a
    repeat build of the same deck replaces only its own marked block.
    """
    import re

    begin, end = f"<!-- BEGIN:{deck_label} -->", f"<!-- END:{deck_label} -->"
    block = begin + "\n" + "\n".join(lines) + "\n" + end

    existing = notes_path.read_text() if notes_path.exists() else ""
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    if pattern.search(existing):
        new_content = pattern.sub(block, existing)
    elif existing.strip():
        new_content = existing.rstrip("\n") + "\n\n" + block + "\n"
    else:
        new_content = "# Build notes — cpp-concurrency-and-parallelism decks\n\n" + block + "\n"

    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(new_content)


def set_notes(slide, speaker_text: str) -> None:
    """Add full speaker notes to a slide."""
    notes = slide.notes_slide
    tf = notes.notes_text_frame
    # Clear existing
    tf.clear()
    # Split into paragraphs by double-newline
    paragraphs = [p.strip() for p in speaker_text.split("\n\n") if p.strip()]
    for i, para in enumerate(paragraphs):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        run = p.add_run()
        run.text = para
        run.font.size = Pt(12)


# ============================================================================
# Slide builders — section divider, content, diagram, demo cue, code, stat row
# ============================================================================

def build_section_divider(prs, section_num: int, title: str,
                          tagline: str, page_no: int, total_pages: int,
                          notes: str) -> None:
    """Section divider slide — dark navy bg, big number + title."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_slide_bg(slide, C.BG_SECTION_DARK)

    # Big section number
    add_text(slide, Inches(0.5), Inches(2.0), Inches(4), Inches(2.5),
             f"§{section_num}",
             size=Pt(180), color=C.ACCENT_CYAN,
             bold=True, font=FontFam.HEADER)

    # Section title
    add_text(slide, Inches(4.5), Inches(2.3), Inches(8.5), Inches(2),
             title,
             size=F.TITLE_LARGE, color=C.TEXT_WHITE,
             bold=True, font=FontFam.HEADER)

    # Tagline
    add_text(slide, Inches(4.5), Inches(3.8), Inches(8.5), Inches(2),
             tagline,
             size=F.BODY_LARGE, color=C.TEXT_MUTED,
             italic=True, font=FontFam.BODY)

    # Page indicator
    add_text(slide, SLIDE_W - Inches(1.5), SLIDE_H - Inches(0.5),
             Inches(1.0), Inches(0.3),
             f"{page_no} / {total_pages}",
             size=F.CAPTION, color=C.TEXT_MUTED,
             align=PP_ALIGN.RIGHT, font=FontFam.BODY)

    set_notes(slide, notes)


def build_content_slide(prs, section_label: str, section_title: str,
                        title: str,
                        body_paragraphs: list[dict],
                        page_no: int, total_pages: int,
                        notes: str,
                        right_content: Optional[dict] = None) -> None:
    """Standard two-column or full-width content slide.

    body_paragraphs: list of dicts for add_multi_text
    right_content: optional dict {type: 'code'|'image'|'card', ...}
    """
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_slide_bg(slide, C.TEXT_WHITE)

    add_header_bar(slide, section_label, page_no, total_pages, section_title)
    add_footer(slide, section_title, page_no, total_pages)

    # Slide title
    add_text(slide, Inches(0.5), Inches(0.9), Inches(12), Inches(0.6),
             title,
             size=F.TITLE_MED, color=C.TEXT_DARK,
             bold=True, font=FontFam.HEADER)

    # Body region
    if right_content is None:
        # Full-width body
        body_left = Inches(0.5)
        body_width = Inches(12.3)
    else:
        # Half-width body, right column for content
        body_left = Inches(0.5)
        body_width = Inches(6.0)

    add_multi_text(slide, body_left, Inches(1.7),
                   body_width, Inches(5.0),
                   body_paragraphs)

    # Right content
    if right_content:
        rc_left = Inches(6.8)
        rc_top = Inches(1.7)
        rc_width = Inches(6.0)
        rc_height = Inches(5.0)
        rc_type = right_content.get("type")
        if rc_type == "code":
            add_code_block(slide, rc_left, rc_top, rc_width, rc_height,
                           right_content["code"],
                           lang=right_content.get("lang", "cpp"))
        elif rc_type == "image":
            img_path = right_content["path"]
            if Path(img_path).exists():
                slide.shapes.add_picture(img_path, rc_left, rc_top,
                                         width=rc_width)
        elif rc_type == "card":
            add_card(slide, rc_left, rc_top, rc_width, rc_height,
                     right_content["title"], right_content["body"],
                     bg=right_content.get("bg", C.BG_CARD_LIGHT))
        elif rc_type == "stat":
            add_stat_callout(slide, rc_left, rc_top, rc_width, rc_height,
                             right_content["number"],
                             right_content["label"],
                             color=right_content.get("color", C.ACCENT_CYAN))

    set_notes(slide, notes)


def add_code_block(slide, left, top, width, height,
                   code: str, lang: str = "cpp"):
    """Add a dark-navy code block. Auto-shrinks for long content."""
    add_rect(slide, left, top, width, height, C.BG_CODE_BLOCK)
    tb = slide.shapes.add_textbox(
        left + Inches(0.15), top + Inches(0.1),
        width - Inches(0.3), height - Inches(0.2)
    )
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_top = Inches(0.05)
    tf.margin_left = Inches(0.05)
    tf.margin_right = Inches(0.05)
    lines = code.split("\n")
    max_line = max(len(l) for l in lines) if lines else 0
    n_lines = len(lines)
    # Pick a font size that should fit. Roughly: 11pt fits ~30 lines in a
    # 5" tall box. 12pt fits ~26 lines. 10pt fits ~33.
    if n_lines > 28 or max_line > 70:
        size = Pt(10)
    elif n_lines > 22 or max_line > 60:
        size = F.CODE_SMALL
    else:
        size = F.CODE
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        run = p.add_run()
        run.text = line if line else " "
        run.font.size = size
        run.font.name = FontFam.CODE
        run.font.color.rgb = C.TEXT_LIGHT


def add_card(slide, left, top, width, height,
             title: str, body: str,
             bg: RGBColor = C.BG_CARD_LIGHT,
             title_color: RGBColor = C.TEXT_DARK,
             body_color: RGBColor = C.TEXT_DARK):
    """Add a titled card box."""
    add_rect(slide, left, top, width, height, bg)
    add_text(slide, left + Inches(0.2), top + Inches(0.15),
             width - Inches(0.4), Inches(0.4),
             title, size=F.BODY_LARGE, color=title_color,
             bold=True, font=FontFam.HEADER)
    add_text(slide, left + Inches(0.2), top + Inches(0.7),
             width - Inches(0.4), height - Inches(0.85),
             body, size=F.BODY_SMALL, color=body_color,
             font=FontFam.BODY)


def add_stat_callout(slide, left, top, width, height,
                     number: str, label: str,
                     color: RGBColor = C.ACCENT_CYAN):
    """Big-number callout — number on top, label below."""
    add_rect(slide, left, top, width, height, C.BG_CARD_SOFT)
    # Number
    add_text(slide, left, top + Inches(0.5), width, Inches(2),
             number, size=F.STAT_HUGE, color=color,
             bold=True, align=PP_ALIGN.CENTER,
             anchor=MSO_ANCHOR.MIDDLE, font=FontFam.HEADER)
    # Label
    add_text(slide, left + Inches(0.2), top + Inches(2.8),
             width - Inches(0.4), Inches(1.5),
             label, size=F.BODY, color=C.TEXT_DARK,
             align=PP_ALIGN.CENTER, font=FontFam.BODY)


def build_diagram_slide(prs, section_label: str, section_title: str,
                        title: str,
                        diagram_path: str,
                        caption: str,
                        page_no: int, total_pages: int,
                        notes: str) -> None:
    """A slide whose primary content is a single diagram."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_slide_bg(slide, C.TEXT_WHITE)

    add_header_bar(slide, section_label, page_no, total_pages, section_title)
    add_footer(slide, section_title, page_no, total_pages)

    # Title
    add_text(slide, Inches(0.5), Inches(0.9), Inches(12), Inches(0.5),
             title,
             size=F.TITLE_MED, color=C.TEXT_DARK,
             bold=True, font=FontFam.HEADER)

    # Diagram — size by aspect ratio so it fits the available area.
    # Available: 12.3" wide x 5.0" tall (between title and caption)
    avail_w = Inches(12.3)
    avail_h = Inches(5.0)
    if Path(diagram_path).exists():
        try:
            from PIL import Image
            with Image.open(diagram_path) as img:
                px_w, px_h = img.size
            aspect = px_w / px_h
            # Fit to whichever dimension hits the cap first
            if aspect >= avail_w / avail_h:
                # Wider than tall → constrain by width
                draw_w = avail_w
                draw_h = int(avail_w / aspect)
            else:
                # Taller than wide → constrain by height
                draw_h = avail_h
                draw_w = int(avail_h * aspect)
            # Center horizontally
            left = Inches(0.5) + (avail_w - draw_w) / 2
            top = Inches(1.6) + (avail_h - draw_h) / 2
            slide.shapes.add_picture(diagram_path, left, top,
                                     width=draw_w, height=draw_h)
        except Exception:
            slide.shapes.add_picture(diagram_path, Inches(1.0),
                                     Inches(1.6), width=Inches(11.3))
    else:
        add_text(slide, Inches(1.0), Inches(3.0), Inches(11.3), Inches(2),
                 f"[Diagram not found: {diagram_path}]",
                 size=F.BODY, color=C.ACCENT_RED, align=PP_ALIGN.CENTER)

    # Caption
    add_text(slide, Inches(0.5), Inches(6.75), Inches(12.3), Inches(0.35),
             caption,
             size=F.CAPTION, color=C.TEXT_MUTED,
             italic=True, align=PP_ALIGN.CENTER, font=FontFam.BODY)

    set_notes(slide, notes)


def build_demo_cue(prs, section_label: str, section_title: str,
                   demo_num: int, demo_name: str,
                   demo_command: str, demo_description: str,
                   demo_url: str,
                   page_no: int, total_pages: int,
                   notes: str) -> None:
    """A demo cue slide — green DEMO pill, command, description."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_slide_bg(slide, C.BG_SECTION_DARK)

    # "DEMO N" badge
    pill_w = Inches(2.5)
    add_pill(slide, Inches(0.6), Inches(0.6), pill_w, Inches(0.65),
             C.BG_DEMO_PILL)
    add_text(slide, Inches(0.6), Inches(0.6), pill_w, Inches(0.65),
             f"▶ DEMO {demo_num:02d}",
             size=Pt(22), color=C.TEXT_WHITE,
             bold=True, align=PP_ALIGN.CENTER,
             anchor=MSO_ANCHOR.MIDDLE, font=FontFam.HEADER)

    # Demo name
    add_text(slide, Inches(0.6), Inches(1.8), Inches(12), Inches(1.2),
             demo_name,
             size=F.TITLE_LARGE, color=C.TEXT_WHITE,
             bold=True, font=FontFam.HEADER)

    # Description
    add_text(slide, Inches(0.6), Inches(3.0), Inches(12), Inches(1.5),
             demo_description,
             size=F.BODY_LARGE, color=C.TEXT_LIGHT, font=FontFam.BODY)

    # Command — code block style
    cmd_top = Inches(4.7)
    add_rect(slide, Inches(0.6), cmd_top, Inches(12.1), Inches(1.2),
             C.BG_CODE_BLOCK)
    add_text(slide, Inches(0.8), cmd_top + Inches(0.1),
             Inches(11.8), Inches(0.5),
             "$ " + demo_command,
             size=Pt(18), color=C.ACCENT_CYAN,
             font=FontFam.CODE)
    add_text(slide, Inches(0.8), cmd_top + Inches(0.65),
             Inches(11.8), Inches(0.4),
             f"  source on site: {demo_url}",
             size=F.CAPTION, color=C.TEXT_MUTED, font=FontFam.CODE)

    # Page number
    add_text(slide, SLIDE_W - Inches(1.5), SLIDE_H - Inches(0.5),
             Inches(1.0), Inches(0.3),
             f"{page_no} / {total_pages}",
             size=F.CAPTION, color=C.TEXT_MUTED,
             align=PP_ALIGN.RIGHT, font=FontFam.BODY)

    set_notes(slide, notes)


def build_stat_row(prs, section_label: str, section_title: str,
                   title: str, stats: list,
                   page_no: int, total_pages: int,
                   notes: str) -> None:
    """Row of 4 big-number callouts — the 'gap' slide pattern."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_slide_bg(slide, C.TEXT_WHITE)

    add_header_bar(slide, section_label, page_no, total_pages, section_title)
    add_footer(slide, section_title, page_no, total_pages)

    # Slide title
    add_text(slide, Inches(0.5), Inches(0.9), Inches(12), Inches(0.6),
             title, size=F.TITLE_MED, color=C.TEXT_DARK,
             bold=True, font=FontFam.HEADER)

    # 4 stat callouts side-by-side
    n = len(stats)
    avail_w = Inches(12.3)
    gap = Inches(0.2)
    box_w = (avail_w - gap * (n - 1)) / n
    box_h = Inches(4.5)
    top = Inches(1.7)
    left_start = Inches(0.5)

    for i, (number, label, color) in enumerate(stats):
        x = left_start + i * (box_w + gap)
        add_rect(slide, x, top, box_w, box_h, C.BG_CARD_SOFT)

        # Number (big)
        add_text(slide, x, top + Inches(0.3), box_w, Inches(2.2),
                 number, size=Pt(54), color=color,
                 bold=True, align=PP_ALIGN.CENTER,
                 anchor=MSO_ANCHOR.MIDDLE, font=FontFam.HEADER)

        # Label below
        add_text(slide, x + Inches(0.15), top + Inches(2.7),
                 box_w - Inches(0.3), box_h - Inches(2.9),
                 label, size=F.BODY_SMALL, color=C.TEXT_DARK,
                 align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.TOP,
                 font=FontFam.BODY)

    set_notes(slide, notes)


# ============================================================================
# Dispatcher — render a slide based on its 'kind' field
# ============================================================================

def render_slide(prs, section, slide_data: dict,
                 page_no: int, total_pages: int) -> None:
    """Dispatch on slide kind."""
    kind = slide_data["kind"]
    label = section["label"]
    section_title = section["title"]

    if kind == "content":
        right = None
        if slide_data.get("code"):
            right = {"type": "code", "code": slide_data["code"]}
        elif slide_data.get("diagram"):
            right = {"type": "image", "path": slide_data["diagram"]}
        build_content_slide(
            prs, label, section_title,
            slide_data["title"],
            slide_data["body"],
            page_no, total_pages,
            slide_data["notes"],
            right_content=right,
        )

    elif kind == "content-code":
        right = {"type": "code", "code": slide_data["code"]}
        build_content_slide(
            prs, label, section_title,
            slide_data["title"],
            slide_data["body"],
            page_no, total_pages,
            slide_data["notes"],
            right_content=right,
        )

    elif kind == "code-content":
        # code goes on left, body on right — flipped layout
        # For simplicity, render as content-code (body left, code right)
        right = {"type": "code", "code": slide_data["code"]}
        build_content_slide(
            prs, label, section_title,
            slide_data["title"],
            slide_data["body"],
            page_no, total_pages,
            slide_data["notes"],
            right_content=right,
        )

    elif kind == "diagram":
        build_diagram_slide(
            prs, label, section_title,
            slide_data["title"],
            slide_data["diagram"],
            slide_data["caption"],
            page_no, total_pages,
            slide_data["notes"],
        )

    elif kind == "stat-row":
        build_stat_row(
            prs, label, section_title,
            slide_data["title"],
            slide_data["stats"],
            page_no, total_pages,
            slide_data["notes"],
        )

    elif kind == "demo-cue":
        build_demo_cue(
            prs, label, section_title,
            slide_data["demo_num"],
            slide_data["demo_name"],
            slide_data["demo_command"],
            slide_data["demo_description"],
            slide_data["demo_url"],
            page_no, total_pages,
            slide_data["notes"],
        )

    else:
        raise ValueError(f"Unknown slide kind: {kind}")

