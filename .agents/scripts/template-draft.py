#!/usr/bin/env python3
"""
template-draft.py - Generate a draft ODT document template with placeholders.

Part of aidevops document-creation-helper.sh (extracted for complexity reduction).

Usage: template-draft.py <output_path> <doc_type> [fields] [header_logo] [footer_text]
  output_path:  path to write the .odt file
  doc_type:     document type (letter, report, invoice, statement, etc.)
  fields:       comma-separated placeholder field names (optional)
  header_logo:  path to logo image for header (optional)
  footer_text:  footer text string (optional)
"""

import sys
import os

from odf.opendocument import OpenDocumentText
from odf.style import (
    Style,
    MasterPage,
    PageLayout,
    PageLayoutProperties,
    TextProperties,
    ParagraphProperties,
    GraphicProperties,
    Header as StyleHeader,
    Footer as StyleFooter,
    FontFace,
    HeaderStyle,
    FooterStyle,
)
from odf.text import P, PageNumber, PageCount
from odf.draw import Frame, Image
from odf import dc


def build_styles(doc: OpenDocumentText) -> dict:
    """Create and register all paragraph/text styles. Returns style name map."""
    # Font
    ff = FontFace(attributes={
        "name": "Arial",
        "fontfamily": "Arial",
        "fontfamilygeneric": "swiss",
        "fontpitch": "variable",
    })
    doc.fontfacedecls.addElement(ff)

    # Page layout
    pl = PageLayout(name="ContentLayout")
    pl.addElement(PageLayoutProperties(
        pagewidth="21.001cm", pageheight="29.7cm",
        margintop="2.5cm", marginbottom="3cm",
        marginleft="2cm", marginright="2cm",
        printorientation="portrait",
    ))
    pl.addElement(HeaderStyle())
    pl.addElement(FooterStyle())
    doc.automaticstyles.addElement(pl)

    heading = Style(name="Heading", family="paragraph")
    heading.addElement(TextProperties(fontname="Arial", fontsize="14pt", fontweight="bold"))
    heading.addElement(ParagraphProperties(marginbottom="0.3cm", margintop="0.5cm"))
    doc.styles.addElement(heading)

    body = Style(name="Body", family="paragraph")
    body.addElement(TextProperties(fontname="Arial", fontsize="11pt"))
    body.addElement(ParagraphProperties(
        lineheight="150%", marginbottom="0.3cm", textalign="justify"
    ))
    doc.styles.addElement(body)

    placeholder = Style(name="Placeholder", family="paragraph")
    placeholder.addElement(TextProperties(fontname="Arial", fontsize="11pt", color="#cc0000"))
    placeholder.addElement(ParagraphProperties(lineheight="150%", marginbottom="0.3cm"))
    doc.styles.addElement(placeholder)

    footer_s = Style(name="FooterText", family="paragraph")
    footer_s.addElement(TextProperties(fontname="Arial", fontsize="7pt", color="#888888"))
    footer_s.addElement(ParagraphProperties(textalign="center", lineheight="120%"))
    doc.styles.addElement(footer_s)

    footer_pg = Style(name="FooterPage", family="paragraph")
    footer_pg.addElement(TextProperties(fontname="Arial", fontsize="9pt", color="#666666"))
    footer_pg.addElement(ParagraphProperties(textalign="center"))
    doc.styles.addElement(footer_pg)

    header_s = Style(name="HeaderPara", family="paragraph")
    header_s.addElement(ParagraphProperties(textalign="end"))
    doc.styles.addElement(header_s)

    img_style = Style(name="ImgFrame", family="graphic")
    img_style.addElement(GraphicProperties(
        verticalpos="top", verticalrel="paragraph",
        horizontalpos="center", horizontalrel="paragraph",
        wrap="none",
    ))
    doc.automaticstyles.addElement(img_style)

    return {
        "body": body,
        "placeholder": placeholder,
        "footer_s": footer_s,
        "footer_pg": footer_pg,
        "header_s": header_s,
        "img_style": img_style,
    }


def build_master_page(
    doc: OpenDocumentText,
    styles: dict,
    header_logo: str,
    footer_text: str,
) -> None:
    """Create master page with header and footer."""
    master = MasterPage(name="Standard", pagelayoutname="ContentLayout")

    # Header
    header = StyleHeader()
    hp = P(stylename="HeaderPara")
    if header_logo and os.path.isfile(header_logo):
        href = doc.addPicture(header_logo)
        frame = Frame(
            stylename=styles["img_style"],
            width="4.5cm", height="1.13cm", anchortype="as-char",
        )
        frame.addElement(Image(href=href))
        hp.addElement(frame)
    else:
        hp.addText("{{header_logo}}")
    header.addElement(hp)
    master.addElement(header)

    # Footer
    footer = StyleFooter()
    fp1 = P(stylename="FooterPage")
    fp1.addText("Page ")
    fp1.addElement(PageNumber(selectpage="current"))
    fp1.addText(" of ")
    fp1.addElement(PageCount())
    footer.addElement(fp1)

    fp2 = P(stylename="FooterText")
    fp2.addText(footer_text if footer_text else "{{footer_text}}")
    footer.addElement(fp2)

    master.addElement(footer)
    doc.masterstyles.addElement(master)


def add_content(
    doc: OpenDocumentText,
    styles: dict,
    doc_type: str,
    fields: list,
) -> None:
    """Add title placeholder and field placeholders to document body."""
    title_s = Style(name="TitlePara", family="paragraph", masterpagename="Standard")
    title_s.addElement(TextProperties(
        fontname="Arial", fontsize="18pt", fontweight="bold"
    ))
    title_s.addElement(ParagraphProperties(
        textalign="center", marginbottom="1cm", breakbefore="page"
    ))
    doc.automaticstyles.addElement(title_s)

    p = P(stylename="TitlePara")
    p.addText("{{title}}")
    doc.text.addElement(p)

    doc.text.addElement(P(stylename="Body"))

    # Add placeholder fields
    if fields:
        for field in fields:
            fp = P(stylename="Placeholder")
            fp.addText("{{" + field + "}}")
            doc.text.addElement(fp)
    else:
        # Default fields based on document type
        defaults = {
            "letter": [
                "date", "recipient_name", "recipient_address",
                "subject", "body", "signoff", "author",
            ],
            "report": ["title", "author", "date", "summary", "body"],
            "invoice": [
                "invoice_number", "date", "client_name", "client_address",
                "items", "subtotal", "vat", "total",
            ],
            "statement": [
                "title", "property_name", "property_address",
                "date", "author", "body",
            ],
        }
        for field in defaults.get(doc_type, ["title", "date", "author", "body"]):
            fp = P(stylename="Placeholder")
            fp.addText("{{" + field + "}}")
            doc.text.addElement(fp)


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: template-draft.py <output_path> <doc_type> "
            "[fields] [header_logo] [footer_text]",
            file=sys.stderr,
        )
        sys.exit(1)

    output_path = sys.argv[1]
    doc_type = sys.argv[2]
    fields_str = sys.argv[3] if len(sys.argv) > 3 else ""
    header_logo = sys.argv[4] if len(sys.argv) > 4 else ""
    footer_text = sys.argv[5] if len(sys.argv) > 5 else ""

    fields = [f.strip() for f in fields_str.split(",") if f.strip()] if fields_str else []

    doc = OpenDocumentText()
    styles = build_styles(doc)
    build_master_page(doc, styles, header_logo, footer_text)
    add_content(doc, styles, doc_type, fields)

    # Metadata
    doc.meta.addElement(dc.Title(text=f"{doc_type.title()} Template"))
    doc.meta.addElement(dc.Description(
        text=f"Draft template for {doc_type} documents. "
        "Replace {{placeholders}} with actual content."
    ))

    doc.save(output_path)
    print(f"Template saved: {output_path}")


if __name__ == '__main__':
    main()
