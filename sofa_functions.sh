#!/bin/zsh
# ABOUTME: Shared functions for SOFA feed parsing and hardware-aware update targeting.
# ABOUTME: Sourced by the main update notification script and by tests.

# find_target_for_device <boardID> <sofaJSON>
#
# Walks OSVersions from newest to oldest. For each OS, checks if the board ID
# appears in the Latest release's SupportedDevices. If not, walks SecurityReleases
# to find the newest release that supports this hardware.
#
# This means a macOS 15 machine whose hardware supports Tahoe will be targeted
# for the latest Tahoe release it's eligible for — not stuck on macOS 15.
#
# Outputs a single line: <productVersion> <osIndex>
# Returns 0 if a supported version was found, 1 if not.
find_target_for_device() {
    local boardID="$1"
    local sofaData="$2"

    autoload -Uz is-at-least

    # Declare all loop variables up front to avoid zsh's typeset re-declaration
    # printing previous values to stdout on subsequent iterations
    local osCount osIdx osLatest latestDevices relCount ridx relVer relDevices
    local bestVer bestOsIdx

    osCount=$(echo "$sofaData" | plutil -extract "OSVersions" raw -o - - 2>/dev/null)
    if [[ -z "$osCount" || "$osCount" -eq 0 ]]; then
        return 1
    fi

    for (( osIdx=0; osIdx<osCount; osIdx++ )); do
        osLatest=$(echo "$sofaData" | plutil -extract "OSVersions.$osIdx.Latest.ProductVersion" raw -o - - 2>/dev/null)

        # If no board ID was detected, fall back to absolute latest
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

# find_enforced_update <ddmEntries> <currentVersion> <boardID> <sofaData>
#
# Filters DDM enforcement entries to find the most urgent applicable one.
# Skips versions the machine already has and versions not available for
# this hardware per SOFA SupportedDevices. Returns the earliest deadline.
#
# ddmEntries: newline-separated "version|date" lines (from plist parsing)
# Outputs: "version|deadline" for the most urgent enforcement
# Returns 0 if an applicable enforcement was found, 1 if not.
find_enforced_update() {
    local ddmEntries="$1"
    local currentVersion="$2"
    local boardID="$3"
    local sofaData="$4"

    autoload -Uz is-at-least

    local tVer tDate tEpoch
    local bestEpoch=""
    local bestVer=""
    local bestDate=""

    [[ -z "$ddmEntries" ]] && return 1

    while IFS='|' read -r tVer tDate; do
        [[ -z "$tVer" || -z "$tDate" ]] && continue

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
