# CE-M1-6 审计事件扩展 (clipboard/alarm/cmd/record)

## 1. 任务目标

在保留 `AuditConn` / `AuditFile` 两张表及其现有端点的前提下,新增统一审计事件表 `audit_event(kind, peer_id, from_peer, from_name, session_id, ip, payload_json, created_at)`,承接剪贴板、告警、远程命令、会话录像等新事件,并暴露客户端写入端点 `POST /api/audit/event` 与后台查询端点 `GET /api/admin/audit_event/list`(支持按 `kind` 过滤、分页、批量删除)。验收信号:

- 在 SQLite/PostgreSQL 任一 DSN 下 `AutoMigrate` 后存在 `audit_events` 表及 `(kind, created_at)` 复合索引。
- 客户端用任意 `kind` POST 一条 ≤16KB 的 `payload_json` 返回 `Success`;>16KB 时返回 `ParamsError`。
- 后台 `GET /api/admin/audit_event/list?kind=clipboard&page=1&page_size=10` 能正确返回新写入的记录,且其他 `kind` 不混入。
- 原 `/api/audit/conn`、`/api/audit/file`、`/api/admin/audit_conn/list`、`/api/admin/audit_file/list` 行为字段一字不动。

任务卡引用见 `docs/ai-development-plan.md:318-342`。

## 2. 上下文与依赖

- 上游依赖任务卡:无强阻塞。客户端剪贴板/告警的实际上报由 CE-M1-7 完成(见 `docs/ai-development-plan.md:344-356`),本任务先把服务端契约和表落地。
- 下游会用到此输出的任务卡:
  - CE-M1-7 客户端审计上报(`docs/ai-development-plan.md:344-356`)将调用 `POST /api/audit/event` 写剪贴板/告警/异常断开等事件。
  - 后台前端列表页(rustdesk-api-web)会消费 `GET /admin/audit_event/list` 输出(本卡只提供后端契约)。
- 关键背景事实:
  - 现有 `AuditConn` 结构在 `rustdesk-api/model/audit.go:8-21`,带 `IdModel` + `TimeModel`(`rustdesk-api/model/model.go:14-20`)。所有审计表 GORM 默认表名为 `audit_conns` / `audit_files`,因此新表名将为 `audit_events`。
  - `AuditService` 单例式实现于 `rustdesk-api/service/audit.go:8-95`,通过包级 `DB` 句柄操作 GORM,分页用 `Paginate` scope(`AuditConnList` 见同文件第 11-23 行)。新事件服务复用同一模式。
  - 客户端审计写入路径见 `rustdesk-api/http/controller/api/audit.go:26-84`,均落在 `/api` 组的 **未鉴权** 段(`rustdesk-api/http/router/api.go:69-74`,在 `RustAuth()` 之前)。新 `/api/audit/event` 端点应放在同一段,与 conn/file 一致。
  - 后台审计绑定见 `rustdesk-api/http/router/admin.go:194-204`,路径模式为 `/api/admin/audit_xxx/{list,delete,batchDelete}`,统一带 `middleware.AdminPrivilege()`。新端点遵循此模式。
  - 后台分页/筛选请求结构 `AuditQuery` 在 `rustdesk-api/http/request/admin/audit.go:3-7`,复用 `PageQuery`。新 query 需额外携带 `kind`,且 `peer_id` / `from_peer` 仍需支持模糊查询(`rustdesk-api/http/controller/admin/audit.go:36-44`)。
  - `AutoMigrate` 注册位置在 `rustdesk-api/cmd/apimain.go:289-313`,新增模型需追加到列表;现有 `Version` 升级钩子 (`apimain.go` 同文件 `MigrateIfNecessary` 段) 仅做数据回填,本任务暂不需要数据回填,只需建表。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
| --- | --- | --- | --- |
| `rustdesk-api/model/audit.go` | 修改 | +60 | 追加 `AuditEvent` struct、`AuditEventList`,以及 `AuditEventKind*` 常量。**不动** 现有 `AuditConn`/`AuditFile`。 |
| `rustdesk-api/service/audit.go` | 修改 | +60 | 追加 `CreateAuditEvent` / `AuditEventList` / `EventInfoById` / `DeleteAuditEvent` / `BatchDeleteAuditEvent`。 |
| `rustdesk-api/http/request/api/audit.go` | 修改 | +50 | 追加 `AuditEventForm` 与 `ToAuditEvent()`,做 16KB 校验、kind 白名单校验。 |
| `rustdesk-api/http/request/admin/audit.go` | 修改 | +10 | 追加 `AuditEventQuery`(含 `Kind` 字段)与 `AuditEventLogIds`。 |
| `rustdesk-api/http/controller/api/audit.go` | 修改 | +35 | 追加 `AuditEvent` handler。 |
| `rustdesk-api/http/controller/admin/audit.go` | 修改 | +100 | 追加 `EventList` / `EventDelete` / `BatchEventDelete`。 |
| `rustdesk-api/http/router/api.go` | 修改 | +2 | `frg.POST("/audit/event", au.AuditEvent)` 放在与 conn/file 同一未鉴权段(`router/api.go:69-74`)。 |
| `rustdesk-api/http/router/admin.go` | 修改 | +5 | 在 `AuditBind` 末尾追加 `audit_event` 子组(`router/admin.go:194-204`)。 |
| `rustdesk-api/cmd/apimain.go` | 修改 | +1 | 在 `AutoMigrate` 列表中追加 `&model.AuditEvent{}`(`cmd/apimain.go:291-309`)。 |
| `rustdesk-api/service/audit_event_test.go` | 新建 | ~120 | 服务层单元测试(参考 `service/app_test.go` 现有方式)。 |
| `rustdesk-api/http/controller/api/audit_event_test.go` | 新建 | ~80 | 控制器单元/集成测试(若仓库已有 controller 测试 harness 则复用;否则按 `httptest` 自行搭建,**建议命名,可调整**)。 |
| `docs/ai-development-plan.md` | 修改 | +1 | 任务卡末尾追加 `状态: 完成 (commit <hash>)`。 |

> 备注:仓库根 `rustdesk-api/db/` 目录(SQL 脚本)未发现独立 DDL 文件;迁移完全依赖 GORM `AutoMigrate`。若发现 `rustdesk-api/sql/*.sql` 类种子文件,需要同步更新——**未找到,需新建** 的 SQL 文件不在本任务范围,以代码 AutoMigrate 为准。

## 4. 数据契约

### 4.1 Go 结构体 (新增到 `rustdesk-api/model/audit.go`)

```go
const (
    AuditEventKindClipboard = "clipboard"   // 文本/文件剪贴板
    AuditEventKindAlarm     = "alarm"       // 策略告警 / 异常断开
    AuditEventKindCmd       = "cmd"         // 服务端下发或客户端执行命令
    AuditEventKindRecord    = "record"      // 会话录像开始/结束
)

type AuditEvent struct {
    IdModel
    Kind        string `json:"kind"         gorm:"size:32;default:'';not null;index:idx_audit_event_kind_created,priority:1"`
    PeerId      string `json:"peer_id"      gorm:"size:64;default:'';not null;index"`
    FromPeer    string `json:"from_peer"    gorm:"size:64;default:'';not null;index"`
    FromName    string `json:"from_name"    gorm:"size:128;default:'';not null;"`
    SessionId   string `json:"session_id"   gorm:"size:64;default:'';not null;"`
    Ip          string `json:"ip"           gorm:"size:64;default:'';not null;"`
    PayloadJson string `json:"payload_json" gorm:"type:text;default:'';not null;"`
    TimeModel          // 提供 CreatedAt;复合索引 (kind, created_at) 通过 tag 拼接
}

type AuditEventList struct {
    AuditEvents []*AuditEvent `json:"list"`
    Pagination
}
```

复合索引在 `TimeModel.CreatedAt` 一侧通过 `gorm` tag 追加(因 `TimeModel` 不便改动,使用 `AfterMigrate` Hook 或在 `Migrate()` 中显式 `db.Exec`):

```go
// 在 rustdesk-api/cmd/apimain.go Migrate() 末尾(AutoMigrate 之后)追加:
global.DB.Exec("CREATE INDEX IF NOT EXISTS idx_audit_event_kind_created ON audit_events(kind, created_at)")
```

> SQLite 与 PostgreSQL 都支持 `CREATE INDEX IF NOT EXISTS`,无方言分支。MySQL 不支持 `IF NOT EXISTS`,但本项目 README/`config.yaml` 当前未声明 MySQL,延续 GORM 多方言原则在 `Migrate()` 中按 `global.DB.Dialector.Name()` 分支即可——**建议命名,可调整**。

### 4.2 SQL DDL (供 DBA 参考,与 AutoMigrate 等价)

SQLite 方言:

```sql
CREATE TABLE audit_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  kind         TEXT    NOT NULL DEFAULT '',
  peer_id      TEXT    NOT NULL DEFAULT '',
  from_peer    TEXT    NOT NULL DEFAULT '',
  from_name    TEXT    NOT NULL DEFAULT '',
  session_id   TEXT    NOT NULL DEFAULT '',
  ip           TEXT    NOT NULL DEFAULT '',
  payload_json TEXT    NOT NULL DEFAULT '',
  created_at   DATETIME,
  updated_at   DATETIME
);
CREATE INDEX IF NOT EXISTS idx_audit_event_peer_id      ON audit_events(peer_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_from_peer    ON audit_events(from_peer);
CREATE INDEX IF NOT EXISTS idx_audit_event_kind_created ON audit_events(kind, created_at);
```

PostgreSQL 方言:

```sql
CREATE TABLE audit_events (
  id           BIGSERIAL PRIMARY KEY,
  kind         VARCHAR(32)  NOT NULL DEFAULT '',
  peer_id      VARCHAR(64)  NOT NULL DEFAULT '',
  from_peer    VARCHAR(64)  NOT NULL DEFAULT '',
  from_name    VARCHAR(128) NOT NULL DEFAULT '',
  session_id   VARCHAR(64)  NOT NULL DEFAULT '',
  ip           VARCHAR(64)  NOT NULL DEFAULT '',
  payload_json TEXT         NOT NULL DEFAULT '',
  created_at   TIMESTAMP,
  updated_at   TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_audit_event_peer_id      ON audit_events(peer_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_from_peer    ON audit_events(from_peer);
CREATE INDEX IF NOT EXISTS idx_audit_event_kind_created ON audit_events(kind, created_at);
```

### 4.3 HTTP 请求/响应 JSON

`POST /api/audit/event`(未鉴权,与 `/api/audit/conn` 同段):

```json
{
  "kind": "clipboard",
  "peer_id": "123456789",
  "from_peer": "987654321",
  "from_name": "alice@office",
  "session_id": "8347598347",
  "ip": "10.0.0.5",
  "payload_json": "{\"size\":1234,\"format\":\"text\"}"
}
```

响应同既有 audit 端点:`response.Success(c, "")` 或 `response.Error(c, "...")`。

`GET /api/admin/audit_event/list`(管理员鉴权):

- Query: `page`, `page_size`, `kind`(精确匹配,留空表示全部),`peer_id`(模糊),`from_peer`(模糊)。
- Response:`response.Response{ data: AuditEventList }`,与 `AuditConnList` 同形(`controller/admin/audit.go:30-46`)。

`POST /api/admin/audit_event/delete`:body `{"id": <uint>}`(模型同 `AuditEvent`)。

`POST /api/admin/audit_event/batchDelete`:body `{"ids": [1,2,3]}`(`AuditEventLogIds`)。

### 4.4 Server-side 限制

- `payload_json` 在 controller 入口处 `len(form.PayloadJson) > 16*1024` 即返回 `response.Error(c, "ParamsError: payload too large")`。
- `kind` 必须命中白名单(常量集合);未命中返回 `ParamsError: unknown kind`。白名单允许未来扩展,新增 kind 等同改常量。

### 4.5 配置项

无新增 env / yaml key。沿用 `rustdesk-api/conf/config.yaml` 的 DB 配置。

## 5. 实现步骤

1. **建模型**:在 `rustdesk-api/model/audit.go:47` 末尾追加 §4.1 的 `AuditEvent` / `AuditEventList` / `AuditEventKind*`。
2. **接 AutoMigrate**:在 `rustdesk-api/cmd/apimain.go:303-309` 列表追加 `&model.AuditEvent{}`;在 `Migrate()` AutoMigrate 调用之后追加 `global.DB.Exec("CREATE INDEX IF NOT EXISTS idx_audit_event_kind_created ON audit_events(kind, created_at)")`(注意只在 SQLite/PostgreSQL 路径执行,通过 `global.DB.Dialector.Name()` 判定;MySQL 走 raw `CREATE INDEX` + 捕获 1061 错误)。
3. **写服务层**:在 `rustdesk-api/service/audit.go:95` 末尾追加 `CreateAuditEvent` / `AuditEventList(page,pageSize,where)` / `EventInfoById` / `DeleteAuditEvent` / `BatchDeleteAuditEvent`,完全镜像 `AuditConn` 系列(`service/audit.go:11-94`)。
4. **请求/表单**:在 `rustdesk-api/http/request/api/audit.go:78` 末尾追加 `AuditEventForm`,字段同 §4.3;实现 `ToAuditEvent() *model.AuditEvent` 以及 `Validate()`(白名单+大小校验);在 `rustdesk-api/http/request/admin/audit.go:7` 末尾追加 `AuditEventQuery{ Kind, PeerId, FromPeer; PageQuery }` 与 `AuditEventLogIds`。
5. **客户端 controller**:在 `rustdesk-api/http/controller/api/audit.go:85` 末尾追加 `func (a *Audit) AuditEvent(c *gin.Context)`,模仿 `AuditFile`(同文件第 71-84 行);先 `ShouldBindBodyWith` 解析,再 `Validate`,失败返 `ParamsError`,成功调用 service 创建并返回 `response.Success(c, "")`。
6. **后台 controller**:在 `rustdesk-api/http/controller/admin/audit.go:213` 末尾追加 `EventList` / `EventDelete` / `BatchEventDelete`,完整复用 `ConnList`/`ConnDelete`/`BatchConnDelete` 模板(同文件第 30-113 行)。`EventList` 内 where 闭包按 `kind` 等值过滤、`peer_id`/`from_peer` 走 `LIKE`。
7. **路由**:
   - `rustdesk-api/http/router/api.go:69-74` 内追加 `frg.POST("/audit/event", au.AuditEvent)`。
   - `rustdesk-api/http/router/admin.go:194-204` `AuditBind` 末尾追加:
     ```go
     aeR := rg.Group("/audit_event").Use(middleware.AdminPrivilege())
     aeR.GET("/list", cont.EventList)
     aeR.POST("/delete", cont.EventDelete)
     aeR.POST("/batchDelete", cont.BatchEventDelete)
     ```
8. **Swagger 注释**:为新 handlers 补 swag 注解,与 `controller/api/audit.go:17-25` / `controller/admin/audit.go:17-28` 风格一致(`@Tags 审计事件` 等)。后续 `make swag` 或 README 的 `swag init` 命令会重生成 `docs/api`、`docs/admin`。
9. **测试**:见 §6。
10. **文档**:更新 `docs/ai-development-plan.md` 任务卡末尾状态行(见 DoD)。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
| - | --- | --- | --- | --- |
| 1 | `rustdesk-api/service/audit_event_test.go` | `TestAuditService_CreateAndList` | 连续插入 3 条 `kind=clipboard` + 2 条 `kind=alarm` | `AuditEventList(1,10, where(kind=clipboard))` 返回 3 条,`Total=3`;`where=nil` 时返回 5 条。 |
| 2 | `rustdesk-api/service/audit_event_test.go` | `TestAuditService_BatchDeleteAuditEvent` | 插入 5 条,删除其中 3 个 id | 列表查询剩 2 条,被删除 id 通过 `EventInfoById` 返回 `Id=0`(zero value)。 |
| 3 | `rustdesk-api/http/controller/api/audit_event_test.go` | `TestAuditEventAPI_HappyPath` | `POST /api/audit/event` `{kind:"clipboard", peer_id:"1", payload_json:"{}"}` | HTTP 200,DB 中新增 1 条;`CreatedAt` 非零。 |
| 4 | `rustdesk-api/http/controller/api/audit_event_test.go` | `TestAuditEventAPI_PayloadTooLarge` | `payload_json` = 17KB 字符串 | HTTP 200 + `Response.Error`(包含 `ParamsError`),DB 中 0 条新记录。 |
| 5 | `rustdesk-api/http/controller/api/audit_event_test.go` | `TestAuditEventAPI_UnknownKind` | `kind:"randomstring"` | HTTP 200 + `Response.Error`,DB 中 0 条新记录。 |
| 6 | `rustdesk-api/http/controller/admin/audit_event_test.go` | `TestAdminAuditEventList_FilterByKind` | 预置 `clipboard`/`alarm` 各 2 条;`GET /api/admin/audit_event/list?kind=alarm` | 返回 2 条,`kind` 全部 = `alarm`,`Total=2`。 |
| 7 | `rustdesk-api/http/controller/admin/audit_event_test.go` | `TestAdminAuditEventList_BackwardCompat_NoKind` | 无 `kind` query | 返回所有事件,按 `id desc` 排序。 |
| 8 | `rustdesk-api/http/controller/api/audit_test.go`(已存在场景,新增/确认) | `TestAuditFile_StillWorks_AfterMigration` | 现有 `POST /api/audit/file` 调用 | 不受新表影响,仍写入 `audit_files`。**向后兼容用例**。 |

> 若仓库当前未引入 controller 级测试 harness,可在 step 1-2 的 service 层完成全部强校验,controller 层用 `httptest.NewRecorder` + `gin.New()` 走最小化集成测试。

## 7. 验证命令

按顺序执行(均在 `rustdesk-api/` 目录):

```bash
# 1. 依赖
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go mod tidy

# 2. 编译
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go build ./...

# 3. 单元测试(SQLite,默认配置)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go test ./service/... ./http/controller/... -run Audit -v

# 4. 生成 swagger(若改动了 swag 注释)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && swag init -g cmd/apimain.go -o docs/api      # 客户端 API
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && swag init -g cmd/apimain.go -o docs/admin    # 管理端 API
# 注:具体 swag 命令以仓库 Makefile/README 为准;如未安装 swag CLI,在 macOS dev box 可跳过 (CI 会再生成)。

# 5. 启动本地服务做手工 smoke
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go run ./cmd/apimain.go &
sleep 2
curl -sS -X POST http://127.0.0.1:21114/api/audit/event \
  -H 'Content-Type: application/json' \
  -d '{"kind":"clipboard","peer_id":"1","payload_json":"{}"}'
curl -sS 'http://127.0.0.1:21114/api/admin/audit_event/list?kind=clipboard&page=1&page_size=10' \
  -H "Authorization: Bearer <admin-token>"
kill %1

# 6. PostgreSQL 集成验证(可在 macOS dev box 跳过,理由:本地默认 SQLite;CI/远端环境需运行)
DB_TYPE=postgres DB_HOST=... go test ./service/... -run AuditEvent -v
```

可在 macOS dev box 跳过项:第 4 步(无 swag CLI 时)、第 6 步(无 PostgreSQL 实例)。其余必须通过。

## 8. 兼容性 / 安全注意事项

- **协议兼容**:本次不动 protobuf。`/api/audit/conn` `/api/audit/file` 表结构、字段、JSON 形状必须保持原样;CE-M1-7 客户端会按是否支持 `event` 端点降级回 `file` 端点。
- **老客户端**:不会调用 `/api/audit/event`,无影响。
- **老服务端 + 新客户端**:新客户端遇到 404 应静默降级(由 CE-M1-7 负责),本任务保留 file/conn 端点是关键。
- **迁移回滚**:`AutoMigrate` 只增表,不动既有列;回滚相当于 drop 新表(见 §9)。
- **payload_json 敏感数据**:
  - 服务端 **不解析** payload 内容,只做长度校验。
  - 客户端落盘前应对剪贴板内容做哈希 + 截断(由 CE-M1-7 实施),服务端不存原文。本卡在 swag 注释和 controller 注释中明确写出 “payload_json must not contain raw clipboard/file content; client must hash & truncate”。
  - 16KB 上限拒绝把整段剪贴板贴进来。
- **限流**:`/api/audit/event` 与 conn/file 一致暂走全局 gin 限流(若 README/`config.yaml` 有 `app.rate_limit` 项需复用)。如未来需要单端点限流,**建议命名,可调整** `app.rate_limit_audit_event_qps`。
- **鉴权**:`/api/audit/event` 维持未鉴权(与 conn/file 一致),依赖 RustDesk 网关侧 IP/UUID 白名单。**注意**:这是已知设计,不在本卡范围;若安全策略升级,统一在另一卡处理 conn/file/event 三者。
- **索引**:`(kind, created_at)` 复合索引保证按事件类型时间序查询时不会全表扫;新插入路径只多 1 行 + 1 索引维护,可忽略。

## 9. 回滚方案

1. **代码回滚**:`git revert <commit>` 撤掉本次改动。
2. **数据库回滚**:执行
   ```sql
   DROP INDEX IF EXISTS idx_audit_event_kind_created;
   DROP TABLE IF EXISTS audit_events;
   ```
   该表对老客户端/老逻辑无引用,直接 drop 不影响其他表/外键。
3. **配置回滚**:无配置变更,无需切换。
4. **临时降级**:如代码已上线但想临时关闭新端点而不重新部署,可在反向代理层屏蔽 `^/api/audit/event` 与 `^/api/admin/audit_event/`(返 404),客户端会按 §8 的降级规则继续走 file/conn。**建议命名,可调整** 一个 `app.audit_event_enabled` feature flag(默认 true),后续如需在代码层做开关再加。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-api/model/audit.go` 新增 `AuditEvent` 及常量、`AuditEventList`,字段、tag、索引名与 §4.1 一致。
- [ ] `rustdesk-api/cmd/apimain.go` 在 `AutoMigrate` 中包含 `&model.AuditEvent{}`,并在迁移后创建 `idx_audit_event_kind_created` 索引(SQLite/PostgreSQL 通过)。
- [ ] `rustdesk-api/service/audit.go` 新增 5 个方法,且不影响 `AuditConn`/`AuditFile` 旧方法(`go test ./service/... -run AuditConn` 与 `-run AuditFile` 仍全绿)。
- [ ] `POST /api/audit/event` 完成 kind 白名单、16KB 上限校验,Bad input 返回 `ParamsError`。
- [ ] `GET /api/admin/audit_event/list`、`POST /api/admin/audit_event/delete`、`POST /api/admin/audit_event/batchDelete` 三个后台端点上线,鉴权走 `BackendUserAuth` + `AdminPrivilege`。
- [ ] §6 中所有测试新建并通过(macOS dev box 默认 SQLite 路径)。
- [ ] `go build ./...` 通过;`go vet ./...` 无新增告警。
- [ ] swagger 注解补齐(若仓库当前 CI 跑 swag 检查,需重生成 `docs/api`、`docs/admin`)。
- [ ] 已运行 §7 第 5 步的 curl smoke,clipboard 与 alarm 各一次成功,过大 payload 被拒。
- [ ] 已确认 `/api/audit/file` 与 `/api/audit/conn` 端点+响应字段未变(可与 commit 前的 e2e 输出 diff)。
- [ ] 在 `docs/ai-development-plan.md` 的 CE-M1-6 任务卡末尾追加一行 `状态: 完成 (commit <hash>)`。
