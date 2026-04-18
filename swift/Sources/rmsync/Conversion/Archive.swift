import Foundation

/// Pack and unpack ``.rmdoc`` archives. Port of
/// ``src/rm_sync/conversion/archive.py``.
///
/// A .rmdoc is a zip with this layout:
///
///     <doc_id>.metadata            JSON: visibleName, parent, type, lastModified, version
///     <doc_id>.content             JSON: pages[], fileType, pageCount, ...
///     <doc_id>/<page_id>.rm        v6 scene data
///     <doc_id>/<page_id>-metadata.json    {"layers":[{"name":"Layer 1"}]}
///
/// Two shapes of ``.content`` JSON exist in the wild:
///   - Legacy: ``{"pages": ["<page-id>", ...]}``
///   - sync15: ``{"cPages": {"pages": [{"id": "<page-id>", ...}, ...]}}``
///
/// Cloud-downloaded archives use the sync15 shape. Rmapi accepts both on
/// upload, but the tablet prepends a blank template page if we upload
/// legacy-shaped content, so the push side in Week 5 always writes
/// sync15. (See CHANGES_FROM_SPEC.md for the full discovery story.)
///
/// Rather than pull in a zip dependency we shell out to ``/usr/bin/unzip``
/// and ``/usr/bin/zip``. Both are macOS stock; adding ZipFoundation or
/// similar just for this would be a ~80 KB dep for functionality we get
/// for free.
enum Archive {
    struct RmDocPage: Sendable, Equatable {
        var pageID: String
        var rmBytes: Data
        var layerName: String = "Layer 1"
    }

    struct RmDoc: Sendable {
        var docID: String
        var visibleName: String
        var parent: String = ""
        var pages: [RmDocPage] = []
        var version: Int = 1
        var lastModified: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    }

    enum UnpackError: Error, Sendable {
        case unzipFailed(String)
        case missingMetadata
        case unreadableMetadata
    }

    static func unpack(_ archivePath: URL) async throws -> RmDoc {
        // Extract to a fresh tempdir and then read the files. unzip -p
        // (stream one file) would save the temp hop but complicates the
        // multi-file-per-page iteration; the cost is one tempdir per pull.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-unpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await Subprocess.run(
            executablePath: "/usr/bin/unzip",
            args: ["-qq", "-o", archivePath.path, "-d", tmp.path]
        )
        guard result.exitCode == 0 else {
            throw UnpackError.unzipFailed(result.stderr)
        }

        // Discover doc_id from the sole .metadata file at the archive root.
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        guard let metaName = contents.first(where: { $0.hasSuffix(".metadata") }) else {
            throw UnpackError.missingMetadata
        }
        let docID = String(metaName.dropLast(".metadata".count))

        let metaURL = tmp.appendingPathComponent(metaName)
        guard let metaData = try? Data(contentsOf: metaURL),
              let metaJSON = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        else { throw UnpackError.unreadableMetadata }

        let contentURL = tmp.appendingPathComponent("\(docID).content")
        let contentJSON = (try? Data(contentsOf: contentURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let pageIDs = extractPageIDs(from: contentJSON)

        var pages: [RmDocPage] = []
        for pageID in pageIDs {
            let pageBytesURL = tmp.appendingPathComponent("\(docID)/\(pageID).rm")
            guard let rmBytes = try? Data(contentsOf: pageBytesURL) else {
                // Sync15 archives may omit pages that haven't been opened
                // on the tablet yet; skip silently.
                continue
            }
            var layerName = "Layer 1"
            let layerMetaURL = tmp.appendingPathComponent("\(docID)/\(pageID)-metadata.json")
            if let data = try? Data(contentsOf: layerMetaURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let layers = json["layers"] as? [[String: Any]],
               let name = layers.first?["name"] as? String {
                layerName = name
            }
            pages.append(RmDocPage(pageID: pageID, rmBytes: rmBytes, layerName: layerName))
        }

        let docVersion = (metaJSON["version"] as? Int) ?? 1
        let lastModified: Int64 = {
            if let ms = metaJSON["lastModified"] as? Int64 { return ms }
            if let s = metaJSON["lastModified"] as? String, let ms = Int64(s) { return ms }
            return Int64(Date().timeIntervalSince1970 * 1000)
        }()

        return RmDoc(
            docID: docID,
            visibleName: (metaJSON["visibleName"] as? String) ?? "Untitled",
            parent: (metaJSON["parent"] as? String) ?? "",
            pages: pages,
            version: docVersion,
            lastModified: lastModified
        )
    }

    // MARK: - pack

    enum PackError: Error, Sendable {
        case zipFailed(String)
        case jsonFailed(String)
    }

    /// Serialize an ``RmDoc`` to a ``.rmdoc`` archive on disk. Returns
    /// ``outPath``.
    ///
    /// The shape we write mirrors what the tablet expects under sync15.
    /// Three invariants (discovered the hard way in the Python port — see
    /// CHANGES_FROM_SPEC.md) are baked in here:
    ///
    ///   1. ``cPages`` format with ``idx`` fractional indices. The legacy
    ///      flat ``pages: [id, ...]`` triggers the tablet to prepend a
    ///      blank template page.
    ///   2. ``coverPageNumber: -1``. Any other value renders an extra
    ///      cover thumbnail page.
    ///   3. Stable ``pageID`` list supplied by the caller (the worker).
    ///      Generating fresh IDs per push accumulates ghost cPages entries.
    static func pack(_ doc: RmDoc, to outPath: URL) async throws -> URL {
        // Build the two JSON blobs + page files under a fresh tempdir,
        // then invoke /usr/bin/zip.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmsync-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let metadata = metadataJSON(for: doc)
        let content = contentJSON(for: doc)

        let metadataData = try serialize(metadata)
        let contentData = try serialize(content)
        try metadataData.write(to: staging.appendingPathComponent("\(doc.docID).metadata"))
        try contentData.write(to: staging.appendingPathComponent("\(doc.docID).content"))

        let pageDir = staging.appendingPathComponent(doc.docID, isDirectory: true)
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        for page in doc.pages {
            try page.rmBytes.write(to: pageDir.appendingPathComponent("\(page.pageID).rm"))
            let layerMeta: [String: Any] = [
                "layers": [["name": page.layerName]],
            ]
            let layerData = try serialize(layerMeta)
            try layerData.write(to: pageDir.appendingPathComponent("\(page.pageID)-metadata.json"))
        }

        // Rmapi expects the archive entries to be flat ``<docID>.metadata``
        // / ``<docID>/page.rm`` — mirroring what we staged. Invoke zip in
        // the staging dir so paths come out without any leading
        // ``rmsync-pack-UUID/`` prefix.
        try FileManager.default.createDirectory(
            at: outPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outPath)

        let zipResult = try await Subprocess.run(
            executablePath: "/usr/bin/zip",
            args: ["-qr", outPath.path, "."],
            cwd: staging
        )
        guard zipResult.exitCode == 0 else {
            throw PackError.zipFailed(zipResult.stderr)
        }
        return outPath
    }

    // MARK: - helpers

    static func newPageID() -> String { UUID().uuidString.lowercased() }

    private static func extractPageIDs(from content: [String: Any]) -> [String] {
        if let flat = content["pages"] as? [String] { return flat }
        if let cpages = content["cPages"] as? [String: Any],
           let entries = cpages["pages"] as? [[String: Any]] {
            return entries.compactMap { $0["id"] as? String }
        }
        return []
    }

    private static func metadataJSON(for doc: RmDoc) -> [String: Any] {
        [
            "deleted": false,
            "lastModified": String(doc.lastModified),
            "lastOpened": "",
            "lastOpenedPage": 0,
            "metadatamodified": false,
            "modified": false,
            "parent": doc.parent,
            "pinned": false,
            "synced": true,
            "type": "DocumentType",
            "version": doc.version,
            "visibleName": doc.visibleName,
        ]
    }

    /// sync15 ``.content`` JSON. Shape matches a tablet-native document;
    /// see CHANGES_FROM_SPEC.md for what happens when this drifts.
    private static func contentJSON(for doc: RmDoc) -> [String: Any] {
        let cpagesEntries: [[String: Any]] = doc.pages.enumerated().map { (i, page) in
            [
                "id": page.pageID,
                "idx": ["timestamp": "1:1", "value": fidx(i)] as [String: Any],
            ]
        }
        let lastOpenedID = doc.pages.last?.pageID ?? ""

        return [
            "coverPageNumber": -1,
            "cPages": [
                "lastOpened": ["timestamp": "1:1", "value": lastOpenedID] as [String: Any],
                "original": ["timestamp": "0:0", "value": -1] as [String: Any],
                "pages": cpagesEntries,
                "uuids": [
                    ["first": "00000000-0000-0000-0000-000000000000", "second": 1] as [String: Any]
                ],
            ] as [String: Any],
            "customZoomCenterX": 0,
            "customZoomCenterY": 936,
            "customZoomOrientation": "portrait",
            "customZoomPageHeight": 1872,
            "customZoomPageWidth": 1404,
            "customZoomScale": 1,
            "documentMetadata": [String: Any](),
            "extraMetadata": [String: Any](),
            "fileType": "notebook",
            "fontName": "",
            "formatVersion": 2,
            "lineHeight": -1,
            "margins": 100,
            "orientation": "portrait",
            "pageCount": doc.pages.count,
            "pageTags": [Any](),
            "sizeInBytes": String(doc.pages.reduce(0) { $0 + $1.rmBytes.count }),
            "tags": [Any](),
            "textAlignment": "justify",
            "textScale": 1,
            "zoomMode": "bestFit",
        ]
    }

    /// Fractional-index strings. "ba", "bb", "bc"… keep lexicographic
    /// ordering stable as pages are added. Page 26+ can't happen in
    /// practice (tablets fold long notebooks into multiple docs) but
    /// we still guard against it with a widening suffix.
    private static func fidx(_ n: Int) -> String {
        if n < 26 { return "b" + String(UnicodeScalar(UInt8(0x61 + n))) }
        // "ba", "bb", ..., "bz", then "bza", "bzb", ... keeps ordering.
        return "bz" + fidx(n - 26)
    }

    private static func serialize(_ obj: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted]
            )
        } catch {
            throw PackError.jsonFailed("\(error)")
        }
    }
}
