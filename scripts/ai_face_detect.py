#!/usr/bin/env python3
"""Dense face detection + simple IoU tracker for auto-editor-AI.

Uses OpenCV's built-in YuNet (FaceDetectorYN) DNN detector. The ONNX
weights are auto-downloaded once to ~/.cache/auto-editor-ai/models/ on
first use, unless --model PATH is given. The script decodes every video
frame sequentially (no PTS seeks) and runs the detector at a chosen
cadence (default 6 Hz), then links detections across frames with a
lightweight IoU/centroid tracker.

Stdout is a single-line JSON document with schema:
    {"schema": 2, "video_fps": F, "source_width": W, "source_height": H,
     "tracks": [{"id": N, "hits": M, "frames": [...]}]}

Progress messages and errors go to stderr. Exit codes: 0 ok, 1 runtime
failure, 2 bad args / missing input / missing model.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, List, Optional, Tuple

MODEL_URL = (
    "https://github.com/opencv/opencv_zoo/raw/main/"
    "models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
)
MODEL_FILENAME = "face_detection_yunet_2023mar.onnx"
DETECT_MAX_DIM = 640
IOU_MATCH_THRESHOLD = 0.25
CENTROID_MATCH_PX = 40.0
TRACK_EXPIRY_SECS = 2.0


def log_err(msg: str, verbose: bool = True) -> None:
    if verbose:
        print(msg, file=sys.stderr, flush=True)


def cache_dir() -> str:
    base = os.environ.get("XDG_CACHE_HOME")
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "auto-editor-ai", "models")


def default_model_path() -> str:
    return os.path.join(cache_dir(), MODEL_FILENAME)


def download_model(dest: str, verbose: bool) -> None:
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    tmp = dest + ".tmp"
    log_err(f"face detect: downloading YuNet model -> {dest}", verbose)
    try:
        with urllib.request.urlopen(MODEL_URL, timeout=30) as resp:
            data = resp.read()
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, dest)
    except (urllib.error.URLError, OSError) as exc:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
        raise RuntimeError(
            f"could not download YuNet model from {MODEL_URL}: {exc}\n"
            "hint: download it manually and pass --model PATH"
        ) from exc


def resolve_model(explicit: Optional[str], verbose: bool) -> str:
    if explicit:
        if not os.path.isfile(explicit):
            raise RuntimeError(f"--model does not exist: {explicit}")
        return explicit
    path = default_model_path()
    if not os.path.isfile(path):
        download_model(path, verbose)
    return path


@dataclass
class Detection:
    cx: float  # normalized 0-1 center on source frame
    cy: float
    w: float   # normalized 0-1
    h: float
    conf: float
    # pixel-space bbox on detection-sized frame (for tracker):
    px_x: float
    px_y: float
    px_w: float
    px_h: float


@dataclass
class Track:
    id: int
    last_frame: int
    last_bbox_px: Tuple[float, float, float, float]  # x,y,w,h on detect frame
    hits: int = 0
    frames: List[dict] = field(default_factory=list)


def iou(a: Tuple[float, float, float, float],
        b: Tuple[float, float, float, float]) -> float:
    ax1, ay1, aw, ah = a
    bx1, by1, bw, bh = b
    ax2, ay2 = ax1 + aw, ay1 + ah
    bx2, by2 = bx1 + bw, by1 + bh
    ix1 = max(ax1, bx1)
    iy1 = max(ay1, by1)
    ix2 = min(ax2, bx2)
    iy2 = min(ay2, by2)
    iw = max(0.0, ix2 - ix1)
    ih = max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0.0:
        return 0.0
    union = aw * ah + bw * bh - inter
    if union <= 0.0:
        return 0.0
    return inter / union


def centroid_dist(a: Tuple[float, float, float, float],
                  b: Tuple[float, float, float, float]) -> float:
    acx = a[0] + a[2] * 0.5
    acy = a[1] + a[3] * 0.5
    bcx = b[0] + b[2] * 0.5
    bcy = b[1] + b[3] * 0.5
    dx = acx - bcx
    dy = acy - bcy
    return (dx * dx + dy * dy) ** 0.5


def match_track(tracks: List[Track],
                det_bbox: Tuple[float, float, float, float]) -> Optional[Track]:
    best: Optional[Track] = None
    best_score = 0.0
    for tr in tracks:
        score = iou(tr.last_bbox_px, det_bbox)
        if score > best_score:
            best_score = score
            best = tr
    if best is not None and best_score >= IOU_MATCH_THRESHOLD:
        return best
    # Fallback: centroid distance
    best = None
    best_d = CENTROID_MATCH_PX
    for tr in tracks:
        d = centroid_dist(tr.last_bbox_px, det_bbox)
        if d < best_d:
            best_d = d
            best = tr
    return best


def run_yunet(detector: Any,
              frame: Any,
              scale: float,
              src_w: int,
              src_h: int,
              min_conf: float) -> List[Detection]:
    fh, fw = frame.shape[:2]
    detector.setInputSize((fw, fh))
    _, faces = detector.detect(frame)
    out: List[Detection] = []
    if faces is None:
        return out
    for row in faces:
        # row: [x, y, w, h, re_x, re_y, le_x, le_y, nt_x, nt_y, rcm_x, rcm_y, lcm_x, lcm_y, score]
        x, y, w, h = float(row[0]), float(row[1]), float(row[2]), float(row[3])
        score = float(row[-1])
        if score < min_conf:
            continue
        if w <= 1 or h <= 1:
            continue
        # Clip to detection-frame bounds
        x = max(0.0, x)
        y = max(0.0, y)
        if x + w > fw:
            w = fw - x
        if y + h > fh:
            h = fh - y
        if w <= 1 or h <= 1:
            continue
        # Project to source coords (normalized 0-1). The detection frame is
        # an aspect-preserving resize of the source, so normalizing by the
        # detection frame dimensions already gives source-space normalized
        # coords.
        cx_norm = (x + w * 0.5) / float(fw)
        cy_norm = (y + h * 0.5) / float(fh)
        w_norm = w / float(fw)
        h_norm = h / float(fh)
        out.append(
            Detection(
                cx=cx_norm, cy=cy_norm, w=w_norm, h=h_norm, conf=score,
                px_x=x, px_y=y, px_w=w, px_h=h,
            )
        )
    return out


def process_video(
    cap: Any,
    detector: Any,
    video_fps: float,
    src_w: int,
    src_h: int,
    total_frames: int,
    detect_fps: float,
    min_conf: float,
    verbose: bool,
) -> List[Track]:
    import cv2

    stride = max(1, int(round(video_fps / max(detect_fps, 0.1))))
    scale = 1.0
    if max(src_w, src_h) > DETECT_MAX_DIM:
        scale = DETECT_MAX_DIM / float(max(src_w, src_h))
    det_w = max(1, int(round(src_w * scale)))
    det_h = max(1, int(round(src_h * scale)))
    use_resize = (det_w != src_w or det_h != src_h)

    tracks: List[Track] = []
    next_id = 0
    frame_idx = -1
    duration = total_frames / video_fps if video_fps > 0 else 0.0
    last_log = time.monotonic()

    while True:
        ok = cap.grab()
        if not ok:
            break
        frame_idx += 1
        if frame_idx % stride != 0:
            continue
        ok, frame = cap.retrieve()
        if not ok or frame is None:
            continue

        t = frame_idx / video_fps if video_fps > 0 else 0.0

        if use_resize:
            det_frame = cv2.resize(frame, (det_w, det_h))
        else:
            det_frame = frame

        detections = run_yunet(detector, det_frame, scale, src_w, src_h, min_conf)

        # Expire stale tracks
        cutoff_frames = int(TRACK_EXPIRY_SECS * video_fps)
        tracks = [tr for tr in tracks if frame_idx - tr.last_frame <= cutoff_frames]

        consumed: set[int] = set()
        for det in detections:
            bbox_px = (det.px_x, det.px_y, det.px_w, det.px_h)
            candidates = [tr for tr in tracks if id(tr) not in consumed]
            m = match_track(candidates, bbox_px)
            if m is None:
                m = Track(id=next_id, last_frame=frame_idx, last_bbox_px=bbox_px)
                next_id += 1
                tracks.append(m)
            consumed.add(id(m))
            m.last_frame = frame_idx
            m.last_bbox_px = bbox_px
            m.hits += 1
            m.frames.append({
                "time": round(t, 3),
                "x": round(det.cx, 5),
                "y": round(det.cy, 5),
                "w": round(det.w, 5),
                "h": round(det.h, 5),
                "conf": round(det.conf, 3),
            })

        now = time.monotonic()
        if verbose and now - last_log >= 1.0:
            if duration > 0:
                pct = min(100.0, 100.0 * t / duration)
                log_err(f"face detect: {t:6.1f}s / {duration:6.1f}s ({pct:4.1f}%)", verbose)
            else:
                log_err(f"face detect: frame {frame_idx}", verbose)
            last_log = now

    return tracks


def tracks_to_json(
    tracks: List[Track],
    video_fps: float,
    src_w: int,
    src_h: int,
) -> dict:
    out_tracks = []
    # Reassign IDs compactly so they are contiguous starting at 0
    tracks_sorted = sorted(tracks, key=lambda tr: (-tr.hits, tr.id))
    for new_id, tr in enumerate(tracks_sorted):
        if tr.hits <= 0:
            continue
        out_tracks.append({
            "id": new_id,
            "hits": tr.hits,
            "frames": tr.frames,
        })
    return {
        "schema": 2,
        "video_fps": round(video_fps, 4),
        "source_width": int(src_w),
        "source_height": int(src_h),
        "tracks": out_tracks,
    }


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="ai_face_detect.py",
        description="Dense YuNet face detection + IoU tracking for auto-editor-AI.",
    )
    parser.add_argument("video", help="path to input video")
    parser.add_argument("--model", default=None,
                        help="path to YuNet ONNX model (default: auto-download to cache)")
    parser.add_argument("--fps", type=float, default=6.0,
                        help="detection rate in Hz (default 6.0)")
    parser.add_argument("--min-conf", type=float, default=0.6,
                        help="minimum detection confidence (default 0.6)")
    parser.add_argument("--verbose", action="store_true",
                        help="enable info logs to stderr")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    ns = parse_args(argv)

    if not os.path.isfile(ns.video):
        print(f"video file not found: {ns.video}", file=sys.stderr)
        return 2
    if ns.fps <= 0:
        print("--fps must be positive", file=sys.stderr)
        return 2
    if not (0.0 <= ns.min_conf <= 1.0):
        print("--min-conf must be in [0,1]", file=sys.stderr)
        return 2

    try:
        import cv2  # noqa: F401
    except Exception as exc:
        print(f"python OpenCV import failed: {exc}", file=sys.stderr)
        print("hint: pip install -r requirements-ai.txt", file=sys.stderr)
        return 1

    try:
        model_path = resolve_model(ns.model, ns.verbose)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    cap = cv2.VideoCapture(ns.video)
    if not cap.isOpened():
        print(f"could not open video: {ns.video}", file=sys.stderr)
        return 2

    try:
        video_fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
        if video_fps <= 0:
            video_fps = 30.0
        src_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
        src_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        if src_w <= 0 or src_h <= 0:
            print("could not read video dimensions", file=sys.stderr)
            return 1

        # Detection size: clamp to <=640 on longest side, preserve aspect ratio.
        scale = 1.0
        if max(src_w, src_h) > DETECT_MAX_DIM:
            scale = DETECT_MAX_DIM / float(max(src_w, src_h))
        det_w = max(1, int(round(src_w * scale)))
        det_h = max(1, int(round(src_h * scale)))

        try:
            detector = cv2.FaceDetectorYN.create(
                model_path, "", (det_w, det_h),
                score_threshold=float(ns.min_conf),
                nms_threshold=0.3,
                top_k=50,
            )
        except Exception as exc:
            print(f"could not init YuNet detector from {model_path}: {exc}", file=sys.stderr)
            return 1

        tracks = process_video(
            cap, detector, video_fps, src_w, src_h, total_frames,
            ns.fps, ns.min_conf, ns.verbose,
        )
    except Exception as exc:
        print(f"face detection failed: {exc}", file=sys.stderr)
        return 1
    finally:
        cap.release()

    payload = tracks_to_json(tracks, video_fps, src_w, src_h)
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
