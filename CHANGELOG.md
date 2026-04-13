# Changelog

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
