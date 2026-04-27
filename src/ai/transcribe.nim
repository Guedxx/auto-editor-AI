## Transcription backends: FFmpeg's bundled whisper filter, whisper.cpp CLI,
## and the Python Whisper fallback. All produce a JSON transcript string.

import std/[os, osproc, strformat, streams, strutils, times]

import ./util
import ../log

proc runPythonWhisper*(inputPath, model, language, pythonPath: string): string =
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

proc runWhisperCli*(inputPath, model, language, command, pythonPath: string): string =
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

proc runWhisper*(inputPath, model, language, command, pythonPath: string): string =
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
