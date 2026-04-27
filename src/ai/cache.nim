## Artifact cache for the `--ai` pipeline (Phase 4).
##
## Caches three expensive artifacts on disk, keyed by stable hashes of the
## relevant inputs:
##
## - the Whisper transcript (depends on the video + model path/size + language)
## - the YuNet face-detection JSON (depends on the video + face-script mtime)
## - per-chunk OpenAI edit plans (depends on transcript hash + faces hash +
##   model + provider + chunk size + chunk window)
##
## Cache root defaults to `$XDG_CACHE_HOME/auto-editor-ai/` (or
## `~/.cache/auto-editor-ai/` if `XDG_CACHE_HOME` is empty), falling back to
## `$LOCALAPPDATA\auto-editor-ai\` on Windows and to `os.getCacheDir()` if
## neither variable resolves. Artifacts are stored two-level-deep,
## `<root>/<hash[0..1]>/<hash[2..]>.{json,txt}`, so `ls` on the root stays
## responsive even with thousands of entries.
##
## Cache invalidation: every key bakes in a `schema=N` tag. Bumping N in this
## file instantly invalidates the corresponding artifact across all users.

import std/[json, options, os, strformat, times]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}

import ../log

const
  TranscriptSchema = 1
  FacesSchema = 2
  PlanSchema = 3

type AiCache* = object
  enabled*: bool
  root*: string

proc cacheRoot(): string =
  ## Resolve the cache root. Honors `XDG_CACHE_HOME` on all platforms, then
  ## `LOCALAPPDATA` on Windows, and finally `getCacheDir()` as the
  ## cross-platform fallback. We do NOT create the directory here — the
  ## caller does that once, inside `initAiCache`, so that a creation failure
  ## can disable the cache for the whole run.
  let xdg = getEnv("XDG_CACHE_HOME")
  if xdg.len > 0:
    return xdg / "auto-editor-ai"
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      return local / "auto-editor-ai"
  try:
    return getCacheDir() / "auto-editor-ai"
  except OSError:
    return getHomeDir() / ".cache" / "auto-editor-ai"

proc fileFingerprint*(path: string): string =
  ## Cheap, stable fingerprint for a file: `sha1(abspath)|size|mtime_ns`.
  ## We only hash the absolute path string (not the contents) to keep this
  ## O(ms) even for multi-GB videos. Size + nanosecond mtime catch any
  ## in-place edits that preserved the filename.
  let abspath = try: absolutePath(path) except OSError, ValueError: path
  let sha = $secureHash(abspath)
  var size: int64 = -1
  var mtime: int64 = 0
  try:
    let info = getFileInfo(path)
    size = info.size
    mtime = info.lastWriteTime.toUnix * 1_000_000_000 +
      info.lastWriteTime.nanosecond
  except OSError:
    discard
  &"{sha}|{size}|{mtime}"

proc scriptFingerprint(path: string): string =
  ## Same as `fileFingerprint` but tolerates a missing script (shouldn't
  ## happen after `resolveFaceScript`, but defensive). Returned string still
  ## participates in the cache key so keys stay stable.
  if path == "":
    return "noscript"
  fileFingerprint(path)

proc isWritable(dir: string): bool =
  ## Probe by creating and deleting a sentinel file. `fpUserWrite` checks on
  ## the directory itself would miss cases where the FS is read-only.
  try:
    createDir(dir)
  except OSError, IOError:
    return false
  let probe = dir / ".ae-ai-write-probe"
  try:
    writeFile(probe, "")
    removeFile(probe)
    return true
  except OSError, IOError:
    return false

proc initAiCache*(args: mainArgs): AiCache =
  ## Resolve + prepare the cache root. On any IO failure we warn and return
  ## `enabled: false` so callers can degrade gracefully.
  result.enabled = false
  result.root = ""
  if args.aiNoCache:
    return result
  let root = cacheRoot()
  if not isWritable(root):
    warning &"AI cache directory not writable: {root}. Cache disabled for this run."
    return result
  result.enabled = true
  result.root = root

proc keyPaths(cache: AiCache, key, ext: string): (string, string, string) =
  ## Returns `(dir, finalPath, tmpPath)` for a given full hash key.
  let dir = cache.root / key[0 .. 1]
  let final = dir / (key[2 .. ^1] & ext)
  (dir, final, final & ".tmp")

proc writeAtomic(cache: AiCache, key, ext, data: string) =
  let (dir, final, tmp) = keyPaths(cache, key, ext)
  try:
    createDir(dir)
    writeFile(tmp, data)
    moveFile(tmp, final)
  except OSError, IOError:
    warning &"AI cache write failed for {final}: {getCurrentExceptionMsg()}"
    try: removeFile(tmp) except OSError, IOError: discard

proc readIfExists(cache: AiCache, key, ext: string): Option[string] =
  let (_, final, _) = keyPaths(cache, key, ext)
  if not fileExists(final):
    return none(string)
  try:
    return some(readFile(final))
  except OSError, IOError:
    warning &"AI cache read failed for {final}; treating as miss."
    return none(string)

proc transcriptKey(video, whisperModel, language: string): string =
  let videoFp = fileFingerprint(video)
  var modelPart = whisperModel
  if fileExists(whisperModel):
    # When the model argument is an actual ggml file on disk, mix in its
    # fingerprint so swapping model files invalidates the cache.
    modelPart = whisperModel & "#" & fileFingerprint(whisperModel)
  let raw = &"{videoFp}|{modelPart}|{language}|schema={TranscriptSchema}"
  $secureHash(raw)

proc facesKey(video, faceScript: string): string =
  let raw = &"{fileFingerprint(video)}|{scriptFingerprint(faceScript)}|schema={FacesSchema}"
  $secureHash(raw)

proc planKey(transcriptHash, facesHash, aiModel, aiProvider: string,
    chunkSecs: int, chunkStart, chunkStop: float64): string =
  let raw = &"{transcriptHash}|{facesHash}|{aiModel}|{aiProvider}|" &
    &"{chunkSecs}|{chunkStart}|{chunkStop}|schema={PlanSchema}"
  $secureHash(raw)

proc getTranscript*(cache: AiCache, video, whisperModel,
    language: string): Option[string] =
  if not cache.enabled: return none(string)
  readIfExists(cache, transcriptKey(video, whisperModel, language), ".txt")

proc putTranscript*(cache: AiCache, video, whisperModel,
    language, transcript: string) =
  if not cache.enabled: return
  writeAtomic(cache, transcriptKey(video, whisperModel, language),
    ".txt", transcript)

proc getFaces*(cache: AiCache, video, faceScript: string): Option[string] =
  if not cache.enabled: return none(string)
  readIfExists(cache, facesKey(video, faceScript), ".json")

proc putFaces*(cache: AiCache, video, faceScript, facesJson: string) =
  if not cache.enabled: return
  writeAtomic(cache, facesKey(video, faceScript), ".json", facesJson)

proc transcriptHashOf*(video, whisperModel, language: string): string =
  transcriptKey(video, whisperModel, language)

proc facesHashOf*(video, faceScript: string): string =
  facesKey(video, faceScript)

proc getPlan*(cache: AiCache, video, whisperModel, language,
    faceScript, aiModel, aiProvider: string,
    chunkSecs: int, chunkStart, chunkStop: float64): Option[JsonNode] =
  if not cache.enabled: return none(JsonNode)
  let tHash = transcriptKey(video, whisperModel, language)
  let fHash = facesKey(video, faceScript)
  let key = planKey(tHash, fHash, aiModel, aiProvider, chunkSecs,
    chunkStart, chunkStop)
  let raw = readIfExists(cache, key, ".json")
  if raw.isNone: return none(JsonNode)
  try:
    return some(parseJson(raw.get()))
  except JsonParsingError, ValueError:
    warning &"AI cache plan for chunk {chunkStart}-{chunkStop} is corrupted; treating as miss."
    return none(JsonNode)

proc putPlan*(cache: AiCache, video, whisperModel, language,
    faceScript, aiModel, aiProvider: string,
    chunkSecs: int, chunkStart, chunkStop: float64, plan: JsonNode) =
  if not cache.enabled: return
  let tHash = transcriptKey(video, whisperModel, language)
  let fHash = facesKey(video, faceScript)
  let key = planKey(tHash, fHash, aiModel, aiProvider, chunkSecs,
    chunkStart, chunkStop)
  writeAtomic(cache, key, ".json", $plan)
