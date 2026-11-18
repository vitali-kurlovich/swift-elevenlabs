#!/bin/bash
# Builds FluidSpeech.app into FluidSpeech/build/ (ad-hoc signed, Apple Silicon only: MLX needs it).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/FluidSpeech.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Worker"
cp "$BIN/FluidSpeech" "$APP/Contents/MacOS/FluidSpeech"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Worker/fluid_worker.py Worker/fluid_speech_mlx.py Worker/requirements.txt "$APP/Contents/Resources/Worker/"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
