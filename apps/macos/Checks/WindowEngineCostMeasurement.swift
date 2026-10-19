import LyraReaderKit
import Darwin
import Foundation

extension ReaderChecks {
    /// Opt-in measurement, never part of the regression run: **what a second window's engine
    /// costs**, now that each window builds its own (`ReaderSession`).
    ///
    /// Usage: LyraReaderChecks --measure-window-engine-cost PAPER.pdf [OTHER.pdf]
    ///
    /// The question this answers is the one the multi-window change turns into a design decision:
    /// the app's memory floor (~330 MiB, ADR 0007: PDFium + wgpu/Metal + AppKit + window surfaces)
    /// is paid by the *process*, so a second engine must not be assumed to buy a second copy of it.
    /// The numbers below are the resident footprint (`phys_footprint`, what Activity Monitor shows)
    /// after each step, taken in-process so each step can be attributed:
    ///
    /// 1. after PDFium is loaded and one document is open (the app's first window);
    /// 2. after a second `RustEngine` opens the **same** document — the marginal cost of a second
    ///    window on the same paper, where the per-document caches and the tile pyramid are the only
    ///    thing that could be shared;
    /// 3. after a third engine opens a **different** document.
    ///
    /// It measures the CPU side only (no GPU device, no window surface), which is exactly the part
    /// that a per-window engine could duplicate. Run it on a real paper: a 1-page fixture has no
    /// reference index, no caption index and a much smaller layout than a paper does.
    @MainActor static func measureWindowEngineCost() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            throw NSError(domain: "WindowEngineCost", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected at least one PDF path"])
        }
        let firstURL = URL(fileURLWithPath: args[2])
        let secondURL = args.count > 3 ? URL(fileURLWithPath: args[3]) : firstURL

        let start = footprintBytes()
        var steps: [[String: Any]] = []

        // 1. The first window: PDFium's library mapping plus one open document.
        let first = try RustEngine()
        let firstDocument = try first.openDocument(at: firstURL)
        let afterFirst = footprintBytes()
        steps.append([
            "step": "one engine + first document",
            "document": firstURL.lastPathComponent,
            "pages": firstDocument.pageCount,
            "footprint_bytes": afterFirst,
            "delta_bytes": afterFirst - start,
        ])

        // 2. A second engine on the same document: everything PDFium itself already paid for is
        //    shared (its library is a `OnceLock`), so this delta is per-document state.
        let second = try RustEngine()
        let secondDocument = try second.openDocument(at: firstURL)
        let afterSecond = footprintBytes()
        steps.append([
            "step": "second engine + same document",
            "document": firstURL.lastPathComponent,
            "pages": secondDocument.pageCount,
            "footprint_bytes": afterSecond,
            "delta_bytes": afterSecond - afterFirst,
        ])

        // 3. A third engine on another document, for contrast (a different file has its own layout,
        //    reference list and caption index; the same file would share them if it could).
        let third = try RustEngine()
        let thirdDocument = try third.openDocument(at: secondURL)
        let afterThird = footprintBytes()
        steps.append([
            "step": secondURL == firstURL ? "third engine + same document again"
                                          : "third engine + a different document",
            "document": secondURL.lastPathComponent,
            "pages": thirdDocument.pageCount,
            "footprint_bytes": afterThird,
            "delta_bytes": afterThird - afterSecond,
        ])

        // 4. Two whole windows' worth of AppState (the tile cache, the text layers, the selection
        //    machinery): what a second window costs *besides* its engine.
        let stateA = AppState(engine: try RustEngine())
        stateA.open(url: firstURL)
        stateA.setViewportSize(CGSize(width: 959, height: 715))
        let afterStateA = footprintBytes()
        let stateB = AppState(engine: try RustEngine())
        stateB.open(url: firstURL)
        stateB.setViewportSize(CGSize(width: 959, height: 715))
        let afterStateB = footprintBytes()
        steps.append([
            "step": "second AppState (window) + engine, same document, before any raster",
            "document": firstURL.lastPathComponent,
            "pages": stateB.document?.pageCount ?? 0,
            "footprint_bytes": afterStateB,
            "delta_bytes": afterStateB - afterStateA,
        ])

        let result: [String: Any] = [
            "start_footprint_bytes": start,
            "steps": steps,
            "scope": "CPU footprint (phys_footprint); excludes the GPU device and window surfaces, "
                + "which are process-wide (ADR 0007: ~330 MiB floor)",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }

    /// The process's physical footprint, in bytes (`TASK_VM_INFO`), or 0 if the kernel refuses.
    @MainActor private static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
