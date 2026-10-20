import Testing
@testable import Uncloud

@MainActor
@Suite("ExportPaneRename")
struct ExportPaneRenameTests {
    @Test("The first pane is Backup, the home screen")
    func defaultPaneIsBackup() {
        #expect(ExportModel().pane == .backup)
    }
}
