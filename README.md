# CredAlign — Enterprise Credential Alignment Tool

为 Nessus 扫描临时统一数百台 Linux 主机的 root/sudo 密码，事后可回退至各自原始密码。

## 目录结构

```
CredAlign/
├── CredAlign.sh              # 主脚本
├── inventory.txt             # 主机清单 (创建方式见下文)
├── tests/
│   ├── test_runner.sh        # 测试入口
│   ├── test_unit.sh          # 单元测试 (纯逻辑, 无需外部环境)
│   └── test_integration.sh   # 集成测试 (需 SSH 目标主机)
├── fixtures/                 # 测试用 inventory 样本
└── README.md
```

## 依赖

- **本地**: `bash >= 4.3`, `sshpass`, `ssh`, `flock`, `base64` (或 `openssl` / `python3`), `mktemp`
- **远程**: `chpasswd` (推荐) 或 `passwd --stdin` (RHEL 系 fallback), `base64` (或 `openssl`)

### 安装依赖

```bash
# Debian/Ubuntu
apt install sshpass coreutils util-linux

# RHEL/CentOS
yum install sshpass coreutils
```

## 快速开始

### 1. 创建 inventory.txt

```csv
192.168.1.10,admin,original_pass_for_admin
192.168.1.11,ops,P@ssw0rd!
192.168.1.12,deploy,deploy456
```

- 无表头 CSV: `ip,username,original_password`
- 支持 `#` 注释行和空行
- **严禁**包含 `root` 用户名, 脚本会拒绝执行

### 2. 运行

```bash
# 设置目标统一密码 (推荐)
export TARGET_PASSWORD="NessusTemp2024!"

# 三种模式:

# 1) 干跑 — 测试所有主机 SSH 可达性, 不做任何修改, 不写状态文件
bash CredAlign.sh --dry-run

# 2) 修改 — 批量将所有主机密码从 original → TARGET_PASSWORD
bash CredAlign.sh --change

# 3) 回退 — 批量将所有主机密码从 TARGET_PASSWORD → original
bash CredAlign.sh --revert
```

如果未设置 `TARGET_PASSWORD` 环境变量, 脚本会交互式提示输入 (带确认)。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TARGET_PASSWORD` | (提示) | 统一目标密码 |
| `MAX_PARALLEL` | 10 | 最大并发连接数 |
| `CONNECT_DELAY` | 0.05 | 连接间启动延迟 (秒) |
| `SSH_RETRIES` | 2 | 连接重试次数 |
| `GLOBAL_TIMEOUT` | 1800 | 全局超时 (秒) |
| `DEBUG` | 0 | 设为 1 开启调试日志 |

## 运行模式

### `--dry-run`

- 使用 `original_password` 测试 SSH 连接
- **不写**状态文件, **不改**密码
- 输出每台主机的连通状态: `CONNECT_OK`, `AUTH_FAIL`, `CONN_FAIL`

### `--change`

- **Attempt 1**: 用 `original_password` 连接 → `chpasswd` 改为 `TARGET_PASSWORD`
- **Attempt 2 (fallback)**: 若认证失败, 尝试用 `TARGET_PASSWORD` 连接 → 标记为已处理 (前次运行已完成)
- 每台成功修改的主机写入 `SUCCESS_CHANGE` 到状态文件

### `--revert`

- **Attempt 1**: 用 `TARGET_PASSWORD` 连接 → `chpasswd` 改回 `original_password`
- **Attempt 2 (fallback)**: 若认证失败, 尝试用 `original_password` 连接 → 标记为已回退
- 每台成功回退的主机写入 `SUCCESS_REVERT` 到状态文件

## 生成的文件

| 文件 | 说明 |
|---|---|
| `credflip_state_YYYYMMDD.txt` | 每日状态台账: `ip,username,status,timestamp` |
| `credflip_errors.log` | 错误日志 (>10MB 自动轮转) |
| `credflip_debug.log` | 调试日志 (仅 DEBUG=1 时) |

### 状态文件示例

```
192.168.1.10,admin,SUCCESS_CHANGE,1750000000
192.168.1.11,ops,SUCCESS_REVERT,1750000060
```

重新运行时, 已标记为对应状态的条目会被**自动跳过** (幂等性)。

## 安全特性

- **密码不在进程表暴露**: `SSHPASS` 环境变量 + `sshpass -e`
- **远程密码 base64 编码传输**: 远程端解码后管传 `chpasswd`
- **拒绝 root 用户**: inventory 中任何 `username=root` 的行都会导致脚本退出
- **单实例锁**: `/tmp/credalign_UID.lock` + `flock` 防止并发执行 (多用户独立锁)
- **严格 SSH 选项**: `PubkeyAuthentication=no`, `PasswordAuthentication=yes`, `PreferredAuthentications=password`, 所有主机 key 不写入 known_hosts

## 兼容性

### 远端密码修改方案 (按优先级)

1. `chpasswd` → 最通用 (所有主流发行版)
2. `passwd --stdin` → RHEL/CentOS/Amazon Linux 2 等

### sudo 策略

- 先尝试 `sudo -n` (免密 sudo)
- 若失败, 使用 `sudo -S` (通过 stdin 传入用户密码)
- 若 sudo 不可用, 直接调用 chpasswd (用户为 root 时生效)

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 全部成功 |
| 1 | 部分主机失败 (查看 `credflip_errors.log`) |
| 2 | 参数错误 |
| 3 | 前置条件不满足 (工具缺失/root 拒绝) |
| 4 | 用户中断 (SIGINT/SIGTERM) |
| 5 | 另一实例正在运行 |

## 测试

### 单元测试 (无需外部环境)

```bash
bash tests/test_runner.sh --unit
```

### 集成测试 (需可访问的 SSH 目标)

```bash
TARGET_PASSWORD="your_password" bash tests/test_runner.sh --integration
```

### 全部测试

```bash
TARGET_PASSWORD="your_password" bash tests/test_runner.sh --all
```

## 典型工作流

```bash
# 1. 准备 inventory
cat > inventory.txt <<EOF
192.168.1.10,admin,pa$$w0rd1
192.168.1.11,ops,s3cret!
192.168.1.12,deploy,deploy123
EOF

# 2. 干跑验证
export TARGET_PASSWORD="TempNessus2024!"
bash CredAlign.sh --dry-run

# 3. 执行修改
bash CredAlign.sh --change

# 4. Nessus 扫描 ...

# 5. 回退密码
bash CredAlign.sh --revert

# 6. 验证回退
bash CredAlign.sh --dry-run
```
