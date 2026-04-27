import unittest
import std/[json, math, os, tempfiles, times]

import ../src/[av, conductor, ffmpeg, log, media, timeline, wavutil]
import ../src/util/[color, fun, lang]
import ../src/exports/[kdenlive, fcp11]
import ../src/vendor/tinyre/tinyre
import ../src/ai/[apply, cache, faces, planner, schema, types]

test "avrational":
  let a = AVRational(num: 3, den: 4)
  let b = AVRational(num: 3, den: 4)
  check a + b == AVRational(num: 3, den: 2)
  check a + a == a * 2

  let intThree: int64 = 3
  check intThree / AVRational(3) == AVRational(1)
  check intThree * AVRational(3) == AVRational(9)

  check AVRational(num: 9, den: 3).int64 == intThree
  check AVRational(num: 10, den: 3).int64 == intThree
  check AVRational(num: 11, den: 3).int64 == intThree
  check AVRational(num: 10, den: 5) != AVRational(num: 2, den: 1) # use compare

  check AVRational("42") == AVRational(42)
  check AVRational("-2/3") == AVRational(num: -2, den: 3)
  check AVRational("6/8") == AVRational(num: 3, den: 4)
  check AVRational("1.5") == AVRational(num: 3, den: 2)

test "color":
  check RGBColor(red: 0, green: 0, blue: 0).toString == "#000000"
  check RGBColor(red: 255, green: 255, blue: 255).toString == "#ffffff"

  check parseColor("#000") == RGBColor(red: 0, green: 0, blue: 0)
  check parseColor("#000000") == RGBColor(red: 0, green: 0, blue: 0)
  check parseColor("#FFF") == RGBColor(red: 255, green: 255, blue: 255)
  check parseColor("#fff") == RGBColor(red: 255, green: 255, blue: 255)
  check parseColor("#FFFFFF") == RGBColor(red: 255, green: 255, blue: 255)

  check parseColor("black") == RGBColor(red: 0, green: 0, blue: 0)
  check parseColor("darkgreen") == RGBColor(red: 0, green: 100, blue: 0)

test "dialogue":
  check "0,0,Default,,0,0,0,,oop".dialogue == "oop"
  check "0,0,Default,,0,0,0,,boop".dialogue == "boop"

test "encoder":
  let (_, encoderCtx) = initEncoder("pcm_s16le")
  check encoderCtx.codec_type == AVMEDIA_TYPE_AUDIO
  check encoderCtx.bit_rate != 0

  let (_, encoderCtx2) = initEncoder(ID_PCM_S16LE)
  check encoderCtx2.codec_type == AVMEDIA_TYPE_AUDIO
  check encoderCtx2.bit_rate != 0

test "exports":
  check(parseExportString("premiere:name=a,version=3") == ("premiere", "a", "3"))
  check(parseExportString("premiere:name=a") == ("premiere", "a", "11"))
  check(parseExportString("premiere:name=\"Hello \\\" World") == ("premiere",
      "Hello \" World", "11"))
  check(parseExportString("premiere:name=\"Hello \\\\ World") == ("premiere",
      "Hello \\ World", "11"))

test "margin":
  var levels: seq[bool]
  levels = @[false, false, true, false, false]
  mutMargin(levels, 0, 1)
  check(levels == @[false, false, true, true, false])

  levels = @[false, false, true, false, false]
  mutMargin(levels, 1, 0)
  check(levels == @[false, true, true, false, false])

  levels = @[false, false, true, false, false]
  mutMargin(levels, 1, 1)
  check(levels == @[false, true, true, true, false])

  levels = @[false, false, true, false, false]
  mutMargin(levels, 2, 2)
  check(levels == @[true, true, true, true, true])

  levels = @[false, true, true, true, false]
  mutMargin(levels, -1, -1)
  check(levels == @[false, false, true, false, false])

  levels = @[false, true, true, true, true, true, true, true, false]
  mutMargin(levels, 3, -4)
  check(levels == @[true, true, true, true, false, false, false, false, false])

test "mp3towav":
  let tempDir = createTempDir("tmp", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out2.wav"
  transcodeAudio("resources/mono.mp3", outFile, 0)

  let container = av.open(outFile)
  defer: container.close()
  check container.audio.len == 1
  check $container.audio[0].name == "pcm_s16le"
  check $container.audio[0].codecpar.ch_layout in ["mono", "1 channels"]

test "mp4towav":
  let tempDir = createTempDir("tmp", "")
  defer: removeDir(tempDir)
  let outFile = tempDir / "out.wav"
  transcodeAudio("example.mp4", outFile, 0)

  let container = av.open(outFile)
  defer: container.close()
  check container.audio.len == 1
  check $container.audio[0].name == "pcm_s16le"

test "size-of-objects":
  check sizeof(seq) == 16
  check sizeof(ref seq) == 8
  check sizeof(string) == 16
  check sizeof(ref string) == 8
  check sizeof(AVCodecID) == 4
  check sizeof(AVPixelFormat) == 4
  check sizeof(AVRational) == 8
  check sizeof(VideoStream) == 96
  check sizeof(AudioStream) == 48
  check sizeof(SubtitleStream) == 16
  check sizeof(MediaInfo) == 96
  check sizeof(Clip) == 40
  check sizeof(AVChannelLayout) == 24

  check sizeof(RGBColor) == 3
  check sizeof(v3) == 128

test "lang-to-string":
  check sizeof(Lang) == 4
  var a: Lang = ['a', 's', 'd', 'f']
  check $a == "asdf"
  a  = ['e', 'n', 'g', '\0']
  check $a == "eng"

test "re":
  check match("abc123", re"\d+") == @["123"]
  check match("abc123", re(".", {reGlobal})) == @["a", "b", "c", "1", "2", "3"]
  check match("abc123", re("ABC", {reIgnoreCase})) == @["abc"]
  check match("abc123", re"ABC") != @["abc"]
  check match("中文", re("..", {reUtf8})) == @["中文"]
  check match("中文", re"..") != @["中文"]

test "smpte":
  check parseSMPTE("13:44:05:21", AVRational(num: 24000, den: 1001)) == 1186701

test "uuid":
  # Test that genUuid generates valid RFC 4122 version 4 UUIDs
  for i in 1..3:
    let uuid = genUuid()

    # Check format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    check(uuid.len == 36)
    check(uuid[8] == '-')
    check(uuid[13] == '-')
    check(uuid[18] == '-')
    check(uuid[23] == '-')

    # Check version (should be 4)
    check(uuid[14] == '4')

    # Check variant bits (should be 8, 9, a, or b)
    check(uuid[19] in ['8', '9', 'a', 'b'])

    # Check all other characters are valid hex
    for j, c in uuid:
      if j notin [8, 13, 18, 23]: # Skip dashes
        check(c in "0123456789abcdef")


# ---------------------------------------------------------------------------
# Phase 7: AI pipeline unit tests
# ---------------------------------------------------------------------------

const FixturesDir = currentSourcePath().parentDir / "fixtures"

test "Actions: aNil, aCut identity":
  check aNil == aNil
  check aCut == aCut
  check aNil != aCut
  check aNil.isEmpty and not aCut.isEmpty
  check aCut.isCut and not aNil.isCut
  check aNil.len == 0 and aCut.len == 0

test "Actions: value-equality with same content":
  let a = newActions(@[Action(kind: actSpeed, val: 1.2)])
  let b = newActions(@[Action(kind: actSpeed, val: 1.2)])
  check a == b
  check a.len == 1
  check a[0].kind == actSpeed
  check a[0].val == 1.2'f32

test "Actions: zoom x,y participates in equality":
  let a = newActions(@[Action(kind: actZoom, val: 1.2, x: 0.5, y: 0.5)])
  let b = newActions(@[Action(kind: actZoom, val: 1.2, x: 0.5, y: 0.5)])
  let c = newActions(@[Action(kind: actZoom, val: 1.2, x: 0.6, y: 0.5)])
  check a == b
  check a != c

test "parseTranscript: python whisper format":
  let raw = readFile(FixturesDir / "transcript_python.json")
  let segs = parseTranscript(raw)
  check segs.len == 3
  check segs[0].start == 0.0
  check segs[0].endTime == 1.5
  check segs[0].text == "Hello world."
  check segs[1].start == 1.5
  check segs[1].endTime == 3.25
  check segs[2].text == "Three segments."

test "parseTranscript: whisper.cpp offsets format (ms -> seconds)":
  let raw = readFile(FixturesDir / "transcript_whisper.json")
  let segs = parseTranscript(raw)
  check segs.len == 2
  check segs[0].start == 0.0
  check segs[0].endTime == 1.5
  check segs[0].text == "Hello world."
  check segs[1].start == 1.5
  check segs[1].endTime == 3.25
  check segs[1].text == "This is a test."

test "parseTranscript: unknown format -> empty":
  let segs = parseTranscript("""{"weird":[1,2,3]}""")
  check segs.len == 0

test "parseTranscript: empty string -> empty":
  check parseTranscript("").len == 0
  check parseTranscript("   \n\t ").len == 0

test "parseTranscript: malformed JSON -> empty":
  check parseTranscript("{not json").len == 0

test "pickSpeakerTrack: hits dominate over bbox area":
  # Track A: 10 frames in [0,5] at size 0.04 (w=0.2, h=0.2)
  # Track B:  3 frames in [0,5] at size 0.12 (w=0.3, h=0.4)
  var tA = FaceTrack(id: 1, hits: 10)
  for i in 0 .. 9:
    let t = i.float64 * 0.5  # 0.0, 0.5, ..., 4.5 — all inside [0, 5]
    tA.frames.add FaceFrame(
      time: t, x: 0.5'f32, y: 0.5'f32,
      w: 0.2'f32, h: 0.2'f32, conf: 0.9'f32, trackId: 1)
  var tB = FaceTrack(id: 2, hits: 3)
  for i in 0 .. 2:
    let t = 1.0 + i.float64 * 1.5
    tB.frames.add FaceFrame(
      time: t, x: 0.5'f32, y: 0.5'f32,
      w: 0.3'f32, h: 0.4'f32, conf: 0.9'f32, trackId: 2)
  let tracks = FaceTracks(videoFps: 30.0, sourceWidth: 1920,
    sourceHeight: 1080, tracks: @[tA, tB])
  let (picked, ok) = pickSpeakerTrack(tracks, 0.0, 5.0)
  check ok
  check picked.id == 1

test "pickSpeakerTrack: no coverage -> (_, false)":
  var tA = FaceTrack(id: 1, hits: 2)
  tA.frames.add FaceFrame(time: 10.0, x: 0.5'f32, y: 0.5'f32,
    w: 0.2'f32, h: 0.2'f32, conf: 0.9'f32, trackId: 1)
  tA.frames.add FaceFrame(time: 11.0, x: 0.5'f32, y: 0.5'f32,
    w: 0.2'f32, h: 0.2'f32, conf: 0.9'f32, trackId: 1)
  let tracks = FaceTracks(tracks: @[tA])
  let (_, ok) = pickSpeakerTrack(tracks, 0.0, 5.0)
  check not ok

test "smoothedCenter: moving average inside window":
  # x goes linearly 0.2 -> 0.8 across t=0..1. Use times that are exactly
  # representable in binary floating point so windowing isn't affected by
  # the 0.1-isn't-representable wart.
  # Samples at t = 0.0, 0.25, 0.5, 0.75, 1.0 with x = 0.2, 0.35, 0.5, 0.65, 0.8.
  var tr = FaceTrack(id: 0, hits: 5)
  for i in 0 .. 4:
    let t = i.float64 * 0.25
    let x = (0.2 + 0.6 * t).float32
    tr.frames.add FaceFrame(time: t, x: x, y: 0.5'f32,
      w: 0.1'f32, h: 0.1'f32, conf: 0.9'f32, trackId: 0)
  # Window around t=0.5 with +/- 0.3 pulls in frames at t=0.25, 0.5, 0.75.
  # Their x values are 0.35, 0.5, 0.65 => mean = 0.5.
  let (sx, sy) = smoothedCenter(tr, 0.5, 0.3)
  check abs(sx - 0.5'f32) < 0.01'f32
  check abs(sy - 0.5'f32) < 1e-5'f32

test "smoothedCenter: empty window -> (-1, -1)":
  var tr = FaceTrack(id: 0, hits: 2)
  tr.frames.add FaceFrame(time: 0.0, x: 0.5'f32, y: 0.5'f32,
    w: 0.1'f32, h: 0.1'f32, conf: 0.9'f32, trackId: 0)
  tr.frames.add FaceFrame(time: 1.0, x: 0.5'f32, y: 0.5'f32,
    w: 0.1'f32, h: 0.1'f32, conf: 0.9'f32, trackId: 0)
  let (sx, sy) = smoothedCenter(tr, 10.0, 0.5)
  check sx == -1.0'f32
  check sy == -1.0'f32

# -- Helpers for apply tests -------------------------------------------------

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

proc onlyAnim(a: Actions): Action =
  ## Return the first actZoomAnim Action in an Actions group (raises if none).
  for act in a:
    if act.kind == actZoomAnim:
      return act
  raise newException(ValueError, "no actZoomAnim in group")

proc hasSpeed(a: Actions): bool =
  for act in a:
    if act.kind == actSpeed:
      return true
  false

test "addPlanActions: animated zoom emits eased sub-windows with face center":
  # Post Phase E: a single actZoomAnim Action with a dense keyframe list,
  # not multiple sub-windowed zoom entries.
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 3.0, "action": "keep",
       "speed": 1.0, "zoom": 1.2, "reason": "test"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.4'f32, 0.0, 6.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)

  check args.setAction.len == 1
  let (group, _, _) = args.setAction[0]
  let anim = onlyAnim(group)
  check anim.zoomKfCount > 3

  # Keyframes centered on (0.5, 0.4) (constant face track).
  for kf in anim.zoomKeyframes:
    check abs(kf.x - 0.5'f32) < 0.01'f32
    check abs(kf.y - 0.4'f32) < 0.01'f32

  # First / last keyframe eases to 1.0, some middle keyframe hits 1.2.
  let n = anim.zoomKfCount
  check anim.zoomKfAt(0).zoom < 1.2'f32
  check anim.zoomKfAt(n - 1).zoom < 1.2'f32
  check abs(anim.zoomKfAt(0).zoom - 1.0'f32) < 1e-4'f32
  check abs(anim.zoomKfAt(n - 1).zoom - 1.0'f32) < 1e-4'f32

  var sawPlateau = false
  for kf in anim.zoomKeyframes:
    if abs(kf.zoom - 1.2'f32) < 1e-4'f32:
      sawPlateau = true
      break
  check sawPlateau

test "addPlanActions: cut segment emits a single aCut group":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 2.0, "action": "cut",
       "speed": 1.0, "zoom": 1.0, "reason": "silence"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.5'f32, 0.0, 6.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)
  check args.setAction.len == 1
  check args.setAction[0][0].isCut

test "addPlanActions: keep speed=1.2 zoom=1.0 -> no sub-segmentation":
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 3.0, "action": "keep",
       "speed": 1.2, "zoom": 1.0, "reason": "tight"}
    ]
  }
  let tracks = buildFlatTracks(0.5'f32, 0.5'f32, 0.0, 6.0, 60)
  let faces = toFaceSamples(tracks)
  addPlanActions(args, plan, tracks, faces,
    chunkStart = 0.0, chunkStop = 5.0, duration = 10.0)
  check args.setAction.len == 1
  let group = args.setAction[0][0]
  check group.hasSpeed
  # no actZoom should be present
  var gotZoom = false
  for act in group:
    if act.kind == actZoom:
      gotZoom = true
  check not gotZoom
  check group.len == 1
  check group[0].val == 1.2'f32

test "addPlanActions: short zoom segment (< 2*ease) -> single constant-zoom step":
  # Post Phase E: a single-keyframe actZoomAnim at constant zoom.
  # Ease threshold is 0.20 s, so any segDur < 0.40 s is "short".
  var args = mainArgs()
  let plan = %* {
    "segments": [
      {"start": 1.0, "end": 1.1, "action": "keep",
       "speed": 1.0, "zoom": 1.2, "reason": "emphasis"}
    ]
  }
  let tracks = buildFlatTracks(0.4'f32, 0.6'f32, 0.0, 6.0, 60)
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

test "planSchema: shape + clamps + required reason":
  let s = planSchema()
  check s.kind == JObject
  check s.hasKey("properties")
  let segItems = s["properties"]["segments"]["items"]
  check segItems.hasKey("properties")
  let props = segItems["properties"]
  check props["speed"]["minimum"].getFloat() == 0.75
  check props["speed"]["maximum"].getFloat() == 1.5
  check props["zoom"]["minimum"].getFloat() == 1.0
  check props["zoom"]["maximum"].getFloat() == 1.35
  # `reason` must be in the required list.
  var sawReason = false
  for r in segItems["required"]:
    if r.getStr() == "reason":
      sawReason = true
      break
  check sawReason

test "fileFingerprint: stable across repeated calls on unchanged file":
  let tempDir = createTempDir("ae-ai-fp", "")
  defer: removeDir(tempDir)
  let path = tempDir / "probe.bin"
  writeFile(path, "hello-fingerprint")
  let fp1 = fileFingerprint(path)
  let fp2 = fileFingerprint(path)
  check fp1.len > 0
  check fp1 == fp2

test "fileFingerprint: changes when mtime changes":
  let tempDir = createTempDir("ae-ai-fp2", "")
  defer: removeDir(tempDir)
  let path = tempDir / "probe.bin"
  writeFile(path, "hello-fingerprint")
  let fp1 = fileFingerprint(path)

  # Bump mtime by a full second to defeat any FS second-level truncation.
  let info = getFileInfo(path)
  let newT = info.lastWriteTime + initDuration(seconds = 2)
  setLastModificationTime(path, newT)

  let fp2 = fileFingerprint(path)
  check fp1 != fp2

import ./test_zoom_anim
import ./test_zoom_export
import ./test_apply_keyframes
import ./test_export_mlt
import ./test_export_apple

