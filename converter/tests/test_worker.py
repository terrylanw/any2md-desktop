import io
import json
from pathlib import Path

from service import (
    ConversionResult,
    Converter,
    WorkbookInspection,
    WorkbookSheetInfo,
)
from worker import handle_request, run


class FakeConverter(Converter):
    def convert(
        self,
        raw_path: str,
        requested_type: str | None = None,
        sheet_names: list[str] | None = None,
    ):
        return ConversionResult("# Converted\n", ["example_warning"])

    def inspect_workbook(
        self, raw_path: str, requested_type: str | None = None
    ):
        return WorkbookInspection(
            sheets=[
                WorkbookSheetInfo(
                    name="Summary",
                    index=0,
                    visibility="visible",
                    is_empty=False,
                    row_count=2,
                    column_count=2,
                    preview=[["Name", "Value"], ["Alpha", "42"]],
                )
            ]
        )


def test_worker_emits_ready_and_conversion_result():
    request = {
        "v": 1,
        "id": "task-1",
        "method": "convert",
        "params": {"inputPath": "C:\\test.docx", "inputType": "docx"},
    }
    input_stream = io.StringIO(json.dumps(request) + "\n")
    output_stream = io.StringIO()

    original_convert = Converter.convert
    Converter.convert = FakeConverter.convert
    try:
        assert run(input_stream, output_stream) == 0
    finally:
        Converter.convert = original_convert

    messages = [json.loads(line) for line in output_stream.getvalue().splitlines()]
    assert messages[0]["type"] == "ready"
    assert messages[1]["ok"] is True
    assert messages[1]["data"]["markdown"] == "# Converted\n"


def test_ping_and_shutdown():
    converter = FakeConverter()
    pong, should_stop = handle_request(
        {"v": 1, "id": "ping-1", "method": "ping"}, converter
    )
    assert pong["type"] == "pong"
    assert should_stop is False

    response, should_stop = handle_request(
        {"v": 1, "id": "stop-1", "method": "shutdown"}, converter
    )
    assert response["ok"] is True
    assert should_stop is True


def test_inspect_workbook_returns_sheet_metadata():
    response, should_stop = handle_request(
        {
            "v": 1,
            "id": "inspect-1",
            "method": "inspect_workbook",
            "params": {"inputPath": "C:\\test.xlsx", "inputType": "xlsx"},
        },
        FakeConverter(),
    )

    assert should_stop is False
    assert response["ok"] is True
    assert response["data"]["sheets"][0]["name"] == "Summary"
    assert response["data"]["sheets"][0]["preview"][1] == ["Alpha", "42"]


def test_rejects_invalid_sheet_names_payload():
    response, should_stop = handle_request(
        {
            "v": 1,
            "id": "bad-sheets",
            "method": "convert",
            "params": {
                "inputPath": "C:\\test.xlsx",
                "inputType": "xlsx",
                "sheetNames": ["Summary", 42],
            },
        },
        FakeConverter(),
    )

    assert should_stop is False
    assert response["error"]["code"] == "protocol_error"


def test_unknown_method_is_protocol_error():
    response, should_stop = handle_request(
        {"v": 1, "id": "bad-1", "method": "missing"}, FakeConverter()
    )
    assert should_stop is False
    assert response["error"]["code"] == "protocol_error"


def test_emit_preserves_non_ascii_markdown():
    output_stream = io.StringIO()
    from worker import emit

    emit({"markdown": "中文 और Markdown"}, output_stream)
    assert json.loads(output_stream.getvalue())["markdown"] == "中文 और Markdown"


def test_large_result_can_be_returned_through_temporary_file():
    class LargeConverter(Converter):
        def convert(
            self,
            raw_path: str,
            requested_type: str | None = None,
            sheet_names: list[str] | None = None,
        ):
            return ConversionResult("x" * (256 * 1024 + 1), [])

    response, should_stop = handle_request(
        {
            "v": 1,
            "id": "large-1",
            "method": "convert",
            "params": {
                "inputPath": "C:\\test.docx",
                "inputType": "docx",
                "preferFileResult": True,
            },
        },
        LargeConverter(),
    )

    result_path = Path(response["data"]["markdownPath"])
    try:
        assert should_stop is False
        assert "markdown" not in response["data"]
        assert result_path.read_text(encoding="utf-8") == "x" * (256 * 1024 + 1)
    finally:
        result_path.unlink(missing_ok=True)
