import Testing
@testable import Uncloud

@MainActor
@Suite("ExportPaneRename")
struct ExportPaneRenameTests {
    @Test("The first pane is Cloud Library, the home screen")
    func defaultPaneIsCloudLibrary() {
        #expect(ExportModel().pane == .export)
    }

    @Test("The panes follow the steps: get photos out, then free up iCloud, with the settings last")
    func panesAreInSidebarOrder() {
        #expect(ExportModel.Pane.allCases == [.export, .browse, .cleanup, .backup])
    }

    @Test("Each pane has its sidebar title")
    func panesHaveTitles() {
        #expect(ExportModel.Pane.allCases.map(\.title) == ["Cloud Library", "Browse Backup", "Delete from iCloud", "Export Settings"])
    }

    @Test("The panes are numbered 1 to 4 in sidebar order for the View menu shortcuts")
    func panesHaveShortcuts() {
        #expect(ExportModel.Pane.allCases.map(\.shortcut) == ["1", "2", "3", "4"])
        #expect(ExportModel.Pane.backup.shortcut == "4")
        #expect(ExportModel.Pane.cleanup.shortcut == "3")
    }

    @Test("Export Settings opens on General")
    func exportSettingsStartsOnGeneral() {
        #expect(ExportModel().exportSettingsSection == .general)
        #expect(ExportModel.ExportSettingsSection.allCases == [.general, .folders])
    }
}
