from pathlib import Path

import pytest
from docx import Document
from openpyxl import Workbook
from pptx import Presentation
from reportlab.pdfgen import canvas

from service import ConversionError, Converter


@pytest.fixture(scope="module")
def converter():
    return Converter()


def test_converts_docx(tmp_path: Path, converter: Converter):
    source = tmp_path / "report.docx"
    document = Document()
    document.add_heading("Quarterly Report", level=1)
    document.add_paragraph("Revenue increased.")
    document.save(source)

    result = converter.convert(str(source), "docx")

    assert "Quarterly Report" in result.markdown
    assert "Revenue increased" in result.markdown


def test_converts_xlsx(tmp_path: Path, converter: Converter):
    source = tmp_path / "budget.xlsx"
    workbook = Workbook()
    sheet = workbook.active
    sheet.append(["Department", "Budget"])
    sheet.append(["Research", 1200])
    workbook.save(source)

    result = converter.convert(str(source), "xlsx")

    assert "Department" in result.markdown
    assert "Research" in result.markdown


def test_converts_pptx(tmp_path: Path, converter: Converter):
    source = tmp_path / "slides.pptx"
    presentation = Presentation()
    slide = presentation.slides.add_slide(presentation.slide_layouts[1])
    slide.shapes.title.text = "Launch Plan"
    slide.placeholders[1].text = "Prepare beta release"
    presentation.save(source)

    result = converter.convert(str(source), "pptx")

    assert "Launch Plan" in result.markdown
    assert "Prepare beta release" in result.markdown


def test_converts_text_pdf(tmp_path: Path, converter: Converter):
    source = tmp_path / "memo.pdf"
    document = canvas.Canvas(str(source))
    document.drawString(72, 760, "Any2MD text PDF conversion fixture")
    document.save()

    result = converter.convert(str(source), "pdf")

    assert "Any2MD text PDF conversion fixture" in result.markdown


def test_rejects_pdf_without_text(tmp_path: Path, converter: Converter):
    source = tmp_path / "blank.pdf"
    document = canvas.Canvas(str(source))
    document.showPage()
    document.save()

    with pytest.raises(ConversionError) as caught:
        converter.convert(str(source), "pdf")

    assert caught.value.code == "no_extractable_text"


@pytest.mark.parametrize(
    ("name", "content", "expected"),
    [
        ("notes.txt", "Local Markdown conversion", "Local Markdown conversion"),
        ("data.csv", "Name,Value\nAlpha,42\n", "Alpha"),
        ("page.html", "<h1>Local HTML</h1><p>Converted safely.</p>", "Local HTML"),
    ],
)
def test_converts_text_formats(
    tmp_path: Path,
    converter: Converter,
    name: str,
    content: str,
    expected: str,
):
    source = tmp_path / name
    source.write_text(content, encoding="utf-8")

    result = converter.convert(str(source))

    assert expected in result.markdown
