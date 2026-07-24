from pathlib import Path

import pytest

from service import ConversionError, extract_markdown, validate_input


class FakeResult:
    def __init__(self, text_content: str):
        self.text_content = text_content


def test_extract_markdown_from_text_content():
    assert extract_markdown(FakeResult("hello")) == "hello"


def test_extract_markdown_from_string():
    assert extract_markdown("hello") == "hello"


def test_rejects_relative_path():
    with pytest.raises(ConversionError, match="absolute") as caught:
        validate_input("relative.docx")
    assert caught.value.code == "invalid_input"


def test_rejects_unsupported_extension(tmp_path: Path):
    input_file = tmp_path / "test.bin"
    input_file.write_bytes(b"hello")
    with pytest.raises(ConversionError) as caught:
        validate_input(str(input_file))
    assert caught.value.code == "unsupported_type"


def test_validates_requested_type(tmp_path: Path):
    input_file = tmp_path / "test.docx"
    input_file.write_bytes(b"fake")
    with pytest.raises(ConversionError) as caught:
        validate_input(str(input_file), "pdf")
    assert caught.value.code == "invalid_input"
