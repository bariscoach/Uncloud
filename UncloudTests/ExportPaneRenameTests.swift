import Testing
@testable import Uncloud

@MainActor
@Suite("ExportPaneRename")
struct ExportPaneRenameTests {
    @Test("The first pane is Export, the photo grid")
    func defaultPaneIsExport() {
        #expect(ExportModel().pane == .export)
    }
}
