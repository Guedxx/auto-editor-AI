import unittest
import std/[os, strutils, tempfiles, xmlparser]

import ../src/[ffmpeg, log, timeline]
import ../src/util/color
import ../src/exports/[kdenlive, shotcut]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkKf(t, z, x, y: float32): ZoomKeyframe =
  ZoomKeyframe(time: t, zoom: z, x: x, y: y)

proc makeZoomTimeline(): v3 =
  ## Build a minimal v3 with a single 60-frame @ 30 fps clip whose effect
  ## group holds one actZoomAnim with three keyframes:
  ##   (0.0, 1.0, 0.5, 0.5), (1.0, 1.2, 0.4, 0.4), (2.0, 1.0, 0.5, 0.5)
  let srcPtr = cast[ptr string](alloc0(sizeof(string)))
  srcPtr[] = "example.mp4"

  let anim = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.2'f32, 0.4'f32, 0.4'f32),
    mkKf(2.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
  ])
  let effects = @[newActions(@[anim])]
  let clip = Clip(src: srcPtr, start: 0, dur: 60, offset: 0,
                  effects: 0'u32, stream: 0)

  result = v3(
    layout: initLayout("stereo"),
    res: (1920'i32, 1080'i32),
    tb: AVRational(num: 30, den: 1),
    bg: RGBColor(red: 0, green: 0, blue: 0),
    sr: 48000.cint,
    v: @[@[clip]],
    a: @[],
    s: @[],
    langs: @[],
    effects: effects,
    clips2: @[],
  )

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test "kdenliveWrite emits keyframed transition.rect filter on zoomed clip":
  let tl = makeZoomTimeline()
  let tempDir = createTempDir("ae-mlt-kd", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.mlt"
  kdenliveWrite(outFile, tl)

  let xmlStr = readFile(outFile)

  # The filter lives inside an <entry> inside the clip playlist.
  check xmlStr.contains("<filter")
  check xmlStr.contains("transition.rect")
  check xmlStr.contains("mlt_service")
  check xmlStr.contains(">affine<")
  check xmlStr.contains("pan_zoom")

  # Animation should start at frame 0 and end at frame 60 (2 s * 30 fps).
  let rectIdx = xmlStr.find("transition.rect")
  check rectIdx >= 0
  let openIdx = xmlStr.find('>', rectIdx)
  let closeIdx = xmlStr.find('<', openIdx)
  let animVal = xmlStr[openIdx + 1 ..< closeIdx].strip()
  check animVal.startsWith("0=")
  # last segment should have frame 60 = round(2.0 * 30)
  let segs = animVal.split("; ")
  check segs.len == 3
  check segs[^1].startsWith("60=")

  # Output must be well-formed XML.
  discard parseXml(xmlStr)

test "shotcutWriteMlt emits keyframed transition.rect filter on zoomed clip":
  let tl = makeZoomTimeline()
  let tempDir = createTempDir("ae-mlt-sc", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.mlt"
  shotcutWriteMlt(outFile, tl)

  let xmlStr = readFile(outFile)

  check xmlStr.contains("<filter")
  check xmlStr.contains("transition.rect")
  check xmlStr.contains(">affine<")

  let rectIdx = xmlStr.find("transition.rect")
  check rectIdx >= 0
  let openIdx = xmlStr.find('>', rectIdx)
  let closeIdx = xmlStr.find('<', openIdx)
  let animVal = xmlStr[openIdx + 1 ..< closeIdx].strip()
  check animVal.startsWith("0=")
  let segs = animVal.split("; ")
  check segs.len == 3
  check segs[^1].startsWith("60=")

  # Output must be well-formed XML.
  discard parseXml(xmlStr)

test "kdenliveWrite: no zoom filter when clip has no actZoomAnim":
  let srcPtr = cast[ptr string](alloc0(sizeof(string)))
  srcPtr[] = "example.mp4"
  let clip = Clip(src: srcPtr, start: 0, dur: 60, offset: 0,
                  effects: 0'u32, stream: 0)
  let tl = v3(
    layout: initLayout("stereo"),
    res: (1920'i32, 1080'i32),
    tb: AVRational(num: 30, den: 1),
    bg: RGBColor(red: 0, green: 0, blue: 0),
    sr: 48000.cint,
    v: @[@[clip]],
    a: @[],
    s: @[],
    langs: @[],
    effects: @[aNil],
    clips2: @[],
  )
  let tempDir = createTempDir("ae-mlt-kd2", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.mlt"
  kdenliveWrite(outFile, tl)
  let xmlStr = readFile(outFile)
  check not xmlStr.contains("transition.rect")
  discard parseXml(xmlStr)

test "kdenliveWrite: neutral-zoom animation produces no filter":
  # Every keyframe zoom <= ZoomEpsilon -> mltRectAnimation returns empty.
  let srcPtr = cast[ptr string](alloc0(sizeof(string)))
  srcPtr[] = "example.mp4"
  let anim = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
  ])
  let clip = Clip(src: srcPtr, start: 0, dur: 60, offset: 0,
                  effects: 0'u32, stream: 0)
  let tl = v3(
    layout: initLayout("stereo"),
    res: (1920'i32, 1080'i32),
    tb: AVRational(num: 30, den: 1),
    bg: RGBColor(red: 0, green: 0, blue: 0),
    sr: 48000.cint,
    v: @[@[clip]],
    a: @[],
    s: @[],
    langs: @[],
    effects: @[newActions(@[anim])],
    clips2: @[],
  )
  let tempDir = createTempDir("ae-mlt-kd3", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.mlt"
  kdenliveWrite(outFile, tl)
  let xmlStr = readFile(outFile)
  check not xmlStr.contains("transition.rect")
