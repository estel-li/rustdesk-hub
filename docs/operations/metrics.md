# RustDesk 自托管栈 Prometheus Metrics(hbbs / hbbr)

> 任务卡:CE-M0-3 hbbs/hbbr Prometheus metrics 独立端口
> 适用版本:rustdesk-server fork(本仓库 `rustdesk-server/` 子目录)
> 默认:**关闭**。仅在显式传入 `--metrics-bind` 后才监听对应端口。

## 1. 设计概览

hbbs 与 hbbr 各自暴露一个独立的 `/metrics` HTTP 端点,通过 CLI flag `--metrics-bind <ip>:<port>` 指定监听地址。该端口与现有业务端口完全隔离:

| 进程 | 已用端口 | 建议 metrics 端口 |
|------|----------|-------------------|
| rustdesk-api | 21114 (HTTP API) | — |
| hbbs | 21115 (NAT test), 21116 (主), 21118 (WS) | **21120**(本任务建议) |
| hbbr | 21117 (TCP), 21119 (WS) | **21121**(本任务建议) |

实现位于 `rustdesk-server/src/metrics.rs`,基于 `metrics` + `metrics-exporter-prometheus`。所有 label 严格枚举,**禁止**把 peer_id / IP / uuid / pk / ticket 作为 label value(高基数 + PII)。

## 2. 启用方式

### 2.1 CLI

```bash
hbbs --metrics-bind 127.0.0.1:21120
hbbr --metrics-bind 127.0.0.1:21121
```

未传 / 空字符串 = 不启用,binary 行为与未引入本任务前完全一致(零端口监听、零额外内存结构)。

### 2.2 环境变量(仅 hbbr)

hbbr 还支持 `METRICS_BIND` 环境变量回退(对齐现有 `PORT` / `KEY` 处理风格):

```bash
METRICS_BIND=127.0.0.1:21121 hbbr
```

flag 优先级 > 环境变量 > 关闭。

### 2.3 systemd unit 示例

```ini
# /etc/systemd/system/hbbs.service
[Service]
ExecStart=/usr/local/bin/hbbs \
    --port 21116 \
    --relay-servers relay.example.com:21117 \
    --metrics-bind 127.0.0.1:21120
Restart=always
```

```ini
# /etc/systemd/system/hbbr.service
[Service]
ExecStart=/usr/local/bin/hbbr --metrics-bind 127.0.0.1:21121
Restart=always
```

### 2.4 docker-compose 示例

```yaml
services:
  hbbs:
    image: rustdesk/rustdesk-server:ce
    command: hbbs --metrics-bind 127.0.0.1:21120
    network_mode: host
  hbbr:
    image: rustdesk/rustdesk-server:ce
    command: hbbr --metrics-bind 127.0.0.1:21121
    network_mode: host
```

> 提示:host network 才能 loopback 暴露 metrics 给同机 Prometheus。如果 Prometheus 跑在其他主机,应改用 socket activation 或反向代理 + auth,**禁止**直接绑 `0.0.0.0`。

## 3. Prometheus scrape 示例

```yaml
# /etc/prometheus/prometheus.yml
scrape_configs:
  - job_name: rustdesk-hbbs
    metrics_path: /metrics
    static_configs:
      - targets: ['127.0.0.1:21120']
        labels:
          service: hbbs
  - job_name: rustdesk-hbbr
    metrics_path: /metrics
    static_configs:
      - targets: ['127.0.0.1:21121']
        labels:
          service: hbbr
```

## 4. Metric 字典

### 4.1 hbbs

| 名称 | 类型 | labels | 含义 |
|------|------|--------|------|
| `hbbs_build_info` | gauge | `role`, `version` | 始终为 1,用于看板分组 |
| `hbbs_peers_online` | gauge | — | 当前 `last_reg_time` 在 `REG_TIMEOUT` 内的内存 peer 数(5s 周期采样) |
| `hbbs_peermap_entries` | gauge | — | PeerMap 内存条目数(5s 周期采样) |
| `hbbs_ws_connections_active` | gauge | — | 当前活跃 WebSocket 连接数 |
| `hbbs_register_total` | counter | `kind` ∈ `peer` \| `pk` | RegisterPeer / RegisterPk 事件数 |
| `hbbs_register_reject_total` | counter | `reason` ∈ `too_frequent` \| `uuid_mismatch` | RegisterPk 被拒事件数 |
| `hbbs_punch_hole_total` | counter | `transport` ∈ `udp` \| `tcp` \| `ws` | 打洞请求数(按入口分类) |
| `hbbs_punch_hole_result_total` | counter | `result` ∈ `ok` \| `offline` \| `id_not_exist` \| `license_mismatch` \| `same_intranet` | 打洞结果分支 |
| `hbbs_relay_assign_total` | counter | — | 分配 relay server 次数 |
| `hbbs_ip_blocked_total` | counter | — | IP 频控拒绝 |
| `hbbs_api_access_check_seconds` | histogram | `decision` ∈ `allow` \| `deny` \| `error` | API/RBAC 访问检查延迟(预留,CE-M2 才会观测) |

### 4.2 hbbr

| 名称 | 类型 | labels | 含义 |
|------|------|--------|------|
| `hbbr_build_info` | gauge | `role`, `version` | 始终为 1 |
| `hbbr_sessions_active` | gauge | — | 当前正在 relay 的会话数 |
| `hbbr_pair_pending` | gauge | — | 等待对端配对的连接数 |
| `hbbr_pair_timeout_total` | counter | — | 30s 内无配对、超时移除次数 |
| `hbbr_bytes_total` | counter | `dir` ∈ `in` \| `out` | relay 通过的比特数 |
| `hbbr_limiter_consume_total` | counter | `class` ∈ `normal` \| `downgrade_blacked` \| `total` | 限速器 consume 调用次数 |
| `hbbr_downgrade_total` | counter | — | 超阈值触发 downgrade |
| `hbbr_blocked_total` | counter | `kind` ∈ `block_pre_pair` \| `block_mid_relay` | blocklist 命中 |
| `hbbr_relay_close_total` | counter | `reason` ∈ `peer_eof` \| `client_eof` \| `timeout` \| `send_err` | relay 关闭原因 |

> `hbbr_bytes_total` 的单位是 **bit**(原 relay 内部计速也以 bit 为单位)。Grafana 看板按需 `/8` 换算为 Byte。

## 5. 安全注意事项

1. **绑定地址**:强制 loopback。需要远端 scrape 时使用 reverse proxy(nginx/caddy)+ Basic Auth 或 mTLS,不要直接 `0.0.0.0`。
2. **基数控制**:严禁向 metric label 注入 peer_id / IP / uuid 等高基数字段——既会撑爆 Prometheus,也会泄露 PII。本任务的代码插桩点已严格使用枚举常量。
3. **DoS**:`/metrics` 仅 HTTP GET,无外部输入,绑 loopback 即可。
4. **审计 endpoint 不在此**:`audit_conn` / `audit_file` 等审计接口仍归 `rustdesk-api`,与 metrics endpoint 互不影响。

## 6. 回滚

- **运行时**:删除 `--metrics-bind` 参数(或设为空字符串),进程立即退回到无 metrics 端口监听。无需重新部署其他组件。
- **代码**:回退本任务对应 commit。所有插桩通过 `metrics::*` facade 宏调用,删除 `mod metrics;` + `Cargo.toml` 中两行依赖后,编译期会精准报告需移除的调用点(全部位于 `ce_metrics::` 命名空间)。

## 7. 验证步骤

```bash
# 1. 启动 hbbs + metrics
hbbs --metrics-bind 127.0.0.1:21120 &
sleep 2
curl -sf http://127.0.0.1:21120/metrics | grep -E '^hbbs_(build_info|register_total)'

# 2. 启动 hbbr + metrics
hbbr --metrics-bind 127.0.0.1:21121 &
sleep 2
curl -sf http://127.0.0.1:21121/metrics | grep -E '^hbbr_(build_info|bytes_total)'

# 3. 确认 21114 不被抢占(rustdesk-api 独占)
! lsof -nP -iTCP:21114 -sTCP:LISTEN | grep -q hbb
```

## 8. 后续依赖

- **CE-M0-4 rustdesk-api metrics**:Go 侧用 `prometheus/client_golang` 暴露 `/metrics`,聚合到同一 Grafana 看板。
- **CE-M2 RBAC/MFA**:`hbbs_api_access_check_seconds` 直方图在该任务上线后才会有非空观测值。Grafana 仪表盘里 P95 面板可先建好,数据自动填充。
- **CE-M0-6 PeerMap GC**:GC 上线后 `hbbs_peermap_entries` 应可观测到稳态而非单调增长。
