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

  # Filter emission matches Kdenlive's native "Position and Zoom" shape:
  # pixel-space rects, timecode keyframes, and the specific support
  # properties Kdenlive/MLT require to actually apply the affine filter.
  check xmlStr.contains("<filter")
  check xmlStr.contains("transition.rect")
  check xmlStr.contains("mlt_service")
  check xmlStr.contains(">affine<")
  check xmlStr.contains("pan_zoom")
  check xmlStr.contains("use_normalised")
  check xmlStr.contains("colour:0")
  check xmlStr.contains("0x00000000")
  check xmlStr.contains("transition.repeat_off")
  check xmlStr.contains("transition.mirror_off")

  # Keyframes are anchored by timecode; rect values are 4 space-separated
  # integers in profile pixel space. Clip is 2 s at 30 fps = last
  # keyframe at 00:00:02.000.
  let rectIdx = xmlStr.find("transition.rect")
  check rectIdx >= 0
  let openIdx = xmlStr.find('>', rectIdx)
  let closeIdx = xmlStr.find('<', openIdx)
  let animVal = xmlStr[openIdx + 1 ..< closeIdx].strip()
  check animVal.startsWith("00:00:00.000=")
  let segs = animVal.split(";")
  check segs.len == 3
  check segs[^1].startsWith("00:00:02.000=")

  # Each rect must be "X Y W H" — four integers, space-separated.
  # Pull the rect payload from the first keyframe and count tokens.
  let firstEq = segs[0].find('=')
  let firstRect = segs[0][firstEq + 1 .. ^1]
  let firstTokens = firstRect.splitWhitespace()
  check firstTokens.len == 4
  for tok in firstTokens:
    # Each token is a signed integer.
    discard parseInt(tok)

  # The middle keyframe is zoom=1.2 at normalized (0.4, 0.4) in a
  # 1920 x 1080 profile. Expected pixel rect:
  #   W = round(1920 * 1.2)                = 2304
  #   H = round(1080 * 1.2)                = 1296
  #   X = round(1920 * (0.5 - 0.4 * 1.2))  = round(1920 * 0.02) = 38
  #   Y = round(1080 * (0.5 - 0.4 * 1.2))  = round(1080 * 0.02) = 22
  let midEq = segs[1].find('=')
  let midRect = segs[1][midEq + 1 .. ^1].strip()
  check midRect == "38 22 2304 1296"

  # Output must be well-formed XML.
  discard parseXml(xmlStr)

test "shotcutWriteMlt emits keyframed transition.rect filter on zoomed clip":
  let tl = makeZoomTimeline()
  let tempDir = createTempDir("ae-mlt-sc", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.mlt"
  shotcutWriteMlt(outFile, tl)

  let xmlStr = readFile(outFile)

  # Shotcut is still on the percentage-based path for now (separate fix).
  # This test asserts the current behavior so a future Shotcut refactor
  # consciously updates the expectations.
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
