"""FluidSpeech worker: keeps one Fluid Speech Pro model in memory and answers JSON-line requests on stdin.

Requests (one JSON object per line):
    {"id": 1, "op": "load", "model_dir": "/path", "bits": 8, "clean": false}
    {"id": 2, "op": "transcribe", "path": "/path/audio.f32", "chunk_duration": 120}
    {"id": 3, "op": "unload"}

Replies (one JSON object per line on stdout):
    {"id": 0, "type": "hello", "mlx": "0.32.4", "parakeet_mlx": "0.7.0"}
    {"id": n, "type": "progress", "value": 0.42}
    {"id": n, "type": "result", ...}
    {"id": n, "type": "error", "message": "..."}

`.f32` paths are raw little-endian float32 mono samples at 16 kHz (the app decodes audio with AVFoundation).
Any other path is decoded by parakeet-mlx through ffmpeg.
"""
import gc
import json
import os
import sys
import time
import traceback
from importlib.metadata import version
from pathlib import Path

# Everything the libraries print goes to stderr; stdout carries only protocol lines.
_protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
sys.stdout = sys.stderr

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
import parakeet_mlx.parakeet as parakeet  # noqa: E402

import fluid_speech_mlx  # noqa: E402

SAMPLE_RATE = 16000
_stock_load_audio = parakeet.load_audio


def _load_audio(path, sampling_rate, dtype=mx.bfloat16):
    path = Path(path)
    if path.suffix == ".f32":
        if sampling_rate != SAMPLE_RATE:
            raise ValueError(f"raw audio must be {SAMPLE_RATE} Hz, model wants {sampling_rate} Hz")
        return mx.array(np.fromfile(path, dtype="<f4"))
    return _stock_load_audio(path, sampling_rate, dtype)


parakeet.load_audio = _load_audio


def send(message):
    _protocol.write(json.dumps(message, ensure_ascii=False) + "\n")
    _protocol.flush()


class Worker:
    def __init__(self):
        self.model = None
        self.key = None

    def load(self, req):
        key = (req["model_dir"], req.get("bits"), bool(req.get("clean")))
        if self.key == key:
            return {"cached": True, "seconds": 0.0}
        self.unload({})
        started = time.monotonic()
        self.model = fluid_speech_mlx.load(req["model_dir"], bits=req.get("bits"), clean_mode=bool(req.get("clean")))
        self.key = key
        return {"cached": False, "seconds": round(time.monotonic() - started, 2)}

    def unload(self, _req):
        self.model = None
        self.key = None
        gc.collect()
        mx.clear_cache()
        return {}

    def transcribe(self, req, rid):
        if self.model is None:
            raise RuntimeError("no model loaded")
        chunk = req.get("chunk_duration")
        overlap = float(req.get("overlap_duration", 15.0))

        def on_chunk(position, total):
            send({"id": rid, "type": "progress", "value": position / max(total, 1)})

        started = time.monotonic()
        result = self.model.transcribe(
            req["path"], chunk_duration=chunk, overlap_duration=overlap, chunk_callback=on_chunk
        )
        elapsed = time.monotonic() - started
        return {
            "text": result.text,
            "seconds": round(elapsed, 3),
            "sentences": [
                {
                    "text": s.text.strip(),
                    "start": round(s.start, 3),
                    "end": round(s.end, 3),
                    "confidence": round(float(s.confidence), 4),
                }
                for s in result.sentences
            ],
        }


def main():
    worker = Worker()
    send({"id": 0, "type": "hello", "mlx": version("mlx"), "parakeet_mlx": version("parakeet-mlx")})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            op = req.get("op")
            if op == "load":
                reply = worker.load(req)
            elif op == "transcribe":
                reply = worker.transcribe(req, rid)
            elif op == "unload":
                reply = worker.unload(req)
            elif op == "quit":
                break
            else:
                raise ValueError(f"unknown op {op!r}")
            send({"id": rid, "type": "result", **reply})
        except Exception as error:  # report every failure to the app instead of dying
            traceback.print_exc()
            send({"id": rid, "type": "error", "message": f"{type(error).__name__}: {error}"})


if __name__ == "__main__":
    main()
