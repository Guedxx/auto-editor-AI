## Converts a parsed edit-plan JSON into `mainArgs.setAction` entries, using
## face tracks to place animated zoom centers.
##
## For every `keep` segment with `zoom > 1.0` we slice the range into short
## sub-windows (see `SubSegmentSecs`) and sample the speaker track's
## smoothed center at each window midpoint. The zoom factor eases in/out
## over `ZoomEaseSecs` at both edges using a smoothstep curve, so the crop
## glides rather than snapping. Flat-middle sub-windows with identical
## `(zoom, x, y)` triples collapse via the existing `chunkify` dedup, so the
## extra resolution does not balloon the clip count.

import std/[json, math, strformat]

import ./[faces, types, util]
import ../log

const
  SubSegmentSecs* = 0.15    ## Width of each animated sub-window (seconds).
  ZoomEaseSecs* = 0.10      ## Ease-in / ease-out duration on each side.
  FaceSmoothSecs* = 0.50    ## Moving-average window for `smoothedCenter`.

func easeInOut(t: float64): float64 =
  ## Smoothstep curve: flat slope at t=0 and t=1, steepest in the middle.
  let x = max(0.0, min(1.0, t))
  x * x * (3.0 - 2.0 * x)

func lerp(a, b, t: float64): float64 {.inline.} =
  a + (b - a) * t

func resolveCenter(track: FaceTrack, trackFound: bool,
                   faces: seq[FaceSample],
                   start, stop, mid: float64): (float32, float32) =
  ## Best (x, y) we can produce for a midpoint in [start, stop].
  ## Priority: smoothed track sample → legacy nearestFace → (0.5, 0.5).
  if trackFound:
    let (sx, sy) = smoothedCenter(track, mid, FaceSmoothSecs)
    if sx >= 0.0 and sy >= 0.0:
      return (sx, sy)
  let (nx, ny) = nearestFace(faces, start, stop)
  if nx >= 0.0 and ny >= 0.0:
    return (nx, ny)
  (0.5'f32, 0.5'f32)

proc emitAnimatedZoom(args: var mainArgs, tracks: FaceTracks,
                     faces: seq[FaceSample],
                     start, stop: float64, speed, zoom: float64) =
  ## Slice [start, stop] into sub-windows and emit per-window (speed?, zoom)
  ## action groups with an ease-in/ease-out on the zoom factor.
  let duration = stop - start
  let hasSpeed = abs(speed - 1.0) > 0.01

  # Degenerate span (shorter than 2× ease): single zoom step at midpoint,
  # no easing. Avoids chopping a ~250ms emphasis into even finer pieces.
  if duration <= 2.0 * ZoomEaseSecs:
    let mid = (start + stop) / 2.0
    let (track, found) = pickSpeakerTrack(tracks, start, stop)
    let (x, y) = resolveCenter(track, found, faces, start, stop, mid)
    var list: seq[Action]
    if hasSpeed:
      list.add Action(kind: actSpeed, val: speed.float32)
    list.add Action(kind: actZoom, val: zoom.float32, x: x, y: y)
    args.setAction.add (newActions(list), packSeconds(start), packSeconds(stop))
    return

  let (track, found) = pickSpeakerTrack(tracks, start, stop)
  let nWindows = max(1, int(ceil(duration / SubSegmentSecs)))
  let step = duration / nWindows.float64

  for i in 0 ..< nWindows:
    let s = start + i.float64 * step
    # Clamp the last window exactly to `stop` to avoid FP drift at the edge.
    let e = if i == nWindows - 1: stop else: start + (i + 1).float64 * step
    if e <= s:
      continue
    let mid = (s + e) / 2.0

    let (x, y) = resolveCenter(track, found, faces, start, stop, mid)

    # Ease-in / ease-out on the zoom factor. Windows outside both ease
    # regions stay at the full zoom, so their (zoom, x, y) triples only
    # vary when the face actually moves.
    var zoomI = zoom
    let dFromStart = mid - start
    let dFromStop = stop - mid
    if dFromStart < ZoomEaseSecs:
      let t = max(0.0, dFromStart / ZoomEaseSecs)
      zoomI = lerp(1.0, zoom, easeInOut(t))
    elif dFromStop < ZoomEaseSecs:
      let t = max(0.0, dFromStop / ZoomEaseSecs)
      zoomI = lerp(1.0, zoom, easeInOut(t))

    var list: seq[Action]
    if hasSpeed:
      list.add Action(kind: actSpeed, val: speed.float32)
    list.add Action(kind: actZoom, val: zoomI.float32, x: x, y: y)
    args.setAction.add (newActions(list), packSeconds(s), packSeconds(e))

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
        # Animated path: slice + ease. Speed (if any) rides along on every
        # sub-window so the speed change spans the full original range.
        emitAnimatedZoom(args, tracks, faces, start, stop, speed, zoom)
      else:
        # No zoom → preserve the single-group behavior.
        var list: seq[Action]
        if hasSpeed:
          list.add Action(kind: actSpeed, val: speed.float32)
        let group = newActions(list)
        args.setAction.add (group, packSeconds(start), packSeconds(stop))
    else:
      error &"AI edit plan has unknown action: {action}"
