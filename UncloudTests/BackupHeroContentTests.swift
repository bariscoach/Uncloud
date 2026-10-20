import Foundation
import Testing
@testable import Uncloud

/// One test per row of the Backup hero's table, and the precedence between rows.
@Suite("BackupHeroContent")
struct BackupHeroContentTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// Three days before `now`, which the hero words as "3 days ago".
    private static let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!

    /// A hero for the given state. Everything not named is the quiet default: a folder is chosen and nothing is waiting.
    private func make(
        phase: ExportModel.Phase = .idle,
        hasDestination: Bool = true,
        hasAutoResume: Bool = false,
        offersResumeExport: Bool = false,
        failedCount: Int = 0,
        newPhotos: NewPhotosStatus? = nil,
        lastExport: Date? = nil,
        readySummary: String? = nil,
        fraction: Double? = nil,
        notBackedUpCount: Int? = nil,
        source: LibrarySource = .iCloud
    ) -> BackupHeroContent {
        BackupHeroContent.make(
            phase: phase,
            hasDestination: hasDestination,
            hasAutoResume: hasAutoResume,
            offersResumeExport: offersResumeExport,
            failedCount: failedCount,
            newPhotos: newPhotos,
            lastExport: lastExport,
            readySummary: readySummary,
            fraction: fraction,
            notBackedUpCount: notBackedUpCount,
            source: source,
            now: Self.now
        )
    }

    private func newPhotos(_ count: Int, isAtLeast: Bool = false) -> NewPhotosStatus {
        NewPhotosStatus(count: count, isAtLeast: isAtLeast, since: Self.threeDaysAgo)
    }

    // MARK: - Rows 1 to 11

    @Test func row1PreparingIsExporting() {
        let content = make(phase: .preparing)
        #expect(content == BackupHeroContent(kind: .exporting, symbol: "arrow.down.circle", title: "Getting ready…", subtitle: nil, tone: .accent))
    }

    @Test func row1RunningIsExporting() {
        let content = make(phase: .running)
        #expect(content == BackupHeroContent(kind: .exporting, symbol: "arrow.down.circle", title: "Exporting…", subtitle: nil, tone: .accent))
    }

    @Test func row1RunningShowsThePercentWhenKnown() {
        let content = make(phase: .running, fraction: 0.42)
        #expect(content.title == "Exporting… 42%")
        #expect(content.kind == .exporting)
    }

    @Test func row1PausedIsExportingNeutral() {
        let content = make(phase: .paused)
        #expect(content == BackupHeroContent(kind: .exporting, symbol: "pause.circle", title: "Export paused", subtitle: nil, tone: .neutral))
    }

    @Test func row1CancellingIsExportingNeutral() {
        let content = make(phase: .cancelling)
        #expect(content == BackupHeroContent(kind: .exporting, symbol: "xmark.circle", title: "Stopping…", subtitle: nil, tone: .neutral))
    }

    @Test func row2WaitingToResume() {
        let content = make(hasAutoResume: true)
        #expect(content == BackupHeroContent(kind: .waiting, symbol: "clock", title: "Waiting to resume", subtitle: nil, tone: .warning))
    }

    @Test func row2WaitingToResumeShowsTheTimeWhenKnown() {
        let resumeAt = Self.now.addingTimeInterval(14 * 60)
        let content = BackupHeroContent.make(
            phase: .idle, hasDestination: true, hasAutoResume: true, offersResumeExport: false, failedCount: 0,
            newPhotos: nil, lastExport: nil, readySummary: nil, resumeAt: resumeAt, now: Self.now
        )
        #expect(content.title == "Waiting to resume")
        #expect(content.subtitle == "Resumes at \(ExportModel.resumeTimeText(resumeAt)).")
    }

    @Test func row2WaitingForTheDriveAsksToConnectIt() {
        let content = BackupHeroContent.make(
            phase: .idle, hasDestination: true, hasAutoResume: true, offersResumeExport: false, failedCount: 0,
            newPhotos: nil, lastExport: nil, readySummary: nil, resumeAt: Self.now, isWaitingForDestination: true, now: Self.now
        )
        #expect(content.title == "Waiting to resume")
        #expect(content.subtitle == "Connect your backup drive to continue.")
    }

    @Test func row3InterruptedRunOffersResume() {
        let content = make(offersResumeExport: true)
        #expect(content == BackupHeroContent(kind: .interrupted, symbol: "arrow.clockwise.circle", title: "Your last export didn’t finish", subtitle: nil, tone: .warning))
    }

    @Test func row4WithoutFolderChoosesOne() {
        let content = make(hasDestination: false)
        #expect(content == BackupHeroContent(
            kind: .needsFolder, symbol: "externaldrive.badge.plus", title: "Choose a backup folder",
            subtitle: "Pick a folder on your external drive.", tone: .accent
        ))
    }

    @Test func row5CompletedWithFailuresFinishedWithProblems() {
        let content = make(phase: .completed, failedCount: 2)
        #expect(content == BackupHeroContent(kind: .finishedWithProblems, symbol: "exclamationmark.triangle", title: "Some photos weren’t exported", subtitle: nil, tone: .warning))
    }

    @Test func row6FailedIsStopped() {
        let content = make(phase: .failed("Disk full"))
        #expect(content == BackupHeroContent(kind: .stopped, symbol: "xmark.octagon", title: "Export stopped", subtitle: nil, tone: .danger))
    }

    @Test func row7CancelledIsCancelled() {
        let content = make(phase: .cancelled)
        #expect(content == BackupHeroContent(kind: .cancelled, symbol: "xmark.circle", title: "Export cancelled", subtitle: nil, tone: .neutral))
    }

    @Test func row8NewPhotosSaysHowManySinceLastExport() {
        let content = make(newPhotos: newPhotos(1_243))
        #expect(content == BackupHeroContent(
            kind: .newPhotos, symbol: "photo.badge.plus", title: "1,243 new photos",
            subtitle: "Since your last export 3 days ago.", tone: .accent
        ))
    }

    @Test func row8AtLeastShowsAPlus() {
        let content = make(newPhotos: newPhotos(5_000, isAtLeast: true))
        #expect(content.kind == .newPhotos)
        #expect(content.title == "5,000+ new photos")
    }

    @Test func row8SingularPhoto() {
        let content = make(newPhotos: newPhotos(1))
        #expect(content.title == "1 new photo")
    }

    @Test func row9NoNewPhotosIsUpToDate() {
        let content = make(newPhotos: newPhotos(0))
        #expect(content == BackupHeroContent(kind: .upToDate, symbol: "checkmark.circle", title: "Your backup is up to date", subtitle: "Last export 3 days ago.", tone: .success))
    }

    @Test func row9bNoNewPhotosButPhotosMissingIsNotBackedUp() {
        let content = make(newPhotos: newPhotos(0), notBackedUpCount: 298)
        #expect(content == BackupHeroContent(
            kind: .notBackedUp, symbol: "exclamationmark.circle", title: "298 photos aren’t backed up",
            subtitle: "Older photos that weren’t exported. Check Whole Library exports them.", tone: .warning
        ))
    }

    @Test func row9bSinglePhotoIsNotBackedUp() {
        let content = make(newPhotos: newPhotos(0), notBackedUpCount: 1)
        #expect(content.kind == .notBackedUp)
        #expect(content.title == "1 photo isn’t backed up")
    }

    @Test func row9bNoneMissingIsStillUpToDate() {
        #expect(make(newPhotos: newPhotos(0), notBackedUpCount: 0).kind == .upToDate)
        #expect(make(newPhotos: newPhotos(0), notBackedUpCount: nil).kind == .upToDate)
    }

    @Test func row9bNewPhotosWinOverMissingPhotos() {
        let content = make(newPhotos: newPhotos(3), notBackedUpCount: 298)
        #expect(content.kind == .newPhotos)
    }

    @Test func row9bWithoutAWatermarkMissingPhotosDoNotApply() {
        let content = make(readySummary: "9,207 backed up · 298 to go", notBackedUpCount: 298)
        #expect(content.kind == .ready)
    }

    @Test func row9bPhotosLibraryNamesTheExportInsteadOfTheCheck() {
        let content = make(newPhotos: newPhotos(0), notBackedUpCount: 298, source: .photosLibrary)
        #expect(content.kind == .notBackedUp)
        #expect(content.subtitle == "Older photos that weren’t exported. Export All Photos picks them up.")
    }

    @Test func row10CompletedIsExportComplete() {
        let content = make(phase: .completed, lastExport: Self.threeDaysAgo)
        #expect(content == BackupHeroContent(kind: .complete, symbol: "checkmark.circle", title: "Export complete", subtitle: "Last export 3 days ago.", tone: .success))
    }

    @Test func row10CompletedWithoutADateHasNoSubtitle() {
        let content = make(phase: .completed)
        #expect(content.subtitle == nil)
        #expect(content.title == "Export complete")
    }

    @Test func row11OtherwiseIsReadyWithTheDriveSummary() {
        let content = make(readySummary: "0 already on this drive · 93,015 to go")
        #expect(content == BackupHeroContent(
            kind: .ready, symbol: "arrow.down.circle", title: "Ready to export",
            subtitle: "0 already on this drive · 93,015 to go", tone: .accent
        ))
    }

    // MARK: - Precedence

    @Test func interruptedRunWinsOverNewPhotos() {
        let content = make(offersResumeExport: true, newPhotos: newPhotos(1_243))
        #expect(content.kind == .interrupted)
    }

    @Test func pausedExportWinsOverNewPhotos() {
        let content = make(phase: .paused, newPhotos: newPhotos(1_243))
        #expect(content.kind == .exporting)
        #expect(content.title == "Export paused")
    }

    @Test func waitingToResumeWinsOverInterrupted() {
        let content = make(hasAutoResume: true, offersResumeExport: true)
        #expect(content.kind == .waiting)
    }

    @Test func missingFolderWinsOverNewPhotos() {
        let content = make(hasDestination: false, newPhotos: newPhotos(1_243))
        #expect(content.kind == .needsFolder)
    }

    @Test func completedWithNewPhotosShowsNewPhotos() {
        let content = make(phase: .completed, newPhotos: newPhotos(3))
        #expect(content.kind == .newPhotos)
    }
}
