import AppKit
import Foundation
import SwiftUI

@testable import LyraReaderKit

extension ReaderChecks {
  /// The content-edit path must find every annotation the reader adopted, including the ones a
  /// producer stored directly in a page's `/Annots` array, and it must never present a pending
  /// state for an edit that did not land.
  ///
  /// The sample is `pdf-samples/with_annotations/review_du_0923 (annotated).pdf`: page 1 carries
  /// two `/Highlight` dictionaries **inline** in `/Annots`. PDFium reads them, so the sidebar and
  /// adoption see them; the writer used to look only at indirect references and therefore could
  /// not resolve their identities. The test copies the sample and never writes into `pdf-samples`.
  @MainActor static func contentEditIdentityChecks(root: URL) async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lyra-content-identity-\(UUID())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let samples = ProcessInfo.processInfo.environment["LYRA_READER_PDF_SAMPLES"]
      .map { URL(fileURLWithPath: $0) }
      ?? root.appendingPathComponent("pdf-samples")
    let sample = samples.appendingPathComponent(
      "with_annotations/review_du_0923 (annotated).pdf")
    guard FileManager.default.fileExists(atPath: sample.path) else {
      print("INFO: skipping inline-annotation content edit (sample not present)")
      return
    }

    // ── The reported file: adopt its annotations, then edit its page content ────────────────
    let copy = scratch.appendingPathComponent("review_du_0923.pdf")
    try FileManager.default.copyItem(at: sample, to: copy)
    let state = AppState(engine: try RustEngine())
    state.setViewportSize(CGSize(width: 1100, height: 850))
    state.newTab(url: copy)
    try await eventually("the annotated sample opens") {
      state.document?.url == copy && !state.canvasPageFrames.isEmpty
    }
    try await eventually("the sample's annotations are read") {
      state.documentAnnotations.count >= 10 && !state.documentAnnotationsLoading
    }
    let identities = Set(state.documentAnnotations.map(\.id))
    let inlineHighlight = "nm:215E95D5-376F-444C-B18D-95099FEFC3B6"
    let secondInlineHighlight = "nm:7E0C57AF-6DB3-487E-8EF3-32F50101F6BB"
    require(
      identities.contains(inlineHighlight) && identities.contains(secondInlineHighlight),
      "PDFium reports both page-1 highlights stored inline in /Annots")
    let editable = state.documentAnnotations.filter {
      AppState.documentAnnotationEditability($0) == .editable
    }
    // The two page-1 highlights and three page-8 highlights are the editable marks. The note
    // icons and hidden entries are replies, which the editability policy refuses so a parent's
    // deletion cannot orphan an adopted entry.
    require(editable.count >= 5, "the sample offers its editable content annotations for adoption")
    for annotation in editable {
      require(
        state.adoptDocumentAnnotation(annotation.id) != nil,
        "adopting \(annotation.id) succeeds")
    }
    require(
      state.annotations.count == editable.count,
      "every editable file annotation has an adopted entry")

    state.toggleContentEditing()
    await state.reloadContentObjects()
    try await eventually("the sample's page content is editable") {
      state.contentEditPage != nil && !state.contentEditLoading
    }
    state.insertContentText(at: CGRect(x: 80, y: 300, width: 180, height: 50))
    try await eventuallyExplaining(
      "a content edit of the sample lands",
      {
        "ops=\(state.pageEditPendingOperations) inFlight=\(state.contentCommandInFlight) "
          + "error=\(state.lastError ?? "none") session=\(state.pageEditSessionActive) "
          + "summary=\(state.pageEditPendingSummary ?? "nil")"
      },
      { state.pageEditPendingOperations.count == 1 && !state.contentCommandInFlight })
    require(
      state.lastError?.contains("NotFound") != true,
      "the content edit does not fail with NotFound: \(state.lastError ?? "no error")")
    require(
      state.pageEditPendingSummary?.hasPrefix("1 page change pending") == true,
      "the successful edit presents exactly one pending page change")

    let saved = scratch.appendingPathComponent("review-edited.pdf")
    let savedOK = await state.savePageEditsCopy(to: saved)
    require(savedOK, "the edited sample saves a copy: \(state.lastError ?? "no error")")
    let reopened = AppState(engine: try RustEngine())
    reopened.newTab(url: saved)
    try await eventually("the saved sample reopens") {
      reopened.document?.url == saved && reopened.documentAnnotations.count >= identities.count
    }
    let reopenedIdentities = Set(reopened.documentAnnotations.map(\.id))
    require(
      reopenedIdentities == identities,
      "the saved file reports the same annotation identities (missing: "
        + "\(identities.subtracting(reopenedIdentities).sorted()), extra: "
        + "\(reopenedIdentities.subtracting(identities).sorted()))")

    // ── A failed first content edit stages nothing and shows no pending banner ─────────────
    let textFixture = scratch.appendingPathComponent("text-page.pdf")
    try FileManager.default.copyItem(
      at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: textFixture)
    let failing = AppState(engine: try RustEngine())
    failing.setViewportSize(CGSize(width: 1000, height: 800))
    failing.newTab(url: textFixture)
    try await eventually("the text fixture opens") {
      failing.document?.url == textFixture && !failing.canvasPageFrames.isEmpty
    }
    failing.toggleContentEditing()
    await failing.reloadContentObjects()
    try await eventually("the text fixture's page content is editable") {
      failing.contentEditPage != nil && !failing.contentEditLoading
    }
    guard let item = failing.contentEditPage?.items.first(where: { $0.can_edit_text }) else {
      fatalError("the text fixture has no editable block")
    }
    let revision = failing.contentEditPage?.revision
    failing.replaceContentText(item, text: String(repeating: "Overflow ", count: 500))
    try await eventually("the oversized draft fails in the PDF writer") {
      failing.contentTextRecovery != nil && !failing.contentCommandInFlight
    }
    require(
      failing.lastError?.contains("Content edit failed") == true,
      "the edit error is what the reader sees: \(failing.lastError ?? "no error")")
    require(
      failing.contentEditPage?.revision == revision,
      "the failed edit keeps the previous revision")
    require(
      !failing.pageEditHasPendingChanges && failing.pageEditPendingOperations.isEmpty,
      "the failed edit stages no page change")
    require(
      failing.pageEditPendingSummary == nil,
      "no zero-count \"page changes pending\" confirmation can be presented")
    require(
      !failing.pageEditSessionActive,
      "the prepared-but-empty working copy is closed instead of left pending")
    failing.discardContentTextRecovery()

    // A refused page operation follows the same rule: it prepares a session, fails, and must
    // not leave a pending state behind (this is the other path that used to show a zero count).
    let refused = await failing.applyPageEditOperation(
      .delete(pages: [0]), label: "Delete every page")
    require(!refused, "deleting the only page is refused")
    require(
      failing.pageEditPendingSummary == nil && !failing.pageEditHasPendingChanges,
      "a refused page operation presents no pending changes")
    require(
      !failing.pageEditSessionActive,
      "a refused first page operation closes the empty working copy")

    // ── A real page change still presents the true count and saves ─────────────────────────
    let rotated = await failing.applyPageEditOperation(
      .rotate(pages: [0], quarterTurns: 1), label: "Rotate page 1")
    require(rotated, "a rotation stages: \(failing.lastError ?? "no error")")
    require(
      failing.pageEditPendingSummary == "1 page change pending · the file on disk is unchanged",
      "a real pending change is presented with its true count")
    let rotatedCopy = scratch.appendingPathComponent("rotated.pdf")
    let rotatedOK = await failing.savePageEditsCopy(to: rotatedCopy)
    require(rotatedOK, "the staged rotation saves: \(failing.lastError ?? "no error")")
    require(
      failing.pageEditPendingSummary == nil && !failing.pageEditHasPendingChanges,
      "a successful save ends the pending state instead of leaving a zero-count confirmation")
  }
}
