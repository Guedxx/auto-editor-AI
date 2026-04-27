## Shared record types used across the `ai` submodules.

type
  FaceFrame* = object
    time*: float64        # seconds from start
    x*: float32           # bbox center, normalized 0-1 (source coords)
    y*: float32           # bbox center, normalized 0-1 (source coords)
    w*: float32           # bbox width, normalized 0-1
    h*: float32           # bbox height, normalized 0-1
    conf*: float32        # detector confidence
    trackId*: int32

  FaceTrack* = object
    id*: int32
    hits*: int32
    frames*: seq[FaceFrame]

  FaceTracks* = object
    videoFps*: float64
    sourceWidth*: int32
    sourceHeight*: int32
    tracks*: seq[FaceTrack]

  # Legacy type, still used by planner.nim / apply.nim. Derived from
  # FaceTracks via `toFaceSamples` in faces.nim.
  FaceSample* = object
    time*: float64
    x*: float32
    y*: float32
    size*: float32   # bbox area, w * h (normalized)
