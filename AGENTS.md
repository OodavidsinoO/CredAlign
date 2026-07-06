# AGENTS.md — CredAlign

## Project overview

Single-file enterprise Bash script (`CredAlign.sh`, ~700 LOC) that temporarily aligns passwords across hundreds of Linux hosts for Nessus scanning, then reverts them. Inventory is a CSV without headers (`ip,username,original_password`). Three modes: `--dry-run`, `--change`, `--revert`.

### v1.1.0: Dry-run now probes remote capability
`--dry-run` connects to each host and probes: (a) available tool (`chpasswd` or `passwd_stdin`), (b) sudo method (`sudo_n` / `sudo_S` / `raw`). Output format: `CAP:<tool>:<method>` (e.g. `CAP:chpasswd:sudo_S`). The old `CONNECT_OK` status is gone. `probe_remote_capability()` mirrors `change_password_remote()` but uses `true`/`id` instead of `chpasswd` — never modifies passwords.

## Dev commands

```bash
# Syntax check only
bash -n CredAlign.sh

# Unit tests (no network needed, ~5s)
bash tests/test_unit.sh

# Integration tests (needs 192.168.1.242, hermes:hermes accessible)
TARGET_PASSWORD="<pw>" bash tests/test_integration.sh

# All tests via runner
TARGET_PASSWORD="<pw>" bash tests/test_runner.sh --all
```

## Critical gotchas (agents WILL break things without these)

### No `set -e` — only `set -o pipefail`
Worker functions use explicit `||` chains. Adding `set -e` will cause mysterious early exits in background workers.

### Never `wait` without args in `run_batch`
There is a background timeout watchdog (`_start_timeout`) that holds a fd. `wait` without args waits for it and hangs for `GLOBAL_TIMEOUT` seconds. Always use `while running>0; do wait -n; done`.

### Background processes inherit stdout — redirect or they hang `$()`
Any `( ... ) &` launched from the script keeps stdout open. Inside `$()` command substitution, this causes the capture to block until the background process exits. The timeout watchdog was the culprit — always redirect: `( ... ) >/dev/null 2>&1 &`.

### `grep -c` with 0 matches: outputs `0`, exits `1`
`grep -cE 'pattern' file 2>/dev/null || echo 0` produces `0\n0` (double zero), which breaks arithmetic. Solution: check file existence first, then `grep -c ... || ok=0` with a separate `[[ -z "$ok" ]] && ok=0` guard. See `run_batch` line ~550.

### `sshpass -e` only, never pass password as CLI arg
Passwords live exclusively in `SSHPASS` env var. The SSH_OPT string must NOT contain `BatchMode=yes` (prevents sshpass from feeding the password prompt). DO NOT add it back.

### REMOTE auth uses 3-tier sudo
The remote `change_password_remote` function does: (1) `sudo -n chpasswd` (passwordless), (2) `sudo -S chpasswd` with auth password fed via stdin, (3) `chpasswd` bare (root user). Changing this ordering or removing the `sudo -S` fallback will break hosts without passwordless sudo (e.g., Ubuntu default). The auth password is base64-encoded and passed alongside user/pass in the remote command.

### Lock file path is per-UID
`/tmp/credalign_${UID:-$(id -u)}.lock` — not `/tmp/credalign.lock`. Tests and cleanup commands must match. Multiple users on the same host get independent locks.

### `--dry-run` skips TARGET_PASSWORD resolution entirely
Don't test password prompt behavior with `--dry-run` — the `resolve_target_pass` function returns early on dry-run. Use `--change` or `--revert` for those tests.

### Unit test fixture: use `inventory_unit_test.txt`, not `inventory_valid.txt`
The unit test fixture uses `127.0.0.2` (loopback, no SSH) which fails in ~3ms. `inventory_valid.txt` has real RFC1918 IPs that timeout at 4s per host. Unit tests will run 10x slower with the wrong fixture.

### Integration test target is hardcoded
`tests/test_integration.sh` hardcodes `TEST_IP=192.168.1.242`, `TEST_USER=hermes`, `TEST_ORIG_PASS=hermes`. The tests perform a real `change → verify → revert → verify` cycle. The server's password will be modified and restored. Must be reachable.

### ANSI colors: blank on non-TTY
`[[ -t 1 ]]` guard sets all color vars to empty strings when stdout is not a terminal. Color references in error messages (stderr) still work with `[[ -t 2 ]]`. Don't assume colors are always present.

### Remote stderr is captured, not suppressed
`change_password_remote` captures remote stderr to a temp file and logs it via `log_info` to the error log. `CHPASSWD_FAIL(97)` in results means check `credalign_errors.log` for the remote error message.

### `sort -V` removed — use plain `sort`
The script targets BusyBox compatibility where possible. Result sorting uses plain `sort` (defaults to lexicographic, which works for IP/status lines).

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All targets OK |
| 1 | Partial failures (check `credalign_errors.log`) |
| 2 | Bad args |
| 3 | Missing deps, root user in inventory, empty inventory |
| 4 | SIGINT/SIGTERM |
| 5 | Another instance running (lock contention) |
