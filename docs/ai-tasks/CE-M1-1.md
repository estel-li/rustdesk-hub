# CE-M1-1 数据模型:user_mfa

## 1. 任务目标

为 RustDesk API/Web 账号 MFA 体系落地数据底座:新增 `model.UserMfa` GORM 模型与对应的 `user_mfas` 数据表,将 `DatabaseVersion` 从 265 bump 到 266(参见 `rustdesk-api/cmd/apimain.go:26`)并把新模型加入 `AutoMigrate` 调用(`rustdesk-api/cmd/apimain.go:291-309`);同时落地 secret 字段加密、recovery code 仅存 bcrypt 哈希的安全约束。验收信号为下列命令通过:

```bash
cd rustdesk-api
go test ./model ./service
```

任务卡原文(`docs/ai-development-plan.md:241-258`):
> ### CE-M1-1 数据模型:user_mfa
> 目标:
> - `rustdesk-api/model/user_mfa.go`
> - 字段:`user_id`、`secret`、`recovery_codes` JSON、`enabled_at`、`last_used_at`、`created_at`、`updated_at`。
> - `DatabaseVersion` 从 265 bump 到 266。
> 要求:
> - Secret 加密或至少使用现有敏感字段处理方式。
> - Recovery code 只存 hash,不要明文存储。
> - AutoMigrate 不够时补手写迁移。

## 2. 上下文与依赖

- 上游依赖任务卡:无(M1 第一张卡)。
- 下游会用到此输出的任务卡:
  - `CE-M1-2 MFA service`(`docs/ai-development-plan.md:260-274`):enroll/verify/recovery 全部 CRUD `user_mfas`。
  - `CE-M1-3 两步登录状态机`(`docs/ai-development-plan.md:276-291`):登录首步根据 `user_mfas.enabled_at` 是否非空决定走 ticket 流程。
  - `CE-M1-5 后台强制 MFA`(`docs/ai-development-plan.md:308-316`):管理员视图依赖 `last_used_at`、`enabled_at` 展示与审计。
- 关键背景事实:
  - `User` 模型见 `rustdesk-api/model/user.go:3-16`,主键 + 时间戳通过嵌入 `IdModel`、`TimeModel`(`rustdesk-api/model/model.go:14-20`)实现,新模型保持同样的内嵌组合。
  - 版本号宿主常量在 `rustdesk-api/cmd/apimain.go:26`(`const DatabaseVersion = 265`);版本表与迁移分支在 `rustdesk-api/cmd/apimain.go:258-286`,新版本迁移走 `Migrate(version)`(`rustdesk-api/cmd/apimain.go:289-313`)。
  - AutoMigrate 当前注册了 17 个模型(`rustdesk-api/cmd/apimain.go:291-309`),没有 `user_mfas`,需要补一行。
  - 现有 JSON 字段统一使用 `custom_types.AutoJson`(`rustdesk-api/model/custom_types/auto_json.go:11-66`),其 `Scan/Value` 已处理空值兼容,recovery codes JSON 列复用即可。
  - 密码哈希工具在 `rustdesk-api/utils/password.go:8-16`(bcrypt),recovery code 哈希复用 `utils.EncryptPassword` / `utils.VerifyPassword`(`rustdesk-api/utils/password.go:21-42`)。
  - 项目无现成对称加密工具(`grep -rn "crypto/aes" rustdesk-api` 无命中,唯一密钥相关配置是 `config.Jwt.Key`,见 `rustdesk-api/config/jwt.go:5-8`、`rustdesk-api/cmd/apimain.go:199`)。本卡需要新增 secret 字段加密辅助函数。
  - service 入口聚合在 `rustdesk-api/service/service.go:12-27`,后续 `MFAService` 由 CE-M1-2 落地,本卡不动 `Service` 结构体。
  - Go module 名:`github.com/lejianwen/rustdesk-api/v2`(`rustdesk-api/go.mod:1`),Go 1.23(`rustdesk-api/go.mod:3-5`),GORM v1.25.10。
  - 同时支持 SQLite、MySQL、PostgreSQL 三种方言(`rustdesk-api/cmd/apimain.go:146-182`),DDL/索引必须三方言通用。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
| --- | --- | --- | --- |
| `rustdesk-api/model/user_mfa.go` | 新建 | ~60 | 定义 `UserMfa` 结构体、表名、`TableName()`(可选)、`UserMfaList`。 |
| `rustdesk-api/utils/secret_cipher.go` | 新建 | ~110 | AES-GCM 加解密辅助,密钥从 `config.App.MfaSecretKey`(建议命名,可调整)派生,fallback 到 `config.Jwt.Key` 做 HKDF。 |
| `rustdesk-api/utils/secret_cipher_test.go` | 新建 | ~70 | 覆盖加密回环、空密钥报错、密文篡改返回错误。 |
| `rustdesk-api/utils/password.go` | 修改 | +20 | 新增 `HashRecoveryCode` / `VerifyRecoveryCode` 包装(复用 bcrypt,保持单一调用入口)。 |
| `rustdesk-api/utils/password_test.go` | 修改 | +30 | 新增对 recovery code hash 函数的单元测试。 |
| `rustdesk-api/config/config.go` | 修改 | +1 | 在 `Config` 嵌入新的 `Mfa` 子结构(见 §4)。 |
| `rustdesk-api/config/mfa.go` | 新建 | ~15 | 新增 `Mfa` 配置结构体,字段 `SecretKey`、`Issuer`。 |
| `rustdesk-api/conf/config.yaml` | 修改 | +5 | 新增 `mfa:` 段并附注释;若文件不存在则在 §3 标注。 |
| `rustdesk-api/cmd/apimain.go` | 修改 | +3 | `DatabaseVersion` 改成 266;`AutoMigrate(...)` 加上 `&model.UserMfa{}`;在版本分支补 `if v.Version < 266 { ... }` 做后置回填(本卡仅打桩,只需保留 hook)。 |
| `rustdesk-api/model/user_mfa_test.go` | 新建 | ~80 | 用内存 SQLite 建表后做 GORM CRUD/唯一索引断言。 |
| `docs/ai-development-plan.md` | 修改 | +1 | 完成后在 CE-M1-1 末尾追加状态行(见 §10)。 |

未找到/需要新建的项已在表格"动作"列标注。`rustdesk-api/conf/config.yaml` 若仓库内没有(模板可能在 `conf/` 之外),需在 §11 README 备注;此情况下视作"未找到,需新建"。

## 4. 数据契约

### 4.1 Go 结构体(GORM 模型)

`rustdesk-api/model/user_mfa.go`:

```go
package model

import (
    "github.com/lejianwen/rustdesk-api/v2/model/custom_types"
)

// UserMfa 记录单个用户的 TOTP MFA 状态。
// 一个用户最多一条记录;表通过 user_id 唯一索引保证。
type UserMfa struct {
    IdModel
    UserId         uint                  `json:"user_id"        gorm:"column:user_id;default:0;not null;uniqueIndex:uniq_user_mfa_user_id"`
    Secret         string                `json:"-"              gorm:"column:secret;type:varchar(512);default:'';not null"` // AES-GCM(base64) 后的 TOTP secret
    RecoveryCodes  custom_types.AutoJson `json:"recovery_codes" gorm:"column:recovery_codes;type:text"`                      // JSON 数组,元素为 bcrypt(recovery_code) 字符串
    EnabledAt      *int64                `json:"enabled_at"     gorm:"column:enabled_at;default:null;index"`                 // unix 秒;NULL 表示尚未启用
    LastUsedAt     *int64                `json:"last_used_at"   gorm:"column:last_used_at;default:null"`                     // unix 秒
    TimeModel
}

func (UserMfa) TableName() string { return "user_mfas" }

type UserMfaList struct {
    UserMfas []*UserMfa `json:"list,omitempty"`
    Pagination
}
```

设计要点:
- `Secret` 序列化时 `json:"-"`,避免管理 API 误回传明文密钥。
- `EnabledAt`、`LastUsedAt` 用指针类型(`*int64`),区分"未启用 / 尚未使用过" 与 "时间戳 = 0"。
- `RecoveryCodes` 复用 `custom_types.AutoJson`(`model/custom_types/auto_json.go:11-66`),空值自动转 `[]`,跨方言兼容。

### 4.2 SQL DDL(由 AutoMigrate 生成,这里写出等价 DDL 供验证)

SQLite:

```sql
CREATE TABLE user_mfas (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         INTEGER NOT NULL DEFAULT 0,
    secret          TEXT    NOT NULL DEFAULT '',
    recovery_codes  TEXT,
    enabled_at      INTEGER,
    last_used_at    INTEGER,
    created_at      DATETIME,
    updated_at      DATETIME
);
CREATE UNIQUE INDEX uniq_user_mfa_user_id ON user_mfas(user_id);
CREATE INDEX idx_user_mfas_enabled_at ON user_mfas(enabled_at);
```

PostgreSQL:

```sql
CREATE TABLE user_mfas (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL DEFAULT 0,
    secret          VARCHAR(512) NOT NULL DEFAULT '',
    recovery_codes  TEXT,
    enabled_at      BIGINT,
    last_used_at    BIGINT,
    created_at      TIMESTAMP,
    updated_at      TIMESTAMP
);
CREATE UNIQUE INDEX uniq_user_mfa_user_id ON user_mfas(user_id);
CREATE INDEX idx_user_mfas_enabled_at ON user_mfas(enabled_at);
```

MySQL:

```sql
CREATE TABLE user_mfas (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id         BIGINT UNSIGNED NOT NULL DEFAULT 0,
    secret          VARCHAR(512) NOT NULL DEFAULT '',
    recovery_codes  TEXT,
    enabled_at      BIGINT NULL,
    last_used_at    BIGINT NULL,
    created_at      DATETIME,
    updated_at      DATETIME,
    UNIQUE KEY uniq_user_mfa_user_id (user_id),
    KEY idx_user_mfas_enabled_at (enabled_at)
) DEFAULT CHARSET=utf8mb4;
```

`uniq_user_mfa_user_id`:GORM tag `uniqueIndex:uniq_user_mfa_user_id` 跨方言生成同名索引;`enabled_at` 上的 `index` 通过 GORM tag 自动派生,如有方言差异以 `AutoMigrate` 输出为准,不要手写 ALTER。

### 4.3 配置项

`rustdesk-api/config/mfa.go`(新建):

```go
package config

type Mfa struct {
    SecretKey string `mapstructure:"secret-key"` // 32 byte base64 或 hex;留空则 HKDF(Jwt.Key)
    Issuer    string `mapstructure:"issuer"`     // TOTP otpauth issuer,默认 "RustDesk"
}
```

`Config` 增加 `Mfa Mfa` 字段(`rustdesk-api/config/config.go:34-50`)。

env 变量(viper 大写 + `_`,前缀 `RUSTDESK_API`):
- `RUSTDESK_API_MFA_SECRET_KEY`
- `RUSTDESK_API_MFA_ISSUER`

yaml key:
```yaml
mfa:
  secret-key: ""        # 留空则从 jwt.key 派生
  issuer: "RustDesk"
```

### 4.4 加密辅助函数签名

`rustdesk-api/utils/secret_cipher.go`:

```go
// EncryptSecret 用 AES-256-GCM 加密 plaintext;key 为 32 byte。
// 返回 base64(nonce||ciphertext||tag)。
func EncryptSecret(key []byte, plaintext string) (string, error)

// DecryptSecret 与上对偶,密文被篡改时返回 error。
func DecryptSecret(key []byte, ciphertext string) (string, error)

// DeriveMfaKey 优先返回 raw key(hex/base64 解析);失败时 HKDF(sha256, jwtKey, "rustdesk-mfa-secret")。
func DeriveMfaKey(rawKey, jwtKey string) ([]byte, error)
```

### 4.5 Recovery code 哈希辅助

`rustdesk-api/utils/password.go` 追加(基于 `rustdesk-api/utils/password.go:10-16` 现有 `EncryptPassword`):

```go
func HashRecoveryCode(code string) (string, error)             // 内部调用 bcrypt
func VerifyRecoveryCode(hash, input string) (matched bool, err error)
```

## 5. 实现步骤

1. **新增加密配置项**
   - 在 `rustdesk-api/config/jwt.go` 同级新增 `rustdesk-api/config/mfa.go`(参考 `config/jwt.go:5-8` 风格)。
   - 修改 `rustdesk-api/config/config.go:34-50`,在 `Config` struct 中追加 `Mfa Mfa`。
   - 若仓库存在 `rustdesk-api/conf/config.yaml`,追加 `mfa:` 段;无文件则在 `rustdesk-api/README*` 注明 env 名。
2. **实现 AES-GCM 工具与单测**
   - 新建 `rustdesk-api/utils/secret_cipher.go`,实现 `EncryptSecret/DecryptSecret/DeriveMfaKey`(签名见 §4.4)。
   - 新建 `rustdesk-api/utils/secret_cipher_test.go` 覆盖三种场景(见 §6)。
3. **实现 recovery code hash 包装**
   - 在 `rustdesk-api/utils/password.go` 末尾追加 `HashRecoveryCode/VerifyRecoveryCode`(内部转调 `bcrypt`,参照现有 `EncryptPassword`,`utils/password.go:10-16`)。
   - 在 `rustdesk-api/utils/password_test.go` 追加测试。
4. **定义 GORM 模型**
   - 新建 `rustdesk-api/model/user_mfa.go`,内容见 §4.1。
5. **bump DatabaseVersion 并注册 AutoMigrate**
   - 修改 `rustdesk-api/cmd/apimain.go:26`:`const DatabaseVersion = 266`。
   - 修改 `rustdesk-api/cmd/apimain.go:291-309`:在 `AutoMigrate` 调用末尾追加 `&model.UserMfa{},`。
   - 在 `rustdesk-api/cmd/apimain.go:283-286` 之后追加版本回填分支:
     ```go
     if v.Version < 266 {
         // CE-M1-1: 仅建表,无历史数据回填
     }
     ```
     即使空体也保留 hook,后续 CE-M1-2/3 可继续追加。
6. **新增模型层测试**
   - 新建 `rustdesk-api/model/user_mfa_test.go`,使用内存 SQLite(`gorm.io/driver/sqlite` + `:memory:`)`AutoMigrate(&UserMfa{})`,断言唯一索引、`AutoJson` 序列化、指针时间戳的 nil 行为。
7. **运行 §7 中验证命令**,把任何 lint/编译错修干净后,在 `docs/ai-development-plan.md:241` 这张任务卡末尾追加完成状态行(见 §10)。

每步 ≤ 1 天工作量,步骤 1-3 可并行,步骤 4 依赖 1,5 依赖 4。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
| --- | --- | --- | --- | --- |
| 1 | `rustdesk-api/model/user_mfa_test.go` | `TestUserMfa_AutoMigrate_Create` | 在内存 SQLite AutoMigrate `&UserMfa{}` 后写入 `UserId=1, Secret="enc"`,RecoveryCodes 为 JSON `["h1","h2"]` | 查询回读字段一一相等;`EnabledAt`、`LastUsedAt` 为 nil |
| 2 | `rustdesk-api/model/user_mfa_test.go` | `TestUserMfa_UniqueUserId` | 同 user_id 插入两次 | 第二次返回 GORM 唯一约束 err(失败模式) |
| 3 | `rustdesk-api/model/user_mfa_test.go` | `TestUserMfa_RecoveryCodes_Empty` | 不显式赋 RecoveryCodes,直接 Create + Reload | 读回非 nil 且 JSON 形态为 `[]`(对应 `custom_types.AutoJson` 默认行为,`model/custom_types/auto_json.go:30-33`) |
| 4 | `rustdesk-api/utils/secret_cipher_test.go` | `TestEncryptSecret_RoundTrip` | 32 byte key + plaintext "JBSWY3DPEHPK3PXP" | `Decrypt(Encrypt(x)) == x` |
| 5 | `rustdesk-api/utils/secret_cipher_test.go` | `TestDecryptSecret_Tampered` | 改写密文 base64 任一字节后 Decrypt | 返回非 nil error(失败模式) |
| 6 | `rustdesk-api/utils/secret_cipher_test.go` | `TestDeriveMfaKey_FallbackToJwt` | `rawKey=""`,`jwtKey="hello"` | 返回 32 byte 长度 key,无 error;两次同输入得相同 key(确定性) |
| 7 | `rustdesk-api/utils/password_test.go` | `TestHashRecoveryCode_VerifyOk` | 任意 10 位 code | `VerifyRecoveryCode(hash, code) == true` |
| 8 | `rustdesk-api/utils/password_test.go` | `TestHashRecoveryCode_VerifyMismatch` | hash 与不同 input | `matched == false, err == nil`(失败模式) |
| 9 | `rustdesk-api/model/user_mfa_test.go` | `TestUserMfa_OldVersionCompat` | 在已有 v=265 schema 的 DB 上跑 AutoMigrate,然后 Create | 不丢失老表;新表存在(向后兼容用例) |

`go test ./model ./service`(任务卡验收命令)需要全部通过;`./service` 此时无新增测试,只需保证整包不因 import 变化而打破。

## 7. 验证命令

```bash
# 1. 模块整理
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api
go mod tidy

# 2. 编译全量
go build ./...

# 3. 任务卡指定的最小验收
go test ./model ./service

# 4. 单独跑新增包,便于定位
go test ./utils ./model -run UserMfa -v
go test ./utils -run SecretCipher -v

# 5. 跑一遍 apimain 的迁移路径(可选,本地需 sqlite 默认配置)
# macOS 开发盒可跳过此步,因为它会真的写一个本地 sqlite 文件;CI 上必须跑。
go run ./cmd help

# 6. vet/格式
go vet ./...
gofmt -l model utils config cmd
```

跳过说明:
- 第 5 步可在 macOS dev box 跳过,理由是会在仓库生成 sqlite 文件,污染 git status;CI 必须执行,以验证 `DatabaseVersion=266` 路径不报错。
- 其余步骤必跑。

## 8. 兼容性 / 安全注意事项

- 协议兼容:本卡只动数据库,protobuf/客户端协议无变更。CE-M1-3 才引入新 JSON 字段,本卡 OK。
- 数据库迁移:
  - `AutoMigrate` 对所有已支持方言新增 `user_mfas` 表与 `uniq_user_mfa_user_id` 索引;现有表无字段变化,老版本服务连接新库时只是多一张表,可向后兼容。
  - `Version` 表新增 v=266 记录,旧二进制看到大于自身 `DatabaseVersion` 的版本时(`rustdesk-api/cmd/apimain.go:262-265`)不会再触发 Migrate,行为安全。
- 老客户端/老服务端互通:登录响应未变,本卡对客户端透明。
- 敏感字段不落盘:
  - `Secret` 进库前必须经过 `utils.EncryptSecret`(由 CE-M1-2 service 调用),本卡 model 层不写明文。
  - `RecoveryCodes` 仅存 `bcrypt(code)`,明文只在 enroll 接口一次性返回给前端(由 CE-M1-2 实现)。
  - JSON tag `Secret -> "-"`,杜绝管理列表 API 反查泄漏。
- 限流:本卡不涉及限流,但 CE-M1-3 会复用 `utils.LoginLimiter`(`rustdesk-api/cmd/apimain.go:206-212`),数据库字段已提供 `LastUsedAt`,为后续 MFA 错误统计提供 hook。
- 配置安全:`mfa.secret-key` 若使用默认 fallback(HKDF(Jwt.Key)),需在 README 标注:更换 `jwt.key` 将导致所有已存 TOTP secret 解密失败,必须重新 enroll。

## 9. 回滚方案

- 代码回滚:`git revert` 本卡 commit;DatabaseVersion 回到 265,旧二进制可正常启动。
- 数据库回滚:由于 `user_mfas` 表是新增、与其他表无 FK,只需 `DROP TABLE user_mfas;` 及 `DELETE FROM versions WHERE version = 266;`(三方言通用)。提供 SQL 片段在 `docs/runbooks/`(由 CE-M1-10 收口)。
- 配置回滚:`mfa.secret-key` 留空时不影响启动;直接删配置段即可。
- 紧急 feature flag:即使代码已合并,只要不调用 CE-M1-2 的接口,新表保持空,客户端无影响;无需额外开关。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-api/model/user_mfa.go` 新增,字段与 §4.1 一致。
- [ ] `rustdesk-api/utils/secret_cipher.go` 实现 `EncryptSecret/DecryptSecret/DeriveMfaKey`。
- [ ] `rustdesk-api/utils/password.go` 新增 `HashRecoveryCode/VerifyRecoveryCode`。
- [ ] `rustdesk-api/config/mfa.go` 新增,`Config` 嵌入 `Mfa`。
- [ ] `rustdesk-api/cmd/apimain.go` 中 `DatabaseVersion` 改为 266,`AutoMigrate` 注册 `&model.UserMfa{}`,版本迁移分支留 v<266 hook。
- [ ] 新增/修改的测试全部通过(§6 中 9 个用例)。
- [ ] `go build ./...` `go vet ./...` `gofmt -l` 均通过。
- [ ] 在 `docs/ai-development-plan.md` CE-M1-1 任务卡末尾(约 `docs/ai-development-plan.md:258` 行后)追加一行 `状态: 完成 (commit <hash>)`。
