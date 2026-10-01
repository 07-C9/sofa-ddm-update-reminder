#!/bin/zsh
# ABOUTME: End-to-end tests for the update reminder script, run under Jamf-like conditions with stubbed system commands.
# ABOUTME: Verifies the reminder stays silent without a DDM enforcement and shows the enforced version and deadline with one.

SCRIPT_DIR="${0:A:h}"
REMINDER="$SCRIPT_DIR/update_reminder.sh"

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
echo testuser
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
EOF
cat > "$STUBS/dialog" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUBS"/*

# --- Copy of the real script with the DDM state plist and SwiftDialog paths pointed at fixtures ---
SCRIPT_COPY="$WORK/reminder.sh"
DDM_PLIST="$WORK/SoftwareUpdateDDMStatePersistence.plist"
sed -e "s|^ddmPlistPath=.*|ddmPlistPath=\"$DDM_PLIST\"|" \
    -e "s|^swiftDialogPath=.*|swiftDialogPath=\"$STUBS/dialog\"|" \
    "$REMINDER" > "$SCRIPT_COPY"
if ! grep -q "^ddmPlistPath=\"$DDM_PLIST\"" "$SCRIPT_COPY" || ! grep -q "^swiftDialogPath=\"$STUBS/dialog\"" "$SCRIPT_COPY"; then
    echo "FATAL: Could not redirect ddmPlistPath/swiftDialogPath in the script copy."
    exit 1
fi

# --- SOFA fixture: 27.0 exists (pinned away), 26.7.2 is the brand-new untested minor ---
export STUB_SOFA_FILE="$WORK/sofa.json"
cat > "$STUB_SOFA_FILE" <<'EOF'
{"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.0","Build":"27A000","SupportedDevices":["J700AP"]},"SecurityReleases":[{"ProductVersion":"27.0"}]},{"OSVersion":"26","Latest":{"ProductVersion":"26.7.2","Build":"25G400","AllBuilds":["25G400"],"SupportedDevices":["J700AP"]},"SecurityReleases":[{"ProductVersion":"26.7.2"},{"ProductVersion":"26.7.1"},{"ProductVersion":"26.6.2"}]}]}
EOF

# write_ddm_plist <json>: writes a DDM state fixture in Apple's XML plist format
write_ddm_plist() {
    echo "$1" | plutil -convert xml1 -o "$DDM_PLIST" -
}

# run_reminder: runs the script copy the way Jamf does (SIGPIPE ignored, no stdin,
# parameter 4 = 26) behind a 30s watchdog. Sets RUN_RC, RUN_OUT, RUN_LAUNCH.
run_reminder() {
    export STUB_LAUNCH_LOG="$WORK/launch.log"
    rm -f "$STUB_LAUNCH_LOG"
    ( trap '' PIPE; PATH="$STUBS:$PATH" /bin/zsh "$SCRIPT_COPY" "/" "testhost" "testuser" "26" </dev/null > "$WORK/out.txt" 2>&1 ) &
    local pid=$! ticks=0
    while kill -0 $pid 2>/dev/null; do
        if (( ticks >= 300 )); then
            kill -9 $pid 2>/dev/null
            RUN_RC=124
            RUN_OUT="HUNG: watchdog killed the script after 30s"
            RUN_LAUNCH=""
            return
        fi
        /bin/sleep 0.1
        (( ticks++ ))
    done
    wait $pid
    RUN_RC=$?
    # The dialog launch is backgrounded by the script; give the stub a moment to finish logging it
    ticks=0
    while (( ticks < 20 )) && [[ -f "$STUB_LAUNCH_LOG" ]] && (( $(grep -c '^CALL$' "$STUB_LAUNCH_LOG") < 2 )); do
        /bin/sleep 0.1
        (( ticks++ ))
    done
    RUN_OUT=$(cat "$WORK/out.txt")
    RUN_LAUNCH=$(cat "$STUB_LAUNCH_LOG" 2>/dev/null)
}

echo "=== Test Suite: update reminder end to end (Jamf context) ==="

echo ""
echo "--- No DDM state file, newer minor in SOFA: silent exit ---"
rm -f "$DDM_PLIST"
export STUB_OS_VERSION="26.7.1" STUB_OS_BUILD="25G300"
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs no-enforcement line" "No active DDM enforcement - nothing to remind" "$RUN_OUT"
assert_eq "launches nothing (no dialog, no Settings)" "" "$RUN_LAUNCH"

echo ""
echo "--- Empty DDM state plist (no order on the Mac): silent exit ---"
write_ddm_plist '{}'
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs no-enforcement line" "No active DDM enforcement - nothing to remind" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- Enforcement already satisfied (on 26.7.1, order for 26.7.1): silent exit ---"
write_ddm_plist '{"SUCorePersistedStatePolicyFields":{"Declarations":{"Blueprint_test_sys_cfg":{"TargetOSVersion":"26.7.1","TargetLocalDateTime":"2026-10-08T21:00:00"}}}}'
run_reminder
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs no-enforcement line" "No active DDM enforcement - nothing to remind" "$RUN_OUT"
assert_eq "launches nothing" "" "$RUN_LAUNCH"

echo ""
echo "--- Active enforcement for 26.7.1 while SOFA has 26.7.2: DDM dialog for the enforced version ---"
export STUB_OS_VERSION="26.6.2" STUB_OS_BUILD="25G100"
run_reminder
expectedDeadline=$(date -jf "%Y-%m-%dT%H:%M:%S" "2026-10-08T21:00:00" "+%A, %b %d at %I:%M %p")
assert_eq "exits 0" "0" "$RUN_RC"
assert_contains "logs the enforcement" "Found active enforcement: macOS 26.7.1 by 2026-10-08T21:00:00" "$RUN_OUT"
assert_contains "dialog title names the enforced version" "Software Update Required: macOS 26.7.1" "$RUN_LAUNCH"
assert_contains "infobox shows the enforced version" "**Required macOS:** :green[26.7.1]" "$RUN_LAUNCH"
assert_contains "infobox shows the deadline" "**Deadline:** $expectedDeadline" "$RUN_LAUNCH"
assert_contains "dialog carries the enforcement overlay" "--overlayicon" "$RUN_LAUNCH"
assert_not_contains "never mentions the untested 26.7.2" "26.7.2" "$RUN_LAUNCH"
assert_contains "opens Software Update settings" "x-apple.systempreferences:com.apple.Software-Update-Settings.extension" "$RUN_LAUNCH"

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
