# 审计事件扩展运维手册 (CE-M1-10)

> 任务卡:CE-M1-10(`../ai-tasks/CE-M1-10.md`),依赖 CE-M1-6 / CE-M1-7,衔接 CE-M1-9。
> 适用范围:`rustdesk-api` 端 `audit_event` 表 + `/api/audit/event` 端点,以及客户端 `rustdesk`
> 在剪贴板 / 告警 / 远程命令钩子上的上报。
> 默认:**事件总开关 `audit.event-enabled=true`**;`AuditConn` / `AuditFile` 与历史一致,**永不替换**。

本手册与 `./2fa.md` 共同构成 M1 阶段"安全闭环"——MFA 控制谁能登录,本手册控制
"登录之后做了什么"如何被记录、查询、归档。

## 1. 概述

CE-M1-6 新增**统一审计事件**模型 `AuditEvent`,与历史 `AuditConn` / `AuditFile` **并存**:

- 旧端点 **完全不变**:`/api/audit/conn` 与 `/api/audit/file` 由客户端连接 / 文件传输钩子继续写入;
  `/admin/audit_conn/list` 与 `/admin/audit_file/list` 在管理后台继续可用,**列表行为不退化**。
- 新端点 **只增不替**:
  - `POST /api/audit/event` 客户端上报剪贴板 / 告警 / 命令等 kind 事件。
  - `GET  /admin/audit_event/list` 后台分页查询,支持按 `kind` / 时间段 / `peer_id` 过滤。
  - `POST /admin/audit_event/delete` / `POST /admin/audit_event/batchDelete` 受限删除。
- **事件 kind 白名单**(代码 `rustdesk-api/model/audit.go`):`clipboard` / `alarm` / `cmd` / `record`。
  其中 `record`(会话录像)在 M1 仅占位,M3 才落地;运维 dashboard 暂时**不要**对其做 SLO 告警。

### 兼容性铁律(与 `../ai-development-plan.md` §1.1 / L341-L342 一致)

1. **proto 不破坏向后兼容**:客户端如果不识别 `/api/audit/event`,继续走 `/api/audit/file`
   不会受影响;服务端在 `audit.event-enabled=false` 时该端点直接 503,客户端按"上报失败"重试退避。
2. **数据库迁移单向递增**:CE-M1-6 把 `DatabaseVersion` 抬到 266 同步引入 `user_mfa` 与
   `audit_event` 两张表(CE-M1-5 后续到 267)。**禁止**手动改 `DatabaseVersion`。
3. **新增端点不删旧端点**:`/api/audit/file` 与 `/admin/audit_file/list` 行为不变,
   `/api/audit/conn` 同上;新 kind 走 `/api/audit/event`,二者通过统一管理后台视图汇总。

### 与 CE-M1-9 的衔接

运维若需要**分发已开启审计上报的客户端**,可参考 CE-M1-9 的轻量 Client Builder
(`../ai-development-plan.md#ce-m1-9-轻量-client-builder`):后台填写 server / key / api 后
生成 `RustDesk-host=<server>,key=<base64>,api=<url>.exe`,下发对象首次启动即指向本 api,
新 kind 自动上报。CE-M1-9 未合并时此段视作"未来扩展",不阻塞 M1 验收。

## 2. 前置阅读

- 任务卡
  - `../ai-development-plan.md#ce-m1-6-审计事件扩展` — `audit_event` 表 schema、kind 枚举、控制器路由。
  - `../ai-development-plan.md#ce-m1-7-客户端审计上报` — 客户端钩子位置(剪贴板 / 文件传输 / 告警);
    **上报失败不阻塞会话**(`../ai-development-plan.md` L350)。
  - `../ai-development-plan.md#ce-m1-9-轻量-client-builder` — 衔接,用于下发开启审计的客户端。
- 上游文档
  - `../architecture.md#23-鉴权链路` — `/api/audit/*` 通过 Bearer token 鉴权,服务端用解析后的
    `user_id` 作为真实身份;客户端上报的 `from_peer` **仅作展示,不可信**。
  - `../rustdesk-api.md` 审计章节 — 历史 `AuditConn` / `AuditFile` 字段对照。
- 源码入口(实现以代码为准)
  - `rustdesk-api/model/audit.go` — `AuditEvent` 结构 + kind 白名单。
  - `rustdesk-api/service/audit.go` — `AuditEventList` / `CreateAuditEvent` / 批量删除。
  - `rustdesk-api/http/controller/api/audit.go` — `POST /api/audit/event`。
  - `rustdesk-api/http/controller/admin/audit.go` — `GET /admin/audit_event/list` 等管理面。
  - `rustdesk-api/http/request/api/audit.go` — `AuditEventForm` + payload 16KB 上限。

衔接:本手册的 "客户端上报" 与 "常见故障" 章节假设客户端已升级到含 CE-M1-7 的版本;若客户端尚未升级,
管理后台只会看到 `AuditConn` / `AuditFile` 旧表数据,新 `kind` 列为空属正常。

## 3. 配置项

> 命名沿用 `RUSTDESK_API_<段>_<键>` 模式;若 CE-M1-6 实现时调整以代码为准并回填。**建议命名,可调整**。

| yaml key | env var | 默认值 | 说明 |
|----------|---------|--------|------|
| `audit.event-enabled` | `RUSTDESK_API_AUDIT_EVENT_ENABLED` | `true` | 新事件总开关。关闭后 `/api/audit/event` 返回 503,旧 `/api/audit/file`、`/api/audit/conn` 不受影响 |
| `audit.event-kinds` | `RUSTDESK_API_AUDIT_EVENT_KINDS` | `clipboard,alarm` | 启用上报的 kind 白名单;未在白名单内的 kind 服务端返回 400 `ParamsError: unknown kind` |
| `audit.event-retention-days` | `RUSTDESK_API_AUDIT_EVENT_RETENTION_DAYS` | `90` | `audit_event` 表保留天数,GC 任务按 `created_at` 清理。设 `0` 关闭自动 GC |
| `audit.event-payload-max-bytes` | `RUSTDESK_API_AUDIT_EVENT_PAYLOAD_MAX_BYTES` | `16384` | `payload_json` 体积上限(代码常量 `AuditEventPayloadMaxBytes`)。超长由服务端返回 400 |
| `audit.event-gc-interval` | `RUSTDESK_API_AUDIT_EVENT_GC_INTERVAL` | `24h` | 后台 GC 扫描周期 |

`config.yaml` 片段示例:

```yaml
audit:
  event-enabled: true
  event-kinds: "clipboard,alarm"        # 当前生产建议:不开 cmd / record
  event-retention-days: 90
  event-payload-max-bytes: 16384
  event-gc-interval: "24h"
```

**安全约束**:

- `payload_json` 由**客户端**做哈希 / 截断;服务端**不解析**,只做长度校验,避免敏感剪贴板原文入库。
- `from_peer` / `from_name` / `ip` 来自客户端,**仅作展示**;真实身份由服务端解析 `Authorization`
  Bearer token 得到的 `user_id` / `peer_id` 决定。
- 录屏审计(`record` kind)在 M1 仅占位,**M3 才 GA**(`../upgrade-plan.md` L116),手册不要承诺其 SLO。

## 4. 事件类型与契约

代码 `rustdesk-api/model/audit.go` 中的 kind 枚举(常量名摘自源码,字符串值即 JSON 中的 `kind`):

| 常量 | `kind` 字符串 | 触发点(客户端钩子) | payload 建议 |
|------|---------------|---------------------|--------------|
| `AuditEventKindClipboard` | `clipboard` | 剪贴板文本 / 文件复制粘贴跨端传输 | `{"size":<int>, "is_file":<bool>, "preview_hash":"<sha1-16>"}`,**不要**放明文 |
| `AuditEventKindAlarm` | `alarm` | 策略告警 / 异常断开 / 反爆破触发 | `{"alarm_type":"login_brute","detail":"<short>"}` |
| `AuditEventKindCmd` | `cmd` | 服务端下发或客户端执行命令(M2+ 才大规模启用) | `{"cmd":"shutdown","exit_code":0}` |
| `AuditEventKindRecord` | `record` | 会话录像开始 / 结束(**M1 占位,M3 落地**) | `{"phase":"start","filename":"<uuid>.mkv"}` |

数据库表 `audit_event`(逐字对应 `model.AuditEvent`,顺序按 GORM 字段声明):

| 字段 | 类型 | 含义 |
|------|------|------|
| `id` | uint | 主键 |
| `kind` | string(32) | kind 枚举,索引 `idx_audit_event_kind_created` 第一列 |
| `peer_id` | string(64) | 远控对端 ID |
| `from_peer` | string(64) | 上报端自报 ID,**展示用** |
| `from_name` | string(128) | 上报端自报用户名,**展示用** |
| `session_id` | string(64) | 关联 `audit_conn.session_id`(便于跨表 JOIN) |
| `ip` | string(64) | 客户端自报 IP |
| `payload_json` | text | ≤16KB,服务端只做长度校验 |
| `created_at` / `updated_at` | int | TimeModel,索引 `idx_audit_event_kind_created` 第二列 |

复合索引由 `cmd/apimain.go` 的 `Migrate()` 末尾显式建立,**不要**手动 DROP;GORM tag
里的 `priority:1` 仅作说明。

## 5. 客户端上报

CE-M1-7 在客户端以下钩子调用 `audit_event!(kind, payload)`(实现细节以客户端代码为准):

- `src/server/connection.rs` 剪贴板 / 文件传输 / 远端命令分支;
- `src/server/clipboard_service.rs` 文本与文件剪贴板;
- `src/server/alarm.rs`(或同等位置)登录爆破 / 异常断开。

**关键约束**:

- **上报失败不阻塞远控会话**(`../ai-development-plan.md` L350)。客户端使用单独 worker queue
  发送 `/api/audit/event`,失败按指数退避重试 N 次后落本地 ring buffer,日志告警但**不要**中断
  RDP 流。
- **`from_peer` 不可信**(`../architecture.md` §鉴权链路 / `../ai-development-plan.md` L52 L531)。
  本字段仅作 UI 展示,任何安全决策必须基于服务端解析 token 得到的 `user_id` / 关联 `peer_id`。
- **payload 须由客户端预处理**:剪贴板内容必须先做 SHA1-16 截断 / 大小汇总,**不要**直接把原文塞进
  `payload_json`。
- 客户端默认只启用 `clipboard` / `alarm` 两个 kind;`cmd` 在 M2 启用,`record` 在 M3 启用。
  CE-M1-9 生成的轻量客户端在打包时按 `audit.event-kinds` 配置裁剪。

## 6. 管理后台查询

`GET /admin/audit_event/list` 支持的过滤参数(见 `http/controller/admin/audit.go`):

| query | 类型 | 说明 |
|-------|------|------|
| `page` / `page_size` | uint | 默认 1 / 20 |
| `kind` | string | 单值过滤;空表示全部 |
| `peer_id` | string | 精确匹配 |
| `from_peer` | string | 精确匹配 |
| `from` / `to` | unix-timestamp 或 `YYYY-MM-DD` | 时间窗 |
| `session_id` | string | 关联 `audit_conn` 行 |

示例:

```bash
curl -s "http://127.0.0.1:21114/admin/audit_event/list?kind=clipboard&from=2026-06-01&to=2026-06-30&page=1&page_size=20" \
  -H "Authorization: Bearer <admin_token>" | jq '.data.total, .data.list[0]'
```

CSV 导出(若 CE-M1-6 已合并 `export?format=csv` 子路由)走 `GET /admin/audit_event/list?format=csv`;
未合并时手册写 `TODO: pending CE-M1-6 export subroute`。**不要**为了凑文档而在 jq 里手写脚本 —
导出能力是产品决策,运维同学按上游任务卡进展引用即可。

后台批量删除:

```bash
# 单条
curl -s -X POST http://127.0.0.1:21114/admin/audit_event/delete \
  -H "Authorization: Bearer <admin_token>" \
  -H 'Content-Type: application/json' \
  -d '{"id": 12345}'

# 批量
curl -s -X POST http://127.0.0.1:21114/admin/audit_event/batchDelete \
  -H "Authorization: Bearer <admin_token>" \
  -H 'Content-Type: application/json' \
  -d '{"ids":[1,2,3]}'
```

## 7. API 示例

> 默认端口 `21114`;Bearer token 由 `/api/login`(+ MFA 时叠 `/api/login-mfa`)签发,见 `./2fa.md`。

### 7.1 客户端上报剪贴板事件

```bash
curl -s -X POST http://127.0.0.1:21114/api/audit/event \
  -H 'Authorization: Bearer <client_token>' \
  -H 'Content-Type: application/json' \
  -d '{
        "kind": "clipboard",
        "peer_id": "123456789",
        "from_peer": "987654321",
        "from_name": "alice",
        "session_id": "<uuid>",
        "ip": "1.2.3.4",
        "payload_json": "{\"size\":42,\"is_file\":false,\"preview_hash\":\"<sha1-16>\"}"
      }'
```

预期响应 `{"data":null}` HTTP 200。失败常见 `400 ParamsError: unknown kind` 或
`400 ParamsError: payload too large`。

### 7.2 客户端上报告警事件

```bash
curl -s -X POST http://127.0.0.1:21114/api/audit/event \
  -H 'Authorization: Bearer <client_token>' \
  -H 'Content-Type: application/json' \
  -d '{"kind":"alarm","peer_id":"123456789","payload_json":"{\"alarm_type\":\"login_brute\",\"detail\":\"too_many_fail\"}"}'
```

### 7.3 后台按 kind 查询

```bash
curl -s "http://127.0.0.1:21114/admin/audit_event/list?kind=alarm&page=1&page_size=10" \
  -H "Authorization: Bearer <admin_token>" | jq '.data.total'
```

### 7.4 后台按时间段查询

```bash
curl -s "http://127.0.0.1:21114/admin/audit_event/list?from=2026-06-01&to=2026-06-27&page=1&page_size=50" \
  -H "Authorization: Bearer <admin_token>" | jq '.data.list | length'
```

### 7.5 旧 `/api/audit/file` 兼容样例(行为不变)

```bash
curl -s -X POST http://127.0.0.1:21114/api/audit/file \
  -H 'Authorization: Bearer <client_token>' \
  -H 'Content-Type: application/json' \
  -d '{
        "peer_id":"123456789","from_peer":"987654321","from_name":"alice",
        "path":"/tmp/x.zip","is_file":true,"type":0,"num":1,
        "uuid":"<uuid>","ip":"1.2.3.4","info":""
      }'

# 后台查询(行为不变)
curl -s "http://127.0.0.1:21114/admin/audit_file/list?page=1&page_size=20" \
  -H "Authorization: Bearer <admin_token>" | jq '.data.total'
```

`/api/audit/file` 与 `/admin/audit_file/list` 行为不变,任何老接入方继续工作。

## 8. 常见故障

| # | 现象 | 排查 | 修复 |
|---|------|------|------|
| 1 | 客户端 `payload too large` 400 | `payload_json` > `audit.event-payload-max-bytes`(默认 16KB) | 客户端钩子内做 SHA1-16 + 元数据压缩;**不要**调高服务端上限以塞原文 |
| 2 | `unknown kind` 400 | kind 未在 `audit.event-kinds` 白名单 | 后台 yaml 把 kind 加入白名单并热重载;或客户端按 kind 路由到合适端点 |
| 3 | 客户端短暂断网后未补传 | 重试退避耗尽 N 次后丢弃,本地 ring buffer 满 | 在客户端日志里 `grep audit_event drop`;扩大 ring buffer,但不要阻塞会话 |
| 4 | 后台审计页显示 `from_peer=anonymous` | 客户端版本 < CE-M1-7,未带 `from_peer` 字段 | 升级客户端或忽略;**不要**用 `from_peer` 做任何安全决策 |
| 5 | 90 天前的事件突然消失 | `audit.event-retention-days` GC 扫到 | 调高保留天数或在 GC 前夜冷备 `audit_event` 表 |
| 6 | `audit_event` 表暴涨 | 客户端误把高频钩子接进 `clipboard` | 临时 `audit.event-enabled=false`,定位钩子频率,加客户端节流 |
| 7 | `record` kind 查不到数据 | 录屏在 M1 占位,M3 才落地 | 等待 M3;不要为它配 dashboard |
| 8 | 旧客户端只上 `AuditConn` / `AuditFile`,新 kind 全空 | 客户端尚未升级到 CE-M1-7 | 用 CE-M1-9 builder 下发已开启审计的客户端 |

排查命令清单:

```bash
# 看最近 50 条新事件
docker compose exec rustdesk-api sqlite3 /data/rustdesk.db \
  "SELECT id, kind, peer_id, length(payload_json) AS sz, created_at FROM audit_event ORDER BY id DESC LIMIT 50;"

# 看老 audit_file 行为是否仍正常(兼容验证)
docker compose exec rustdesk-api sqlite3 /data/rustdesk.db \
  "SELECT count(*) FROM audit_file WHERE created_at > strftime('%s','now','-1 day');"

# 看告警事件分布
docker compose exec rustdesk-api sqlite3 /data/rustdesk.db \
  "SELECT kind, count(*) FROM audit_event WHERE created_at > strftime('%s','now','-7 day') GROUP BY kind;"
```

## 9. 回滚

### 9.1 软回滚(推荐)

- **关闭新事件总开关**:`audit.event-enabled=false` 重启服务。客户端继续工作,只是新 kind 不再写入;
  保留期内已写入的事件继续可查;`/api/audit/file` / `/api/audit/conn` 不受影响。
- **缩白名单**:把 `audit.event-kinds` 收窄到 `clipboard,alarm` 排除噪声 kind。
- **缩保留期**:调小 `audit.event-retention-days` 让 GC 加速清理;**不要**直接 `TRUNCATE` 表。

### 9.2 硬回滚(仅灾难恢复)

仅当回滚到 CE-M1-6 之前的二进制版本时执行,**不要**例行操作:

1. 暂停 `apimain` 进程。
2. 备份当前数据库;`audit_event` 表先 `INSERT INTO bk_audit_event SELECT * FROM audit_event;`。
3. 用上一版本二进制启动;新版本写入的 `audit_event` 表对旧二进制无影响(GORM 忽略多余表)。
4. **仅在 dev / staging**:`DROP TABLE audit_event;`,把 `cmd/apimain.go:DatabaseVersion` 改回 265。
   生产环境**禁止**手动改 `DatabaseVersion`。

### 9.3 特性开关纪要

- `audit.event-enabled=false` 与 `mfa.enabled=false` 是两条独立 feature flag,可独立灰度。
- 客户端 CE-M1-7 行为受 `audit.event-kinds` 间接控制;客户端打包时若用 CE-M1-9 轻量 builder
  可裁剪 kind。

## 10. 验收

> 直接对应 `../upgrade-plan.md` L175 用户验收剧本:"后台审计页能看到文件 / 剪贴板事件"。

按顺序执行,任一步失败即视为不通过:

```bash
API="http://127.0.0.1:21114"
ADMIN_TOKEN="<admin_jwt>"
CLIENT_TOKEN="<client_jwt>"

# 1) 总开关已打开
curl -s "$API/api/admin/config/show" -H "Authorization: Bearer $ADMIN_TOKEN" \
  | jq '.data.audit."event-enabled"'
# 期望: true

# 2) 旧 /api/audit/file 仍写得进
curl -s -X POST "$API/api/audit/file" -H "Authorization: Bearer $CLIENT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"peer_id":"1","from_peer":"2","path":"/tmp/x","is_file":true,"type":0,"num":1,"uuid":"u","ip":"1.2.3.4","info":""}'
curl -s "$API/admin/audit_file/list?page=1&page_size=1" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.data.total'
# 期望: ≥ 1(兼容验证)

# 3) 新 /api/audit/event 写得进
curl -s -X POST "$API/api/audit/event" -H "Authorization: Bearer $CLIENT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"kind":"clipboard","peer_id":"1","from_peer":"2","payload_json":"{\"size\":1}"}'

# 4) 新事件能按 kind 过滤
curl -s "$API/admin/audit_event/list?kind=clipboard&page=1&page_size=1" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.data.total'
# 期望: ≥ 1

# 5) 未知 kind 被拒
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API/api/audit/event" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"kind":"bogus","payload_json":"{}"}'
# 期望: 400

# 6) payload 超长被拒
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API/api/audit/event" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"kind\":\"clipboard\",\"payload_json\":\"$(head -c 20000 /dev/urandom | base64 | tr -d '\n')\"}"
# 期望: 400
```

**人工核对项**:

- [ ] 后台审计页能同时看到 **文件审计** 与 **剪贴板事件** 列表(对应 `../upgrade-plan.md` L175)。
- [ ] 客户端剪贴板上报 payload 中**没有明文剪贴板内容**,只有 hash + 大小 + 类型。
- [ ] 客户端在 api 临时不可达时 RDP 会话**不卡顿**;`audit_event drop` 计数会上升但不阻塞。
- [ ] `/api/audit/file` 与 `/admin/audit_file/list` 行为与升级前完全一致(对照历史录屏 / 测试日志)。

补充端到端步骤(需要完整 docker-compose 与开启 MFA 的测试账号)写在 `../upgrade-plan.md`
Sprint 2 收尾验收里;本仓库不强求 CI 覆盖,该项标注 `skipped (env-bound)` 即可。
