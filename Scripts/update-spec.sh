#!/bin/sh
# Re-download the ElevenLabs spec and regenerate the audio-only openapi.yaml.
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d)
curl -sSf https://api.elevenlabs.io/openapi.json -o "$tmp/openapi.json"
python3 -I make_yaml.py "$tmp/openapi.json" "$tmp/full.yaml" ../Sources/ElevenLabs/openapi.yaml
rm -rf "$tmp"
