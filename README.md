# CredAlign — Enterprise Credential Alignment Tool

Temporarily aligns passwords across hundreds of Linux hosts for Nessus scanning, then reverts to original passwords.

## Directory Structure

```
CredAlign/
├── CredAlign.sh              # Main script
├── inventory.txt             # Host inventory (see below)
├── tests/
│   ├── test_runner.sh        # Test orchestrator
│   ├── test_unit.sh          # Unit tests (logic only, no network needed)
│   └── test_integration.sh   # Integration tests (SSH target required)
├── fixtures/                 # Sample inventory files for testing
└── README.md
```

## Dependencies

- **Local**: `bash >= 4.3`, `sshpass`, `ssh`, `flock`, `base64` (or `openssl` / `python3`), `mktemp`
- **Remote**: `chpasswd` (preferred) or `passwd --stdin` (RHEL family fallback), `base64` (or `openssl`)

### Installing Dependencies

```bash
# Debian/Ubuntu
apt install sshpass coreutils util-linux

# RHEL/CentOS
yum install sshpass coreutils
```

## Quick Start

### 1. Create inventory.txt

```csv
192.168.1.10,admin,original_pass_for_admin
192.168.1.11,ops,P@ssw0rd!
192.168.1.12,deploy,deploy456
```

- Headerless CSV: `ip,username,original_password`
- `#` comment lines and blank lines are supported
- **Never** include `root` as username — the script will refuse to run

### 2. Run

```bash
# Set the unified target password (recommended)
export TARGET_PASSWORD="NessusTemp2026!"

# Three modes:

# 1) Dry-run — test SSH connectivity + probe remote chpasswd/sudo capability
bash CredAlign.sh --dry-run

# 2) Change — batch-change all passwords from original → TARGET_PASSWORD
bash CredAlign.sh --change

# 3) Revert — batch-revert all passwords from TARGET_PASSWORD → original
bash CredAlign.sh --revert
```

If `TARGET_PASSWORD` is not set, the script prompts interactively (with confirmation).

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TARGET_PASSWORD` | (prompted) | Unified target password |
| `MAX_PARALLEL` | 10 | Max concurrent connections |
| `CONNECT_DELAY` | 0.05 | Startup delay between connections (sec) |
| `SSH_RETRIES` | 2 | Connection retry count |
| `GLOBAL_TIMEOUT` | 1800 | Global timeout (sec) |
| `DEBUG` | 1 | Enable debug logging |

## Modes

### `--dry-run`

- Tests SSH connectivity using `original_password`
- For each reachable host, probes remote password-change capability:
  - Available tool: `chpasswd` or `passwd --stdin`
  - Sudo method: `sudo_n` (passwordless), `sudo_S` (password-piped), `raw` (root user)
- Output format: `CAP:<tool>:<method>` (e.g. `CAP:chpasswd:sudo_S`)
- **Does NOT** write state file, does **NOT** change passwords
- Unreachable hosts still report `CONN_FAIL`, `AUTH_FAIL`

### `--change`

- **Attempt 1**: Connect with `original_password` → `chpasswd` to `TARGET_PASSWORD`
- **Attempt 2 (fallback)**: On auth failure, try `TARGET_PASSWORD` → mark as already processed (previous run completed)
- Writes `SUCCESS_CHANGE` to state file for each successfully changed host

### `--revert`

- **Attempt 1**: Connect with `TARGET_PASSWORD` → `chpasswd` back to `original_password`
- **Attempt 2 (fallback)**: On auth failure, try `original_password` → mark as already reverted
- Writes `SUCCESS_REVERT` to state file for each successfully reverted host

## Generated Files

| File | Description |
|---|---|
| `credflip_state_YYYYMMDD.txt` | Daily state ledger: `ip,username,status,timestamp` |
| `credflip_errors.log` | Error log (auto-rotated at >10MB) |
| `credflip_debug.log` | Debug log (only when DEBUG=1) |

### State File Example

```
192.168.1.10,admin,SUCCESS_CHANGE,1750000000
192.168.1.11,ops,SUCCESS_REVERT,1750000060
```

Entries matching the current mode's status are **automatically skipped** on re-run (idempotency).

## Security

- **Passwords never in process tree**: `SSHPASS` env var + `sshpass -e`
- **Remote password via base64**: decoded on remote, piped to `chpasswd`
- **Root user rejected**: any `username=root` line causes script to exit
- **Single-instance lock**: `/tmp/credalign_UID.lock` + `flock` (per-UID isolation)
- **Strict SSH options**: `PubkeyAuthentication=no`, `PasswordAuthentication=yes`, `PreferredAuthentications=password`, host keys never written to known_hosts

## Compatibility

### Remote Password Change (priority order)

1. `chpasswd` → most universal (all major distros)
2. `passwd --stdin` → RHEL/CentOS/Amazon Linux 2 etc.

### Sudo Strategy

- Try `sudo -n` first (passwordless sudo)
- On failure, use `sudo -S` (feed user's password via stdin)
- If sudo unavailable, invoke chpasswd directly (root users)

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | All targets OK |
| 1 | Partial failures (check `credflip_errors.log`) |
| 2 | Bad arguments |
| 3 | Preconditions not met (missing tools / root in inventory) |
| 4 | Interrupted (SIGINT/SIGTERM) |
| 5 | Another instance running |

## Testing

### Unit Tests (no external environment needed)

```bash
bash tests/test_runner.sh --unit
```

### Integration Tests (requires reachable SSH target)

```bash
TARGET_PASSWORD="your_password" bash tests/test_runner.sh --integration
```

### All Tests

```bash
TARGET_PASSWORD="your_password" bash tests/test_runner.sh --all
```

## Typical Workflow

```bash
# 1. Prepare inventory
cat > inventory.txt <<EOF
192.168.1.10,admin,pa$$w0rd1
192.168.1.11,ops,s3cret!
192.168.1.12,deploy,deploy123
EOF

# 2. Dry-run verification
export TARGET_PASSWORD="TempNessus2026!"
bash CredAlign.sh --dry-run

# 3. Execute change
bash CredAlign.sh --change

# 4. Nessus scan ...

# 5. Revert passwords
bash CredAlign.sh --revert

# 6. Verify revert
bash CredAlign.sh --dry-run
```
