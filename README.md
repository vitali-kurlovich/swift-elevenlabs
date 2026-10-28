# ElevenLabsClient

Swift client for the ElevenLabs audio API (text-to-speech, speech-to-text, voice changer,
sound effects, audio isolation, music, voices, models, history). It is generated at build time by
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator) from
`Sources/ElevenLabs/openapi.yaml`.

## Use

```swift
import ElevenLabs

let api = ElevenLabs(apiKey: "sk_...")            // or try ElevenLabs.fromEnvironment()
let mp3 = try await api.speech("Hello!", voiceID: "JBFqnCBsd6RMkjVDRZzb")
let transcript = try await api.transcribe(mp3, filename: "hello.mp3")
let voices = try await api.voices()

// Every other endpoint, via the generated client:
let models = try await api.client.getModels()
```

`fromEnvironment()` reads `ELEVENLABS_API_KEY`, plus an optional `ELEVENLABS_BASE_URL` for a proxy.
Don't ship your API key in an app binary. Call ElevenLabs through your own backend instead.

## Demo

```sh
export ELEVENLABS_API_KEY=sk_...
swift run elevenlabs-demo voices
swift run elevenlabs-demo speak "Hello there" JBFqnCBsd6RMkjVDRZzb out.mp3
swift run elevenlabs-demo transcribe out.mp3
```

## Updating the spec

```sh
Scripts/update-spec.sh
```

This downloads `https://api.elevenlabs.io/openapi.json`, keeps only the audio endpoints, and
patches the parts swift-openapi-generator can't handle:

- `X | null` (`anyOf` with `null`) is dropped by the generator, so the null variant is removed
  and those fields become optional.
- Multipart `string | [string]` becomes `[string]`. Multipart `object | string` becomes `string`
  (a JSON-encoded part).
- Multipart array fields behind a `$ref` are inlined.
- Binary multipart parts are sent as `application/octet-stream`.

`spec/` holds the unpatched ElevenLabs spec converted to YAML: the full API, plus the audio-only subset.
