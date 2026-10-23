import Testing
@testable import Uncloud

@MainActor
@Suite("ExportPaneRename")
struct ExportPaneRenameTests {
    @Test("The first pane is Cloud Library, the home screen")
    func defaultPaneIsCloudLibrary() {
        #expect(ExportModel().pane == .export)
    }

    @Test("The panes are in sidebar order, with Tools before Delete from iCloud")
    func panesAreInSidebarOrder() {
        #expect(ExportModel.Pane.allCases == [.export, .backup, .browse, .tools, .cleanup])
    }

    @Test("Each pane has its sidebar title")
    func panesHaveTitles() {
        #expect(ExportModel.Pane.allCases.map(\.title) == ["Cloud Library", "Export Settings", "Browse Backup", "Tools", "Delete from iCloud"])
    }

    @Test("The panes are numbered 1 to 5 for the View menu shortcuts")
    func panesHaveShortcuts() {
        #expect(ExportModel.Pane.allCases.map(\.shortcut) == ["1", "2", "3", "4", "5"])
    }

    @Test("Export Settings opens on General")
    func exportSettingsStartsOnGeneral() {
        #expect(ExportModel().exportSettingsSection == .general)
        #expect(ExportModel.ExportSettingsSection.allCases == [.general, .folders])
    }
}
