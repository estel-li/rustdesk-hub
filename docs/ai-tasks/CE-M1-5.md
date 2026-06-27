# CE-M1-5 后台强制 MFA (user + group level)

## 1. 任务目标

为 `rustdesk-api` 增加"强制 MFA"策略:用户级与组级各持一个 `mfa_required` 开关,有效策略 = `group.mfa_required OR user.mfa_required`。后台提供 toggle 接口;一旦命中策略而账号尚未 enroll,登录响应必须返回 `mfa_required=true` 且附带 `enroll_required=true` 与短期 ticket,允许客户端通过 `POST /api/mfa/enroll-then-verify` 在同一登录会话内完成 enroll + 校验。管理员对任意账号关闭 MFA(包含强制位、清除 secret)必须落盘审计日志(`LoginLog` 或新增 audit entry)。

验收信号:`go test ./model ./service ./http/...` 全绿,且能通过 curl 复现 4 条流程 —— (a) 未强制未启用→旧流程通过;(b) 强制未启用→返回 enroll_required;(c) 强制已启用→走 CE-M1-3 的两步登录;(d) 管理员关闭目标用户 MFA,`login_logs` 表新增一条带 `type="mfa_disabled_by_admin"` 的记录。

## 2. 上下文与依赖

- 上游依赖任务卡
  - CE-M1-1 `user_mfa` 表(secret、recovery_codes、enabled_at)。
  - CE-M1-2 `service/mfa.go`(Enroll / Verify / ConsumeRecoveryCode / Disable)。
  - CE-M1-3 `/api/login` 两步状态机与 ticket JWT 签发逻辑。

- 下游会用到此输出的任务卡
  - CE-M1-4 客户端 API MFA UI:必须识别 `enroll_required` 分支并跳转 `POST /api/mfa/enroll-then-verify`。
  - CE-M1-6 审计事件扩展:可复用本卡新增的 `login_logs.type` 枚举值(如统一到 `AuditEvent` 则做映射)。
  - 文档 `docs/operations/2fa.md`(在 plan.md 391 行声明)。

- 关键背景事实(file:line)
  - `User` 模型当前字段集与 `IsAdmin *bool` 写法,见 `rustdesk-api/model/user.go:3-16` —— 新增 `MfaRequired *bool` 必须沿用 `*bool` 指针,否则 `gorm.Updates(u)` 在 `model/user.go service/user.go:261` 这种"传整结构体"路径会因为零值被忽略掉(可对比 `IsAdmin *bool` 的处理 `service/user.go:295-297`)。
  - `Group` 模型字段极简,见 `rustdesk-api/model/group.go:8-13`,需要新增同名字段 + 默认 0 + not null。
  - 现有用户管理接口在 `rustdesk-api/http/controller/admin/user.go:111-133`(`Update`)与 `:182-204`(`UpdatePassword`),走 `f.ToUser()` → `service.UserService.Update` 模式;`f.ToUser()` 见 `http/request/admin/user.go:32-44` —— 当前不包含 `MfaRequired`,需扩字段同步映射。
  - 路由分组在 `rustdesk-api/http/router/admin.go:75-95`(User)、`:97-107`(Group),全部走 `middleware.AdminPrivilege()`,toggle 路由要挂到这两组。
  - 登录入口 `rustdesk-api/http/controller/admin/login.go:67-100` 与 `responseLoginSuccess` `:236-242` —— 后台登录目前直接发 token;**注意** 计划文档明确两步登录是 `/api/login`(API 侧)而非 `/admin/login`(plan.md:279-281),所以 admin webadmin 端登录路径可保持原状,本卡的两段式仅作用于 `/api/login` 与新增 `/api/mfa/enroll-then-verify`。
  - 当前 `LoginLog.Type` 仅有 `account / oauth` 两个枚举,见 `model/loginLog.go:23-26` —— 需要追加 `mfa_required_set / mfa_disabled_by_admin` 等,审计落盘走 `DB.Create(&model.LoginLog{...})`(模式见 `service/user.go:108`)。
  - `DatabaseVersion = 265`(`rustdesk-api/cmd/apimain.go:26`)与 AutoMigrate 列表 `:291-309` —— CE-M1-1 已 bump 到 266,本卡再 bump 到 267,并在 `:268-285` 仿照 245/246 加 `if v.Version < 267` 分支补 `mfa_required` 默认值列。
  - `service/user.go:251-262` 当前 `Update` 用 `DB.Model(u).Updates(u)`,要避免误把"管理员调用 update"中漏传的 `mfa_required` 误置为 false。本卡应改成显式 select 字段 或 切换到 map[string]interface{},决定写在第 5 节。
  - `service/group.go:42-44` 同样使用 `DB.Model(u).Updates(u)`,存在同类风险。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|---|---|---|---|
| `rustdesk-api/model/user.go` | 修改 | +3 | 新增 `MfaRequired *bool` 字段(gorm 默认 0、not null、index)。 |
| `rustdesk-api/model/group.go` | 修改 | +2 | 新增 `MfaRequired *bool`,语义同上。 |
| `rustdesk-api/model/loginLog.go` | 修改 | +6 | 追加 `LoginLogTypeMfaRequiredSet / LoginLogTypeMfaRequiredUnset / LoginLogTypeMfaDisabledByAdmin / LoginLogTypeMfaEnrollForced` 常量。 |
| `rustdesk-api/cmd/apimain.go` | 修改 | +12 | `DatabaseVersion` 由 266 升至 267;在 DatabaseAutoUpdate 末段补 `if v.Version < 267` 兼容补列。 |
| `rustdesk-api/service/user.go` | 修改 | +40 | 新增 `EffectiveMfaRequired(u) bool`、`SetMfaRequired(u, bool, opUser, ip)`、`DisableMfa(u, opUser, ip, reason)`;`Update` 改成显式列更新避免覆盖 `mfa_required`。 |
| `rustdesk-api/service/group.go` | 修改 | +20 | 新增 `SetMfaRequired(g, bool, opUser, ip)`;`Update` 同样改显式列。 |
| `rustdesk-api/service/mfa.go` | 修改 | +15 | (依赖 CE-M1-2 已建文件)新增 `IsEnrolled(userId) bool` 供策略层调用;`Disable` 已存在则确保会同步删 `user_mfa` 行。 |
| `rustdesk-api/http/request/admin/user.go` | 修改 | +6 | `UserForm` 增 `MfaRequired *bool`;`FromUser` / `ToUser` 同步。新增 `MfaToggleForm`。 |
| `rustdesk-api/http/request/admin/group.go` | 修改 | +4 | `GroupForm` 增 `MfaRequired *bool`;新增 `GroupMfaToggleForm`。 |
| `rustdesk-api/http/controller/admin/user.go` | 修改 | +90 | 新增 `SetMfaRequired`、`DisableUserMfa` 两个 handler;Update 路径补审计落盘。 |
| `rustdesk-api/http/controller/admin/group.go` | 修改 | +50 | 新增 `SetMfaRequired` handler。 |
| `rustdesk-api/http/router/admin.go` | 修改 | +6 | `UserBind`/`GroupBind` 内追加 `POST /user/mfa/required`、`POST /user/mfa/disable`、`POST /group/mfa/required`。 |
| `rustdesk-api/http/controller/api/login.go` | 修改 | +40 | (CE-M1-3 已搭好两步)在密码校验通过后调用 `EffectiveMfaRequired`;若 required 且未 enrolled,签发带 `purpose=enroll` 的 ticket,响应增加 `enroll_required=true`。 |
| `rustdesk-api/http/controller/api/mfa.go` | 新建 | +80 | `POST /api/mfa/enroll-then-verify`:校验 enroll-purpose ticket → 调用 `MfaService.Enroll` → 立刻 `Verify(code)` → 成功后 `Login()` 返回正式 token。失败不消费 enroll。 |
| `rustdesk-api/http/router/api.go` | 修改 | +2 | 注册 `/api/mfa/enroll-then-verify`(若 CE-M1-3 未挂)。**未找到该文件请先 grep,未挂载需新建路由组**。 |
| `rustdesk-api/http/response/admin/loginPayload.go` | 修改 | +4 | `LoginPayload` 增 `MfaRequired bool` `EnrollRequired bool` `MfaTicket string`(omitempty)。**若路径名不同,以仓内 `adResp.LoginPayload` 引用为准**。 |
| `docs/operations/2fa.md` | 修改/新建 | +30 | 写清 enroll-then-verify 流程、强制策略矩阵、回滚步骤。若 CE-M1-2 已建则追加章节。 |
| `rustdesk-api/service/user_test.go` | 新建 | +60 | 单测覆盖 `EffectiveMfaRequired` 真值表。 |
| `rustdesk-api/http/controller/admin/user_test.go` | 新建 | +90 | handler 集成测试(httptest + sqlite)。 |

## 4. 数据契约

### 4.1 GORM 字段

```go
// model/user.go
type User struct {
    ...
    MfaRequired *bool `json:"mfa_required" gorm:"default:0;not null;index"`
    ...
}

// model/group.go
type Group struct {
    ...
    MfaRequired *bool `json:"mfa_required" gorm:"default:0;not null;index"`
    ...
}
```

`*bool` 与现有 `IsAdmin *bool`(`model/user.go:12`)一致,避免 GORM Updates 把零值视作未设置。

### 4.2 SQL DDL(自动迁移之外的手写补丁)

SQLite(`v.Version < 267` 分支,`cmd/apimain.go:268` 风格):

```sql
ALTER TABLE users ADD COLUMN mfa_required INTEGER NOT NULL DEFAULT 0;
ALTER TABLE `groups` ADD COLUMN mfa_required INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_users_mfa_required ON users(mfa_required);
CREATE INDEX IF NOT EXISTS idx_groups_mfa_required ON `groups`(mfa_required);
```

PostgreSQL:

```sql
ALTER TABLE users ADD COLUMN mfa_required BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE groups ADD COLUMN mfa_required BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_users_mfa_required ON users(mfa_required);
CREATE INDEX IF NOT EXISTS idx_groups_mfa_required ON groups(mfa_required);
```

MySQL(若部署使用,见 `cmd/apimain.go:221`):

```sql
ALTER TABLE users ADD COLUMN mfa_required TINYINT(1) NOT NULL DEFAULT 0, ADD INDEX idx_users_mfa_required(mfa_required);
ALTER TABLE `groups` ADD COLUMN mfa_required TINYINT(1) NOT NULL DEFAULT 0, ADD INDEX idx_groups_mfa_required(mfa_required);
```

### 4.3 HTTP 接口形状

`POST /api/admin/user/mfa/required`(管理员)

请求:
```json
{ "user_id": 12, "mfa_required": true }
```
响应:
```json
{ "code": 0, "msg": "", "data": null }
```

`POST /api/admin/user/mfa/disable`(管理员强制关闭某账号 MFA,清 secret + recovery)

请求:
```json
{ "user_id": 12, "reason": "user lost device" }
```

`POST /api/admin/group/mfa/required`

请求:
```json
{ "group_id": 3, "mfa_required": true }
```

`POST /api/login`(扩字段,CE-M1-3 基础上)

响应 enroll 分支:
```json
{
  "code": 0,
  "data": {
    "mfa_required": true,
    "enroll_required": true,
    "ticket": "<jwt purpose=enroll exp=300s>",
    "username": "alice"
  }
}
```

`POST /api/mfa/enroll-then-verify`

请求:
```json
{ "ticket": "<enroll-jwt>", "code": "123456" }
```
首次调用(还没拿 secret)需要支持两阶段:建议响应分两轮 —— 第一轮空 `code` 返回 `{ "secret": "...", "qr_png_b64": "..." }`;第二轮带 `code` 完成 enroll 并 verify,成功返回常规 `LoginPayload` 含 token + recovery_codes。

```json
// 第二轮 success
{
  "code": 0,
  "data": {
    "token": "...",
    "username": "alice",
    "recovery_codes": ["xxxx-xxxx", ...]
  }
}
```

`recovery_codes` 仅本次返回,后端 hash 存盘(语义来自 CE-M1-1 计划文档 plan.md:250)。

### 4.4 配置项(建议命名,可调整)

- `app.mfa.enroll_ticket_ttl`(秒,默认 300)—— 控制 enroll-purpose ticket 有效期。
- `app.mfa.force_enroll_on_required`(bool,默认 true)—— 若为 false,则强制策略命中 + 未 enroll 时直接拒绝登录(返回错误码 113 + i18n key `MfaEnrollRequired`),不走 enroll-then-verify 分支。文档化策略选择见 docs/operations/2fa.md。

## 5. 实现步骤

1. **模型字段 + 迁移** 修改 `model/user.go:3-16` 与 `model/group.go:8-13`,加 `MfaRequired *bool`;在 `cmd/apimain.go:26` 把 `DatabaseVersion` 改为 267,在 `:268-285` 的 if-chain 末尾追加 `if v.Version < 267 { ... }` 分支,按 §4.2 DDL 用 `db.Exec` 执行(根据 `global.Config.Gorm.Type` 走对应方言)。
2. **登录响应结构** 修改 `http/response/admin/loginPayload.go`(目录:`http/response/admin/`,文件由 `controller/admin/login.go:8` 的 `adResp` 引用),增加 `MfaRequired/EnrollRequired/MfaTicket` 字段(omitempty)。同时为 API 侧响应建一份对等结构(若与 admin 共用同一文件则复用)。
3. **EffectiveMfaRequired** 在 `service/user.go` 末尾新增 `func (us *UserService) EffectiveMfaRequired(u *model.User) bool`:取 `*u.MfaRequired` 或 group 表的同名字段(走 `GroupService.InfoById(u.GroupId)`);任一为 true 即 true。
4. **service.UserService.Update 修复** 把 `service/user.go:261` 改为显式列 `DB.Model(u).Select("username","email",...,"mfa_required").Updates(u)`;若改动面太大,可拆出 `UpdateProfile`/`SetMfaRequired` 两条路径。同样修 `service/group.go:42-44`。
5. **审计写盘** 新增辅助 `service/user.go::writeMfaAudit(opUser *model.User, target *model.User, action string, ip string)`,内部 `DB.Create(&model.LoginLog{UserId: opUser.Id, Type: action, Ip: ip, ...})`,引用 `service/user.go:108` 的写盘模式;`action` 取自 `model/loginLog.go` 新增常量。
6. **Admin handler:user toggle** 在 `http/controller/admin/user.go` 新增 `SetMfaRequired(c)` 与 `DisableUserMfa(c)`,从 `c.Get("curUser")` 取 op user(`service.UserService.CurUser`,`service/user.go:117`),写审计。Disable 时调用 `MfaService.Disable(userId)` 删除 `user_mfa` 行,并把 `users.mfa_required` 也置 false(避免立即触发再次 enroll)。
7. **Admin handler:group toggle** 在 `http/controller/admin/group.go` 新增 `SetMfaRequired(c)`,落审计记一条 `LoginLogTypeMfaRequiredSet` 并 `target_group_id` 放进 `LoginLog.Remark`(若无该字段,则直接 fmt 字符串到 `Ip` 是不合适的,改为复用 plan.md 的 audit_event 表 —— **建议先简方案**:写到 `LoginLog` 自有的 `Platform` 字段不合理;若 plan.md 中 CE-M1-6 尚未实施,**建议命名,可调整**:在 `LoginLog` 加 `Remark string`(向后兼容)字段,或临时把 group 操作改为 stdout `Logger.Info` + DB 落 `AuditConn`-like 行,待 CE-M1-6 落地后归一。本卡先用 `Logger.Info` + 用户级 `LoginLog`,group 级仅日志)。
8. **路由注册** 修改 `http/router/admin.go:85-94` 的 `UserBind`(`aRP` 分支)追加:
   - `aRP.POST("/mfa/required", cont.SetMfaRequired)`
   - `aRP.POST("/mfa/disable", cont.DisableUserMfa)`
   修改 `:97-107` `GroupBind` 追加 `aR.POST("/mfa/required", cont.SetMfaRequired)`。
9. **API 登录分支** 修改 `http/controller/api/login.go`(CE-M1-3 增改的两步状态机):密码 OK 后调用 `EffectiveMfaRequired`;若 true 且 `MfaService.IsEnrolled(u.Id) == false`:
   - 当 `config.App.Mfa.ForceEnrollOnRequired = true`,签发 `purpose=enroll` 的 ticket(复用 CE-M1-3 的 ticket 签发函数,但增加 `purpose` claim),响应 `enroll_required=true`;
   - 否则直接 `response.Fail(c, 113, "MfaEnrollRequired")`。
10. **新增 `/api/mfa/enroll-then-verify`** 新建 `http/controller/api/mfa.go`(若 CE-M1-2/CE-M1-3 已建则追加 handler):
    - 校验 ticket 签名、`purpose == "enroll"`、未过期、绑定的 user_id 与 client_ip 一致;
    - body 无 `code`:走 `MfaService.Enroll(userId)` 返回 secret + qr_png_b64(secret 暂存到内存或绑定 ticket id,避免落库);
    - body 有 `code`:`MfaService.VerifyEnroll(userId, code)` 通过后正式落 `user_mfa` 行(`enabled_at = now`),生成 recovery_codes 一次性返回,然后 `UserService.Login` 发正式 token;失败保留 enroll 状态,允许重试,3 次失败后失效 ticket。
11. **测试** 见 §6。
12. **文档** 在 `docs/operations/2fa.md` 增 "强制 MFA 策略矩阵" 与 "管理员关闭 MFA 审计" 两节;在 `docs/ai-development-plan.md` 第 308 行任务卡末尾追加 `状态: 完成 (commit <hash>)`。

## 6. 测试用例

| # | 文件 | 测试名 | 输入 | 期望 |
|---|---|---|---|---|
| 1 | `rustdesk-api/service/user_test.go` | `TestEffectiveMfaRequired_UserOnly` | user.mfa_required=true, group.mfa_required=false | true |
| 2 | 同上 | `TestEffectiveMfaRequired_GroupOnly` | user=false, group=true | true |
| 3 | 同上 | `TestEffectiveMfaRequired_Both` | 都 true | true |
| 4 | 同上 | `TestEffectiveMfaRequired_Neither` | 都 false | false |
| 5 | 同上 | `TestEffectiveMfaRequired_NilUserPointer` | user.MfaRequired=nil | 视为 false,不 panic(回归) |
| 6 | `rustdesk-api/http/controller/admin/user_test.go` | `TestSetMfaRequired_NonAdminForbidden` | 非 admin token POST /admin/user/mfa/required | 401/403 |
| 7 | 同上 | `TestSetMfaRequired_OK` | admin POST `{user_id:2, mfa_required:true}` | DB user.mfa_required=true 且 login_logs 多一条 `mfa_required_set` |
| 8 | 同上 | `TestDisableUserMfa_WritesAudit` | admin 对已 enroll 用户调用 disable | user_mfa 行被删 + login_logs 增 `mfa_disabled_by_admin` |
| 9 | `rustdesk-api/http/controller/api/login_test.go` | `TestLogin_ForcedNotEnrolled_ReturnsEnrollRequired` | user.mfa_required=true, 无 user_mfa 行 | 响应含 `enroll_required:true, ticket: <jwt>` |
| 10 | 同上 | `TestLogin_NotForced_LegacyResponse` | 默认账号 | 响应与历史一致,无 `mfa_required` 字段或为 false(向后兼容) |
| 11 | 同上 | `TestEnrollThenVerify_WrongCode_KeepsTicket` | 第二轮 code 错误 | 401,ticket 仍可重试 ≤3 次 |

## 7. 验证命令

```bash
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api
go build ./...
go vet ./...
go test ./model ./service ./http/...
# 启动本地 API(macOS dev box 可执行)
RUSTDESK_API_DB_TYPE=sqlite go run ./cmd/apimain.go &
API_PID=$!

# 准备:把 user_id=2 设为强制 MFA(假设 token 为已知 admin token)
curl -X POST http://127.0.0.1:21114/api/admin/user/mfa/required \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"user_id":2,"mfa_required":true}'

# 登录触发 enroll_required
curl -X POST http://127.0.0.1:21114/api/login \
  -d '{"username":"u2","password":"xxx"}'

# 关闭 MFA,检查审计
curl -X POST http://127.0.0.1:21114/api/admin/user/mfa/disable \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"user_id":2,"reason":"lost device"}'
sqlite3 conf/db.sqlite3 'select type, user_id, created_at from login_logs order by id desc limit 5;'

kill $API_PID
```

- macOS dev box 上 sqlite/curl 步骤均可执行,无需跳过。
- 如果 dev box 没装 PostgreSQL/MySQL,DDL 兼容性靠 §6 之外的 CI 跑,**可在本机跳过**多方言执行,但必须 `go test` 通过。

## 8. 兼容性 / 安全注意事项

- Protobuf 兼容:不涉及 .proto,但 admin 后台增加字段需要保证旧前端反序列化忽略未知字段(Gin JSON 默认忽略,OK)。
- 老客户端 / 老服务端互通:登录响应新增 `mfa_required` / `enroll_required` / `ticket` 字段必须 `omitempty`,旧客户端按 plan.md:290-291 要求"未启用 MFA 用户响应不破坏旧客户端"。在第 9 步,如果 `EffectiveMfaRequired=false`,响应体不能携带这三个字段。
- 数据库迁移回滚:补列改 `DEFAULT 0/FALSE`,旧二进制能够无视该列正常 SELECT 列出(GORM 用结构体字段名);回滚见 §9。
- 敏感字段不落盘:本卡的 enroll ticket 只放 JWT(签名+短 TTL),后端无需新表;`recovery_codes` 仅 hash 存(CE-M1-1 约定),日志/审计禁止打印 secret 或明文 code。
- 限流:`/api/mfa/enroll-then-verify` 必须复用 `global.LoginLimiter`(`controller/admin/login.go:39`)对 client IP 计数,**否则攻击者可暴力刷 TOTP**。建议每个 ticket 内部允许 3 次尝试,过后视为登录失败计入 limiter。
- 审计落盘失败必须降级为 `Logger.Error` 而不能阻塞业务路径,但需返回 5xx 让管理员知晓(避免静默)。
- 管理员关闭 MFA(disable)与下调 `mfa_required` 必须区分两个常量,前者会清掉 secret(强动作),后者只是把策略位置 false,不会丢已 enroll 的因子。
- 自我保护:禁止用户对自己执行 `/admin/user/mfa/disable`(防止管理员误操作锁死);用 `if opUser.Id == target.Id && opUser.IsAdmin` 拒绝。

## 9. 回滚方案

1. 切回上一个 commit。
2. 数据库列保留(SQLite/PostgreSQL/MySQL 多出一个 `mfa_required` 列对旧二进制无影响,GORM 不会因为多列报错)。如果一定要清:
   ```sql
   -- 仅在确认无生产数据依赖时执行
   UPDATE users SET mfa_required = 0;
   UPDATE groups SET mfa_required = 0;
   -- 可选物理删列(PostgreSQL):
   ALTER TABLE users DROP COLUMN mfa_required;
   ALTER TABLE groups DROP COLUMN mfa_required;
   ```
3. 把 `cmd/apimain.go:26` 的 `DatabaseVersion` 改回 266,并删除 `if v.Version < 267` 分支。
4. Feature flag 维度:可不删代码,只把 `app.mfa.force_enroll_on_required` 设 false 并把 `users.mfa_required`/`groups.mfa_required` 全部 reset 到 0,即可在保留代码的情况下回归旧行为。

## 10. 完成定义 (DoD)

- [ ] `model/user.go` 与 `model/group.go` 增加 `MfaRequired *bool` 字段并通过 `go vet`。
- [ ] `cmd/apimain.go` 的 `DatabaseVersion` 升至 267 且补 `if v.Version < 267` 兼容分支(覆盖 SQLite / PostgreSQL / MySQL 三方言)。
- [ ] `service.UserService.EffectiveMfaRequired` 实现并通过 §6 单测 1-5。
- [ ] 管理员路由 `POST /api/admin/user/mfa/required`、`POST /api/admin/user/mfa/disable`、`POST /api/admin/group/mfa/required` 已注册并被 `AdminPrivilege()` 中间件保护。
- [ ] `service.UserService.Update` 与 `service.GroupService.Update` 已改为显式列更新,旧调用方测试通过。
- [ ] 登录响应:未强制时 payload 不含新字段(向后兼容测试 10 通过);强制未 enroll 时返回 `enroll_required + ticket`。
- [ ] `/api/mfa/enroll-then-verify` 完整 2 段流程通过测试 11 与手工 curl 验证。
- [ ] 管理员关闭 MFA / 设置强制位时,`login_logs` 新增带新枚举的记录;禁止 admin 关掉自己 MFA。
- [ ] `docs/operations/2fa.md` 含强制策略矩阵与回滚说明。
- [ ] `go test ./model ./service ./http/...` 全绿。
- [ ] 在 `docs/ai-development-plan.md` 的对应任务卡末尾追加 `状态: 完成 (commit <hash>)`。
