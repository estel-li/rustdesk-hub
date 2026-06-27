# CE-M0-7 管理 CLI 改 UDS + token

## 1. 任务目标

将 `rustdesk-server` (hbbs 与 hbbr) 当前裸跑在 TCP loopback 上、零认证的"管理 CLI"通道,在 Unix 平台改为 Unix domain socket (UDS) + 启动期生成的 32 字节 token 双重防护;Windows 平台保留 TCP loopback,但必须显式 bind `127.0.0.1` 并叠加同样的 token 校验。验收信号:同主机普通用户(非 `rustdesk` 组、非 root)即使绕过端口监听,也无法读到 socket 或 token 文件,管理命令直接拒绝;`rustdesk` 用户或 root 用户使用 token 可以下达管理命令并得到回包。

> 原任务卡(docs/ai-development-plan.md:222-235)摘录:
> - loopback 管理 CLI 改为 Unix domain socket
> - socket 文件权限 `0660`
> - token 启动时打印到 stderr 或写入仅 root/rustdesk 可读文件
> - hbbs 与 hbbr 都要处理
> - macOS/Linux 行为可能不同,Windows 需要保留旧路径或明确不支持
> - 本机普通用户无法调用管理命令;`rustdesk` 用户或 root 可以调用

## 2. 上下文与依赖

- 上游依赖任务卡:
  - **CE-M0-5 systemd 加固**(docs/ai-development-plan.md:184):需要 `User=rustdesk Group=rustdesk` 与 `RuntimeDirectory=rustdesk-server` 提供 `/run/rustdesk-server/` 由 systemd 创建,并设定属主。本卡假定该 systemd unit 已落地;若未落地,本卡的实施步骤需要兼容兜底(socket 父目录由进程在启动期 `mkdir -p` + chown)。
- 下游会用到此输出的任务卡:
  - **CE-M0-6 PeerMap GC 与 tcp_punch key**(docs/ai-development-plan.md:202):后续会增加新的管理 CLI 子命令(例如 dump PeerMap 状态),将复用本卡建立的 UDS + token 通道。
  - M1/M2 各任务卡若新增运行期可调试参数,统一走本卡通道。
- 关键背景事实:
  - hbbs 当前管理 CLI 嵌在 NAT-test 端口(`port - 1`,默认 21115)上,以 `is_loopback()` 区分:rustdesk-server/src/rendezvous_server.rs:1102-1117 (`handle_listener2`),调度的解析逻辑在 rustdesk-server/src/rendezvous_server.rs:937-1100 (`check_cmd`)。
  - hbbr 当前管理 CLI 嵌在中继主端口(默认 21117)上,同样以 `is_loopback()` 区分:rustdesk-server/src/relay_server.rs:359-391 (`handle_connection`),解析在 rustdesk-server/src/relay_server.rs:152-324 (`check_cmd`)。
  - 两处都用裸 `[u8; 1024]` 缓冲一次性读取后回写 `String`,没有协议帧,本卡需保留这个"行/段式纯文本"语义以兼容运维人员手写的脚本(只是换底层 socket + 增加首行 token)。
  - hbbs 入口 rustdesk-server/src/main.rs:10-37 与 hbbr 入口 rustdesk-server/src/hbbr.rs:9-45,都使用 `clap` 风格的 args;新增 CLI 参数与 env 走 `init_args` / `get_arg_or`(rustdesk-server/src/common.rs:56-96)的统一约定(env var 名 = 参数名大写,'_'→'-')。
  - `listen_signal` 已分别在 hbbs (rustdesk-server/src/rendezvous_server.rs:224) 与 hbbr (rustdesk-server/src/relay_server.rs:91) 接入,新增的 UDS accept loop 必须并入 `tokio::select!`。
  - hbbs 的 io_loop 已有 `LoopFailure::Listener2` 等枚举(rustdesk-server/src/rendezvous_server.rs:93-98 与 209-222)处理 listener 重建,新的 UDS listener 也应有同样的可恢复路径或至少有可观测的失败日志。
  - 现有 `hbb_common` 已 re-export `tokio`(见 rustdesk-server/src/relay_server.rs:13-19),`tokio::net::UnixListener` / `UnixStream` 可直接用。
  - 文档 docs/rustdesk-server.md:145 与 :198 已明确把这一条列为"任何本机用户可改运行参数"的高危项;docs/upgrade-plan.md:195 (CE-M0-7) 与 :221 (架构图新增"UDS 管理 CLI")给出最终落地形态:`/run/rustdesk-server/{hbbs,hbbr}.sock`。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
| --- | --- | --- | --- |
| rustdesk-server/src/admin_cli.rs | 新建 | ~220 | 新增模块,封装 UDS / TCP loopback listener 创建、token 生成与持久化、`(stream, peer_cred) → cmd_string` 通用读取/回写、token 校验帧解析。hbbs 与 hbbr 共用。 |
| rustdesk-server/src/lib.rs | 修改 | ~3 | 注册 `pub mod admin_cli;` 让 hbbs(`hbbs::admin_cli`)与 hbbr (通过 `mod admin_cli` 或同样走 lib.rs)都能引用。 |
| rustdesk-server/src/hbbr.rs | 修改 | ~5 | 增加 `mod admin_cli;` 声明(因 hbbr.rs 是独立 bin,不能从 lib.rs 拿,需要 `#[path]` 或在 lib.rs `pub mod` 后由 bin re-use);并在 `main` 中读取新 CLI 参数 `--admin-socket`、`--admin-token-file`,传给 `relay_server::start`。 |
| rustdesk-server/src/main.rs | 修改 | ~5 | 同上,为 hbbs 增加新的 `-A, --admin-socket` 与 `--admin-token-file` 参数(建议命名,可调整);通过 env/args 透传给 `RendezvousServer::start`。 |
| rustdesk-server/src/rendezvous_server.rs | 修改 | ~80 | (1) 删除 `handle_listener2` 中 `ip.is_loopback()` 分支(:1105-1117),只保留 NAT-test / OnlineRequest 路径;(2) 在 `RendezvousServer::start`(:150 附近 listener 创建之后)新增 `admin_cli::spawn_listener("hbbs", check_cmd_clone)`;(3) 把 `check_cmd`(:937-1100)从 `&self` 方法拆出 / 或克隆 `RendezvousServer` 进入 admin loop;(4) `LoopFailure` / `io_loop` 不再监听 listener2 的 loopback 分支(保留 listener2 本身用于 NAT-test)。 |
| rustdesk-server/src/relay_server.rs | 修改 | ~60 | (1) 删除 `handle_connection` 中 `!ws && ip.is_loopback()` 分支(:367-380),让中继端口只走中继协议;(2) 在 `start`(:85 main_task 之前)`spawn` 一个 `admin_cli::spawn_listener("hbbr", check_cmd_clone)`;(3) `check_cmd`(:152-324)签名维持原样,但提取为 `pub(crate) async fn`,接 admin_cli 调用。 |
| rustdesk-server/src/common.rs | 修改 | ~30 | 增加 helper `admin_runtime_dir()` 与 `admin_token_dir()`,封装 Linux/macOS/Windows 默认路径选择(在 §4 配置项给出)。 |
| rustdesk-server/Cargo.toml | 修改 | ~3 | 增加 `rand = "0.8"`(token 生成)与启用 `tokio` 的 `net` feature(若 `hbb_common` 透传 `tokio` 未启用 UnixListener,改在本 crate 直接 `tokio = { version = "1", features = ["net", "io-util", "macros"] }`)。最终以编译期验证为准。 |
| rustdesk-server/systemd/rustdesk-hbbs.service | 修改 | ~3 | 增加 `RuntimeDirectory=rustdesk-server` 与 `RuntimeDirectoryMode=0750`;`StateDirectory=rustdesk-server`(供 admin.token 落盘)。CE-M0-5 可能已加,本卡需幂等。 |
| rustdesk-server/systemd/rustdesk-hbbr.service | 修改 | ~3 | 同上。 |
| rustdesk-server/tests/admin_cli_test.rs | 新建 | ~150 | 集成测试:启动一个 mock listener,验证 token 接收、错误 token 拒绝、socket 权限、Windows 旁路。 |
| docs/rustdesk-server.md | 修改 | ~10 | 把 :145 与 :198 的"无认证"风险项标记为"已修复(CE-M0-7)";:285 / :287 端口表补充"管理 CLI 已迁移到 UDS"。 |
| docs/ai-development-plan.md | 修改 | ~1 | 任务卡末尾追加 "状态: 完成 (commit <hash>)"(见 §10)。 |

> 注:`rustdesk-server/src/lib.rs` 内容只有 6 行(参见 `wc -l`),为避免 hbbr.rs 这种独立 bin 需要重复声明 `mod admin_cli`,建议把 `admin_cli` 作为 `pub mod admin_cli;` 放进 lib.rs,然后 hbbr.rs(目前用 `mod common; mod relay_server;` 局部声明)改为 `use hbbs::admin_cli;`。

## 4. 数据契约

### 4.1 配置项 / CLI 参数 / env 变量

| CLI 参数 (建议命名,可调整) | env (init_args 大写形态) | 适用 bin | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `--admin-socket=<PATH>` | `ADMIN-SOCKET` | hbbs, hbbr | Linux: `/run/rustdesk-server/{hbbs\|hbbr}.sock`<br>macOS dev: `/tmp/rustdesk-{hbbs\|hbbr}.sock`<br>Windows: 空(不创建 UDS,改用 `--admin-tcp`) | UDS 监听路径;空字符串 = 禁用。 |
| `--admin-tcp=<ADDR>` | `ADMIN-TCP` | hbbs, hbbr | Linux/macOS: 空;Windows: `127.0.0.1:0`(随机端口,实际端口写到 token 文件首行)| Windows 兜底/调试用 TCP loopback 监听。**必须** 绑定 `127.0.0.1` 或 `::1`,绑定到其他地址需 hard fail。 |
| `--admin-token-file=<PATH>` | `ADMIN-TOKEN-FILE` | hbbs, hbbr | Linux: `/var/lib/rustdesk-server/admin.token`<br>macOS dev: `/tmp/rustdesk-admin.token`<br>Windows: `%PROGRAMDATA%\rustdesk-server\admin.token` | Token 持久化路径,mode 0640,owner 与运行用户同。 |
| `--admin-disable` | `ADMIN-DISABLE`=`Y` | hbbs, hbbr | 未设置 | 显式禁用管理 CLI(用于精简部署 / 测试)。 |

`common::admin_runtime_dir()` 返回逻辑(Rust 伪代码,实际放在 rustdesk-server/src/common.rs):

```text
if let Some(d) = env::var("RUNTIME_DIRECTORY") { return d; }  // systemd 注入
cfg!(target_os = "linux")  => "/run/rustdesk-server"
cfg!(target_os = "macos")  => "/tmp"
cfg!(target_os = "windows")=> %PROGRAMDATA%/rustdesk-server
```

### 4.2 Token 与文件权限

- Token: 32 字节随机,使用 `rand::thread_rng().fill_bytes(&mut buf)`,以 base64 (URL safe, no pad) 编码,长度 43 字符。
- 启动期行为:
  1. 生成 token,**同时** 写 stderr(以 `log::warn!("admin token: {}", token)` 或直接 `eprintln!`,确保被 systemd 捕获到 `hbbs.error`);
  2. 写 `--admin-token-file`,先 `open(O_WRONLY|O_CREAT|O_TRUNC, 0o640)`,然后 `fchmod(0o640)`,然后 `fchown(uid=getuid(), gid=getgid())`(systemd 已切换到 rustdesk 用户,继承即可)。如果文件已存在且 mode 大于 `0o640`,先 `unlink` 再创建,确保权限始终收紧。
  3. UDS 文件:`bind` 之前 `unlink` 旧 socket;`bind` 后立刻 `fchmod(0o660)`(`std::os::unix::fs::PermissionsExt`)。**注意**:`UnixListener::bind` 使用进程 umask,显式 chmod 不能省。
  4. 父目录 `/run/rustdesk-server`:由 systemd `RuntimeDirectory=` 创建为 `0750 rustdesk:rustdesk`;进程兜底:若目录不存在则 `mkdir(0o750)`,owner 不强制(交给 systemd / 包管理)。

### 4.3 Wire 协议(纯文本,与旧 CLI 保持兼容)

客户端 → 服务端:UTF-8,首段为 token,空格或换行分隔,之后是原命令。例如:

```
<token> rs 1.2.3.4:21117\n
```

服务端处理流程:
1. 一次性 `read` 最多 1024 字节(对齐 rustdesk-server/src/rendezvous_server.rs:1108 与 rustdesk-server/src/relay_server.rs:371 现有行为)。
2. 在第一个空白符(`b' '` 或 `b'\n'`)切分;前段做 **常量时间比较** (`subtle::ConstantTimeEq` 或手写按位 XOR,**不要** 用 `==`)。
3. 校验失败:写 `ERR unauthorized\n` 并关闭。**不要** 在错误回包中暴露 token 长度信息。
4. 校验成功:把剩余字节作为旧 `cmd` 传给原有 `check_cmd` / `RendezvousServer::check_cmd`,回包不变。
5. UDS 路径 **额外** 验证 `SO_PEERCRED`(Linux)或 `LOCAL_PEERCRED`(macOS,可选,失败仅 warn):仅允许 `uid==0` 或 `uid==getuid()`(即与服务进程相同 uid)。

### 4.4 admin.token 文件格式

```
<base64-token>\n
# 可选第二行,仅 Windows / --admin-tcp 时存在:
tcp=127.0.0.1:<port>\n
```

CLI 工具读取规则:第一行非 `#`、非空的行为 token;`key=value` 形式的行为元数据。保持向后兼容。

### 4.5 错误码 / 回包文本

| 触发 | 回包(纯文本,末尾带 `\n`) |
| --- | --- |
| token 缺失或格式错 | `ERR unauthorized\n` |
| token 不匹配 | `ERR unauthorized\n` |
| 命令长度超 1024 | `ERR too-large\n` |
| 旧客户端无 token 直连 UDS | `ERR unauthorized\n` |
| 校验通过,空命令 | 原 `check_cmd("")` 输出(空字符串) |

## 5. 实现步骤

1. **新增 `rustdesk-server/src/admin_cli.rs` 骨架**:定义 `pub async fn spawn_listener(name: &'static str, cmd_handler: Arc<dyn AdminCmd + Send + Sync>)`,以及 `pub trait AdminCmd { async fn run(&self, cmd: &str) -> String; }`。在 lib.rs 注册 `pub mod admin_cli;`。
2. **新增 token 生成 / 持久化**(admin_cli.rs):`fn generate_token() -> String`,`fn write_token_file(path: &Path, token: &str) -> io::Result<()>`,后者负责 `mkdir -p` 父目录(0o750)、`open(O_WRONLY|O_CREAT|O_TRUNC, 0o640)`、`set_permissions(0o640)`、写入 + 落盘 + `eprintln!("[admin] token written to {}", path.display())`。
3. **新增 UDS bind 逻辑**(admin_cli.rs):`async fn bind_uds(path: &Path) -> Result<UnixListener>`,先 `let _ = fs::remove_file(path)`,然后 `UnixListener::bind(path)`,再 `fs::set_permissions(path, Permissions::from_mode(0o660))`。`#[cfg(target_os = "linux")]` 用 `SO_PEERCRED` 校验。
4. **新增 TCP fallback bind**(admin_cli.rs,Windows 与 `--admin-tcp` 显式开启时):严格校验 addr 必须 `is_loopback()`,否则 panic with `unreachable: admin TCP must bind loopback`。
5. **统一 accept loop**(admin_cli.rs):`tokio::select!` UDS + 可选 TCP,每个连接 `tokio::spawn` 处理,内部:`timeout(1000, read)` 读取 1024 字节、拆 token、`ConstantTimeEq` 比较、调用 `cmd_handler.run(&cmd).await`、写回、`shutdown()`。失败路径只 `log::warn`,绝不 panic。
6. **改造 hbbs**(rustdesk-server/src/rendezvous_server.rs):
   - 在 :100-150 的 `RendezvousServer::start` 内,listener 创建之后、`main_task` 创建之前,读取 `get_arg_or("admin-socket", default_hbbs_sock())`,如果非空且未 `--admin-disable`,`tokio::spawn(admin_cli::spawn_listener("hbbs", Arc::new(self.clone())))`。
   - 把 `check_cmd`(:937-1100)从 `impl RendezvousServer` 上提为 `pub(crate) async fn`,或者为 `RendezvousServer` 实现 `admin_cli::AdminCmd`,`async fn run(&self, cmd: &str) -> String { self.check_cmd(cmd).await }`。
   - 删除 `handle_listener2`(:1102-1117)中 `ip.is_loopback()` 分支,**保留** 非 loopback 的 NAT-test 协议路径。`handle_listener2` 内的 1024 byte read 整段移除。
7. **改造 hbbr**(rustdesk-server/src/relay_server.rs):
   - 在 `start`(:85)`main_task` 之前 spawn admin listener,handler 内 clone 当前 limiter(注意 `check_cmd` 当前签名带 `limiter: Limiter`,需要把 limiter 通过 `Arc` 或 `Lazy<RwLock<...>>` 共享给 admin handler,或将 limiter 抽为全局 `static` —— 建议命名 `static LIMITER: OnceLock<Limiter>`,可调整)。
   - 删除 `handle_connection`(:359-391)中 `!ws && ip.is_loopback()` 分支(:367-380)。
8. **CLI / env 接线**:rustdesk-server/src/main.rs:16-26 与 rustdesk-server/src/hbbr.rs:15-19 的 `args` 字符串里追加四个新参数;rustdesk-server/src/common.rs 新增 `pub fn admin_default_socket(role: &str) -> PathBuf` 等 helper。
9. **systemd**:rustdesk-server/systemd/rustdesk-hbbs.service 与 rustdesk-hbbr.service 增加 `RuntimeDirectory=rustdesk-server`、`RuntimeDirectoryMode=0750`、`StateDirectory=rustdesk-server`、`StateDirectoryMode=0750`、`User=rustdesk`、`Group=rustdesk`(CE-M0-5 已加部分,这里幂等检查)。
10. **集成测试**:新增 rustdesk-server/tests/admin_cli_test.rs,启动一个 mock `AdminCmd` 实现并 spawn listener,使用 `tokio::net::UnixStream` 测试正常 / 错误 / 超限。详见 §6。
11. **文档**:更新 docs/rustdesk-server.md 风险条目,标记 :145 / :198 / :485 已修复,并补一段 §运维 章节说明 token 文件位置与轮换方法(SIGHUP 暂不支持;轮换 = 重启服务)。

## 6. 测试用例

| # | 测试文件路径 | 测试名 | 输入 | 期望 |
| --- | --- | --- | --- | --- |
| 1 | rustdesk-server/tests/admin_cli_test.rs | `uds_auth_happy_path` | 临时目录建 socket,启动 listener,写 `"<token> h\n"` | 收到包含 `relay-servers` 字样的 help 文本;socket mode == `0o660`。 |
| 2 | rustdesk-server/tests/admin_cli_test.rs | `uds_reject_missing_token` | 写 `"h\n"`(无 token) | 收到 `"ERR unauthorized\n"`,handler 不被调用。 |
| 3 | rustdesk-server/tests/admin_cli_test.rs | `uds_reject_wrong_token` | 写 `"deadbeef h\n"` | 收到 `"ERR unauthorized\n"`,且 wall-clock 差异 < 5ms(常量时间比较的弱断言)。 |
| 4 | rustdesk-server/tests/admin_cli_test.rs | `uds_reject_oversized` | 写 2048 字节随机数据 | 连接被关闭或返回 `ERR too-large`;handler 不被调用。 |
| 5 | rustdesk-server/tests/admin_cli_test.rs | `token_file_perms` | 用临时 token 路径启动 listener | `stat(token_path).mode & 0o777 == 0o640`;`stat(parent).mode & 0o777 == 0o750`。 |
| 6 | rustdesk-server/tests/admin_cli_test.rs | `backcompat_legacy_loopback_tcp_rejected_on_unix` | 连旧的 hbbs nat-test 端口 (`port-1`) 发 `"rs\n"` | **不再** 收到 admin 回包(空响应或 NAT 协议解析失败),证明旧通道关闭。 |
| 7 | rustdesk-server/tests/admin_cli_test.rs (cfg windows) | `windows_tcp_loopback_only` | bind `0.0.0.0` 应直接 panic;bind `127.0.0.1` 成功 | bind 非 loopback 返回 Err / panic。 |
| 8 | rustdesk-server/tests/admin_cli_test.rs | `disabled_flag_no_socket` | 设 `--admin-disable` | 不创建 socket 文件,不写 token,日志含 `admin cli disabled`。 |
| 9 (手动) | 命令行 | `peer_cred_nonroot_rejected` | 在 Linux,非 rustdesk 用户 `nc -U /run/rustdesk-server/hbbs.sock` | EACCES(权限 0660 拒绝)或在能读的场景下被 `SO_PEERCRED` 拒绝。 |

测试 1-8 自动化(`cargo test -p hbbs --test admin_cli_test`);测试 9 在 CI 跳过,记入 §7 验证命令的"Linux only 手动复核"段。

## 7. 验证命令

按顺序执行:

```bash
# 1. 编译(macOS 与 Linux 均可)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-server
cargo build --bins

# 2. 单元 + 集成测试
cargo test --tests

# 3. 静态检查
cargo clippy --bins --tests -- -D warnings
cargo fmt --check

# 4. 本地起 hbbs,验证 UDS + token(macOS dev path)
ADMIN-SOCKET=/tmp/rustdesk-hbbs.sock \
ADMIN-TOKEN-FILE=/tmp/rustdesk-admin.token \
RUST_LOG=info \
./target/debug/hbbs -p 21116 &
sleep 1
stat -f '%Sp %Su:%Sg' /tmp/rustdesk-hbbs.sock   # 期望 srw-rw---- $USER:staff
stat -f '%Sp %Su:%Sg' /tmp/rustdesk-admin.token # 期望 -rw-r----- $USER:staff
TOKEN=$(head -n1 /tmp/rustdesk-admin.token)
printf '%s h\n' "$TOKEN" | nc -U /tmp/rustdesk-hbbs.sock
# 期望:输出 relay-servers / reload-geo / ... 帮助文本

# 5. 负面用例
printf 'h\n' | nc -U /tmp/rustdesk-hbbs.sock
# 期望:输出 ERR unauthorized

# 6. 同样验证 hbbr
ADMIN-SOCKET=/tmp/rustdesk-hbbr.sock \
ADMIN-TOKEN-FILE=/tmp/rustdesk-admin.token \
./target/debug/hbbr -p 21117 &
sleep 1
printf '%s h\n' "$TOKEN" | nc -U /tmp/rustdesk-hbbr.sock
# 期望:输出 blacklist-add / blocklist-add / ... 帮助文本

# 7. 旧通道关闭确认(macOS 下 hbbs 的 NAT-test 端口已不再吐管理回包)
printf 'rs\n' | nc -w1 127.0.0.1 21115 | head -c 64
# 期望:空 / 协议错,不再是 relay 列表

# 8. (Linux only,macOS dev box 跳过) 通过 systemd 启动并验证目录归属
# 跳过原因:macOS 没有 systemd,且 /run/rustdesk-server 在 macOS 不可写。
sudo systemctl restart rustdesk-hbbs rustdesk-hbbr
sudo -u nobody cat /var/lib/rustdesk-server/admin.token  # 期望 EACCES
sudo -u rustdesk cat /var/lib/rustdesk-server/admin.token # 期望读到 token
```

可在 macOS dev box 跳过的命令:**第 8 步**(systemd 与 `/run/rustdesk-server` 仅 Linux 生效)。其余命令均可在 macOS 上跑通(macOS dev 路径使用 `/tmp/...`)。

## 8. 兼容性 / 安全注意事项

- **Protobuf 兼容**:本卡不修改任何 protobuf,无影响。
- **老客户端 / 老服务端互通**:管理 CLI 不在客户端协议中,纯运维通道,改动不影响 RustDesk 客户端 ↔ 服务端的鉴权与连接。**但是**:任何外部运维脚本(`echo rs | nc 127.0.0.1 21115`)将失效;在 docs/rustdesk-server.md 中需附迁移说明:`socat - UNIX-CONNECT:/run/rustdesk-server/hbbs.sock` 加 token 前缀。
- **数据库迁移回滚**:本卡不涉及数据库,无迁移。
- **敏感字段不落盘**:token 落盘是必要的,但 mode 0640 + 父目录 0750 + 进程同 uid;**禁止** token 出现在 stdout(systemd `StandardOutput=append:hbbs.log`,日志可能被多人读)。本卡使用 stderr(`hbbs.error`)+ token 文件双通道,且 token 文件优先级高,stderr 仅作为人工排障时第一次启动的 fallback。
- **常量时间比较**:token 比较必须用 `subtle::ConstantTimeEq` 或等价实现,避免计时侧信道。
- **限流**:admin handler 每个连接读取上限 1024 字节(与现实现一致),accept 不显式限流,但需要在 `tokio::spawn` 内部 `timeout(1000ms, read)`,防止半开连接堆积。
- **`SO_PEERCRED`**:Linux 上对 UDS 连接做 peer credential 校验,仅 uid == 0 或 uid == 服务进程 uid 通过;macOS dev 路径下若 `LOCAL_PEERCRED` syscall 失败,降级为只校验 token + 文件权限。
- **Windows 通道**:必须显式只 bind `127.0.0.1` / `::1`;若用户传 `0.0.0.0` 视为配置错误,启动期 hard fail。建议日志一条:`Windows 仍走旧 loopback TCP,但绑定 127.0.0.1 并增加 token 校验`(中文 log,匹配 CLAUDE.md 偏好)。
- **`Display` / log 误打 token**:`Token` 类型建议 newtype 包装,实现 `Debug`/`Display` 输出 `***`,只暴露 `expose()` 方法;仅在写文件 / 启动 stderr 一次性场景调用 `expose()`。
- **socket 文件残留**:进程异常崩溃可能残留 stale socket,启动期 `unlink` 是必要的;但要先确认无其他实例占用(尝试 `connect` 一次,若连得通则 hard fail "another instance running")。

## 9. 回滚方案

1. **代码层**:本卡所有改动都在 `admin_cli` 模块和 `start` 路径,可通过环境变量 `ADMIN-DISABLE=Y` 完全关闭新通道。但 **旧 loopback TCP 通道已删除**,关闭新通道后整个管理 CLI 不可用 —— 对运维不可接受,所以回滚必须走代码回滚。
2. **Git 回滚**:`git revert <merge-commit>` 即可,无数据库迁移、无配置文件破坏性变化。`/run/rustdesk-server/*.sock` 与 `/var/lib/rustdesk-server/admin.token` 是新生成文件,revert 后下次启动不再写入,旧文件可手动 `rm`。
3. **Feature flag 兜底(可选,不推荐)**:若想保留双通道一段时间,可加 cfg feature `admin_legacy_tcp`(默认关闭),开启时同时保留旧 loopback 分支。**不建议** 默认带这个 feature,因为旧通道零认证就是本卡要消除的风险。
4. **systemd 回滚**:`RuntimeDirectory=` 与 `StateDirectory=` 是新增项,移除即可;`User=`/`Group=` 若 CE-M0-5 已落地,不属于本卡回滚范围。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-server/src/admin_cli.rs` 落地,包含 token 生成、UDS bind + chmod、可选 TCP loopback bind、token 校验、`AdminCmd` trait。
- [ ] hbbs(`rendezvous_server.rs`)与 hbbr(`relay_server.rs`)的 `is_loopback()` 旧分支被删除,管理路径走 `admin_cli::spawn_listener`。
- [ ] hbbs / hbbr 启动期均生成 token,写入 `--admin-token-file`(mode 0640)与 stderr 各一次。
- [ ] UDS 文件 mode 为 `0o660`,父目录 mode 为 `0o750`,owner 与服务进程一致(Linux 通过 systemd,macOS dev 通过当前 uid)。
- [ ] Linux 实现 `SO_PEERCRED` 校验;macOS 至少完成 token 校验,且 peer-cred 失败降级有日志。
- [ ] Windows 实现保留 TCP loopback + token 校验,且 bind 非 loopback 时启动失败,日志中文化 `Windows 仍走旧 loopback TCP,但绑定 127.0.0.1 并增加 token 校验`。
- [ ] 新增的 8 个自动化测试在 `cargo test --tests` 全绿;手动 §7 第 4-7 步在 macOS dev box 复核通过。
- [ ] `cargo clippy -- -D warnings` 与 `cargo fmt --check` 通过。
- [ ] docs/rustdesk-server.md 中 :145 / :198 / :485 的高危标记被更新为"已修复 (CE-M0-7)";端口表注明管理 CLI 不再监听 TCP(Unix 平台)。
- [ ] systemd unit 文件包含 `RuntimeDirectory` / `StateDirectory` / `User=rustdesk` / `Group=rustdesk`(与 CE-M0-5 协调,幂等)。
- [ ] 在 docs/ai-development-plan.md 的对应任务卡末尾追加 "状态: 完成 (commit <hash>)"。
