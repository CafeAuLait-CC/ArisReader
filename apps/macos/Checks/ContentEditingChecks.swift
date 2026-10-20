import AppKit
import Foundation
import PDFKit
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func contentEditingChecks(root: URL) async throws {
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("lyra-content-native-\(UUID())")
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:scratch)}
        let source=scratch.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at:root.appendingPathComponent("tests/fixtures/text-page.pdf"),to:source)
        let original=try Data(contentsOf:source)
        let state=AppState(engine:try RustEngine())
        state.setViewportSize(CGSize(width:1000,height:800));state.newTab(url:source)
        try await eventually("content fixture opens and lays out") {state.document?.url == source && !state.canvasPageFrames.isEmpty}
        state.toggleContentEditing();await state.reloadContentObjects()
        guard let first=state.contentEditPage?.items.first(where:{$0.can_edit_text}) else{fatalError("No editable fixture text")}
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        let view=ContentEditorView(frame:CGRect(x:0,y:0,width:1000,height:800));view.state=state;window.contentView=view
        defer {window.contentView=nil;window.orderOut(nil)}
        func point(_ item:PDFContentItem)->CGPoint {
            let placement=state.canvasPageFrames.first{$0.index==0}!
            let z=state.zoomFactor;let offset=max(0,(view.bounds.width-state.contentWidthPt*z)/2)
            return CGPoint(x:offset+(placement.leftPt+item.bounds.x+item.bounds.width/2)*z,y:(placement.topPt+item.bounds.y+item.bounds.height/2-state.scrollYPt)*z)
        }
        func event(_ type:NSEvent.EventType,_ point:CGPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        let p=point(first)
        view.mouseMoved(with:event(.mouseMoved,p))
        require(view.hoveredContentID==first.id,"Edit hover identifies the complete text block")
        view.mouseDown(with:event(.leftMouseDown,p));view.mouseUp(with:event(.leftMouseUp,p))
        require(state.contentEditSelection==first.id,"first click selects a block without opening the text editor")
        require(view.subviews.compactMap{$0 as? NSTextView}.isEmpty,"selection and caret editing are distinct states")
        let moved=CGPoint(x:p.x+20*state.zoomFactor,y:p.y+12*state.zoomFactor)
        view.mouseDown(with:event(.leftMouseDown,p));view.mouseDragged(with:event(.leftMouseDragged,moved));view.mouseUp(with:event(.leftMouseUp,moved))
        try await eventually("drag stages and reopens a content revision") {state.pageEditPendingOperations.count==1 && !state.contentEditLoading && !state.pageEditBusy}
        guard let block=state.contentEditPage?.items.first(where:{$0.text==first.text}) else{fatalError("Moved text missing: \(state.lastError ?? "")")}
        require(abs(block.bounds.x-first.bounds.x-20)<0.5,"drag uses page points at the current zoom")
        let q=point(block)
        view.mouseDown(with:event(.leftMouseDown,q));view.mouseUp(with:event(.leftMouseUp,q))
        view.mouseDown(with:event(.leftMouseDown,q));view.mouseUp(with:event(.leftMouseUp,q))
        guard let editor=view.subviews.compactMap({$0 as? NSTextView}).first else{fatalError("Second click must open a native caret editor")}
        require(editor.selectedRange().length==0,"second click places a caret instead of selecting all text")
        editor.string="Edited"
        view.mouseDown(with:event(.leftMouseDown,CGPoint(x:5,y:5)))
        try await eventually("typing changes actual page content in a new revision") {state.pageEditPendingOperations.count==2 && !state.contentEditLoading && !state.pageEditBusy}
        require(state.contentEditPage?.items.contains(where:{$0.text=="Edited"}) == true,"modified words survive reopening")
        state.undo()
        try await eventually("content undo restores the moved text revision") {state.pageEditPendingOperations.count==1 && !state.pageEditBusy}
        await state.reloadContentObjects()
        require(state.contentEditPage?.items.contains(where:{$0.text==first.text}) == true,"undo restores original words")
        state.redo()
        try await eventually("content redo restores the edited revision") {state.pageEditPendingOperations.count==2 && !state.pageEditBusy}
        await state.reloadContentObjects()
        guard let edited=state.contentEditPage?.items.first(where:{$0.text=="Edited"}) else{fatalError("Edited block missing")}
        let r=point(edited)
        view.mouseDown(with:event(.leftMouseDown,r));view.mouseUp(with:event(.leftMouseUp,r))
        view.mouseDown(with:event(.leftMouseDown,r));view.mouseUp(with:event(.leftMouseUp,r))
        guard let draft=view.subviews.compactMap({$0 as? NSTextView}).first else{fatalError("Draft editor missing")}
        draft.string="Save"
        let saved=scratch.appendingPathComponent("published.pdf")
        let published=await state.savePageEditsCopy(to:saved)
        require(published,"content working revision publishes through the verified page-edit save: \(state.lastError ?? "")")
        require(PDFDocument(url:saved)?.string?.contains("Save") == true,"Save commits an active caret draft before PDFKit reopens the modified body text")
        let preserved=try Data(contentsOf:source)
        require(preserved==original,"content editing and copy export preserve the source bytes")
        state.contentEditEnabled=false
        let signed=scratch.appendingPathComponent("signed.pdf")
        try FileManager.default.copyItem(at:root.appendingPathComponent("tests/fixtures/signed-signature.pdf"),to:signed)
        state.newTab(url:signed)
        require(state.isReadOnlyDocument && !state.canReplaceOriginalWithPageEdits,"signed original remains protected from content replacement")
        print("Content editing native checks passed")
    }
}
