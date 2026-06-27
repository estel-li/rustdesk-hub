# CE-M1-9 轻量 Client Builder

## 1. 任务目标

在 `rustdesk-api` 后台新增"轻量 Client Builder",允许管理员填写 `id_server` / `relay_server` / `api_server` / `key` 四个字段,基于一份预先上传(或预下载)的 Windows portable 基础 EXE 复制并改名为 RustDesk 客户端识别的 Configuration String 文件名(如 `RustDesk-host=id.example.com,key=<base64>,api=https%3A%2F%2Fapi.example.com,relay=relay.example.com.exe`),配合一次性短期下载 token 暴露下载页与二维码。明确不做编译、不换 icon、不签名。

验收信号:
- 后台 `POST /api/admin/client_builder/build` 返回 `{download_url, landing_url, qr_png_base64, expires_at}`。
- 访问 `download_url` 返回带正确文件名的 EXE,且该文件名能被 `rustdesk/src/custom_server.rs:39` 的 `get_custom_server_from_string` 正确解析(host / key / api / relay 对应原始输入)。
- 7 天内重复构建相同四元组返回同一缓存条目;7 天后或缓存清理后链接 404 / 410。

## 2. 上下文与依赖

- 上游依赖任务卡:
  - CE-M0-4(`rustdesk-api` Redis / metrics / cache healthcheck — 复用 `global.Cache`)。
  - CE-M1-1 已经把 `DatabaseVersion` 从 265 升级到 266;本任务再 bump 到 267(新表 `client_builder_artifact`)。
- 下游会用到此输出的任务卡:
  - CE-M1-10 运维文档,需要补充本功能的部署说明。
  - 未来 M2 RBAC 强制 MFA / 资源访问策略可能需要给 `download_url` 加入访问控制(本任务只用一次性短 token)。
- 关键背景事实(file:line):
  - 客户端文件名解析:`rustdesk/src/custom_server.rs:39-87`,解析以 `host=` 开头、`,` 分隔、可选 `.exe`/`.exe.exe` 后缀;字段 key/host/api/relay 大小写不敏感(`custom_server.rs:67-80`)。测试样例 `custom_server.rs:119-184`。
  - 现有 admin 路由注册:`rustdesk-api/http/router/admin.go:14-55`,所有需 token 的路由集中在 `adg.Use(middleware.BackendUserAuth())` 之后;管理员特权用 `middleware.AdminPrivilege()`(参考 `admin.go:85,98,109`)。
  - 现有"上传到本地"参考:`rustdesk-api/http/controller/admin/file.go:64-83` 已示范 `c.FormFile` + `c.SaveUploadedFile`,可直接借鉴。
  - 管理员配置回显:`rustdesk-api/http/controller/admin/config.go:24-38`(`Admin.ServerConfig`)已经返回了 IdServer/RelayServer/ApiServer/Key 当前默认值,可作为前端表单初值来源。
  - 服务层注册:`rustdesk-api/service/service.go:12-27` 通过 `Service` 聚合每个 *Service 指针;`service.New` 全局赋值 `DB / Cache(全局位于 global.Cache)`;需要在 `Service` 里追加 `*ClientBuilderService`。
  - 全局缓存接口:`rustdesk-api/lib/cache/cache.go:7-11`,`Handler.Set(key, value, exp int)`,`global.Cache` 在 `rustdesk-api/global/global.go:27` 已声明,可直接缓存 token → artifact 元数据 (7 days = 604800 秒,小于 `MaxTimeOut`)。
  - 数据迁移入口:`rustdesk-api/cmd/apimain.go:26`(`DatabaseVersion = 265`,M1-1 已 bump 到 266)、`apimain.go:289-313` 的 `AutoMigrate` 列表;需要在该列表追加 `&model.ClientBuilderArtifact{}` 并将 `DatabaseVersion` 调整为 267。
  - 配置项:`rustdesk-api/config/config.go:34-50` 的 `Config` 结构,需要追加 `ClientBuilder` 子结构;`rustdesk-api/conf/config.yaml:13-19` 是配置的写入位置参考。
  - 静态文件目录约定:`rustdesk-api/http/router/router.go:19-22` 与 `api.go:104` 以 `global.Config.Gin.ResourcesPath`(默认 `resources`)为根挂载静态目录;本任务的"持久 artifact"建议放在仓库根级的 `data/client-builder/base/`(任务说明明确给定),与现有 `resources/` 区分。
  - 客户端默认 PK(`rustdesk/src/custom_server.rs:23-26`)只影响 `*-licensed-` 签名串模式,本任务**只走** `host=...` 文件名分支,无需签名。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|------|------|----------|------|
| `rustdesk-api/model/clientBuilderArtifact.go` | 新建 | 40 | 数据模型 `ClientBuilderArtifact`(基础 EXE 的元数据 + 上游 URL + sha256 + 版本) |
| `rustdesk-api/service/clientBuilder.go` | 新建 | 220 | 服务层:上传/记录基础 EXE、组装文件名、复制/流式输出、签发并校验下载 token、缓存交互、二维码生成 |
| `rustdesk-api/http/controller/admin/clientBuilder.go` | 新建 | 180 | admin 控制器:`UploadBase` / `ListBase` / `DeleteBase` / `Build` |
| `rustdesk-api/http/controller/api/clientBuilder.go` | 新建 | 100 | 公开下载控制器:`Download`(凭 token 流式下发)、`Landing`(下载落地页 HTML)、`QR`(可选,返回 PNG) |
| `rustdesk-api/http/router/admin.go` | 修改 | +18 | 注册 `ClientBuilderBind(adg)`(参照 `admin.go:57-64`/`133-149`) |
| `rustdesk-api/http/router/api.go` | 修改 | +6 | 注册公开 `/api/client-builder/download/:token` `/api/client-builder/landing/:token` `/api/client-builder/qr/:token`(无需鉴权) |
| `rustdesk-api/http/request/admin/clientBuilder.go` | 新建 | 50 | 表单/JSON 请求结构 + 校验 tag |
| `rustdesk-api/http/response/clientBuilder.go` | 新建 | 30 | 响应 DTO:`BuildResponse`、`ArtifactItem`、`ArtifactList` |
| `rustdesk-api/service/service.go` | 修改 | +1 | `Service` 结构追加 `*ClientBuilderService` |
| `rustdesk-api/cmd/apimain.go` | 修改 | +3 | `DatabaseVersion` 266 → 267;`AutoMigrate` 中追加 `&model.ClientBuilderArtifact{}` |
| `rustdesk-api/config/config.go` | 修改 | +25 | 追加 `ClientBuilder` 配置子结构(base-dir / link-ttl-hours / max-base-mb / public-base-url) |
| `rustdesk-api/conf/config.yaml` | 修改 | +8 | 默认 `client-builder` 配置块 |
| `rustdesk-api/go.mod` / `go.sum` | 修改 | +3 | 引入 `github.com/skip2/go-qrcode`(若仓库尚未引入二维码库) |
| `data/client-builder/base/.gitkeep` | 新建 | 1 | 占位,保留目录但不入库二进制 |
| `data/client-builder/base/README.md` | 新建 | 20 | 说明:管理员手动上传或运行脚本下载 RustDesk 官方 portable EXE 到此目录的约定 |
| `rustdesk-api/.gitignore` | 修改 | +2 | 忽略 `data/client-builder/base/*.exe` 和 `data/client-builder/build/`(若不存在 .gitignore 则在仓库根级追加) |
| `docs/ai-development-plan.md` | 修改 | +1 | 在 CE-M1-9 任务卡末尾追加完成状态行 |
| `rustdesk-api/service/clientBuilder_test.go` | 新建 | 120 | 单测:文件名拼装、token 签发/校验、7 天 TTL、错误参数 |
| `rustdesk-api/http/controller/admin/clientBuilder_test.go` | 新建 | 80 | HTTP 集成测:鉴权、Build happy path、过期 token |

> 备注:`rustdesk-api/http/controller/api/` 当前目录已存在,如未找到对应 controller 文件请新建;如未找到 `data/` 目录请新建,与 `runtime/`、`conf/` 同层。

## 4. 数据契约

### 4.1 GORM 模型

```go
// rustdesk-api/model/clientBuilderArtifact.go
package model

type ClientBuilderArtifact struct {
    IdModel
    Name        string `json:"name"         gorm:"size:128;not null;default:''"`     // 友好名,如 "rustdesk-1.4.2-portable"
    Source      string `json:"source"       gorm:"size:16;not null;default:'upload'"` // upload | upstream
    UpstreamUrl string `json:"upstream_url" gorm:"size:512;not null;default:''"`     // source=upstream 时存放 URL
    Sha256      string `json:"sha256"       gorm:"size:64;not null;default:'';index"` // 小写 hex,索引避免重复
    SizeBytes   int64  `json:"size_bytes"   gorm:"not null;default:0"`
    Version     string `json:"version"      gorm:"size:32;not null;default:''"`       // 例 "1.4.2"
    LocalPath   string `json:"local_path"   gorm:"size:512;not null;default:''"`      // 相对仓库根的绝对/相对路径
    Active      int    `json:"active"       gorm:"not null;default:1;index"`          // 1 启用 / 0 停用
    CreatedBy   uint   `json:"created_by"   gorm:"not null;default:0"`
    TimeModel
}
```

复用 `model/model.go:14-19` 的 `IdModel` / `TimeModel`。索引:`sha256`(去重)、`active`(列表)。

### 4.2 SQL DDL(供手写迁移参考)

SQLite:

```sql
CREATE TABLE IF NOT EXISTS client_builder_artifacts (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  name          VARCHAR(128) NOT NULL DEFAULT '',
  source        VARCHAR(16)  NOT NULL DEFAULT 'upload',
  upstream_url  VARCHAR(512) NOT NULL DEFAULT '',
  sha256        VARCHAR(64)  NOT NULL DEFAULT '',
  size_bytes    INTEGER      NOT NULL DEFAULT 0,
  version       VARCHAR(32)  NOT NULL DEFAULT '',
  local_path    VARCHAR(512) NOT NULL DEFAULT '',
  active        INTEGER      NOT NULL DEFAULT 1,
  created_by    INTEGER      NOT NULL DEFAULT 0,
  created_at    TIMESTAMP,
  updated_at    TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_cb_artifacts_sha256 ON client_builder_artifacts(sha256);
CREATE INDEX IF NOT EXISTS idx_cb_artifacts_active ON client_builder_artifacts(active);
```

PostgreSQL:

```sql
CREATE TABLE IF NOT EXISTS client_builder_artifacts (
  id            BIGSERIAL PRIMARY KEY,
  name          VARCHAR(128) NOT NULL DEFAULT '',
  source        VARCHAR(16)  NOT NULL DEFAULT 'upload',
  upstream_url  VARCHAR(512) NOT NULL DEFAULT '',
  sha256        VARCHAR(64)  NOT NULL DEFAULT '',
  size_bytes    BIGINT       NOT NULL DEFAULT 0,
  version       VARCHAR(32)  NOT NULL DEFAULT '',
  local_path    VARCHAR(512) NOT NULL DEFAULT '',
  active        SMALLINT     NOT NULL DEFAULT 1,
  created_by    BIGINT       NOT NULL DEFAULT 0,
  created_at    TIMESTAMP,
  updated_at    TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_cb_artifacts_sha256 ON client_builder_artifacts(sha256);
CREATE INDEX IF NOT EXISTS idx_cb_artifacts_active ON client_builder_artifacts(active);
```

(实际首选 `AutoMigrate` + GORM 默认行为,SQL DDL 仅作为参考,不用手写迁移文件。)

### 4.3 HTTP 请求 / 响应

`POST /api/admin/client_builder/base/upload`(`multipart/form-data`)

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file` | file | 否 | 当 `source=upload` 时必填;上限由 `client-builder.max-base-mb` 限制 |
| `source` | string | 是 | `upload` 或 `upstream` |
| `upstream_url` | string | source=upstream 必填 | `https://...` |
| `sha256` | string | 是 | 上游 / 上传一致校验 |
| `version` | string | 否 | 形如 `1.4.2` |
| `name` | string | 否 | 默认 `rustdesk-portable-<sha8>` |

`POST /api/admin/client_builder/build`(JSON):

```json
{
  "artifact_id": 3,
  "id_server":   "id.example.com:21116",
  "relay_server":"relay.example.com:21117",
  "api_server":  "https://api.example.com",
  "key":         "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw="
}
```

响应:

```json
{
  "code": 0,
  "data": {
    "token": "<32-byte base64url>",
    "filename": "RustDesk-host=id.example.com:21116,key=OeVuKk5nlHiXp%2BAPNn0Y3pC1Iwpwn44JGqrQCsWqmBw%3D,api=https%3A%2F%2Fapi.example.com,relay=relay.example.com:21117.exe",
    "download_url": "https://<api-server>/api/client-builder/download/<token>",
    "landing_url":  "https://<api-server>/api/client-builder/landing/<token>",
    "qr_png_base64": "iVBORw0KGgo...",
    "expires_at":   "2026-07-04T12:34:56Z"
  }
}
```

`GET /api/client-builder/download/:token`:
- 200:`Content-Type: application/octet-stream`、`Content-Disposition: attachment; filename*=UTF-8''<percent-encoded-filename>`,流式输出基础 EXE 内容(不重新写盘)。
- 410:token 过期。
- 404:token 不存在 / artifact 已删除 / 文件丢失。

`GET /api/client-builder/landing/:token`:返回简短 HTML(嵌入下载按钮 + 二维码 `<img src="../qr/<token>">` + Configuration String 的可见信息)。

`GET /api/client-builder/qr/:token`:返回 `image/png`(`download_url` 内容的二维码)。

`GET /api/admin/client_builder/base/list` / `POST /api/admin/client_builder/base/delete`:与现有 admin list / delete 风格一致(参照 `admin.go:101-105`)。

### 4.4 文件名拼装规则(组装函数契约)

输入四元组 `host`, `key`, `api`, `relay`,输出文件名:

1. 顺序固定:`host` → `key` → `api` → `relay`,字段缺省则**省略整段**(避免空 `key=,` 引起客户端误判)。
2. 每个值用 `url.QueryEscape` 编码,但保留 `:`(冒号端口)、`-`、`.`、`=`(base64 padding)三类字符还原(go `url.QueryEscape` 不会转 `-` `.`,会把 `=` 转为 `%3D`、`/` 转为 `%2F`、`+` 转为 `%2B`;客户端 `custom_server.rs:67-80` 不做 percent-decode,要在文件名级别**仅对 `,`、空格、控制字符等 ASCII 不安全字符做转义**)。
3. 因此实现选择保守做法:对 `,`、空白、非 ASCII 字符替换为 `%XX`,其它字符原样保留。具体规则:`safeEncode(s) = strings.NewReplacer(",", "%2C", " ", "%20", "\t", "%09").Replace(s)` 并对剩余非 printable byte percent-encode。**(建议命名,可调整)**
4. 拼接:`"RustDesk-host=" + safe(host) + ",key=" + safe(key) + ",api=" + safe(api) + ",relay=" + safe(relay) + ".exe"`,缺省字段整段省略;最终长度需 ≤ 240 字符(Windows MAX_PATH 短路径预留)。
5. 必须保证:把生成的文件名传回 `get_custom_server_from_string`(见 `custom_server.rs:39-87`)能 100% 解析回原四元组(单测覆盖)。

### 4.5 缓存 key / TTL

- token → JSON `{artifact_id, filename, host, key, api, relay, created_by, expires_at}`,key 命名 `client_builder:token:<token>`,TTL = `client-builder.link-ttl-hours * 3600`(默认 168h=7天)。
- 配置:`cache.NewMemoryCache` 上限不够时由 `global.Cache`(可能是 Redis)接管;参考 `lib/cache/cache.go:7-11`。

### 4.6 配置项

```yaml
# rustdesk-api/conf/config.yaml
client-builder:
  enabled: true
  base-dir: "./data/client-builder/base"      # 基础 EXE 持久目录
  link-ttl-hours: 168                          # 7 天
  max-base-mb: 200                             # 单个基础 EXE 最大体积
  public-base-url: ""                          # 留空时使用 global.Config.Rustdesk.ApiServer
```

```go
// rustdesk-api/config/config.go(新增字段)
type ClientBuilder struct {
    Enabled       bool   `mapstructure:"enabled"`
    BaseDir       string `mapstructure:"base-dir"`
    LinkTTLHours  int    `mapstructure:"link-ttl-hours"`
    MaxBaseMB     int    `mapstructure:"max-base-mb"`
    PublicBaseUrl string `mapstructure:"public-base-url"`
}
```

环境变量:`RUSTDESK_API_CLIENT-BUILDER_ENABLED=true` 等(沿用 `config.go:69` 的 prefix 与 replacer 规则)。

## 5. 实现步骤

1. **模型与迁移**:新增 `rustdesk-api/model/clientBuilderArtifact.go`(§4.1);在 `rustdesk-api/cmd/apimain.go:26` 把 `DatabaseVersion` 改为 `267`(若 CE-M1-1 已经是 266 则升到 267,否则升到 266 后追加注释);把 `&model.ClientBuilderArtifact{}` 追加到 `apimain.go:291-309` 的 `AutoMigrate` 列表。

2. **配置注入**:在 `rustdesk-api/config/config.go:34-50` 的 `Config` 追加 `ClientBuilder ClientBuilder`;在 `conf/config.yaml` 末尾追加 §4.6 配置块。在 `config.go:Init` 中如果 `ClientBuilder.BaseDir` 为空则置默认 `./data/client-builder/base`。

3. **数据目录**:在仓库根创建 `data/client-builder/base/.gitkeep` 和 `README.md`,并在 `.gitignore` 排除 `*.exe`、`data/client-builder/build/`。

4. **服务层骨架**:新增 `rustdesk-api/service/clientBuilder.go`:
   - `type ClientBuilderService struct{}`
   - `(s *ClientBuilderService) CreateBase(req *UploadBaseReq, file *multipart.FileHeader) (*model.ClientBuilderArtifact, error)`:上传/下载基础 EXE,落到 `BaseDir/<sha256>.exe`,sha256 校验,落库(去重时 `active=1`)。
   - `(s *ClientBuilderService) ListBases(page, pageSize uint)` / `DeleteBase(id uint)`(参照 `service/serverCmd.go:13-40`)。
   - `(s *ClientBuilderService) Build(artifactId uint, host, key, api, relay string, userId uint) (*BuildResult, error)`:校验 artifact 存在且 active、文件存在;调用 `BuildFilename`;生成 32 byte 随机 token;`global.Cache.Set("client_builder:token:"+token, payload, ttlSeconds)`。
   - `(s *ClientBuilderService) Resolve(token string) (*TokenPayload, error)`:从 `global.Cache.Get`。
   - `(s *ClientBuilderService) StreamArtifact(c *gin.Context, payload *TokenPayload)`:`c.FileAttachment(localPath, filename)`,并自定义 `Content-Disposition` 用 `filename*=UTF-8''<encoded>`。
   - `(s *ClientBuilderService) QRPng(downloadUrl string) ([]byte, error)`:`qrcode.Encode(downloadUrl, qrcode.Medium, 320)`。
   - `BuildFilename(host, key, api, relay string) string` 按 §4.4 实现,导出供测试。
   - 在 `service/service.go:12-27` 的 `Service` 结构追加 `*ClientBuilderService` 字段(让 `service.AllService.ClientBuilderService.XXX` 可用,沿用 `serverCmd` 风格)。

5. **Admin 控制器**:新增 `rustdesk-api/http/controller/admin/clientBuilder.go`:
   - `UploadBase`、`ListBase`、`DeleteBase`、`Build` 四个 handler,均使用 `response.Fail` / `response.Success`,参数错误 code=101,沿用 `controller/admin/rustdesk.go:21-78` 风格。
   - `Build` 中读取登录用户(参考 `controller/admin/config.go:65-71` 的 `c.GetHeader("api-token")` / `service.AllService.UserService.InfoByAccessToken`)。

6. **公开下载控制器**:新增 `rustdesk-api/http/controller/api/clientBuilder.go`:实现 `Download` / `Landing` / `QR`,使用 `service.AllService.ClientBuilderService.Resolve(token)`。Landing HTML 用 `text/template` 内嵌简单模板(标题、Configuration String 明文展示、二维码 `<img>`、下载按钮)。

7. **路由注册**:
   - `rustdesk-api/http/router/admin.go:51` 之后新增 `ClientBuilderBind(adg)`,与 `RustdeskCmdBind` 平级:`rg := adg.Group("/client_builder").Use(middleware.AdminPrivilege())`;`rg.POST("/base/upload", c.UploadBase)`、`rg.GET("/base/list", c.ListBase)`、`rg.POST("/base/delete", c.DeleteBase)`、`rg.POST("/build", c.Build)`。
   - `rustdesk-api/http/router/api.go`(参照 `api.go:104` 风格)注册 `g.GET("/api/client-builder/download/:token", ...)`、`landing/:token`、`qr/:token`,放在 **鉴权 group 之外**(下载页是公开但 token 一次性短期有效)。

8. **依赖**:`cd rustdesk-api && go get github.com/skip2/go-qrcode@latest`,提交 `go.mod`/`go.sum`。如果不希望新增依赖,可改用 `rsc.io/qr`(纯 Go,体积更小);建议名优先 `skip2/go-qrcode`,可调整。

9. **测试**:见 §6。

10. **文档**:更新 `docs/ai-development-plan.md` 末尾追加完成状态;在 `docs/operations/` 下补一个简短的 `client-builder.md`(可作为 CE-M1-10 的素材,但先把基本用法写好)。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|----------|--------|------|------|
| 1 | `rustdesk-api/service/clientBuilder_test.go` | `TestBuildFilename_AllFields` | host=`id.example.com:21116`, key=`OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=`, api=`https://api.example.com`, relay=`relay.example.com:21117` | 文件名以 `RustDesk-host=` 开头、`.exe` 结尾;`,` 不出现在任意 value 内;反向用 Go 端口的等价解析(把字符串拆解还原)得回相同四元组 |
| 2 | 同上 | `TestBuildFilename_RustDeskClientParse` | 同 #1 | 调用 `rustdesk` 仓库测试样例的解析约定(等价 oracle:lowercase + split `,` + skip prefix)还原结果与输入逐字段相等(覆盖 `rustdesk/src/custom_server.rs:67-80` 的解析逻辑) |
| 3 | 同上 | `TestBuildFilename_OmitEmpty` | host=`id.example.com`, key=``, api=``, relay=`` | 文件名为 `RustDesk-host=id.example.com.exe`,不出现 `key=` / `api=` / `relay=` |
| 4 | 同上 | `TestBuildFilename_RejectEmptyHost` | host=`` | 返回 error,`Build` 不进入缓存 |
| 5 | 同上 | `TestToken_TTL` | 设 `LinkTTLHours=1/3600` 触发即过期 | `Resolve` 第一次返回 payload,第二次(sleep 后)返回 `ErrTokenExpired` |
| 6 | 同上 | `TestSha256Mismatch` | 上传文件实际 sha256 与请求中 `sha256` 不一致 | `CreateBase` 返回 error,文件不落库不落盘 |
| 7 | `rustdesk-api/http/controller/admin/clientBuilder_test.go` | `TestBuildEndpoint_RequiresAdmin` | 普通用户 token 调用 `/api/admin/client_builder/build` | 403 / `NoAccess` |
| 8 | 同上 | `TestBuildEndpoint_Happy` | admin token + 合法 artifact_id | 200,返回 download_url 包含 `<token>`、`expires_at` 与配置 TTL 一致 |
| 9 | 同上 | `TestDownloadEndpoint_Expired` | 构造过期 token | 410 |
| 10 | 同上 | `TestDownloadEndpoint_BackwardCompat` | 老前端**不传** `relay_server` 字段 | 仍可成功,生成文件名省略 `relay=`,客户端解析得 `relay=""` |

## 7. 验证命令

```bash
# 1. 拉依赖
cd rustdesk-api
go mod tidy

# 2. 单测
go test ./model ./service ./http/controller/admin -run 'ClientBuilder|BuildFilename'

# 3. 全量回归
go test ./...

# 4. 跑起来,做一次端到端冒烟(macOS 开发盒可跑,不需要 Windows)
go run ./cmd

# 4a. 上传一个假 EXE(任何 ≥ 8KB 的文件都可以;sha256 自己 shasum -a 256)
curl -F 'file=@./testdata/fake-rustdesk.bin' \
     -F 'source=upload' \
     -F "sha256=$(shasum -a 256 testdata/fake-rustdesk.bin | awk '{print $1}')" \
     -F 'version=1.0.0' \
     -H 'api-token: <admin token>' \
     http://127.0.0.1:21114/api/admin/client_builder/base/upload

# 4b. 构建
curl -X POST -H 'Content-Type: application/json' -H 'api-token: <admin token>' \
     -d '{"artifact_id":1,"id_server":"id.example.com:21116","relay_server":"relay.example.com:21117","api_server":"https://api.example.com","key":"AAA="}' \
     http://127.0.0.1:21114/api/admin/client_builder/build

# 4c. 下载并校验文件名能被解析
curl -OJ http://127.0.0.1:21114/api/client-builder/download/<token>
ls RustDesk-host=*.exe

# 5. (可跳过 macOS 开发盒)真实 Windows 客户端解析
#    把下载到的 EXE 改名拷到 Windows 测试机首次启动,验证 host/key/api/relay 写入了客户端配置。
#    macOS 开发盒原因:RustDesk portable EXE 无法在 macOS 上原生运行,跳过此步骤;改用单测 #2 的等价 oracle 解析。
```

## 8. 兼容性 / 安全注意事项

- **不动 protobuf**:本任务只在 HTTP 层做,客户端识别完全依赖既有 `custom_server.rs:39` 的文件名解析路径,旧客户端无任何改动也能消费产物。
- **老前端兼容**:Build 接口的 `relay_server` / `api_server` / `key` 任何一个空字符串都必须被接受并在文件名中省略,确保兼容只填 `host` 的最小配置。
- **数据库迁移回滚**:GORM AutoMigrate 只新增表,不会改老表;手动回滚命令 `DROP TABLE client_builder_artifacts`。`DatabaseVersion` 是单调自增,降级回滚把 `cmd/apimain.go:26` 改回上一版本号即可(因为 `apimain.go:289-313` 的 `Migrate` 是无条件 AutoMigrate,降级不会删字段)。
- **敏感字段不落盘**:`key` 仅落 `global.Cache`(可能是 Redis / Memory),不写到任何持久库,不打印到日志(下载日志只输出 sha8(token));`audit_log` 可记录 `created_by + artifact_id + ts`,但**不要**记录 key 明文。
- **token 性质**:32 字节 `crypto/rand` 生成 + base64url,TTL ≤ 7 天,且 `global.Cache` 是 in-process 或外部 Redis,重启后内存 cache 失效是预期。token 仅用于下载授权,**不携带任何鉴权能力**。
- **下载限流**:`/api/client-builder/download/:token` 必须复用现有 `middleware` 限流或对 token 维度限频(建议名:`utils.NewDownloadLimiter(token, 30/min)`,可调整)。如果短期内不实现限流,至少给 Nginx/反向代理留个 path 用于配置 rate-limit。
- **基础 EXE 体积**:由 `max-base-mb` 卡,上传时检查 `file.Size`;流式 sha256(`io.Copy(hasher, src)`)避免一次性读入内存。
- **路径穿越**:`local_path` 由服务端用 `filepath.Join(cfg.BaseDir, sha256+".exe")` 派生,不接受客户端传入;响应时 `c.FileAttachment` 之前 `filepath.Clean` 二次校验在 `BaseDir` 之内。
- **下载文件名**:用 RFC 5987 的 `filename*=UTF-8''<percent-encoded>` 形式,避免浏览器/代理把 `,` `=` 当作 header 分隔符。
- **公开端点暴露**:`/api/client-builder/landing/:token` HTML 模板必须对 host/key/api/relay 做 HTML 转义,防 XSS。
- **不签名 / 不改 icon**:严格按任务要求,跳过 Windows codesign 与 PE 资源改写,以避免引入 Authenticode 与 osslsigncode 依赖。

## 9. 回滚方案

- **功能开关**:配置项 `client-builder.enabled: false`,服务启动时如为 `false`,`ClientBuilderBind` 不注册路由(在 `admin.go` / `api.go` 注册函数内首行判断)。
- **数据库回滚**:`DROP TABLE client_builder_artifacts;` 不会影响其它功能。`DatabaseVersion` 改回上一版本(注释说明)。
- **缓存清理**:Redis `redis-cli --scan --pattern 'client_builder:token:*' | xargs redis-cli del`;Memory cache 重启进程即可。
- **磁盘清理**:`rm -rf data/client-builder/base/*` 删除基础 EXE;生成的下载是流式响应,不会在磁盘留下二次副本。
- **路由摘除**:`router/admin.go` 中注释掉 `ClientBuilderBind(adg)` 一行 + `router/api.go` 中的三条公开路由,即可彻底关闭。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-api/model/clientBuilderArtifact.go` 已实现,字段与 §4.1 一致。
- [ ] `DatabaseVersion` bump 完毕,`AutoMigrate` 包含新表;`cd rustdesk-api && go test ./model ./service` 通过。
- [ ] 服务层 `BuildFilename` 在 §6 测试 #1/#2/#3 全部通过,且单测包含等价于 `rustdesk/src/custom_server.rs:39-87` 的解析 oracle。
- [ ] Admin 接口需要 `BackendUserAuth + AdminPrivilege`,普通用户被 403(测试 #7)。
- [ ] 公开 `/api/client-builder/download/:token` 在 token TTL 内可流式下载,过期返回 410(测试 #8/#9)。
- [ ] 二维码 PNG 可由 `GET /api/client-builder/qr/:token` 拉取,Landing HTML 渲染含二维码与下载按钮。
- [ ] 配置项 `client-builder.enabled=false` 时全部路由不注册、且单测启动用例不报错。
- [ ] `data/client-builder/base/` 目录存在,`.gitignore` 排除 `*.exe`,仓库 diff 不含任何二进制。
- [ ] `key` 字段不出现在任何日志、审计、数据库列中(`grep -R "Key" rustdesk-api/runtime/log.txt` 应空)。
- [ ] `cd rustdesk-api && go test ./...` 全绿(或记录已知失败)。
- [ ] 在 `docs/ai-development-plan.md` 的 CE-M1-9 任务卡末尾追加 "状态: 完成 (commit <hash>)"。
