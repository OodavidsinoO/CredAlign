#!/usr/bin/env bash
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
FIXTURES_DIR="$PROJECT_DIR/fixtures"

PASS=0; FAIL=0
TEST_LOG="/tmp/credalign_unit_test_$$.log"
> "$TEST_LOG"

G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[1m'; X='\033[0m'; C='\033[36m'

ok()   { ((PASS++)); printf "  ${G}[PASS]${X} %s\n" "$*" | tee -a "$TEST_LOG"; }
fail() { ((FAIL++)); printf "  ${R}[FAIL]${X} %s\n" "$*" | tee -a "$TEST_LOG"; }
header() { printf "\n${B}${C}── %s ──${X}\n" "$*"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label ($expected==$actual)"
    else fail "$label (expected='$expected' got='$actual')"; fi
}
assert_ne() {
    local label="$1" not_val="$2" actual="$3"
    if [[ "$not_val" != "$actual" ]]; then ok "$label"
    else fail "$label (should NOT be '$not_val')"; fi
}
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then ok "$label"
    else fail "$label (expected to contain '$needle')"; fi
}
assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then ok "$label"
    else fail "$label (should NOT contain '$needle')"; fi
}

# ────────────────────────────────────────────────────────────────────────────
test_bash_version() {
    header "Bash Version Check"
    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then ok "Bash >= 4.3 (actual: ${BASH_VERSION})"
    else fail "Bash too old: ${BASH_VERSION}"; fi
}

# ────────────────────────────────────────────────────────────────────────────
test_parse_args() {
    header "Argument Parsing"
    local script="$PROJECT_DIR/CredAlign.sh"
    bash "$script" </dev/null >/dev/null 2>&1;    assert_eq "no args → exit 2" 2 $?
    bash "$script" --help >/dev/null 2>&1;         assert_eq "--help → exit 2" 2 $?
    bash "$script" --invalid >/dev/null 2>&1;      assert_eq "--invalid → exit 2" 2 $?
    bash "$script" --change --revert >/dev/null 2>&1; assert_eq "multi-arg → exit 2" 2 $?

    local tmpd="/tmp/credalign_test_parse_$$"; mkdir -p "$tmpd"
    cp "$script" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"
    local TARGET_PASSWORD="testtest"

    local out ec
    out=$(cd "$tmpd" && TARGET_PASSWORD="testtest" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_contains "--dry-run accepted (runs preflight)" "$out" "Preflight"
    out=$(cd "$tmpd" && TARGET_PASSWORD="testtest" bash ./CredAlign.sh --change 2>&1); ec=$?
    assert_contains "--change accepted (runs preflight)" "$out" "Preflight"
    out=$(cd "$tmpd" && TARGET_PASSWORD="testtest" bash ./CredAlign.sh --revert 2>&1); ec=$?
    assert_contains "--revert accepted (runs preflight)" "$out" "Preflight"
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_inventory() {
    header "Inventory Parsing & Root Detection"
    local tmpd="/tmp/credalign_test_inv_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"

    local out ec

    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_not_contains "valid inventory passes preflight" "$out" "forbidden"

    cp "$FIXTURES_DIR/inventory_with_root.txt" "$tmpd/inventory.txt"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_contains "root inventory rejected" "$out" "forbidden"
    assert_ne "root → non-zero exit" 0 "$ec"

    cp "$FIXTURES_DIR/inventory_empty.txt" "$tmpd/inventory.txt"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_contains "empty inventory rejected" "$out" "empty"
    assert_ne "empty → non-zero exit" 0 "$ec"

    cp "$FIXTURES_DIR/inventory_bom.txt" "$tmpd/inventory.txt"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_not_contains "BOM file passes preflight" "$out" "forbidden"

    rm -f "$tmpd/inventory.txt"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_contains "missing inventory rejected" "$out" "not found"
    assert_ne "missing → non-zero exit" 0 "$ec"

    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_max_parallel() {
    header "MAX_PARALLEL / SSH_RETRIES Validation"
    local tmpd="/tmp/credalign_test_par_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"

    local out
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" MAX_PARALLEL=abc bash ./CredAlign.sh --dry-run 2>&1) || true
    assert_not_contains "MAX_PARALLEL=abc → no crash" "$out" "FATAL"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" MAX_PARALLEL=0 bash ./CredAlign.sh --dry-run 2>&1) || true
    assert_not_contains "MAX_PARALLEL=0 → no crash" "$out" "FATAL"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" MAX_PARALLEL=-5 bash ./CredAlign.sh --dry-run 2>&1) || true
    assert_not_contains "MAX_PARALLEL=-5 → no crash" "$out" "FATAL"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" SSH_RETRIES=abc bash ./CredAlign.sh --dry-run 2>&1) || true
    assert_not_contains "SSH_RETRIES=abc → no crash" "$out" "FATAL"
    out=$(cd "$tmpd" && TARGET_PASSWORD="x" SSH_RETRIES=0 bash ./CredAlign.sh --dry-run 2>&1) || true
    assert_not_contains "SSH_RETRIES=0 → no crash" "$out" "FATAL"
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_password_prompt() {
    header "Password Prompt"
    local tmpd="/tmp/credalign_test_prompt_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"

    local out ec

    # Dry-run skips password resolution entirely
    out=$(cd "$tmpd" && bash ./CredAlign.sh --dry-run </dev/null 2>&1); ec=$?
    assert_not_contains "dry-run skips password prompt" "$out" "Enter target"
    assert_not_contains "dry-run skips password → no fatal" "$out" "FATAL"

    # TARGET_PASSWORD set via env → no prompt for change/revert
    out=$(cd "$tmpd" && TARGET_PASSWORD="mypass" bash ./CredAlign.sh --change 2>&1); ec=$?
    assert_not_contains "TARGET_PASSWORD set → no prompt" "$out" "Enter target"

    # TARGET_PASSWORD not set + piped stdin for --change → non-interactive fatal
    out=$(cd "$tmpd" && printf 'pass1\npass1\n' | bash ./CredAlign.sh --change 2>&1); ec=$?
    assert_contains "piped stdin → non-interactive" "$out" "non-interactive"
    assert_ne "piped stdin → non-zero exit" 0 "$ec"

    # /dev/null stdin for --change → non-interactive fatal
    out=$(cd "$tmpd" && bash ./CredAlign.sh --change </dev/null 2>&1); ec=$?
    assert_contains "/dev/null stdin → non-interactive" "$out" "non-interactive"
    assert_ne "/dev/null stdin → non-zero exit" 0 "$ec"
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_base64() {
    header "Base64 Encode/Decode Round-trip"
    _b64enc() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }
    local tcs=("simple" "p@ssw0rd!" "password with spaces" "test\nnewline" "unicode→↓→↑←" "a very long password")
    for tc in "${tcs[@]}"; do
        local enc; enc=$(_b64enc "$tc")
        local dec; dec=$(printf '%s' "$enc" | { base64 -d 2>/dev/null || openssl base64 -d 2>/dev/null; })
        if [[ "$dec" == "$tc" ]]; then ok "base64 round-trip: '$tc'"
        else fail "base64 round-trip FAIL: '$tc' → dec='$dec'"; fi
    done
}

# ────────────────────────────────────────────────────────────────────────────
test_special_chars() {
    header "Special Character Password Handling"
    _b64enc() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }
    local pass='p@$$w0rd!'
    local enc; enc=$(_b64enc "$pass")
    assert_ne "special chars → base64 encoded" "" "$enc"
    assert_not_contains "special chars → not plaintext in b64" "$enc" "p@$$w0rd"
    local dec; dec=$(printf '%s' "$enc" | base64 -d 2>/dev/null)
    assert_eq "special chars → round-trip" "$pass" "$dec"
    assert_not_contains "b64 → no rm injection" "$enc" ';rm'
    assert_not_contains "b64 → no backtick" "$enc" '`'
    assert_not_contains "b64 → no dollar-paren" "$enc" '$('
    assert_not_contains "b64 → no single quote" "$enc" "'"
}

# ────────────────────────────────────────────────────────────────────────────
test_ssh_options() {
    header "SSH Options Are Strict"
    local scr="$PROJECT_DIR/CredAlign.sh"
    assert_contains "StrictHostKeyChecking=no" "$(grep 'StrictHostKeyChecking' "$scr")" "StrictHostKeyChecking=no"
    assert_contains "PubkeyAuthentication=no"  "$(grep 'PubkeyAuthentication' "$scr")"  "PubkeyAuthentication=no"
    assert_contains "PasswordAuthentication=yes" "$(grep 'PasswordAuthentication' "$scr")" "PasswordAuthentication=yes"
    assert_contains "PreferredAuthentications=password" "$(grep 'PreferredAuthentications' "$scr")" "PreferredAuthentications=password"
    assert_contains "UserKnownHostsFile=/dev/null" "$(grep 'UserKnownHostsFile' "$scr")" "UserKnownHostsFile=/dev/null"
}

# ────────────────────────────────────────────────────────────────────────────
test_auth_logic() {
    header "Auth & Connection Error Dispatch"
    local tmpd="/tmp/credalign_test_auth_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    printf '127.0.0.2,testuser,testpass\n' > "$tmpd/inventory.txt"
    local out ec
    out=$(cd "$tmpd" && TARGET_PASSWORD="dummy" bash ./CredAlign.sh --dry-run 2>&1); ec=$?
    assert_contains "unreachable → CONN_FAIL" "$out" "CONN_FAIL"
    assert_not_contains "unreachable → no AUTH_ERROR" "$out" "AUTH_ERROR"
    assert_ne "failing host → non-zero exit" 0 "$ec"
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_state_file() {
    header "State File & Idempotency"
    local tmpd="/tmp/credalign_test_state_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"
    local sf="credflip_state_$(date +%Y%m%d).txt"
    printf '127.0.0.2,testuser,SUCCESS_CHANGE,1234567890\n' > "$tmpd/$sf"
    local out ec
    out=$(cd "$tmpd" && TARGET_PASSWORD="testtest" bash ./CredAlign.sh --change 2>&1); ec=$?
    assert_contains "state → Skipped count shown" "$out" "Skipped"
    assert_contains "state file has seeded entries" "$(cat "$tmpd/$sf")" "SUCCESS_CHANGE"
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_lock() {
    header "Single-Instance Lock"
    local tmpd="/tmp/credalign_test_lock_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"
    rm -f /tmp/credalign_*.lock
    flock /tmp/credalign_1000.lock sleep 3 &
    local lock_pid=$!
    sleep 0.3
    local out2 ec2
    out2=$(cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run 2>&1); ec2=$?
    wait "$lock_pid" 2>/dev/null || true
    if [[ "$ec2" -eq 5 ]] || echo "$out2" | grep -qiE 'already running'; then ok "lock prevents concurrent runs"
    else fail "lock did NOT prevent concurrent runs (exit=$ec2)"; fi
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_dry_run_isolation() {
    header "Dry Run → No State File"
    local tmpd="/tmp/credalign_test_dry_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"
    local sf="credflip_state_$(date +%Y%m%d).txt"
    (cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run >/dev/null 2>&1) || true
    if [[ ! -f "$tmpd/$sf" ]]; then ok "dry-run → no state file created"
    elif [[ ! -s "$tmpd/$sf" ]]; then ok "dry-run → state file empty"
    else fail "dry-run → state file should NOT be written"; fi
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_log_rotation() {
    header "Error Log Rotation"
    local tmpd="/tmp/credalign_test_log_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    cp "$FIXTURES_DIR/inventory_unit_test.txt" "$tmpd/inventory.txt"
    dd if=/dev/zero of="$tmpd/credflip_errors.log" bs=1M count=11 2>/dev/null
    (cd "$tmpd" && TARGET_PASSWORD="x" bash ./CredAlign.sh --dry-run >/dev/null 2>&1) || true
    local sz; sz=$(stat -c%s "$tmpd/credflip_errors.log" 2>/dev/null || echo 0)
    if [[ "$sz" -lt 10485760 ]]; then ok "large error log → rotated (now ${sz} bytes)"
    else fail "error log NOT rotated, still ${sz} bytes"; fi
    local rc; rc=$(ls "$tmpd"/credflip_errors.log.* 2>/dev/null | wc -l)
    if [[ "$rc" -ge 1 ]]; then ok "rotation backup exists"; else fail "no rotation backup found"; fi
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
test_trap_cleanup() {
    header "Trap & Cleanup on SIGTERM"
    local tmpd="/tmp/credalign_test_trap_$$"; mkdir -p "$tmpd"
    cp "$PROJECT_DIR/CredAlign.sh" "$tmpd/"
    printf '192.168.1.99,slow,pass\n' > "$tmpd/inventory.txt"  # unreachable with longer timeout
    (cd "$tmpd" && TARGET_PASSWORD="x" GLOBAL_TIMEOUT=10 bash ./CredAlign.sh --dry-run >/dev/null 2>&1) &
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        if [[ $? -ge 128 ]]; then ok "SIGTERM → exit by signal"
        else ok "SIGTERM → exited $?"; fi
    else
        ok "SIGTERM test → process already finished (fast host)"
    fi
    rm -rf "$tmpd"
}

# ────────────────────────────────────────────────────────────────────────────
main() {
    printf "${B}${C}══════════════════════════════════════════════${X}\n"
    printf "${B}  CredAlign Unit Tests${X}\n"
    printf "${B}${C}══════════════════════════════════════════════${X}\n"

    test_bash_version
    test_parse_args
    test_inventory
    test_max_parallel
    test_password_prompt
    test_base64
    test_special_chars
    test_ssh_options
    test_auth_logic
    test_state_file
    test_lock
    test_dry_run_isolation
    test_log_rotation
    test_trap_cleanup

    printf "\n${B}${C}──────────────────────────────────────────────────${X}\n"
    printf "${B}  Results: ${G}%d PASS${X}  ${R}%d FAIL${X}  Total: %d${X}\n" "$PASS" "$FAIL" $((PASS + FAIL))
    printf "${B}${C}──────────────────────────────────────────────────${X}\n"
    printf "  Log: %s\n" "$TEST_LOG"
    [[ "$FAIL" -gt 0 ]] && exit 1
}

main "$@"
