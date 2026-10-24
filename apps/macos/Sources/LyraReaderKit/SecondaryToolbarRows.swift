import AppKit
import SwiftUI

/// The Fill & Sign sub-toolbar row.
///
/// Seven items, in the order the request names them: Text, Signature, Date, Checkmark, Cross,
/// Stamp, Image. Choosing one arms it (the row button stays selected) and opens the right-hand
/// inspector for its options. The labels fall back to icons at narrow widths, exactly like the
/// primary toolbar's compact row; the help and the inspector still name every item.
struct FillSignToolRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func row(labels: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(FillSignTool.rowOrder) { tool in
                let command = state.fillSignRowCommands.first { $0.tool == tool }
                Button { state.selectFillSignTool(tool) } label: {
                    if labels {
                        Label(tool.title, systemImage: tool.icon).padding(.horizontal, 7)
                    } else {
                        Image(systemName: tool.icon)
                    }
                }
                .buttonStyle(LyraReaderToolStyle(selected: state.armedFillSignTool == tool))
                .disabled(!(command?.enabled ?? false))
                .help(command?.help ?? tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityValue(state.armedFillSignTool == tool ? "Armed" : "")
                .modifier(AnnotationToolbarItemFrame(
                    id: tool.title, width: labels ? 116 : AnnotationToolbarLayout.buttonWidth))
            }
            Button { state.clearFillSignTool() } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .disabled(state.armedFillSignTool == nil)
            .help("Clear the Fill & Sign tool")
            .accessibilityLabel("Clear Fill & Sign tool")
            .modifier(AnnotationToolbarItemFrame(id: "Clear Fill & Sign tool", width: 30))
        }
        .font(.system(size: 12))
    }
}

/// The Export sub-toolbar row.
///
/// #153 had these commands in a toolbar menu. They are now the row itself: Save, Save As, Save
/// Annotated Copy, Flattened Copy, Filled Form Copy, Form Values to Original, Export Annotations
/// and Print, in that order. The icon is a download-arrow document, not the system Share glyph
/// (`square.and.arrow.up`), which the toolbar used before and which macOS reserves for sharing.
struct ExportToolRow: View {
    @ObservedObject var state: AppState

    /// The toolbar button's glyph, shared with the row tests.
    static var icon: String { AnnotationToolbarLayout.exportIcon }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func row(labels: Bool) -> some View {
        HStack(spacing: labels ? 4 : 6) {
            ForEach(ExportCommand.all) { command in
                Button { command.perform(on: state) } label: {
                    if labels {
                        Label(command.title, systemImage: command.icon).padding(.horizontal, 7)
                    } else {
                        Image(systemName: command.icon)
                    }
                }
                .buttonStyle(LyraReaderToolStyle())
                .disabled(!command.isEnabled(state))
                .help(command.helpText(state))
                .accessibilityLabel(command.fullTitle)
                .modifier(ExportItemFrame(id: command.id, labels: labels))
            }
        }
        .font(.system(size: labels ? 11 : 12))
    }
}

/// Export items keep a fixed cell in the compact row and a reported, natural frame when the
/// labels are shown, so the order assertion works in both layouts.
private struct ExportItemFrame: ViewModifier {
    let id: String
    let labels: Bool

    func body(content: Content) -> some View {
        if labels {
            content
                .padding(.horizontal, 2)
                .background(AnnotationToolbarFrameReader(id: "export.\(id)"))
        } else {
            content
                .frame(width: AnnotationToolbarLayout.buttonWidth,
                       height: AnnotationToolbarLayout.buttonHeight)
                .background(AnnotationToolbarFrameReader(id: "export.\(id)"))
        }
    }
}

extension ReaderToolbarProbe {
    /// Frames for the Fill & Sign row at a given row width.
    public static func fillSignRowFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(
            FillSignToolRow(state: state)
                .padding(.horizontal, AnnotationToolbarLayout.horizontalPadding),
            width: width
        )
    }

    /// Frames for the Export row at a given row width.
    public static func exportRowFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(
            ExportToolRow(state: state)
                .padding(.horizontal, AnnotationToolbarLayout.horizontalPadding),
            width: width
        )
    }
}

/// One layout outcome of the primary toolbar: which labels it chose, and the Fill & Sign
/// button's frame. The checks use it to prove the label is present at a wide window and absent
/// at the minimum width, without a screenshot.
extension ReaderToolbarProbe {
    /// Hosts the real primary toolbar at `width` and reports the labels and Fill & Sign button.
    public static func toolbarFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(
            ReaderToolbar(state: state),
            width: width,
            height: 60
        )
    }
}
