#!/bin/zsh
# ABOUTME: macOS update reminder using SwiftDialog, SOFA feed hardware-aware targeting, and DDM log reading.
# ABOUTME: Self-contained script for Jamf deployment — no external dependencies.

####################################################################################################
# HYBRID UPDATE REMINDER - UNIVERSAL EDITION v6.8
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
# SwiftDialog loads this remotely — no local download required.
corporateLogoURL="https://dli-engineering.s3.us-west-2.amazonaws.com/PSD.png"

# URL that opens when users click "open a support ticket"
support_ticket_url="https://psd401.freshservice.com/support/tickets/new"

# Icon overlaid on the dialog during DDM enforcement (red stop sign or yellow triangle)
# Options: AlertStopIcon.icns  |  AlertCautionIcon.icns
cautionIcon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns"

# Set to "true" to force-show the dialog on any machine regardless of update status.
# Use this to test UI appearance. Set back to "false" before deploying.
demoMode="false"

####################################################################################################
# END CONFIGURATION
####################################################################################################

# --- SOFA FUNCTIONS ---

# find_target_for_device <boardID> <sofaJSON>
#
# Walks OSVersions from newest to oldest. For each OS, scans all SecurityReleases and
# returns the highest version this device supports. Does not assume feed ordering.
# Falls back to Latest if SecurityReleases is empty.
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

# --- Internal constants ---
scriptVersion="6.8-Universal"
sofaURL="https://sofafeed.macadmins.io/v2/macos_data_feed.json"
osIconPath="/var/tmp/os_icon.png"
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

if [[ "$demoMode" == "true" ]]; then
    echo "DEMO MODE: Skipping SOFA check, forcing dialog display."
    latestVersion="26.3.1"
    targetMajor="26"
else
    # Fetch SOFA with bounded retry. ~19s worst case (3 x 5s timeout + 2 x 2s sleep).
    sofaData=""
    for attempt in 1 2 3; do
        sofaData=$(curl -L -m 5 -s "$sofaURL")
        [[ -n "$sofaData" ]] && break
        echo "SOFA fetch attempt $attempt failed."
        [[ $attempt -lt 3 ]] && sleep 2
    done

    if [[ -z "$sofaData" ]]; then
        echo "WARNING: Could not fetch SOFA feed after 3 attempts. Cannot verify update availability. Exiting."
        exit 0
    fi

    # Find the newest release this hardware supports across ALL OS versions.
    # Walks from newest OS (e.g., Tahoe) to oldest. A macOS 15 machine whose
    # hardware supports Tahoe will be targeted for Tahoe, not stuck on 15.
    targetResult=$(find_target_for_device "$boardID" "$sofaData")
    if [[ $? -ne 0 || -z "$targetResult" ]]; then
        echo "ERROR: No supported OS version found for $boardID in SOFA feed. Exiting."
        exit 0
    fi

    latestVersion=$(echo "$targetResult" | awk '{print $1}')
    targetOSIndex=$(echo "$targetResult" | awk '{print $2}')
    targetMajor=$(echo "$latestVersion" | cut -d. -f1)

    echo "Target: $latestVersion (OS index $targetOSIndex)"

    # Safety: refuse to recommend a downgrade. If SOFA returns a version older
    # than current, something is wrong with the feed or our parser — exit clean.
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

# --- STEP 2: DOWNLOAD ASSETS ---
echo "=== Phase 2: Downloading Assets ==="

# Download macOS Icon based on Target Version
# We still download this one because --icon prefers local paths or system paths
case ${targetMajor} in
    14) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_eecee9688d1bc0426083d427d80c9ad48fa118b71d8d4962061d4de8d45747e7" ;;
    15) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_0968afcd54ff99edd98ec6d9a418a5ab0c851576b687756dc3004ec52bac704e" ;;
    26) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_7320c100c9ca155dc388e143dbc05620907e2d17d6bf74a8fb6d6278ece2c2b4" ;;
    *) macOSIconURL="https://ics.services.jamfcloud.com/icon/hash_4555d9dc8fecb4e2678faffa8bdcf43cba110e81950e07a4ce3695ec2d5579ee" ;;
esac

echo "Downloading icon for macOS $targetMajor..."
if curl -o "$osIconPath" "$macOSIconURL" --silent --fail; then
    mainIcon="$osIconPath"
    # Ensure user can read the icon
    chmod 644 "$osIconPath"
else
    echo "Failed to download icon. Using Finder icon."
    mainIcon="/System/Library/CoreServices/Finder.app"
fi

# --- STEP 3: CHECK FOR DDM ENFORCEMENT ---
echo "=== Phase 3: Analyzing DDM State ==="

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
        enforcedResult=$(find_enforced_update "$ddmEntries" "$currentVersion" "$boardID" "$sofaData")
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

if [[ "$isDDM" == "false" ]]; then
    echo "No active DDM enforcement found."
fi

# --- DEFAULT UI (Standard Mode) ---
title="macOS $latestVersion Available"

# Message construction
# Uses Markdown for the logo to allow remote URL loading without local resizing artifacts
baseMessage="![Organization Logo]($corporateLogoURL)${NL}${NL}**A new software update is available for your Mac.**${NL}${NL}Keeping your Mac up to date ensures you have the latest security features and performance improvements.${NL}${NL}We have opened **Software Update** settings for you to proceed."

# Append the assistance message
message="$baseMessage$assistance_message"

# InfoBox: Left-aligned stats
# Formatting: Bold Label / Plain Value
infobox="**Current macOS:** :red[$currentVersion]${NL}${NL}**Required macOS:** :green[$latestVersion]"

# Overlay: None for standard mode
activeOverlay="none"
helpText="For assistance, please [open a support ticket]($support_ticket_url)."

# --- DDM OVERRIDE (Enforced Mode) ---
if [[ "$isDDM" == "true" ]]; then
    # Calculate Deadline
    deadlineEpoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "$ddmDeadline" "+%s" 2>/dev/null)
    nowEpoch=$(date +%s)

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
            baseMessage="![Organization Logo]($corporateLogoURL)${NL}${NL}**Action Required: macOS Update**${NL}${NL}Your Mac must be updated to **macOS $ddmVersion** immediately. The update deadline has passed.${NL}${NL}We have opened **Software Update** settings for you.${NL}${NL}Your Mac will **automatically restart** to install this update soon if no action is taken."
        else
            baseMessage="![Organization Logo]($corporateLogoURL)${NL}${NL}**Action Required: macOS Update**${NL}${NL}Your Mac must be updated to **macOS $ddmVersion** to remain compliant.${NL}${NL}We have opened **Software Update** settings for you.${NL}${NL}If no action is taken, your Mac will **automatically restart** to install this update at the deadline shown."
        fi
        message="$baseMessage$assistance_message"

        infobox="**Current macOS:** :red[$currentVersion]${NL}${NL}**Required macOS:** :green[$ddmVersion]${NL}${NL}**Deadline:** $deadlineHuman${NL}${NL}**Days Remaining:** $daysLeft"

        activeOverlay="$cautionIcon"
        helpText="For assistance with this required update, please [open a support ticket]($support_ticket_url)."
    else
        echo "Error: Failed to calculate deadline epoch from $ddmDeadline"
    fi
fi

# --- STEP 4: LAUNCH DIALOG ---
echo "=== Phase 4: Launching Interface ==="

if [[ ! -x "$swiftDialogPath" ]]; then
    echo "SwiftDialog not found. Exiting."
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
    --button1text "OK"
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

# Execute
# 1. Launch System Settings FIRST
echo "Opening System Settings..."
launchctl asuser "$currentUserID" sudo -u "$currentUser" open "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"

# 2. Launch Dialog
echo "Launching Dialog..."
launchctl asuser "$currentUserID" sudo -u "$currentUser" "${dialogArgs[@]}" &

exit 0
