import Foundation

public struct AuthorIDEntry: Equatable {
    public var authorID: Int
    public var uuid: UUID

    public init(authorID: Int, uuid: UUID) {
        self.authorID = authorID
        self.uuid = uuid
    }
}

public struct SceneInfo: Equatable {
    public var currentLayer: LWWValue<CrdtID>
    public var backgroundVisible: LWWValue<Bool>?
    public var rootDocumentVisible: LWWValue<Bool>?
    public var paperSize: (Int, Int)?
    public var extraData: Data

    public init(currentLayer: LWWValue<CrdtID>, backgroundVisible: LWWValue<Bool>? = nil, rootDocumentVisible: LWWValue<Bool>? = nil, paperSize: (Int, Int)? = nil, extraData: Data = Data()) {
        self.currentLayer = currentLayer
        self.backgroundVisible = backgroundVisible
        self.rootDocumentVisible = rootDocumentVisible
        self.paperSize = paperSize
        self.extraData = extraData
    }

    public static func == (lhs: SceneInfo, rhs: SceneInfo) -> Bool {
        lhs.currentLayer == rhs.currentLayer &&
            lhs.backgroundVisible == rhs.backgroundVisible &&
            lhs.rootDocumentVisible == rhs.rootDocumentVisible &&
            lhs.paperSize?.0 == rhs.paperSize?.0 &&
            lhs.paperSize?.1 == rhs.paperSize?.1 &&
            lhs.extraData == rhs.extraData
    }
}

public struct AuthorIDsBlock: Equatable {
    public var authorUUIDs: [AuthorIDEntry]
    public var extraData: Data

    public init(authorUUIDs: [AuthorIDEntry], extraData: Data = Data()) {
        self.authorUUIDs = authorUUIDs
        self.extraData = extraData
    }
}

public struct MigrationInfoBlock: Equatable {
    public var migrationID: CrdtID
    public var isDevice: Bool
    public var unknown: Bool
    public var extraData: Data

    public init(migrationID: CrdtID, isDevice: Bool, unknown: Bool = false, extraData: Data = Data()) {
        self.migrationID = migrationID
        self.isDevice = isDevice
        self.unknown = unknown
        self.extraData = extraData
    }
}

public struct TreeNodeBlock: Equatable {
    public var group: Group
    public var extraData: Data

    public init(group: Group, extraData: Data = Data()) {
        self.group = group
        self.extraData = extraData
    }
}

public struct PageInfoBlock: Equatable {
    public var loadsCount: Int
    public var mergesCount: Int
    public var textCharsCount: Int
    public var textLinesCount: Int
    public var typeFolioUseCount: Int
    public var extraData: Data

    public init(loadsCount: Int, mergesCount: Int, textCharsCount: Int, textLinesCount: Int, typeFolioUseCount: Int = 0, extraData: Data = Data()) {
        self.loadsCount = loadsCount
        self.mergesCount = mergesCount
        self.textCharsCount = textCharsCount
        self.textLinesCount = textLinesCount
        self.typeFolioUseCount = typeFolioUseCount
        self.extraData = extraData
    }
}

public struct SceneTreeBlock: Equatable {
    public var treeID: CrdtID
    public var nodeID: CrdtID
    public var isUpdate: Bool
    public var parentID: CrdtID
    public var extraData: Data

    public init(treeID: CrdtID, nodeID: CrdtID, isUpdate: Bool, parentID: CrdtID, extraData: Data = Data()) {
        self.treeID = treeID
        self.nodeID = nodeID
        self.isUpdate = isUpdate
        self.parentID = parentID
        self.extraData = extraData
    }
}

public struct SceneGlyphItemBlock: Equatable {
    public var parentID: CrdtID
    public var item: CrdtSequenceItem<GlyphRange?>
    public var extraValueData: Data
    public var extraData: Data

    public init(parentID: CrdtID, item: CrdtSequenceItem<GlyphRange?>, extraValueData: Data = Data(), extraData: Data = Data()) {
        self.parentID = parentID
        self.item = item
        self.extraValueData = extraValueData
        self.extraData = extraData
    }
}

public struct SceneGroupItemBlock: Equatable {
    public var parentID: CrdtID
    public var item: CrdtSequenceItem<CrdtID?>
    public var extraValueData: Data
    public var extraData: Data

    public init(parentID: CrdtID, item: CrdtSequenceItem<CrdtID?>, extraValueData: Data = Data(), extraData: Data = Data()) {
        self.parentID = parentID
        self.item = item
        self.extraValueData = extraValueData
        self.extraData = extraData
    }
}

public struct SceneLineItemBlock: Equatable {
    public var parentID: CrdtID
    public var item: CrdtSequenceItem<Line?>
    public var extraValueData: Data
    public var extraData: Data

    public init(parentID: CrdtID, item: CrdtSequenceItem<Line?>, extraValueData: Data = Data(), extraData: Data = Data()) {
        self.parentID = parentID
        self.item = item
        self.extraValueData = extraValueData
        self.extraData = extraData
    }
}

public struct SceneTextItemBlock: Equatable {
    public var parentID: CrdtID
    public var itemID: CrdtID
    public var leftID: CrdtID
    public var rightID: CrdtID
    public var deletedLength: Int
    public var extraValueData: Data
    public var extraData: Data

    public init(parentID: CrdtID, itemID: CrdtID, leftID: CrdtID, rightID: CrdtID, deletedLength: Int, extraValueData: Data = Data(), extraData: Data = Data()) {
        self.parentID = parentID
        self.itemID = itemID
        self.leftID = leftID
        self.rightID = rightID
        self.deletedLength = deletedLength
        self.extraValueData = extraValueData
        self.extraData = extraData
    }
}

public struct SceneTombstoneItemBlock: Equatable {
    public var parentID: CrdtID
    public var itemID: CrdtID
    public var leftID: CrdtID
    public var rightID: CrdtID
    public var deletedLength: Int
    public var extraValueData: Data
    public var extraData: Data

    public init(parentID: CrdtID, itemID: CrdtID, leftID: CrdtID, rightID: CrdtID, deletedLength: Int, extraValueData: Data = Data(), extraData: Data = Data()) {
        self.parentID = parentID
        self.itemID = itemID
        self.leftID = leftID
        self.rightID = rightID
        self.deletedLength = deletedLength
        self.extraValueData = extraValueData
        self.extraData = extraData
    }
}

public struct RootTextBlock: Equatable {
    public var blockID: CrdtID
    public var value: Text
    public var extraData: Data

    public init(blockID: CrdtID, value: Text, extraData: Data = Data()) {
        self.blockID = blockID
        self.value = value
        self.extraData = extraData
    }
}

public struct UnreadableBlock: Equatable {
    public var error: String
    public var data: Data
    public var info: MainBlockInfo
    public var extraData: Data

    public init(error: String, data: Data, info: MainBlockInfo, extraData: Data = Data()) {
        self.error = error
        self.data = data
        self.info = info
        self.extraData = extraData
    }
}

public enum SceneBlock: Equatable {
    case unreadable(UnreadableBlock)
    case sceneInfo(SceneInfo)
    case authorIDs(AuthorIDsBlock)
    case migrationInfo(MigrationInfoBlock)
    case treeNode(TreeNodeBlock)
    case pageInfo(PageInfoBlock)
    case sceneTree(SceneTreeBlock)
    case sceneGlyphItem(SceneGlyphItemBlock)
    case sceneGroupItem(SceneGroupItemBlock)
    case sceneLineItem(SceneLineItemBlock)
    case sceneTextItem(SceneTextItemBlock)
    case sceneTombstoneItem(SceneTombstoneItemBlock)
    case rootText(RootTextBlock)
}

public struct RMSceneDecoder {
    public init() {}

    public func decodeBlocks(from data: Data) throws -> [SceneBlock] {
        let reader = TaggedBlockReader(data: data)
        try reader.readHeader()
        var blocks: [SceneBlock] = []
        while let block = try readBlock(from: reader) {
            blocks.append(block)
        }
        return blocks
    }

    public func decodeTree(from data: Data) throws -> SceneTree {
        let tree = SceneTree()
        try buildTree(tree, from: decodeBlocks(from: data))
        return tree
    }
}

public struct RMSceneEncoder {
    public init() {}

    public func encode(_ blocks: [SceneBlock], version: RemarkableVersion) throws -> Data {
        let writer = TaggedBlockWriter(version: version)
        writer.writeHeader()
        for block in blocks {
            try write(block, to: writer)
        }
        return writer.encodedData
    }

    public func simpleTextDocument(_ text: String, authorID: UUID? = nil) -> [SceneBlock] {
        let authorID = authorID ?? UUID()
        return [
            .authorIDs(AuthorIDsBlock(authorUUIDs: [AuthorIDEntry(authorID: 1, uuid: authorID)])),
            .migrationInfo(MigrationInfoBlock(migrationID: CrdtID(1, 1), isDevice: true)),
            .pageInfo(PageInfoBlock(
                loadsCount: 1,
                mergesCount: 0,
                textCharsCount: text.count + 1,
                textLinesCount: text.components(separatedBy: "\n").count
            )),
            .sceneTree(SceneTreeBlock(treeID: CrdtID(0, 11), nodeID: CrdtID(0, 0), isUpdate: true, parentID: SceneTree.rootID)),
            .rootText(RootTextBlock(
                blockID: .zero,
                value: Text(
                    items: CrdtSequence([
                        CrdtSequenceItem(itemID: CrdtID(1, 16), leftID: .zero, rightID: .zero, deletedLength: 0, value: .string(text)),
                    ]),
                    styles: OrderedMap([
                        (.zero, LWWValue(timestamp: CrdtID(1, 15), value: .plain)),
                    ]),
                    posX: -468.0,
                    posY: 234.0,
                    width: 936.0
                )
            )),
            .treeNode(TreeNodeBlock(group: Group(nodeID: SceneTree.rootID))),
            .treeNode(TreeNodeBlock(group: Group(nodeID: CrdtID(0, 11), label: LWWValue(timestamp: CrdtID(0, 12), value: "Layer 1")))),
            .sceneGroupItem(SceneGroupItemBlock(
                parentID: SceneTree.rootID,
                item: CrdtSequenceItem(itemID: CrdtID(0, 13), leftID: .zero, rightID: .zero, deletedLength: 0, value: CrdtID(0, 11))
            )),
        ]
    }

    /// One styled span within a paragraph: a run of text plus its inline
    /// (bold/italic) attributes. Spans are flattened when building the
    /// CRDT — adjacent spans with identical style merge implicitly.
    public struct Span {
        public var text: String
        public var style: InlineTextStyle
        public init(text: String, style: InlineTextStyle = InlineTextStyle()) {
            self.text = text
            self.style = style
        }
    }

    /// One paragraph: its block style (heading / bullet / etc.) plus the
    /// inline-styled spans that make up its body. Empty body is allowed
    /// (an empty paragraph) but is rare — the higher-level markdown
    /// pipeline collapses runs of blanks before reaching us.
    public struct StyledParagraph {
        public var style: ParagraphStyle
        public var spans: [Span]
        public init(style: ParagraphStyle, spans: [Span]) {
            self.style = style
            self.spans = spans
        }
    }

    /// Build a `.rm` page from styled paragraphs, preserving paragraph
    /// styles (heading / bullet / checkbox / …) and inline bold + italic
    /// runs. Mirrors ``simpleTextDocument`` but emits a multi-item CRDT
    /// sequence so the `text.styles` map can key each paragraph's style
    /// to the CRDT ID of its leading newline (or `.zero` for the first
    /// paragraph) — that keying is what `TextDocument.fromSceneItem`
    /// reads back on the pull side.
    ///
    /// CRDT IDs are assigned sequentially starting at `(1, 16)` (matching
    /// `simpleTextDocument`'s base) so every character / format-code
    /// owns a unique slot, and items chain forward via `leftID` /
    /// `rightID`. Inline transitions emit format codes 1/2 (bold on/off)
    /// and 3/4 (italic on/off) — the exact codes `Core.applyFormatting`
    /// reads on parse.
    public func richTextDocument(_ paragraphs: [StyledParagraph], authorID: UUID? = nil) -> [SceneBlock] {
        let authorID = authorID ?? UUID()

        var items: [CrdtSequenceItem<TextItemValue>] = []
        var styleEntries: [(CrdtID, LWWValue<ParagraphStyle>)] = []
        var nextSlot = 16
        var totalChars = 0
        var prevLastID: CrdtID = .zero
        var inlineState = InlineTextStyle()

        // Helper to emit a CRDT item that takes `slots` ID slots. Returns
        // the itemID assigned. The leftID is wired to the previous item's
        // last ID; the rightID is left as `.zero` and re-stitched after
        // the loop completes (we don't know the next item's first ID
        // until we've decided what to emit next).
        func append(_ value: TextItemValue, slots: Int) -> CrdtID {
            let itemID = CrdtID(1, nextSlot)
            items.append(CrdtSequenceItem(
                itemID: itemID,
                leftID: prevLastID,
                rightID: .zero,
                deletedLength: 0,
                value: value
            ))
            // Last expanded ID for this item is itemID + (slots - 1).
            prevLastID = CrdtID(1, nextSlot + slots - 1)
            nextSlot += slots
            return itemID
        }

        // Emit format-code transitions to move from `inlineState` to
        // `target`. Order matches what the pull-side `applyFormatting`
        // expects: bold first, then italic. Format codes occupy 1 slot.
        func transitionInlineTo(_ target: InlineTextStyle) {
            if target.fontWeight != inlineState.fontWeight {
                let code = (target.fontWeight == .bold) ? 1 : 2
                _ = append(.formatCode(code), slots: 1)
                totalChars += 0 // format codes are not user-visible chars
            }
            if target.fontStyle != inlineState.fontStyle {
                let code = (target.fontStyle == .italic) ? 3 : 4
                _ = append(.formatCode(code), slots: 1)
            }
            inlineState = target
        }

        // First paragraph's style is keyed by `.zero` — `fromSceneItem`
        // assigns `.zero` as the startID for any paragraph whose CRDT
        // sequence doesn't begin with a `\n` character.
        if let first = paragraphs.first {
            styleEntries.append((.zero, LWWValue(timestamp: CrdtID(1, 15), value: first.style)))
        }

        for (paraIdx, paragraph) in paragraphs.enumerated() {
            for span in paragraph.spans where !span.text.isEmpty {
                transitionInlineTo(span.style)
                _ = append(.string(span.text), slots: span.text.count)
                totalChars += span.text.count
            }

            // Inter-paragraph newline. Acts as both the paragraph
            // terminator AND the CRDT key for the next paragraph's
            // style. Skipped after the last paragraph — the document
            // doesn't carry a trailing empty paragraph.
            if paraIdx < paragraphs.count - 1 {
                // Reset inline style at paragraph boundary so the next
                // paragraph starts clean. We emit any closing format
                // codes BEFORE the newline so the paragraph break
                // doesn't fall inside a styled run.
                transitionInlineTo(InlineTextStyle())
                let newlineID = append(.string("\n"), slots: 1)
                totalChars += 1
                let nextStyle = paragraphs[paraIdx + 1].style
                styleEntries.append((newlineID, LWWValue(timestamp: CrdtID(1, 15), value: nextStyle)))
            }
        }

        // Close any open inline run at the end of the document so the
        // wire format never has a dangling bold-on with no matching
        // bold-off — keeps the file deterministic and round-trippable.
        transitionInlineTo(InlineTextStyle())

        // Re-stitch rightIDs: each item's rightID points at the next
        // item's itemID. The final item retains `.zero`. Done as a
        // post-pass so we don't need to know "next item's first ID"
        // while iterating. ``indices.dropLast()`` is empty when items
        // has 0 or 1 entries — both are valid (handwriting page or a
        // single text run).
        for i in items.indices.dropLast() {
            let next = items[i + 1]
            items[i] = CrdtSequenceItem(
                itemID: items[i].itemID,
                leftID: items[i].leftID,
                rightID: next.itemID,
                deletedLength: items[i].deletedLength,
                value: items[i].value
            )
        }

        let lineCount = max(paragraphs.count, 1)

        return [
            .authorIDs(AuthorIDsBlock(authorUUIDs: [AuthorIDEntry(authorID: 1, uuid: authorID)])),
            .migrationInfo(MigrationInfoBlock(migrationID: CrdtID(1, 1), isDevice: true)),
            .pageInfo(PageInfoBlock(
                loadsCount: 1,
                mergesCount: 0,
                textCharsCount: totalChars + 1,
                textLinesCount: lineCount
            )),
            .sceneTree(SceneTreeBlock(treeID: CrdtID(0, 11), nodeID: CrdtID(0, 0), isUpdate: true, parentID: SceneTree.rootID)),
            .rootText(RootTextBlock(
                blockID: .zero,
                value: Text(
                    items: CrdtSequence(items),
                    styles: OrderedMap(styleEntries),
                    posX: -468.0,
                    posY: 234.0,
                    width: 936.0
                )
            )),
            .treeNode(TreeNodeBlock(group: Group(nodeID: SceneTree.rootID))),
            .treeNode(TreeNodeBlock(group: Group(nodeID: CrdtID(0, 11), label: LWWValue(timestamp: CrdtID(0, 12), value: "Layer 1")))),
            .sceneGroupItem(SceneGroupItemBlock(
                parentID: SceneTree.rootID,
                item: CrdtSequenceItem(itemID: CrdtID(0, 13), leftID: .zero, rightID: .zero, deletedLength: 0, value: CrdtID(0, 11))
            )),
        ]
    }
}

public func buildTree(_ tree: SceneTree, from blocks: [SceneBlock]) throws {
    for block in blocks {
        switch block {
        case let .sceneTree(sceneTree):
            try tree.addNode(nodeID: sceneTree.treeID, parentID: sceneTree.parentID)
        case let .treeNode(treeNode):
            try tree.updateNode(treeNode.group)
        case let .sceneGroupItem(groupItem):
            guard let nodeID = groupItem.item.value else {
                continue
            }
            guard let group = tree[nodeID] else {
                throw RMSceneFormatError.invalidValue("Node does not exist for SceneGroupItemBlock: \(nodeID)")
            }
            try tree.addItem(
                CrdtSequenceItem(
                    itemID: groupItem.item.itemID,
                    leftID: groupItem.item.leftID,
                    rightID: groupItem.item.rightID,
                    deletedLength: groupItem.item.deletedLength,
                    value: .group(group)
                ),
                parentID: groupItem.parentID
            )
        case let .sceneLineItem(lineItem):
            guard let line = lineItem.item.value else {
                continue
            }
            try tree.addItem(
                CrdtSequenceItem(
                    itemID: lineItem.item.itemID,
                    leftID: lineItem.item.leftID,
                    rightID: lineItem.item.rightID,
                    deletedLength: lineItem.item.deletedLength,
                    value: .line(line)
                ),
                parentID: lineItem.parentID
            )
        case let .sceneGlyphItem(glyphItem):
            guard let glyph = glyphItem.item.value else {
                continue
            }
            try tree.addItem(
                CrdtSequenceItem(
                    itemID: glyphItem.item.itemID,
                    leftID: glyphItem.item.leftID,
                    rightID: glyphItem.item.rightID,
                    deletedLength: glyphItem.item.deletedLength,
                    value: .glyphRange(glyph)
                ),
                parentID: glyphItem.parentID
            )
        case let .sceneInfo(sceneInfo):
            tree.setSceneInfo(sceneInfo)
        case let .rootText(rootText):
            tree.setRootText(rootText.value)
        case .sceneTextItem, .sceneTombstoneItem, .authorIDs, .migrationInfo, .pageInfo, .unreadable:
            break
        }
    }
}

private func readBlock(from reader: TaggedBlockReader) throws -> SceneBlock? {
    guard let info = try reader.nextBlockInfo() else {
        return nil
    }

    let block: SceneBlock
    do {
        switch info.blockType {
        case 0x00:
            block = .migrationInfo(try readMigrationInfoBlock(from: reader))
        case 0x01:
            block = .sceneTree(try readSceneTreeBlock(from: reader))
        case 0x02:
            block = .treeNode(try readTreeNodeBlock(from: reader))
        case 0x03:
            block = .sceneGlyphItem(try readSceneGlyphItemBlock(from: reader))
        case 0x04:
            block = .sceneGroupItem(try readSceneGroupItemBlock(from: reader))
        case 0x05:
            block = .sceneLineItem(try readSceneLineItemBlock(from: reader, version: info.currentVersion))
        case 0x06:
            block = .sceneTextItem(try readSceneTextItemBlock(from: reader))
        case 0x07:
            block = .rootText(try readRootTextBlock(from: reader))
        case 0x08:
            block = .sceneTombstoneItem(try readSceneTombstoneItemBlock(from: reader))
        case 0x09:
            block = .authorIDs(try readAuthorIDsBlock(from: reader))
        case 0x0A:
            block = .pageInfo(try readPageInfoBlock(from: reader))
        case 0x0D:
            block = .sceneInfo(try readSceneInfoBlock(from: reader))
        default:
            let message = "Unknown block type \(info.blockType). Skipping \(info.size) bytes."
            let data = try reader.data.readBytes(info.size)
            block = .unreadable(UnreadableBlock(error: message, data: data, info: info))
        }
    } catch {
        reader.data.seek(info.offset)
        let data = try reader.data.readBytes(info.size)
        block = .unreadable(UnreadableBlock(error: String(describing: error), data: data, info: info))
    }

    let finalizedInfo = try reader.finishCurrentBlock()
    return applyingExtraData(finalizedInfo.extraData, to: block)
}

private func write(_ block: SceneBlock, to writer: TaggedBlockWriter) throws {
    let (type, minVersion, currentVersion, extraData) = metadata(for: block, writer: writer)
    try writer.withBlock(type: type, minVersion: minVersion, currentVersion: currentVersion) {
        switch block {
        case let .unreadable(unreadable):
            writer.data.writeBytes(unreadable.data)
        case let .sceneInfo(sceneInfo):
            try writeSceneInfo(sceneInfo, to: writer)
        case let .authorIDs(authorIDs):
            try writeAuthorIDs(authorIDs, to: writer)
        case let .migrationInfo(migrationInfo):
            try writeMigrationInfo(migrationInfo, to: writer)
        case let .treeNode(treeNode):
            try writeTreeNode(treeNode, to: writer)
        case let .pageInfo(pageInfo):
            try writePageInfo(pageInfo, to: writer)
        case let .sceneTree(sceneTree):
            try writeSceneTree(sceneTree, to: writer)
        case let .sceneGlyphItem(glyphItem):
            try writeSceneGlyphItem(glyphItem, to: writer)
        case let .sceneGroupItem(groupItem):
            try writeSceneGroupItem(groupItem, to: writer)
        case let .sceneLineItem(lineItem):
            try writeSceneLineItem(lineItem, to: writer)
        case let .sceneTextItem(textItem):
            try writeSceneTextItem(textItem, to: writer)
        case let .sceneTombstoneItem(tombstone):
            try writeSceneTombstoneItem(tombstone, to: writer)
        case let .rootText(rootText):
            try writeRootText(rootText, to: writer)
        }
        writer.data.writeBytes(extraData)
    }
}

private func metadata(for block: SceneBlock, writer: TaggedBlockWriter) -> (type: Int, minVersion: Int, currentVersion: Int, extraData: Data) {
    switch block {
    case let .unreadable(unreadable):
        return (unreadable.info.blockType, unreadable.info.minVersion, unreadable.info.currentVersion, unreadable.extraData)
    case let .sceneInfo(sceneInfo):
        return (0x0D, 0, 1, sceneInfo.extraData)
    case let .authorIDs(authorIDs):
        return (0x09, 1, 1, authorIDs.extraData)
    case let .migrationInfo(migrationInfo):
        return (0x00, 1, 1, migrationInfo.extraData)
    case let .treeNode(treeNode):
        return (0x02, writer.version ?? "9999" >= "3.4" ? 1 : 1, writer.version ?? "9999" >= "3.4" ? 2 : 1, treeNode.extraData)
    case let .pageInfo(pageInfo):
        return (0x0A, 0, 1, pageInfo.extraData)
    case let .sceneTree(sceneTree):
        return (0x01, 1, 1, sceneTree.extraData)
    case let .sceneGlyphItem(glyphItem):
        return (0x03, 1, 1, glyphItem.extraData)
    case let .sceneGroupItem(groupItem):
        return (0x04, 1, 1, groupItem.extraData)
    case let .sceneLineItem(lineItem):
        let lineVersion: Int = (writer.version ?? "9999") > "3.0" ? 2 : 1
        return (0x05, lineVersion, lineVersion, lineItem.extraData)
    case let .sceneTextItem(textItem):
        return (0x06, 1, 1, textItem.extraData)
    case let .sceneTombstoneItem(tombstone):
        return (0x08, 1, 1, tombstone.extraData)
    case let .rootText(rootText):
        return (0x07, 1, 1, rootText.extraData)
    }
}

private func applyingExtraData(_ extraData: Data, to block: SceneBlock) -> SceneBlock {
    switch block {
    case var .sceneInfo(sceneInfo):
        sceneInfo.extraData = extraData
        return .sceneInfo(sceneInfo)
    case var .authorIDs(authorIDs):
        authorIDs.extraData = extraData
        return .authorIDs(authorIDs)
    case var .migrationInfo(migrationInfo):
        migrationInfo.extraData = extraData
        return .migrationInfo(migrationInfo)
    case var .treeNode(treeNode):
        treeNode.extraData = extraData
        return .treeNode(treeNode)
    case var .pageInfo(pageInfo):
        pageInfo.extraData = extraData
        return .pageInfo(pageInfo)
    case var .sceneTree(sceneTree):
        sceneTree.extraData = extraData
        return .sceneTree(sceneTree)
    case var .sceneGlyphItem(glyphItem):
        glyphItem.extraData = extraData
        return .sceneGlyphItem(glyphItem)
    case var .sceneGroupItem(groupItem):
        groupItem.extraData = extraData
        return .sceneGroupItem(groupItem)
    case var .sceneLineItem(lineItem):
        lineItem.extraData = extraData
        return .sceneLineItem(lineItem)
    case var .sceneTextItem(textItem):
        textItem.extraData = extraData
        return .sceneTextItem(textItem)
    case var .sceneTombstoneItem(tombstone):
        tombstone.extraData = extraData
        return .sceneTombstoneItem(tombstone)
    case var .rootText(rootText):
        rootText.extraData = extraData
        return .rootText(rootText)
    case var .unreadable(unreadable):
        unreadable.extraData = extraData
        return .unreadable(unreadable)
    }
}

private func readSceneInfoBlock(from reader: TaggedBlockReader) throws -> SceneInfo {
    let currentLayer = try reader.readLWWID(index: 1)
    let backgroundVisible = try reader.bytesRemainingInBlock() > 0 ? reader.readLWWBool(index: 2) : nil
    let rootDocumentVisible = try reader.bytesRemainingInBlock() > 0 ? reader.readLWWBool(index: 3) : nil
    let paperSize = try reader.bytesRemainingInBlock() > 0 ? reader.readIntPair(index: 5) : nil
    return SceneInfo(currentLayer: currentLayer, backgroundVisible: backgroundVisible, rootDocumentVisible: rootDocumentVisible, paperSize: paperSize)
}

private func writeSceneInfo(_ sceneInfo: SceneInfo, to writer: TaggedBlockWriter) throws {
    try writer.writeLWWID(index: 1, value: sceneInfo.currentLayer)
    if let backgroundVisible = sceneInfo.backgroundVisible {
        try writer.writeLWWBool(index: 2, value: backgroundVisible)
    }
    if let rootDocumentVisible = sceneInfo.rootDocumentVisible {
        try writer.writeLWWBool(index: 3, value: rootDocumentVisible)
    }
    if let paperSize = sceneInfo.paperSize {
        try writer.writeIntPair(index: 5, value: paperSize)
    }
}

private func readAuthorIDsBlock(from reader: TaggedBlockReader) throws -> AuthorIDsBlock {
    let count = try reader.data.readVarUInt()
    var authorIDs: [AuthorIDEntry] = []
    for _ in 0..<count {
        let subblock = try reader.beginSubblock(index: 0)
        let uuidLength = try reader.data.readVarUInt()
        guard uuidLength == 16 else {
            throw RMSceneFormatError.invalidValue("Expected UUID length to be 16 bytes")
        }
        let uuid = try uuidFromLittleEndianBytes(reader.data.readBytes(uuidLength))
        let authorID = Int(try reader.data.readUInt16())
        _ = try reader.finishSubblock(subblock)
        authorIDs.append(AuthorIDEntry(authorID: authorID, uuid: uuid))
    }
    return AuthorIDsBlock(authorUUIDs: authorIDs)
}

private func writeAuthorIDs(_ authorIDs: AuthorIDsBlock, to writer: TaggedBlockWriter) throws {
    try writer.data.writeVarUInt(authorIDs.authorUUIDs.count)
    for entry in authorIDs.authorUUIDs {
        try writer.withSubblock(index: 0) {
            let bytes = uuidLittleEndianBytes(entry.uuid)
            try writer.data.writeVarUInt(bytes.count)
            writer.data.writeBytes(bytes)
            writer.data.writeUInt16(UInt16(entry.authorID))
        }
    }
}

private func readMigrationInfoBlock(from reader: TaggedBlockReader) throws -> MigrationInfoBlock {
    let migrationID = try reader.readID(index: 1)
    let isDevice = try reader.readBool(index: 2)
    let unknown = try reader.bytesRemainingInBlock() > 0 ? reader.readBool(index: 3) : false
    return MigrationInfoBlock(migrationID: migrationID, isDevice: isDevice, unknown: unknown)
}

private func writeMigrationInfo(_ migrationInfo: MigrationInfoBlock, to writer: TaggedBlockWriter) throws {
    try writer.writeID(index: 1, value: migrationInfo.migrationID)
    try writer.writeBool(index: 2, value: migrationInfo.isDevice)
    if (writer.version ?? "9.9.9") >= "3.2.2" {
        try writer.writeBool(index: 3, value: migrationInfo.unknown)
    }
}

private func readTreeNodeBlock(from reader: TaggedBlockReader) throws -> TreeNodeBlock {
    let group = Group(
        nodeID: try reader.readID(index: 1),
        label: try reader.readLWWString(index: 2),
        visible: try reader.readLWWBool(index: 3)
    )

    if try reader.bytesRemainingInBlock() > 0 {
        group.anchorID = try reader.readLWWID(index: 7)
        group.anchorType = try reader.readLWWByte(index: 8)
        group.anchorThreshold = try reader.readLWWFloat(index: 9)
        group.anchorOriginX = try reader.readLWWFloat(index: 10)
    }
    return TreeNodeBlock(group: group)
}

private func writeTreeNode(_ treeNode: TreeNodeBlock, to writer: TaggedBlockWriter) throws {
    try writer.writeID(index: 1, value: treeNode.group.nodeID)
    try writer.writeLWWString(index: 2, value: treeNode.group.label)
    try writer.writeLWWBool(index: 3, value: treeNode.group.visible)
    if let anchorID = treeNode.group.anchorID {
        guard
            let anchorType = treeNode.group.anchorType,
            let anchorThreshold = treeNode.group.anchorThreshold,
            let anchorOriginX = treeNode.group.anchorOriginX
        else {
            throw RMSceneFormatError.invalidValue("Incomplete anchor data")
        }
        try writer.writeLWWID(index: 7, value: anchorID)
        try writer.writeLWWByte(index: 8, value: anchorType)
        try writer.writeLWWFloat(index: 9, value: anchorThreshold)
        try writer.writeLWWFloat(index: 10, value: anchorOriginX)
    }
}

private func readPageInfoBlock(from reader: TaggedBlockReader) throws -> PageInfoBlock {
    var pageInfo = PageInfoBlock(
        loadsCount: try reader.readInt(index: 1),
        mergesCount: try reader.readInt(index: 2),
        textCharsCount: try reader.readInt(index: 3),
        textLinesCount: try reader.readInt(index: 4)
    )
    if try reader.bytesRemainingInBlock() > 0 {
        pageInfo.typeFolioUseCount = try reader.readInt(index: 5)
    }
    return pageInfo
}

private func writePageInfo(_ pageInfo: PageInfoBlock, to writer: TaggedBlockWriter) throws {
    try writer.writeInt(index: 1, value: pageInfo.loadsCount)
    try writer.writeInt(index: 2, value: pageInfo.mergesCount)
    try writer.writeInt(index: 3, value: pageInfo.textCharsCount)
    try writer.writeInt(index: 4, value: pageInfo.textLinesCount)
    if (writer.version ?? "9999") >= "3.2.2" {
        try writer.writeInt(index: 5, value: pageInfo.typeFolioUseCount)
    }
}

private func readSceneTreeBlock(from reader: TaggedBlockReader) throws -> SceneTreeBlock {
    let treeID = try reader.readID(index: 1)
    let nodeID = try reader.readID(index: 2)
    let isUpdate = try reader.readBool(index: 3)
    let subblock = try reader.beginSubblock(index: 4)
    let parentID = try reader.readID(index: 1)
    _ = try reader.finishSubblock(subblock)
    return SceneTreeBlock(treeID: treeID, nodeID: nodeID, isUpdate: isUpdate, parentID: parentID)
}

private func writeSceneTree(_ sceneTree: SceneTreeBlock, to writer: TaggedBlockWriter) throws {
    try writer.writeID(index: 1, value: sceneTree.treeID)
    try writer.writeID(index: 2, value: sceneTree.nodeID)
    try writer.writeBool(index: 3, value: sceneTree.isUpdate)
    try writer.withSubblock(index: 4) {
        try writer.writeID(index: 1, value: sceneTree.parentID)
    }
}

private func pointFromReader(_ reader: TaggedBlockReader, version: Int) throws -> Point {
    guard version == 1 || version == 2 else {
        throw RMSceneFormatError.invalidValue("Unknown version \(version)")
    }
    let x = try reader.data.readFloat32()
    let y = try reader.data.readFloat32()
    if version == 1 {
        let rawSpeed = try reader.data.readFloat32()
        let rawDirection = try reader.data.readFloat32()
        let rawWidth = try reader.data.readFloat32()
        let rawPressure = try reader.data.readFloat32()
        let speed = rawSpeed * 4.0
        let direction = 255.0 * rawDirection / (Double.pi * 2.0)
        let width = round(rawWidth * 4.0)
        let pressure = rawPressure * 255.0
        return Point(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure)
    }

    let speed = Double(try reader.data.readUInt16())
    let width = Double(try reader.data.readUInt16())
    let direction = Double(try reader.data.readUInt8())
    let pressure = Double(try reader.data.readUInt8())
    return Point(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure)
}

private func pointSerializedSize(version: Int) throws -> Int {
    switch version {
    case 1:
        return 0x18
    case 2:
        return 0x0E
    default:
        throw RMSceneFormatError.invalidValue("Unknown version \(version)")
    }
}

private func writePoint(_ point: Point, to writer: TaggedBlockWriter, version: Int) throws {
    guard version == 1 || version == 2 else {
        throw RMSceneFormatError.invalidValue("Unknown version \(version)")
    }
    writer.data.writeFloat32(point.x)
    writer.data.writeFloat32(point.y)
    if version == 1 {
        writer.data.writeFloat32(point.speed / 4.0)
        writer.data.writeFloat32(point.direction * (Double.pi * 2.0) / 255.0)
        writer.data.writeFloat32(point.width / 4.0)
        writer.data.writeFloat32(point.pressure / 255.0)
    } else {
        writer.data.writeUInt16(UInt16(round(point.speed)))
        writer.data.writeUInt16(UInt16(round(point.width)))
        writer.data.writeUInt8(UInt8(round(point.direction)))
        writer.data.writeUInt8(UInt8(round(point.pressure)))
    }
}

private func readLine(from reader: TaggedBlockReader, version: Int) throws -> Line {
    let toolID = try reader.readInt(index: 1)
    guard let tool = Pen(rawValue: toolID) else {
        throw RMSceneFormatError.invalidValue("Unknown tool \(toolID)")
    }
    let colorID = try reader.readInt(index: 2)
    guard let color = PenColor(rawValue: colorID) else {
        throw RMSceneFormatError.invalidValue("Unknown color \(colorID)")
    }
    let thicknessScale = try reader.readDouble(index: 3)
    let startingLength = try reader.readFloat(index: 4)
    let subblock = try reader.beginSubblock(index: 5)
    let pointSize = try pointSerializedSize(version: version)
    guard subblock.size % pointSize == 0 else {
        throw RMSceneFormatError.invalidValue("Point data size mismatch: \(subblock.size) is not multiple of point_size")
    }
    let pointCount = subblock.size / pointSize
    var points: [Point] = []
    points.reserveCapacity(pointCount)
    for _ in 0..<pointCount {
        points.append(try pointFromReader(reader, version: version))
    }
    _ = try reader.finishSubblock(subblock)
    _ = try reader.readID(index: 6)
    let moveID: CrdtID?
    if try reader.bytesRemainingInBlock() >= 3 {
        moveID = reader.readIDOptional(index: 7)
    } else {
        moveID = nil
    }
    let colorRGBA = reader.readColorOptional(index: 8)
    return Line(color: color, tool: tool, points: points, thicknessScale: thicknessScale, startingLength: startingLength, moveID: moveID, colorRGBA: colorRGBA)
}

private func writeLine(_ line: Line, to writer: TaggedBlockWriter, version: Int) throws {
    try writer.writeInt(index: 1, value: line.tool.rawValue)
    try writer.writeInt(index: 2, value: line.color.rawValue)
    try writer.writeDouble(index: 3, value: line.thicknessScale)
    try writer.writeFloat(index: 4, value: line.startingLength)
    try writer.withSubblock(index: 5) {
        for point in line.points {
            try writePoint(point, to: writer, version: version)
        }
    }
    try writer.writeID(index: 6, value: SceneTree.rootID)
    if let moveID = line.moveID {
        try writer.writeID(index: 7, value: moveID)
    }
    if let colorRGBA = line.colorRGBA {
        try writer.writeColor(index: 8, value: colorRGBA)
    }
}

private func readSceneGlyphItemBlock(from reader: TaggedBlockReader) throws -> SceneGlyphItemBlock {
    let parsed = try readSceneItemMetadata(from: reader, expectedItemType: 0x01)
    let glyphRange = try parsed.valueSubblockInfo != nil ? readGlyphRange(from: reader) : nil
    let extraValueData = try finishValueSubblockIfNeeded(parsed.valueSubblockInfo, reader: reader)
    return SceneGlyphItemBlock(
        parentID: parsed.parentID,
        item: CrdtSequenceItem(itemID: parsed.itemID, leftID: parsed.leftID, rightID: parsed.rightID, deletedLength: parsed.deletedLength, value: glyphRange),
        extraValueData: extraValueData
    )
}

private func writeSceneGlyphItem(_ block: SceneGlyphItemBlock, to writer: TaggedBlockWriter) throws {
    try writeSceneItemMetadata(parentID: block.parentID, itemID: block.item.itemID, leftID: block.item.leftID, rightID: block.item.rightID, deletedLength: block.item.deletedLength, itemType: 0x01, hasValue: block.item.value != nil, extraValueData: block.extraValueData, writer: writer) {
        if let value = block.item.value {
            try writeGlyphRange(value, to: writer)
        }
    }
}

private func readSceneGroupItemBlock(from reader: TaggedBlockReader) throws -> SceneGroupItemBlock {
    let parsed = try readSceneItemMetadata(from: reader, expectedItemType: 0x02)
    let value = try parsed.valueSubblockInfo != nil ? reader.readID(index: 2) : nil
    let extraValueData = try finishValueSubblockIfNeeded(parsed.valueSubblockInfo, reader: reader)
    return SceneGroupItemBlock(
        parentID: parsed.parentID,
        item: CrdtSequenceItem(itemID: parsed.itemID, leftID: parsed.leftID, rightID: parsed.rightID, deletedLength: parsed.deletedLength, value: value),
        extraValueData: extraValueData
    )
}

private func writeSceneGroupItem(_ block: SceneGroupItemBlock, to writer: TaggedBlockWriter) throws {
    try writeSceneItemMetadata(parentID: block.parentID, itemID: block.item.itemID, leftID: block.item.leftID, rightID: block.item.rightID, deletedLength: block.item.deletedLength, itemType: 0x02, hasValue: block.item.value != nil, extraValueData: block.extraValueData, writer: writer) {
        if let value = block.item.value {
            try writer.writeID(index: 2, value: value)
        }
    }
}

private func readSceneLineItemBlock(from reader: TaggedBlockReader, version: Int) throws -> SceneLineItemBlock {
    let parsed = try readSceneItemMetadata(from: reader, expectedItemType: 0x03)
    let line = try parsed.valueSubblockInfo != nil ? readLine(from: reader, version: version) : nil
    let extraValueData = try finishValueSubblockIfNeeded(parsed.valueSubblockInfo, reader: reader)
    return SceneLineItemBlock(
        parentID: parsed.parentID,
        item: CrdtSequenceItem(itemID: parsed.itemID, leftID: parsed.leftID, rightID: parsed.rightID, deletedLength: parsed.deletedLength, value: line),
        extraValueData: extraValueData
    )
}

private func writeSceneLineItem(_ block: SceneLineItemBlock, to writer: TaggedBlockWriter) throws {
    let version = (writer.version ?? "9999") > "3.0" ? 2 : 1
    try writeSceneItemMetadata(parentID: block.parentID, itemID: block.item.itemID, leftID: block.item.leftID, rightID: block.item.rightID, deletedLength: block.item.deletedLength, itemType: 0x03, hasValue: block.item.value != nil, extraValueData: block.extraValueData, writer: writer) {
        if let value = block.item.value {
            try writeLine(value, to: writer, version: version)
        }
    }
}

private func readSceneTextItemBlock(from reader: TaggedBlockReader) throws -> SceneTextItemBlock {
    let parsed = try readSceneItemMetadata(from: reader, expectedItemType: 0x05)
    let extraValueData = try finishValueSubblockIfNeeded(parsed.valueSubblockInfo, reader: reader)
    return SceneTextItemBlock(parentID: parsed.parentID, itemID: parsed.itemID, leftID: parsed.leftID, rightID: parsed.rightID, deletedLength: parsed.deletedLength, extraValueData: extraValueData)
}

private func writeSceneTextItem(_ block: SceneTextItemBlock, to writer: TaggedBlockWriter) throws {
    try writeSceneItemMetadata(parentID: block.parentID, itemID: block.itemID, leftID: block.leftID, rightID: block.rightID, deletedLength: block.deletedLength, itemType: 0x05, hasValue: false, extraValueData: block.extraValueData, writer: writer) {}
}

private func readSceneTombstoneItemBlock(from reader: TaggedBlockReader) throws -> SceneTombstoneItemBlock {
    let parsed = try readSceneItemMetadata(from: reader, expectedItemType: 0x00)
    let extraValueData = try finishValueSubblockIfNeeded(parsed.valueSubblockInfo, reader: reader)
    return SceneTombstoneItemBlock(parentID: parsed.parentID, itemID: parsed.itemID, leftID: parsed.leftID, rightID: parsed.rightID, deletedLength: parsed.deletedLength, extraValueData: extraValueData)
}

private func writeSceneTombstoneItem(_ block: SceneTombstoneItemBlock, to writer: TaggedBlockWriter) throws {
    try writeSceneItemMetadata(parentID: block.parentID, itemID: block.itemID, leftID: block.leftID, rightID: block.rightID, deletedLength: block.deletedLength, itemType: 0x00, hasValue: false, extraValueData: block.extraValueData, writer: writer) {}
}

private func readGlyphRange(from reader: TaggedBlockReader) throws -> GlyphRange {
    let start = reader.readIntOptional(index: 2)
    var length = reader.readIntOptional(index: 3)
    let colorID = try reader.readInt(index: 4)
    guard let color = PenColor(rawValue: colorID) else {
        throw RMSceneFormatError.invalidValue("Unknown color \(colorID)")
    }
    let text = try reader.readString(index: 5)
    if length == nil {
        length = text.count
    }
    let subblock = try reader.beginSubblock(index: 6)
    let rectCount = try reader.data.readVarUInt()
    var rectangles: [Rectangle] = []
    rectangles.reserveCapacity(rectCount)
    for _ in 0..<rectCount {
        rectangles.append(Rectangle(
            x: try reader.data.readFloat64(),
            y: try reader.data.readFloat64(),
            w: try reader.data.readFloat64(),
            h: try reader.data.readFloat64()
        ))
    }
    _ = try reader.finishSubblock(subblock)
    let colorRGBA = reader.readColorOptional(index: 10)
    return GlyphRange(start: start, length: length ?? text.count, text: text, color: color, rectangles: rectangles, colorRGBA: colorRGBA)
}

private func writeGlyphRange(_ glyphRange: GlyphRange, to writer: TaggedBlockWriter) throws {
    if let start = glyphRange.start {
        try writer.writeInt(index: 2, value: start)
        try writer.writeInt(index: 3, value: glyphRange.length)
    }
    try writer.writeInt(index: 4, value: glyphRange.color.rawValue)
    try writer.writeString(index: 5, value: glyphRange.text)
    try writer.withSubblock(index: 6) {
        try writer.data.writeVarUInt(glyphRange.rectangles.count)
        for rectangle in glyphRange.rectangles {
            writer.data.writeFloat64(rectangle.x)
            writer.data.writeFloat64(rectangle.y)
            writer.data.writeFloat64(rectangle.w)
            writer.data.writeFloat64(rectangle.h)
        }
    }
    if let colorRGBA = glyphRange.colorRGBA {
        try writer.writeColor(index: 10, value: colorRGBA)
    }
}

private func readRootTextBlock(from reader: TaggedBlockReader) throws -> RootTextBlock {
    let blockID = try reader.readID(index: 1)
    let outer = try reader.beginSubblock(index: 2)

    let textItemsOuter = try reader.beginSubblock(index: 1)
    let textItemsInner = try reader.beginSubblock(index: 1)
    let textItemCount = try reader.data.readVarUInt()
    var textItems: [CrdtSequenceItem<TextItemValue>] = []
    textItems.reserveCapacity(textItemCount)
    for _ in 0..<textItemCount {
        textItems.append(try readTextItem(from: reader))
    }
    _ = try reader.finishSubblock(textItemsInner)
    _ = try reader.finishSubblock(textItemsOuter)

    let formatsOuter = try reader.beginSubblock(index: 2)
    let formatsInner = try reader.beginSubblock(index: 1)
    let formatCount = try reader.data.readVarUInt()
    var formats: [(CrdtID, LWWValue<ParagraphStyle>)] = []
    formats.reserveCapacity(formatCount)
    for _ in 0..<formatCount {
        formats.append(try readTextFormat(from: reader))
    }
    _ = try reader.finishSubblock(formatsInner)
    _ = try reader.finishSubblock(formatsOuter)

    _ = try reader.finishSubblock(outer)

    let positionSubblock = try reader.beginSubblock(index: 3)
    let posX = try reader.data.readFloat64()
    let posY = try reader.data.readFloat64()
    _ = try reader.finishSubblock(positionSubblock)
    let width = try reader.readFloat(index: 4)

    return RootTextBlock(
        blockID: blockID,
        value: Text(items: CrdtSequence(textItems), styles: OrderedMap(formats), posX: posX, posY: posY, width: width)
    )
}

private func writeRootText(_ block: RootTextBlock, to writer: TaggedBlockWriter) throws {
    try writer.writeID(index: 1, value: block.blockID)
    try writer.withSubblock(index: 2) {
        try writer.withSubblock(index: 1) {
            try writer.withSubblock(index: 1) {
                try writer.data.writeVarUInt(block.value.items.sequenceItems().count)
                for item in block.value.items.sequenceItems() {
                    try writeTextItem(item, to: writer)
                }
            }
        }
        try writer.withSubblock(index: 2) {
            try writer.withSubblock(index: 1) {
                try writer.data.writeVarUInt(block.value.styles.count)
                for (key, value) in block.value.styles.orderedPairs {
                    try writeTextFormat(charID: key, value: value, to: writer)
                }
            }
        }
    }
    try writer.withSubblock(index: 3) {
        writer.data.writeFloat64(block.value.posX)
        writer.data.writeFloat64(block.value.posY)
    }
    try writer.writeFloat(index: 4, value: block.value.width)
}

private func readTextItem(from reader: TaggedBlockReader) throws -> CrdtSequenceItem<TextItemValue> {
    let subblock = try reader.beginSubblock(index: 0)
    let itemID = try reader.readID(index: 2)
    let leftID = try reader.readID(index: 3)
    let rightID = try reader.readID(index: 4)
    let deletedLength = try reader.readInt(index: 5)
    let value: TextItemValue
    if reader.hasSubblock(index: 6) {
        let (text, format) = try reader.readStringWithFormat(index: 6)
        if let format {
            value = .formatCode(format)
        } else {
            value = .string(text)
        }
    } else {
        value = .string("")
    }
    _ = try reader.finishSubblock(subblock)
    return CrdtSequenceItem(itemID: itemID, leftID: leftID, rightID: rightID, deletedLength: deletedLength, value: value)
}

private func writeTextItem(_ item: CrdtSequenceItem<TextItemValue>, to writer: TaggedBlockWriter) throws {
    try writer.withSubblock(index: 0) {
        try writer.writeID(index: 2, value: item.itemID)
        try writer.writeID(index: 3, value: item.leftID)
        try writer.writeID(index: 4, value: item.rightID)
        try writer.writeInt(index: 5, value: item.deletedLength)
        switch item.value {
        case let .string(text):
            if !text.isEmpty {
                try writer.writeString(index: 6, value: text)
            }
        case let .formatCode(format):
            try writer.writeStringWithFormat(index: 6, text: "", format: format)
        }
    }
}

private func readTextFormat(from reader: TaggedBlockReader) throws -> (CrdtID, LWWValue<ParagraphStyle>) {
    let charID = try reader.data.readCrdtID()
    let timestamp = try reader.readID(index: 1)
    let subblock = try reader.beginSubblock(index: 2)
    let marker = try reader.data.readUInt8()
    guard marker == 17 else {
        throw RMSceneFormatError.invalidValue("Expected text format marker 17")
    }
    let rawFormat = Int(try reader.data.readUInt8())
    let format = ParagraphStyle(rawValue: rawFormat) ?? .plain
    _ = try reader.finishSubblock(subblock)
    return (charID, LWWValue(timestamp: timestamp, value: format))
}

private func writeTextFormat(charID: CrdtID, value: LWWValue<ParagraphStyle>, to writer: TaggedBlockWriter) throws {
    try writer.data.writeCrdtID(charID)
    try writer.writeID(index: 1, value: value.timestamp)
    try writer.withSubblock(index: 2) {
        writer.data.writeUInt8(17)
        writer.data.writeUInt8(UInt8(value.value.rawValue))
    }
}

private struct ParsedSceneItemMetadata {
    var parentID: CrdtID
    var itemID: CrdtID
    var leftID: CrdtID
    var rightID: CrdtID
    var deletedLength: Int
    var valueSubblockInfo: SubBlockInfo?
}

private func readSceneItemMetadata(from reader: TaggedBlockReader, expectedItemType: Int) throws -> ParsedSceneItemMetadata {
    let parentID = try reader.readID(index: 1)
    let itemID = try reader.readID(index: 2)
    let leftID = try reader.readID(index: 3)
    let rightID = try reader.readID(index: 4)
    let deletedLength = try reader.readInt(index: 5)
    let valueSubblockInfo: SubBlockInfo?
    if reader.hasSubblock(index: 6) {
        let subblock = try reader.beginSubblock(index: 6)
        let itemType = Int(try reader.data.readUInt8())
        guard itemType == expectedItemType else {
            throw RMSceneFormatError.invalidValue("Unexpected scene item type \(itemType), expected \(expectedItemType)")
        }
        valueSubblockInfo = subblock
    } else {
        valueSubblockInfo = nil
    }
    return ParsedSceneItemMetadata(parentID: parentID, itemID: itemID, leftID: leftID, rightID: rightID, deletedLength: deletedLength, valueSubblockInfo: valueSubblockInfo)
}

private func finishValueSubblockIfNeeded(_ subblockInfo: SubBlockInfo?, reader: TaggedBlockReader) throws -> Data {
    guard let subblockInfo else {
        return Data()
    }
    let finished = try reader.finishSubblock(subblockInfo)
    return finished.extraData
}

private func writeSceneItemMetadata(
    parentID: CrdtID,
    itemID: CrdtID,
    leftID: CrdtID,
    rightID: CrdtID,
    deletedLength: Int,
    itemType: Int,
    hasValue: Bool,
    extraValueData: Data,
    writer: TaggedBlockWriter,
    body: () throws -> Void
) throws {
    try writer.writeID(index: 1, value: parentID)
    try writer.writeID(index: 2, value: itemID)
    try writer.writeID(index: 3, value: leftID)
    try writer.writeID(index: 4, value: rightID)
    try writer.writeInt(index: 5, value: deletedLength)
    if hasValue {
        try writer.withSubblock(index: 6) {
            writer.data.writeUInt8(UInt8(itemType))
            try body()
            writer.data.writeBytes(extraValueData)
        }
    }
}

private func uuidFromLittleEndianBytes(_ data: Data) throws -> UUID {
    guard data.count == 16 else {
        throw RMSceneFormatError.invalidValue("Expected UUID length to be 16 bytes")
    }
    let bytes = Array(data)
    let reordered: [UInt8] = [
        bytes[3], bytes[2], bytes[1], bytes[0],
        bytes[5], bytes[4],
        bytes[7], bytes[6],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    ]
    return reordered.withUnsafeBytes { rawBuffer in
        let typed = rawBuffer.bindMemory(to: uuid_t.self)
        return UUID(uuid: typed[0])
    }
}

private func uuidLittleEndianBytes(_ uuid: UUID) -> Data {
    withUnsafeBytes(of: uuid.uuid) { rawBuffer in
        let bytes = Array(rawBuffer)
        return Data([
            bytes[3], bytes[2], bytes[1], bytes[0],
            bytes[5], bytes[4],
            bytes[7], bytes[6],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ])
    }
}
