from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Any


PROTOCOL_VERSION = 1
SUPPORTED_EXTENSIONS = {
    ".csv": "csv",
    ".docx": "docx",
    ".htm": "html",
    ".html": "html",
    ".pdf": "pdf",
    ".pptx": "pptx",
    ".txt": "txt",
    ".xlsx": "xlsx",
}


class ConversionError(Exception):
    def __init__(self, code: str, message: str, *, retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable


@dataclass(frozen=True)
class ConversionResult:
    markdown: str
    warnings: list[str]


def extract_markdown(result: Any) -> str:
    text_content = getattr(result, "text_content", None)
    if isinstance(text_content, str):
        return text_content

    markdown = getattr(result, "markdown", None)
    if isinstance(markdown, str):
        return markdown

    if isinstance(result, str):
        return result

    raise ConversionError(
        "conversion_failed",
        "MarkItDown returned an unsupported result type",
    )


def validate_input(raw_path: str, requested_type: str | None = None) -> Path:
    input_path = Path(raw_path).expanduser()
    if not input_path.is_absolute():
        raise ConversionError("invalid_input", "inputPath must be absolute")
    if not input_path.exists():
        raise ConversionError("unreadable_file", f"file not found: {input_path}")
    if not input_path.is_file():
        raise ConversionError("invalid_input", f"not a file: {input_path}")

    detected_type = SUPPORTED_EXTENSIONS.get(input_path.suffix.lower())
    if detected_type is None:
        raise ConversionError(
            "unsupported_type",
            f"unsupported file type: {input_path.suffix or '(none)'}",
        )
    if requested_type and requested_type != detected_type:
        raise ConversionError(
            "invalid_input",
            f"inputType {requested_type!r} does not match {detected_type!r}",
        )
    return input_path.resolve()


class Converter:
    def __init__(self) -> None:
        self._converter: Any | None = None

    def _get_converter(self) -> Any:
        if self._converter is None:
            from markitdown import MarkItDown

            self._converter = MarkItDown()
        return self._converter

    def convert(self, raw_path: str, requested_type: str | None = None) -> ConversionResult:
        input_path = validate_input(raw_path, requested_type)
        try:
            result = self._get_converter().convert(str(input_path))
            markdown = extract_markdown(result)
        except ConversionError:
            raise
        except PermissionError as error:
            raise ConversionError("unreadable_file", str(error)) from error
        except Exception as error:
            message = str(error) or error.__class__.__name__
            lowered = message.lower()
            if "password" in lowered or "encrypted" in lowered:
                code = "password_protected"
                retryable = False
            else:
                code = "conversion_failed"
                retryable = True
            raise ConversionError(code, message, retryable=retryable) from error

        warnings: list[str] = []
        if input_path.suffix.lower() == ".pdf":
            without_comments = re.sub(r"<!--.*?-->", "", markdown, flags=re.DOTALL)
            visible_text_length = sum(
                1 for character in without_comments if character.isalnum()
            )
            if visible_text_length == 0:
                raise ConversionError(
                    "no_extractable_text",
                    "PDF contains no extractable text; OCR is not available",
                )
            if visible_text_length < 50:
                warnings.append("possible_scanned_pdf")

        return ConversionResult(markdown=markdown, warnings=warnings)
