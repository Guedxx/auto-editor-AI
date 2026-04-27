import std/[httpclient, json, math, os, osproc, strformat, streams, strutils,
  times]

import ./[av, log]

type
  FaceSample = object
    time: float64
    x: float32
    y: float32
    size: float32

proc jsonFloat(node: JsonNode, key: string, fallback: float64): float64 =
  if node.kind == JObject and node.hasKey(key):
    case node[key].kind
    of JInt: return node[key].getInt().float64
    of JFloat: return node[key].getFloat()
    else: discard
  fallback

proc jsonStr(node: JsonNode, key, fallback: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    return node[key].getStr()
  fallback

proc stripEnvQuotes(value: string): string =
  result = value.strip()
  if result.len >= 2:
    if (result[0] == '"' and result[^1] == '"') or (result[0] == '\'' and result[^1] == '\''):
      result = result[1 .. ^2]

proc loadDotEnvValue(name: string): string =
  let envPath = getCurrentDir() / ".env"
  if not fileExists(envPath):
    return ""

  for line in readFile(envPath).splitLines():
    let trimmed = line.strip()
    if trimmed == "" or trimmed.startsWith("#"):
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let key = trimmed[0 ..< eq].strip()
    if key == name:
      return stripEnvQuotes(trimmed[eq + 1 .. ^1])
  ""

proc getSecret(name: string): string =
  result = getEnv(name)
  if result == "":
    result = loadDotEnvValue(name)

proc packSeconds(sec: float64): PackedInt =
  pack(true, int64(round(max(sec, 0.0) * 1000.0)))

proc mediaDuration(path: string): float64 =
  let input = (try: av.open(path) except IOError as e: error e.msg)
  defer: input.close()
  mediaLength(input).float64

proc resolveFaceScript(path: string): string =
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

proc resolvePython(path: string): string =
  if path != "":
    if not fileExists(path):
      error &"--ai-python does not exist: {path}"
    return path

  let venvPython = getCurrentDir() / ".venv" / "bin" / "python"
  if fileExists(venvPython):
    return venvPython

  "python3"

proc resolveWhisperPython(path: string): string =
  if path != "":
    if not fileExists(path):
      error &"--ai-whisper-python does not exist: {path}"
    return path
  "python3"

proc resolveWhisperScript(): string =
  let cwdScript = getCurrentDir() / "scripts" / "ai_transcribe_whisper.py"
  if fileExists(cwdScript):
    return cwdScript

  let appScript = getAppDir() / "scripts" / "ai_transcribe_whisper.py"
  if fileExists(appScript):
    return appScript

  error "Could not find scripts/ai_transcribe_whisper.py."

proc findProgram(candidates: openArray[string]): string =
  for candidate in candidates:
    if candidate != "":
      let found = findExe(candidate)
      if found != "":
        return found
  ""

proc runPythonWhisper(inputPath, model, language, pythonPath: string): string =
  let scriptPath = resolveWhisperScript()
  let outPath = getTempDir() / (&"auto-editor-ai-python-whisper-{epochTime()}.json")
  var cmd = @[scriptPath, inputPath, model, "--output", outPath]
  if language != "" and language != "auto":
    cmd.add @["--language", language]

  conwrite("AI: transcribing with Python Whisper...")
  var p: Process
  try:
    p = startProcess(pythonPath, args = cmd, options = {poUsePath, poStdErrToStdOut})
  except OSError:
    error &"Could not start Python Whisper: {getCurrentExceptionMsg()}"
  defer: p.close()

  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    error &"Python Whisper failed:\n{output.strip()}"
  if not fileExists(outPath):
    error &"Python Whisper did not produce JSON: {outPath}"

  result = readFile(outPath)
  try:
    removeFile(outPath)
  except OSError:
    discard

proc runWhisperCli(inputPath, model, language, command, pythonPath: string): string =
  let whisperCli = if command != "": command else: findProgram(["whisper-cli", "whisper.cpp", "main"])
  if whisperCli == "" or not fileExists(whisperCli):
    warning "No whisper.cpp CLI was found; trying Python Whisper."
    return runPythonWhisper(inputPath, model, language, pythonPath)

  let root = getTempDir() / (&"auto-editor-ai-whisper-{epochTime()}")
  let wavPath = root & ".wav"
  let outPrefix = root & "-out"
  let outJson = outPrefix & ".json"

  var ffmpeg: Process
  try:
    ffmpeg = startProcess("ffmpeg", args = @[
      "-y", "-v", "error", "-i", inputPath, "-vn", "-ac", "1", "-ar", "16000", wavPath
    ], options = {poUsePath, poParentStreams})
  except OSError:
    error &"Could not start ffmpeg for whisper.cpp audio extraction: {getCurrentExceptionMsg()}"
  defer: ffmpeg.close()
  let ffmpegCode = ffmpeg.waitForExit()
  if ffmpegCode != 0:
    error &"ffmpeg audio extraction for whisper.cpp failed with exit code {ffmpegCode}"

  var cmd = @["-m", model, "-f", wavPath, "-oj", "-of", outPrefix]
  if language != "" and language != "auto":
    cmd.add @["-l", language]

  var whisper: Process
  try:
    whisper = startProcess(whisperCli, args = cmd, options = {poUsePath, poParentStreams})
  except OSError:
    error &"Could not start whisper.cpp CLI: {getCurrentExceptionMsg()}"
  defer: whisper.close()
  let code = whisper.waitForExit()
  if code != 0:
    warning &"whisper.cpp CLI failed with exit code {code}; trying Python Whisper."
    return runPythonWhisper(inputPath, model, language, pythonPath)
  if not fileExists(outJson):
    warning "whisper.cpp CLI did not produce JSON; trying Python Whisper."
    return runPythonWhisper(inputPath, model, language, pythonPath)

  result = readFile(outJson)
  for path in [wavPath, outJson]:
    try:
      removeFile(path)
    except OSError:
      discard

proc runWhisper(inputPath, model, language, command, pythonPath: string): string =
  if model == "":
    error "--ai requires --ai-whisper-model MODEL_OR_PATH"
  if not fileExists(model):
    warning &"--ai-whisper-model is not a file; treating '{model}' as a Python Whisper model name."
    return runPythonWhisper(inputPath, model, language, pythonPath)

  let outPath = getTempDir() / (&"auto-editor-ai-transcript-{epochTime()}.json")
  var cmd = @["whisper", inputPath, model, "--format", "json", "--output", outPath]
  if language != "":
    cmd.add @["--language", language]

  conwrite("AI: transcribing audio...")
  var p: Process
  try:
    p = startProcess(getAppFilename(), args = cmd, options = {poUsePath, poParentStreams})
  except OSError:
    error &"Could not start whisper subprocess: {getCurrentExceptionMsg()}"
  defer: p.close()
  let code = p.waitForExit()
  if code != 0:
    warning &"FFmpeg whisper filter failed with exit code {code}; trying whisper.cpp CLI."
    return runWhisperCli(inputPath, model, language, command, pythonPath)
  if not fileExists(outPath):
    warning "FFmpeg whisper filter did not produce a transcript; trying whisper.cpp CLI."
    return runWhisperCli(inputPath, model, language, command, pythonPath)
  result = readFile(outPath)
  try:
    removeFile(outPath)
  except OSError:
    discard

proc runFaceDetection(inputPath, scriptPath, pythonPath: string): seq[FaceSample] =
  conwrite("AI: detecting faces...")
  var p: Process
  try:
    p = startProcess(pythonPath, args = @[scriptPath, inputPath],
      options = {poUsePath, poStdErrToStdOut})
  except OSError:
    error &"Could not start Python for OpenCV face detection: {getCurrentExceptionMsg()}"
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    error &"OpenCV face detection failed:\n{output.strip()}"

  let node = (try: parseJson(output) except JsonParsingError as e:
    error &"OpenCV face helper returned invalid JSON: {e.msg}")
  if node.kind != JArray:
    error "OpenCV face helper must return a JSON array"

  for item in node:
    if item.kind != JObject:
      continue
    result.add FaceSample(
      time: jsonFloat(item, "time", 0.0),
      x: jsonFloat(item, "x", -1.0).float32,
      y: jsonFloat(item, "y", -1.0).float32,
      size: jsonFloat(item, "size", 0.0).float32,
    )

proc nearestFace(faces: seq[FaceSample], start, stop: float64): (float32, float32) =
  if faces.len == 0:
    return (-1.0'f32, -1.0'f32)
  let midpoint = (start + stop) / 2.0
  var best = faces[0]
  var bestScore = abs(best.time - midpoint) - best.size.float64
  for face in faces:
    let score = abs(face.time - midpoint) - face.size.float64
    if score < bestScore:
      best = face
      bestScore = score
  if abs(best.time - midpoint) > max(4.0, (stop - start) / 2.0 + 1.0):
    return (-1.0'f32, -1.0'f32)
  (best.x, best.y)

proc faceSamplesJson(faces: seq[FaceSample], start, stop: float64): JsonNode =
  result = newJArray()
  var added = 0
  for face in faces:
    if face.time >= start and face.time <= stop:
      result.add(%* {
        "time": round(face.time, 2),
        "x": round(face.x.float64, 3),
        "y": round(face.y.float64, 3),
        "size": round(face.size.float64, 4),
      })
      inc added
      if added >= 80:
        break

proc planSchema(): JsonNode =
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
            "start": {"type": "number"},
            "end": {"type": "number"},
            "action": {"type": "string", "enum": ["keep", "cut"]},
            "speed": {"type": "number"},
            "zoom": {"type": "number"}
          },
          "required": ["start", "end", "action", "speed", "zoom"]
        }
      }
    },
    "required": ["segments"]
  }

proc extractOutputText(node: JsonNode): string =
  if node.kind == JObject:
    if node.hasKey("output_text") and node["output_text"].kind == JString:
      return node["output_text"].getStr()
    if node.hasKey("type") and jsonStr(node, "type", "") == "output_text" and
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

proc openAiPlanChunk(args: mainArgs, transcript: string, faces: seq[FaceSample],
    start, stop, duration: float64): JsonNode =
  let apiKey = getSecret("OPENAI_API_KEY")
  if apiKey == "":
    error "--ai-provider openai requires OPENAI_API_KEY in the environment or .env"

  let prompt = &"""
Plan an automatic video edit for only this time window.

Window start seconds: {start}
Window end seconds: {stop}
Full media duration seconds: {duration}

Return concise timeline segments inside this window. Use:
- action "cut" for filler, long pauses, false starts, repeated phrases, and dead air.
- action "keep" for useful speech.
- speed 1.0 for normal speech, 1.05-1.35 to tighten slow phrases, never below 0.75 or above 1.5.
- zoom 1.0 for no zoom, 1.08-1.30 for useful emphasis.
Do not invent times outside the window. Prefer phrase-boundary cuts.

Transcript JSON/text:
{transcript}

Face samples in this window, normalized x/y:
{faceSamplesJson(faces, start, stop)}
"""

  let payload = %* {
    "model": args.aiModel,
    "input": [
      {
        "role": "system",
        "content": "You are an autonomous video editing planner. Return only valid structured JSON."
      },
      {
        "role": "user",
        "content": prompt
      }
    ],
    "text": {
      "format": {
        "type": "json_schema",
        "name": "auto_editor_ai_plan",
        "strict": true,
        "schema": planSchema()
      }
    }
  }

  conwrite(&"AI: planning {round(start, 1)}s-{round(stop, 1)}s...")
  var client = newHttpClient()
  client.headers = newHttpHeaders([
    ("Authorization", "Bearer " & apiKey),
    ("Content-Type", "application/json"),
  ])
  var response: string
  try:
    let res = client.request("https://api.openai.com/v1/responses",
      httpMethod = HttpPost, body = $payload)
    response = res.body
    if not res.status.startsWith("2"):
      error &"OpenAI request failed: {res.status}\n{response}"
  except CatchableError:
    error &"OpenAI request failed: {getCurrentExceptionMsg()}"
  let responseJson = (try: parseJson(response) except JsonParsingError as e:
    error &"OpenAI returned invalid JSON: {e.msg}")
  if responseJson.kind == JObject and responseJson.hasKey("error") and responseJson["error"].kind != JNull:
    let err = $(responseJson["error"])
    error &"OpenAI error: {err}"

  let text = extractOutputText(responseJson).strip()
  if text == "":
    error &"OpenAI response did not contain output_text:\n{pretty(responseJson)}"
  try:
    result = parseJson(text)
  except JsonParsingError as e:
    error &"OpenAI output was not valid edit-plan JSON: {e.msg}"

proc addPlanActions(args: var mainArgs, plan: JsonNode, faces: seq[FaceSample],
    chunkStart, chunkStop, duration: float64) =
  if plan.kind != JObject or not plan.hasKey("segments") or plan["segments"].kind != JArray:
    error "AI edit plan must contain a segments array"

  var lastStop = chunkStart
  for seg in plan["segments"]:
    if seg.kind != JObject:
      continue
    var start = max(chunkStart, min(duration, jsonFloat(seg, "start", chunkStart)))
    var stop = max(chunkStart, min(duration, jsonFloat(seg, "end", chunkStop)))
    stop = min(stop, chunkStop)
    if stop <= start:
      continue
    if start < lastStop - 0.001:
      error &"AI edit plan has overlapping or unsorted segments near {start}s"
    lastStop = stop

    let action = jsonStr(seg, "action", "keep")
    var group = aNil
    if action == "cut":
      group = aCut
    elif action == "keep":
      var list: seq[Action]
      let speed = max(0.75, min(1.5, jsonFloat(seg, "speed", 1.0)))
      let zoom = max(1.0, min(1.35, jsonFloat(seg, "zoom", 1.0)))
      if abs(speed - 1.0) > 0.01:
        list.add Action(kind: actSpeed, val: speed.float32)
      if zoom > 1.01:
        let (x, y) = nearestFace(faces, start, stop)
        list.add Action(kind: actZoom, val: zoom.float32, x: x, y: y)
      group = newActions(list)
    else:
      error &"AI edit plan has unknown action: {action}"

    args.setAction.add (group, packSeconds(start), packSeconds(stop))

proc applyAi*(args: var mainArgs) =
  if args.inputs.len != 1:
    error "--ai currently supports exactly one input file"
  if args.aiProvider != "openai":
    error &"--ai-provider '{args.aiProvider}' is not implemented yet. Use openai."
  if getSecret("OPENAI_API_KEY") == "":
    error "--ai-provider openai requires OPENAI_API_KEY in the environment or .env"
  if args.aiChunkSecs < 5 or args.aiChunkSecs > 600:
    error "--ai-chunk-secs must be between 5 and 600"

  let inputPath = args.inputs[0]
  let faceScript = resolveFaceScript(args.aiFaceScript)
  let pythonPath = resolvePython(args.aiPython)
  let whisperPython = resolveWhisperPython(args.aiWhisperPython)
  let duration = mediaDuration(inputPath)
  if duration <= 0.0:
    error "--ai could not determine media duration"

  let transcript = runWhisper(inputPath, args.aiWhisperModel, args.aiLanguage,
    args.aiWhisperCommand, whisperPython)
  let faces = runFaceDetection(inputPath, faceScript, pythonPath)

  let userActions = args.setAction
  args.setAction = @[]
  args.edit = "none"
  args.whenNormal = aNil

  var chunkStart = 0.0
  while chunkStart < duration:
    let chunkStop = min(duration, chunkStart + args.aiChunkSecs.float64)
    let plan = openAiPlanChunk(args, transcript, faces, chunkStart, chunkStop, duration)
    addPlanActions(args, plan, faces, chunkStart, chunkStop, duration)
    chunkStart = chunkStop

  for action in userActions:
    args.setAction.add action
  clearline()
