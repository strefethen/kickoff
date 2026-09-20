import CryptoKit
import Foundation

// Synthetic inputs isolate marker work. They are not an observed Hulu AX tree.
let visibleText = [
    "", "Play", "Pause", "Mute", "Unmute", "Volume", "Settings", "Captions",
    "Full screen", "Exit full screen", "Next episode", "Episodes", "Watch live",
    "00:00", "45:20", "1:02:03", "Season 2", "Episode 14", "Hulu", "Continue watching",
    "English", "Audio description", "Quality", "Auto", "1080p", "Return to browse",
    "Playback speed", "Sign in", "Comedy", "Résumé", "日本語", "😀"
]
let countdowns = ["Ad 0:00", "Ad 0:01", "Ad 1:09", "Ad 1:59", "Ad 9:58", "Ad 99:23", "Ad 000:00", "Ad 123456789:59"]
let nearMisses = ["Ads", "Ad ", "Ad 1:60", "Ad 1:0", "Ad 1:000", "Ad ١:00", "Ad 1:٠٠", "Ad 1:00 extra", "Ad\n", "Ad 1:00\r\n", "Ad\u{0301}", "Ad\u{0000}"]

enum Operation {
    case matches([String])
    case nodes([PlayerContentNode])
}

struct Workload {
    let name: String
    let operation: Operation
    let repetitions: Int
    var callsPerRepetition: Int {
        switch operation {
        case .matches(let values): return values.count
        case .nodes: return 1
        }
    }
}

let workloads = [
    Workload(name: "synthetic_visible_text", operation: .matches(visibleText + ["Ad", "Ad 0:30"]), repetitions: 2048),
    Workload(name: "exact_ad", operation: .matches(["Ad"]), repetitions: 16384),
    Workload(name: "countdowns", operation: .matches(countdowns), repetitions: 4096),
    Workload(name: "ad_prefix_near_misses", operation: .matches(nearMisses), repetitions: 4096),
    Workload(name: "synthetic_static_node_scan", operation: .nodes(visibleText.map { PlayerContentNode(role: "AXStaticText", value: $0) }), repetitions: 2048),
    Workload(name: "nonstatic_node_filter", operation: .nodes((visibleText + ["Ad", "Ad 0:30"]).map { PlayerContentNode(role: "AXButton", value: $0) }), repetitions: 8192),
]

// The accumulated return value is emitted, keeping all measured calls observable.
@inline(never)
func runBatch(_ workload: Workload, repetitions: Int) -> Int {
    var hits = 0
    switch workload.operation {
    case .matches(let values):
        for _ in 0..<repetitions {
            for value in values {
                if AdMarker.matches(value) { hits &+= 1 }
            }
        }
    case .nodes(let nodes):
        for _ in 0..<repetitions {
            if AdMarker.isPresent(inPlayerNodes: nodes) { hits &+= 1 }
        }
    }
    return hits
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func signature() -> [String: Any] {
    var corpus = visibleText + countdowns + nearMisses
    let endings = ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}", "\u{0000}"]
    for value in ["Ad", "Ad 0:00", "Ad 123:59"] {
        corpus += endings.map { value + $0 }
        corpus += endings.map { $0 + value }
    }
    corpus += ["ad", "AD", "Ａd", "Aⅾ", "A\u{0301}d", "A\u{0000}d", " Ad", "Ad １:00", "Ad 1:００", "Ad 1:0😀", "Ad 1:00\u{FE0F}", String(repeating: "x", count: 4096), "Ad " + String(repeating: "9", count: 4096) + ":59"]
    // Deterministically generated valid Unicode scalar strings, including mixed scripts.
    let alphabet = ["A", "d", " ", ":", "0", "5", "9", "x", "é", "\u{0301}", "😀", "\u{2028}", "\u{0000}", "١"]
    var state: UInt64 = 0x4b69636b6f6666
    for index in 0..<2048 {
        var value = index % 2 == 0 ? "Ad" : ""
        for _ in 0..<(index % 24) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            value += alphabet[Int(state % UInt64(alphabet.count))]
        }
        corpus.append(value)
    }
    let rows: [[String: Any]] = corpus.map { value in
        ["utf8_base64": Data(value.utf8).base64EncodedString(), "matches": AdMarker.matches(value)]
    }
    let nodes: [[String: Any]] = workloads.map {
        ["name": $0.name, "hits_per_repetition": runBatch($0, repetitions: 1)]
    }
    let payload: [String: Any] = ["corpus": rows, "workload_outputs": nodes]
    let bytes = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return ["sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "count": corpus.count, "outputs": payload]
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "--signature":
    emit(signature())
case "--cold":
    let name = arguments[2]
    let value = name == "non_ad" ? "Play" : (name == "exact_ad" ? "Ad" : "Ad 0:30")
    // No marker call before this timestamp: regex lazy initialization is included.
    let start = DispatchTime.now().uptimeNanoseconds
    let matched = AdMarker.matches(value)
    let end = DispatchTime.now().uptimeNanoseconds
    emit(["name": name, "elapsed_ns": end - start, "matched": matched])
case "--profile":
    let workload = workloads.first { $0.name == arguments[2] }!
    let duration = UInt64(arguments.count > 3 ? arguments[3] : "15")! * 1_000_000_000
    let deadline = DispatchTime.now().uptimeNanoseconds + duration
    var hits = 0
    while DispatchTime.now().uptimeNanoseconds < deadline {
        hits &+= runBatch(workload, repetitions: workload.repetitions)
    }
    emit(["name": workload.name, "hits": hits])
case "--warm":
    let sampleCount = arguments.count > 2 ? Int(arguments[2])! : 200
    let warmups = 10
    var results: [[String: Any]] = []
    // Round-robin ordering limits drift between workload measurements.
    var samples = Array(repeating: [Double](), count: workloads.count)
    var checksums = Array(repeating: 0, count: workloads.count)
    for _ in 0..<warmups {
        for workload in workloads { _ = runBatch(workload, repetitions: workload.repetitions) }
    }
    for round in 0..<sampleCount {
        for offset in workloads.indices {
            let index = (round + offset) % workloads.count
            let workload = workloads[index]
            let start = DispatchTime.now().uptimeNanoseconds
            let hits = runBatch(workload, repetitions: workload.repetitions)
            let end = DispatchTime.now().uptimeNanoseconds
            checksums[index] &+= hits
            samples[index].append(Double(end - start) / Double(workload.repetitions * workload.callsPerRepetition))
        }
    }
    for (index, workload) in workloads.enumerated() {
        results.append(["name": workload.name, "repetitions": workload.repetitions, "calls_per_repetition": workload.callsPerRepetition, "unit": "ns/call", "samples": samples[index], "checksum": checksums[index]])
    }
    emit(["samples_per_workload": sampleCount, "warmup_batches": warmups, "workloads": results])
default:
    fputs("Usage: benchmark --warm [samples] | --cold non_ad|exact_ad|countdown | --signature | --profile workload [seconds]\n", stderr)
    exit(2)
}
