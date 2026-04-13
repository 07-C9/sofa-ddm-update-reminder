#!/bin/zsh
# ABOUTME: Tests for SOFA feed parsing and hardware-aware update targeting.
# ABOUTME: Uses real SOFA feed data to validate device matching logic.

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/sofa_functions.sh"

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

assert_return() {
    local test_name="$1"
    local expected_rc="$2"
    shift 2
    "$@"
    local actual_rc=$?
    if [[ "$expected_rc" == "$actual_rc" ]]; then
        echo "  PASS: $test_name"
        (( PASS++ ))
    else
        echo "  FAIL: $test_name"
        echo "    expected return code: $expected_rc"
        echo "    actual return code:   $actual_rc"
        (( FAIL++ ))
    fi
}

# --- Fetch real SOFA data once ---
echo "Fetching SOFA feed..."
SOFA_DATA=$(curl -L -m 10 -s "https://sofafeed.macadmins.io/v2/macos_data_feed.json")
if [[ -z "$SOFA_DATA" ]]; then
    echo "FATAL: Could not fetch SOFA data. Cannot run tests."
    exit 1
fi

# --- Extract test fixtures from real data ---
# Get the latest OS version (index 0) and its latest release
LATEST_OS_VER=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.0.Latest.ProductVersion" raw -o - - 2>/dev/null)
LATEST_OS_MAJOR=$(echo "$LATEST_OS_VER" | cut -d. -f1)

# Get a second OS version (index 1) if it exists
SECOND_OS_VER=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.1.Latest.ProductVersion" raw -o - - 2>/dev/null)
SECOND_OS_MAJOR=$(echo "$SECOND_OS_VER" | cut -d. -f1)

# Get a board ID that IS in the latest release's SupportedDevices
LATEST_DEVICES=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.0.Latest.SupportedDevices" json -o - - 2>/dev/null)
KNOWN_GOOD_BOARD=$(echo "$LATEST_DEVICES" | grep -o '"[^"]*AP"' | head -1 | tr -d '"')

# Get this machine's actual board ID
THIS_BOARD=$(sysctl -n hw.target 2>/dev/null)
if [[ -z "$THIS_BOARD" ]]; then
    THIS_BOARD=$(ioreg -d2 -c IOPlatformExpertDevice | awk -F'"' '/board-id/{print $4}')
fi

# Get a board ID that's in the second OS but NOT the latest (if possible)
SECOND_DEVICES=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.1.Latest.SupportedDevices" json -o - - 2>/dev/null)
SECOND_ONLY_BOARD=""
if [[ -n "$SECOND_DEVICES" ]]; then
    # Find a board ID in second OS that's not in the latest OS (any release)
    while IFS= read -r bid; do
        bid=$(echo "$bid" | tr -d '"' | tr -d ' ')
        [[ -z "$bid" ]] && continue
        # Check if this board ID appears anywhere in index 0
        os0_json=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.0" json -o - - 2>/dev/null)
        if ! echo "$os0_json" | grep -q "\"$bid\""; then
            SECOND_ONLY_BOARD="$bid"
            break
        fi
    done < <(echo "$SECOND_DEVICES" | grep -o '"[^"]*"' | grep -v '^\[' | grep -v '^\]')
fi

echo ""
echo "=== Test Fixtures ==="
echo "Latest OS: $LATEST_OS_VER (macOS $LATEST_OS_MAJOR)"
echo "Second OS: $SECOND_OS_VER (macOS $SECOND_OS_MAJOR)"
echo "Known good board ID: $KNOWN_GOOD_BOARD"
echo "This machine's board ID: $THIS_BOARD"
echo "Board ID only in second OS: ${SECOND_ONLY_BOARD:-<none found>}"
echo ""

# ============================================================
echo "=== Test Suite: find_target_for_device ==="
# ============================================================

echo ""
echo "--- Board ID in Latest release of newest OS ---"
result=$(find_target_for_device "$KNOWN_GOOD_BOARD" "$SOFA_DATA")
rc=$?
result_ver=$(echo "$result" | awk '{print $1}')
result_idx=$(echo "$result" | awk '{print $2}')
assert_eq "returns success" "0" "$rc"
assert_eq "targets latest OS version" "$LATEST_OS_VER" "$result_ver"
assert_eq "targets OS index 0" "0" "$result_idx"

echo ""
echo "--- This machine's board ID ---"
result=$(find_target_for_device "$THIS_BOARD" "$SOFA_DATA")
rc=$?
result_ver=$(echo "$result" | awk '{print $1}')
assert_eq "returns success for this machine" "0" "$rc"
# We can't assert exact version, but it should return SOMETHING
if [[ -n "$result_ver" ]]; then
    echo "  PASS: returns a version ($result_ver)"
    (( PASS++ ))
else
    echo "  FAIL: returned empty version"
    (( FAIL++ ))
fi

echo ""
echo "--- Completely fake board ID ---"
result=$(find_target_for_device "FAKEBOARD999" "$SOFA_DATA")
rc=$?
assert_eq "returns failure for unknown board" "1" "$rc"
assert_eq "returns empty output" "" "$result"

echo ""
echo "--- Empty board ID (fallback to absolute latest) ---"
result=$(find_target_for_device "" "$SOFA_DATA")
rc=$?
result_ver=$(echo "$result" | awk '{print $1}')
result_idx=$(echo "$result" | awk '{print $2}')
assert_eq "returns success with empty board ID" "0" "$rc"
assert_eq "falls back to absolute latest" "$LATEST_OS_VER" "$result_ver"
assert_eq "falls back to OS index 0" "0" "$result_idx"

echo ""
echo "--- Board ID only in older OS (cross-version should NOT match latest) ---"
if [[ -n "$SECOND_ONLY_BOARD" ]]; then
    result=$(find_target_for_device "$SECOND_ONLY_BOARD" "$SOFA_DATA")
    rc=$?
    result_ver=$(echo "$result" | awk '{print $1}')
    result_idx=$(echo "$result" | awk '{print $2}')
    assert_eq "returns success for older-OS board" "0" "$rc"
    # Should find it in the second OS, not the first
    assert_eq "targets second OS index" "1" "$result_idx"
    echo "  INFO: $SECOND_ONLY_BOARD -> $result_ver (index $result_idx)"
else
    echo "  SKIP: No board ID found that's exclusive to the second OS"
fi

echo ""
echo "--- Empty SOFA data ---"
result=$(find_target_for_device "$KNOWN_GOOD_BOARD" "")
rc=$?
assert_eq "returns failure with empty SOFA" "1" "$rc"

echo ""
echo "--- MacBook Neo scenario: J700AP gets Neo-specific release ---"
# 26.3.2 in SecurityReleases has SupportedDevices: ["J700AP"] only
NEO_DEVICES=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.0.SecurityReleases.0.SupportedDevices" json -o - - 2>/dev/null)
NEO_VER=$(echo "$SOFA_DATA" | plutil -extract "OSVersions.0.SecurityReleases.0.ProductVersion" raw -o - - 2>/dev/null)
if echo "$NEO_DEVICES" | grep -q '"J700AP"'; then
    # J700AP (MacBook Neo) should get the Neo-specific release, not Latest
    result=$(find_target_for_device "J700AP" "$SOFA_DATA")
    rc=$?
    result_ver=$(echo "$result" | awk '{print $1}')
    assert_eq "Neo board returns success" "0" "$rc"
    assert_eq "Neo board gets $NEO_VER (not $LATEST_OS_VER)" "$NEO_VER" "$result_ver"
else
    echo "  SKIP: SOFA data doesn't have J700AP in SecurityReleases[0] (data may have changed)"
fi

echo ""
echo "--- Non-Neo Mac should NOT get Neo-only release ---"
# This machine (J314sAP) should get Latest (26.3.1), not 26.3.2
result=$(find_target_for_device "$THIS_BOARD" "$SOFA_DATA")
rc=$?
result_ver=$(echo "$result" | awk '{print $1}')
if [[ -n "$NEO_VER" && "$NEO_VER" != "$LATEST_OS_VER" ]]; then
    assert_eq "non-Neo Mac gets Latest, not Neo release" "$LATEST_OS_VER" "$result_ver"
else
    echo "  SKIP: Neo version same as Latest or not found"
fi

# ============================================================
echo ""
echo "=== Test Suite: is_version_for_device ==="
# ============================================================

echo ""
echo "--- Version available for board ID ---"
# Use synthetic data with known board ID in SupportedDevices
COMPAT_TEST_DATA='{"OSVersions":[{"Latest":{"ProductVersion":"26.4","Build":"25E0000","SupportedDevices":["J314sAP","J316sAP"]},"SecurityReleases":[{"ProductVersion":"26.4","SupportedDevices":["J314sAP","J316sAP"]},{"ProductVersion":"26.3.2","SupportedDevices":["J700AP"]},{"ProductVersion":"26.3.1","SupportedDevices":["J314sAP","J316sAP","J700AP"]}]}]}'

result=$(is_version_for_device "26.4" "J314sAP" "$COMPAT_TEST_DATA")
rc=$?
assert_eq "26.4 is available for J314sAP" "0" "$rc"

echo ""
echo "--- Neo-only version NOT available for non-Neo board ---"
result=$(is_version_for_device "26.3.2" "J314sAP" "$COMPAT_TEST_DATA")
rc=$?
assert_eq "26.3.2 is NOT available for J314sAP" "1" "$rc"

echo ""
echo "--- Neo-only version IS available for Neo board ---"
result=$(is_version_for_device "26.3.2" "J700AP" "$COMPAT_TEST_DATA")
rc=$?
assert_eq "26.3.2 IS available for J700AP" "0" "$rc"

echo ""
echo "--- Older version available for board that supports it ---"
result=$(is_version_for_device "26.3.1" "J314sAP" "$COMPAT_TEST_DATA")
rc=$?
assert_eq "26.3.1 is available for J314sAP" "0" "$rc"

echo ""
echo "--- Version not in SOFA at all ---"
result=$(is_version_for_device "99.0.0" "J314sAP" "$COMPAT_TEST_DATA")
rc=$?
assert_eq "99.0.0 not found at all" "1" "$rc"

echo ""
echo "--- Empty board ID assumes compatible ---"
result=$(is_version_for_device "26.4" "" "$COMPAT_TEST_DATA")
rc=$?
assert_eq "empty board ID returns success" "0" "$rc"

echo ""
echo "--- Version only in Latest (no SecurityReleases) ---"
LATEST_ONLY_DATA='{"OSVersions":[{"Latest":{"ProductVersion":"15.7.4","Build":"24H0000","SupportedDevices":["J132AP"]},"SecurityReleases":[]}]}'
result=$(is_version_for_device "15.7.4" "J132AP" "$LATEST_ONLY_DATA")
rc=$?
assert_eq "version in Latest with empty SecurityReleases" "0" "$rc"

echo ""
echo "--- Real SOFA: Neo-only version not available for this machine ---"
if [[ -n "$NEO_VER" && "$NEO_VER" != "$LATEST_OS_VER" ]]; then
    result=$(is_version_for_device "$NEO_VER" "$THIS_BOARD" "$SOFA_DATA")
    rc=$?
    assert_eq "real SOFA: $NEO_VER not available for $THIS_BOARD" "1" "$rc"
else
    echo "  SKIP: No Neo-specific version to test against"
fi

echo ""
echo "--- Universal SecurityRelease: version available via Latest.SupportedDevices ---"
# UNIVERSAL_TEST_DATA's 26.4 SecurityRelease omits SupportedDevices (universal).
# Function must check Latest.SupportedDevices as fallback and confirm availability.
UNIVERSAL_TEST_DATA='{"OSVersions":[{"Latest":{"ProductVersion":"26.4.1","Build":"25E42","SupportedDevices":["J314sAP","J313AP","J713AP","J700AP"]},"SecurityReleases":[{"ProductVersion":"26.4.1"},{"ProductVersion":"26.4"},{"ProductVersion":"26.3.2","SupportedDevices":["J700AP"]},{"ProductVersion":"26.3.1"},{"ProductVersion":"26.3","SupportedDevices":["J314sAP","J313AP","J713AP","J700AP"]}]}]}'
result=$(is_version_for_device "26.4" "J314sAP" "$UNIVERSAL_TEST_DATA")
rc=$?
assert_eq "universal 26.4 is available for J314sAP via Latest list" "0" "$rc"

echo ""
echo "--- Universal SecurityRelease: board not in Latest means not available ---"
result=$(is_version_for_device "26.4" "J99UNKNOWN" "$UNIVERSAL_TEST_DATA")
rc=$?
assert_eq "universal 26.4 NOT available for unknown board" "1" "$rc"

# ============================================================
echo ""
echo "=== Test Suite: find_target_for_device (continued) ==="
# ============================================================

echo ""
echo "--- SecurityReleases ordering independence ---"
# Synthetic feed with SecurityReleases ordered OLDEST-first.
# A naive first-match implementation would return 26.2.0. Correct behavior returns 26.3.1.
ORDERING_TEST_DATA=$(plutil -create json /dev/stdout 2>/dev/null || echo "")
ORDERING_TEST_DATA='{"OSVersions":[{"Latest":{"ProductVersion":"26.3.1","Build":"25D0000","SupportedDevices":["J314sAP"]},"SecurityReleases":[{"ProductVersion":"26.2.0","SupportedDevices":["J314sAP"]},{"ProductVersion":"26.3.1","SupportedDevices":["J314sAP"]}]}]}'
result=$(find_target_for_device "J314sAP" "$ORDERING_TEST_DATA")
result_ver=$(echo "$result" | awk '{print $1}')
assert_eq "returns newest version regardless of SecurityReleases ordering" "26.3.1" "$result_ver"

echo ""
echo "--- Universal SecurityRelease: missing SupportedDevices falls back to Latest ---"
# Real SOFA omits SupportedDevices for universal releases (DeviceScope=universal).
# Only device-specific releases (like 26.3.2 for Neo) carry a SupportedDevices list.
# Function must treat missing SupportedDevices on a SecurityRelease as "applies to
# whatever Latest.SupportedDevices lists for this OS family."
UNIVERSAL_TEST_DATA='{"OSVersions":[{"Latest":{"ProductVersion":"26.4.1","Build":"25E42","SupportedDevices":["J314sAP","J313AP","J713AP","J700AP"]},"SecurityReleases":[{"ProductVersion":"26.4.1"},{"ProductVersion":"26.4"},{"ProductVersion":"26.3.2","SupportedDevices":["J700AP"]},{"ProductVersion":"26.3.1"},{"ProductVersion":"26.3","SupportedDevices":["J314sAP","J313AP","J713AP","J700AP"]}]}]}'
result=$(find_target_for_device "J314sAP" "$UNIVERSAL_TEST_DATA")
result_ver=$(echo "$result" | awk '{print $1}')
assert_eq "non-Neo board gets 26.4.1 from universal release" "26.4.1" "$result_ver"

# ============================================================
echo ""
echo "=== Test Suite: find_enforced_update ==="
# ============================================================

# Synthetic SOFA data: 26.4 for all, 26.3.2 Neo-only, 26.3.1 for all
DDM_SOFA='{"OSVersions":[{"Latest":{"ProductVersion":"26.4","Build":"25E0000","SupportedDevices":["J314sAP","J316sAP","J700AP"]},"SecurityReleases":[{"ProductVersion":"26.4","SupportedDevices":["J314sAP","J316sAP","J700AP"]},{"ProductVersion":"26.3.2","SupportedDevices":["J700AP"]},{"ProductVersion":"26.3.1","SupportedDevices":["J314sAP","J316sAP","J700AP"]}]}]}'

echo ""
echo "--- Brad's bug: DDM enforces Neo-only 26.3.2 on non-Neo hardware ---"
DDM_ENTRIES="26.3.2|2026-03-20T23:30:01"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
assert_eq "Neo-only enforcement skipped for J314sAP" "1" "$rc"
assert_eq "no output when skipped" "" "$result"

echo ""
echo "--- Same enforcement IS valid for Neo ---"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J700AP" "$DDM_SOFA")
rc=$?
result_ver=$(echo "$result" | cut -d'|' -f1)
assert_eq "Neo-only enforcement valid for J700AP" "0" "$rc"
assert_eq "returns 26.3.2 for Neo" "26.3.2" "$result_ver"

echo ""
echo "--- Already compliant - version already installed ---"
result=$(find_enforced_update "26.3.1|2026-03-20T23:30:01" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
assert_eq "already compliant returns failure" "1" "$rc"

echo ""
echo "--- Already compliant - newer version installed ---"
result=$(find_enforced_update "26.3.1|2026-03-20T23:30:01" "26.4" "J314sAP" "$DDM_SOFA")
rc=$?
assert_eq "newer version installed returns failure" "1" "$rc"

echo ""
echo "--- Valid enforcement for compatible version ---"
DDM_ENTRIES="26.4|2026-04-01T17:00:00"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
result_ver=$(echo "$result" | cut -d'|' -f1)
result_date=$(echo "$result" | cut -d'|' -f2)
assert_eq "compatible enforcement returns success" "0" "$rc"
assert_eq "returns correct version" "26.4" "$result_ver"
assert_eq "returns correct deadline" "2026-04-01T17:00:00" "$result_date"

echo ""
echo "--- Multiple enforcements: picks earliest deadline ---"
DDM_ENTRIES="26.4|2026-04-15T17:00:00
26.4|2026-04-01T09:00:00
26.4|2026-04-10T17:00:00"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
result_date=$(echo "$result" | cut -d'|' -f2)
assert_eq "picks earliest of multiple deadlines" "0" "$rc"
assert_eq "earliest deadline is April 1" "2026-04-01T09:00:00" "$result_date"

echo ""
echo "--- Mixed: one incompatible, one compatible ---"
DDM_ENTRIES="26.3.2|2026-03-20T23:30:01
26.4|2026-04-01T17:00:00"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
result_ver=$(echo "$result" | cut -d'|' -f1)
assert_eq "skips incompatible, returns compatible" "0" "$rc"
assert_eq "returns 26.4 not 26.3.2" "26.4" "$result_ver"

echo ""
echo "--- Empty entries ---"
result=$(find_enforced_update "" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
assert_eq "empty entries returns failure" "1" "$rc"

echo ""
echo "--- Overdue enforcement still returned ---"
DDM_ENTRIES="26.4|2025-01-01T00:00:00"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
result_ver=$(echo "$result" | cut -d'|' -f1)
assert_eq "overdue enforcement still returned" "0" "$rc"
assert_eq "returns correct version" "26.4" "$result_ver"

echo ""
echo "--- Stale + new: higher version wins over earlier deadline ---"
# Brad's 26.4/26.4.1 bug: an old 26.4 enforcement (deadline passed) lingered in the plist
# after 26.4.1 released with its own enforcement. Earliest-deadline rule picked stale 26.4.
# Correct rule: higher version wins — installing 26.4.1 satisfies both.
DDM_SOFA_41='{"OSVersions":[{"Latest":{"ProductVersion":"26.4.1","Build":"25E42","SupportedDevices":["J314sAP","J316sAP","J700AP"]},"SecurityReleases":[{"ProductVersion":"26.4.1"},{"ProductVersion":"26.4"},{"ProductVersion":"26.3.2","SupportedDevices":["J700AP"]}]}]}'
DDM_ENTRIES="26.4|2026-04-03T23:30:00
26.4.1|2026-04-22T23:30:00"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA_41")
rc=$?
result_ver=$(echo "$result" | cut -d'|' -f1)
result_date=$(echo "$result" | cut -d'|' -f2)
assert_eq "higher version picked over stale lower" "26.4.1" "$result_ver"
assert_eq "deadline matches higher version" "2026-04-22T23:30:00" "$result_date"

echo ""
echo "--- Same version, earliest deadline wins (tiebreaker) ---"
DDM_ENTRIES="26.4|2026-04-15T17:00:00
26.4|2026-04-01T09:00:00
26.4|2026-04-10T17:00:00"
result=$(find_enforced_update "$DDM_ENTRIES" "26.3.1" "J314sAP" "$DDM_SOFA")
rc=$?
result_date=$(echo "$result" | cut -d'|' -f2)
assert_eq "same version tiebreaker is earliest" "2026-04-01T09:00:00" "$result_date"

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
