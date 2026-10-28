import ElevenLabs
import Foundation

// Usage:
//   swift run elevenlabs-demo voices
//   swift run elevenlabs-demo speak "Hello there" [voice_id] [out.mp3]
//   swift run elevenlabs-demo transcribe file.mp3

let args = Array(CommandLine.arguments.dropFirst())

do {
    let api = try ElevenLabs.fromEnvironment()
    switch args.first {
    case "voices":
        for voice in try await api.voices() {
            print(voice.voiceId, voice.name)
        }
    case "speak" where args.count >= 2:
        let voiceID = args.count > 2 ? args[2] : "JBFqnCBsd6RMkjVDRZzb"
        let output = URL(fileURLWithPath: args.count > 3 ? args[3] : "speech.mp3")
        let audio = try await api.speech(args[1], voiceID: voiceID)
        try audio.write(to: output)
        print("Wrote \(audio.count) bytes to \(output.path)")
    case "transcribe" where args.count >= 2:
        let url = URL(fileURLWithPath: args[1])
        let transcript = try await api.transcribe(try Data(contentsOf: url), filename: url.lastPathComponent)
        print("[\(transcript.languageCode)] \(transcript.text)")
    default:
        print("usage: elevenlabs-demo voices | speak <text> [voice_id] [out.mp3] | transcribe <file>")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
