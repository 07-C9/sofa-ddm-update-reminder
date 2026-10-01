#!/bin/zsh
# ABOUTME: macOS update reminder using SwiftDialog, SOFA feed hardware-aware targeting, and DDM log reading.
# ABOUTME: Self-contained script for Jamf deployment - no external dependencies.

####################################################################################################
# HYBRID UPDATE REMINDER - UNIVERSAL EDITION v6.12
#
# A "Set it and forget it" script that handles both standard updates and DDM enforcement.
#
# FEATURES:
# 1. Self-Correcting Shell: Automatically re-launches in Zsh if run as 'sh' (fixes syntax errors).
# 2. DDM Detection: Reads Apple's SoftwareUpdateDDMStatePersistence plist for both
#    scheduled MDM pushes and Blueprint enforcement policies.
# 3. Native Branding: Uses Markdown to render remote logos perfectly without local resizing.
# 4. SOFA Feed Integration: Checks against MacAdmins.io SOFA feed for truth.
# 5. Hardware-Aware Targeting: Matches updates to device board ID via SOFA SupportedDevices.
# 6. Daily Nudge Without DDM: with no DDM enforcement, recommends the newest
#    release only after it has cleared a release hold AND Software Update on the
#    Mac is offering it.
# 7. Respectful Timing: waits out meetings and presentations before showing the
#    dialog.
# 8. User-Driven Settings: the dialog's button opens Software Update; nothing
#    opens on its own.
####################################################################################################

# --- SAFETY CHECK: Force Zsh Execution ---
# If the script is run with 'sh' or 'bash', this block re-executes it with 'zsh' automatically.
# This prevents "autoload not found" errors if an admin or MDM agent uses the wrong shell.
if [ -z "$ZSH_VERSION" ]; then
    echo "Wrong shell detected. Re-launching in Zsh..."
    exec /bin/zsh "$0" "$@"
fi

####################################################################################################
# CONFIGURATION
####################################################################################################

# Path to SwiftDialog binary
swiftDialogPath="/usr/local/bin/dialog"

# Direct URL to your organization's logo (PNG/JPG, ideally transparent PNG ~300-500px wide).
# SwiftDialog loads this remotely - no local download required.
corporateLogoURL="https://dli-engineering.s3.us-west-2.amazonaws.com/PSD.png"

# URL that opens when users click "open a support ticket"
support_ticket_url="https://psd401.freshservice.com/support/tickets/new"

# Icon overlaid on the dialog during DDM enforcement (red stop sign or yellow triangle)
# Options: AlertStopIcon.icns  |  AlertCautionIcon.icns
cautionIcon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns"

# Set to "true" to force-show the dialog on any machine regardless of update status.
# Use this to test UI appearance. Set back to "false" before deploying.
demoMode="false"

# Maximum major macOS version to recommend (Jamf script parameter 4).
# Set to e.g. "26" to hold the fleet on macOS 26 while a newer major (27) is
# hidden via a Blueprint or deferral: the script then recommends the newest
# 26.x this hardware supports and never suggests 27. A Mac already on a newer
# major than the pin (e.g. restored onto 27) is capped at its own major instead,
# so it still gets that major's updates. Applies to both the standard reminder
# and DDM enforcement. Leave blank ($4 unset) to always recommend the newest
# supported version.
maxMajorPin="$4"
if [[ -n "$maxMajorPin" && ! "$maxMajorPin" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Ignoring non-numeric version pin '$maxMajorPin' (parameter 4)."
    maxMajorPin=""
fi

# Days a new macOS release is held before the reminder recommends it when no DDM
# enforcement is active. Counted from SOFA's ReleaseDate plus one day, matching
# a Software Update minor deferral of the same length.
releaseHoldDays=2

# Seconds to wait for `softwareupdate --list` before giving up quietly
softwareUpdateListSeconds=90

# Log and lock for the presenter that waits out meetings and shows the dialog
reminderLogPath="/var/log/update_reminder.log"
reminderPidPath="/var/run/update_reminder.pid"

# Apps or assertion names that mean a meeting or presentation is on screen
# (matched against `pmset -g assertions` display-sleep lines)
meetingAssertionApps=( "MSTeams" "zoom.us" "Webex" "Slide Show" "Keynote" "Blink Wake Lock" )

# Meeting wait: re-check every meetingCheckSeconds, at most meetingMaxChecks times
# (300 x 15 = 75 minutes)
meetingCheckSeconds=300
meetingMaxChecks=15

# Seconds before an unanswered dialog closes itself, so an ignored reminder
# cannot hold the run lock and block the next day's reminder (14400 = 4 hours)
dialogTimeoutSeconds=14400

# Software Update pane opened by the dialog's button
softwareUpdateURL="x-apple.systempreferences:com.apple.Software-Update-Settings.extension"

####################################################################################################
# END CONFIGURATION
####################################################################################################

# --- SOFA FUNCTIONS ---

# sofa_is_usable <sofaJSON>
#
# Returns 0 if the payload parses as a SOFA feed with at least one OS version,
# 1 otherwise. Guards against empty, truncated, or non-JSON downloads that are
# non-empty but unparseable (a curl body cut short by a timeout, or a
# captive-portal HTML page). find_target_for_device treats an unparseable feed
# as "no supported version", so the fetch loop must reject junk and retry
# rather than accept the first non-empty response.
sofa_is_usable() {
    local data="$1"
    [[ -z "$data" ]] && return 1
    local n
    n=$(echo "$data" | plutil -extract "OSVersions" raw -o - - 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# find_target_for_device <boardID> <sofaJSON> [maxMajor]
#
# Walks OSVersions from newest to oldest. For each OS, scans all SecurityReleases and
# returns the highest version this device supports. Does not assume feed ordering.
# Falls back to Latest if SecurityReleases is empty.
#
# This means a macOS 15 machine whose hardware supports Tahoe will be targeted
# for the latest Tahoe release it's eligible for - not stuck on macOS 15.
#
# maxMajor (optional): pin the recommendation to a major version. OS families
# whose major is higher than maxMajor are skipped, so a fleet held on macOS 26
# via a Blueprint still gets the newest 26.x rather than being pushed to 27.
# Empty maxMajor means no cap (recommend the newest supported version).
#
# Outputs a single line: <productVersion> <osIndex>
# Returns 0 if a supported version was found, 1 if not.
find_target_for_device() {
    local boardID="$1"
    local sofaData="$2"
    local maxMajor="$3"

    autoload -Uz is-at-least

    # Declare all loop variables up front to avoid zsh's typeset re-declaration
    # printing previous values to stdout on subsequent iterations
    local osCount osIdx osLatest osMajor latestDevices relCount ridx relVer relDevices
    local bestVer bestOsIdx

    osCount=$(echo "$sofaData" | plutil -extract "OSVersions" raw -o - - 2>/dev/null)
    if [[ -z "$osCount" || "$osCount" -eq 0 ]]; then
        return 1
    fi

    for (( osIdx=0; osIdx<osCount; osIdx++ )); do
        osLatest=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.ProductVersion" raw -o - - 2>/dev/null)

        # Skip OS families above the version pin, if one is set
        osMajor="${osLatest%%.*}"
        if [[ -n "$maxMajor" && -n "$osMajor" && "$osMajor" -gt "$maxMajor" ]]; then
            continue
        fi

        # If no board ID was detected, fall back to absolute latest (within the pin)
        if [[ -z "$boardID" ]]; then
            echo "$osLatest $osIdx"
            return 0
        fi

        # Cache Latest.SupportedDevices once per OS. Universal SecurityReleases
        # omit SupportedDevices in SOFA's current schema - they apply to whatever
        # hardware Latest lists for this OS family.
        latestDevices=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.SupportedDevices" json -o - - 2>/dev/null)

        # Walk all SecurityReleases and track the highest version this device supports.
        # Does not assume feed ordering - always returns the newest eligible release.
        # (e.g., 26.3.2 for Neo only while general fleet stays on 26.3.1)
        relCount=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases" raw -o - - 2>/dev/null)
        if [[ -n "$relCount" && "$relCount" -gt 0 ]]; then
            bestVer=""
            bestOsIdx=""
            for (( ridx=0; ridx<relCount; ridx++ )); do
                relVer=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases.$ridx.ProductVersion" raw -o - - 2>/dev/null)
                relDevices=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases.$ridx.SupportedDevices" json -o - - 2>/dev/null)
                # Universal release: no SupportedDevices means "applies to Latest's list"
                if [[ -z "$relDevices" ]]; then
                    relDevices="$latestDevices"
                fi
                if [[ -n "$relDevices" ]] && echo "$relDevices" | grep -q "\"$boardID\""; then
                    # Update best if this release is newer (is-at-least A B = true if B >= A)
                    if [[ -z "$bestVer" ]] || ! is-at-least "$relVer" "$bestVer"; then
                        bestVer="$relVer"
                        bestOsIdx="$osIdx"
                    fi
                fi
            done
            if [[ -n "$bestVer" ]]; then
                echo "$bestVer $bestOsIdx"
                return 0
            fi
        else
            # No SecurityReleases - fall back to Latest
            if [[ -n "$latestDevices" ]] && echo "$latestDevices" | grep -q "\"$boardID\""; then
                echo "$osLatest $osIdx"
                return 0
            fi
        fi
    done

    # Board ID not found in any OS version
    return 1
}

# is_version_for_device <version> <boardID> <sofaJSON>
#
# Checks whether a specific macOS version is available for a given device
# by looking up SupportedDevices in SOFA's SecurityReleases and Latest.
# Returns 0 if the version is available for the device, 1 if not.
is_version_for_device() {
    local version="$1"
    local boardID="$2"
    local sofaData="$3"

    # No board ID = assume compatible
    [[ -z "$boardID" ]] && return 0

    local osCount osIdx relCount ridx relVer relDevices osLatest latestDevices

    osCount=$(echo "$sofaData" | plutil -extract "OSVersions" raw -o - - 2>/dev/null)
    [[ -z "$osCount" || "$osCount" -eq 0 ]] && return 1

    for (( osIdx=0; osIdx<osCount; osIdx++ )); do
        # Cache Latest.SupportedDevices once per OS as fallback for universal releases
        latestDevices=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.SupportedDevices" json -o - - 2>/dev/null)

        # Check SecurityReleases for this version
        relCount=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases" raw -o - - 2>/dev/null)
        if [[ -n "$relCount" && "$relCount" -gt 0 ]]; then
            for (( ridx=0; ridx<relCount; ridx++ )); do
                relVer=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases.$ridx.ProductVersion" raw -o - - 2>/dev/null)
                if [[ "$relVer" == "$version" ]]; then
                    relDevices=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases.$ridx.SupportedDevices" json -o - - 2>/dev/null)
                    # Universal release: no SupportedDevices means "applies to Latest's list"
                    if [[ -z "$relDevices" ]]; then
                        relDevices="$latestDevices"
                    fi
                    if [[ -n "$relDevices" ]] && echo "$relDevices" | grep -q "\"$boardID\""; then
                        return 0
                    fi
                    # Version found but board ID not supported - keep checking other OS entries
                fi
            done
        fi

        # Check Latest for this version
        osLatest=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.ProductVersion" raw -o - - 2>/dev/null)
        if [[ "$osLatest" == "$version" ]]; then
            if [[ -n "$latestDevices" ]] && echo "$latestDevices" | grep -q "\"$boardID\""; then
                return 0
            fi
        fi
    done

    return 1
}

# find_enforced_update <ddmEntries> <currentVersion> <boardID> <sofaData> [maxMajor]
#
# Filters DDM enforcement entries to find the most urgent applicable one.
# Skips versions the machine already has and versions not available for
# this hardware per SOFA SupportedDevices. Returns the earliest deadline.
#
# maxMajor (optional): same version pin as find_target_for_device. Enforcement
# declarations for a major above the pin are skipped, so the reminder stays
# consistent with a fleet pinned to an older major.
#
# ddmEntries: newline-separated "version|date" lines (from plist parsing)
# Outputs: "version|deadline" for the most urgent enforcement
# Returns 0 if an applicable enforcement was found, 1 if not.
find_enforced_update() {
    local ddmEntries="$1"
    local currentVersion="$2"
    local boardID="$3"
    local sofaData="$4"
    local maxMajor="$5"

    autoload -Uz is-at-least

    local tVer tDate tEpoch tMajor
    local bestEpoch=""
    local bestVer=""
    local bestDate=""

    [[ -z "$ddmEntries" ]] && return 1

    while IFS='|' read -r tVer tDate; do
        [[ -z "$tVer" || -z "$tDate" ]] && continue

        # Skip enforcement above the version pin, if one is set
        tMajor="${tVer%%.*}"
        if [[ -n "$maxMajor" && -n "$tMajor" && "$tMajor" -gt "$maxMajor" ]]; then
            continue
        fi

        # Skip versions this machine already has
        if is-at-least "$tVer" "$currentVersion"; then
            continue
        fi

        # Skip versions not available for this hardware per SOFA SupportedDevices
        if [[ -n "$sofaData" ]] && ! is_version_for_device "$tVer" "$boardID" "$sofaData"; then
            continue
        fi

        tEpoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$tDate" "+%s" 2>/dev/null)
        [[ -z "$tEpoch" ]] && continue

        # Prefer higher version - installing the newer release satisfies every
        # older enforcement and avoids picking a stale leftover declaration.
        # Earliest deadline is only the tiebreaker for declarations of the same version.
        if [[ -z "$bestVer" ]] || ! is-at-least "$tVer" "$bestVer"; then
            bestEpoch="$tEpoch"
            bestVer="$tVer"
            bestDate="$tDate"
        elif [[ "$tVer" == "$bestVer" && "$tEpoch" -lt "$bestEpoch" ]]; then
            bestEpoch="$tEpoch"
            bestDate="$tDate"
        fi
    done <<< "$ddmEntries"

    if [[ -n "$bestVer" ]]; then
        echo "${bestVer}|${bestDate}"
        return 0
    fi

    return 1
}

# effective_major_cap <pin> <currentVersion>
#
# The version pin (Jamf parameter 4) holds Macs below it back from a newer major.
# It never stops a Mac that is already on a newer major, for example one restored
# onto macOS 27, from getting that major's own updates. Outputs the cap to use:
# the higher of the pin and the current major, or empty when no pin is set.
effective_major_cap() {
    local pin="$1"
    local currentMajor="${2%%.*}"
    if [[ -z "$pin" ]]; then
        echo ""
        return 0
    fi
    if [[ "$currentMajor" =~ ^[0-9]+$ ]] && (( currentMajor > pin )); then
        echo "$currentMajor"
    else
        echo "$pin"
    fi
}

# release_epoch_for_version <version> <sofaJSON>
#
# Looks up the SOFA ReleaseDate for an exact macOS version, checking
# SecurityReleases first and then Latest, and prints it as epoch seconds.
# SOFA publishes day-granular dates at midnight UTC, e.g. 2026-09-28T00:00:00Z.
# Returns 1 when the version is not in the feed or has no parseable date.
release_epoch_for_version() {
    local version="$1"
    local sofaData="$2"
    local osCount osIdx relCount ridx relVer relDate osLatest relEpoch
    osCount=$(echo "$sofaData" | plutil -extract "OSVersions" raw -o - - 2>/dev/null)
    [[ "$osCount" =~ ^[0-9]+$ ]] || return 1
    relDate=""
    for (( osIdx=0; osIdx<osCount; osIdx++ )); do
        relCount=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases" raw -o - - 2>/dev/null)
        [[ "$relCount" =~ ^[0-9]+$ ]] || relCount=0
        for (( ridx=0; ridx<relCount; ridx++ )); do
            relVer=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases.$ridx.ProductVersion" raw -o - - 2>/dev/null)
            if [[ "$relVer" == "$version" ]]; then
                relDate=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.SecurityReleases.$ridx.ReleaseDate" raw -o - - 2>/dev/null)
                break 2
            fi
        done
        osLatest=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.ProductVersion" raw -o - - 2>/dev/null)
        if [[ "$osLatest" == "$version" ]]; then
            relDate=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.ReleaseDate" raw -o - - 2>/dev/null)
            break
        fi
    done
    [[ -z "$relDate" ]] && return 1
    relEpoch=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$relDate" "+%s" 2>/dev/null)
    [[ "$relEpoch" =~ ^[0-9]+$ ]] || return 1
    echo "$relEpoch"
}

# release_cleared_hold <version> <sofaJSON> <holdDays> <nowEpoch>
#
# Decides whether a release is old enough to recommend when no DDM enforcement
# is ordering it. The hold ends holdDays plus one day after SOFA's ReleaseDate:
# SOFA dates are midnight UTC while Apple publishes in the US daytime and counts
# its own deferral from its release date, so the extra day keeps the reminder
# from getting ahead of the Software Update deferral.
# Returns 0 when the hold has ended, 1 while it is running, 2 when SOFA has no
# usable release date for the version.
release_cleared_hold() {
    local version="$1"
    local sofaData="$2"
    local holdDays="$3"
    local nowEpoch="$4"
    local relEpoch
    relEpoch=$(release_epoch_for_version "$version" "$sofaData") || return 2
    (( nowEpoch >= relEpoch + (holdDays + 1) * 86400 )) && return 0
    return 1
}

# su_offers_version <version> <softwareupdateListText>
#
# Returns 0 when `softwareupdate --list` output offers exactly this macOS
# version. Software Update hides releases that are still deferred, so this is
# the Mac's own answer to "would the user find this update if they looked".
# Only "Title: macOS ..." lines count, so Safari or another product with the
# same version number never matches, and a line marked "Deferred: YES" is not
# an offer. Matches the "Version: X," field so 27.0.1 never matches 27.0 or
# 27.0.10.
su_offers_version() {
    local version="$1"
    local listText="$2"
    local line
    [[ -z "$version" ]] && return 1
    while IFS= read -r line; do
        [[ "$line" == *"Title: macOS "* ]] || continue
        [[ "$line" == *", Version: ${version},"* ]] || continue
        [[ "$line" == *"Deferred: YES"* ]] && continue
        return 0
    done <<< "$listText"
    return 1
}

# list_offered_updates <outFile> <maxSeconds>
#
# Runs `softwareupdate --list` into outFile with a time limit, so an unreachable
# catalog can never hold the Jamf policy open. At the limit it sends SIGTERM,
# allows 2 seconds, then sends SIGKILL, so a client that ignores SIGTERM cannot
# hang the script either. Returns 0 when the command finished, 1 when it had to
# be stopped at the limit.
list_offered_updates() {
    local outFile="$1"
    local maxSeconds="$2"
    local pid ticks=0
    softwareupdate --list > "$outFile" 2>&1 < /dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( ticks >= maxSeconds * 10 )); then
            kill "$pid" 2>/dev/null
            ticks=0
            while kill -0 "$pid" 2>/dev/null && (( ticks < 20 )); do
                /bin/sleep 0.1
                (( ticks++ ))
            done
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 1
        fi
        /bin/sleep 0.1
        (( ticks++ ))
    done
    wait "$pid" 2>/dev/null
    return 0
}

# meeting_in_progress <pmsetAssertionsText> <app>...
#
# Returns 0 when `pmset -g assertions` shows a listed meeting or presentation app
# keeping the display awake (NoDisplaySleepAssertion or PreventUserIdleDisplaySleep
# on a per-process line). Each app string is matched against the whole line, so it
# can name a process ("zoom.us") or an assertion name ("Slide Show"). coreaudiod is
# ignored because it asserts for any audio, and system-sleep-only assertions such as
# caffeinate's default do not count.
meeting_in_progress() {
    local assertions="$1"
    shift
    local line app
    [[ -z "$assertions" ]] && return 1
    while IFS= read -r line; do
        [[ "$line" == *"pid "*"("*"):"* ]] || continue
        [[ "$line" == *NoDisplaySleepAssertion* || "$line" == *PreventUserIdleDisplaySleep* ]] || continue
        [[ "$line" == *"(coreaudiod)"* ]] && continue
        for app in "$@"; do
            [[ "$line" == *"$app"* ]] && return 0
        done
    done <<< "$assertions"
    return 1
}

# present_reminder
#
# Runs detached from the Jamf policy. Waits out a meeting or presentation
# (meetingCheckSeconds x meetingMaxChecks), then shows the reminder dialog to
# the console user and opens Software Update only when they click the button.
# A meeting that outlasts the wait skips today's nudge; a DDM reminder is shown
# anyway. Never shows the dialog if the console user changed while waiting.
# Every path ends by removing the icon folder and the run lock.
present_reminder() {
    local checks=0 rc show="true" waitMinutes=$(( meetingCheckSeconds * meetingMaxChecks / 60 ))
    echo "$(date '+%Y-%m-%d %H:%M:%S') Reminder for macOS $reminderVersion (DDM enforcement: $isDDM)"
    if [[ "$skipMeetingCheck" != "true" ]]; then
        while meeting_in_progress "$(pmset -g assertions 2>/dev/null)" "${meetingAssertionApps[@]}"; do
            if (( checks >= meetingMaxChecks )); then
                if [[ "$isDDM" == "true" ]]; then
                    echo "Meeting or presentation still active after $waitMinutes minutes - showing the required-update reminder anyway."
                else
                    echo "Meeting or presentation still active after $waitMinutes minutes - skipping today's reminder."
                    show="false"
                fi
                break
            fi
            (( checks++ ))
            echo "Meeting or presentation in progress (check $checks of $meetingMaxChecks) - waiting $meetingCheckSeconds seconds."
            sleep "$meetingCheckSeconds"
        done
    fi
    if [[ "$show" == "true" && "$(stat -f%Su /dev/console)" != "$currentUser" ]]; then
        echo "$currentUser is no longer the console user - skipping the reminder."
        show="false"
    fi
    if [[ "$show" == "true" ]]; then
        launchctl asuser "$currentUserID" sudo -u "$currentUser" "${dialogArgs[@]}"
        rc=$?
        if (( rc == 0 )); then
            echo "User clicked Open Software Update."
            launchctl asuser "$currentUserID" sudo -u "$currentUser" open "$softwareUpdateURL"
        elif (( rc == 4 )); then
            echo "Reminder closed itself after $(( dialogTimeoutSeconds / 3600 )) hours with no answer."
        else
            echo "User dismissed the reminder (dialog exit $rc)."
        fi
    fi
    [[ -n "$iconDir" ]] && rm -rf "$iconDir"
    rm -f "$reminderPidPath"
    echo "Presenter finished."
}

# --- Internal constants ---
scriptVersion="6.12-Universal"
sofaURL="https://sofafeed.macadmins.io/v2/macos_data_feed.json"
NL=$'\n'
assistance_message="${NL}${NL}If you encounter any issues with the update process or don't have enough storage, please [open a support ticket]($support_ticket_url)."

# --- Current User & Root Check ---
currentUser=$(stat -f%Su /dev/console)
currentUserID=$(id -u "$currentUser")

if [[ $(id -u) -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

if [[ -z "$currentUser" || "$currentUser" == "root" || "$currentUser" == "loginwindow" ]]; then
    echo "No valid user logged in. Exiting."
    exit 0
fi

# --- STEP 1: SOFA VERIFICATION ---
echo "=== Phase 1: Checking SOFA Feed ==="

currentVersion=$(sw_vers -productVersion)
currentBuild=$(sw_vers -buildVersion)

# Get device board ID for hardware compatibility checks
boardID=$(sysctl -n hw.target 2>/dev/null)
if [[ -z "$boardID" ]]; then
    boardID=$(ioreg -d2 -c IOPlatformExpertDevice | awk -F'"' '/board-id/{print $4}')
fi
echo "Device: $boardID | Current: $currentVersion ($currentBuild)"
majorCap=$(effective_major_cap "$maxMajorPin" "$currentVersion")
echo "Version pin: ${maxMajorPin:-none (recommend newest supported)} | Effective major cap: ${majorCap:-none}"

if [[ "$demoMode" == "true" ]]; then
    echo "DEMO MODE: Skipping SOFA check, forcing dialog display."
    latestVersion="26.3.1"
    targetMajor="26"
else
    # Fetch SOFA with bounded retry. Accept a response only if it parses as a
    # complete feed - a slow link can return a non-empty but truncated body that
    # is unparseable, which would otherwise be mistaken for "no supported version".
    # connect-timeout fails fast when there is no route; the longer max-time gives
    # the ~315KB body time to finish. ~55s worst case (3 x 15s + 2 x 2s sleep).
    sofaData=""
    for attempt in 1 2 3; do
        sofaData=$(curl -L --connect-timeout 5 -m 15 -s "$sofaURL")
        if sofa_is_usable "$sofaData"; then
            break
        fi
        echo "SOFA fetch attempt $attempt failed or returned an incomplete feed."
        sofaData=""
        [[ $attempt -lt 3 ]] && sleep 2
    done

    if [[ -z "$sofaData" ]]; then
        echo "WARNING: Could not fetch a complete SOFA feed after 3 attempts. Cannot verify update availability. Exiting."
        exit 0
    fi

    # Find the newest release this hardware supports across ALL OS versions.
    # Walks from newest OS (e.g., Tahoe) to oldest. A macOS 15 machine whose
    # hardware supports Tahoe will be targeted for Tahoe, not stuck on 15.
    targetResult=$(find_target_for_device "$boardID" "$sofaData" "$majorCap")
    if [[ $? -ne 0 || -z "$targetResult" ]]; then
        echo "ERROR: No supported OS version found for $boardID in SOFA feed. Exiting."
        exit 0
    fi

    latestVersion=$(echo "$targetResult" | awk '{print $1}')
    targetOSIndex=$(echo "$targetResult" | awk '{print $2}')
    targetMajor=$(echo "$latestVersion" | cut -d. -f1)

    echo "Target: $latestVersion (OS index $targetOSIndex)"

    # Safety: refuse to recommend a downgrade. If SOFA returns a version older
    # than current, something is wrong with the feed or our parser - exit clean.
    autoload -Uz is-at-least
    if ! is-at-least "$currentVersion" "$latestVersion"; then
        echo "WARNING: SOFA target $latestVersion is older than current $currentVersion. Exiting."
        exit 0
    fi

    if [[ "$currentVersion" == "$latestVersion" ]]; then
        # Version match, checking build
        allBuildsJSON=$(echo "$sofaData" | plutil -extract "OSVersions.$targetOSIndex.Latest.AllBuilds" json -o - - 2>/dev/null)
        if [[ -n "$allBuildsJSON" ]] && echo "$allBuildsJSON" | grep -q "\"$currentBuild\""; then
            echo "VERIFIED: System is on latest version and build. Exiting."
            exit 0
        fi
        # Fallback build check
        latestBuild=$(echo "$sofaData" | plutil -extract "OSVersions.$targetOSIndex.Latest.Build" raw -o - - 2>/dev/null)
        if [[ "$currentBuild" == "$latestBuild" ]]; then
            echo "VERIFIED: System is on latest build. Exiting."
            exit 0
        fi
    else
        echo "Update available."
    fi
fi

# --- STEP 2: CHECK FOR DDM ENFORCEMENT ---
echo "=== Phase 2: Analyzing DDM State ==="

autoload -Uz is-at-least
isDDM="false"
ddmVersion=""
ddmDeadline=""

# Read DDM enforcement state from Apple's persistent declaration store.
# Covers both scheduled MDM pushes and Blueprint enforcement policies.
ddmPlistPath="/var/db/softwareupdate/SoftwareUpdateDDMStatePersistence.plist"
echo "Checking DDM state persistence..."

if [[ -f "$ddmPlistPath" ]]; then
    declXML=$(plutil -extract "SUCorePersistedStatePolicyFields.Declarations" xml1 -o - "$ddmPlistPath" 2>/dev/null)

    if [[ -n "$declXML" ]]; then
        # Parse TargetOSVersion and TargetLocalDateTime from each declaration
        ddmEntries=$(echo "$declXML" | awk '
            /<dict>/ { depth++; if (depth == 2) { ver = ""; dt = "" } }
            /<\/dict>/ {
                depth--
                if (depth == 1 && ver != "" && dt != "") { print ver "|" dt }
            }
            /<key>TargetOSVersion<\/key>/ {
                getline; gsub(/^[[:space:]]*<string>/, ""); gsub(/<\/string>[[:space:]]*$/, ""); ver = $0
            }
            /<key>TargetLocalDateTime<\/key>/ {
                getline; gsub(/^[[:space:]]*<string>/, ""); gsub(/<\/string>[[:space:]]*$/, ""); dt = $0
            }
        ')

        # Filter entries by compliance and hardware compatibility, pick earliest deadline
        enforcedResult=$(find_enforced_update "$ddmEntries" "$currentVersion" "$boardID" "$sofaData" "$majorCap")
        if [[ $? -eq 0 && -n "$enforcedResult" ]]; then
            ddmVersion=$(echo "$enforcedResult" | cut -d'|' -f1)
            ddmDeadline=$(echo "$enforcedResult" | cut -d'|' -f2)
            isDDM="true"
            echo "Found active enforcement: macOS $ddmVersion by $ddmDeadline"
        fi
    fi
else
    echo "No DDM state file found."
fi

nowEpoch=$(date +%s)
deadlineEpoch=""
skipMeetingCheck="false"

if [[ "$isDDM" == "true" ]]; then
    reminderVersion="$ddmVersion"
    # Icon matches the enforced version, not SOFA's newest
    targetMajor="${ddmVersion%%.*}"
    deadlineEpoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$ddmDeadline" "+%s" 2>/dev/null)
    if [[ -z "$deadlineEpoch" ]]; then
        echo "Error: Failed to calculate deadline epoch from $ddmDeadline. Exiting."
        exit 0
    fi
    # Apple shows its own enforcement notices regardless of Focus in the last 24 hours
    if (( deadlineEpoch - nowEpoch < 86400 )); then
        skipMeetingCheck="true"
    fi
elif [[ "$demoMode" == "true" ]]; then
    echo "DEMO MODE: No active DDM enforcement, showing the standard dialog anyway."
    reminderVersion="$latestVersion"
else
    reminderVersion="$latestVersion"
    release_cleared_hold "$latestVersion" "$sofaData" "$releaseHoldDays" "$nowEpoch"
    case $? in
        0) echo "macOS $latestVersion has cleared the ${releaseHoldDays}-day release hold." ;;
        1) echo "macOS $latestVersion is still inside its ${releaseHoldDays}-day release hold - no reminder yet. Exiting."
           exit 0 ;;
        *) echo "WARNING: SOFA has no usable ReleaseDate for macOS $latestVersion - cannot apply the release hold. Exiting."
           exit 0 ;;
    esac
fi

# With no enforcement, only recommend what Software Update on this Mac is actually offering
if [[ "$isDDM" == "false" && "$demoMode" != "true" ]]; then
    suListFile=$(mktemp /tmp/update_reminder_su.XXXXXX)
    if ! list_offered_updates "$suListFile" "$softwareUpdateListSeconds"; then
        rm -f "$suListFile"
        echo "WARNING: softwareupdate --list did not finish within $softwareUpdateListSeconds seconds - no reminder. Exiting."
        exit 0
    fi
    suList=$(cat "$suListFile")
    rm -f "$suListFile"
    if ! su_offers_version "$latestVersion" "$suList"; then
        echo "Software Update is not offering macOS $latestVersion on this Mac yet (deferred or not yet visible) - no reminder. Exiting."
        exit 0
    fi
    echo "Software Update is offering macOS $latestVersion."
fi

# --- STEP 3: DOWNLOAD ASSETS ---
echo "=== Phase 3: Downloading Assets ==="

# Download macOS Icon based on Target Version
# We still download this one because --icon prefers local paths or system paths
case ${targetMajor} in
    14) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_eecee9688d1bc0426083d427d80c9ad48fa118b71d8d4962061d4de8d45747e7" ;;
    15) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_0968afcd54ff99edd98ec6d9a418a5ab0c851576b687756dc3004ec52bac704e" ;;
    26) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_7320c100c9ca155dc388e143dbc05620907e2d17d6bf74a8fb6d6278ece2c2b4" ;;
    *) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_4555d9dc8fecb4e2678faffa8bdcf43cba110e81950e07a4ce3695ec2d5579ee" ;;
esac

echo "Downloading icon for macOS $targetMajor..."
# A private per-run folder: root never writes to a predictable path in the
# world-writable /var/tmp, and the folder is removed when the presenter ends
iconDir=$(mktemp -d /var/tmp/update_reminder.XXXXXX 2>/dev/null) && chmod 755 "$iconDir"
osIconPath="$iconDir/os_icon.png"
if [[ -n "$iconDir" ]] && curl --connect-timeout 5 -m 30 -o "$osIconPath" "$macOSIconURL" --silent --fail; then
    mainIcon="$osIconPath"
    # Ensure user can read the icon
    chmod 644 "$osIconPath"
else
    echo "Failed to download icon. Using Finder icon."
    mainIcon="/System/Library/CoreServices/Finder.app"
fi

# --- DEFAULT UI (Standard Mode) ---
title="macOS $latestVersion Available"

# Message construction
# Uses Markdown for the logo to allow remote URL loading without local resizing artifacts
baseMessage="![Organization Logo]($corporateLogoURL)${NL}${NL}**A software update is available for your Mac.**${NL}${NL}Keeping your Mac up to date ensures you have the latest security features and performance improvements.${NL}${NL}Click **Open Software Update** to install it."

# Append the assistance message
message="$baseMessage$assistance_message"

# InfoBox: Left-aligned stats
# Formatting: Bold Label / Plain Value
infobox="**Current macOS:** :red[$currentVersion]${NL}${NL}**Latest macOS:** :green[$latestVersion]"

# Overlay: None for standard mode
activeOverlay="none"
helpText="For assistance, please [open a support ticket]($support_ticket_url)."

# --- DDM OVERRIDE (Enforced Mode) ---
if [[ "$isDDM" == "true" ]]; then
    if [[ -n "$deadlineEpoch" ]]; then
        secondsLeft=$((deadlineEpoch - nowEpoch))
        daysLeft=$(( (secondsLeft + 43200) / 86400 ))

        if [[ $secondsLeft -lt 0 ]]; then
            daysLeft="Overdue"
            deadlineHuman=$(date -jf "%s" "$deadlineEpoch" "+%A, %b %d at %I:%M %p")
        else
            deadlineHuman=$(date -jf "%s" "$deadlineEpoch" "+%A, %b %d at %I:%M %p")
        fi

        # Rich UI Updates for DDM
        title="Software Update Required: macOS $ddmVersion"

        if [[ "$daysLeft" == "Overdue" ]]; then
            baseMessage="![Organization Logo]($corporateLogoURL)${NL}${NL}**Action Required: macOS Update**${NL}${NL}Your Mac must be updated to **macOS $ddmVersion** immediately. The update deadline has passed.${NL}${NL}Click **Open Software Update** to install it.${NL}${NL}Your Mac will **automatically restart** to install this update soon if no action is taken."
        else
            baseMessage="![Organization Logo]($corporateLogoURL)${NL}${NL}**Action Required: macOS Update**${NL}${NL}Your Mac must be updated to **macOS $ddmVersion** to remain compliant.${NL}${NL}Click **Open Software Update** to install it.${NL}${NL}If no action is taken, your Mac will **automatically restart** to install this update at the deadline shown."
        fi
        message="$baseMessage$assistance_message"

        infobox="**Current macOS:** :red[$currentVersion]${NL}${NL}**Required macOS:** :green[$ddmVersion]${NL}${NL}**Deadline:** $deadlineHuman${NL}${NL}**Days Remaining:** $daysLeft"

        activeOverlay="$cautionIcon"
        helpText="For assistance with this required update, please [open a support ticket]($support_ticket_url)."
    fi
fi

# --- STEP 4: LAUNCH DIALOG ---
echo "=== Phase 4: Launching Interface ==="

if [[ ! -x "$swiftDialogPath" ]]; then
    echo "SwiftDialog not found. Exiting."
    [[ -n "$iconDir" ]] && rm -rf "$iconDir"
    exit 1
fi

# Build arguments
dialogArgs=(
    "$swiftDialogPath"
    --title "$title"
    --message "$message"
    --icon "$mainIcon"
    --infobox "$infobox"
    --iconsize "150"
    --height "500"       # Static height prevents layout shift when remote image loads
    --button1text "Open Software Update"
    --button2text "Later"
    --timer "$dialogTimeoutSeconds"
    --hidetimerbar
    --ontop
    --moveable
    --titlefont "size=16"
    --messagefont "size=13"
    --helpmessage "$helpText"
    --commandfile "/var/tmp/dialog_update.log"
)

# Only add overlay if it's not "none"
if [[ "$activeOverlay" != "none" ]]; then
    dialogArgs+=(--overlayicon "$activeOverlay")
fi

# One reminder at a time: a presenter from an earlier run may still be waiting out a meeting
if [[ -f "$reminderPidPath" ]]; then
    priorPid=$(cat "$reminderPidPath" 2>/dev/null)
    if [[ "$priorPid" =~ ^[0-9]+$ ]] && kill -0 "$priorPid" 2>/dev/null && [[ "$(ps -p "$priorPid" -o command= 2>/dev/null)" == *zsh* ]]; then
        echo "A reminder from an earlier run is still waiting or on screen - not stacking another. Exiting."
        [[ -n "$iconDir" ]] && rm -rf "$iconDir"
        exit 0
    fi
fi

# The presenter runs detached so a meeting wait never holds the Jamf policy open
echo "Handing the reminder to the presenter (log: $reminderLogPath)."
present_reminder >> "$reminderLogPath" 2>&1 < /dev/null &!
echo "$!" > "$reminderPidPath"
exit 0
