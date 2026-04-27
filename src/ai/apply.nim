## Converts a parsed edit-plan JSON into `mainArgs.setAction` entries, using
## face tracks to place keyframed zoom centers.
##
## For every `keep` segment with `zoom > 1.0` we emit a SINGLE
## `actZoomAnim` Action carrying a dense list of `ZoomKeyframe`s covering
## the full segment. The renderer interpolates between keyframes per frame
## (Phase B). The keyframe schedule is:
##
## * Ease-in over `ZoomEaseSecs` (shrunk for short segments) with
##   4 keyframes using a smoothstep curve.
## * Flat-zoom middle sampled at `KeyframeHz` against the speaker track's
##   smoothed face center.
## * Ease-out mirroring the ease-in.
##
## Keyframe `time` is measured in seconds from the start of the zoom
## segment (0.0 .. segDur). The total keyframe count is capped at
## `MaxKeyframesPerClip` by sparsifying the middle region.
##
## Segments shorter than `2 * ZoomEaseSecs` fall back to a single-keyframe
## animation at constant zoom (the renderer holds a single keyframe for the
## full clip duration).

import std/[json, math, strformat]

import ./[faces, types, util]
import ../log

const
  KeyframeHz* = 8.0           ## Face samples per second in the flat-zoom middle region.
  ZoomEaseSecs* = 0.20        ## Ease-in / ease-out duration (seconds).
  FaceSmoothSecs* = 0.70      ## Moving-average window for smoothedCenter.
  MaxKeyframesPerClip* = 120  ## Safety cap; re-sample middle sparser if exceeded.

func easeInOut(t: float64): float64 =
  ## Smoothstep curve: flat slope at t=0 and t=1, steepest in the middle.
  let x = max(0.0, min(1.0, t))
  x * x * (3.0 - 2.0 * x)

func lerp(a, b, t: float64): float64 {.inline.} =
  a + (b - a) * t

func resolveCenter(track: FaceTrack, trackFound: bool,
                   faces: seq[FaceSample],
                   start, stop, tAbs: float64): (float32, float32) =
  ## Best (x, y) we can produce at absolute time `tAbs` within [start, stop].
  ## Priority: smoothed track sample → legacy nearestFace → (0.5, 0.5).
  if trackFound:
    let (sx, sy) = smoothedCenter(track, tAbs, FaceSmoothSecs)
    if sx >= 0.0 and sy >= 0.0:
      return (sx, sy)
  let (nx, ny) = nearestFace(faces, start, stop)
  if nx >= 0.0 and ny >= 0.0:
    return (nx, ny)
  (0.5'f32, 0.5'f32)

proc buildZoomKeyframes(track: FaceTrack, trackFound: bool,
                        faces: seq[FaceSample],
                        start, stop: float64, zoom: float64): seq[ZoomKeyframe] =
  ## Build the keyframe list (segment-local time) for a keep+zoom segment.
  let segDur = stop - start

  # Short segment: single constant-zoom keyframe at the midpoint center.
  if segDur <= 2.0 * ZoomEaseSecs:
    let mid = (start + stop) / 2.0
    let (cx, cy) = resolveCenter(track, trackFound, faces, start, stop, mid)
    return @[ZoomKeyframe(time: 0.0'f32, zoom: zoom.float32, x: cx, y: cy)]

  let effEase = min(ZoomEaseSecs, segDur * 0.4)
  let midDur = segDur - 2.0 * effEase
  var midKfCount = max(1, int(round(midDur * KeyframeHz)))

  # Ease keyframe layout: 4 on each side (t = 0, e/3, 2e/3, e) and (segDur-e,
  # segDur-2e/3, segDur-e/3, segDur). The t=e and t=segDur-e keyframes are
  # also the boundary of the flat-zoom middle region. We emit midKfCount
  # middle keyframes STRICTLY between those boundaries, so total count is:
  #   4 (ease-in) + midKfCount (strict interior) + 4 (ease-out)
  # Apply cap:
  let easeCount = 4 + 4
  if easeCount + midKfCount > MaxKeyframesPerClip:
    midKfCount = max(0, MaxKeyframesPerClip - easeCount)

  var kfs: seq[ZoomKeyframe]

  # --- Ease-in ---
  # t_local = 0, e/3, 2e/3, e
  block easeIn:
    let steps = [0.0, 1.0/3.0, 2.0/3.0, 1.0]
    for s in steps:
      let tLocal = effEase * s
      let z = lerp(1.0, zoom, easeInOut(s))
      let (cx, cy) = resolveCenter(track, trackFound, faces, start, stop,
                                   start + tLocal)
      kfs.add ZoomKeyframe(time: tLocal.float32, zoom: z.float32, x: cx, y: cy)

  # --- Middle: strict interior of (effEase, segDur - effEase) ---
  if midKfCount > 0 and midDur > 0.0:
    let step = midDur / (midKfCount + 1).float64
    for i in 1 .. midKfCount:
      let tLocal = effEase + i.float64 * step
      let (cx, cy) = resolveCenter(track, trackFound, faces, start, stop,
                                   start + tLocal)
      kfs.add ZoomKeyframe(time: tLocal.float32, zoom: zoom.float32,
                           x: cx, y: cy)

  # --- Ease-out: mirror of ease-in. t = segDur-e, segDur-2e/3, segDur-e/3, segDur ---
  block easeOut:
    let steps = [1.0, 2.0/3.0, 1.0/3.0, 0.0]
    for s in steps:
      let tLocal = segDur - effEase * s
      # zoom at symmetric phase: at s=1 -> zoom; at s=0 -> 1.0
      let z = lerp(1.0, zoom, easeInOut(s))
      let (cx, cy) = resolveCenter(track, trackFound, faces, start, stop,
                                   start + tLocal)
      kfs.add ZoomKeyframe(time: tLocal.float32, zoom: z.float32, x: cx, y: cy)

  kfs

proc emitKeyframedZoom(args: var mainArgs, tracks: FaceTracks,
                       faces: seq[FaceSample],
                       start, stop: float64, speed, zoom: float64) =
  ## Emit a single (speed?, actZoomAnim) group for [start, stop].
  let hasSpeed = abs(speed - 1.0) > 0.01
  let (track, found) = pickSpeakerTrack(tracks, start, stop)

  let kfs = buildZoomKeyframes(track, found, faces, start, stop, zoom)

  var list: seq[Action]
  if hasSpeed:
    list.add Action(kind: actSpeed, val: speed.float32)
  list.add newZoomAnim(kfs)
  args.setAction.add (newActions(list), packSeconds(start), packSeconds(stop))

proc addPlanActions*(args: var mainArgs, plan: JsonNode,
                    tracks: FaceTracks,
                    faces: seq[FaceSample],
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
    if action == "cut":
      args.setAction.add (aCut, packSeconds(start), packSeconds(stop))
    elif action == "keep":
      let speed = max(0.75, min(1.5, jsonFloat(seg, "speed", 1.0)))
      let zoom = max(1.0, min(1.35, jsonFloat(seg, "zoom", 1.0)))
      let hasSpeed = abs(speed - 1.0) > 0.01
      let hasZoom = zoom > 1.01

      if hasZoom:
        emitKeyframedZoom(args, tracks, faces, start, stop, speed, zoom)
      else:
        # No zoom → preserve the single-group behavior.
        var list: seq[Action]
        if hasSpeed:
          list.add Action(kind: actSpeed, val: speed.float32)
        let group = newActions(list)
        args.setAction.add (group, packSeconds(start), packSeconds(stop))
    else:
      error &"AI edit plan has unknown action: {action}"
