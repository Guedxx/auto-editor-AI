## Face detection helper (shells out to `scripts/ai_face_detect.py`) and
## helpers for picking face-near-window samples.
##
## The Python script emits the schema-2 format (tracks + per-frame bboxes).
## Legacy callers (planner.nim / apply.nim) still consume the flat
## `seq[FaceSample]` view via `toFaceSamples`.

import std/[json, math, osproc, streams, strformat, strutils]

import ./[types, util]
import ../log

proc parseFaceTracks(node: JsonNode): FaceTracks =
  if node.kind != JObject:
    error "OpenCV face helper must return a JSON object"
  if not node.hasKey("schema") or node["schema"].kind != JInt or
      node["schema"].getInt() != 2:
    error "OpenCV face helper returned unsupported schema (expected 2)"

  result.videoFps = jsonFloat(node, "video_fps", 0.0)
  result.sourceWidth = jsonFloat(node, "source_width", 0.0).int32
  result.sourceHeight = jsonFloat(node, "source_height", 0.0).int32

  if not node.hasKey("tracks") or node["tracks"].kind != JArray:
    error "OpenCV face helper missing tracks array"

  for trackNode in node["tracks"]:
    if trackNode.kind != JObject:
      continue
    var track = FaceTrack(
      id: jsonFloat(trackNode, "id", -1.0).int32,
      hits: jsonFloat(trackNode, "hits", 0.0).int32,
    )
    if trackNode.hasKey("frames") and trackNode["frames"].kind == JArray:
      for frameNode in trackNode["frames"]:
        if frameNode.kind != JObject:
          continue
        track.frames.add FaceFrame(
          time: jsonFloat(frameNode, "time", 0.0),
          x: jsonFloat(frameNode, "x", -1.0).float32,
          y: jsonFloat(frameNode, "y", -1.0).float32,
          w: jsonFloat(frameNode, "w", 0.0).float32,
          h: jsonFloat(frameNode, "h", 0.0).float32,
          conf: jsonFloat(frameNode, "conf", 0.0).float32,
          trackId: track.id,
        )
    result.tracks.add track

proc runFaceDetection*(inputPath, scriptPath, pythonPath: string): FaceTracks =
  conwrite("AI: detecting faces...")
  var p: Process
  try:
    p = startProcess(pythonPath, args = @[scriptPath, inputPath],
      options = {poUsePath})
  except OSError:
    error &"Could not start Python for OpenCV face detection: {getCurrentExceptionMsg()}"
  defer: p.close()
  let stdoutStr = p.outputStream.readAll()
  let stderrStr = p.errorStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    var detail = stderrStr.strip()
    if detail == "":
      detail = stdoutStr.strip()
    error &"OpenCV face detection failed (exit {code}):\n{detail}"

  let node = (try: parseJson(stdoutStr) except JsonParsingError as e:
    error &"OpenCV face helper returned invalid JSON: {e.msg}")
  parseFaceTracks(node)

func toFaceSamples*(t: FaceTracks): seq[FaceSample] =
  ## Flatten all tracks into the legacy per-sample view used by the planner
  ## and apply modules until they are upgraded in Phase 2.
  for track in t.tracks:
    for f in track.frames:
      result.add FaceSample(
        time: f.time,
        x: f.x,
        y: f.y,
        size: f.w * f.h,
      )

proc nearestFace*(faces: seq[FaceSample], start, stop: float64): (float32, float32) =
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

proc faceSamplesJson*(faces: seq[FaceSample], start, stop: float64): JsonNode =
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

func smoothedCenter*(track: FaceTrack, t: float64,
    windowSecs = 0.5): (float32, float32) =
  ## Moving-average of the track center within +/- windowSecs around t.
  ## Returns (-1, -1) if no samples fall inside the window.
  if track.frames.len == 0:
    return (-1.0'f32, -1.0'f32)
  let lo = t - windowSecs
  let hi = t + windowSecs
  var sumX = 0.0
  var sumY = 0.0
  var n = 0
  for f in track.frames:
    if f.time >= lo and f.time <= hi:
      sumX += f.x.float64
      sumY += f.y.float64
      inc n
  if n == 0:
    return (-1.0'f32, -1.0'f32)
  ((sumX / n.float64).float32, (sumY / n.float64).float32)

func pickSpeakerTrack*(tracks: FaceTracks,
    start, stop: float64): (FaceTrack, bool) =
  ## Picks the track with the most in-window hits and largest mean bbox
  ## area across [start, stop]. Falls back to `(FaceTrack(), false)` when
  ## no track has any coverage.
  var best: FaceTrack
  var found = false
  var bestScore = -1.0
  for track in tracks.tracks:
    var hits = 0
    var areaSum = 0.0
    for f in track.frames:
      if f.time >= start and f.time <= stop:
        inc hits
        areaSum += f.w.float64 * f.h.float64
    if hits == 0:
      continue
    let meanArea = areaSum / hits.float64
    # Primary: hits. Tie-break: mean area. Encode both into a single score
    # by weighting hits highly so additional coverage dominates bbox size.
    let score = hits.float64 * 1000.0 + meanArea
    if score > bestScore:
      bestScore = score
      best = track
      found = true
  (best, found)
