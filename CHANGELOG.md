# Changelog

## v6.12 - 2026-10-01

### Changed
- With no DDM enforcement, the script nudges again, but only toward a release
  that has cleared a release hold (`releaseHoldDays`, default 2, counted from
  SOFA's `ReleaseDate` plus one day) and that `softwareupdate --list` on the
  Mac is offering. A release Software Update is still deferring gets no dialog.
- The dialog has **Open Software Update** and **Later** buttons. Software
  Update opens only when the user clicks; the script no longer opens it before
  showing the dialog. The no-enforcement dialog labels the version
  "Latest macOS".
- The version pin (parameter 4) caps a Mac at the higher of the pin and its
  current major, so a Mac already on a newer major still gets that major's
  updates.

### Added
- Meeting check. While Teams, Zoom, Webex, a PowerPoint slide show, Keynote or
  a Chrome screen wake lock (Google Meet) holds a display-sleep assertion, the
  dialog waits, checking every 5 minutes for up to 75 minutes. A meeting that
  outlasts the wait skips a no-enforcement nudge for the day; a DDM reminder is
  shown anyway. Skipped within 24 hours of a DDM deadline.
- Install Tonight check. If `install.log` shows the user queued this version
  for tonight and the 2:00 AM window hasn't started, the reminder is skipped
  for the day. A DDM deadline before the window overrides it.
- The dialog runs in a detached presenter so the Jamf policy finishes in
  seconds. The presenter logs to `/var/log/update_reminder.log`, uses a lock so
  a second run can't stack another dialog, and skips the dialog if the console
  user changed while it waited.
- `softwareupdate --list` runs under a time limit (`softwareUpdateListSeconds`)
  and is force-stopped if it ignores SIGTERM.
- An unanswered dialog closes itself after `dialogTimeoutSeconds` (4 hours) and
  is logged, so an ignored reminder can't hold the lock and block the next day's.
- The macOS icon downloads with a time limit into a private per-run folder under
  `/var/tmp` that is removed when the presenter ends, instead of a fixed path.
- End-to-end test suite (`test_update_reminder.sh`) that runs the real script
  under Jamf-like conditions, plus a test that keeps the script's functions
  identical to `sofa_functions.sh`. Fixtures captured from real Macs live in
  `fixtures/`.

## v6.11 - 2026-10-01

### Changed
- Reminders only for active DDM enforcement. With no enforcement the script
  exited quietly instead of recommending SOFA's newest release, which on
  release day is a minor nobody has tested yet. Replaced by the release hold
  and Software Update check in 6.12.
- A deadline that can't be parsed exits instead of falling back to the
  standard dialog.

## v6.10 - 2026-09-16

### Fixed
- A slow link could return a SOFA download that was non-empty but cut short.
  It was accepted, failed to parse, and the script exited with "No supported OS
  version found". Downloads now have to parse as a SOFA feed with at least one
  OS version, or the script retries. curl uses `--connect-timeout 5 -m 15`
  (about 55 seconds worst case over 3 attempts).

## v6.9 - 2026-09-15

### Added
- Maximum major version pin via Jamf script parameter 4. With `26`, the script
  recommends the newest 26.x this hardware supports and ignores DDM
  declarations for a higher major. Blank means no cap. Non-numeric values are
  ignored with a warning.

## v6.8 - 2026-04-13

### Fixed
- SOFA added a `DeviceScope` field to `SecurityReleases`. Universal releases
  (like 26.4.1, 26.4, 26.3.1) now omit `SupportedDevices` entirely; only
  device-specific releases (like a Neo-only build) still carry the list.
  Previous versions treated missing `SupportedDevices` as "skip this release",
  silently falling through to older releases that still had the field
  populated - effectively recommending downgrades across the fleet.
  `find_target_for_device` and `is_version_for_device` now fall back to
  `Latest.SupportedDevices` for the OS family when a SecurityRelease omits its
  own list.
- `find_enforced_update` now prefers the highest-version DDM declaration when
  multiple apply, with earliest deadline as the tiebreaker for same-version
  declarations. Prevents a stale older enforcement (e.g., a 26.4 declaration
  whose deadline has passed) from beating a newer 26.4.1 enforcement that
  arrived in the same plist.

### Added
- Downgrade safety guard in the main script. After targeting resolves, if the
  chosen version is below the current version the script logs a `WARNING:` and
  exits clean. Defense-in-depth against future SOFA schema drift.
- Bounded SOFA fetch retry: 3 attempts, 5 second timeout each, 2 second sleep
  between attempts. Roughly 19 seconds worst case. Replaces the previous
  single-shot fetch.
- Four new tests covering the real SOFA universal-release structure and the
  stale-DDM-declaration scenario. 43/43 passing.

## v6.7 - 2026-03-24

### Fixed
- DDM enforcement filter now verifies hardware compatibility via SOFA
  `SupportedDevices` rather than comparing version numbers. Previous versions
  would pass a Neo-only release (like 26.3.2) on non-Neo hardware because the
  comparison was purely numerical.
- Dialog color for required version: `:#007A00[text]` hex syntax is not
  supported by SwiftDialog; switched to the supported `:green[text]` named
  color.
- Past-due DDM deadlines now display the actual date instead of a literal
  "Past Due" string.

### Changed
- Extracted DDM filtering into `find_enforced_update` (tested). Main script
  DDM section is now plist reading + one function call.
- Dialog height raised from 450 to 500 so the support ticket link isn't
  clipped on shorter content.

## v6.6 - 2026-03-17

### Added
- DDM enforcement detection via Apple's persistent declaration store
  (`/var/db/softwareupdate/SoftwareUpdateDDMStatePersistence.plist`). Covers
  both scheduled MDM pushes and Blueprint "enforce latest within N days"
  policies. Previous `install.log` grep only caught scheduled pushes;
  Blueprints never wrote there.
- Script filters DDM declarations against SOFA `SupportedDevices` so a
  declaration targeting hardware the machine doesn't have (e.g., a Neo-only
  build enforced fleet-wide) is ignored.
- Urgent dialog layout when DDM enforcement is active: caution overlay,
  deadline, days remaining, and stronger messaging.

## v6.5 - 2026-03-12

### Added
- Hardware-aware update targeting. `find_target_for_device` walks SOFA
  `OSVersions` newest-to-oldest and returns the highest release whose
  `SupportedDevices` list includes this machine's board ID. A device-specific
  release (like a Neo-only build) only targets that hardware; the rest of the
  fleet is unaffected.
- Cross-version targeting. A macOS 15 machine whose hardware supports Tahoe is
  pointed at Tahoe, not stuck on 15.
- SOFA logic extracted into `sofa_functions.sh` with a test suite covering
  targeting behavior. Inlined into the main script for Jamf deployment.

### Fixed
- First-match-wins ordering bug in SecurityReleases. If SOFA ever ordered
  entries oldest-first, the old code returned the first match rather than the
  newest eligible one. Now scans the full list and tracks the highest
  `is-at-least` match.
