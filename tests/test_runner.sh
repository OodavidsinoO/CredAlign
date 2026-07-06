#!/usr/bin/env bash
# ============================================================================
# test_runner.sh — Orchestrates unit + integration tests
# ============================================================================
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEST="$TEST_DIR/test_unit.sh"
INTEG_TEST="$TEST_DIR/test_integration.sh"

G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[1m'; X='\033[0m'; C='\033[36m'

UNIT_RESULT=0
INTEG_RESULT=0

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
CredAlign Test Runner

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --all          Run all tests (unit + integration)  [default]
  --unit         Run unit tests only
  --integration  Run integration tests only (requires 192.168.1.242)
  --help         Show this help

ENVIRONMENT:
  TARGET_PASSWORD   Password for integration test --change/--revert cycle
EOF
    exit 0
}

# ── Banner ──────────────────────────────────────────────────────────────────
banner() {
    printf '\n%b%s%b\n' "$C" "$(printf '%0.s═' $(seq 1 50))" "$X"
    printf '%b  CredAlign Test Suite%b\n' "$B" "$X"
    printf '%b%s%b\n' "$C" "$(printf '%0.s═' $(seq 1 50))" "$X"
}

# ── Run Unit ────────────────────────────────────────────────────────────────
run_unit() {
    printf '\n%b[1/2] Running Unit Tests ...%b\n' "$Y" "$X"
    if bash "$UNIT_TEST"; then
        UNIT_RESULT=0
        printf '%b  Unit Tests: ALL PASSED%b\n' "$G" "$X"
    else
        UNIT_RESULT=1
        printf '%b  Unit Tests: FAILURES DETECTED%b\n' "$R" "$X"
    fi
}

# ── Run Integration ─────────────────────────────────────────────────────────
run_integration() {
    printf '\n%b[2/2] Running Integration Tests ...%b\n' "$Y" "$X"
    if bash "$INTEG_TEST"; then
        INTEG_RESULT=0
        printf '%b  Integration Tests: ALL PASSED%b\n' "$G" "$X"
    else
        INTEG_RESULT=1
        printf '%b  Integration Tests: FAILURES DETECTED%b\n' "$R" "$X"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
summary() {
    local total_fail=$((UNIT_RESULT + INTEG_RESULT))
    printf '\n%b%s%b\n' "$C" "$(printf '%0.s═' $(seq 1 50))" "$X"
    printf '%b  SUMMARY%b\n' "$B" "$X"
    printf '  Unit:         %s\n' "$([[ $UNIT_RESULT -eq 0 ]] && printf '%bPASS%b' "$G" "$X" || printf '%bFAIL%b' "$R" "$X")"
    printf '  Integration:  %s\n' "$([[ $INTEG_RESULT -eq 0 ]] && printf '%bPASS%b' "$G" "$X" || printf '%bFAIL%b' "$R" "$X")"
    printf '%b%s%b\n' "$C" "$(printf '%0.s═' $(seq 1 50))" "$X"

    if [[ "$total_fail" -gt 0 ]]; then
        printf '\n%bSome tests FAILED. Check output above for details.%b\n' "$R" "$X"
        exit 1
    else
        printf '\n%bAll tests PASSED.%b\n' "$G" "$X"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    local run_units=0
    local run_integ=0

    case "${1:-}" in
        --all|-a|"")
            run_units=1
            run_integ=1
            ;;
        --unit|-u)
            run_units=1
            ;;
        --integration|-i)
            run_integ=1
            ;;
        --help|-h)
            usage
            ;;
        *)
            printf '%bUnknown option: %s%b\n' "$R" "$1" "$X"
            usage
            ;;
    esac

    # Check if integration target is reachable
    if [[ "$run_integ" -eq 1 ]]; then
        if SSHPASS="${TARGET_PASSWORD:-}" sshpass -e ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
            -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
            hermes@192.168.1.242 'exit 0' 2>/dev/null; then
            printf '%b Integration target reachable: 192.168.1.242%b\n' "$G" "$X"
        elif SSHPASS="hermes" sshpass -e ssh \
            -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
            -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
            hermes@192.168.1.242 'exit 0' 2>/dev/null; then
            printf '%b Integration target reachable (original): 192.168.1.242%b\n' "$G" "$X"
        else
            printf '%b Integration target NOT reachable. Skipping integration tests.%b\n' "$Y" "$X"
            run_integ=0
        fi
    fi

    banner

    [[ "$run_units" -eq 1 ]] && run_unit
    [[ "$run_integ" -eq 1 ]] && run_integration

    if [[ "$run_units" -eq 0 && "$run_integ" -eq 0 ]]; then
        printf '%bNo tests selected.%b\n' "$Y" "$X"
        exit 1
    fi

    summary
}

main "$@"
