## Pure JSON construction / parsing helpers shared by the planner:
##
## - `TranscriptSegment` row type + `parseTranscript` that understands both
##   the Python Whisper (`{segments: [{start, end, text}]}`) shape and the
##   whisper.cpp `-oj` (`{transcription: [{offsets: {from, to}, text}]}`,
##   where `from`/`to` are milliseconds) shape.
## - `planSchema` JSON schema passed to OpenAI strict structured output,
##   including explicit `minimum`/`maximum` clamps and the `reason` field.
## - `extractOutputText` response walker for `/v1/responses` payloads.
## - `compactTranscriptJson` helper that serialises a filtered slice of
##   segments for a given window without whitespace.
##
## This module intentionally has zero dependencies on `log`, `util`, or
## `faces` so the planner can be trivially unit-tested and future caching
## (Phase 4) can re-use the same shapes.

import std/[json, math, strutils]

type
  TranscriptSegment* = object
    start*: float64
    endTime*: float64
    text*: string

proc parseTranscript*(raw: string): seq[TranscriptSegment] =
  ## Parse a raw transcript JSON string into a flat seq of `(start, end, text)`.
  ##
  ## Returns `@[]` (and silently, so the planner can still warn/continue)
  ## for malformed or empty payloads, or for schemas we don't recognise.
  result = @[]
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return

  var root: JsonNode
  try:
    root = parseJson(trimmed)
  except JsonParsingError, ValueError:
    return
  if root.kind != JObject:
    return

  # Python Whisper / ai_transcribe_whisper.py shape: `{segments: [...]}`.
  if root.hasKey("segments") and root["segments"].kind == JArray:
    for seg in root["segments"]:
      if seg.kind != JObject: continue
      var s, e: float64
      if seg.hasKey("start"):
        case seg["start"].kind
        of JInt: s = seg["start"].getInt().float64
        of JFloat: s = seg["start"].getFloat()
        else: continue
      else:
        continue
      if seg.hasKey("end"):
        case seg["end"].kind
        of JInt: e = seg["end"].getInt().float64
        of JFloat: e = seg["end"].getFloat()
        else: continue
      else:
        continue
      var text = ""
      if seg.hasKey("text") and seg["text"].kind == JString:
        text = seg["text"].getStr().strip()
      result.add TranscriptSegment(start: s, endTime: e, text: text)
    return

  # whisper.cpp `-oj` shape: `{transcription: [{offsets: {from, to}, text}]}`,
  # where offsets are milliseconds.
  if root.hasKey("transcription") and root["transcription"].kind == JArray:
    for seg in root["transcription"]:
      if seg.kind != JObject: continue
      if not seg.hasKey("offsets") or seg["offsets"].kind != JObject: continue
      let off = seg["offsets"]
      if not off.hasKey("from") or not off.hasKey("to"): continue
      var fromMs, toMs: float64
      case off["from"].kind
      of JInt: fromMs = off["from"].getInt().float64
      of JFloat: fromMs = off["from"].getFloat()
      else: continue
      case off["to"].kind
      of JInt: toMs = off["to"].getInt().float64
      of JFloat: toMs = off["to"].getFloat()
      else: continue
      var text = ""
      if seg.hasKey("text") and seg["text"].kind == JString:
        text = seg["text"].getStr().strip()
      result.add TranscriptSegment(
        start: fromMs / 1000.0,
        endTime: toMs / 1000.0,
        text: text,
      )
    return

  # Unknown shape: leave `result` empty.

proc planSchema*(): JsonNode =
  ## OpenAI strict structured-output schema for a per-chunk edit plan.
  ##
  ## `speed` / `zoom` have explicit min/max so the model can't return
  ## out-of-range values; `reason` is required (strict mode needs every
  ## declared property listed in `required`) and is used for debug logging
  ## only.
  %* {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "segments": {
        "type": "array",
        "items": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "start":  {"type": "number", "minimum": 0.0},
            "end":    {"type": "number", "minimum": 0.0},
            "action": {"type": "string", "enum": ["keep", "cut"]},
            "speed":  {"type": "number", "minimum": 0.75, "maximum": 1.5},
            "zoom":   {"type": "number", "minimum": 1.0,  "maximum": 1.35},
            "reason": {"type": "string"}
          },
          "required": ["start", "end", "action", "speed", "zoom", "reason"]
        }
      }
    },
    "required": ["segments"]
  }

proc extractOutputText*(node: JsonNode): string =
  ## Walks a `/v1/responses` payload and returns the first `output_text` it
  ## finds, either as a top-level shortcut field or inside the content array.
  if node.kind == JObject:
    if node.hasKey("output_text") and node["output_text"].kind == JString:
      return node["output_text"].getStr()
    if node.hasKey("type") and node["type"].kind == JString and
        node["type"].getStr() == "output_text" and
        node.hasKey("text") and node["text"].kind == JString:
      return node["text"].getStr()
    for _, child in node:
      let found = extractOutputText(child)
      if found != "":
        return found
  elif node.kind == JArray:
    for child in node:
      let found = extractOutputText(child)
      if found != "":
        return found
  ""

proc compactTranscriptJson*(segs: seq[TranscriptSegment],
    windowStart, windowStop: float64): string =
  ## Filter `segs` to those that overlap `[windowStart, windowStop]` and
  ## return a compact (no pretty-print) JSON array. Each entry is a
  ## `[start, end, text]` triple so the model gets tight token usage while
  ## keeping enough context to reason about phrase boundaries.
  var arr = newJArray()
  for s in segs:
    if s.endTime > windowStart and s.start < windowStop:
      var row = newJArray()
      row.add newJFloat(round(s.start, 3))
      row.add newJFloat(round(s.endTime, 3))
      row.add newJString(s.text)
      arr.add row
  $arr
