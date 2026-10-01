#!/bin/zsh
# ABOUTME: Decision functions shared by the update reminder script and its unit tests.
# ABOUTME: update_reminder.sh carries an identical copy; test_sofa_functions.sh enforces the match.

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
# Walks OSVersions from newest to oldest. For each OS, checks if the board ID
# appears in the Latest release's SupportedDevices. If not, walks SecurityReleases
# to find the newest release that supports this hardware.
#
# This means a macOS 15 machine whose hardware supports Tahoe will be targeted
# for the latest Tahoe release it's eligible for — not stuck on macOS 15.
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
        # omit SupportedDevices in SOFA's current schema — they apply to whatever
        # hardware Latest lists for this OS family.
        latestDevices=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.SupportedDevices" json -o - - 2>/dev/null)

        # Walk all SecurityReleases and track the highest version this device supports.
        # Does not assume feed ordering — always returns the newest eligible release.
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
            # No SecurityReleases — fall back to Latest
            if [[ -n "$latestDevices" ]] && echo "$latestDevices" | grep -q "\"$boardID\""; then
                echo "$osLatest $osIdx"
                return 0
            fi
        fi
    done

    # Board ID not found in any OS version
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

        # Prefer higher version — installing the newer release satisfies every
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
# catalog can never hold the Jamf policy open. Returns 0 when the command
# finished, 1 when it had to be stopped at the limit.
list_offered_updates() {
    local outFile="$1"
    local maxSeconds="$2"
    local pid ticks=0
    softwareupdate --list > "$outFile" 2>&1 < /dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( ticks >= maxSeconds * 10 )); then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 1
        fi
        /bin/sleep 0.1
        (( ticks++ ))
    done
    wait "$pid" 2>/dev/null
    return 0
}

# install_tonight_pending <version> <installLogLines> <nowEpoch> [deadlineEpoch]
#
# Returns 0 when the user has already chosen Install Tonight for this version
# in Software Update and tonight's install window has not started yet, so a
# reminder today would only repeat what they already did. installLogLines are
# the "Updates queued for later: [" and "Updated install tonight state" lines
# from /var/log/install.log. The newest of each decides: the state must be
# enabled = true and the queue must name this version. Software Update runs
# queued installs from 02:00 local time; once that time passes and the Mac is
# still behind, the install did not happen and reminders resume. When a DDM
# deadline falls before the window, the reminder is never suppressed.
install_tonight_pending() {
    local version="$1"
    local logLines="$2"
    local nowEpoch="$3"
    local deadlineEpoch="$4"
    local lastState lastQueue stateEpoch stateDay windowEpoch
    [[ -z "$version" || -z "$logLines" ]] && return 1
    lastState=$(echo "$logLines" | grep 'Updated install tonight state' | tail -n 1)
    lastQueue=$(echo "$logLines" | grep 'Updates queued for later: \[' | tail -n 1)
    [[ "$lastState" == *"(enabled = true"* ]] || return 1
    [[ "$lastQueue" == *"_${version}_"* ]] || return 1
    stateEpoch=$(date -jf "%Y-%m-%d %H:%M:%S" "${lastState[1,19]}" "+%s" 2>/dev/null)
    [[ "$stateEpoch" =~ ^[0-9]+$ ]] || return 1
    stateDay=$(date -jf "%s" "$stateEpoch" "+%Y-%m-%d")
    windowEpoch=$(date -jf "%Y-%m-%d %H:%M:%S" "$stateDay 02:00:00" "+%s" 2>/dev/null)
    if (( windowEpoch <= stateEpoch )); then
        windowEpoch=$(date -v+1d -jf "%Y-%m-%d %H:%M:%S" "$stateDay 02:00:00" "+%s" 2>/dev/null)
    fi
    [[ "$windowEpoch" =~ ^[0-9]+$ ]] || return 1
    (( nowEpoch < windowEpoch )) || return 1
    if [[ -n "$deadlineEpoch" ]] && (( deadlineEpoch <= windowEpoch )); then
        return 1
    fi
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
