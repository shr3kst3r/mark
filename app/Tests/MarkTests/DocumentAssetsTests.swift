import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// Serving a document's own pictures.
///
/// The bug these pin: `![alt](assets/x.png)` resolved against
/// `mark-asset://shell/`, whose handler serves three bundle files and 404s
/// everything else — so every local image in every document was a broken-image
/// icon, while the shipped markdown reference told the reader that "paths are
/// resolved relative to the document".
///
/// Half of these are refusals, deliberately. The allowlist is the security
/// boundary: `pulldown-cmark` passes a document's raw HTML straight through, so
/// script in the page is not necessarily ours, and "which paths will this
/// handler read off disk" is the question that has to have a small, testable
/// answer.
@Suite("Document images")
@MainActor
struct DocumentAssetsTests {

    /// A web view is only ever used here as a key into the handler's per-view
    /// allowlists, so a bare one on the shared configuration is enough — no
    /// page is loaded and nothing is rendered.
    private func makeWebView() -> WKWebView {
        WKWebView(frame: .zero, configuration: WebViewFactory.configuration)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    // ---- the base URL ----------------------------------------------------

    @Test("the base URL is the document's directory, with a trailing slash")
    func baseIsADirectory() throws {
        let base = try #require(
            DocumentAssetSchemeHandler.base(forDocumentAt: URL(fileURLWithPath: "/notes/a.md")))
        #expect(base.scheme == DocumentAssetSchemeHandler.scheme)
        #expect(base.absoluteString == "mark-doc:///notes/")
        // Without the trailing slash, `x.png` resolves beside the directory
        // rather than inside it.
        #expect(base.absoluteString.hasSuffix("/"))
    }

    @Test("a relative source resolves inside the document's directory")
    func relativeSourcesResolve() throws {
        let base = try #require(
            DocumentAssetSchemeHandler.base(
                forDocumentAt: URL(fileURLWithPath: "/notes/2026/08/day.md")))
        #expect(
            URL(string: "assets/x.png", relativeTo: base)?.absoluteURL.path
                == "/notes/2026/08/assets/x.png")
        // The case a path check would have had to special-case, and the reason
        // the allowlist is computed rather than derived from a directory.
        #expect(
            URL(string: "../../pics/y.png", relativeTo: base)?.absoluteURL.path
                == "/notes/pics/y.png")
    }

    @Test("a name with a space survives the round trip through the URL")
    func spacesSurvive() throws {
        let directory = try temporaryDirectory()
        let image = directory.appendingPathComponent("my pic.png")
        try Data([0x89, 0x50]).write(to: image)

        let handler = DocumentAssetSchemeHandler()
        let view = makeWebView()
        handler.allow([image.path], for: view)

        let base = try #require(
            DocumentAssetSchemeHandler.base(
                forDocumentAt: directory.appendingPathComponent("notes.md")))
        // `%20` on the way out, a space on the way back in — which is what the
        // handler compares against the allowlist.
        let requested = try #require(URL(string: "my%20pic.png", relativeTo: base)?.absoluteURL)
        let (data, _) = try handler.resolve(requested, for: view)
        #expect(data.count == 2)
    }

    // ---- what is served, and what is refused ------------------------------

    @Test("an allowed image is served with an image MIME type")
    func servesAnAllowedImage() throws {
        let directory = try temporaryDirectory()
        let image = directory.appendingPathComponent("x.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        let handler = DocumentAssetSchemeHandler()
        let view = makeWebView()
        handler.allow([image.path], for: view)

        let (data, mime) = try handler.resolve(
            URL(string: "mark-doc://\(image.path)"), for: view)
        #expect(data.count == 4)
        #expect(mime == "image/png")
    }

    @Test("a path the document does not reference is refused")
    func refusesAnUnreferencedPath() throws {
        let directory = try temporaryDirectory()
        let referenced = directory.appendingPathComponent("x.png")
        let secret = directory.appendingPathComponent("private.png")
        try Data([0x89]).write(to: referenced)
        try Data([0x89]).write(to: secret)

        let handler = DocumentAssetSchemeHandler()
        let view = makeWebView()
        handler.allow([referenced.path], for: view)

        // Both files exist and both are images. The only thing separating them
        // is that the document names one of them.
        #expect(throws: DocumentAssetSchemeHandler.AssetError.self) {
            _ = try handler.resolve(URL(string: "mark-doc://\(secret.path)"), for: view)
        }
    }

    @Test("a non-image is refused even when it is on the allowlist")
    func refusesANonImage() throws {
        let directory = try temporaryDirectory()
        let text = directory.appendingPathComponent("secrets.txt")
        try Data("hunter2".utf8).write(to: text)

        let handler = DocumentAssetSchemeHandler()
        let view = makeWebView()
        // Belt and braces: the allowlist is built from image references, so
        // this should be unreachable. It is asserted anyway, because the
        // extension check is the part that stays true if the allowlist is ever
        // built from something looser.
        handler.allow([text.path], for: view)

        #expect(throws: DocumentAssetSchemeHandler.AssetError.self) {
            _ = try handler.resolve(URL(string: "mark-doc://\(text.path)"), for: view)
        }
    }

    @Test("a web view showing no document may load nothing")
    func refusesWithNoDocument() throws {
        let handler = DocumentAssetSchemeHandler()
        #expect(throws: DocumentAssetSchemeHandler.AssetError.self) {
            _ = try handler.resolve(URL(string: "mark-doc:///etc/hosts"), for: makeWebView())
        }
    }

    @Test("a directory is not a picture")
    func refusesADirectory() throws {
        let directory = try temporaryDirectory()
        let inner = directory.appendingPathComponent("pics.png", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let handler = DocumentAssetSchemeHandler()
        let view = makeWebView()
        handler.allow([inner.path], for: view)

        #expect(throws: DocumentAssetSchemeHandler.AssetError.self) {
            _ = try handler.resolve(URL(string: "mark-doc://\(inner.path)"), for: view)
        }
    }

    @Test("forgetting a web view revokes what it could load")
    func forgettingRevokes() throws {
        let directory = try temporaryDirectory()
        let image = directory.appendingPathComponent("x.png")
        try Data([0x89]).write(to: image)

        let handler = DocumentAssetSchemeHandler()
        let view = makeWebView()
        handler.allow([image.path], for: view)
        #expect(handler.allowedPaths(for: view).count == 1)

        handler.forget(view)
        #expect(handler.allowedPaths(for: view).isEmpty)
        #expect(throws: DocumentAssetSchemeHandler.AssetError.self) {
            _ = try handler.resolve(URL(string: "mark-doc://\(image.path)"), for: view)
        }
    }

    @Test("two web views do not share an allowlist")
    func allowlistsArePerWebView() throws {
        let directory = try temporaryDirectory()
        let mine = directory.appendingPathComponent("mine.png")
        try Data([0x89]).write(to: mine)

        let handler = DocumentAssetSchemeHandler()
        let ours = makeWebView()
        let theirs = makeWebView()
        handler.allow([mine.path], for: ours)
        handler.allow([], for: theirs)

        #expect(throws: DocumentAssetSchemeHandler.AssetError.self) {
            _ = try handler.resolve(URL(string: "mark-doc://\(mine.path)"), for: theirs)
        }
        #expect(throws: Never.self) {
            _ = try handler.resolve(URL(string: "mark-doc://\(mine.path)"), for: ours)
        }
    }

    // ---- the whole path, in a real web view -------------------------------

    /// A 1×1 PNG. Real bytes, because the assertion is `naturalWidth`, which
    /// WebKit only reports for an image it actually decoded — the point of the
    /// test is that the picture arrived, not that a request was made.
    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQ"
            + "GAhKmMIQAAAABJRU5ErkJggg==")!

    /// How wide the page thinks the first `<img>` is. Zero for a broken image,
    /// which is exactly what this used to be for every document.
    private func naturalWidth(in tab: DocumentTab) async throws -> Int {
        let view = try #require(tab.documentView)
        let width = try await view.call(
            """
            var img = document.querySelector('#mk-doc img');
            if (!img) return -1;
            if (img.complete) return img.naturalWidth;
            return await new Promise(function (resolve) {
              img.addEventListener('load', function () { resolve(img.naturalWidth); });
              img.addEventListener('error', function () { resolve(0); });
              setTimeout(function () { resolve(img.naturalWidth); }, 2000);
            });
            """)
        return (width as? Int) ?? Int((width as? Double) ?? -1)
    }

    @Test("a local image in a document actually loads")
    func aLocalImageLoads() async throws {
        let harness = try RoundTripHarness()
        try Self.onePixelPNG.write(
            to: harness.fixture.directory.appendingPathComponent("pic.png"))

        let tab = try await harness.open("# Notes\n\n![a picture](pic.png)\n", named: "notes.md")
        let width = try await naturalWidth(in: tab)
        #expect(width == 1, "the image did not load; naturalWidth was \(width)")
    }

    @Test("an image beside the document, reached through a parent segment, loads")
    func anImageUpAndOverLoads() async throws {
        let harness = try RoundTripHarness()
        let assets = harness.fixture.directory.appendingPathComponent("assets")
        let notes = harness.fixture.directory.appendingPathComponent("notes")
        for directory in [assets, notes] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try Self.onePixelPNG.write(to: assets.appendingPathComponent("pic.png"))

        // The layout a path check would have refused, and the reason the
        // allowlist is computed instead.
        let tab = try await harness.open(
            "# Notes\n\n![a picture](../assets/pic.png)\n", named: "notes/day.md")
        let width = try await naturalWidth(in: tab)
        #expect(width == 1, "the image did not load; naturalWidth was \(width)")
    }

    @Test("an image added by an edit loads without reopening the document")
    func anImageAddedByAnEditLoads() async throws {
        let harness = try RoundTripHarness()
        try Self.onePixelPNG.write(
            to: harness.fixture.directory.appendingPathComponent("pic.png"))

        let tab = try await harness.open("# Notes\n\nnothing yet\n", named: "notes.md")
        #expect(try await naturalWidth(in: tab) == -1, "no image yet")

        // The patch path, not the open path: the allowlist has to be refreshed
        // before the inserted block reaches the DOM.
        _ = await tab.documentView?.apply(source: "# Notes\n\n![a picture](pic.png)\n")
        let width = try await naturalWidth(in: tab)
        #expect(width == 1, "the image did not load after the edit; got \(width)")
    }

    // ---- the core's half of the allowlist ---------------------------------

    @Test("the allowlist comes from the images the document names")
    func theCoreNamesTheImages() throws {
        let directory = try temporaryDirectory()
        try Data([0x89]).write(to: directory.appendingPathComponent("there.png"))

        let images = try MarkCore.links(
            source: """
                # Notes

                ![here](there.png)
                ![gone](missing.png)
                [not an image](other.md)
                """,
            base: directory.path,
            images: true)

        #expect(images.count == 2, "links are not images")
        #expect(images[0].exists == true)
        #expect(images[0].path == directory.appendingPathComponent("there.png").path)
        #expect(images[1].exists == false)
    }
}
