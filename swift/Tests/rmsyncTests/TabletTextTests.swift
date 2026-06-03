import Foundation
import Testing
@testable import rmsync

@Suite("Tablet text spacing")
struct TabletTextTests {
    @Test("normalization collapses markdown paragraph blank lines")
    func normalizeParagraphSpacing() {
        let source = "# Intro\n\nbody\n\n## Next\n"
        let tablet = TabletText.normalizeForTablet(source)
        #expect(tablet == "# Intro\nbody\n## Next\n")
    }

    @Test("normalization leaves fenced code blank lines alone")
    func preserveFenceSpacing() {
        let source = "before\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nafter\n"
        let tablet = TabletText.normalizeForTablet(source)
        #expect(tablet == "before\n```swift\nlet x = 1\n\nlet y = 2\n```\nafter\n")
    }

    @Test("unchanged tablet text maps back to exact source")
    func unchangedTabletPreservesSource() {
        let source = "## Heading\n\n- item\n\nbody\n"
        let tablet = TabletText.normalizeForTablet(source)
        #expect(
            TabletText.sourceByApplyingTabletEdit(
                baseSource: source,
                editedTablet: tablet
            ) == source
        )
    }

    @Test("tablet append applies without rewriting unrelated spacing")
    func appendPreservesSourceSpacing() {
        let source = "## Heading\n\nbody\n"
        let tablet = TabletText.normalizeForTablet(source) + "new line\n"
        #expect(
            TabletText.sourceByApplyingTabletEdit(
                baseSource: source,
                editedTablet: tablet
            ) == "## Heading\n\nbody\nnew line\n"
        )
    }

    @Test("tablet line edit preserves paragraph spacing around edited text")
    func lineEditPreservesParagraphSpacing() {
        let source = "# Intro\n\nbody\n"
        let edited = "# Intro\nchanged\n"
        #expect(
            TabletText.sourceByApplyingTabletEdit(
                baseSource: source,
                editedTablet: edited
            ) == "# Intro\n\nchanged\n"
        )
    }
}
