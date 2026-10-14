import ArisReaderKit
import Foundation

extension ReaderChecks {
    @MainActor static func annotationChecks(a: URL, b: URL) async throws {
        let sidecar = a.appendingPathExtension("aris-annotations.json")
        let annotation = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            colorIndex: 0, note: "old", createdAt: Date())
        let encoder = JSONEncoder()
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(annotation)) as! [String: Any]
        legacy.removeValue(forKey: "kind")
        try JSONSerialization.data(withJSONObject: [legacy]).write(to: sidecar)
        let state = AppState(engine: try RustEngine())
        state.open(url: a)
        require(state.annotations.first?.kind == .highlight, "legacy sidecar defaults to highlight")
        state.updateNote("n", for: annotation.id)
        state.updateNote("new", for: annotation.id)
        require(state.undoStack.count == 1, "note typing coalesces undo")
        state.undo()
        require(state.annotations.first?.note == "old", "note undo restores original")
        state.redo()
        let disk = try JSONDecoder().decode([AppState.Annotation].self, from: Data(contentsOf: sidecar))
        require(disk.first?.note == "new", "note redo persists to disk")
        state.jump(to: annotation)
        require(state.addAnnotationFromSelection(kind: .underline), "underline persists")
        state.undo()
        require(state.annotations.count == 1, "undo removes new annotation")
        state.redo()
        require(state.annotations.count == 2, "redo restores new annotation")
        let id = state.annotations.last!.id
        state.removeAnnotation(id)
        state.undo()
        require(state.annotations.contains(where: { $0.id == id }), "delete is undoable")
        state.open(url: b)
        require(state.annotations.isEmpty && !state.canUndo, "annotation state never crosses documents")
        state.open(url: a)
        require(state.annotations.count == 2, "ordinary reopen restores annotations")
        // A directory at the target path deterministically makes atomic persistence fail.
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        let before = state.annotations
        state.updateNote("must not publish", for: annotation.id)
        require(state.annotations == before && state.lastError != nil, "failed save preserves state and reports error")
        try FileManager.default.removeItem(at: sidecar)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: sidecar)
        state.open(url: a)
        state.jump(to: annotation)
        require(!state.addHighlightFromSelection(), "corrupt sidecar blocks writes")
        let preserved = try Data(contentsOf: sidecar)
        require(preserved == corrupt, "corrupt bytes remain untouched")
        try FileManager.default.removeItem(at: sidecar)
        state.open(url: a)
        state.jump(to: annotation)
        require(state.addHighlightFromSelection(), "missing sidecar is created on first annotation")
    }
}
