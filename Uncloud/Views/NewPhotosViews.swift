import SwiftUI

/// The idle status line of the Backup pane's card: "1,243 new photos since your last export on 17 Sep." or
/// "Up to date. Last export 17 Sep.". Plain secondary text, like the card's other idle lines.
struct NewPhotosStatusLabel: View {
    let status: NewPhotosStatus

    var body: some View {
        let text = NewPhotosText.statusLine(status, now: .now)
        Label(text, systemImage: status.count == 0 && !status.isAtLeast ? "checkmark.circle" : "photo.badge.plus")
            .foregroundStyle(.secondary)
            .accessibilityLabel(text)
    }
}

extension ExportModel {
    /// The count on the Backup sidebar row while there are new photos. Nil when there are none.
    var newPhotosBadgeText: Text? {
        guard let status = newPhotosStatus, status.count > 0 || status.isAtLeast else { return nil }
        let number = status.count.formatted()
        return Text(status.isAtLeast ? "\(number)+" : number)
    }

    /// Help and VoiceOver hint for the primary button when it exports only the photos not yet backed up.
    var primaryExportHelp: String? {
        offersNewPhotosOnly ? NewPhotosTitle.newOnlyHelp : nil
    }
}

/// Settings › Backups: the new-photo reminder and how often it can appear.
struct NewPhotosReminderSection: View {
    @Bindable var reminder: NewPhotosReminderSettings
    /// False without Uncloud Plus: the reminder is shown off and locked. The count itself stays free.
    var isAllowed = true
    var onGetPlus: () -> Void = {}

    var body: some View {
        Section("New Photo Reminders") {
            Toggle("Remind me about new photos", isOn: Binding(
                get: { isAllowed && reminder.isEnabled },
                set: { value in
                    guard isAllowed else { return }
                    reminder.isEnabled = value
                }
            ))
            .disabled(!isAllowed)
            .help("Checks every 6 hours while Uncloud is running")
            .accessibilityHint("Checks every 6 hours while Uncloud is running")
            Picker("How often", selection: $reminder.frequency) {
                ForEach(NewPhotosReminderFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            .disabled(!reminder.isEnabled || !isAllowed)
            Text("Get a notification when there are new photos and your backup drive isn’t connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isAllowed {
                LockedSettingRow(text: "New photo reminders are part of Uncloud Plus.", action: onGetPlus)
            }
        }
    }
}

/// The line under a locked Settings control: a lock, one sentence, and the way to Uncloud Plus.
struct LockedSettingRow: View {
    let text: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Tokens.Space.s)
            Button("Get Uncloud Plus…", action: action)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
