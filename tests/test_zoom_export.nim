import unittest
import std/[math, strutils]

import ../src/log
import ../src/exports/zoom_export

# --- helpers ----------------------------------------------------------------

proc mkKf(t, z, x, y: float32): ZoomKeyframe =
  ZoomKeyframe(time: t, zoom: z, x: x, y: y)

proc countSub(s, needle: string): int =
  var i = 0
  result = 0
  while true:
    let p = s.find(needle, i)
    if p < 0: break
    inc result
    i = p + needle.len

# --- tests ------------------------------------------------------------------

test "sampleZoomAt: clamps on both sides and linearly interpolates mid":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.3'f32, 0.5'f32, 0.5'f32),
  ])
  let before = sampleZoomAt(a, -0.5)
  check abs(before.zoom - 1.0) < 1e-5
  check abs(before.x - 0.5) < 1e-5
  check abs(before.y - 0.5) < 1e-5

  let after = sampleZoomAt(a, 2.0)
  check abs(after.zoom - 1.3) < 1e-5

  let mid = sampleZoomAt(a, 0.5)
  check abs(mid.zoom - 1.15) < 1e-5

test "sampleZoomAt: zero keyframes -> neutral (1.0, 0.5, 0.5)":
  let a = newZoomAnim(@[])
  let r = sampleZoomAt(a, 0.0)
  check r.zoom == 1.0
  check r.x == 0.5
  check r.y == 0.5

test "sampleZoomAt: single keyframe is constant":
  let a = newZoomAnim(@[mkKf(0.3'f32, 1.2'f32, 0.4'f32, 0.6'f32)])
  for t in [-1.0, 0.0, 0.3, 5.0]:
    let r = sampleZoomAt(a, t)
    check abs(r.zoom - 1.2) < 1e-5
    check abs(r.x - 0.4) < 1e-5
    check abs(r.y - 0.6) < 1e-5

test "scaleAndTranslate: zoom=1.2, cx=0.45, cy=0.5 at 1920x1080":
  let st = scaleAndTranslate(1.2, 0.45, 0.5, 1920'i32, 1080'i32)
  check abs(st.scale - 1.2) < 1e-9
  check abs(st.tx - 115.2) < 1e-6
  check abs(st.ty - 0.0) < 1e-9

test "mltRectPercent: golden string for zoom=1.2, cx=0.45, cy=0.5":
  check mltRectPercent(1.2, 0.45, 0.5) ==
    "6.000%/0.000%:120.000%x120.000%:100"

test "mltRectAnimation: three keyframes at 60 fps on a 1s clip":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.2'f32, 0.45'f32, 0.5'f32),
    mkKf(0.5'f32, 1.2'f32, 0.5'f32,  0.5'f32),
    mkKf(1.0'f32, 1.2'f32, 0.55'f32, 0.5'f32),
  ])
  let s = mltRectAnimation(a, clipDurSecs = 1.0, fps = 60.0)
  check s.len > 0
  let segs = s.split("; ")
  check segs.len == 3
  check segs[0].startsWith("0=")
  check segs[1].startsWith("30=")
  check segs[2].startsWith("60=")

test "mltRectAnimation: empty when every keyframe zoom <= ZoomEpsilon":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
  ])
  check mltRectAnimation(a, 1.0, 30.0) == ""

test "mltRectAnimation: empty for zero keyframes":
  let a = newZoomAnim(@[])
  check mltRectAnimation(a, 1.0, 30.0) == ""

test "fcpxmlScaleParamXml: contains keyframeAnimation and three keyframes":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.2'f32, 0.5'f32, 0.5'f32),
    mkKf(0.5'f32, 1.25'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.3'f32, 0.5'f32, 0.5'f32),
  ])
  let xml = fcpxmlScaleParamXml(a, 1.0, 30.0)
  check xml.contains("<keyframeAnimation>")
  check xml.contains("</keyframeAnimation>")
  check countSub(xml, "<keyframe ") == 3
  check xml.contains("time=\"0.000s\"")
  check xml.contains("time=\"0.500s\"")
  check xml.contains("time=\"1.000s\"")

test "fcpxmlScaleParamXml: clipInSecs offset shifts the keyframe times":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.2'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.2'f32, 0.5'f32, 0.5'f32),
  ])
  let xml = fcpxmlScaleParamXml(a, 1.0, 30.0, clipInSecs = 2.0)
  check xml.contains("time=\"2.000s\"")
  check xml.contains("time=\"3.000s\"")

test "fcpxmlScaleParamXml: empty when no animated zoom":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
  ])
  check fcpxmlScaleParamXml(a, 1.0, 30.0) == ""

test "fcpxmlPositionParamXml: embeds scale-and-translate pixel offsets":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.2'f32, 0.45'f32, 0.5'f32),
    mkKf(1.0'f32, 1.2'f32, 0.45'f32, 0.5'f32),
  ])
  let xml = fcpxmlPositionParamXml(a, 1.0, 30.0, 1920'i32, 1080'i32)
  check xml.contains("<param name=\"position\">")
  check xml.contains("115.200 0.000")

test "fcp7BasicMotionXml: integer <when> frames at 30 fps":
  let a = newZoomAnim(@[
    mkKf(0.0'f32, 1.2'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.2'f32, 0.5'f32, 0.5'f32),
  ])
  let xml = fcp7BasicMotionXml(a, 1.0, 30.0, 1920'i32, 1080'i32)
  check xml.contains("<effectid>basic</effectid>")
  check xml.contains("<parameterid>scale</parameterid>")
  check xml.contains("<parameterid>center</parameterid>")
  check xml.contains("<when>0</when>")
  check xml.contains("<when>30</when>")
  # Two <keyframe> nodes per <parameter> -> four total.
  check countSub(xml, "<keyframe>") == 4

test "fcp7BasicMotionXml: empty when no animated zoom":
  let a = newZoomAnim(@[mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32)])
  check fcp7BasicMotionXml(a, 1.0, 30.0, 1920'i32, 1080'i32) == ""

test "hasAnimatedZoom: empty, neutral, and real zoom cases":
  let zero = newZoomAnim(@[])
  check not hasAnimatedZoom(zero)

  let neutral = newZoomAnim(@[mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32)])
  check not hasAnimatedZoom(neutral)

  let zoomed = newZoomAnim(@[mkKf(0.0'f32, 1.2'f32, 0.5'f32, 0.5'f32)])
  check hasAnimatedZoom(zoomed)

  # Mixed — one KF at neutral, one zoomed, should register as animated.
  let mixed = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.15'f32, 0.5'f32, 0.5'f32),
  ])
  check hasAnimatedZoom(mixed)
