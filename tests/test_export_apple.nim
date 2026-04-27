import unittest
import std/[os, strutils, tempfiles, xmlparser]

import ../src/[ffmpeg, log, timeline]
import ../src/util/color
import ../src/exports/[fcp7, fcp11]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const testSrcPath = "resources/testsrc.mp4"

proc mkKf(t, z, x, y: float32): ZoomKeyframe =
  ZoomKeyframe(time: t, zoom: z, x: x, y: y)

proc makeZoomTimeline(): v3 =
  ## Build a minimal v3 with a single 120-frame @ 60 fps clip whose effect
  ## group holds one actZoomAnim with three keyframes:
  ##   (0.0, 1.0, 0.5, 0.5), (1.0, 1.2, 0.4, 0.4), (2.0, 1.0, 0.5, 0.5)
  let srcPtr = cast[ptr string](alloc0(sizeof(string)))
  srcPtr[] = testSrcPath

  let anim = newZoomAnim(@[
    mkKf(0.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
    mkKf(1.0'f32, 1.2'f32, 0.4'f32, 0.4'f32),
    mkKf(2.0'f32, 1.0'f32, 0.5'f32, 0.5'f32),
  ])
  let effects = @[newActions(@[anim])]
  let clip = Clip(src: srcPtr, start: 0, dur: 120, offset: 0,
                  effects: 0'u32, stream: 0)

  result = v3(
    layout: initLayout("stereo"),
    res: (1920'i32, 1080'i32),
    tb: AVRational(num: 60, den: 1),
    bg: RGBColor(red: 0, green: 0, blue: 0),
    sr: 48000.cint,
    v: @[@[clip]],
    a: @[],
    s: @[],
    langs: @[],
    effects: effects,
    clips2: @[],
  )

proc makePlainTimeline(): v3 =
  ## Same clip geometry but effects = @[aNil] (no zoom).
  let srcPtr = cast[ptr string](alloc0(sizeof(string)))
  srcPtr[] = testSrcPath

  let clip = Clip(src: srcPtr, start: 0, dur: 120, offset: 0,
                  effects: 0'u32, stream: 0)
  result = v3(
    layout: initLayout("stereo"),
    res: (1920'i32, 1080'i32),
    tb: AVRational(num: 60, den: 1),
    bg: RGBColor(red: 0, green: 0, blue: 0),
    sr: 48000.cint,
    v: @[@[clip]],
    a: @[],
    s: @[],
    langs: @[],
    effects: @[aNil],
    clips2: @[],
  )

# ---------------------------------------------------------------------------
# FCP7 tests
# ---------------------------------------------------------------------------

test "fcp7WriteXml emits basic-motion filter with keyframed scale+center":
  let tl = makeZoomTimeline()
  let tempDir = createTempDir("ae-fcp7-zoom", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.xml"
  fcp7WriteXml("test", outFile, resolve = false, tl)

  let xmlStr = readFile(outFile)

  # Must contain the basic-motion effect.
  check xmlStr.contains("<effectid>basic</effectid>")

  # Scale parameter with keyframes.
  let scaleId = "<parameterid>scale</parameterid>"
  check xmlStr.contains(scaleId)
  # Locate the scale <parameter> block.
  let scaleIdx = xmlStr.find(scaleId)
  check scaleIdx >= 0
  # Find enclosing <parameter>...</parameter> after this id.
  let paramEnd = xmlStr.find("</parameter>", scaleIdx)
  check paramEnd > scaleIdx
  let scaleBlock = xmlStr[scaleIdx ..< paramEnd]
  # At least 3 keyframes inside the scale parameter.
  var kfCount = 0
  var i = 0
  while true:
    let k = scaleBlock.find("<keyframe>", i)
    if k < 0: break
    inc kfCount
    i = k + 1
  check kfCount >= 3

  # Center parameter with keyframes.
  let centerId = "<parameterid>center</parameterid>"
  check xmlStr.contains(centerId)
  let centerIdx = xmlStr.find(centerId)
  check centerIdx >= 0
  let centerEnd = xmlStr.find("</parameter>", centerIdx)
  check centerEnd > centerIdx
  let centerBlock = xmlStr[centerIdx ..< centerEnd]
  var centerKfs = 0
  var j = 0
  while true:
    let k = centerBlock.find("<keyframe>", j)
    if k < 0: break
    inc centerKfs
    j = k + 1
  check centerKfs >= 3

  # Well-formed XML.
  discard parseXml(xmlStr)

test "fcp7WriteXml (resolve) emits basic-motion filter":
  let tl = makeZoomTimeline()
  let tempDir = createTempDir("ae-fcp7-resolve-zoom", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.xml"
  fcp7WriteXml("test", outFile, resolve = true, tl)

  let xmlStr = readFile(outFile)
  check xmlStr.contains("<effectid>basic</effectid>")
  check xmlStr.contains("<parameterid>scale</parameterid>")
  check xmlStr.contains("<parameterid>center</parameterid>")
  discard parseXml(xmlStr)

test "fcp7WriteXml: no basic-motion filter when clip has no zoom":
  let tl = makePlainTimeline()
  let tempDir = createTempDir("ae-fcp7-plain", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.xml"
  fcp7WriteXml("test", outFile, resolve = false, tl)

  let xmlStr = readFile(outFile)
  check not xmlStr.contains("<effectid>basic</effectid>")
  discard parseXml(xmlStr)

# ---------------------------------------------------------------------------
# FCPXML 1.11 tests
# ---------------------------------------------------------------------------

test "fcp11WriteXml emits adjust-transform with keyframeAnimation":
  let tl = makeZoomTimeline()
  let tempDir = createTempDir("ae-fcp11-zoom", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.fcpxml"
  fcp11WriteXml("test", "11", outFile, resolve = false, tl)

  let xmlStr = readFile(outFile)
  check xmlStr.contains("<adjust-transform>")
  check xmlStr.contains("<keyframeAnimation>")

  # At least one <param name="scale"> inside.
  check xmlStr.contains("name=\"scale\"")
  discard parseXml(xmlStr)

test "fcp11WriteXml: no adjust-transform when clip has no zoom":
  let tl = makePlainTimeline()
  let tempDir = createTempDir("ae-fcp11-plain", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.fcpxml"
  fcp11WriteXml("test", "11", outFile, resolve = false, tl)

  let xmlStr = readFile(outFile)
  check not xmlStr.contains("<adjust-transform>")
  discard parseXml(xmlStr)
