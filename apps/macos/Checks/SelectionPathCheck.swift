import LyraReaderKit
import Foundation

extension ReaderChecks {
    /// A private/local PDF need not become a repository fixture to verify its hit path.
    /// Usage: --check-selection-path PDF page-index x start-y end-y minimum-index maximum-index step-y
    @MainActor static func checkSelectionPath() async throws {
        let args = CommandLine.arguments
        guard args.count == 10, let page = Int(args[3]), let x = Double(args[4]),
              let start = Double(args[5]), let end = Double(args[6]),
              x.isFinite, start.isFinite, end.isFinite, end >= start,
              let minimum = Int(args[7]), let maximum = Int(args[8]),
              let step = Double(args[9]), step.isFinite, step > 0, minimum <= maximum else {
            throw NSError(domain: "SelectionPath", code: 1)
        }
        let engine = try RustEngine()
        _ = try engine.openDocument(at: URL(fileURLWithPath: args[2]))
        let text = try await engine.textPage(page)
        var count = 0
        var previous = minimum
        for y in stride(from: start, through: end, by: step) {
            guard let hit = text.characterIndex(at: CGPoint(x: x, y: y), extendingSelection: true),
                  (minimum...maximum).contains(hit), hit >= previous else {
                throw NSError(domain: "SelectionPath", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Selection path escaped/regressed at y=\(y)"])
            }
            previous = hit
            count += 1
        }
        print("PASS: \(count) real-PDF drag endpoints remain in order and inside the expected body-text range")
    }
}
