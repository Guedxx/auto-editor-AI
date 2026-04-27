## Shared utilities for the `ai` modules: small JSON helpers, path/script
## resolvers, media-duration lookup, and misc glue.

import std/[json, math, os, strformat]

import ../[av, log]

proc jsonFloat*(node: JsonNode, key: string, fallback: float64): float64 =
  if node.kind == JObject and node.hasKey(key):
    case node[key].kind
    of JInt: return node[key].getInt().float64
    of JFloat: return node[key].getFloat()
    else: discard
  fallback

proc jsonStr*(node: JsonNode, key, fallback: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    return node[key].getStr()
  fallback

proc packSeconds*(sec: float64): PackedInt =
  pack(true, int64(round(max(sec, 0.0) * 1000.0)))

proc mediaDuration*(path: string): float64 =
  let input = (try: av.open(path) except IOError as e: error e.msg)
  defer: input.close()
  mediaLength(input).float64

proc resolveFaceScript*(path: string): string =
  if path != "":
    if not fileExists(path):
      error &"--ai-face-script does not exist: {path}"
    return path

  let cwdScript = getCurrentDir() / "scripts" / "ai_face_detect.py"
  if fileExists(cwdScript):
    return cwdScript

  let appScript = getAppDir() / "scripts" / "ai_face_detect.py"
  if fileExists(appScript):
    return appScript

  error "Could not find scripts/ai_face_detect.py. Use --ai-face-script PATH."

proc resolvePython*(path: string): string =
  if path != "":
    if not fileExists(path):
      error &"--ai-python does not exist: {path}"
    return path

  let venvPython = getCurrentDir() / ".venv" / "bin" / "python"
  if fileExists(venvPython):
    return venvPython

  "python3"

proc resolveWhisperPython*(path: string): string =
  if path != "":
    if not fileExists(path):
      error &"--ai-whisper-python does not exist: {path}"
    return path
  "python3"

proc resolveWhisperScript*(): string =
  let cwdScript = getCurrentDir() / "scripts" / "ai_transcribe_whisper.py"
  if fileExists(cwdScript):
    return cwdScript

  let appScript = getAppDir() / "scripts" / "ai_transcribe_whisper.py"
  if fileExists(appScript):
    return appScript

  error "Could not find scripts/ai_transcribe_whisper.py."

proc findProgram*(candidates: openArray[string]): string =
  for candidate in candidates:
    if candidate != "":
      let found = findExe(candidate)
      if found != "":
        return found
  ""
