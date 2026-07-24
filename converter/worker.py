from __future__ import annotations

import json
import sys
import tempfile
from typing import Any, TextIO

from service import PROTOCOL_VERSION, ConversionError, Converter


FILE_RESULT_THRESHOLD = 256 * 1024


def emit(payload: dict[str, Any], stream: TextIO = sys.stdout) -> None:
    stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    stream.flush()


def error_payload(request_id: str, error: ConversionError) -> dict[str, Any]:
    return {
        "v": PROTOCOL_VERSION,
        "id": request_id,
        "type": "result",
        "ok": False,
        "error": {
            "code": error.code,
            "message": error.message,
            "retryable": error.retryable,
        },
    }


def handle_request(message: Any, converter: Converter) -> tuple[dict[str, Any], bool]:
    if not isinstance(message, dict):
        raise ConversionError("protocol_error", "request must be a JSON object")

    request_id = message.get("id")
    if not isinstance(request_id, str) or not request_id:
        raise ConversionError("protocol_error", "request id must be a non-empty string")
    if message.get("v") != PROTOCOL_VERSION:
        return error_payload(
            request_id,
            ConversionError("protocol_error", "unsupported protocol version"),
        ), False

    method = message.get("method")
    if method == "ping":
        return {
            "v": PROTOCOL_VERSION,
            "id": request_id,
            "type": "pong",
            "ok": True,
        }, False
    if method == "shutdown":
        return {
            "v": PROTOCOL_VERSION,
            "id": request_id,
            "type": "result",
            "ok": True,
            "data": {},
        }, True
    if method != "convert":
        return error_payload(
            request_id,
            ConversionError("protocol_error", f"unknown method: {method}"),
        ), False

    params = message.get("params")
    if not isinstance(params, dict):
        return error_payload(
            request_id,
            ConversionError("protocol_error", "params must be an object"),
        ), False
    input_path = params.get("inputPath")
    input_type = params.get("inputType")
    if not isinstance(input_path, str) or not input_path:
        return error_payload(
            request_id,
            ConversionError("protocol_error", "inputPath must be a string"),
        ), False
    if input_type is not None and not isinstance(input_type, str):
        return error_payload(
            request_id,
            ConversionError("protocol_error", "inputType must be a string"),
        ), False

    try:
        result = converter.convert(input_path, input_type)
    except ConversionError as error:
        return error_payload(request_id, error), False

    data: dict[str, Any] = {
        "warnings": result.warnings,
        "assets": [],
        "stats": {"characterCount": len(result.markdown)},
    }
    if params.get("preferFileResult") is True and len(result.markdown) > FILE_RESULT_THRESHOLD:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix="any2md-result-",
            suffix=".md",
            delete=False,
        ) as result_file:
            result_file.write(result.markdown)
            data["markdownPath"] = result_file.name
    else:
        data["markdown"] = result.markdown

    return {
        "v": PROTOCOL_VERSION,
        "id": request_id,
        "type": "result",
        "ok": True,
        "data": data,
    }, False


def run(input_stream: TextIO = sys.stdin, output_stream: TextIO = sys.stdout) -> int:
    converter = Converter()
    emit(
        {
            "v": PROTOCOL_VERSION,
            "type": "ready",
            "capabilities": ["convert", "result_file"],
        },
        output_stream,
    )
    for raw_line in input_stream:
        if not raw_line.strip():
            continue
        try:
            message = json.loads(raw_line)
            payload, should_stop = handle_request(message, converter)
        except json.JSONDecodeError as error:
            payload = error_payload(
                "unknown",
                ConversionError("protocol_error", f"invalid JSON: {error.msg}"),
            )
            should_stop = False
        except ConversionError as error:
            payload = error_payload("unknown", error)
            should_stop = False
        except Exception as error:
            print(f"worker failure: {error}", file=sys.stderr, flush=True)
            payload = error_payload(
                "unknown",
                ConversionError("conversion_failed", str(error), retryable=True),
            )
            should_stop = False
        emit(payload, output_stream)
        if should_stop:
            return 0
    return 0


def main() -> int:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="strict")
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
