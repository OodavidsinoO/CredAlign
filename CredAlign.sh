#!/usr/bin/env bash
set -o pipefail
# ============================================================================
# CredAlign.sh v1.0.1 — Enterprise Credential Alignment for Nessus Scanning
# ============================================================================

# ── Globals ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${SCRIPT_DIR}/inventory.txt"
STATE_FILE="${SCRIPT_DIR}/credflip_state_$(date +%Y%m%d).txt"
ERROR_LOG="${SCRIPT_DIR}/credflip_errors.log"
DEBUG_LOG="${SCRIPT_DIR}/credflip_debug.log"

LOCK_FILE="/tmp/credalign_${UID:-$(id -u)}.lock"
RESULTS_TMP=""
INVENTORY_TMP=""

MAX_PARALLEL=${MAX_PARALLEL:-10}
CONNECT_DELAY=${CONNECT_DELAY:-0.05}
SSH_RETRIES=${SSH_RETRIES:-2}
GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT:-1800}
DEBUG=${DEBUG:-0}

SSH_OPT="-o StrictHostKeyChecking=no -o ConnectTimeout=4 -o PasswordAuthentication=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=2"

declare -A STATE_MAP
MODE=""
TARGET_PASS=""
TOTAL_HOSTS=0
SKIP_COUNT=0
LOCK_FD=""
START_TIME=$(date +%s)
VERSION="1.0.1"
TIMEOUT_PID=""

# ── ANSI ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RST=$'\033[0m';    C_BLD=$'\033[1m';    C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GRN=$'\033[32m';   C_YEL=$'\033[33m'
    C_CYN=$'\033[36m';   C_MAG=$'\033[35m'
else
    C_RST=''; C_BLD=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_MAG=''
fi

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
CredAlign.sh v1.0.0 — Enterprise Credential Alignment Tool

USAGE:
  CredAlign.sh --dry-run | --change | --revert

MODES:
  --dry-run   Test SSH connectivity (no changes; does NOT write state file)
  --change    Change all host passwords from original → TARGET_PASSWORD
  --revert    Revert all host passwords from TARGET_PASSWORD → original

ENVIRONMENT:
  TARGET_PASSWORD   Unified target password (prompted if not set)
  MAX_PARALLEL      Max concurrent connections          (default: 10)
  CONNECT_DELAY     Delay between connection starts     (default: 0.05s)
  SSH_RETRIES       Connection retry attempts           (default: 2)
  GLOBAL_TIMEOUT    Overall timeout in seconds          (default: 1800)
  DEBUG=1           Enable debug logging to credflip_debug.log

FILES:
  inventory.txt                    CSV (no header): ip,username,original_password
  credflip_state_YYYYMMDD.txt      Daily state ledger
  credflip_errors.log              Error log
USAGE
    exit 2
}

# ── Fatal ───────────────────────────────────────────────────────────────────
die() {
    printf '%b[FATAL]%b %s\n' "$C_RED" "$C_RST" "$*" >&2
    exit 3
}

# ── Debug ───────────────────────────────────────────────────────────────────
_debug() { [[ "$DEBUG" -ge 1 ]] && printf '[DEBUG %(%H:%M:%S)T] %s\n' -1 "$*" >> "$DEBUG_LOG"; }

# ── Base64 Encode ───────────────────────────────────────────────────────────
_b64enc() {
    local raw="$1"
    if command -v base64 >/dev/null 2>&1; then
        printf '%s' "$raw" | base64 -w0 2>/dev/null || printf '%s' "$raw" | base64 | tr -d '\n'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$raw" | openssl base64 | tr -d '\n'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$raw" | python3 -c "import sys,base64;sys.stdout.write(base64.b64encode(sys.stdin.read().encode()).decode())"
    else
        die "No base64 encoder found (base64 / openssl / python3 required)"
    fi
}

# ── Logging ─────────────────────────────────────────────────────────────────
_log_rotate() {
    [[ -f "$ERROR_LOG" ]] || return
    local sz; sz=$(stat -c%s "$ERROR_LOG" 2>/dev/null) || return
    if [[ "$sz" -gt 10485760 ]]; then
        mv "$ERROR_LOG" "${ERROR_LOG}.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
}

log_error() {
    local ip="$1" user="$2" msg="$3"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] [$ip,$user] $msg"
    _log_rotate
    (
        flock -e 200
        printf '%s\n' "$line" >> "$ERROR_LOG"
    ) 200>>"$ERROR_LOG"
    [[ -t 2 ]] && printf '%b[ERROR]%b [%s,%s] %s\n' "$C_RED" "$C_RST" "$ip" "$user" "$msg" >&2
}

log_info() {
    local ip="$1" user="$2" msg="$3"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] [$ip,$user] $msg"
    _log_rotate
    (
        flock -e 200
        printf '%s\n' "$line" >> "$ERROR_LOG"
    ) 200>>"$ERROR_LOG"
    _debug "[$ip,$user] $msg"
}

# ── State Ledger ────────────────────────────────────────────────────────────
load_state() {
    [[ -f "$STATE_FILE" ]] || return 0
    local count=0
    while IFS=',' read -r ip user status _; do
        [[ -z "$ip" || "$ip" == \#* ]] && continue
        ip="${ip#"${ip%%[![:space:]]*}"}";     ip="${ip%"${ip##*[![:space:]]}"}"
        user="${user#"${user%%[![:space:]]*}"}"; user="${user%"${user##*[![:space:]]}"}"
        status="${status#"${status%%[![:space:]]*}"}"; status="${status%"${status##*[![:space:]]}"}"
        STATE_MAP["${ip},${user}"]="$status"
        ((count++))
    done < "$STATE_FILE"
    _debug "loaded $count entries from state: $STATE_FILE"
}

mark_state() {
    local ip="$1" user="$2" status="$3"
    (
        flock -e 201
        printf '%s\n' "${ip},${user},${status},$(date +%s)" >> "$STATE_FILE"
    ) 201>>"$STATE_FILE"
}

# ── Results ─────────────────────────────────────────────────────────────────
log_result() {
    local ip="$1" status="$2"
    (
        flock -e 202
        printf '%-16s  %-22s  %s\n' "$ip" "$status" "$(date +%H:%M:%S)" >> "$RESULTS_TMP"
    ) 202>>"$RESULTS_TMP"
}

# ── Progress Bar ────────────────────────────────────────────────────────────
draw_progress_bar() {
    local done="$1" total="$2"
    [[ "$total" -eq 0 ]] && total=1
    local pct=$((done * 100 / total))
    local bar_w=30
    local fill=$((pct * bar_w / 100))
    local bar_filled='' bar_empty=''
    printf -v bar_filled "%${fill}s"; bar_filled="${bar_filled// /#}"
    printf -v bar_empty "%$((bar_w - fill))s"; bar_empty="${bar_empty// /-}"
    printf '\r\033[K[%b%s%s%b] %3d/%d (%3d%%)' "$C_GRN" "$bar_filled" "$bar_empty" "$C_RST" "$done" "$total" "$pct"
}

progress_monitor() {
    local total="$1"
    local last=-1 done_cnt=0
    while true; do
        done_cnt=0
        [[ -f "$RESULTS_TMP" ]] && done_cnt=$(wc -l < "$RESULTS_TMP" 2>/dev/null) || done_cnt=0
        if [[ "$done_cnt" -ne "$last" ]]; then
            last="$done_cnt"
            draw_progress_bar "$done_cnt" "$total"
        fi
        [[ "$done_cnt" -ge "$total" ]] && break
        sleep 0.5
    done
    draw_progress_bar "$done_cnt" "$total"
    printf '\n'
}

# ── Prerequisites ───────────────────────────────────────────────────────────
check_prereqs() {
    local missing=''
    for cmd in sshpass ssh flock base64 mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [[ -n "$missing" ]] && die "Missing required tools:${missing}"
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
       { [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3 ]]; }; then
        die "Bash >= 4.3 required (current: ${BASH_VERSION})"
    fi
}

acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        printf '%b[ERROR]%b Another instance is already running (lock: %s)\n' \
            "$C_RED" "$C_RST" "$LOCK_FILE" >&2
        exit 5
    fi
}

check_inventory() {
    [[ -f "$INVENTORY_FILE" ]] || die "Inventory file not found: $INVENTORY_FILE"
    [[ -s "$INVENTORY_FILE" ]]  || die "Inventory file is empty: $INVENTORY_FILE"

    local has_root=0 line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        [[ "$line_num" -eq 1 ]] && line="${line#$'\xEF\xBB\xBF'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        IFS=',' read -r _ip user _ <<< "$line"
        user="${user#"${user%%[![:space:]]*}"}"; user="${user%"${user##*[![:space:]]}"}"
        if [[ "${user,,}" == "root" ]]; then
            printf '%b[REJECTED]%b Line %d: username "root" is forbidden\n' \
                "$C_RED" "$C_RST" "$line_num" >&2
            has_root=1
        fi
    done < "$INVENTORY_FILE"
    [[ "$has_root" -eq 1 ]] && die "Inventory contains root user entries — refusing for safety"
}

# ── Password Resolution ─────────────────────────────────────────────────────
resolve_target_pass() {
    if [[ "$MODE" == "dry-run" ]]; then
        _debug "dry-run mode: skipping target password resolution"
        return 0
    fi
    if [[ -n "${TARGET_PASSWORD:-}" ]]; then
        TARGET_PASS="$TARGET_PASSWORD"
        local trimmed; trimmed="${TARGET_PASS#"${TARGET_PASS%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ "$trimmed" != "$TARGET_PASS" ]] && die "TARGET_PASSWORD has leading/trailing whitespace"
        [[ -z "$TARGET_PASS" ]] && die "TARGET_PASSWORD is empty"
    else
        if [[ -t 0 ]]; then
            local c1 c2
            printf 'Enter target (unified) password: '
            read -r -s c1; printf '\n'
            printf 'Confirm target password: '
            read -r -s c2; printf '\n'
            [[ "$c1" != "$c2" ]] && die "Passwords do not match"
            [[ -z "$c1" ]] && die "Target password cannot be empty"
            TARGET_PASS="$c1"
        else
            die "TARGET_PASSWORD not set and terminal is non-interactive"
        fi
    fi
    _debug "target password resolved (len=${#TARGET_PASS})"
}

# ── SSH Auth Test ───────────────────────────────────────────────────────────
test_auth() {
    local ip="$1" user="$2" pass="$3"
    local ec=0
    for ((i=1; i<=SSH_RETRIES; i++)); do
        SSHPASS="$pass" sshpass -e ssh $SSH_OPT "$user@$ip" 'exit 0' 2>/dev/null
        ec=$?
        [[ "$ec" -eq 0 || "$ec" -eq 5 || "$ec" -eq 6 ]] && break
        [[ "$i" -lt "$SSH_RETRIES" ]] && sleep $((i * 2))
    done
    return "$ec"
}

# ── Remote Password Change ──────────────────────────────────────────────────
change_password_remote() {
    local ip="$1" user="$2" auth_pass="$3" new_pass="$4"

    local b64_user b64_pass b64_auth
    b64_user=$(_b64enc "$user")
    b64_pass=$(_b64enc "$new_pass")
    b64_auth=$(_b64enc "$auth_pass")

    local remote_cmd
    remote_cmd="_u=\$(printf '%s' '${b64_user}' | { base64 -d 2>/dev/null || openssl base64 -d 2>/dev/null; }) || { >&2 echo 'CREDALIGN_B64_FAIL'; exit 97; }
_d=\$(printf '%s' '${b64_pass}' | { base64 -d 2>/dev/null || openssl base64 -d 2>/dev/null; }) || { >&2 echo 'CREDALIGN_B64_FAIL'; exit 97; }
_a=\$(printf '%s' '${b64_auth}' | { base64 -d 2>/dev/null || openssl base64 -d 2>/dev/null; }) || { >&2 echo 'CREDALIGN_B64_FAIL'; exit 97; }
if command -v chpasswd >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
        printf '%s:%s\n' \"\$_u\" \"\$_d\" | sudo -n chpasswd 2>/dev/null
    elif command -v sudo >/dev/null 2>&1; then
        { printf '%s\n' \"\$_a\"; printf '%s:%s\n' \"\$_u\" \"\$_d\"; } | sudo -S -p '' chpasswd 2>/dev/null
    else
        printf '%s:%s\n' \"\$_u\" \"\$_d\" | chpasswd 2>/dev/null
    fi
    exit \$?
elif passwd --help 2>&1 | grep -q -- '--stdin'; then
    if sudo -n true 2>/dev/null; then
        printf '%s' \"\$_d\" | sudo -n passwd --stdin \"\$_u\" 2>/dev/null
    elif command -v sudo >/dev/null 2>&1; then
        { printf '%s\n' \"\$_a\"; printf '%s' \"\$_d\"; } | sudo -S -p '' passwd --stdin \"\$_u\" 2>/dev/null
    else
        printf '%s' \"\$_d\" | passwd --stdin \"\$_u\" 2>/dev/null
    fi
    exit \$?
else
    >&2 echo 'CREDALIGN_NO_TOOL'; exit 98
fi"

    local ec
    local stderr_tmp; stderr_tmp=$(mktemp /tmp/credalign_ssh_err_XXXXXX)
    SSHPASS="$auth_pass" sshpass -e ssh $SSH_OPT "$user@$ip" "$remote_cmd" 2>"$stderr_tmp"
    ec=$?
    if [[ "$ec" -ne 0 ]]; then
        local rerr; rerr=$(tr '\n' ' ' < "$stderr_tmp" 2>/dev/null)
        rerr="${rerr#"${rerr%%[![:space:]]*}"}"
        [[ -n "$rerr" ]] && log_info "$ip" "$user" "remote: $rerr"
    fi
    rm -f "$stderr_tmp"
    return "$ec"
}

# ── Mode: Dry Run ───────────────────────────────────────────────────────────
do_dry_run() {
    local ip="$1" user="$2" pass="$3"
    test_auth "$ip" "$user" "$pass"
    local ec=$?
    case "$ec" in
        0) log_result "$ip" "CONNECT_OK"      ; return 0 ;;
        5) log_result "$ip" "AUTH_FAIL"       ; log_error "$ip" "$user" "AUTH_FAILED on dry-run"; return 1 ;;
        6) log_result "$ip" "HOSTKEY_REJECT"  ; log_error "$ip" "$user" "Host key rejected on dry-run"; return 1 ;;
        *) log_result "$ip" "CONN_FAIL($ec)"  ; log_error "$ip" "$user" "Connection failed on dry-run (code=$ec)"; return 1 ;;
    esac
}

# ── Mode: Change ────────────────────────────────────────────────────────────
do_change() {
    local ip="$1" user="$2" pass="$3"

    # Attempt 1: original_password
    test_auth "$ip" "$user" "$pass"
    local ec1=$?

    if [[ "$ec1" -eq 0 ]]; then
        change_password_remote "$ip" "$user" "$pass" "$TARGET_PASS"
        local cec=$?
        if [[ "$cec" -eq 0 ]]; then
            mark_state "$ip" "$user" "SUCCESS_CHANGE"
            log_result "$ip" "SUCCESS_CHANGE"
            return 0
        else
            log_result "$ip" "CHPASSWD_FAIL($cec)"
            log_error "$ip" "$user" "chpasswd failed on change (code=$cec)"
            return 1
        fi
    elif [[ "$ec1" -eq 5 ]]; then
        # Auth fail → fallback: try TARGET_PASSWORD
        test_auth "$ip" "$user" "$TARGET_PASS"
        local ec2=$?
        if [[ "$ec2" -eq 0 ]]; then
            mark_state "$ip" "$user" "SUCCESS_CHANGE"
            log_result "$ip" "SUCCESS_CHANGE"
            log_info "$ip" "$user" "Already at target (fallback auth OK)"
            return 0
        else
            log_result "$ip" "AUTH_ERROR"
            log_error "$ip" "$user" "AUTH_FAILED on change (both passwords tried)"
            return 1
        fi
    elif [[ "$ec1" -eq 6 ]]; then
        log_result "$ip" "HOSTKEY_REJECT"
        log_error "$ip" "$user" "Host key rejected on change"
        return 1
    else
        log_result "$ip" "CONN_FAIL($ec1)"
        log_error "$ip" "$user" "Connection failed on change (code=$ec1)"
        return 1
    fi
}

# ── Mode: Revert ────────────────────────────────────────────────────────────
do_revert() {
    local ip="$1" user="$2" pass="$3"

    # Attempt 1: TARGET_PASSWORD
    test_auth "$ip" "$user" "$TARGET_PASS"
    local ec1=$?

    if [[ "$ec1" -eq 0 ]]; then
        change_password_remote "$ip" "$user" "$TARGET_PASS" "$pass"
        local cec=$?
        if [[ "$cec" -eq 0 ]]; then
            mark_state "$ip" "$user" "SUCCESS_REVERT"
            log_result "$ip" "SUCCESS_REVERT"
            return 0
        else
            log_result "$ip" "CHPASSWD_FAIL($cec)"
            log_error "$ip" "$user" "chpasswd failed on revert (code=$cec)"
            return 1
        fi
    elif [[ "$ec1" -eq 5 ]]; then
        # Auth fail → fallback: try original_password
        test_auth "$ip" "$user" "$pass"
        local ec2=$?
        if [[ "$ec2" -eq 0 ]]; then
            mark_state "$ip" "$user" "SUCCESS_REVERT"
            log_result "$ip" "SUCCESS_REVERT"
            log_info "$ip" "$user" "Already reverted (fallback auth OK)"
            return 0
        else
            log_result "$ip" "AUTH_ERROR"
            log_error "$ip" "$user" "AUTH_FAILED on revert (both passwords tried)"
            return 1
        fi
    elif [[ "$ec1" -eq 6 ]]; then
        log_result "$ip" "HOSTKEY_REJECT"
        log_error "$ip" "$user" "Host key rejected on revert"
        return 1
    else
        log_result "$ip" "CONN_FAIL($ec1)"
        log_error "$ip" "$user" "Connection failed on revert (code=$ec1)"
        return 1
    fi
}

# ── Inventory Filtering ─────────────────────────────────────────────────────
filter_inventory() {
    local mode="$1"
    local line_num=0 total=0 skipped=0 invalid=0

    > "$INVENTORY_TMP"

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        [[ "$line_num" -eq 1 ]] && line="${line#$'\xEF\xBB\xBF'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        ((total++))

        IFS=',' read -r ip user pass <<< "$line"
        ip="${ip#"${ip%%[![:space:]]*}"}";       ip="${ip%"${ip##*[![:space:]]}"}"
        user="${user#"${user%%[![:space:]]*}"}";   user="${user%"${user##*[![:space:]]}"}"
        pass="${pass#"${pass%%[![:space:]]*}"}";   pass="${pass%"${pass##*[![:space:]]}"}"

        if [[ -z "$ip" || -z "$user" || -z "$pass" ]]; then
            log_error "$ip" "$user" "Skipping line $line_num: empty field (ip/user/pass)"
            ((invalid++))
            continue
        fi

        local key="${ip},${user}"
        local expected
        case "$mode" in
            change) expected="SUCCESS_CHANGE" ;;
            revert) expected="SUCCESS_REVERT" ;;
            *)      expected="" ;;
        esac

        if [[ -n "$expected" && "${STATE_MAP[$key]:-}" == "$expected" ]]; then
            ((skipped++))
            continue
        fi

        printf '%s,%s,%s\n' "$ip" "$user" "$pass" >> "$INVENTORY_TMP"
    done < "$INVENTORY_FILE"

    TOTAL_HOSTS=$((total - skipped - invalid))
    SKIP_COUNT=$skipped
    _debug "filter: $total total, $skipped skipped, $invalid invalid, $TOTAL_HOSTS to process"
}

# ── Worker ──────────────────────────────────────────────────────────────────
worker() {
    local ip="$1" user="$2" pass="$3"
    case "$MODE" in
        dry-run) do_dry_run "$ip" "$user" "$pass" ;;
        change)  do_change  "$ip" "$user" "$pass" ;;
        revert)  do_revert  "$ip" "$user" "$pass" ;;
    esac
}

# ── Batch Runner ────────────────────────────────────────────────────────────
run_batch() {
    local mode_label
    case "$MODE" in
        dry-run) mode_label="DRY RUN" ;;
        change)  mode_label="CHANGE"  ;;
        revert)  mode_label="REVERT"  ;;
    esac

    printf '%b══════════════════════════════════════════════%b\n' "$C_CYN" "$C_RST"
    printf '%b%s%bv%s — Mode: %b%s%b\n' "$C_BLD" "$(printf '%-25s' 'CredAlign')" "$C_RST" \
        "$VERSION" "$C_GRN" "$mode_label" "$C_RST"
    printf '  Targets: %b%d%b | Skipped: %d | Parallel: %d | Delay: %.2fs\n' \
        "$C_BLD" "$TOTAL_HOSTS" "$C_RST" "$SKIP_COUNT" "$MAX_PARALLEL" "$CONNECT_DELAY"
    printf '%b──────────────────────────────────────────────────%b\n' "$C_CYN" "$C_RST"

    if [[ "$TOTAL_HOSTS" -eq 0 ]]; then
        printf '  All hosts already processed. Nothing to do.\n'
        return 0
    fi

    progress_monitor "$TOTAL_HOSTS" &
    local pm_pid=$!

    local running=0 processed=0 start_ts="$SECONDS"

    > "$RESULTS_TMP"

    while IFS=',' read -r ip user pass; do
        [[ -z "$ip" ]] && continue

        while [[ "$running" -ge "$MAX_PARALLEL" ]]; do
            wait -n 2>/dev/null
            if [[ $? -le 127 ]]; then
                ((running--))
            else
                running=0
                break
            fi
        done

        (
            worker "$ip" "$user" "$pass"
        ) &
        ((running++))
        ((processed++))

        sleep "$CONNECT_DELAY"
    done < "$INVENTORY_TMP"

    while [[ "$running" -gt 0 ]]; do
        wait -n 2>/dev/null
        if [[ $? -le 127 ]]; then
            ((running--))
        else
            running=0
        fi
    done

    kill "$pm_pid" 2>/dev/null || true
    wait "$pm_pid" 2>/dev/null || true

    local elapsed=$((SECONDS - start_ts))
    local ok=0 fail=0
    if [[ -f "$RESULTS_TMP" && -s "$RESULTS_TMP" ]]; then
        ok=$(grep -cE 'SUCCESS|CONNECT_OK' "$RESULTS_TMP" 2>/dev/null) || ok=0
        [[ -z "$ok" ]] && ok=0
        fail=$((processed - ok))
    fi

    printf '\n%b══════════════════════════════════════════════%b\n' "$C_CYN" "$C_RST"
    printf '  %bSUMMARY%b\n' "$C_BLD" "$C_RST"
    printf '  Total: %d | %bSuccess:%b %d | %bFailed:%b %d | Skipped: %d\n' \
        "$processed" "$C_GRN" "$C_RST" "$ok" "$C_RED" "$C_RST" "$fail" "$SKIP_COUNT"
    printf '  Duration: %ds | State: %s\n' "$elapsed" "$STATE_FILE"
    printf '  Errors:   %s\n' "$ERROR_LOG"
    printf '%b══════════════════════════════════════════════%b\n' "$C_CYN" "$C_RST"

    if [[ -f "$RESULTS_TMP" && -s "$RESULTS_TMP" ]]; then
        printf '\n%bResults:%b\n' "$C_BLD" "$C_RST"
        printf '  %-16s  %-22s  %s\n' 'HOST' 'STATUS' 'TIME'
        printf '  %s  %s  %s\n' '────────────────' '──────────────────────' '────────'
        sort "$RESULTS_TMP" | while IFS= read -r rline; do
            printf '  %s\n' "$rline"
        done
    fi

    [[ "$fail" -eq 0 ]] && return 0 || return 1
}

# ── Preflight ───────────────────────────────────────────────────────────────
preflight() {
    printf '%b[CredAlign]%b Preflight check ...\n' "$C_CYN" "$C_RST"
    check_prereqs
    check_inventory
    acquire_lock
    resolve_target_pass
    load_state

    # Validate and clamp numeric env vars
    [[ "$MAX_PARALLEL"    =~ ^[1-9][0-9]{0,2}$ ]] || MAX_PARALLEL=10
    if [[ "$MAX_PARALLEL" -gt 100 ]]; then MAX_PARALLEL=100; fi

    [[ "$SSH_RETRIES"     =~ ^[1-9][0-9]?$    ]] || SSH_RETRIES=2
    if [[ "$SSH_RETRIES" -gt 10 ]]; then SSH_RETRIES=10; fi

    [[ "$CONNECT_DELAY"   =~ ^0?\.[0-9]{1,3}$ ]] || CONNECT_DELAY=0.05

    [[ "$GLOBAL_TIMEOUT"  =~ ^[1-9][0-9]{0,4}$ ]] || GLOBAL_TIMEOUT=1800

    # Create secure temp files
    RESULTS_TMP=$(mktemp /tmp/credalign_results_XXXXXX)
    INVENTORY_TMP=$(mktemp /tmp/credalign_inventory_XXXXXX)

    _debug "MAX_PARALLEL=$MAX_PARALLEL SSH_RETRIES=$SSH_RETRIES DELAY=$CONNECT_DELAY TIMEOUT=$GLOBAL_TIMEOUT"
}

# ── Global Timeout Watchdog ─────────────────────────────────────────────────
_start_timeout() {
    [[ "$GLOBAL_TIMEOUT" -le 0 ]] && return
    (
        sleep "$GLOBAL_TIMEOUT"
        kill -ALRM $$ 2>/dev/null
    ) >/dev/null 2>&1 &
    TIMEOUT_PID=$!
}

_stop_timeout() {
    [[ -n "$TIMEOUT_PID" ]] && kill "$TIMEOUT_PID" 2>/dev/null || true
    TIMEOUT_PID=""
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    local _rc=$?
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    rm -f "$RESULTS_TMP" "$INVENTORY_TMP"
    [[ -n "$LOCK_FD" ]] && flock -u "$LOCK_FD" 2>/dev/null || true
    return $_rc
}

trap 'cleanup; printf "\n%b[ABORTED]%b Interrupted\n" "$C_RED" "$C_RST" >&2; exit 4' INT TERM
trap 'printf "\n%b[TIMEOUT]%b Global timeout (%ds) reached\n" "$C_RED" "$C_RST" "$GLOBAL_TIMEOUT" >&2; cleanup; exit 1' ALRM
trap 'cleanup' EXIT

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    [[ $# -ne 1 ]] && usage
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --change)  MODE="change"  ;;
        --revert)  MODE="revert"  ;;
        --help|-h) usage          ;;
        *) usage                  ;;
    esac

    preflight
    filter_inventory "$MODE"
    _start_timeout
    run_batch
    local _rc=$?
    _stop_timeout
    return $_rc
}

main "$@"
