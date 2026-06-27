# CE-M1-2 MFA service (TOTP enroll/verify/recovery)

## 1. 任务目标

在 `rustdesk-api/service` 下新增 `MfaService`,围绕 `github.com/pquerna/otp/totp` 提供 enroll / verify / recovery-code 全套流程,作为 CE-M1-3 两步登录状态机和 CE-M1-5 强制 MFA 的底层依赖。**验收信号**: `cd rustdesk-api && go test ./service -run TestMfa` 通过,覆盖正确 TOTP、错误 TOTP、未启用、recovery 一次性消费、disable 等 case;`go vet ./...` 与 `go build ./...` 通过。原始任务卡见 `docs/ai-development-plan.md:260-274`。

> 任务卡接口建议(verbatim,见 `docs/ai-development-plan.md:267-271`):
> - `Enroll(userId uint) (secret string, qrPNG []byte, err error)`
> - `Verify(userId uint, code string) (bool, error)`
> - `GenerateRecoveryCodes(userId uint) ([]string, error)`
> - `ConsumeRecoveryCode(userId uint, code string) (bool, error)`

## 2. 上下文与依赖

- **上游依赖任务卡**
  - CE-M1-1 `数据模型:user_mfa` — 必须先落地 `model.UserMfa`(字段 `user_id` / `secret` / `recovery_codes` JSON / `enabled_at` / `last_used_at` / `created_at` / `updated_at`,见 `docs/ai-development-plan.md:241-251`)并把 `DatabaseVersion` 从 265 升到 266(当前值见 `rustdesk-api/cmd/apimain.go:26`)。
  - CE-M0 系列加密/审计基础设施(若需要 secret 落库加密)。
- **下游会用到此输出的任务卡**
  - CE-M1-3 两步登录状态机(`docs/ai-development-plan.md:276-291`),调用 `Verify` 与 `ConsumeRecoveryCode`。
  - CE-M1-4 客户端 API MFA UI(`docs/ai-development-plan.md:293-306`),通过 HTTP 间接消费本服务。
  - CE-M1-5 后台强制 MFA(`docs/ai-development-plan.md:308-316`),调用 `IsEnrolled` / `Disable`。
  - CE-M1-6 审计扩展(`docs/ai-development-plan.md:318-338`)记录 enroll/disable/recovery 事件。
- **关键背景事实**
  - `Service` 聚合结构体在 `rustdesk-api/service/service.go:12-27` 通过匿名嵌入注入各子服务;新增 `*MfaService` 必须加在此处,初始化由 `service.New` (`service/service.go:45-53`) 完成。
  - 全局变量 `DB` / `Logger` / `Config` / `Lock` 在 `service/service.go:37-41` 暴露,`MfaService` 直接复用,无需独立持有句柄。
  - 错误哨兵命名约定参见 `service/ldap.go:22-31`(`ErrLdapNotEnabled` 等)— 本任务遵循同样的 `var (... = errors.New("..."))` 风格。
  - 现有 `utils.RandomString` (`rustdesk-api/utils/tools.go:67-80`) 使用 `crypto/rand` 但字符表是 `[a-zA-Z0-9]`,**不可直接用于 recovery code**(任务卡要求 base32)。需在 `utils/` 新增 base32 helper 或在 `service/mfa.go` 内联。
  - `utils.EncryptPassword` / bcrypt 流程(`rustdesk-api/utils/password.go:10-16`)是 recovery code 单向 hash 的现成方案。
  - 项目 `go.mod` (`rustdesk-api/go.mod`) 当前未引入 `github.com/pquerna/otp`;CE-M1-2 需要 `go get github.com/pquerna/otp@v1.4.0`(v1.x 最新稳定)。该包传递依赖 `github.com/boombuler/barcode`。
  - TOTP issuer/account 命名约定:本仓库无现成"应用名"配置,`config.Admin.Title` (`rustdesk-api/config/config.go:28`) 用作后台标题,但可能为空。**建议命名,可调整**:issuer 取 `Config.Admin.Title`,空则回退 `"RustDesk API"`;account 取 `user.Username`(若 `user.Email` 非空则用 email,符合大多数 Authenticator 的展示习惯)。
  - `cmd/apimain.go:213-266` 已有 AutoMigrate + 手写 migration 流程,新表由 CE-M1-1 负责;本任务不直接动 migration。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|---|---|---|---|
| `rustdesk-api/service/mfa.go` | 新建 | 约 260 行 | `MfaService` 主体:Enroll / Verify / GenerateRecoveryCodes / ConsumeRecoveryCode / Disable / IsEnrolled,以及 issuer/account 拼装、QR 渲染。 |
| `rustdesk-api/service/mfa_test.go` | 新建 | 约 220 行 | 单元测试,使用 sqlite 内存库 + `service.New`。 |
| `rustdesk-api/service/service.go` | 修改 | +2 行 | 在 `Service` 结构体匿名嵌入 `*MfaService`(参照 `service/service.go:12-27`)。 |
| `rustdesk-api/utils/totp.go` | 新建 | 约 80 行 | base32 recovery code 生成器 + hash helper;隔离 `crypto/rand` 失败路径以便测试。 |
| `rustdesk-api/utils/totp_test.go` | 新建 | 约 60 行 | recovery code 形状、唯一性、hash 验证测试。 |
| `rustdesk-api/go.mod` | 修改 | +2 行 | 新增 `github.com/pquerna/otp v1.4.0`(及传递依赖 `github.com/boombuler/barcode`)。 |
| `rustdesk-api/go.sum` | 修改 | 自动 | `go mod tidy` 产物。 |
| `rustdesk-api/model/user_mfa.go` | 依赖,不在本卡内修改 | — | 由 CE-M1-1 创建;本卡只引用其字段。若 CE-M1-1 未完成,本卡 §3 标注 **未找到,需先完成 CE-M1-1**。 |

## 4. 数据契约

### 4.1 错误哨兵(`service/mfa.go` 顶部)

```go
var (
    ErrMfaNotEnrolled    = errors.New("MfaNotEnrolled")
    ErrMfaAlreadyEnrolled = errors.New("MfaAlreadyEnrolled")
    ErrMfaInvalid        = errors.New("MfaInvalid")
    ErrMfaRecoveryUsed   = errors.New("MfaRecoveryUsed")
    ErrMfaUserNotFound   = errors.New("MfaUserNotFound")
)
```
风格对齐 `service/ldap.go:22-31`。

### 4.2 `MfaService` 方法签名(verbatim)

```go
type MfaService struct{}

// Enroll 生成 TOTP secret 并返回 otpauth:// URL 渲染出的 PNG 二维码。
// 若用户已 enabled,返回 ErrMfaAlreadyEnrolled。
// 此时仅落库 secret + 状态 pending(enabled_at 为 0),需要后续调用 Verify 完成激活。
func (s *MfaService) Enroll(userId uint) (secret string, qrPNG []byte, err error)

// Verify 校验 TOTP code (RFC6238, 6 位, period=30s, skew=±1 step)。
// 若 user_mfa 记录处于 pending(enabled_at==0),首次 Verify 成功后将其激活(写 enabled_at=now)。
// 返回 (false, nil) 表示 code 错误;返回 (false, ErrMfaNotEnrolled) 表示用户未 enroll。
// 成功时更新 last_used_at。
func (s *MfaService) Verify(userId uint, code string) (bool, error)

// GenerateRecoveryCodes 生成 12 条 10 字符 base32 recovery code(无填充),
// 将 bcrypt(code) 数组以 JSON 写入 user_mfa.recovery_codes 字段(覆盖旧值)。
// 仅在用户已 enrolled (enabled_at>0) 时允许调用,否则返回 ErrMfaNotEnrolled。
// 返回明文 codes,由调用方负责仅向用户展示一次。
func (s *MfaService) GenerateRecoveryCodes(userId uint) ([]string, error)

// ConsumeRecoveryCode 比对 code 与已存 hash;命中则把该 hash 从数组中移除并落库,返回 (true, nil)。
// 已被消费或不在列表:返回 (false, ErrMfaRecoveryUsed)。
// 未 enroll: 返回 (false, ErrMfaNotEnrolled)。
func (s *MfaService) ConsumeRecoveryCode(userId uint, code string) (bool, error)

// Disable 删除 user_mfa 记录(物理删除)。无对应记录返回 ErrMfaNotEnrolled。
func (s *MfaService) Disable(userId uint) error

// IsEnrolled 仅当 user_mfa 记录存在且 enabled_at>0 时返回 true。
func (s *MfaService) IsEnrolled(userId uint) bool
```

### 4.3 TOTP otp.Key 生成参数

调用 `totp.Generate(totp.GenerateOpts{...})`:
- `Issuer`: `Config.Admin.Title`,为空回退 `"RustDesk API"`(建议命名,可调整;后续 CE-M1-5 强制 MFA 时可独立成 `Config.App.MfaIssuer`)。
- `AccountName`: `user.Email` 非空则取 email,否则取 `user.Username`。
- `Period`: 30(默认)。
- `SecretSize`: 20(160-bit,RFC6238 推荐)。
- `Digits`: `otp.DigitsSix`。
- `Algorithm`: `otp.AlgorithmSHA1`(兼容 Google Authenticator / 1Password / Authy)。

### 4.4 QR PNG 渲染

```go
img, err := key.Image(256, 256) // image.Image
var buf bytes.Buffer
_ = png.Encode(&buf, img)
qrPNG = buf.Bytes()
```
`key.Image` 由 `github.com/pquerna/otp` 提供;`image/png` 来自标准库。Content-Type 由上层 HTTP 层设置 `image/png`。

### 4.5 Recovery code 生成(`utils/totp.go`)

```go
// 12 条,每条 10 字符,字符集 RFC4648 base32 (A-Z2-7),无 padding。
// 使用 crypto/rand 取 8 字节熵,再 base32.StdEncoding.WithPadding(NoPadding).EncodeToString,
// 截断到前 10 字符(8 字节 = 16 base32 字符,取前 10 即可)。
func GenerateRecoveryCodes(count, length int) ([]string, error)

// 单向 hash 使用 bcrypt(cost=10),复用 utils.EncryptPassword 模式。
func HashRecoveryCode(code string) (string, error)
func VerifyRecoveryCode(hash, code string) bool
```

### 4.6 user_mfa 存储格式(由 CE-M1-1 落库,本卡读写)

预期字段(参考 `docs/ai-development-plan.md:241-251`):
- `secret` TEXT — 明文 base32 TOTP secret(若 CE-M0 提供加密 helper 则加密,否则采用现有敏感字段处理方式)。
- `recovery_codes` TEXT — JSON 数组,元素是 bcrypt hash 字符串,例如 `["$2a$10$...","$2a$10$..."]`。
- `enabled_at` INTEGER — Unix 秒;0 表示 pending。
- `last_used_at` INTEGER — Unix 秒。

### 4.7 配置项

无新增 yaml key;沿用 `Config.Admin.Title`。**可选增项(建议命名,可调整,留待 CE-M1-5 决定)**:`app.mfa-issuer`、`app.mfa-recovery-count`、`app.mfa-recovery-length`。

## 5. 实现步骤

1. **拉取依赖** — 在 `rustdesk-api/` 目录执行 `go get github.com/pquerna/otp@v1.4.0 && go mod tidy`;确认 `go.mod` 出现 `github.com/pquerna/otp v1.4.0` 与 `github.com/boombuler/barcode v0.0.0-...`(后者可能为 indirect)。
2. **新增 `utils/totp.go`** — 写 `GenerateRecoveryCodes(count, length int) ([]string, error)`、`HashRecoveryCode`、`VerifyRecoveryCode`。`crypto/rand` 错误路径直接返回 error(不要静默返回空字符串,区别于 `utils/tools.go:67-80` 的旧行为)。
3. **新增 `utils/totp_test.go`** — 测试: (a) `GenerateRecoveryCodes(12, 10)` 返回 12 条、每条 10 字符、字符全部 ∈ `[A-Z2-7]`;(b) 12 条之间互不相同;(c) `VerifyRecoveryCode(HashRecoveryCode(c), c) == true`,大小写敏感。
4. **修改 `service/service.go`** — 在 `Service` 结构体(`service/service.go:12-27`)增加一行 `*MfaService`,保持嵌入顺序紧邻 `*UserService` 之后,便于阅读;无需修改 `service.New`(嵌入字段零值即可直接调用方法)。
5. **新增 `service/mfa.go`** —
   - 顶部声明 §4.1 错误哨兵。
   - 私有 helper `loadOrCreate(userId uint) (*model.UserMfa, error)`、`save(*model.UserMfa) error`。
   - `Enroll`: 先 `Lock.Lock("mfa:enroll:" + strconv.FormatUint(uint64(userId),10))`,`defer Lock.UnLock`(参考 `service/user.go:322-323` 的用法)。查询 user(`UserService.InfoById`,见 `service/user.go:20-24`);若不存在返回 `ErrMfaUserNotFound`。查询既有 user_mfa;若 `enabled_at>0` 返回 `ErrMfaAlreadyEnrolled`。调用 `totp.Generate` → 渲染 PNG → upsert user_mfa(secret 落库,enabled_at=0,recovery_codes 暂空 `"[]"`)。
   - `Verify`: 查 user_mfa,无记录返回 `(false, ErrMfaNotEnrolled)`。`totp.ValidateCustom(code, secret, time.Now(), totp.ValidateOpts{Period:30, Skew:1, Digits:otp.DigitsSix, Algorithm:otp.AlgorithmSHA1})`。成功:若 `enabled_at==0` 写入 `time.Now().Unix()`;无论新旧,更新 `last_used_at`。
   - `GenerateRecoveryCodes`: 校验 `IsEnrolled`;否则 `ErrMfaNotEnrolled`。生成 12×10 base32 → bcrypt hash 数组 → `json.Marshal` → 写入。返回明文 codes 切片。
   - `ConsumeRecoveryCode`: 同样加锁。读取 user_mfa;反序列化 `recovery_codes`;线性扫描调用 `VerifyRecoveryCode`,命中即从数组移除、重新 `json.Marshal` 落库,返回 `(true, nil)`;未命中返回 `(false, ErrMfaRecoveryUsed)`。
   - `Disable`: 物理 `DB.Where("user_id = ?", userId).Delete(&model.UserMfa{})`;`RowsAffected==0` 返回 `ErrMfaNotEnrolled`。
   - `IsEnrolled`: 单查询 `Select("enabled_at")` + 判 `>0`。
6. **新增 `service/mfa_test.go`** — 使用与 `service/app_test.go`(`service/app_test.go:1-33`)类似的轻量风格,但需要一个 `setupTestService(t)` helper:打开 sqlite `:memory:` → `AutoMigrate(&model.User{}, &model.UserMfa{})` → 调用 `service.New(...)`,然后造一个 user。每个测试用 `t.Cleanup` 清表。
7. **跑测试 + go vet + go build** — 见 §7。
8. **更新 docs** — 完成后在 `docs/ai-development-plan.md` 第 260 行的 CE-M1-2 卡末尾追加状态行(见 §10)。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|---|---|---|---|
| 1 | `rustdesk-api/service/mfa_test.go` | `TestMfa_EnrollHappyPath` | 已有 user, 首次调用 `Enroll(u.Id)` | 返回非空 secret(20 字节 base32, 32 字符),qrPNG 长度 >0 且前 8 字节为 `\x89PNG\r\n\x1a\n`,user_mfa 记录存在且 enabled_at==0。 |
| 2 | `rustdesk-api/service/mfa_test.go` | `TestMfa_VerifyCorrectCodeActivates` | Enroll 后用 `totp.GenerateCode(secret, time.Now())` 生成 code,调用 `Verify` | 返回 `(true, nil)`;再次查 user_mfa,`enabled_at>0`,`last_used_at>0`。 |
| 3 | `rustdesk-api/service/mfa_test.go` | `TestMfa_VerifyWrongCode` | Enroll 后传入 `"000000"` | 返回 `(false, nil)`,`enabled_at` 仍为 0。 |
| 4 | `rustdesk-api/service/mfa_test.go` | `TestMfa_VerifyNotEnrolled` | 未 Enroll 的 user_id 调用 `Verify` | 返回 `(false, ErrMfaNotEnrolled)`。 |
| 5 | `rustdesk-api/service/mfa_test.go` | `TestMfa_RecoveryCodeShapeAndOneTime` | 已激活的 user,`GenerateRecoveryCodes` 后取第 0 条调用 `ConsumeRecoveryCode` 两次 | 第一次 `(true, nil)`;第二次 `(false, ErrMfaRecoveryUsed)`;`Generate` 返回切片长度==12,每条 len==10。 |
| 6 | `rustdesk-api/service/mfa_test.go` | `TestMfa_RecoveryCodeBeforeEnrollRejected` | 仅 Enroll 未 Verify 时调用 `GenerateRecoveryCodes` | 返回 `ErrMfaNotEnrolled`。 |
| 7 | `rustdesk-api/service/mfa_test.go` | `TestMfa_AlreadyEnrolled` | 已激活 user 再次 `Enroll` | 返回 `ErrMfaAlreadyEnrolled`,secret/qrPNG 为零值。 |
| 8 | `rustdesk-api/service/mfa_test.go` | `TestMfa_DisableThenReEnroll` | 激活 → `Disable` → 再 `Enroll` | `Disable` 返回 nil;后续 `IsEnrolled` 为 false;再 `Enroll` 成功并产生**新的** secret(与旧 secret 不等)。覆盖向后兼容:旧 secret 不复用。 |
| 9 | `rustdesk-api/service/mfa_test.go` | `TestMfa_ExpiredCodeRejected` | Enroll 激活后用 `totp.GenerateCode(secret, time.Now().Add(-5*time.Minute))` | 返回 `(false, nil)`(超过 skew=1 的容忍窗)。 |
| 10 | `rustdesk-api/utils/totp_test.go` | `TestGenerateRecoveryCodes_Shape` | `GenerateRecoveryCodes(12, 10)` | len==12;每条 len==10;每字符 ∈ `A-Z2-7`;12 条互不相同。 |
| 11 | `rustdesk-api/utils/totp_test.go` | `TestRecoveryCodeHashRoundtrip` | 任取 code → hash → verify | `VerifyRecoveryCode(hash, code)==true`;`VerifyRecoveryCode(hash, code+"X")==false`。 |

覆盖维度:happy path (#1, #2, #5);失败模式 (#3, #4, #7, #9);向后兼容 (#8,Disable→重 Enroll 不复用旧 secret)。

## 7. 验证命令

按顺序执行(均在 `rustdesk-api/` 目录):

```bash
# 1. 依赖
go mod tidy

# 2. 编译
go build ./...

# 3. 静态检查
go vet ./...

# 4. 单元测试(关键)
go test ./service -run TestMfa -v
go test ./utils  -run TestGenerateRecoveryCodes -v
go test ./utils  -run TestRecoveryCodeHashRoundtrip -v

# 5. 全量回归
go test ./...
```

macOS dev 盒子可全部本地执行;无需跳过。`go test ./...` 若在缺少 Docker 的环境里碰到 `service/oauth*` 集成测试,可改用 `go test ./service -short` 缩短(本任务新增测试不依赖外部资源)。

## 8. 兼容性 / 安全注意事项

- **Protobuf 兼容**:本任务不动 proto。CE-M1-3 才会增加 `mfa_required` / `ticket` 字段,需保证旧客户端忽略未知 JSON 字段(`encoding/json` 默认行为)。
- **老客户端/老服务端互通**:本卡只新增服务端能力,未启用 MFA 的用户不受影响;CE-M1-3 上线前任何前端不会感知 `mfa_required`。
- **数据库迁移回滚**:本任务**不动迁移**;迁移在 CE-M1-1。但本卡的代码必须在 `user_mfa` 表不存在时优雅退化—在 `MfaService` 任意方法入口若 `DB.Migrator().HasTable(&model.UserMfa{}) == false`,直接返回 `ErrMfaNotEnrolled`(防止 panic)。
- **敏感字段不落盘**:
  - TOTP secret 落库为 base32 明文 + 由 CE-M1-1 决定是否再加密;**禁止**写入日志,`Logger.Errorf` 输出 secret 必须用 `***`。
  - Recovery code 明文仅在 `Enroll`/`GenerateRecoveryCodes` 返回值内出现,**不要** `Logger` 打印,**不要**回写数据库;落库只存 bcrypt hash。
  - QR PNG 包含 secret;HTTP 层(CE-M1-3/4)必须设置 `Cache-Control: no-store`,不可写入文件。
- **限流**:`Verify` 错误应被上层 limiter 计入,参考 `service/user.go:97` 周边的 `Login` 流程与 `utils.LoginLimiter`(`rustdesk-api/utils/login_limiter.go`)。本卡接口不直接调用 limiter,但需在 godoc 注释里提示调用方。
- **时间同步**:`totp.ValidateCustom` 使用服务器时钟;若集群时钟漂移 > 30s 会导致全员 MFA 失败。文档化 `chronyd` / `ntpd` 要求(留给 CE-M1-10 运维文档)。
- **base32 字母表**:RFC4648 base32,**不含** `0/1/8/9/O/I`,降低手抄歧义;`crypto/rand` 失败必须返回 error,严禁回退到 `math/rand`。
- **并发**:`Enroll` / `ConsumeRecoveryCode` 使用 `Lock.Lock(...)` per-user 串行化(参考 `service/user.go:322-323`),避免双发 enroll 或并发消费同一 recovery code。

## 9. 回滚方案

- 本卡为纯新增,回滚路径:
  1. `git revert <commit>` 删除 `service/mfa.go` / `service/mfa_test.go` / `utils/totp*.go` 与 `service/service.go` 中嵌入 `*MfaService` 的那一行。
  2. `go mod tidy` 移除 `github.com/pquerna/otp` 依赖(若 CE-M1-3 已合并则保留)。
  3. 数据库 `user_mfa` 表保留(由 CE-M1-1 管理,不在本卡回滚范围)。
- 无 feature flag(代码未被任何路由引用,等价于功能未启用);若上层 CE-M1-3 已经接线,通过环境变量 `RUSTDESK_API_APP_MFA_ENABLED=false`(**建议命名,可调整**,留待 CE-M1-3 决定)强制走旧登录分支。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-api/service/mfa.go` 实现 §4.2 全部 6 个方法,签名与文档一致。
- [ ] `rustdesk-api/utils/totp.go` 提供 `GenerateRecoveryCodes` / `HashRecoveryCode` / `VerifyRecoveryCode`。
- [ ] `rustdesk-api/service/service.go` 注入 `*MfaService`。
- [ ] `go.mod` 锁定 `github.com/pquerna/otp v1.4.x`。
- [ ] `service/mfa_test.go` 与 `utils/totp_test.go` 覆盖 §6 全部 11 个用例,本地 `go test ./service ./utils` 全绿。
- [ ] `go vet ./...` 与 `go build ./...` 通过,无新 warning。
- [ ] godoc 在每个导出方法上明确标注哪些错误是 sentinel、调用方应如何处理。
- [ ] 任意方法在 `user_mfa` 表缺失时返回 `ErrMfaNotEnrolled`,不 panic。
- [ ] 日志输出中不包含 TOTP secret 或 recovery code 明文(`grep -rn "secret\|recovery" service/mfa.go` 人工 review)。
- [ ] 在 `docs/ai-development-plan.md` 的对应任务卡末尾追加 `状态: 完成 (commit <hash>)`。
