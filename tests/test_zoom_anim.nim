import unittest

import ../src/log
import ../src/imports/json

test "newZoomAnim: empty keyframes":
  let a = newZoomAnim(@[])
  check a.kind == actZoomAnim
  check a.zoomKfCount == 0
  check a.keyframes == nil

test "newZoomAnim: two keyframes, counts and field access":
  let kfs = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
    ZoomKeyframe(time: 1.0'f32, zoom: 1.2'f32, x: 0.4'f32, y: 0.3'f32),
  ]
  let a = newZoomAnim(kfs)
  check a.kind == actZoomAnim
  check a.zoomKfCount == 2
  check a.zoomKfAt(0).zoom == 1.0'f32
  check a.zoomKfAt(0).time == 0.0'f32
  check a.zoomKfAt(0).x == 0.5'f32
  check a.zoomKfAt(0).y == 0.5'f32
  check a.zoomKfAt(1).x == 0.4'f32
  check a.zoomKfAt(1).y == 0.3'f32
  check a.zoomKfAt(1).zoom == 1.2'f32
  check a.zoomKfAt(1).time == 1.0'f32

test "zoomKeyframes iterator yields in order":
  let kfs = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
    ZoomKeyframe(time: 1.0'f32, zoom: 1.2'f32, x: 0.4'f32, y: 0.3'f32),
  ]
  let a = newZoomAnim(kfs)
  var collected: seq[ZoomKeyframe]
  for kf in a.zoomKeyframes:
    collected.add kf
  check collected.len == 2
  check collected[0].zoom == 1.0'f32
  check collected[0].x == 0.5'f32
  check collected[1].zoom == 1.2'f32
  check collected[1].x == 0.4'f32

test "actZoomAnim equality: same keyframes are equal":
  let kfs = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
    ZoomKeyframe(time: 1.0'f32, zoom: 1.2'f32, x: 0.4'f32, y: 0.3'f32),
  ]
  let a = newZoomAnim(kfs)
  let b = newZoomAnim(kfs)
  check a == b

test "actZoomAnim equality: differing field not equal":
  let kfsA = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
    ZoomKeyframe(time: 1.0'f32, zoom: 1.2'f32, x: 0.4'f32, y: 0.3'f32),
  ]
  let kfsB = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
    ZoomKeyframe(time: 1.0'f32, zoom: 1.25'f32, x: 0.4'f32, y: 0.3'f32),
  ]
  let kfsC = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
  ]
  let a = newZoomAnim(kfsA)
  let b = newZoomAnim(kfsB)
  let c = newZoomAnim(kfsC)
  check a != b
  check a != c

test "actZoomAnim roundtrip via $ + parseAction":
  let kfs = @[
    ZoomKeyframe(time: 0.0'f32, zoom: 1.0'f32, x: 0.5'f32, y: 0.5'f32),
    ZoomKeyframe(time: 1.0'f32, zoom: 1.2'f32, x: 0.4'f32, y: 0.3'f32),
  ]
  let a = newZoomAnim(kfs)
  let s = $a
  check s == "zoomanim:0.0,1.0,0.5,0.5;1.0,1.2,0.4,0.3"
  let parsed = parseAction(s)
  check parsed == a

test "actZoomAnim empty roundtrip":
  let a = newZoomAnim(@[])
  check $a == "zoomanim:"
  let parsed = parseAction("zoomanim:")
  check parsed.kind == actZoomAnim
  check parsed.zoomKfCount == 0
  check parsed == a

test "existing actZoom static path unchanged":
  let z = Action(kind: actZoom, val: 1.2'f32, x: 0.5'f32, y: 0.5'f32)
  check z == z
  check $z == "zoom:1.2:0.5:0.5"
