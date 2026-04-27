#!/usr/bin/env python3
import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("model")
    parser.add_argument("--language", default=None)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        import whisper
    except Exception as exc:
        print(f"python openai-whisper import failed: {exc}", file=sys.stderr)
        return 2

    try:
        model = whisper.load_model(args.model)
        result = model.transcribe(
            args.input,
            language=args.language,
            word_timestamps=True,
            verbose=False,
        )
    except Exception as exc:
        print(f"python openai-whisper transcription failed: {exc}", file=sys.stderr)
        return 1

    payload = {
        "text": result.get("text", ""),
        "language": result.get("language"),
        "segments": [],
    }
    for segment in result.get("segments", []):
        payload["segments"].append(
            {
                "id": segment.get("id"),
                "start": float(segment.get("start", 0.0)),
                "end": float(segment.get("end", 0.0)),
                "text": segment.get("text", ""),
            }
        )

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
