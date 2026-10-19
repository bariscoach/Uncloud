# Uncloud polish plan: calmer, simpler, easier

Status: audit and plan only. No Swift code was changed. Author: design lead (Opus), 2026-10-18.
Branch: `feature/duplicates-and-icloud-cleanup` (f607a2c, v0.1.7).

Owner's request: "make the app look more chic, more modern UI, simplified terms, messages, menu usage, ease of use."

This builds on `.claude/design/ui-refresh-plan.md`, which already shipped `DesignTokens.swift`, `BackupHero`, the sky-blue
accent, window titles and subtitles, toolbar grouping with `ToolbarSpacer`, the glass Export Started banner and the
calmer Clean Up toolbar. This pass doesn't undo any of that. It finishes the job: it **removes** things, and it
**rewords** everything to one vocabulary. Those were the two things the first plan put out of scope ("No copy rewrites").

---

## 1. Design direction

1. **One thing per screen.** Every pane and sheet has one prominent button, and the status line above it says why.
   Everything else is quieter: bordered, in a menu, or in `.help`.
2. **Colour means status.** Colour is for the accent (the primary action, progress) and the four status tones. Places and
   sections don't get colour. The rainbow of section tiles goes; sidebar rows use plain SF Symbols, as Finder and Mail do.
3. **Fewer boxes.** Use grouped `Form` sections for structure, and nothing inside them. No `GroupBox` inside a `Form`, no
   `info.circle` in front of grey helper text, no caption under every button. A caption that explains a control becomes
   its `.help` and `.accessibilityHint`.
4. **Confident type, plenty of space.** Hero title `.title` semibold, one secondary line, 24 pt between sections. Helper
   text is `.callout` secondary. Metadata is `.caption`. Nothing else.
5. **Say it once, in the user's words.** One term per concept (section 2). Messages are a short sentence plus the next
   step, with no internals (no icloudpd, bridge, session, checksum, set-aside, item or destination).
6. **Status is sentence case, commands are title case.** Hero titles, status lines and toggles use sentence case ("Your
   backup is up to date"), as Software Update does. Buttons, menu items, window, sheet and dialog titles, and empty-state
   titles use title case.
7. **Glass for controls, never for content.** On macOS 26 and later, transient banners float on glass. Content stays on
   the window background. Everything is behind `#available(macOS 26, *)`, with the macOS 14 look kept.
8. **Safe, not scary.** Every destructive flow keeps exactly its current gate (typed number, two confirmations, Cancel as
   the cancel action, Return never deletes). Only the wording gets shorter and calmer.

---

## 2. Glossary: one term per concept

| Concept | Use (UI) | Retire from UI |
|---|---|---|
| Where photos are saved | **backup folder**. In sentences: "your backup folder", or the drive's name in curly quotes ("“Archive”"). Section header: **Backup Folder**. Menu: **Choose Backup Folder…** | destination, export folder, "the folder you chose", "Save To", "this folder" (when it means the backup), volume |
| The physical disk | **drive** / **backup drive**, only for connecting and free space ("Connect “Archive”", "1.2 TB free") | disk, volume, "destination drive" |
| What's on the drive | **backup** (noun) | "on this drive", "already there", "in the destination" |
| The action | **Export** (verb and noun: Export, exported, an export) | download / downloaded, copy / copied (except duplicate *copies*), back up (verb), re-export |
| The feature that runs on its own | **automatic backups** (noun) | "automatic backup" as a verb phrase |
| A photo or video | **photo / photos**. "photos and videos" only in Getting Started | item / items / Item / Items, asset, media |
| Saved on the drive | **backed up / not backed up** | exported (as a state), on the drive, recorded, registered, tracked, untracked |
| Source: iCloud | **iCloud Photos** | iCloud library |
| Source: local | **Photos on This Mac** (in sentences: "Photos on this Mac") | Photos Library on This Mac, photo library, Photos library, the library on this Mac |
| Apple's account | **Apple Account** (Apple's name since 2024) | Apple ID |
| Being signed in | **sign-in** ("Your iCloud sign-in has expired") | session, authentication token, two-factor authentication (say **verification code**) |
| An unfinished run | "**didn't finish**"; button **Resume Export** | interrupted, incomplete, "Choose Resume", "continue later" |
| One try inside an export | **run** (Run 1, Run 2) | attempt, chain |
| Quick recount of the drive | **Check Now** (drive row); results sheet **Check Results** | Check Drive, Drive Check, scan, Quick check / Full check |
| Full integrity check | **Verify Backup** | checksum (in UI), "Check Backup" |
| Folder for damaged files | **a separate folder** / **Damaged Files** | set-aside, set aside, moved aside |
| Deleting from iCloud | pane **Clean Up iCloud**; action **Delete from iCloud…**; undo **Recover** | "a clean up", "Clean Up" alone, restore, deletions (except "Apple is limiting deletions") |
| Diagnostic transcripts | **diagnostic logs** | helper, transcript |
| Organisation on disk | **Folders** (header), the options keep their titles (By Month, …) | Folder layout, Folders and Files |
| Spelling | US English (organized, favorites). One exception: keep "Cancelled", which is already used everywhere in the app; don't mix it with "Canceled" | Organised |
| Our account | **Uncloud account** ("Sign Out of Uncloud…", "Delete Your Uncloud Account?") | "profile", "login", "user" |
| Apple's account | **Apple Account** (unchanged) | Apple ID, iCloud account |
| The paid plan | **Uncloud Plus**; the free plan **Free** | Pro, Premium, subscription tier |
| Stripe's page | **the billing page** (in sentences); button **Manage Subscription…** | Stripe portal, customer portal |

Rules:
- Use `^[\(n) photo](inflect: true)` in `Text`, or a `photos(_:)` helper for runtime strings (chunk 1 adds `Plural.photos(n)`).
- Quote names with curly quotes “ ”, and use curly apostrophes everywhere (`SessionRecorder.swift:183` uses a straight `'`).
- Menu paths use › ("Help › Show Diagnostic Logs in Finder"), not ">".
- An ellipsis only when the command asks for more before it acts (opens a picker, a confirmation or a sheet whose own button does the work). "Getting Started", "How It Works" and "Find Photos" lose theirs.
- Marketing text never leads with an Apple trademark, never uses "Sign In with Apple" wording (that is Apple's own
  feature), and uses "iCloud" and "Photos" only descriptively.

---

## 3. String changes

Line numbers are at f607a2c. **T** means a test asserts this string (section 6 lists the files). Rows marked
"remove" delete the string (its information moves elsewhere, as noted).

### 3.1 Menus and commands

| File:line | Current | New |
|---|---|---|
| App/ExportCommands.swift:12 | Choose Export Folder… | Choose Backup Folder… |
| App/ExportCommands.swift:21 | Sign Out of iCloud… | Sign Out of iCloud… when signed in, otherwise **Sign In to iCloud…** (same slot) |
| App/ExportCommands.swift:43 | Browse Backup ⌘4 | Browse Backup **⌘3** (moves above Clean Up iCloud) |
| App/ExportCommands.swift:38 | Clean Up iCloud ⌘3 | Clean Up iCloud **⌘4** |
| App/ExportCommands.swift:51 | CommandMenu("Export") | CommandMenu("**Backup**") (section 4) |
| App/ExportCommands.swift:68 | Resume / Pause | Resume Export / Pause Export |
| App/ExportCommands.swift:115 | Getting Started… | Getting Started |
| App/ExportCommands.swift:122 | Show Diagnostic Logs | Show Diagnostic Logs in Finder |
| Views/MenuBarContent.swift:41 | Waiting for the backup drive to resume | Waiting for your backup drive |
| Views/MenuBarContent.swift:42 | Resuming at \(time) | Resumes at \(time) |
| Views/MenuBarContent.swift:45 | Last backup: \(relative) | Last export \(relative) |
| Views/MenuBarContent.swift:47 | No backups yet | Not exported yet |
| Views/MenuBarContent.swift (new, before :44) | — | "Your last export didn’t finish" when `offersResumeExport`; `NewPhotosText.statusLine(…)` when there are new photos |

### 3.2 Window, sidebar, Library, landing, onboarding, sign-in, Settings

| File:line | Current | New |
|---|---|---|
| Views/LibraryWindow.swift:100 | Uncloud forgets this Apple ID and its saved password. Files already in your folder aren’t changed. | Uncloud forgets this Apple Account and its saved password. Your backup isn’t changed. |
| Views/LibraryWindow.swift:109 | Export started. Track its progress in Backup. | Export started. Progress is in Backup. |
| Views/LibraryWindow.swift:169 | Picker "Source" | Picker "Photos From" |
| Views/LibraryWindow.swift:212 | Source and account, \(title), \(subtitle) | Photos from \(title), \(subtitle) |
| Views/LibraryWindow.swift:213 | Switch source or change the iCloud account | Choose where photos come from, or change the iCloud account |
| Views/LibraryWindow.swift:238 | Ready / Access needed | Ready / Needs access |
| Views/LibraryWindow.swift:274–291 | Export started / Track its progress in Backup. / Show Backup / Dismiss | remove: the banner goes (section 5.2). The announcement at :109 stays |
| Views/LibraryView.swift:33 | All \(n) items selected | All \(n) photos selected |
| Views/LibraryView.swift:48–58 | Menu "Select" › Select All / Deselect All, help "Select or deselect every item" | One button: **Select All** (when not everything is selected), else **Deselect All**. No help needed |
| Views/LibraryView.swift:79 | Waiting to resume | Waiting to Resume (a button label) |
| Views/LibraryView.swift:83 | The export resumes automatically. Show Backup for details. | Resumes on its own. Click to see why. |
| Views/LibraryView.swift:188 | Reading your library… | Loading your library… |
| Views/LandingView.swift:44 | iCloud Photos, Straight to Your Drive | Your Photos, on Your Own Drive |
| Views/LandingView.swift:47 | Full-size originals stream from iCloud onto your external drive. Nothing is saved on your Mac first. | Full-size originals go from iCloud straight to your external drive, without filling up your Mac. |
| Views/LandingView.swift:59 | Sign In with Apple ID… | Sign In to iCloud… |
| Views/LandingView.swift:68 | Use the Photos Library on This Mac | Use Photos on This Mac |
| Views/LandingView.swift:75 | Downloads may pass through the Photos library on this Mac first. | Photos may download to this Mac first. |
| Views/LandingView.swift:89 | Your Apple ID password goes only to Apple. | Your password goes only to Apple. |
| Views/LandingView.swift:91 | Learn More… | How It Works |
| Views/BenefitsCarousel.swift:212 | Organised Your Way | Organized Your Way |
| Views/BenefitsCarousel.swift:213 | …With the Photos library on this Mac, by place too. | …With Photos on this Mac, by place too. |
| Views/BenefitsCarousel.swift:227 | Saves a checksum for every file so you can verify your backup any time, and exports on its own when your drive connects. | Records every file so Verify Backup can prove it’s intact, and exports on its own when your drive connects. |
| Views/BenefitsCarousel.swift:228 | A checksum for every file. Exports when your drive connects. | Verified files. Exports when your drive connects. |
| Views/BenefitsCarousel.swift:271 | Your photos go straight to your own folder or drive. Your Apple ID password goes only to Apple, through icloudpd, the open-source tool inside Uncloud, and is kept in your Keychain only if you choose. | Your photos go straight to your own drive. Your password goes only to Apple, through icloudpd, the open-source tool built into Uncloud, and is saved in your keychain only if you choose. |
| Views/BenefitsCarousel.swift:283 | Learn More… | How It Works |
| Views/HowItWorksSteps.swift:17 | Use your Apple ID, or the Photos library on this Mac. | Use your Apple Account, or Photos on this Mac. |
| Views/HowItWorksSteps.swift:30 | Pick a Drive | Choose a Drive |
| Views/GettingStartedView.swift:26 | …share them from Help > Show Diagnostic Logs. | …share them from Help › Show Diagnostic Logs in Finder. |
| Views/PhotosAccessView.swift:9 | Photo Library Access Needed | Allow Access to Photos |
| Views/PhotosAccessView.swift:12 | Access to the photo library is restricted on this Mac, possibly by a configuration profile. Contact your administrator. | Access to Photos is restricted on this Mac, possibly by your organization. Contact your administrator. |
| Views/PhotosAccessView.swift:14 | Uncloud needs permission to read your photo library. Turn it on in System Settings under Privacy & Security. | Uncloud needs access to Photos to export your library. Turn it on in System Settings › Privacy & Security › Photos. |
| Views/PhotosAccessView.swift:17, :43 | Open Settings | Open System Settings |
| Views/PhotosAccessView.swift:38 | Only the items you’ve allowed will be exported. To export your whole library, allow full access in System Settings. | Only the photos you’ve allowed are exported. To export everything, allow full access in System Settings. |
| Views/ICloudSignInSheet.swift:34 | Enter the 6-digit code shown on your Apple devices. | Enter the 6-digit code shown on your other devices. |
| Views/ICloudSignInSheet.swift:59 | TextField "Apple ID" | "Apple Account" (prompt: "Email or phone number") |
| Views/ICloudSignInSheet.swift:64 | Remember password in Keychain | Remember my password |
| Views/ICloudSignInSheet.swift:65 | Lets automatic backups sign in again on their own. If it’s off, you’ll be asked for your password when the sign-in expires (about every two months). | Saved in your keychain, so automatic backups can sign in on their own. Otherwise you’re asked again about every two months. |
| Views/ICloudSignInSheet.swift:72 | Your Apple ID and password are sent only to Apple, through icloudpd, the open-source tool built into this app. Two-factor authentication works as usual. | Your password goes only to Apple, through icloudpd, the open-source tool built into Uncloud. |
| Views/SettingsView.swift:15 | Back up when the destination drive is connected | Export when the backup drive is connected |
| Views/SettingsView.swift:17 | Back up once a day | Export once a day |
| Views/SettingsView.swift:20 | Save To | Backup folder |
| Views/SettingsView.swift:22 | No folder chosen | None |
| Views/SettingsView.swift:26 | Choose Folder… / Change Folder… | Choose… / Change… |
| Views/SettingsView.swift:51 | The menu bar item appears while automatic backup is on. | Shown while automatic backups are on. |
| Views/SettingsView.swift:61–62 | Last backup: \(last). While automatic backup is on, Uncloud keeps running in the menu bar after you close its window. ("none yet") | Last export: \(last). While automatic backups are on, Uncloud keeps running in the menu bar. ("never") |
| Views/NewPhotosViews.swift:27 | Copies new photos, and any missing from the folder. Photos already there are skipped. | Exports new photos, and any missing from your backup. |
| Views/NewPhotosViews.swift:39 | Picker "Remind me" | "How often" |
| Views/NewPhotosViews.swift:45 | A notification when photos have been added to your library since your last export and your backup drive isn’t connected. Uncloud checks every six hours while it runs, which automatic backup or the menu bar keeps it doing. | Get a notification when there are new photos and your backup drive isn’t connected. |

### 3.3 Backup pane, hero, progress, drive check, history

| File:line | Current | New |
|---|---|---|
| Views/BackupPane.swift:20 | Choose where your photos come from first: iCloud or the Photos library on this Mac. | Sign in to iCloud or choose Photos on This Mac first. |
| Views/BackupPane.swift:65 | SectionTitle "Save To" (teal tile) | header "Backup Folder" (no tile) |
| Views/BackupPane.swift:69 | Picker "Folder layout" | "Folders" (pop-up menu, section 5.1) |
| Views/BackupPane.swift:97 | Place names come from each photo’s location, which is sent to Apple to look up the city and country. Photos without a location go in “Unknown Location”. | Place names come from each photo’s location, which Apple looks up. Photos without one go in “Unknown Location”. |
| Views/BackupPane.swift:103 | Each album is saved in its own folder. Photos that aren’t in any album aren’t included. | Each album gets its own folder. Photos that aren’t in an album aren’t exported. |
| Views/BackupPane.swift:104 | Items in more than one album are saved in each album’s folder. On drives formatted as APFS the extra copies take no additional space. | Photos in several albums are saved in each one. On APFS drives the extra copies use no extra space. |
| Views/BackupPane.swift:125 | Save metadata files (.xmp) | Save XMP metadata files |
| Views/BackupPane.swift:127 | Adds a small file next to each item with its albums, favorite status, location and dates, which apps like Lightroom can read. Titles, captions, keywords and people aren’t available to other apps, so they can’t be included. | Adds a small file beside each photo with its albums, favorites, location and dates, for apps like Lightroom. (The second sentence moves to the toggle's `.help`.) |
| Views/BackupPane.swift:131 | Folders and Files | Folders |
| Views/BackupPane.swift:138 | Backup Tools | Tools |
| Views/BackupPane.swift:177 | About \(size) still to copy | About \(size) still to export |
| Views/BackupPane.swift:225 | No folder chosen | No backup folder chosen |
| Views/BackupHero.swift:47 **T** | Preparing Export… | Getting ready… |
| Views/BackupHero.swift:51 **T** | Export Paused | Export paused |
| Views/BackupHero.swift:53 **T** | Cancelling… | Stopping… |
| Views/BackupHero.swift:59 **T** | Waiting to Resume | Waiting to resume |
| Views/BackupHero.swift:62 **T** | Your Last Export Didn’t Finish | Your last export didn’t finish |
| Views/BackupHero.swift:66–67 | Choose Where to Save / Pick a folder on your external drive to start. | Choose a backup folder / Pick a folder on your external drive. |
| Views/BackupHero.swift:71 **T** | Finished with Problems | Some photos weren’t exported |
| Views/BackupHero.swift:74 **T** | Export Stopped | Export stopped |
| Views/BackupHero.swift:77 **T** | Export Cancelled | Export cancelled |
| Views/BackupHero.swift:88 **T** | Up to Date | Your backup is up to date |
| Views/BackupHero.swift:92 **T** | Export Complete | Export complete |
| Views/BackupHero.swift:95 | Ready to Export | Ready to export |
| Views/BackupHero.swift:49 | Exporting… | Exporting… 42% (percent appended while running; the card's big percentage goes) |
| Views/ProgressCard.swift:37 | \(n) of ^[\(total) item] | \(n) of ^[\(total) photo] |
| Views/ProgressCard.swift:76 | Start New Export | Start Over |
| Views/ProgressCard.swift:142 | Your last export stopped before it finished — 120 of 500 copied. Choose Resume Export to continue where it left off. | 120 of 500 photos exported. Resume to pick up where it left off. (no icon) |
| Views/ProgressCard.swift:156 | Everything is already \(verb) to this folder. | Everything is backed up. |
| Views/ProgressCard.swift:159, :162 | \(summary). / Ready to export. | remove (the hero says it) |
| Views/ProgressCard.swift:166, :169, :172, :175, :181 | Preparing… / Exporting… / Paused / Cancelling… / Export complete | remove (the hero title says it; no duplicate status line) |
| Views/ProgressCard.swift:178 | Finished, but N item(s) couldn’t be \(verb). See Activity for details. | N photos couldn’t be exported. Details are in History. |
| Views/ProgressCard.swift:187 | Export cancelled. You can resume it later. | You can resume it later. |
| Views/ProgressCard.swift:219 | the backup drive | your backup drive |
| Views/ProgressCard.swift:220 **T** | \(reason). Uncloud resumes automatically when \(name) is connected. | \(reason). Resumes when \(name) is connected. |
| Views/ProgressCard.swift:224 | \(reason). Resuming automatically… | \(reason). Resuming… |
| Views/ProgressCard.swift:229 **T** | \(reason). Resuming automatically at \(t) (in \(n)). | \(reason). Resumes at \(t) (in \(n)). |
| Views/CheckDriveViews.swift:24 | Checking your drive… | Checking your backup… |
| Views/CheckDriveViews.swift:53 | Check Drive | Check Now |
| Views/CheckDriveViews.swift:55 | Finds missing and damaged files. Damaged files are moved aside, never deleted. | Finds missing and damaged files. Damaged files are moved to a separate folder, never deleted. |
| Views/CheckDriveViews.swift (new) | (no sheet title) | sheet title **Check Results** |
| Views/CheckDriveViews.swift:86–87 | Scope: Every file / Folders that changed | remove the row (shown in Session Detail only) |
| Views/CheckDriveViews.swift:89–92 | Status: [About] X already on this drive · Y to go | Backed up: [about] X · Y to go |
| Views/CheckDriveViews.swift:104 | Everything on the drive is in order. | Everything looks good. |
| Views/CheckDriveViews.swift:115 | N items are missing | N photos are missing |
| Views/CheckDriveViews.swift:120 | They’ll be \(verb) again on the next export. | They’ll be exported again next time. |
| Views/CheckDriveViews.swift:132 | N files are empty or changed size | N files are damaged |
| Views/CheckDriveViews.swift:141 | Show Set-Aside Folder | Show Damaged Files in Finder |
| Views/CheckDriveViews.swift:144 | Show Damaged Files | List Damaged Files |
| Views/CheckDriveViews.swift:147 | N couldn’t be moved aside. They stay where they are, isn’t \(verb) again, and is checked again next time. (grammar bug) | N couldn’t be moved and were left in place. They’re checked again next time. |
| Views/CheckDriveViews.swift:163 | N files changed size | N other files changed |
| Views/CheckDriveViews.swift:168 | Uncloud can’t tell it saved these, so it left them as they are. | They may not be Uncloud’s, so they were left alone. |
| Views/CheckDriveViews.swift:180 | N files were recorded | N files recognized |
| Views/CheckDriveViews.swift:185 | These were at the paths iCloud uses, with no record. Their checksums are added during the next export. | These were already in your backup folder. Verify Backup can check them after the next export. |
| Views/CheckDriveViews.swift:188 / :190 | Show Recorded Files / Registered | Show Files / Recognized |
| Views/CheckDriveViews.swift:213 | N unfinished downloads, N partly downloaded items | N unfinished files |
| Views/CheckDriveViews.swift:218 | Partial downloads don’t count as on the drive, so they’ll be downloaded again. | They’ll be exported again next time. |
| Views/CheckDriveViews.swift:222 | Partial Downloads | Unfinished |
| Views/CheckDriveViews.swift:245 | They’ll be moved aside and \(verb) again when you export or choose Check Drive. | They’ll be moved to a separate folder and exported again next time. |
| Views/CheckDriveViews.swift:248 | Moved to the set-aside folder, never deleted. Their items will be \(verb) again. | Moved to a separate folder, never deleted. They’ll be exported again. |
| Views/BackupToolSheets.swift:47, :57, :68 | three captions | remove; each becomes `.help` + `.accessibilityHint`: "Checks that every file is intact." / "Finds photos saved more than once." / "Removes photos from this Mac that are safely backed up." |
| Views/ExportHistoryView.swift:20 | No exports to this drive yet. | No exports yet. |
| Views/ExportHistoryView.swift:30 | Shows each attempt in this export. | Shows details. |
| Views/ExportHistoryView.swift:34 | Export History (indigo tile) | header "History" (no tile) |
| Views/ExportHistoryView.swift:37 | Show History in Finder | Show in Finder (footer stays, `.link` style) |
| Views/ExportHistoryView.swift:178 | Resumed 1 time / Resumed N times | Resumed once / Resumed N times |
| Views/ExportHistoryView.swift:181 | From a newer Uncloud | From a newer version |
| Views/ExportSessionDetailView.swift:61 | Items | Photos |
| Views/ExportSessionDetailView.swift:67 | Attempts | Runs |
| Views/ExportSessionDetailView.swift:86 | Outcome | Result |
| Views/ExportSessionDetailView.swift:90 | Exported / Downloaded | Exported |
| Views/ExportSessionDetailView.swift:94 | Already there | Already backed up |
| Views/ExportSessionDetailView.swift:99 | Failed | Not exported |
| Views/ExportSessionDetailView.swift:109 / :112 | Source / Layout | From / Folders |
| Views/ExportSessionDetailView.swift:116, :118 | Drive Check / X already on this drive · Y to go | Drive check / X backed up · Y to go |
| Views/ExportSessionDetailView.swift:128 | Continued | Picked up |
| Views/ExportSessionDetailView.swift:140 | Uncloud Version | App version |
| Views/ExportSessionDetailView.swift:177 | N items couldn’t be \(verb) | N photos couldn’t be exported |
| Views/ExportSessionDetailView.swift:180 | Failed Items (N) | Not Exported (N) |
| Views/ExportSessionDetailView.swift:186 | Attempt N | Run N |
| Views/ExportSessionDetailView.swift:195–199 | Started by hand / Export All / Automatic backup / Automatic resume / Resumed by hand | Started by you / Export All / Automatic backup / Resumed automatically / Resumed by you |
| Views/ExportSessionDetailView.swift:209 | Completed with N failures | Completed, N not exported |
| Views/ExportSessionDetailView.swift:213 | Interrupted | Didn’t finish |
| Views/ExportSessionDetailView.swift:221–223 | set aside / not recorded / Full check / Quick check | moved / unrecognized / Every file / Changed folders |
| Views/ExportSessionDetailView.swift:233 | Continued from item N | Continued from photo N |
| Views/ExportSessionDetailView.swift:237 **T** | \(Verb) only the selected items | Exported only the selected photos |
| Model/ExportHistory.swift:49 | Completed with N failure(s) | Completed, N not exported |
| Model/ExportHistory.swift:53 | Interrupted | Didn’t finish |
| Model/ExportHistory.swift:61 | N downloaded / N exported | N exported |
| Model/ExportHistory.swift:63 | N already there | N already backed up |
| Model/ExportHistory.swift:66 | N failed | N not exported |
| Model/ExportHistory.swift:76 | N attempts | N runs |

### 3.4 Clean Up iCloud, Browse Backup, tool sheets

| File:line | Current | New |
|---|---|---|
| Views/CleanupView.swift:22 | Label "Clean Up iCloud", symbol trash | symbol `icloud` |
| Views/CleanupView.swift:24 | Clean Up works on your iCloud Photos library. Switch the source to iCloud Photos to choose items to delete. | Clean Up iCloud works with iCloud Photos. Switch to iCloud Photos to choose photos to delete. |
| Views/CleanupView.swift:35 | Sign in to iCloud to choose items to delete from iCloud Photos. | Sign in to choose photos to delete from iCloud. |
| Views/CleanupView.swift:74 | Items are permanently removed by iCloud after 30 days. | Deleted for good after 30 days |
| Views/CleanupView.swift:81 | ContentUnavailableView("Recently Deleted is empty.") | title "No Recently Deleted Photos" |
| Views/CleanupView.swift:103 | Reading your library… | Loading your library… |
| Views/CleanupView.swift:191–201 | Select menu | single Select All / Deselect All button (as Library) |
| Views/CleanupView.swift:254 | All N items selected | All N photos selected |
| Views/CleanupView.swift:274 / :285 | A clean up is running. | Wait for the current deletion to finish. / Wait for the current recovery to finish. |
| Views/CleanupView.swift:276 | Delete the selected items from iCloud Photos. They stay in Recently Deleted for 30 days. | Moves the selected photos to Recently Deleted, where they stay for 30 days. |
| Views/CleanupView.swift:281 | Recover N Item(s) / Recover Items | Recover N Photo(s) / Recover |
| Views/CleanupView.swift:287 | Recover the selected items to your library on all your devices. | Puts the selected photos back in your library on all your devices. |
| Views/CleanupView.swift:308 | Finding items… | Finding photos… |
| Views/CleanupView.swift:328 | Dismiss | OK |
| Views/CleanupView.swift:375 | Stopping after the batch in progress… | Stopping after the current batch… |
| Views/CleanupView.swift:381 | A batch already sent to iCloud can’t be recalled. | Photos already sent to iCloud can’t be called back. |
| Views/CleanupView.swift:410 | Trying the rest again in \(t). Items already deleted stay deleted. | Trying again in \(t). Photos already deleted stay in Recently Deleted. |
| Views/CleanupView.swift:442 | "\(failure.id): \(failure.reason)" (shows an internal ID) | "\(failure.reason)" grouped with a count, e.g. "3 × The item couldn’t be deleted." |
| Views/CleanupView.swift:459 | View Recently Deleted | Show Recently Deleted |
| Views/CleanupView.swift:476 / :486 | Stopped. Recovered N items. / Stopped. Deleted N items from iCloud. | Stopped after recovering N photos. / Stopped after deleting N photos. |
| Views/CleanupView.swift:480 / :490 | No items were recovered. / No items were deleted. | Nothing was recovered. / Nothing was deleted. |
| Views/CleanupView.swift:482 | Recovered N items. They’re back in your library. | Recovered N photos. They’re back in your library. |
| Views/CleanupView.swift:492 | Deleted N items from iCloud. | Deleted N photos from iCloud. |
| Views/CleanupView.swift:497 | item / items | photo / photos |
| Views/CleanupView.swift:512 | Delete ^[N item](inflect) from iCloud? | Delete ^[N Photo](inflect) from iCloud? |
| Views/CleanupView.swift:514 | The items move to Recently Deleted on all your devices. They can be recovered there for 30 days. | They move to Recently Deleted on all your devices, where you can recover them for 30 days. |
| Views/CleanupView.swift:517 | N of them aren’t backed up to your drive. | N of them aren’t in your backup. (orange triangle stays) |
| Views/CleanupView.swift:520 | A batch that has already been sent to iCloud can’t be recalled. | remove (stays as the Cancel button's help at :381) |
| Views/CleanupView.swift:527 | Number of items | Number of photos |
| Views/CleanupView.swift:540 / :570 | Delete ^[N Item] / Recover ^[N Item] | Delete ^[N Photo] / Recover ^[N Photo] |
| Views/CleanupView.swift:560 | Recover ^[N item](inflect)? | Recover ^[N Photo](inflect)? |
| Views/BrowseBackupView.swift:24 | Filter places | Search places |
| Views/BrowseBackupView.swift:66 | Choose a backup folder to browse it. | Choose a backup folder to see your photos on a map. |
| Views/BrowseBackupView.swift:68 | Choose Folder… | Choose Backup Folder… |
| Views/BrowseBackupView.swift:87 | Export some photos to this folder, then come back to see where they were taken. | Export some photos, then see where they were taken. |
| Views/BrowseBackupView.swift:89 | Go to Backup | Show Backup |
| Views/BrowseBackupView.swift:170 | \(n) photos (says "1 photos") | ^[\(n) photo](inflect: true) |
| Views/BrowseBackupView.swift:199 | No Photos Have a Location | No Photo Locations |
| Views/BrowseBackupView.swift:201 | None of the photos on this drive has a location. Photos taken with location off are listed under No Location in Places. | None of these photos has a location. Find them under No Location in Places. |
| Views/BrowseBackupView.swift:238 | Choose a Place | Select a Place |
| Views/BrowseBackupView.swift:266, :302 | Checking the backup… | Opening your backup… |
| Views/VerifyBackupSheet.swift:32 | Delete Files and Export Again | Delete and Export Again (role stays `.destructive`) |
| Views/VerifyBackupSheet.swift:37 | Uncloud will delete the files these items still have in “X”, then copy them again from your photo library. Your photo library isn’t changed. | Their files in “X” are deleted and exported again from your library. Your library isn’t changed. |
| Views/VerifyBackupSheet.swift:42 | the backup folder | your backup folder |
| Views/VerifyBackupSheet.swift:53 | Export N item(s) again? | Export N Photos Again? |
| Views/VerifyBackupSheet.swift:60 | Uncloud will read every file in “X” and compare it with the checksum saved when it was exported. This can take a while for a large backup. | Uncloud reads every file in “X” and checks it’s identical to when it was exported. Large backups take a while. |
| Views/VerifyBackupSheet.swift:63 | Wait for the export to finish before checking the backup. | Available when the export finishes. |
| Views/VerifyBackupSheet.swift:93 | Removing old files… | Removing damaged files… |
| Views/VerifyBackupSheet.swift:112 | Check Backup | Verify |
| Views/VerifyBackupSheet.swift:131 | Re-export N Item(s)… | Export N Again… |
| Views/VerifyBackupSheet.swift:169 | There’s nothing in this backup yet. | Nothing to verify yet. |
| Views/VerifyBackupSheet.swift:174–175 | N items verified / Every file is present and matches the original. | N photos verified / Every file is intact. |
| Views/VerifyBackupSheet.swift:183 | N items damaged or missing | N photos damaged or missing |
| Views/VerifyBackupSheet.swift:193–194 | N items can’t be checked / These were exported by an earlier version of Uncloud that didn’t save checksums. Their files are there and look fine, but they can’t be checked until they’re exported again. | N photos can’t be verified / Exported by an older version of Uncloud. They look fine, and can be verified once they’re exported again. |
| Views/VerifyBackupSheet.swift:202–203 | N items not backed up yet / These are in your photo library but not in this backup. Choose Export or Resume to copy them. | N photos not backed up yet / They’re in your library but not in this backup. Export to add them. |
| Views/VerifyBackupSheet.swift:210 | N item(s) with problems is/are no longer in your photo library, so it/they can’t be exported again. Its/Their files were left as they are. | N of these are no longer in your library, so they can’t be exported again. Their files were left as they are. |
| Views/FindDuplicatesSheet.swift:39 | Uncloud will move N copies (X) from “Y” to the Trash. One copy of each is kept. Your photo library isn’t changed. Empty the Trash to free the space. | N copies (X) in “Y” go to the Trash. One copy of each photo is kept. Empty the Trash to free the space. |
| Views/FindDuplicatesSheet.swift:44 | the backup folder | your backup folder |
| Views/FindDuplicatesSheet.swift:56 | Uncloud compares the files in “X” using the checksums saved when they were exported. Items saved more than once are listed, and you choose which copy to keep. | Uncloud looks for photos saved more than once in “X”. You choose which copy to keep. |
| Views/FindDuplicatesSheet.swift:58 | Only the folder changes. Your photo library and iCloud aren’t touched. | Only your backup folder changes. Your library and iCloud aren’t touched. |
| Views/FindDuplicatesSheet.swift:62 | Wait for the export to finish before looking for duplicates. | Available when the export finishes. |
| Views/FindDuplicatesSheet.swift:87, :201 | N items couldn’t be checked because it was/they were saved by an older version of Uncloud. | N photos exported by an older version of Uncloud couldn’t be checked. |
| Views/FindDuplicatesSheet.swift:156 | Open Trash | Show Trash |
| Views/FindDuplicatesSheet.swift:301 | Keep This One | Keep This |
| Views/FindDuplicatesSheet.swift:394 | In the folder you chose | In your backup folder |
| Views/FreeUpSpaceSheet.swift (new) | (no title) | sheet title **Free Up Space** |
| Views/FreeUpSpaceSheet.swift:18 | Only items older than | Only photos older than |
| Views/FreeUpSpaceSheet.swift:24 | Keep hidden items | Keep hidden photos |
| Views/FreeUpSpaceSheet.swift:48 | Remove N item(s) from your photo library? | Remove N Photos from This Mac? |
| Views/FreeUpSpaceSheet.swift:52 | Remove N Item(s) | Remove N Photos |
| Views/FreeUpSpaceSheet.swift:57 | They’ll be deleted from this Mac and, if iCloud Photos is on, from iCloud and all your devices, and items in a Shared Library are removed for everyone who shares it. You can get them back from Recently Deleted in Photos for 30 days. The copies in “X” are kept. | They’re deleted from Photos on this Mac and, if iCloud Photos is on, from all your devices. Shared Library photos are removed for everyone. They stay in Recently Deleted in Photos for 30 days. Your backup in “X” is kept. |
| Views/FreeUpSpaceSheet.swift:64 | Removing items deletes them from the photo library on this Mac. If iCloud Photos is on, they’re also deleted from iCloud and from all your devices. Items in a Shared Library are removed for everyone who shares it. | Removes photos from Photos on this Mac. If iCloud Photos is on, they’re removed from all your devices, and Shared Library photos for everyone. (orange triangle stays) |
| Views/FreeUpSpaceSheet.swift:70 | Removed items stay in Recently Deleted in Photos for 30 days. Only items that are verified in this backup are offered. | Only photos verified in your backup are offered. Removed photos stay in Recently Deleted for 30 days. |
| Views/FreeUpSpaceSheet.swift:95 | Wait for the export to finish first. | Available when the export finishes. |
| Views/FreeUpSpaceSheet.swift:98 | Uncloud needs access to your photo library. | Uncloud needs access to Photos. |
| Views/FreeUpSpaceSheet.swift:106 | Looking for items… | Looking for photos… |
| Views/FreeUpSpaceSheet.swift:132 | Waiting for you to confirm in the macOS alert… | Confirm in the dialog to continue… |
| Views/FreeUpSpaceSheet.swift:165 | Remove N Item(s) from Library… | Remove N Photos… |
| Views/FreeUpSpaceSheet.swift:182 | Find Items… | Find Photos |
| Views/FreeUpSpaceSheet.swift:199 | No items can be removed with these options. | No photos match these options. |
| Views/FreeUpSpaceSheet.swift:202 | N items (X in the backup) are safely backed up and can be removed. | N photos (X) are safely backed up and can be removed. |
| Views/FreeUpSpaceSheet.swift:228, :231, :237 | N items not verified in this backup / N items changed in Photos since … / N hidden items | N photos not verified in your backup / N photos changed in Photos since they were backed up / N hidden photos |

### 3.5 Model and engine messages (Activity, errors, notifications, alerts)

| File:line | Current | New |
|---|---|---|
| Model/ExportModel.swift:464 **T** | Export N Item(s) | Export N Photo(s) |
| Model/ExportModel.swift:602 | There May Not Be Enough Space | Your Drive May Run Out of Space |
| Model/ExportModel.swift:603 | \(w) The export stops if the drive fills up, and you can resume it after making room. | \(w) If it fills up, the export stops and you can resume after making room. |
| Model/ExportModel.swift:619 | Paused. The item in progress will finish first. | Paused. The photo in progress finishes first. |
| Model/ExportModel.swift:640 | The export is still stopping in the background. | Still stopping in the background. |
| Model/ExportModel.swift:787 | Continuing from where the last export stopped: [about ]N already on this drive. | Picking up where the last export stopped. [About ]N photos already backed up. |
| Model/ExportModel.swift:934–935 | N item(s) was/were already in the destination. | N photo(s) already backed up. |
| Model/ExportModel.swift:939 | Export finished, but N items couldn’t be \(verb). Choose Resume to try them again. | Export finished, but N photos couldn’t be exported. Export again to retry them. |
| Model/ExportModel.swift:943 | Export cancelled. Choose Resume to continue later. | Export cancelled. You can resume it later. |
| Model/ExportModel.swift:1219 **T** | [about ]N already on this drive · [about ]M to go | [about ]N backed up · [about ]M to go |
| Model/ExportModel.swift:1294 | First check of this drive takes a little longer. | The first check of a drive takes a little longer. |
| Model/ExportModel.swift:1341 | N files are missing or damaged and will be \(verb) again. | N files are missing or damaged and will be exported again. |
| Model/ExportModel.swift:1342 | …They’ll be fixed when you export or choose Check Drive. | …They’re fixed on the next export or check. |
| Model/ExportModel.swift:1345 | Moved N damaged file(s) to .photo-export/set-aside on the drive. | Moved N damaged file(s) to a separate folder on the drive. |
| Model/ExportModel.swift:1349–1350 | Couldn’t move N damaged files aside, such as “x”: reason It stays/They stay where it is/they are and will be checked again next time. | Couldn’t move N damaged file(s), such as “x”: reason. They’re checked again next time. |
| Model/ExportModel.swift:1354 | N file(s) that Uncloud can’t tell it saved changed size since the last check, such as “x”. It was/They were left as it is/they are. | N file(s) Uncloud may not have saved changed since the last check, such as “x”. They were left alone. |
| Model/ExportModel.swift:1491 | Estimated from each item’s dimensions and length, including edited versions and Live Photo videos. | Estimated from each photo’s size and length, including edits and Live Photos. |
| Model/ExportModel.swift:1493 | Originals and Live Photo videos, as sized by iCloud. | Originals and Live Photos, as sized by iCloud. |
| Model/ExportModel.swift:1495 | Originals and Live Photo videos, estimated from the items checked so far. Uncloud checks the rest in the background. | Estimated so far. Uncloud is still measuring the rest. |
| Model/ExportModel.swift:1666 | “X” isn’t available. Connect the drive or choose a different folder. | “X” isn’t connected. Connect the drive or choose another backup folder. |
| Model/ExportModel.swift:1674 | You can’t save files to “X”. Choose a different folder. | Uncloud can’t write to “X”. Choose another backup folder. |
| Model/ExportModel.swift:1731 | your destination | your backup drive |
| Model/ExportModel.swift:1735 | Backup finished, but N items couldn’t be \(verb). | Export finished, but N photos couldn’t be exported. |
| Model/ExportModel.swift:1740 | Backed up N new item(s) to “X”. | Exported N new photo(s) to “X”. |
| Model/ExportModel.swift:1787 **T** | Paused because \(reason). Resuming at \(t) (attempt N). | Paused: \(Reason). Resumes at \(t) (try N). |
| Model/ExportModel.swift:1878 | Resuming automatically (attempt N). | Resuming (try N). |
| Model/ExportModel.swift:1918 | Download Again Here | Export Again Here |
| Model/ExportModel.swift:1958 | Folder layout changed to \(layout). The next export downloads everything again into this folder. | Now organized \(layout). The next export saves everything again in this folder. |
| Model/ExportModel.swift:1997 / :1998 **T** | Uncloud can’t read “X” right now, so it can’t tell whether it already has items saved another way. / …is still reading “X”, so it can’t tell yet whether… | keep the substrings "can’t read “X”" and "can’t tell yet"; items → photos |
| Model/ExportModel.swift:2003, :2016 **T** | Download Everything Again? | Export Everything Again? |
| Model/ExportModel.swift:2004–2005, :2017–2019 **T** | …switching to \(L) downloads \(what) again\(size) into this folder, next to the copies already there. To keep one copy, choose a new folder for the new layout. | …“X” already has N photos organized \(old). Switching to \(L) exports \(what) again\(size), next to those copies. To keep one copy, choose a new folder. |
| Model/ExportModel.swift:2029 | This folder already has items exported \(old). They’ll stay where they are, and new items will use the layout you choose here. | This folder already has photos organized \(old). They stay, and new photos use the new folders. |
| Model/ExportModel.swift:2035–2036 **T** | This folder already has N item(s) saved \(old). Exporting \(new) downloads everything again into this folder. To keep one copy, choose a new folder. | This folder already has N photos organized \(old). Organizing \(new) exports everything again. To keep one copy, choose a new folder. |
| Model/ExportModel.swift:2046, :2048 **T** | This folder already has other files. Uncloud will leave them alone, but a dedicated folder is easier to keep tidy. / A file of yours with the same name and size as a photo counts as already \(verb). | This folder has other files. Uncloud leaves them alone, but a folder of its own is tidier. / A file with the same name and size as a photo counts as backed up. |
| Model/LibrarySource.swift:14 | Photos Library on This Mac | Photos on This Mac |
| Model/LibrarySource.swift:21–22 **T** | copiedVerb "downloaded" / "exported" | "exported" for both (or delete `copiedVerb` and inline "exported"; update the one test) |
| Model/FolderLayout.swift:40–46 **T** | Every photo and video is saved directly in the folder you chose, with no subfolders. Files keep their iCloud/original names; when two have the same name, the second gets its size added/a number, like … | Everything goes straight into your backup folder, with no subfolders. When two files share a name, the second gets its size added, like IMG_0001-2483921.HEIC. / …gets a number, like IMG_0001 (1).HEIC. |
| Model/NewPhotos.swift:171 **T** | Choose Folder… | Choose Backup Folder… |
| Model/NewPhotos.swift:248 | New photos to back up | New Photos to Export |
| Model/NewPhotos.swift:295 | Open Uncloud to back them up. / Connect your backup drive to save them. | Open Uncloud to export them. / Connect your backup drive to export them. |
| Model/AutoResume.swift:77 | Uncloud stopped retrying after several hours. Start the export again to continue; photos already on your drive are skipped. | Uncloud stopped trying after several hours. Export again to continue. Photos already backed up are skipped. |
| Model/BackupVerification.swift:161 | An export started while old files were being removed, so the backup records weren’t changed. When it finishes, choose Verify Backup again. | An export started, so nothing was changed. Verify again when it finishes. |
| Model/BackupVerification.swift:170 | Old files were removed, but the backup records couldn’t be updated. \(e) | The damaged files were removed, but Uncloud couldn’t update its records. \(e) |
| Model/BackupVerification.swift:179 | No items were prepared for re-export. | Nothing needed exporting again. |
| Model/BackupVerification.swift:182 | Exporting N items again. | Exporting N photos again. |
| Model/BackupVerification.swift:184 | N items will be exported again. Choose Export or Resume in the Backup pane to copy them. | N photos are ready to export again. Click Export in Backup. |
| Model/BackupVerification.swift:188 | N items couldn’t be prepared and were left as they are. | N photos couldn’t be prepared and were left as they are. |
| Model/LibraryCleanup.swift:153 | Items couldn’t be checked. \(e) | Photos couldn’t be checked. \(e) |
| Model/LibraryCleanup.swift:253 | …Choose Find Items again. | …Click Find Photos again. |
| Model/LibraryCleanup.swift:275, :277, :287 | Removed N items from your photo library. They’re in Recently Deleted in Photos for 30 days. / N items couldn’t be removed. / N items changed since… | Removed N photos from this Mac. They’re in Recently Deleted for 30 days. / N photos couldn’t be removed. / N photos changed since… |
| Model/ICloudCleanup.swift:362 | Apple is limiting deletions. Try Clean Up again later. | Apple is limiting deletions. Try again later. |
| Model/LibraryBrowser.swift:354 | Uncloud doesn’t have access to your Photos library. | Uncloud doesn’t have access to Photos. |
| Model/SessionRecorder.swift:183 **T** | Couldn't save the export history on this drive (straight ') | Couldn’t save the export history on this drive. |
| Export/ExportEngine.swift:26 | The destination is full. Free up space or choose another folder, then choose Resume. | Your backup drive is full. Make room or choose another backup folder, then resume. |
| Export/ExportEngine.swift:28 | The destination folder is no longer available. Reconnect the drive or choose another folder, then choose Resume. | Your backup folder isn’t available. Reconnect the drive, then resume. |
| Export/ExportEngine.swift:69–70 | Leaving out N item(s) that aren’t selected. | Leaving out N photo(s) that aren’t selected. |
| Export/PlaceResolver.swift:9 | …then choose Resume. | …then resume. |
| Export/ICloud/ICloudHelperProcess.swift:15 | The iCloud downloader is missing from Uncloud. Reinstall the app, then try again. | Part of Uncloud is missing. Reinstall the app, then try again. |
| Export/ICloud/ICloudHelperProcess.swift:21 **T** | The iCloud download stopped: \(detail). Choose Resume to try again. | The export stopped because of an iCloud error (\(detail)). Resume to try again. |
| Export/ICloud/ICloudHelperProcess.swift:23 | The iCloud download stopped unexpectedly (code N). | The export stopped unexpectedly (error N). |
| Export/ICloud/ICloudHelperProcess.swift:25 | The connection to iCloud was interrupted. Choose Resume to continue. | The connection to iCloud was interrupted. Resume to continue. |
| Export/ICloud/ICloudOutputParser.swift:44 | The Apple ID or password isn’t correct. | The Apple Account or password is incorrect. |
| Export/ICloud/ICloudOutputParser.swift:49 | Your iCloud session has expired. Sign in again. | Your iCloud sign-in has expired. Sign in again. |
| Export/ICloud/ICloudOutputParser.swift:51 | Your iCloud session expired. Reconnecting… | Reconnecting to iCloud… |
| Export/ICloud/ICloudOutputParser.swift:55 | iCloud is still preparing your photo library for access. This is normal after signing in or changing account settings, and can take from a few minutes to a few hours for large libraries. Uncloud will try again automatically. | iCloud is still preparing your library. After signing in this can take a few minutes to a few hours. Uncloud keeps trying. |
| Export/ICloud/ICloudOutputParser.swift:57 | Apple needs you to accept its updated iCloud Terms and Conditions before your photos can be downloaded. Apple shows them only in its own apps: in System Settings, click your name and look for a “Review” banner, or sign in at icloud.com. Uncloud checks again when you come back. | Apple needs you to accept updated iCloud terms first. In System Settings, click your name and look for a Review banner, or sign in at icloud.com. Uncloud checks again when you come back. |
| Export/ICloud/ICloudOutputParser.swift:59 | iCloud Photos isn’t available for this Apple ID. Check that iCloud Photos is turned on and that Access iCloud Data on the Web is enabled. | iCloud Photos isn’t available for this account. Make sure iCloud Photos and Access iCloud Data on the Web are turned on. |
| Export/ICloud/ICloudExportEngine.swift:72 | The iCloud bridge couldn’t start, so icloudpd checked the whole library | A faster resume wasn’t possible, so Uncloud checked the whole library |
| Export/ICloud/ICloudExportEngine.swift:550–551 **T** | Continuing from item N of M, after K new item(s). | Continuing from photo N of M, after K new photo(s). |
| Export/ICloud/ResumePoint.swift:114–115 | The last exported item couldn’t be found where expected / Too many items changed since the last export | The last exported photo moved in your library / Too many photos changed since the last export |
| Export/ICloud/ICloudSignIn.swift:155 | Sign-in stopped unexpectedly (code N). | Sign-in stopped unexpectedly (error N). |

Not changed on purpose: `AutoResume.swift:55–61` reasons ("Apple is limiting downloads", …), which are already plain and
tested; `StorageEstimate.swift:249`; `FolderLayout` titles; `BrowseBackup` "Unknown Place" / "No Location"; the Python
helper's own messages (`Uncloud/Helper/*.py`, e.g. "Your iCloud library changed since you confirmed…"), which are fine
and out of scope; logger and `NSLog` text.

---

## 4. Menus and commands

### Before

```
File     Choose Export Folder… ⌘O | Sign Out of iCloud…
Edit     (system) … Deselect All ⇧⌘A
View     Library ⌘1 | Backup ⌘2 | Clean Up iCloud ⌘3 | Browse Backup ⌘4 | — | Show/Hide Sidebar ⌃⌘S
Export   <primary title> ⌘R | Export All Photos ⌥⌘R | — | Pause/Resume | Cancel Export ⌘. | — |
         Verify Backup… | Find Duplicates… | Free Up Space… (Photos only, hidden for iCloud)
Help     Getting Started… | — | Show Diagnostic Logs
Menu bar status | Export Now | Open Uncloud | — | Settings… | Quit Uncloud ⌘Q
Toolbar  Library: Select ▾, progress ring, primary.  Clean Up: picker, Select ▾, Filter ▾, Delete/Recover.
Sidebar  footer menu: Source picker, Sign In…/Sign Out…  (the only way to switch source)
```

Problems: "Export" menu holds tools that aren't exports. Source switching can only be found in the sidebar footer.
Clean Up's Delete and Recover aren't in any menu (HIG: every toolbar action is also a menu command). Free Up Space is
**hidden** for iCloud (HIG: disable, don't hide). Select ▾ duplicates Edit › Select All. Getting Started has an
ellipsis it doesn't need. "Resume"/"Pause" don't say what they act on.

### After

```
File     Choose Backup Folder… ⌘O
         Show Backup Folder in Finder ⇧⌘O        (model.revealDestination(); disabled without one)
         —
         Photos From ▸  ✓ iCloud Photos / Photos on This Mac   (disabled while exporting)
         Sign In to iCloud…  |  Sign Out of iCloud…   (one slot; only when the source is iCloud)
Edit     (system) Select All ⌘A | Deselect All ⇧⌘A
         —
         Delete from iCloud… ⌘⌫     (Clean Up iCloud, Library mode, focused grid; opens the same typed confirmation)
         Recover ⌘⌫                 (Clean Up iCloud, Recently Deleted mode; same slot, same sheet)
View     Library ⌘1 | Backup ⌘2 | Browse Backup ⌘3 | Clean Up iCloud ⌘4 | — | Show/Hide Sidebar ⌃⌘S
Backup   <primary title> ⌘R                       (unchanged dynamic title: Export New Photos / Resume Export / …)
         Export All Photos ⌥⌘R
         Pause Export / Resume Export
         Cancel Export ⌘.
         —
         Check Now                                (model.checkDrive(full: true); disabled by !canCheckDrive)
         Verify Backup…
         Find Duplicates…
         Free Up Space…                           (always listed; disabled for iCloud, with the reason in the Backup pane)
Help     Getting Started | — | Show Diagnostic Logs in Finder
Menu bar <status line>  (adds "Your last export didn’t finish" and the new-photos line)
         Export Now | Open Uncloud | — | Settings… ⌘, | Quit Uncloud ⌘Q
Toolbar  Library: Select All/Deselect All (one text button) · progress ring · [spacer] · primary.
         Backup (new): Show in Finder (folder symbol), moved from the Backup Folder row.
         Clean Up: picker (centre) · Select All/Deselect All · Filter ▾ · [spacer] · Delete from iCloud… / Recover N.
```

Notes:
- The Edit-menu Delete and Recover commands read a new `FocusedValue` (`CleanupCommandActions`, defined in chunk 1),
  published by `CleanupGridView` while its grid is focused. They call `cleanup.requestConfirmation()` and are disabled by
  `!cleanup.canRequestConfirmation`, exactly as the toolbar button is. The typed-number sheet is still the only way to
  delete. ⌘⌫ only *opens* it, and Return never confirms.
- The menu bar extra stays a `.menu` style item. It has no new actions, only the two status lines.
- ⌘3 and ⌘4 swap so that the two backup panes sit together and the one destructive pane comes last (sidebar order too).

---

## 5. Visual changes, by screen, ordered by impact

### 5.1 Backup pane (BackupPane, BackupHero, ProgressCard, CheckDriveViews, BackupToolSheets, ActivitySection)

Today the pane has six sections, five coloured tiles, about nine grey captions, a radio group with examples, and two
status places (hero and card). Target: three short sections under a calm hero, all visible at 1000×700 with no scrolling
when idle.

1. **Hero**: title `.title.weight(.semibold)` (was `.title2`), subtitle `.body` secondary (was `.callout`). Hero
   wash opacity 0.10 → `Tokens.Hero.wash` (0.06). Gate the hero's content changes with
   `.animation(reduceMotion ? nil : Tokens.Motion.standard, value: content.kind)`.
2. **ProgressCard inside the hero**: drop the `.title` percentage text (the hero title now ends with "42%"), and drop the
   duplicate status `Label`s for preparing, running, paused, cancelling and complete. What's left: the bar, **one** line
   "4,120 of 9,800 photos · About 2 hours left" (`.callout` secondary, monospaced digits), and the controls. Pause and
   Cancel Export become `.controlSize(.small)` bordered buttons with symbols. Resume Export stays prominent, and Start Over
   stays bordered. No `info.circle` in front of the interrupted line.
3. **Backup Folder section** (was "Save To"): one row with the drive symbol (plain, secondary), name and path, and
   **Change…**. The Show in Finder button moves to the toolbar. Underneath, a single `LabeledContent("Space")` whose value is
   "412 GB needed · 1.2 TB free" with the note as `.help`. Then the drive row: "9,207 backed up · 83,808 to go", and
   "Checked today at 14:03" as `.caption`, with **Check Now** trailing. Issues (red) and storage warnings (orange) stay
   right under the row they refer to.
4. **Folders section** (was "Folders and Files"): the radio group with five two-line options becomes a
   `Picker("Folders", …).pickerStyle(.menu)`. The menu items show the title, and the selected layout's example path
   (`layout.example`) shows as one `.caption` line under the picker. Only the caption for the **selected** layout shows
   (one at most), and so do the orange warnings. The XMP toggle keeps a one-line caption. The confirmation dialog is unchanged.
5. **Tools section**: three bordered buttons in one `HStack` (Verify Backup…, Find Duplicates…, Free Up Space…), with no
   captions; `.help` and `.accessibilityHint` carry the text. Free Up Space is shown disabled for iCloud with
   `.help("Only for Photos on This Mac.")` instead of being hidden.
6. **History section** (ExportHistoryView, owned by chunk 2): show the 3 newest rows, then a "Show All…" button that
   opens a sheet with the rest (the same rows). The tags capsule stays. **Activity** becomes a `DisclosureGroup("Activity")`
   row at the end of the History section, not its own section, still collapsed by default (`@AppStorage` key unchanged).
7. **Section headers**: `SectionTitle` keeps its `init(title:symbol:tint:)` signature so callers keep compiling, but it
   renders a plain `Text(title)` (no `IconTile`). Add `init(_ title: String)` and move callers to it.
8. **LimitedAccessNotice**: drop the `GroupBox` and render it as a plain row inside the hero section (orange triangle,
   text, Open System Settings).
9. **Not-ready state** keeps `ContentUnavailableView`. Its symbol becomes `externaldrive` (secondary), and the action
   "Get Started" stays prominent.

### 5.2 Window shell and sidebar (LibraryWindow, LibraryView, LibraryGrid)

1. **Sidebar rows**: replace `IconTile` with plain `Label("Library", systemImage: "photo.on.rectangle")`,
   `"externaldrive"`, `"map"` and `"icloud"`. They pick up the system's accent tinting and HIG sidebar sizing, and are
   calmer on Liquid Glass. Order: Library, Backup, Browse Backup, then a `Section("iCloud")` holding Clean Up iCloud, so the
   destructive pane sits apart. The badges stay.
2. **Remove `ExportStartedBanner`** and its state and timer task. The sidebar % badge, the toolbar progress ring (which
   opens Backup) and the VoiceOver announcement already say it. That's one fewer floating element and one fewer timer.
3. **Account footer**: the tile becomes a plain 16 pt symbol, and the padding becomes `Tokens.Space.m`. The subtitle uses
   `.caption` secondary. It is still a menu, and it duplicates File › Photos From.
4. **Library toolbar**: one text button (Select All or Deselect All) replaces the Select ▾ menu. The rest is as shipped.
5. **Loading state**: the placeholder grid uses `.fill.quaternary` with `Tokens.Radius.s` corners. The text is "Loading
   your library…".
6. **Grid badge** "Backed Up" (LibraryGrid.swift:178): replace the text capsule on every tile with a small
   `externaldrive.fill.badge.checkmark` symbol at `.caption2` on `.regularMaterial`. With 90k photos, the text capsules
   are the noisiest thing on screen. Don't use a plain checkmark, because the selection ring already uses one (that's why
   the comment at :177 chose text). The cell's accessibility label already says "backed up", so nothing else changes.

### 5.3 Landing and onboarding (LandingView, BenefitsCarousel, HowItWorksSteps, GettingStartedView)

1. **Remove the auto-advancing carousel** from the landing page. In its place, three static lines (symbol + short text),
   `.callout` secondary, centred: "Full-quality originals", "Organized by month or album", "Verified, and automatic when
   your drive connects". Keep `Benefit`, `BenefitRow` and `PrivacyNote` for Getting Started. Delete `BenefitsCarousel`
   (the view) if nothing else uses it.
2. Logo 112 → 96, headline `.largeTitle.weight(.bold)` stays, and the spacing uses tokens (`xxxl` between groups).
3. Getting Started: padding 24 stays (reading width), and the title uses the chunk-1 `SheetScaffold`.

### 5.4 Sheets (Verify, Find Duplicates, Free Up Space, Check Results, Session Detail, Sign In, confirmations)

1. All of them use chunk 1's `SheetScaffold` (VStack sheets) or `FormSheetScaffold` (Form sheets): a title in
   `.title2.weight(.semibold)`, the content, then a footer with trailing buttons at **regular** control size. Today
   Verify and Duplicates use `.large`. HIG: large is for the one hero action, not dialog footers.
2. **Add the missing titles**: Free Up Space and Check Results have none today.
3. Remove `info.circle` from plain secondary lines (Verify :63, :169; Duplicates :62; Free Up Space :95, :98, :199).
   Keep symbols only on status lines (success, warning, danger).
4. Duplicates: drop the `GroupBox` per group and use a `List` with `Section` per group (one container instead of N boxes).
5. Sign In: the title uses `.title2.weight(.semibold)` (it's `.headline`, unlike every other sheet).
6. Confirmations keep their roles, gates and default and cancel keys exactly. Only the text changes (section 3).

### 5.5 Clean Up iCloud (CleanupView)

1. `CleanupStatusCard` uses chunk 1's `StatusBanner`: floating glass on macOS 26 (inset `Tokens.Space.s`, radius
   `Tokens.Radius.l`), and on 14 today's `.regularMaterial` strip with its bottom divider. The same component also serves
   Browse's `IndexingBanner`, so the app has one banner look.
2. The summary's buttons: Done is `.borderedProminent` (it's the one action), and Show Recently Deleted is bordered.
3. Failure details show reasons, not internal IDs (section 3.4).
4. Unchanged: the typed-number sheet, its red prominent Delete, the orange not-backed-up warning, Return-never-deletes,
   and Recover prominent without red.

### 5.6 Browse Backup (BrowseBackupView, BrowsePhotoViews)

1. `IndexingBanner` → `StatusBanner` (above).
2. The detail pane under the grid keeps `.bar`. Its row labels are sentence case and `.callout`.
3. The map badge (BrowseMapView.swift:72) uses `NSColor.controlAccentColor`. Keep it, since it follows the user's accent.

### 5.7 Settings and menu bar extra

Settings keeps its grouped Form and its three sections. Only the wording changes, plus "Backup folder" as a read-only
name with **Change…**. The menu bar extra gets the two extra status lines only.

### 5.8 Token changes (DesignTokens.swift)

- **Remove** `Tint.folders`, `Tint.tools`, `Tint.history`, `Tint.neutral` and `Tint.places` once chunks 3–5 stop using
  them (chunk 1 marks them `@available(*, deprecated)`, so the build warns rather than breaks while the chunks land).
  Keep `Tint.library`, `Tint.iCloud` and `Tint.drive` for Getting Started illustrations only.
- **Remove** `Tile.sidebar` after chunk 3 lands (deprecate first).
- **Add**:
  - `Tokens.Space.section = 24` (between Form sections when custom spacing is needed)
  - `Tokens.Hero.wash: Double = 0.06`
  - `Tokens.Font.heroTitle = Font.title.weight(.semibold)`, `heroSubtitle = .body`, `help = .callout`, `meta = .caption`
  - `Tokens.Motion.standard = Animation.smooth(duration: 0.25)` plus
    `func Tokens.Motion.animation(_ reduceMotion: Bool) -> Animation?`
  - `Tokens.Sheet.footerControlSize = ControlSize.regular`
- `AccentVariant` stays as it is (tests use it).

---

## 6. Build chunks

Five chunks. Chunk 1 is small and lands first, since the others build on its components. Chunks 2–5 can then run in
parallel: each owns its files outright, and none edits another's. Shared rules for every chunk:

- **No view initializer used by a test changes signature.** The snapshot tests call `BackupPane()`, `LandingView()`,
  `SettingsView()`, `LibraryWindow()`, `CleanupGridView(...)`, `CleanupConfirmationSheet(...)`, `VerifyBackupSheet(...)`,
  `FindDuplicatesSheet(...)`, `ExportHistoryView(...)`, `ExportSessionDetailView(...)`, `CheckDriveResultsSheet(...)`,
  `DriveSummaryRow(...)`, `IndexingBanner(...)`, `BrowseBackupView(...)` and `BackupHeroHeader(...)`. Keep those exact
  inits. New parameters need defaults.
- Don't change any `disabled(...)` condition, any action, confirmation flow, model method body (beyond string literals),
  `Uncloud/Export/**` logic, or `Uncloud/Helper/**`.
- Swift 6 strict concurrency; typecheck for `arm64-apple-macos14.0`; every macOS 26 API behind `#available` with an else
  branch; `xcodegen generate` after adding files. Every removed caption moves to `.help` **and** `.accessibilityHint`.
  Decorative symbols stay `.accessibilityHidden(true)`.
- Run only your own test files (listed per chunk) while developing. The orchestrator runs the full suite once all chunks
  have merged.

### Chunk 1: Foundation (lands first, small)

Owns: `Uncloud/Views/DesignTokens.swift`, `Uncloud/Views/IconTile.swift`, **new** `Uncloud/Views/Components.swift`.

Adds:
- The tokens in 5.8, with the Tint and Tile removals as deprecations.
- `struct SheetScaffold<Content: View, Buttons: View>: View`, with
  `init(_ title: String, width: CGFloat = Tokens.Sheet.regular, @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons)`.
  It lays out the title (`.title2.weight(.semibold)`), the content, then `HStack { Spacer(); buttons }` with
  `.controlSize(Tokens.Sheet.footerControlSize)`, `Tokens.Sheet.padding` and a fixed width.
- `struct FormSheetScaffold<Content, Buttons>`: the same signature, plus `minHeight: CGFloat = 440`. It lays out the title,
  then a `.grouped` Form, a `Divider`, and the footer.
- `struct StatusBanner<Actions: View>: View`, with
  `init(symbol: String?, tint: Color, title: String, detail: String? = nil, progress: Double? = nil, @ViewBuilder actions: () -> Actions)`.
  On macOS 26 it is glass, inset `Tokens.Space.s` with radius `Tokens.Radius.l`. Otherwise it is a `.regularMaterial`
  strip with a bottom divider. It is `.accessibilityElement(children: .contain)`.
- `struct HelpText: View` (`init(_ text: String)`): `.font(.callout)`, `.foregroundStyle(.secondary)`,
  `.fixedSize(horizontal: false, vertical: true)`.
- `enum Plural { static func photos(_ n: Int) -> String }`, returning "1 photo" or "1,234 photos" (locale-formatted).
- `struct CleanupCommandActions { let title: String; let isEnabled: Bool; let perform: () -> Void }`, plus
  `FocusedValues.cleanupCommand`, mirroring `GridSelectionActions`.

Tests to update: none. Add `UncloudTests/ComponentsTests.swift` (`Plural.photos` for 0, 1, 2 and 1,234; and
`Tokens.Motion.animation(true) == nil`).

Acceptance: builds for macOS 14 with no new warnings except the intended deprecations. `StatusBanner` and both
scaffolds render in light and dark (add them to an existing snapshot harness *in the new test file only*). No call site
outside Components.swift changes.

### Chunk 2: Words in the model, engine and history

Owns: `Model/ExportModel.swift` (string literals only), `Model/LibrarySource.swift`, `Model/FolderLayout.swift`,
`Model/NewPhotos.swift`, `Model/AutoResume.swift`, `Model/BackupVerification.swift`, `Model/LibraryCleanup.swift`,
`Model/ICloudCleanup.swift`, `Model/ExportHistory.swift`, `Model/LibraryBrowser.swift`, `Model/SessionRecorder.swift`,
`Export/ExportEngine.swift`, `Export/PlaceResolver.swift`, `Export/ICloud/ICloudHelperProcess.swift`,
`Export/ICloud/ICloudOutputParser.swift` (the `message` switch only), `Export/ICloud/ICloudExportEngine.swift` (lines 72,
550–551 only), `Export/ICloud/ResumePoint.swift` (lines 114–115), `Export/ICloud/ICloudSignIn.swift`, **plus the history
views** `Views/ExportHistoryView.swift` and `Views/ExportSessionDetailView.swift` (their strings and 5.1 item 6).

Work: every row of 3.5, the ExportHistory rows of 3.3, the ExportHistoryView and ExportSessionDetailView rows of 3.3,
and the History section layout (5.1 item 6, using `SectionTitle(title:symbol:tint:)` as it is; chunk 4 changes how it
draws). Activity moves into the History section *in chunk 4's BackupPane*: chunk 2 leaves `ActivitySection` alone.

Tests to update (string assertions):
- `UncloudTests/ResumeExportTests.swift:60` ("Export 2 Items" → "Export 2 Photos")
- `UncloudTests/NewPhotosTests.swift:188` (Choose Backup Folder…), `:191` (fallback "Export 3 Photos", optional)
- `UncloudTests/AutoResumeTests.swift:66, :70` (AutoResumeStatus text is in ProgressCard, chunk 4; **chunk 2 owns this
  test file**, and chunk 4 sends the final text to chunk 2, or chunk 4 makes the change and chunk 2 updates these two lines
  in its PR, coordinated in section 7), `:158` (the Activity line from ExportModel:1787)
- `UncloudTests/SessionsAndDriveCheckTests.swift:239` (onDriveSummaryText)
- `UncloudTests/ICloudResumeExportTests.swift:143, :176, :432, :490–492, :501`
- `UncloudTests/LayoutChangeConfirmationTests.swift:30, :54, :94, :115, :126–127`
- `UncloudTests/FolderLayoutAndSelectionTests.swift:55–59`
- `UncloudTests/LibrarySourceWordingTests.swift:8–9`
- `UncloudTests/ICloudDiagnosticsTests.swift:124`
- `UncloudTests/SessionRecorderTests.swift:244`
- Check, probably unchanged: `UncloudTests/SessionStoreTests.swift:158`, `UncloudTests/StorageEstimateTests.swift:312–314`

Acceptance: `grep -rnE '"[^"]*\b(item|items|Item|Items|destination|icloudpd|bridge|session|set-aside|Choose Resume)\b' Uncloud/Model Uncloud/Export Uncloud/Views/ExportHistoryView.swift Uncloud/Views/ExportSessionDetailView.swift`
shows only logger lines, file and argument names, and the deliberate icloudpd mentions. All of the test files above pass.
`ICloudFailure.libraryIndexing.message` and `.setupIncomplete.message` are still compared by equality in LibraryWindow,
which keeps working because both sides use the constant.

### Chunk 3: Shell, navigation, onboarding, Settings

Owns: `App/UncloudApp.swift`, `App/ExportCommands.swift`, `Views/MenuBarContent.swift`, `Views/LibraryWindow.swift`,
`Views/LibraryView.swift`, `Views/LibraryGrid.swift`, `Views/LandingView.swift`, `Views/BenefitsCarousel.swift`,
`Views/HowItWorksSteps.swift`, `Views/GettingStartedView.swift`, `Views/PhotosAccessView.swift`,
`Views/ICloudSignInSheet.swift`, `Views/SettingsView.swift`, `Views/NewPhotosViews.swift`, `Views/AppLogo.swift`.

Work: 3.1, 3.2, section 4 (all menus, the menu bar extra, the File › Photos From submenu, and the Edit › Delete from
iCloud / Recover commands consuming `FocusedValues.cleanupCommand`), 5.2, 5.3, 5.7. LimitedAccessNotice's *strings*
belong here. Its layout (no GroupBox) also lives in PhotosAccessView.swift, so it is done here too.

Tests to update: `UncloudTests/LandingSnapshotTests.swift` (only if it references the carousel; today it doesn't).
`UIRefreshSnapshotTests` renders `LibraryWindow()`, `LandingView()` and `SettingsView()` with no-argument inits, so keep
them that way and nothing needs editing.

Acceptance:
- The menus match section 4. Nothing is hidden that should be disabled. ⌘1–⌘4 follow the new sidebar order.
- Edit › Delete from iCloud… only opens the existing typed confirmation, is disabled unless `canRequestConfirmation`, and
  is never triggered by Return.
- The landing page has no auto-advancing element, and Reduce Motion has nothing left to stop.
- The sidebar has no `IconTile`.
- VoiceOver: the sidebar Backup row still reads its value. The landing column reads headline, subtitle, Sign In to iCloud…,
  Use Photos on This Mac, then the three benefit lines.

### Chunk 4: Backup pane

Owns: `Views/BackupPane.swift` (including `SectionTitle`), `Views/BackupHero.swift`, `Views/ProgressCard.swift`
(including `AutoResumeStatus`), `Views/CheckDriveViews.swift`, `Views/BackupToolSheets.swift`,
`Views/ActivitySection.swift`. It is also the only chunk that edits `UncloudTests/UIRefreshSnapshotTests.swift`,
`UncloudTests/DesignSnapshotTests.swift` and `UncloudTests/NewPhotosSnapshotTests.swift`, and only when strictly needed.

Work: the 3.3 rows for these files, and 5.1 items 1–5 and 7–9. Activity becomes a disclosure row placed after
`ExportHistoryView` in the pane's Form (ActivitySection gets `init(asRow: Bool = false)`, so its current init stays
valid). Adds the Backup toolbar's Show in Finder item.

Tests to update:
- `UncloudTests/BackupHeroContentTests.swift` (every title at :44–:148; the symbols are unchanged)
- The AutoResumeStatus text lines in `UncloudTests/AutoResumeTests.swift:66, :70` (coordinated with chunk 2, section 7)
- The snapshot files above, only if an init must change (it shouldn't)

Acceptance:
- At 1000×700, idle with new photos: hero, Backup Folder and Folders are all visible without scrolling. The pane shows
  exactly one prominent button. There's no `IconTile` except the hero's.
- While exporting: hero "Exporting… 42%", the bar, one counts line and Pause/Cancel, with no second status line.
- Interrupted: an orange hero, the count line, Resume Export (prominent) and Start Over.
- Every removed caption exists as `.help` and `.accessibilityHint`.
- Free Up Space is visible but disabled for iCloud.
- The `BackupHeroContent` precedence is unchanged (the existing precedence tests pass untouched).

### Chunk 5: Clean Up iCloud, Browse Backup, tool sheets

Owns: `Views/CleanupView.swift`, `Views/BrowseBackupView.swift`, `Views/BrowseMapView.swift`,
`Views/BrowsePhotoViews.swift`, `Views/VerifyBackupSheet.swift`, `Views/FindDuplicatesSheet.swift`,
`Views/FreeUpSpaceSheet.swift`. Test files: `UncloudTests/CleanupSnapshotTests.swift`,
`UncloudTests/DuplicateSnapshotTests.swift`, `UncloudTests/BrowseBackupSnapshotTests.swift`.

Work: 3.4, 5.4 (the scaffolds for Verify, Duplicates and Free Up Space; CheckDriveResultsSheet belongs to chunk 4, and
ExportSessionDetailView and ICloudSignInSheet to chunks 2 and 3, each adopting the scaffold in its own file), 5.5, 5.6.
`CleanupGridView` publishes `.focusedValue(\.cleanupCommand, …)` from its grid.

Tests to update: the three snapshot files above, only if an init changes (keep `CleanupGridView(...)`,
`CleanupConfirmationSheet(...)`, `FindDuplicatesSheet(...)`, `BrowseBackupView(...)` and `IndexingBanner(...)` as they
are). `UncloudTests/ICloudCleanupTests.swift` asserts helper-originated messages (:197, :369, :393, :505) that this plan
doesn't change, so leave it.

Acceptance:
- The confirmation sheets keep exactly: the typed-number gate, the red prominent Delete only after the typed match,
  `.cancelAction` on Cancel, and Recover as `.defaultAction`.
- Free Up Space still needs both its own confirmation and the system alert.
- Duplicates still asks before moving copies to the Trash.
- Every sheet has a title and a regular-size footer.
- Failure details show no internal IDs.
- "1 photo" (not "1 photos") in the Browse inspector.
- `StatusBanner` is used for the Clean Up status and the indexing progress.

---

## 7. Coordination and order

1. Merge chunk 1.
2. Chunks 2–5 run in parallel against it.
3. The one shared touchpoint is `AutoResumeTests.swift:66/70`. Chunk 4 changes `AutoResumeStatus.text`, and chunk 2 owns
   the test file. Chunk 4 posts the final strings from 3.3 (they are fixed in this plan), and chunk 2 updates those two
   lines. Whichever merges second rebases and runs `AutoResumeTests`.
4. `ExportHistoryView` keeps calling `SectionTitle(title:symbol:tint:)`. Chunk 4 keeps that init compiling (it just stops
   drawing the tile), so chunk 2 and chunk 4 never touch each other's files.
5. After everything has merged: delete the deprecated tokens and `BenefitsCarousel` if unused, re-render the snapshot set
   (`scratchpad/polish/before|after`), and run the full test suite once.

---

## 8. Constraints to keep

- **Trademarks**: no Apple logos or glyphs (no `apple.logo` symbol, no Apple artwork). "iCloud", "iCloud Photos",
  "Photos", "Apple Account" and "Mac" are used only descriptively, never as the lead of a marketing headline, and never in
  a way that suggests Apple made or endorses Uncloud. Don't use "Sign In with Apple" phrasing (Apple's feature name).
  Keep the honest icloudpd attribution once each in Sign In and Getting Started.
- **Accessibility**: keep every existing `accessibilityLabel`, `accessibilityValue`, `accessibilityHint` and
  announcement, and add hints for removed captions. Status never relies on colour alone (symbol plus text). Reduce Motion
  gates every new animation (`Tokens.Motion.animation(reduceMotion)`). Increase Contrast keeps the IconTile stroke where
  tiles remain. Text contrast stays at system `.primary` and `.secondary`.
- **Swift 6 strict concurrency**: no new `@unchecked Sendable`, and no new non-isolated mutable statics. FocusedValue
  payloads hold `@MainActor` closures.
- **Destructive-action safety**: no gate removed or loosened. That covers the typed number for iCloud deletion, the two
  confirmations for Free Up Space, the Trash confirmation for duplicates, "Delete and Export Again" as `.destructive`
  with Cancel, the layout-change confirmation, the sign-out confirmation, destructive buttons never `.defaultAction`, and
  Return never confirming a delete. New menu commands only *open* existing confirmations.
- **Behaviour**: no change to what exports, what's selected by default (everything), the default layout (By Month), or
  when buttons are enabled. This is a presentation and wording pass.

---

## 9. Not verified

- How the plain sidebar symbols and the floating `StatusBanner` look on macOS 26/27 glass (no live window renders exist;
  check manually).
- Whether ⌘⌫ in the Edit menu conflicts with the grid's own key handling in LibraryGrid (test it in the app; fall back to
  no shortcut if it does).
- Whether `Picker(.menu)` in a grouped Form on macOS 14 shows the menu items' secondary example lines (if not, the
  caption under the picker covers it).
