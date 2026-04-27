#!/usr/bin/env python3
import json
import sys

try:
    import cv2
except Exception as exc:
    print(f"python OpenCV import failed: {exc}", file=sys.stderr)
    sys.exit(2)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ai_face_detect.py <video>", file=sys.stderr)
        return 2

    video = sys.argv[1]
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        print(f"could not open video: {video}", file=sys.stderr)
        return 2

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0.0
    duration = total_frames / fps if fps > 0 else 0.0
    sample_count = 30

    cascade_path = cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
    detector = cv2.CascadeClassifier(cascade_path)
    if detector.empty():
        print(f"could not load OpenCV cascade: {cascade_path}", file=sys.stderr)
        return 2

    samples = []
    if duration > 0:
        sample_times = [duration * i / max(sample_count - 1, 1) for i in range(sample_count)]
    else:
        sample_times = [i * 2.0 for i in range(sample_count)]

    for t in sample_times:
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
        ok, frame = cap.read()
        if not ok:
            break

        h, w = frame.shape[:2]
        if w > 480:
            scale = 480.0 / w
            frame = cv2.resize(frame, (480, max(1, int(round(h * scale)))))
        h, w = frame.shape[:2]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        faces = detector.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(32, 32))
        if len(faces):
            # Prefer the largest detected face; it is usually the active speaker in talking-head footage.
            x, y, fw, fh = max(faces, key=lambda box: box[2] * box[3])
            samples.append(
                {
                    "time": round(t, 3),
                    "x": round((x + fw / 2.0) / max(w, 1), 4),
                    "y": round((y + fh / 2.0) / max(h, 1), 4),
                    "size": round((fw * fh) / float(max(w * h, 1)), 6),
                }
            )
    cap.release()
    print(json.dumps(samples, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
