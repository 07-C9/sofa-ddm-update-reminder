#!/bin/zsh
# ABOUTME: End-to-end tests for the update reminder script, run under Jamf-like conditions with stubbed system commands.
# ABOUTME: Covers the no-order nudge gates, the DDM dialog, Install Tonight, meeting waits and the detached presenter.

SCRIPT_DIR="${0:A:h}"
REMINDER="$SCRIPT_DIR/update_reminder.sh"
zmodload zsh/datetime

PASS=0
FAIL=0

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $test_name"
        (( PASS++ ))
    else
        echo "  FAIL: $test_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        (( FAIL++ ))
    fi
}

assert_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $test_name"
        (( PASS++ ))
    else
        echo "  FAIL: $test_name"
        echo "    expected to contain: $needle"
        (( FAIL++ ))
    fi
}

assert_not_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $test_name"
        (( PASS++ ))
    else
        echo "  FAIL: $test_name"
        echo "    expected NOT to contain: $needle"
        (( FAIL++ ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# --- Stubbed system commands (logged-in user, OS version, board ID, network, GUI launch) ---
cat > "$STUBS/id" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "-u" ]; then echo 0; else echo 501; fi
EOF
cat > "$STUBS/stat" <<'EOF'
#!/bin/sh
# The console user is testuser, or otheruser once STUB_USER_CHANGES_AFTER calls have been made
n=$(cat "$STUB_STAT_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_STAT_COUNT"
if [ -n "$STUB_USER_CHANGES_AFTER" ] && [ "$n" -gt "$STUB_USER_CHANGES_AFTER" ]; then echo otheruser; else echo testuser; fi
EOF
cat > "$STUBS/sw_vers" <<'EOF'
#!/bin/sh
case "$1" in
    -productVersion) echo "$STUB_OS_VERSION" ;;
    -buildVersion) echo "$STUB_OS_BUILD" ;;
esac
EOF
cat > "$STUBS/sysctl" <<'EOF'
#!/bin/sh
echo J700AP
EOF
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in *sofafeed*) cat "$STUB_SOFA_FILE"; exit 0 ;; esac
done
exit 22
EOF
cat > "$STUBS/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUBS/launchctl" <<'EOF'
#!/bin/sh
{ echo "CALL"; for a in "$@"; do echo "$a"; done; } >> "$STUB_LAUNCH_LOG"
for a in "$@"; do case "$a" in */dialog) exit "${STUB_DIALOG_RC:-0}" ;; esac; done
exit 0
EOF
cat > "$STUBS/dialog" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUBS/softwareupdate" <<'EOF'
#!/bin/sh
# STUB_SU_IGNORE_TERM makes the stub survive SIGTERM, like a client stuck in a state that ignores it
[ -n "$STUB_SU_IGNORE_TERM" ] && trap '' TERM
[ -n "$STUB_SU_DELAY" ] && /bin/sleep "$STUB_SU_DELAY"
cat "$STUB_SU_FILE" 2>/dev/null
EOF
cat > "$STUBS/pmset" <<'EOF'
#!/bin/sh
# Reports a meeting for the first STUB_MEETING_CALLS calls, then an idle Mac
n=$(cat "$STUB_PMSET_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_PMSET_COUNT"
if [ "$n" -le "${STUB_MEETING_CALLS:-0}" ]; then
    echo '   pid 24542(Webex): [0x1] 00:12:01 PreventUserIdleDisplaySleep named: "On a call"'
else
    echo '   pid 567(powerd): [0x2] 05:10:07 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"'
fi
EOF
chmod +x "$STUBS"/*

# --- Copy of the real script with system paths pointed at fixtures and a short softwareupdate limit ---
SCRIPT_COPY="$WORK/reminder.sh"
DDM_PLIST="$WORK/SoftwareUpdateDDMStatePersistence.plist"
INSTALL_LOG="$WORK/install.log"
REMINDER_LOG="$WORK/update_reminder.log"
REMINDER_PID="$WORK/update_reminder.pid"
sed -e "s|^ddmPlistPath=.*|ddmPlistPath=\"$DDM_PLIST\"|" \
    -e "s|^swiftDialogPath=.*|swiftDialogPath=\"$STUBS/dialog\"|" \
    -e "s|^installLogPath=.*|installLogPath=\"$INSTALL_LOG\"|" \
    -e "s|^reminderLogPath=.*|reminderLogPath=\"$REMINDER_LOG\"|" \
    -e "s|^reminderPidPath=.*|reminderPidPath=\"$REMINDER_PID\"|" \
    -e "s|^softwareUpdateListSeconds=.*|softwareUpdateListSeconds=2|" \
    "$REMINDER" > "$SCRIPT_COPY"
for check in "^ddmPlistPath=\"$DDM_PLIST\"" "^swiftDialogPath=\"$STUBS/dialog\"" "^installLogPath=\"$INSTALL_LOG\"" \
             "^reminderLogPath=\"$REMINDER_LOG\"" "^reminderPidPath=\"$REMINDER_PID\"" "^softwareUpdateListSeconds=2"; do
    if ! grep -q "$check" "$SCRIPT_COPY"; then
        echo "FATAL: script copy is missing redirect $check"
        exit 1
    fi
done

# --- Fixtures ---
export STUB_SOFA_FILE="$WORK/sofa.json" STUB_SU_FILE="$WORK/su_list.txt"
CLEARED=$(date -ju -v-5d "+%Y-%m-%dT00:00:00Z")   # well past a 2-day hold
FRESH=$(date -ju "+%Y-%m-%dT00:00:00Z")           # released today: inside the hold

# write_sofa <26.7.1 ReleaseDate> <27.0.1 ReleaseDate>: SOFA feed with 27.0.1 and 26.7.1 as the newest releases
write_sofa() {
    cat > "$STUB_SOFA_FILE" <<EOF
{"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.0.1","Build":"26A434","AllBuilds":["26A434"],"ReleaseDate":"$2","SupportedDevices":["J700AP"]},"SecurityReleases":[{"ProductVersion":"27.0.1","ReleaseDate":"$2"},{"ProductVersion":"27.0","ReleaseDate":"$CLEARED"}]},{"OSVersion":"26","Latest":{"ProductVersion":"26.7.1","Build":"25G241","AllBuilds":["25G241"],"ReleaseDate":"$1","SupportedDevices":["J700AP"]},"SecurityReleases":[{"ProductVersion":"26.7.1","ReleaseDate":"$1"},{"ProductVersion":"26.7","ReleaseDate":"$CLEARED"},{"ProductVersion":"26.6.2","ReleaseDate":"$CLEARED"}]}]}
EOF
}

# su_offers <version>: softwareupdate --list output offering one macOS version
su_offers() {
    printf 'Software Update Tool\n\nFinding available software\nSoftware Update found the following new or updated software:\n* Label: macOS %s-X\n\tTitle: macOS %s, Version: %s, Size: 1KiB, Recommended: YES, Action: restart, \n' "$1" "$1" "$1" > "$STUB_SU_FILE"
}

# su_nothing: softwareupdate --list output with nothing offered
su_nothing() {
    printf 'Software Update Tool\n\nFinding available software\nNo new software available.\n' > "$STUB_SU_FILE"
}

# write_ddm_plist <json>: writes a DDM state fixture in Apple's XML plist format
write_ddm_plist() {
    echo "$1" | plutil -convert xml1 -o "$DDM_PLIST" -
}

# ddm_order <version> <localDeadline>: DDM state with one Blueprint enforcement
ddm_order() {
    write_ddm_plist "{\"SUCorePersistedStatePolicyFields\":{\"Declarations\":{\"Blueprint_test_sys_cfg\":{\"TargetOSVersion\":\"$1\",\"TargetLocalDateTime\":\"$2\"}}}}"
}

# tonight_queued <version> <localTimestamp>: install.log lines for an Install Tonight choice
tonight_queued() {
    printf '%s-07 TESTMAC001 SoftwareUpdateSettingsExtension[1]: x: Updates queued for later: [<SUOSUProduct: MSU_UPDATE_25X000_patch_%s_minor>], mode: SUOSULaterMode(rawValue: 1)\n%s-07 TESTMAC001 SoftwareUpdateSettingsExtension[1]: x: Updated install tonight state (enabled = true, restart = true)\n' "$2" "$1" "$2" > "$INSTALL_LOG"
}

# reset_defaults: a Mac on 26.6.2, no DDM order, no Install Tonight, 26.7.1 cleared and offered, no meeting
reset_defaults() {
    export STUB_OS_VERSION="26.6.2" STUB_OS_BUILD="25G100" STUB_DIALOG_RC=0 STUB_MEETING_CALLS=0
    unset STUB_USER_CHANGES_AFTER STUB_SU_DELAY STUB_SU_IGNORE_TERM
    rm -f "$DDM_PLIST" "$INSTALL_LOG" "$REMINDER_PID"
    write_sofa "$CLEARED" "$CLEARED"
    su_offers "26.7.1"
}

# run_reminder [pin]: runs the script copy the way Jamf does (SIGPIPE ignored, no stdin,
# parameter 4 = pin, default 26) behind a 30s watchdog, then waits up to 15s for the
# detached presenter. Sets RUN_RC, RUN_OUT, RUN_LAUNCH, RUN_LOG, RUN_SECONDS.
run_reminder() {
    local pin="${1-26}"
    export STUB_LAUNCH_LOG="$WORK/launch.log" STUB_PMSET_COUNT="$WORK/pmset.count" STUB_STAT_COUNT="$WORK/stat.count"
    rm -f "$STUB_LAUNCH_LOG" "$STUB_PMSET_COUNT" "$STUB_STAT_COUNT" "$REMINDER_LOG"
    local started=$EPOCHREALTIME
    ( trap '' PIPE; PATH="$STUBS:$PATH" /bin/zsh "$SCRIPT_COPY" "/" "testhost" "testuser" "$pin" </dev/null > "$WORK/out.txt" 2>&1 ) &
    local pid=$! ticks=0
    while kill -0 $pid 2>/dev/null; do
        if (( ticks >= 300 )); then
            kill -9 $pid 2>/dev/null
            RUN_RC=124
            RUN_OUT="HUNG: watchdog killed the script after 30s"
            RUN_LAUNCH=""
            RUN_LOG=""
            return
        fi
        /bin/sleep 0.1
        (( ticks++ ))
    done
    wait $pid
    RUN_RC=$?
    RUN_SECONDS=$(( EPOCHREALTIME - started ))
    RUN_OUT=$(cat "$WORK/out.txt")
    ticks=0
    if [[ "$RUN_OUT" == *"Handing the reminder to the presenter"* ]]; then
        while (( ticks < 150 )) && ! grep -q '^Presenter finished\.$' "$REMINDER_LOG" 2>/dev/null; do
            /bin/sleep 0.1
            (( ticks++ ))
        done
    fi
    RUN_LOG=$(cat "$REMINDER_LOG" 2>/dev/null)
    RUN_LAUNCH=$(cat "$STUB_LAUNCH_LOG" 2>/dev/null)
}

# launch_order: "dialog-then-open" when the dialog launched before Software Update opened
launch_order() {
    awk '/\/dialog$/{if(!d)d=NR} /x-apple.systempreferences/{if(!o)o=NR} END{print (d && o && d<o) ? "dialog-then-open" : "wrong order"}' <<< "$RUN_LAUNCH"
}

echo "=== Test Suite: update reminder end to end (Jamf context) ==="

echo ""
echo "--- No order, 26.7.1 cleared the hold and Software Update offers it: gentle nudge ---"
reset_defaults
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs the cleared hold" "macOS 26.7.1 has cleared the 2-day release hold" "$RUN_OUT"
assert_contains "dialog title" "macOS 26.7.1 Available" "$RUN_LAUNCH"
assert_contains "nudge infobox" "**Latest macOS:** :green[26.7.1]" "$RUN_LAUNCH"
assert_contains "button opens Software Update" "Open Software Update" "$RUN_LAUNCH"
assert_contains "later button" "Later" "$RUN_LAUNCH"
assert_not_contains "no enforcement overlay" "--overlayicon" "$RUN_LAUNCH"
assert_eq "dialog first, then Settings" "dialog-then-open" "$(launch_order)"
assert_contains "presenter logs the click" "User clicked Open Software Update" "$RUN_LOG"

echo ""
echo "--- No order, user clicks Later: Settings stays closed ---"
reset_defaults
export STUB_DIALOG_RC=2
run_reminder
assert_contains "dialog shown" "macOS 26.7.1 Available" "$RUN_LAUNCH"
assert_not_contains "Settings not opened" "x-apple.systempreferences" "$RUN_LAUNCH"
assert_contains "presenter logs the dismissal" "User dismissed the reminder (dialog exit 2)" "$RUN_LOG"

echo ""
echo "--- No order, 26.7.1 released today: inside the hold, silent ---"
reset_defaults
write_sofa "$FRESH" "$CLEARED"
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs the hold" "macOS 26.7.1 is still inside its 2-day release hold" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- No order, SOFA has no ReleaseDate for the target: silent warning ---"
reset_defaults
echo '{"OSVersions":[{"OSVersion":"26","Latest":{"ProductVersion":"26.7.1","Build":"25G241","AllBuilds":["25G241"],"SupportedDevices":["J700AP"]},"SecurityReleases":[{"ProductVersion":"26.7.1"},{"ProductVersion":"26.6.2"}]}]}' > "$STUB_SOFA_FILE"
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs missing date" "SOFA has no usable ReleaseDate for macOS 26.7.1" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- No order, hold cleared but Software Update is not offering it: silent ---"
reset_defaults
su_nothing
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs the gate" "Software Update is not offering macOS 26.7.1 on this Mac yet" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- softwareupdate --list hangs past the limit: silent, policy not held ---"
reset_defaults
export STUB_SU_DELAY=5
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs the timeout" "softwareupdate --list did not finish within 2 seconds" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"
assert_eq "script returned well before the stub would have" "fast" "$( (( RUN_SECONDS < 4.5 )) && echo fast || echo slow )"

echo ""
echo "--- softwareupdate --list hangs and ignores SIGTERM: still stopped, policy not held ---"
reset_defaults
export STUB_SU_DELAY=20 STUB_SU_IGNORE_TERM=1
run_reminder
assert_eq "exits 0 (not killed by the 30s watchdog)" "0" "$RUN_RC"
assert_contains "logs the timeout" "softwareupdate --list did not finish within 2 seconds" "$RUN_OUT"
assert_eq "script returned within a few seconds of the limit" "fast" "$( (( RUN_SECONDS < 8 )) && echo fast || echo slow )"
pkill -f "sleep 20" 2>/dev/null

echo ""
echo "--- No install.log at all: no suppression, no error ---"
reset_defaults
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "dialog shown" "macOS 26.7.1 Available" "$RUN_LAUNCH"

echo ""
echo "--- No order, user already chose Install Tonight for 26.7.1 this evening: silent ---"
reset_defaults
queuedNow=$(date "+%Y-%m-%d %H:%M:%S")
tonight_queued "26.7.1" "$queuedNow"
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs suppression" "already chose Install Tonight for macOS 26.7.1" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- Install Tonight queued two days ago and Mac still behind: reminder resumes ---"
reset_defaults
tonight_queued "26.7.1" "$(date -v-2d "+%Y-%m-%d %H:%M:%S")"
run_reminder
assert_contains "dialog shown" "macOS 26.7.1 Available" "$RUN_LAUNCH"

echo ""
echo "--- Mac restored onto 27.0 with pin 26: nudged to 27.0.1, not ignored ---"
reset_defaults
export STUB_OS_VERSION="27.0" STUB_OS_BUILD="26A428"
su_offers "27.0.1"
run_reminder 26
assert_contains "effective cap logged" "Effective major cap: 27" "$RUN_OUT"
assert_contains "dialog for 27.0.1" "macOS 27.0.1 Available" "$RUN_LAUNCH"

echo ""
echo "--- Mac on 26.6.2 with pin 26 never hears about 27 ---"
reset_defaults
run_reminder 26
assert_contains "dialog for 26.7.1" "macOS 26.7.1 Available" "$RUN_LAUNCH"
assert_not_contains "never mentions 27" "27.0" "$RUN_LAUNCH"

echo ""
echo "--- Mac already on the newest build: silent ---"
reset_defaults
export STUB_OS_VERSION="26.7.1" STUB_OS_BUILD="25G241"
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "verified" "VERIFIED" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- Active DDM order for 26.7 while SOFA has 26.7.1 inside its hold: DDM dialog for 26.7 only ---"
reset_defaults
write_sofa "$FRESH" "$CLEARED"
deadlineLocal=$(date -v+5d "+%Y-%m-%dT21:00:00")
ddm_order "26.7" "$deadlineLocal"
su_nothing   # Software Update goes quiet under enforcement; the DDM path must not consult it
run_reminder
expectedDeadline=$(date -jf "%Y-%m-%dT%H:%M:%S" "$deadlineLocal" "+%A, %b %d at %I:%M %p")
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs the enforcement" "Found active enforcement: macOS 26.7 by $deadlineLocal" "$RUN_OUT"
assert_contains "title" "Software Update Required: macOS 26.7" "$RUN_LAUNCH"
assert_contains "infobox shows the enforced version" "**Required macOS:** :green[26.7]" "$RUN_LAUNCH"
assert_contains "deadline" "**Deadline:** $expectedDeadline" "$RUN_LAUNCH"
assert_contains "overlay" "--overlayicon" "$RUN_LAUNCH"
assert_contains "button" "Open Software Update" "$RUN_LAUNCH"
assert_not_contains "never the held 26.7.1" "26.7.1" "$RUN_LAUNCH"

echo ""
echo "--- DDM order, Install Tonight queued for it, deadline days away: silent today ---"
reset_defaults
ddm_order "26.7" "$deadlineLocal"
tonight_queued "26.7" "$(date "+%Y-%m-%d %H:%M:%S")"
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs suppression" "already chose Install Tonight for macOS 26.7" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- DDM order, Install Tonight queued, but the deadline is before tonight's window: still reminded ---"
nowHM=$(date "+%H%M")
if [[ "$nowHM" > "0129" && "$nowHM" < "0200" ]]; then
    echo "  SKIP: a 30-minute deadline lands after the 2 AM window at this time of night"
else
    reset_defaults
    ddm_order "26.7" "$(date -v+30M "+%Y-%m-%dT%H:%M:00")"
    tonight_queued "26.7" "$(date "+%Y-%m-%d %H:%M:%S")"
    run_reminder
    assert_contains "dialog shown" "Software Update Required: macOS 26.7" "$RUN_LAUNCH"
fi

echo ""
echo "--- Meeting for the first 2 checks, then free: dialog after the wait ---"
reset_defaults
export STUB_MEETING_CALLS=2
run_reminder
assert_contains "logs the wait" "Meeting or presentation in progress (check 1 of 15)" "$RUN_LOG"
assert_contains "dialog shown after" "macOS 26.7.1 Available" "$RUN_LAUNCH"

echo ""
echo "--- No order, meeting never ends: skipped today, nothing on screen ---"
reset_defaults
export STUB_MEETING_CALLS=99
run_reminder
assert_contains "logs the skip" "still active after 75 minutes - skipping today's reminder" "$RUN_LOG"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- DDM order 5 days out, meeting never ends: shown after 75 minutes anyway ---"
reset_defaults
export STUB_MEETING_CALLS=99
ddm_order "26.7" "$(date -v+5d "+%Y-%m-%dT21:00:00")"
run_reminder
assert_contains "logs show-anyway" "showing the required-update reminder anyway" "$RUN_LOG"
assert_contains "dialog shown" "Software Update Required: macOS 26.7" "$RUN_LAUNCH"

echo ""
echo "--- DDM order due within 24 hours: no meeting wait at all ---"
reset_defaults
export STUB_MEETING_CALLS=99
ddm_order "26.7" "$(date -v+3H "+%Y-%m-%dT%H:%M:00")"
run_reminder
assert_eq "pmset never consulted" "" "$(cat "$STUB_PMSET_COUNT" 2>/dev/null)"
assert_contains "dialog shown" "Software Update Required: macOS 26.7" "$RUN_LAUNCH"

echo ""
echo "--- Console user changes during the meeting wait: no dialog in someone else's session ---"
reset_defaults
export STUB_MEETING_CALLS=1 STUB_USER_CHANGES_AFTER=1
run_reminder
assert_contains "logs the user change" "testuser is no longer the console user" "$RUN_LOG"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- Main script returns while the presenter is still waiting ---"
reset_defaults
export STUB_MEETING_CALLS=99
printf '#!/bin/sh\n/bin/sleep 0.5\n' > "$STUBS/sleep"
chmod +x "$STUBS/sleep"
run_reminder
# The presenter needs 15 x 0.5s = 7.5s; one scenario of the main script measured ~0.7s on 2026-10-01
assert_eq "policy finished in under 3 seconds" "fast" "$( (( RUN_SECONDS < 3 )) && echo fast || echo slow )"
assert_contains "presenter still finished later" "Presenter finished." "$RUN_LOG"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/sleep"
chmod +x "$STUBS/sleep"

echo ""
echo "--- A presenter from an earlier run is still alive: no second dialog ---"
reset_defaults
( exec -a "/bin/zsh update_reminder_presenter" /bin/sleep 30 ) &
holder=$!
echo "$holder" > "$REMINDER_PID"
run_reminder
assert_contains "logs not stacking" "still waiting or on screen - not stacking another" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"
kill $holder 2>/dev/null
wait $holder 2>/dev/null

echo ""
echo "--- Stale pid file from a crashed presenter: reminder proceeds ---"
reset_defaults
echo 999999 > "$REMINDER_PID"
run_reminder
assert_contains "dialog shown" "macOS 26.7.1 Available" "$RUN_LAUNCH"

echo ""
echo "--- Presenter clears its lock when it finishes ---"
reset_defaults
run_reminder
assert_eq "no pid file left behind" "absent" "$([[ -f "$REMINDER_PID" ]] && echo present || echo absent)"

# ============================================================
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo "TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
