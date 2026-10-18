import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

public struct RecentDocument: Codable, Identifiable, Equatable {
    public let id: String
    public let url: URL
    public var openedAt: Date?
    public var title: String { url.deletingPathExtension().lastPathComponent }
}

/// Reads only our cached covers while displaying history. A protected source PDF is opened
/// solely after an explicit user click, never to decorate the Home/Recents screen.
@MainActor public final class RecentDocumentStore: ObservableObject {
    public static let shared = RecentDocumentStore()
    @Published public private(set) var entries: [RecentDocument] = []
    @Published private var covers: [String: NSImage] = [:]
    private let defaults: UserDefaults
    private let cacheDirectory: URL
    private let systemDocuments: NSDocumentController?
    private static let key = "lyra.recentDocuments"

    public init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil,
                systemDocuments: NSDocumentController? = .shared) {
        self.defaults = defaults
        self.systemDocuments = systemDocuments
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyra/RecentCovers", isDirectory: true)
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([RecentDocument].self, from: data) {
            entries = Array(saved.filter { $0.url.isFileURL && $0.id == Self.identity($0.url) }
                .sorted { ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast) }.prefix(100))
        } else {
            entries = (systemDocuments?.recentDocumentURLs ?? []).prefix(100).map { url in
                // The system supplies order, not last-open dates; do not read protected files
                // or invent dates just to fill the card's secondary line.
                RecentDocument(id: Self.identity(url), url: url, openedAt: nil)
            }
        }
        for entry in entries {
            if let image = NSImage(contentsOf: self.cacheDirectory.appendingPathComponent(entry.id + ".png")) {
                covers[entry.id] = image
            }
        }
    }

    public func record(_ url: URL, at date: Date = Date()) {
        guard url.isFileURL else { return }
        let url = url.standardizedFileURL
        let id = Self.identity(url)
        entries.removeAll { $0.id == id }
        entries.insert(RecentDocument(id: id, url: url, openedAt: date), at: 0)
        entries = Array(entries.prefix(100))
        persist()
        systemDocuments?.noteNewRecentDocumentURL(url)
    }

    public func clear() {
        entries = []
        persist()
        systemDocuments?.clearRecentDocuments(nil)
    }

    func cover(for entry: RecentDocument) -> NSImage? { covers[entry.id] }

    /// The bitmap already belongs to the open document: this does not read its source path.
    func saveCover(_ page: PageImage, for url: URL) {
        guard page.pixelWidth > 0, page.pixelHeight > 0,
              let provider = CGDataProvider(data: page.bgra as CFData),
              let image = CGImage(width: page.pixelWidth, height: page.pixelHeight,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: page.pixelWidth * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                    .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let id = Self.identity(url.standardizedFileURL)
        covers[id] = NSImage(cgImage: image, size: page.pointSize)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheDirectory.appendingPathComponent(id + ".png"), options: .atomic)
    }

    private func persist() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) } }
    private static func identity(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReaderHomeView: View {
    @ObservedObject var state: AppState
    let opener: DocumentOpenCoordinator
    @ObservedObject private var recents = RecentDocumentStore.shared
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    @State private var showAll = false
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if showAll {
                    Button { showAll = false } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(LyraToolStyle()).accessibilityLabel("Back to Open File")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 44, weight: .light))
                            .foregroundStyle(LyraTheme.accent)
                        Text("Open a PDF").font(.system(size: 25, weight: .semibold))
                        Text("Drop files here to start reading").foregroundStyle(LyraTheme.textSecondary)
                        Button { state.showFileImporter = true } label: {
                            Label("Open Files…", systemImage: "folder").padding(.horizontal, 18).padding(.vertical, 7)
                        }.buttonStyle(.borderedProminent).tint(LyraTheme.accent)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                    .background(dropTargeted ? LyraTheme.selectedBg : LyraTheme.panelBg,
                                in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
                        dropTargeted ? LyraTheme.accentBorder : LyraTheme.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                        for provider in providers {
                            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                                Task { @MainActor in _ = opener.openDocuments([url]) }
                            }
                        }
                        return !providers.isEmpty
                    }
                }

                HStack {
                    Text("Recents").font(.system(size: showAll ? 28 : 22, weight: .semibold))
                    Spacer()
                    Button("Clear") { recents.clear() }.disabled(recents.entries.isEmpty)
                        .buttonStyle(LyraToolStyle()).help("Clear recent history; keep the original files")
                    if !showAll {
                        Button("View All") { showAll = true }.buttonStyle(LyraToolStyle())
                    }
                }
                if recents.entries.isEmpty {
                    Text("Your recently opened PDFs will appear here.")
                        .foregroundStyle(LyraTheme.textSecondary).padding(.vertical, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 22)],
                              alignment: .leading, spacing: 26) {
                        ForEach(showAll ? recents.entries : Array(recents.entries.prefix(5))) { entry in
                            Button { _ = opener.openDocuments([entry.url]) } label: {
                                VStack(spacing: 9) {
                                    ZStack {
                                        if let image = recents.cover(for: entry) {
                                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                                .modifier(PaperImageAppearance(mode: appearance.mode))
                                        } else {
                                            RoundedRectangle(cornerRadius: 4).fill(LyraTheme.raisedBg)
                                            Image(systemName: "doc.text").font(.system(size: 40, weight: .light))
                                                .foregroundStyle(LyraTheme.textTertiary)
                                        }
                                    }
                                    .frame(width: 140, height: 188)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                                    Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        .frame(height: 34, alignment: .top)
                                    Text(entry.openedAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
                                         ?? "Recently opened")
                                        .font(.caption).foregroundStyle(LyraTheme.textTertiary)
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain).help(entry.url.lastPathComponent)
                            .accessibilityLabel("Open recent PDF: \(entry.title)")
                        }
                    }
                }
            }
            .frame(maxWidth: 1060, alignment: .leading).padding(36)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(LyraTheme.emptyBg).foregroundStyle(LyraTheme.textPrimary)
    }
}
