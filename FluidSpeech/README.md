# FluidSpeech

A macOS app that transcribes speech on your Mac with
[Fluid Speech Pro (MLX)](https://huggingface.co/FluidVoice-Labs/fluid-speech-pro-mlx): English and 24 other European
languages, detected automatically, with punctuation, capitalization and sentence timestamps. Nothing leaves the Mac
after setup.

- Drop audio or video files on the window, use **Open Audio…** (⌘O), or open files with the app from Finder
- **Record** (⌘R) from the microphone and transcribe when you stop
- Sentence view with timestamps: click one to play the audio from there. The current sentence is highlighted while it plays
- **Clean mode** drops filler words (“um”, “uh”) and repeated words. Don't use it where you need an exact record
- 8-bit (751 MB) or full-precision (2.5 GB) weights
- Copy the text, or save it as `.txt` or `.srt` subtitles
- Long files are transcribed in overlapping chunks (Settings → Long files)

Needs an Apple Silicon Mac (MLX) running macOS 14 or later, plus [uv](https://docs.astral.sh/uv/) (`brew install uv`).

## Build

```sh
FluidSpeech/Scripts/build-app.sh
open FluidSpeech/build/FluidSpeech.app
```

On first launch the app walks through two steps: it installs a private Python environment with uv
(Python 3.12, `mlx`, `parakeet-mlx`, about 300 MB), then downloads the model weights from Hugging Face.

## How it works

The model is NVIDIA Parakeet TDT 0.6B v3 with one extra block, and it runs through the Python
[parakeet-mlx](https://github.com/senstella/parakeet-mlx) package. The app has three parts:

| Part | What it does |
| --- | --- |
| SwiftUI app (`Sources/FluidSpeech`) | UI, model downloads, microphone capture, and decoding any AVFoundation-readable audio or video to 16 kHz mono float32 |
| `Worker/fluid_worker.py` | A long-lived Python process that keeps the model in memory and answers JSON-line requests on stdin/stdout |
| `Worker/fluid_speech_mlx.py` | The model's own loader, copied unchanged from the model repo at revision `aeb1d4e` |

The worker is started on the first transcription and stays loaded. Changing the weights or clean mode reloads it.
Files AVFoundation can't open (Ogg, WebM, …) fall back to parakeet-mlx's ffmpeg reader if `ffmpeg` is installed.

Data lives in `~/Library/Application Support/FluidSpeech`: `python/` (the environment), `models/<revision>/`
(the weights), `Recordings/`, and `history.json`. Settings has buttons to delete weights or reinstall the
environment.

## Command line

The app binary also runs without its window:

```sh
APP=FluidSpeech/build/FluidSpeech.app/Contents/MacOS/FluidSpeech
$APP --download [--full] [--clean]
$APP --transcribe [--full] [--clean] [--srt] audio.m4a video.mov …
```

## License

Fluid Speech Pro by FluidVoice, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Based on NVIDIA
Parakeet TDT 0.6B v3. `Worker/fluid_speech_mlx.py` comes from the model repository under the same license.
