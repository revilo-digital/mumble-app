import os

enum Log {
    static let dictation = Logger(subsystem: "nz.olly.Mumble", category: "dictation")
    static let speech = Logger(subsystem: "nz.olly.Mumble", category: "speech")
    static let cleanup = Logger(subsystem: "nz.olly.Mumble", category: "cleanup")
    static let insertion = Logger(subsystem: "nz.olly.Mumble", category: "insertion")
}
