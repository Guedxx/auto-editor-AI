## Shared helper module for emitting native keyframed zoom effects into NLE
## project files from our internal ``actZoomAnim`` representation.
##
## The internal representation uses zoom ∈ [1.0, ~1.35] and a normalized
## ``(x, y)`` crop-center in [0, 1] × [0, 1] on the SOURCE image.
##
## Two output conventions are supported:
##   * "scale + translation" (FCPXML / FCP7 basic-motion) — ``scaleAndTranslate``.
##   * MLT ``rect`` percentage strings (Kdenlive / Shotcut) — ``mltRectPercent``.
##
## Higher-level builders emit ready-to-embed XML fragments.

import std/[math, strformat, strutils]

import ../log  # ActionKind, ZoomKeyframe, Action, zoomKfCount, zoomKfAt

const ZoomEpsilon* = 1.001'f32
  ## Zoom factors at or below this are treated as "no zoom".

# ---------------------------------------------------------------------------
# Predicates and sampling
# ---------------------------------------------------------------------------

func hasAnimatedZoom*(a: Action): bool =
  ## True iff ``a`` is an actZoomAnim with >=1 keyframe whose zoom > ZoomEpsilon.
  if a.kind != actZoomAnim: return false
  let n = zoomKfCount(a)
  if n == 0: return false
  for i in 0 ..< n:
    if zoomKfAt(a, i).zoom > ZoomEpsilon:
      return true
  false

func sampleZoomAt*(a: Action, tSecs: float64):
    tuple[zoom: float64, x: float64, y: float64] =
  ## Linear-interp zoom/x/y at tSecs with clamping at both boundaries.
  ## Returns (1.0, 0.5, 0.5) when ``a`` has no keyframes. Mirrors the
  ## algorithm used by the renderer in ``src/render/video.nim``.
  let n = zoomKfCount(a)
  if n == 0: return (1.0, 0.5, 0.5)
  if n == 1:
    let k = zoomKfAt(a, 0)
    return (k.zoom.float64, k.x.float64, k.y.float64)
  let first = zoomKfAt(a, 0)
  if tSecs <= first.time.float64:
    return (first.zoom.float64, first.x.float64, first.y.float64)
  let last = zoomKfAt(a, n - 1)
  if tSecs >= last.time.float64:
    return (last.zoom.float64, last.x.float64, last.y.float64)
  var lo = 0
  var hi = n - 1
  while lo + 1 < hi:
    let mid = (lo + hi) div 2
    if zoomKfAt(a, mid).time.float64 <= tSecs: lo = mid
    else: hi = mid
  let ka = zoomKfAt(a, lo)
  let kb = zoomKfAt(a, lo + 1)
  let span = max(kb.time.float64 - ka.time.float64, 1e-9)
  let u = max(0.0, min(1.0, (tSecs - ka.time.float64) / span))
  (ka.zoom.float64 + (kb.zoom.float64 - ka.zoom.float64) * u,
   ka.x.float64    + (kb.x.float64    - ka.x.float64)    * u,
   ka.y.float64    + (kb.y.float64    - ka.y.float64)    * u)

# ---------------------------------------------------------------------------
# Convention 1: scale + translation (FCPXML / FCP7 basic-motion)
# ---------------------------------------------------------------------------

func scaleAndTranslate*(zoom, cx, cy: float64; frameW, frameH: int32):
    tuple[scale: float64, tx: float64, ty: float64] =
  ## Returns (scale, tx, ty) in pixels for FCPXML/FCP7 basic-motion.
  ## ``tx`` > 0 shifts the image to the right, ``ty`` > 0 shifts it down.
  (zoom,
   (0.5 - cx) * zoom * frameW.float64,
   (0.5 - cy) * zoom * frameH.float64)

# ---------------------------------------------------------------------------
# Convention 2: MLT ``rect`` percentage strings
# ---------------------------------------------------------------------------

func fmt3(v: float64): string {.inline.} =
  formatFloat(v, ffDecimal, 3)

func mltRectPercent*(zoom, cx, cy: float64): string =
  ## Returns a single MLT rect string like
  ## ``"6.000%/0.000%:120.000%x120.000%:100"``.
  let x = (0.5 - cx) * zoom * 100.0
  let y = (0.5 - cy) * zoom * 100.0
  let w = zoom * 100.0
  let h = zoom * 100.0
  &"{fmt3(x)}%/{fmt3(y)}%:{fmt3(w)}%x{fmt3(h)}%:100"

proc mltRectAnimation*(a: Action; clipDurSecs: float64; fps: float64): string =
  ## Builds the MLT animation string: ``"frame1=rect1; frame2=rect2; ..."``.
  ## Frame numbers are integers (round(kf.time * fps)) clamped to
  ## [0, round(clipDurSecs*fps)]. Uses linear interpolation (``=``) between
  ## keyframes. Returns ``""`` when the Action has zero keyframes or when
  ## every keyframe's zoom is <= ZoomEpsilon.
  let n = zoomKfCount(a)
  if n == 0: return ""
  var anyZoomed = false
  for i in 0 ..< n:
    if zoomKfAt(a, i).zoom > ZoomEpsilon:
      anyZoomed = true
      break
  if not anyZoomed: return ""

  let lastFrame = int(round(clipDurSecs * fps))
  var parts = newSeqOfCap[string](n)
  var prevFrame = low(int)
  for i in 0 ..< n:
    let kf = zoomKfAt(a, i)
    var frame = int(round(kf.time.float64 * fps))
    if frame < 0: frame = 0
    if frame > lastFrame: frame = lastFrame
    # Ensure strictly increasing frame numbers — MLT requires monotonic keys.
    if frame <= prevFrame: frame = prevFrame + 1
    if frame > lastFrame: frame = lastFrame
    prevFrame = frame
    let rect = mltRectPercent(kf.zoom.float64, kf.x.float64, kf.y.float64)
    parts.add(&"{frame}={rect}")
  parts.join("; ")

# ---------------------------------------------------------------------------
# FCPXML helpers
# ---------------------------------------------------------------------------

proc fcpxmlScaleParamXml*(a: Action; clipDurSecs: float64; fps: float64;
    clipInSecs: float64 = 0.0): string =
  ## Returns the inner XML for an FCPXML adjust-transform scale <param>.
  ## Empty string if the Action has no keyframes or all zooms <= ZoomEpsilon.
  let n = zoomKfCount(a)
  if n == 0: return ""
  var anyZoomed = false
  for i in 0 ..< n:
    if zoomKfAt(a, i).zoom > ZoomEpsilon:
      anyZoomed = true
      break
  if not anyZoomed: return ""

  var lines = newSeqOfCap[string](n + 4)
  lines.add("<param name=\"scale\">")
  lines.add("  <keyframeAnimation>")
  for i in 0 ..< n:
    let kf = zoomKfAt(a, i)
    let tAbs = clipInSecs + kf.time.float64
    let s = kf.zoom.float64
    lines.add(&"    <keyframe time=\"{fmt3(tAbs)}s\" value=\"{fmt3(s)} {fmt3(s)}\"/>")
  lines.add("  </keyframeAnimation>")
  lines.add("</param>")
  lines.join("\n")

proc fcpxmlPositionParamXml*(a: Action; clipDurSecs: float64; fps: float64;
    frameW, frameH: int32; clipInSecs: float64 = 0.0): string =
  ## Returns the inner XML for an FCPXML adjust-transform position <param>.
  ## Values are ``"{tx} {ty}"`` in pixels with FCPXML convention
  ## (+x right, +y down). Empty string if not animated.
  let n = zoomKfCount(a)
  if n == 0: return ""
  var anyZoomed = false
  for i in 0 ..< n:
    if zoomKfAt(a, i).zoom > ZoomEpsilon:
      anyZoomed = true
      break
  if not anyZoomed: return ""

  var lines = newSeqOfCap[string](n + 4)
  lines.add("<param name=\"position\">")
  lines.add("  <keyframeAnimation>")
  for i in 0 ..< n:
    let kf = zoomKfAt(a, i)
    let tAbs = clipInSecs + kf.time.float64
    let st = scaleAndTranslate(kf.zoom.float64, kf.x.float64, kf.y.float64,
                               frameW, frameH)
    lines.add(&"    <keyframe time=\"{fmt3(tAbs)}s\" value=\"{fmt3(st.tx)} {fmt3(st.ty)}\"/>")
  lines.add("  </keyframeAnimation>")
  lines.add("</param>")
  lines.join("\n")

# ---------------------------------------------------------------------------
# FCP7 XMEML basic-motion helper
# ---------------------------------------------------------------------------

proc fcp7BasicMotionXml*(a: Action; clipDurSecs: float64; fps: float64;
    frameW, frameH: int32): string =
  ## Returns the full FCP7 <filter> block for basic-motion with keyframed
  ## scale and center parameters. Uses integer <when> frame offsets.
  ## Empty string if the Action has no keyframes or all zooms <= ZoomEpsilon.
  let n = zoomKfCount(a)
  if n == 0: return ""
  var anyZoomed = false
  for i in 0 ..< n:
    if zoomKfAt(a, i).zoom > ZoomEpsilon:
      anyZoomed = true
      break
  if not anyZoomed: return ""

  var scaleKfs = newSeqOfCap[string](n)
  var centerKfs = newSeqOfCap[string](n)
  let lastFrame = int(round(clipDurSecs * fps))
  var prevFrame = low(int)
  for i in 0 ..< n:
    let kf = zoomKfAt(a, i)
    var w = int(round(kf.time.float64 * fps))
    if w < 0: w = 0
    if w > lastFrame: w = lastFrame
    if w <= prevFrame: w = prevFrame + 1
    if w > lastFrame: w = lastFrame
    prevFrame = w
    let sPct = kf.zoom.float64 * 100.0
    let normX = (kf.x.float64 - 0.5) * 2.0
    let normY = (kf.y.float64 - 0.5) * 2.0
    scaleKfs.add(
      &"        <keyframe><when>{w}</when><value>{fmt3(sPct)}</value></keyframe>")
    centerKfs.add(
      "        <keyframe><when>" & $w & "</when>" &
      &"<value><horiz>{fmt3(normX)}</horiz><vert>{fmt3(normY)}</vert></value>" &
      "</keyframe>")

  var lines: seq[string]
  lines.add("<filter>")
  lines.add("  <effect>")
  lines.add("    <name>Basic Motion</name>")
  lines.add("    <effectid>basic</effectid>")
  lines.add("    <effectcategory>motion</effectcategory>")
  lines.add("    <effecttype>motion</effecttype>")
  lines.add("    <mediatype>video</mediatype>")
  lines.add("    <parameter>")
  lines.add("      <parameterid>scale</parameterid>")
  lines.add("      <name>Scale</name>")
  lines.add("      <valuemin>0</valuemin>")
  lines.add("      <valuemax>1000</valuemax>")
  lines.add("      <value>100</value>")
  for s in scaleKfs: lines.add(s)
  lines.add("    </parameter>")
  lines.add("    <parameter>")
  lines.add("      <parameterid>center</parameterid>")
  lines.add("      <name>Center</name>")
  lines.add("      <value><horiz>0</horiz><vert>0</vert></value>")
  for c in centerKfs: lines.add(c)
  lines.add("    </parameter>")
  lines.add("  </effect>")
  lines.add("</filter>")
  lines.join("\n")
