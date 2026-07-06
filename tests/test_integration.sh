#!/usr/bin/env bash
# ============================================================================
# test_integration.sh — Integration tests against 192.168.1.242
# ============================================================================
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
TEST_IP="192.168.1.242"
TEST_USER="hermes"
TEST_ORIG_PASS="hermes"

TMPD="/tmp/credalign_integration_$$"
SSH_OPT="-o StrictHostKeyChecking=no -o ConnectTimeout=4 -o PasswordAuthentication=yes -o PubkeyAuthentication=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

PASS=0
FAIL=0

G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[1m'; X='\033[0m'; C='\033[36m'

# ── Helpers ─────────────────────────────────────────────────────────────────
ok()   { ((PASS++)); printf "  ${G}[PASS]${X} %s\n" "$*"; }
fail() { ((FAIL++)); printf "  ${R}[FAIL]${X} %s\n" "$*"; }
header() { printf "\n${B}${C}── %s ──${X}\n" "$*"; }

# Remote command runner (uses SSHPASS internally)
remote_exec() {
    local user="$1" pass="$2"; shift 2
    SSHPASS="$pass" sshpass -e ssh $SSH_OPT "$user@$TEST_IP" "$@" 2>/dev/null
}

test_ssh_conn() {
    local user="$1" pass="$2"
    remote_exec "$user" "$pass" 'exit 0'
    return $?
}

# ────────────────────────────────────────────────────────────────────────────
# Setup
# ────────────────────────────────────────────────────────────────────────────
setup() {
    header "Setup: Ensure Clean Environment"

    rm -rf "$TMPD"
    mkdir -p "$TMPD"
    cp "$PROJECT_DIR/CredAlign.sh" "$TMPD/"

    # ── Determine current password state on the remote ──
    local s1 s2
    if test_ssh_conn "$TEST_USER" "$TEST_ORIG_PASS"; then
        ok "SSH with original password → OK (state is clean)"
        CURRENT_STATE="original"
    elif test_ssh_conn "$TEST_USER" "$TARGET_PASSWORD"; then
        fail "SSH with target password → OK (state is DIRTY, will revert)"
        CURRENT_STATE="target"
    else
        fail "SSH failed with BOTH passwords — cannot proceed"
        exit 1
    fi

    # Ensure original state
    if [[ "$CURRENT_STATE" == "target" ]]; then
        ok "Reverting to original password first..."
        printf '%s\n' "$TARGET_PASSWORD" "$TARGET_PASSWORD" | \
            SSHPASS="$TARGET_PASSWORD" sshpass -e ssh $SSH_OPT "$TEST_USER@$TEST_IP" \
            "printf '%s:%s\n' '$TEST_USER' '$TEST_ORIG_PASS' | { sudo -n chpasswd 2>/dev/null || chpasswd; }" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            ok "Reverted to original password"
        else
            fail "Could not revert to original password"
            exit 1
        fi
    fi

    # Create inventory
    printf '%s,%s,%s\n' "$TEST_IP" "$TEST_USER" "$TEST_ORIG_PASS" > "$TMPD/inventory.txt"
    ok "Inventory prepared: $TEST_IP,$TEST_USER"
}

# ────────────────────────────────────────────────────────────────────────────
# Test 1: Dry Run
# ────────────────────────────────────────────────────────────────────────────
test_dry_run() {
    header "Test 1: --dry-run"

    cd "$TMPD"

    # Remove any state file from previous runs
    rm -f "$TMPD"/credalign_state_*.txt

    local out ec
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --dry-run 2>&1)
    ec=$?

    if [[ "$ec" -eq 0 ]]; then
        ok "--dry-run exit 0"
    else
        fail "--dry-run exit $ec (expected 0)"
    fi

    if echo "$out" | grep -qE 'CAP:(chpasswd|passwd_stdin):(sudo_n|sudo_S|raw)'; then
        ok "dry-run reports CAP capability"
    else
        fail "dry-run did NOT report CAP capability"
        printf '    Output: %s\n' "$(echo "$out" | tail -5)"
    fi

    # Dry run should NOT write state file
    local sf; sf=$(ls "$TMPD"/credalign_state_*.txt 2>/dev/null || true)
    if [[ -z "$sf" || ! -s "$sf" ]]; then
        ok "dry-run did NOT write state file"
    else
        fail "dry-run wrote state file unexpectedly"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Test 2: Change
# ────────────────────────────────────────────────────────────────────────────
test_change() {
    header "Test 2: --change"

    cd "$TMPD"
    rm -f credalign_state_*.txt credalign_errors.log

    local out ec
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --change 2>&1)
    ec=$?

    printf '%s\n' "$out"

    if [[ "$ec" -eq 0 ]]; then
        ok "--change exit 0"
    else
        fail "--change exit $ec (expected 0)"
    fi

    if echo "$out" | grep -q 'SUCCESS_CHANGE'; then
        ok "reports SUCCESS_CHANGE"
    else
        fail "did NOT report SUCCESS_CHANGE"
    fi

    # State file should have SUCCESS_CHANGE
    local sf; sf=$(ls "$TMPD"/credalign_state_*.txt 2>/dev/null || true)
    if [[ -n "$sf" && -s "$sf" ]]; then
        ok "state file exists after change"
        if grep -q 'SUCCESS_CHANGE' "$sf"; then
            ok "state file contains SUCCESS_CHANGE"
        else
            fail "state file does NOT contain SUCCESS_CHANGE"
        fi
    else
        fail "state file NOT created after change"
    fi

    # Verify: can connect with TARGET_PASSWORD
    if test_ssh_conn "$TEST_USER" "$TARGET_PASSWORD"; then
        ok "SSH with target password → OK (change confirmed)"
    else
        fail "SSH with target password → FAIL (change did NOT take effect)"
    fi

    # Verify: CANNOT connect with original password
    if test_ssh_conn "$TEST_USER" "$TEST_ORIG_PASS"; then
        fail "SSH with original password → OK (should have FAILED)"
    else
        ok "SSH with original password → FAIL (correct, password changed)"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Test 3: Change Idempotency
# ────────────────────────────────────────────────────────────────────────────
test_change_idempotent() {
    header "Test 3: --change (idempotency)"

    cd "$TMPD"

    local out ec
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --change 2>&1)
    ec=$?

    printf '%s\n' "$out"

    if [[ "$ec" -eq 0 ]]; then
        ok "second --change exit 0"
    else
        fail "second --change exit $ec (expected 0)"
    fi

    # Should show "All hosts already processed" or similar
    if echo "$out" | grep -qiE 'already|nothing to do|skipped.*1'; then
        ok "idempotent: host already processed"
    else
        fail "idempotent: host should show as already processed"
        printf '    Output tail: %s\n' "$(echo "$out" | tail -5)"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Test 4: Revert
# ────────────────────────────────────────────────────────────────────────────
test_revert() {
    header "Test 4: --revert"

    cd "$TMPD"
    rm -f credalign_state_*.txt credalign_errors.log

    local out ec
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --revert 2>&1)
    ec=$?

    printf '%s\n' "$out"

    if [[ "$ec" -eq 0 ]]; then
        ok "--revert exit 0"
    else
        fail "--revert exit $ec (expected 0)"
    fi

    if echo "$out" | grep -q 'SUCCESS_REVERT'; then
        ok "reports SUCCESS_REVERT"
    else
        fail "did NOT report SUCCESS_REVERT"
    fi

    # State file should have SUCCESS_REVERT
    local sf; sf=$(ls "$TMPD"/credalign_state_*.txt 2>/dev/null || true)
    if [[ -n "$sf" && -s "$sf" ]] && grep -q 'SUCCESS_REVERT' "$sf"; then
        ok "state file contains SUCCESS_REVERT"
    else
        fail "state file does NOT contain SUCCESS_REVERT"
    fi

    # Verify: can connect with ORIGINAL password
    if test_ssh_conn "$TEST_USER" "$TEST_ORIG_PASS"; then
        ok "SSH with original password → OK (revert confirmed)"
    else
        fail "SSH with original password → FAIL (revert did NOT take effect)"
    fi

    # Verify: CANNOT connect with TARGET_PASSWORD
    if test_ssh_conn "$TEST_USER" "$TARGET_PASSWORD"; then
        fail "SSH with target password → OK (should have FAILED)"
    else
        ok "SSH with target password → FAIL (correct, password reverted)"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Test 5: Revert Idempotency
# ────────────────────────────────────────────────────────────────────────────
test_revert_idempotent() {
    header "Test 5: --revert (idempotency)"

    cd "$TMPD"

    local out ec
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --revert 2>&1)
    ec=$?

    printf '%s\n' "$out"

    if [[ "$ec" -eq 0 ]]; then
        ok "second --revert exit 0"
    else
        fail "second --revert exit $ec (expected 0)"
    fi

    if echo "$out" | grep -qiE 'already|nothing to do|skipped.*1'; then
        ok "idempotent: host already reverted"
    else
        fail "idempotent: host should show as already reverted"
        printf '    Output tail: %s\n' "$(echo "$out" | tail -5)"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Test 6: End-to-End (Change → Revert Full Cycle)
# ────────────────────────────────────────────────────────────────────────────
test_e2e_cycle() {
    header "Test 6: Full Change → Revert Cycle (clean state)"

    cd "$TMPD"

    # Remove state to start fresh
    rm -f credalign_state_*.txt credalign_errors.log

    # Step 1: Ensure original state
    if ! test_ssh_conn "$TEST_USER" "$TEST_ORIG_PASS"; then
        fail "Pre-condition: SSH with original password failed"
        return
    fi
    ok "Pre-condition: SSH with original password OK"

    # Step 2: Change
    local out; out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --change 2>&1)
    if echo "$out" | grep -q 'SUCCESS_CHANGE'; then
        ok "E2E Change: SUCCESS_CHANGE reported"
    else
        fail "E2E Change: FAILED"
        return
    fi

    # Step 3: Verify target password works
    if test_ssh_conn "$TEST_USER" "$TARGET_PASSWORD"; then
        ok "E2E Change: target password works"
    else
        fail "E2E Change: target password verification failed"
        return
    fi

    # Step 4: Revert
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --revert 2>&1)
    if echo "$out" | grep -q 'SUCCESS_REVERT'; then
        ok "E2E Revert: SUCCESS_REVERT reported"
    else
        fail "E2E Revert: FAILED"
        return
    fi

    # Step 5: Verify original password works again
    if test_ssh_conn "$TEST_USER" "$TEST_ORIG_PASS"; then
        ok "E2E Revert: original password works again"
    else
        fail "E2E Revert: original password verification failed"
    fi

    ok "Full cycle: change → verify → revert → verify PASSED"
}

# ────────────────────────────────────────────────────────────────────────────
# Test 7: Adaptive Auth (Fallback on --change when already at target)
# ────────────────────────────────────────────────────────────────────────────
test_adaptive_auth() {
    header "Test 7: Adaptive Auth (fallback when already at target)"

    cd "$TMPD"
    rm -f credalign_state_*.txt credalign_errors.log

    # Ensure we are at original password
    TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --revert >/dev/null 2>&1 || true
    rm -f credalign_state_*.txt credalign_errors.log

    # Step 1: Change to target using the script
    local out; out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --change 2>&1)
    if ! echo "$out" | grep -q 'SUCCESS_CHANGE'; then
        fail "adaptive auth: setup change failed"
        return
    fi
    ok "adaptive auth: first change OK"

    # Step 2: Remove state file so the script discovers state via auth
    rm -f credalign_state_*.txt credalign_errors.log

    # Step 3: Run --change again: original password should fail,
    # fallback with TARGET_PASSWORD should succeed
    out=$(TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --change 2>&1)

    if echo "$out" | grep -q 'SUCCESS_CHANGE'; then
        ok "adaptive auth: SUCCESS_CHANGE via fallback"
    else
        fail "adaptive auth: FAILED (should succeed via fallback)"
        printf '    Output tail: %s\n' "$(echo "$out" | tail -5)"
    fi

    # Revert to original state
    TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --revert >/dev/null 2>&1 || true
}

# ────────────────────────────────────────────────────────────────────────────
# Test 8: Concurrent Execution Prevention
# ────────────────────────────────────────────────────────────────────────────
test_lock() {
    header "Test 8: Lock Prevents Concurrent Execution"

    cd "$TMPD"
    rm -f credalign_state_*.txt credalign_errors.log "/tmp/credalign_${UID:-$(id -u)}.lock"

    # Hold the lock for 5 seconds to simulate a long-running instance
    flock "/tmp/credalign_${UID:-$(id -u)}.lock" sleep 5 &
    local lock_pid=$!
    sleep 0.5

    local out2 ec2
    out2=$(cd "$TMPD" && TARGET_PASSWORD="$TARGET_PASSWORD" bash ./CredAlign.sh --dry-run 2>&1); ec2=$?
    wait "$lock_pid" 2>/dev/null || true

    if [[ "$ec2" -eq 5 ]] || echo "$out2" | grep -qiE 'already running'; then
        ok "concurrent execution prevented by lock"
    else
        fail "concurrent execution NOT prevented (exit=$ec2)"
        printf '    Output: %s\n' "$(echo "$out2" | head -5)"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────────
main() {
    printf "${B}${C}══════════════════════════════════════════════${X}\n"
    printf "${B}  CredAlign Integration Tests${X}\n"
    printf "${B}${C}══════════════════════════════════════════════${X}\n"
    printf "  Target: %s (user=%s)\n" "$TEST_IP" "$TEST_USER"

    # Resolve target password
    if [[ -n "${TARGET_PASSWORD:-}" ]]; then
        TARGET_PASSWORD="${TARGET_PASSWORD}"
        printf "  Target Password: %s (from env)\n" "${TARGET_PASSWORD:0:1}****"
    else
        printf 'Enter TARGET_PASSWORD for integration tests: '
        read -r -s TARGET_PASSWORD
        printf '\n'
    fi

    [[ -z "$TARGET_PASSWORD" ]] && { printf "${R}No target password provided${X}\n"; exit 1; }

    setup
    test_dry_run
    test_lock
    test_change
    test_change_idempotent
    test_revert
    test_revert_idempotent
    test_e2e_cycle
    test_adaptive_auth

    printf "\n${B}${C}──────────────────────────────────────────────────${X}\n"
    printf "${B}  Results: ${G}%d PASS${X}  ${R}%d FAIL${X}  Total: %d${X}\n" "$PASS" "$FAIL" $((PASS + FAIL))
    printf "${B}${C}──────────────────────────────────────────────────${X}\n"

    # Cleanup
    rm -rf "$TMPD"
    printf "\n  Temp directory cleaned: %s\n" "$TMPD"

    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
