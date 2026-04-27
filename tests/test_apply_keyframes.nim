import unittest
import std/[json, math]

import ../src/log
import ../src/ai/[apply, faces, types]

# -- Helpers ----------------------------------------------------------------

proc buildFlatTracks(xv, yv: float32, tStart, tStop: float64,
                     n: int): FaceTracks =
  var tr = FaceTrack(id: 0, hits: int32(n))
  let step = (tStop - tStart) / max(1, n - 1).float64
  for i in 0 ..< n:
    let t = tStart + i.float64 * step
    tr.frames.add FaceFrame(time: t, x: xv, y: yv,
      w: 0.2'f32, h: 0.2'f32, conf: 0.95'f32, trackId: 0)
  FaceTracks(videoFps: 30.0, sourceWidth: 1920, sourceHeight: 1080,
    tracks: @[tr])

proc buildPanningTracks(x0, x1, yv: float32, tStart, tStop: float64,
                        n: int): FaceTracks =
  var tr = FaceTrack(id: 0, hits: int32(n))
  let step = (tStop - tStart) / max(1, n - 1).float64
  for i in 0 ..< n:
    let frac = i.float64 / max(1, n - 1).float64
    let t = tStart + i.float64 * step
    let x = (x0.float64 + (x1.float64 - x0.float64) * frac).float32
    tr.frames.add FaceFrame(time: t, x: x, y: yv,
      w: 0.2'f32, h: 0.2'f32, conf: 0.95'f32, trackId: 0)
  FaceTracks(videoFps: 30.0, sourceWidth: 1920, sourceHeight: 1080,
    tracks: @[tr])

proc onlyAnim(a: Actions): Action =
  for act in a:
    if act.kind == actZoomAnim:
      return act
  raise newException(ValueError, "no actZoomAnim in group")

proc countAnim(a: Actions): int =
  result = 0
  for act in a:
    if act.kind == actZoomAnim:
      inc result

proc countSpeed(a: Actions): int =
  result = 0
  for act in a:
    if act.kind == actSpeed:
      inc result

# -- Tests ------------------------------------------------------------------

test "keyframed: panning face produces single actZoomAnim with many keyframes":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 3.0, "action": "keep",
       "speed": 1.0, "zoom": 1.2, "reason": "test"}
    ]
  }
  let tracks = buildPanningTracks(0.4'f32, 0.6'f32, 0.5'f32, 0.0, 5.0, 200)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)

  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  check countAnim(group) == 1
  check countSpeed(group) == 0

  let anim = onlyAnim(group)
  let n = anim.zoomKfCount
  check n > 5

  # Monotonic time, starts at 0.0, ends ≈ 2.0 (segDur).
  check abs(anim.zoomKfAt(0).time - 0.0'f32) < 1e-5'f32
  check abs(anim.zoomKfAt(n - 1).time - 2.0'f32) < 1e-3'f32
  var lastT = -1.0'f32
  for kf in anim.zoomKeyframes:
    check kf.time >= lastT
    lastT = kf.time

  # First / last keyframe zoom ≈ 1.0; some middle keyframe hits 1.2 exactly.
  check abs(anim.zoomKfAt(0).zoom - 1.0'f32) < 1e-4'f32
  check abs(anim.zoomKfAt(n - 1).zoom - 1.0'f32) < 1e-4'f32
  var sawFullZoom = false
  for kf in anim.zoomKeyframes:
    if abs(kf.zoom - 1.2'f32) < 1e-5'f32:
      sawFullZoom = true
      break
  check sawFullZoom

  # x values should broadly increase across the segment (allow smoothing slack).
  let firstX = anim.zoomKfAt(0).x
  let lastX = anim.zoomKfAt(n - 1).x
  check lastX > firstX
  check firstX < 0.50'f32
  check lastX > 0.50'f32

test "keyframed: speed+zoom produces two actions (actSpeed + actZoomAnim)":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 0.5, "end": 2.5, "action": "keep",
       "speed": 1.2, "zoom": 1.15, "reason": "combo"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.5'f32, 0.0, 5.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)

  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  check group.len == 2
  check countSpeed(group) == 1
  check countAnim(group) == 1
  # actSpeed must come first so the renderer sees it before the anim.
  check group[0].kind == actSpeed
  check abs(group[0].val - 1.2'f32) < 1e-5'f32
  let anim = onlyAnim(group)
  check anim.zoomKfCount >= 3

test "keyframed: cut passthrough unchanged":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 2.0, "action": "cut",
       "speed": 1.0, "zoom": 1.0, "reason": "silence"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.5'f32, 0.0, 5.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)
  check args.setAction.len == 1
  check args.setAction[0][0].isCut

test "keyframed: speed-only keep (zoom=1.0) emits no actZoomAnim":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 0.5, "end": 2.0, "action": "keep",
       "speed": 1.3, "zoom": 1.0, "reason": "tight"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.5'f32, 0.0, 5.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)
  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  check countAnim(group) == 0
  check countSpeed(group) == 1
  check group.len == 1
  check abs(group[0].val - 1.3'f32) < 1e-5'f32

test "keyframed: short segment (segDur=0.1) -> single-keyframe actZoomAnim":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 1.1, "action": "keep",
       "speed": 1.0, "zoom": 1.2, "reason": "emphasis"}
    ]
  }
  let tracks = buildFlatTracks(0.4'f32, 0.6'f32, 0.0, 5.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)

  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  let anim = onlyAnim(group)
  check anim.zoomKfCount == 1
  let kf = anim.zoomKfAt(0)
  check abs(kf.time - 0.0'f32) < 1e-5'f32
  check abs(kf.zoom - 1.2'f32) < 1e-5'f32
  check abs(kf.x - 0.4'f32) < 0.01'f32
  check abs(kf.y - 0.6'f32) < 0.01'f32

test "keyframed: no speaker track -> fallback to (0.5, 0.5)":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 3.0, "action": "keep",
       "speed": 1.0, "zoom": 1.2, "reason": "no faces"}
    ]
  }
  # Empty tracks, no face samples.
  let tracks = FaceTracks(videoFps: 30.0, sourceWidth: 1920,
    sourceHeight: 1080, tracks: @[])
  let faces: seq[FaceSample] = @[]
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)

  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  let anim = onlyAnim(group)
  check anim.zoomKfCount > 0
  for kf in anim.zoomKeyframes:
    check abs(kf.x - 0.5'f32) < 1e-5'f32
    check abs(kf.y - 0.5'f32) < 1e-5'f32

test "keyframed: 60s segment respects MaxKeyframesPerClip cap":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 0.0, "end": 60.0, "action": "keep",
       "speed": 1.0, "zoom": 1.2, "reason": "long"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.5'f32, 0.0, 60.0, 600)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 60.0, duration = 60.0)

  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  let anim = onlyAnim(group)
  let n = anim.zoomKfCount
  check n <= MaxKeyframesPerClip
  # Ensure the segment is covered edge to edge.
  check abs(anim.zoomKfAt(0).time - 0.0'f32) < 1e-5'f32
  check abs(anim.zoomKfAt(n - 1).time - 60.0'f32) < 1e-2'f32
