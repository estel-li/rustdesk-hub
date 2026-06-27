# CE-M0-3 hbbs/hbbr Prometheus metrics 独立端口

## 1. 任务目标

为 `hbbs` 与 `hbbr` 两个守护进程新增独立的 Prometheus `/metrics` HTTP 端点,通过新增 CLI 参数 `--metrics-bind` 绑定 loopback 地址,与现有 21114(rustdesk-api)、21115/21116(hbbs NAT/主端口)、21117(hbbr TCP)、21118/21119(hbbs/hbbr WebSocket,见 `rustdesk-server/src/utils.rs:116-117`)等已用端口完全隔离。任务卡原文(`docs/ai-development-plan.md:146-162`)要求覆盖在线 peer 数、PeerMap 条目数、注册/打洞/relay 计数、API access check 延迟,以及 hbbr 的 session 数、bytes in/out、配对超时数、限速命中数。

验收信号:`curl http://127.0.0.1:<hbbs_metrics_port>/metrics` 与 `curl http://127.0.0.1:<hbbr_metrics_port>/metrics` 都返回非空且格式合法的 Prometheus 文本(`# HELP` / `# TYPE` 行齐全),且未占用 21114。

## 2. 上下文与依赖

- 上游依赖任务卡
  - CE-M0-1 hbb_common fork 对齐(`docs/ai-development-plan.md:101-121`):先确认两个 Rust 仓库可正常 build,再加 metrics,避免与 submodule 漂移混在一次 PR。
  - 总原则 §1.3 安全边界(`docs/ai-development-plan.md:54`):"metrics 不占用 21114,使用显式 `--metrics-bind` 独立 loopback 端口"。
- 下游会用到此输出的任务卡
  - CE-M0-6 PeerMap GC 与 tcp_punch key:GC 之后的 PeerMap size 需要被 `hbbs_peermap_entries` 暴露。
  - CE-M1-3 / CE-M1-5(MFA、强制 MFA):需要 `hbbs_api_access_check_seconds` 直方图衡量 RBAC/MFA 链路延迟。
  - CE-M0-4 rustdesk-api metrics healthcheck:三方 metrics 同源后才能在 docs/operations 中统一聚合。
- 关键背景事实
  - `hbbs` 入口位于 `rustdesk-server/src/main.rs:10-37`,CLI 解析使用 `init_args(&args, "hbbs", ...)`,新增 flag 必须追加到 `args` 字符串(`main.rs:16-26`)。
  - `hbbr` 入口位于 `rustdesk-server/src/hbbr.rs:1-45`,使用 `clap::App::args_from_usage` 解析(`hbbr.rs:20-25`),与 hbbs 是独立的 binary。
  - 已被占用的 TCP 端口:21114 API、21115 nat test、21116 hbbs 主、21117 hbbr TCP、21118 hbbs WebSocket、21119 hbbr WebSocket,源自 `rustdesk-server/src/utils.rs:112-117`。
  - hbbs 中现有的全局计数候选:`ROTATION_RELAY_SERVER`(`rendezvous_server.rs:59`)、`ALWAYS_USE_RELAY`(`rendezvous_server.rs:62`)、`PUNCH_REQS`(`rendezvous_server.rs:69`)、`IP_BLOCKER` / `IP_CHANGES`(`peer.rs:17-19`)。
  - PeerMap 暴露的入口:`PeerMap::get_in_memory`(`peer.rs:172`)、`PeerMap::is_in_memory`(`peer.rs:177`);需要新增一个 `len_in_memory()` 方法供 gauge 采集。
  - hbbr 中现有的全局状态:`PEERS` / `USAGE` / `BLACKLIST` / `BLOCKLIST`(`relay_server.rs:33-38`),计速逻辑在 `relay_server.rs:486-563`,可在此插桩 bytes/限速/超时计数。
  - hbbr 入站逻辑 `relay_server.rs:425-462` 内 `sleep(30.).await` 之后 `PEERS.lock().await.remove(&rf.uuid);` 即为"配对超时",在该分支递增 `hbbr_pair_timeout_total`。
  - `Cargo.toml:32` 已有 `axum = "0.5"`,可用于 hbbs metrics 路由;但 hbbr 不依赖 axum,适合用自带 HTTP server 的 `metrics-exporter-prometheus`。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|------|------|----------|------|
| `rustdesk-server/Cargo.toml` | 修改 | +3 | 新增 `metrics = "0.21"`、`metrics-exporter-prometheus = { version = "0.12", default-features = false, features = ["http-listener"] }`(版本号建议,可调) |
| `rustdesk-server/src/metrics.rs` | 新建 | ~180 | 新模块:定义全部 metric key、`install_recorder(bind: SocketAddr, role: &str)`、`record_*` 便捷函数 |
| `rustdesk-server/src/lib.rs` | 修改 | +1 | 增加 `pub mod metrics;` |
| `rustdesk-server/src/main.rs` | 修改 | ~+15 | CLI 增加 `--metrics-bind`,启动时调用 `metrics::install_recorder` |
| `rustdesk-server/src/hbbr.rs` | 修改 | ~+20 | 同上,并 `mod metrics;` 引入(因为 hbbr 是独立 binary,不走 lib) |
| `rustdesk-server/src/rendezvous_server.rs` | 修改 | ~+25 | 在 `handle_udp` / `handle_punch_hole_request` / `get_relay_server` 等位置插桩 counter / histogram;周期任务里采样 PeerMap gauge |
| `rustdesk-server/src/relay_server.rs` | 修改 | ~+30 | 在 `make_pair_` / `relay` 中插桩 session gauge、bytes counter、限速 counter、超时 counter |
| `rustdesk-server/src/peer.rs` | 修改 | ~+10 | 新增 `pub(crate) async fn len_in_memory(&self) -> usize`,供 gauge 周期采样 |
| `rustdesk-server/src/utils.rs` | 修改 | +2 | `doctor` 增加可选输出 `metrics endpoint` 提示(可选,纯诊断) |
| `rustdesk-server/tests/metrics_smoke.rs` | 新建 | ~80 | 集成测试:启动 recorder 到随机端口,断言抓到 `# TYPE` 与关键 metric 名 |
| `docs/operations/metrics.md` | 新建 | ~120 | 运维文档:flag 用法、默认端口建议、Prometheus scrape 示例、回滚 |
| `docs/ai-development-plan.md` | 修改 | +1 | 任务卡末尾追加状态行(见 §10) |

未找到/不存在的预期文件:无。

## 4. 数据契约

### 4.1 CLI / 配置项

- 新增 flag(hbbs 与 hbbr 都加):
  - 长名 `--metrics-bind`
  - 短名:不分配(避免与现有 `-M`/`-k` 冲突)
  - 取值格式:`<ip>:<port>`,例如 `127.0.0.1:21120`
  - 默认值:空字符串 = **不启用 metrics**(零侵入,保持当前行为)
  - 帮助文本(hbbs,追加到 `main.rs:16-26` 的 args 串):
    ```
    , --metrics-bind=[ADDR] 'Bind Prometheus metrics endpoint, e.g. 127.0.0.1:21120 (disabled if empty)'
    ```
  - 帮助文本(hbbr,追加到 `hbbr.rs:15-19`):
    ```
    , --metrics-bind=[ADDR] 'Bind Prometheus metrics endpoint, e.g. 127.0.0.1:21121 (disabled if empty)'
    ```
- 环境变量回退(与现有 `.env` 加载逻辑兼容,`hbbr.rs:26-30`):`METRICS_BIND`,仅在 flag 未提供时生效。
- 建议默认值(**建议命名,可调整**):
  - hbbs:`127.0.0.1:21120`
  - hbbr:`127.0.0.1:21121`
  - 注意:任务卡指引文字提到 `21118/21119`,但这两个端口已被 hbbs/hbbr WebSocket 监听占用(`utils.rs:116-117`),不能复用。故下移到 `21120/21121`,与 21114(API)/21117(hbbr TCP)间留出至少 1 端口的安全距离。

### 4.2 metrics 库选型(必须明确)

**选择 `metrics` + `metrics-exporter-prometheus`(`PrometheusBuilder`)。** 理由:

1. `metrics-exporter-prometheus` 自带 hyper-based HTTP listener(`with_http_listener(addr)`),hbbr 没有 axum 依赖,直接复用避免拉新 server。
2. `metrics` facade 的 `counter!` / `gauge!` / `histogram!` 宏可在 hot path 里以静态 key 调用,几乎无锁开销。
3. `prometheus` crate 需要手动管理 Encoder 与 HTTP 服务、且全局 registry 是 `lazy_static`,对 hbbs 多模块插桩不友好。
4. `metrics` + 导出器组合在 RustDesk 同生态项目里有先例,版本演进活跃。

### 4.3 metric 字典(label 名采用 snake_case,值小写)

#### hbbs

| 名称 | 类型 | labels | 含义 / 插桩位置 |
|------|------|--------|----------------|
| `hbbs_peers_online` | gauge | (无) | 当前 `last_reg_time` 在 `REG_TIMEOUT` 内的 peer 数;后台 5s 周期任务采样 |
| `hbbs_peermap_entries` | gauge | (无) | PeerMap 内存条目数;来源新方法 `PeerMap::len_in_memory()`(§3 新增) |
| `hbbs_register_total` | counter | `kind` ∈ `peer` \| `pk` | `RegisterPeer` 与 `RegisterPk` 分别在 `rendezvous_server.rs:326`、`:342` 处自增 |
| `hbbs_register_reject_total` | counter | `reason` ∈ `too_frequent` \| `uuid_mismatch` \| `not_support` | `send_rk_res` 调用点(`rendezvous_server.rs:349,351,370,380,556`) |
| `hbbs_punch_hole_total` | counter | `transport` ∈ `udp` \| `tcp` \| `ws` | 在 `handle_udp_punch_hole_request` 与 `handle_tcp_punch_hole_request` 入口(`rendezvous_server.rs:874,857`) |
| `hbbs_punch_hole_result_total` | counter | `result` ∈ `ok` \| `offline` \| `id_not_exist` \| `license_mismatch` \| `same_intranet` \| `force_relay` | `handle_punch_hole_request` 各分支(`rendezvous_server.rs:691-789`) |
| `hbbs_relay_assign_total` | counter | (无) | `get_relay_server` 命中非空分支(`rendezvous_server.rs:927-935`) |
| `hbbs_api_access_check_seconds` | histogram | `decision` ∈ `allow` \| `deny` \| `error` | 预留 metric,CE-M2 RBAC 上线后才会出现观测值;先注册以稳定 schema。Bucket 建议 `[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5]` |
| `hbbs_ws_connections_active` | gauge | (无) | `listener3.accept` 增,WS handler 退出减(`rendezvous_server.rs:288-298, 1142-1201`) |
| `hbbs_ip_blocked_total` | counter | (无) | `check_ip_blocker` 返回 false 时(`rendezvous_server.rs:899`) |
| `hbbs_build_info` | gauge | `version`, `role="hbbs"` | 启动时 set=1,值始终 1,用于看板分组 |

#### hbbr

| 名称 | 类型 | labels | 含义 / 插桩位置 |
|------|------|--------|----------------|
| `hbbr_sessions_active` | gauge | (无) | `make_pair_` 中配对成功进入 `relay()` 自增,relay 退出自减(`relay_server.rs:445-451`) |
| `hbbr_pair_pending` | gauge | (无) | `PEERS.lock().await.insert(...)`(`relay_server.rs:454`)自增,任意 remove 自减 |
| `hbbr_pair_timeout_total` | counter | (无) | `sleep(30.).await; PEERS.lock().await.remove(...)` 分支(`relay_server.rs:455-457`)在 remove 命中时自增 |
| `hbbr_bytes_total` | counter | `dir` ∈ `in` \| `out` | `relay()` 每个 select 分支累计 `bytes.len()`(`relay_server.rs:488-525`) |
| `hbbr_limiter_consume_total` | counter | `class` ∈ `normal` \| `downgrade_blacked` \| `total` | 三个 `consume(nb)` 调用点(`relay_server.rs:493-497, 511-516`) |
| `hbbr_downgrade_total` | counter | (无) | `downgrade = true` 命中(`relay_server.rs:555`) |
| `hbbr_blocked_total` | counter | `kind` ∈ `block_pre_pair` \| `block_mid_relay` | `handle_connection` BLOCKLIST 命中(`relay_server.rs:382-385`)与 `relay()` 内中途黑名单(`relay_server.rs:535-538`) |
| `hbbr_relay_close_total` | counter | `reason` ∈ `peer_eof` \| `client_eof` \| `timeout` \| `send_err` | `relay()` 出口分支(`relay_server.rs:503-505, 522-524, 527-530`) |
| `hbbr_build_info` | gauge | `version`, `role="hbbr"` | 同 hbbs |

### 4.4 `metrics::install_recorder` API(新模块对外形态)

```rust
// rustdesk-server/src/metrics.rs

use std::net::SocketAddr;
use hbb_common::ResultType;

pub fn install_recorder(bind: SocketAddr, role: &'static str) -> ResultType<()>;
// role 取 "hbbs" 或 "hbbr",用于 build_info label 与日志前缀。

// 便捷调用(语义糖,内部全部走 metrics::counter!/gauge!/histogram!):
pub fn inc_register(kind: &'static str);
pub fn inc_punch_hole(transport: &'static str);
pub fn inc_punch_hole_result(result: &'static str);
pub fn inc_relay_assign();
pub fn set_peers_online(v: i64);
pub fn set_peermap_entries(v: i64);
pub fn observe_access_check(decision: &'static str, seconds: f64);

// hbbr:
pub fn inc_session_active(delta: i64);
pub fn inc_pair_timeout();
pub fn add_bytes(dir: &'static str, n: u64);
pub fn inc_relay_close(reason: &'static str);
pub fn inc_blocked(kind: &'static str);
pub fn inc_downgrade();
```

实现细节:`install_recorder` 内部使用 `PrometheusBuilder::new().with_http_listener(bind).install()`,失败返回 `bail!`。`build_info` 在 install 之后立即 `gauge!("hbbs_build_info", 1.0, "version" => env!("CARGO_PKG_VERSION"), "role" => role)`。

## 5. 实现步骤

1. **依赖与模块骨架(0.5 day)**
   - 编辑 `rustdesk-server/Cargo.toml:19-54` 的 `[dependencies]`,追加 `metrics`、`metrics-exporter-prometheus`(版本见 §4.2)。
   - 新建 `rustdesk-server/src/metrics.rs`,实现 `install_recorder` 与 §4.4 列出的便捷函数空壳(全部走 `metrics::*` 宏)。
   - 在 `rustdesk-server/src/lib.rs:1-6` 增加 `pub mod metrics;`。
   - 因 hbbr binary 不经过 `lib.rs`(`Cargo.toml:9-11` 指明 `path = "src/hbbr.rs"`,内部用 `mod common;` 等),在 `hbbr.rs` 顶部新增 `mod metrics;`。
   - 跑 `cargo check` 确保依赖与模块导入通过。

2. **hbbs CLI 接入(0.25 day)**
   - 在 `rustdesk-server/src/main.rs:16-26` 的 `args` 字符串末尾追加 `--metrics-bind` 行(见 §4.1)。
   - 在 `main.rs:35` 之前(`RendezvousServer::start` 之前)读取 `get_arg("metrics-bind")`,若非空 parse `SocketAddr`,调用 `hbbs::metrics::install_recorder(addr, "hbbs")?`。空值时直接跳过,不打印 warning。
   - 失败处理:address parse 失败用 `bail!("invalid --metrics-bind: {e}")`。

3. **hbbr CLI 接入(0.25 day)**
   - 在 `rustdesk-server/src/hbbr.rs:15-19` 的 args 字符串末尾追加新 flag(见 §4.1)。
   - `hbbr.rs:38` `start(...)` 之前读取 `matches.value_of("metrics-bind").map(str::to_owned).or_else(|| std::env::var("METRICS_BIND").ok())`,非空时 parse 并调用 `metrics::install_recorder(addr, "hbbr")`。
   - 注意 `start` 是 `#[tokio::main]`(`relay_server.rs:48`),`install_recorder` 必须在进入 tokio runtime 之前完成 builder 安装但 HTTP listener 需要 runtime;`PrometheusBuilder::install` 内部会派生 runtime 线程,放在 `start()` 之外的同步 main 中即可。

4. **PeerMap 长度暴露(0.25 day)**
   - 在 `rustdesk-server/src/peer.rs` 的 `impl PeerMap`(`peer.rs:68` 起)新增:
     ```rust
     pub(crate) async fn len_in_memory(&self) -> usize { /* read lock + len */ }
     ```
   - 在 `RendezvousServer::start`(`rendezvous_server.rs:191-229`)注入一个 5s tick 的后台任务:周期采样 `pm.len_in_memory()` 并 `metrics::set_peermap_entries`、`set_peers_online`(后者遍历 in-memory peers 判断 `last_reg_time.elapsed() < REG_TIMEOUT`)。

5. **hbbs 计数器/直方图插桩(1 day)**
   - 按 §4.3 hbbs 表逐项添加 `metrics::inc_*` 调用。对每个分支,确认它在所有 await 路径上不会反复重复(例如 `handle_punch_hole_request` 一次请求只 inc 一次 `punch_hole_total`,在函数最开始处)。
   - `api_access_check_seconds`:目前没有 RBAC 调用点,**仅注册不观测**(在 `install_recorder` 内一次性 `describe_histogram!` 注册),避免空 metric 在 scrape 时缺失类型。
   - `ws_connections_active`:在 `handle_listener` 入口 `+1`、`handle_listener_inner` Drop guard `-1`(`rendezvous_server.rs:1142-1201`);用 `scopeguard` 或 RAII struct 包裹。

6. **hbbr 插桩(1 day)**
   - 在 `relay_server.rs:425-462` 的 `make_pair_` 插桩 `pair_pending` / `sessions_active` / `pair_timeout_total`。
   - 在 `relay_server.rs:486-563` 的 `relay()` 内插桩 `bytes_total{dir}`、`limiter_consume_total{class}`、`downgrade_total`、`blocked_total`、`relay_close_total`。
   - 在 `handle_connection`(`relay_server.rs:359-391`)插桩 `blocked_total{kind="block_pre_pair"}`。

7. **集成测试(0.5 day)**
   - 新建 `rustdesk-server/tests/metrics_smoke.rs`:绑定 `127.0.0.1:0` 启动 recorder,自增几个 counter,然后 `reqwest::blocking::get` 抓取 `/metrics`,assert 文本包含 `hbbs_register_total`、`# TYPE hbbs_peers_online gauge` 等。
   - 测试本身不启动完整 hbbs/hbbr,仅验证 metrics 模块自洽。

8. **运维文档(0.25 day)**
   - 新建 `docs/operations/metrics.md`:含 systemd unit 片段、`prometheus.yml` scrape 样例、与 `--metrics-bind` 默认空字符串等价的回滚说明。
   - 在 `docs/ai-development-plan.md` 任务卡末尾追加状态行(见 §10)。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|---------|--------|------|------|
| 1 | `rustdesk-server/tests/metrics_smoke.rs` | `metrics_endpoint_serves_text_format` | 在 127.0.0.1 随机端口安装 recorder,自增 `hbbs_register_total{kind="peer"}` 3 次,HTTP GET `/metrics` | 200,响应体包含 `# TYPE hbbs_register_total counter` 和 `hbbs_register_total{kind="peer"} 3` |
| 2 | `rustdesk-server/tests/metrics_smoke.rs` | `metrics_endpoint_includes_build_info` | 调用 `install_recorder(addr, "hbbs")` 后立即 GET `/metrics` | 响应包含 `hbbs_build_info{role="hbbs",version="<CARGO_PKG_VERSION>"} 1` |
| 3 | `rustdesk-server/tests/metrics_smoke.rs` | `install_recorder_rejects_in_use_port` | 先 bind 一个 `TcpListener` 占住端口,再 `install_recorder` 到同端口 | 返回 `Err`,错误消息含 `metrics-bind` |
| 4 | `rustdesk-server/tests/metrics_smoke.rs` | `install_recorder_rejects_malformed_addr` | CLI 解析层用 `"not-an-addr"` 调用 parse | parse 失败,bubble 上层错误,**不**导致 process abort |
| 5 | `rustdesk-server/src/peer.rs`(`#[cfg(test)] mod tests`) | `peermap_len_reflects_insertions` | new PeerMap,空时 `len_in_memory()==0`;`update_pk` 一个 peer 后 `==1` | 返回值与插入次数一致 |
| 6 | `rustdesk-server/tests/metrics_smoke.rs` | `disabled_when_flag_empty` | 不调用 `install_recorder`,直接调用 `metrics::inc_register("peer")` | 无 panic,无端口监听,GET `127.0.0.1:21120` 应连接失败(向后兼容路径) |
| 7 | `rustdesk-server/tests/metrics_smoke.rs` | `hbbr_pair_timeout_increments_counter` | 模拟 hbbr `make_pair_` 中 PEER insert 后无配对超时分支 | `hbbr_pair_timeout_total` 自增 1 |

至少覆盖:happy path(#1、#2)、失败模式(#3 端口占用、#4 非法地址)、回归兼容(#6 不开启 flag 时行为不变)。

## 7. 验证命令

按顺序执行:

```bash
# 编译与单元/集成测试(macOS 本地可跑)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-server
cargo check
cargo test metrics
cargo test peer
cargo test --test metrics_smoke

# hbbs 本地烟雾测试
cargo run --bin hbbs -- --metrics-bind 127.0.0.1:21120 &
sleep 2
curl -sf http://127.0.0.1:21120/metrics | head -40
curl -sf http://127.0.0.1:21120/metrics | grep -E '^hbbs_(build_info|peers_online|peermap_entries|register_total)'
kill %1

# hbbr 本地烟雾测试
cargo run --bin hbbr -- --metrics-bind 127.0.0.1:21121 &
sleep 2
curl -sf http://127.0.0.1:21121/metrics | head -40
curl -sf http://127.0.0.1:21121/metrics | grep -E '^hbbr_(build_info|sessions_active|bytes_total)'
kill %1

# 显式校验 21114 未被占用
! lsof -nP -iTCP:21114 -sTCP:LISTEN | grep -q hbb
```

可在 macOS 跳过的命令:无。所有命令在 macOS dev box 上均可执行(端口 21120/21121 默认空闲)。生产侧 systemd 集成的端到端 scrape 验证不在本任务范围,留给 CE-M0-5 / docs/operations/metrics.md。

## 8. 兼容性 / 安全注意事项

- **protobuf 兼容**:本任务不修改任何 `.proto` 与线协议,完全旁路注入。
- **老客户端/老服务端互通**:未设置 `--metrics-bind` 时 binary 行为与改动前完全一致(零端口、零内存额外结构);CI、旧 systemd unit、Docker compose 不需要任何变更即可继续部署。
- **数据库迁移**:无 schema 变更。
- **敏感字段不落盘**:metric label 严格使用枚举常量(`"peer"` / `"pk"` / `"udp"` 等)。**禁止**把 peer_id、IP、uuid、pk、ticket 作为 label value——否则会爆 cardinality 且泄露 PII。
- **绑定地址安全**:默认建议 `127.0.0.1`;文档与帮助文本明示禁止绑 `0.0.0.0`,需要外部 scrape 时走 systemd socket activation 或反向代理 + auth。
- **端口冲突**:21118/21119 已被 WebSocket 监听(`utils.rs:116-117`),21114 已被 rustdesk-api 占用且任务卡禁用。本任务采用 **21120(hbbs)/ 21121(hbbr)** 作为建议默认(**建议命名,可调整**,通过 flag 完全可覆盖)。
- **限流 / DoS**:`metrics-exporter-prometheus` 的 HTTP listener 仅服务 GET `/metrics`,绑 loopback 即可隔离;无需额外 rate limit。
- **指标分基线一致性**:`hbbs_api_access_check_seconds` 在 CE-M2 之前是注册但不观测的占位 histogram,确保 Grafana 仪表盘里不会出现 `unknown metric`。

## 9. 回滚方案

- **运行时回滚**:在 hbbs/hbbr 启动命令中去除 `--metrics-bind` 或将其设为 `""`,行为立即退回到无 metrics 端口。
- **代码回滚**:回退本任务的单次 commit。由于全部插桩通过 `metrics::*` 宏在 facade 层注册,删除 `mod metrics;` + Cargo.toml 中两行依赖后编译应即刻通过(代码内 `inc_*` 调用统一封装在 `metrics::` 命名空间,删除模块时 `cargo` 报错会精确定位需移除的调用点)。
- **配置 feature flag(可选,不强制)**:可加 `#[cfg(feature = "metrics")]` 包裹 `install_recorder` 调用与依赖项;但因默认 flag 为空已等价于 disabled,通常不必要。

## 10. 完成定义 (DoD)

- [ ] `cargo check` 与 `cargo test --test metrics_smoke` 在 `rustdesk-server/` 下全绿。
- [ ] `hbbs --metrics-bind 127.0.0.1:21120` 启动后 `/metrics` 返回非空文本且包含 `hbbs_build_info`。
- [ ] `hbbr --metrics-bind 127.0.0.1:21121` 启动后 `/metrics` 返回非空文本且包含 `hbbr_build_info`。
- [ ] 默认(不传 flag)启动行为与改动前一致,无新增端口监听。
- [ ] §4.3 所列每个 metric 在源码中至少有一个插桩点(grep 验证)。
- [ ] `docs/operations/metrics.md` 完成,含 scrape 示例与回滚说明。
- [ ] 21114 未被 hbbs/hbbr 抢占(`lsof` 验证)。
- [ ] 没有把 peer_id / IP / uuid 作为 metric label value(code review checklist)。
- [ ] `docs/ai-development-plan.md` 对应任务卡(`CE-M0-3 metrics 独立端口`, 行 146-162)末尾追加 `状态: 完成 (commit <hash>)`。
