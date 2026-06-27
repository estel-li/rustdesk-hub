# CE-M0-4 rustdesk-api Redis / metrics healthcheck

## 1. 任务目标

为 `rustdesk-api` 二进制增加两项可观测性能力,使其满足 `docs/ai-development-plan.md:164-182` 任务卡 "CE-M0-4 rustdesk-api Redis / metrics healthcheck" 的要求:

1. 启动阶段对 `Redis`(`global.Config.Redis`)以及缓存后端(`global.Config.Cache`)执行一次显式 healthcheck;Redis/外部缓存不可用时 **不得让默认 SQLite + 内存缓存部署崩溃**,而是退化为内存缓存并写出清晰错误日志。
2. 暴露 Prometheus `/metrics` 端点(默认绑定独立 loopback 端口,不与业务 API 抢占 21114)用于后续 RBAC/MFA/Audit 排障。

验收信号(对应 `docs/ai-development-plan.md:178-182`):
```
cd rustdesk-api
go test ./...
go test ./lib/cache ./utils
```
并能通过 `curl http://127.0.0.1:<metrics_port>/metrics` 拿到非空指标,且 `cache.type` 未配置时进程仍能正常 `apimain` 启动。

## 2. 上下文与依赖

- 上游依赖:
  - `CE-M0-3 metrics 独立端口`(`docs/ai-development-plan.md:146-162`)。本卡片继承其 "metrics 不抢 21114" 约束。
- 下游依赖:
  - `CE-M1` 系列(RBAC/MFA/Audit)需要 `/metrics` 指标用于排障(`docs/ai-development-plan.md:169`)。
  - `CE-M0-5 systemd 加固`(`docs/ai-development-plan.md:184-194`)如果对 API 进程加 `ProtectSystem=strict`,需保证 metrics 端口已固化在配置中。
- 关键背景事实:
  - `rustdesk-api/cmd/apimain.go:127-131` 不论 `cache.type` 是什么都会构造 `global.Redis = redis.NewClient(...)` 但 **从未调用 `Ping`**——配置错误时只会在第一次实际访问时报错。
  - `rustdesk-api/cmd/apimain.go:134-144` 中 `cache.type` 只识别 `file` 与 `redis`;其它取值(包括默认空串、`memory`)走 **else 分支不赋值**,`global.Cache` 会保持 `nil`,后续任何使用 `global.Cache.Get` 的代码会 panic。这是当前默认部署的隐藏雷区,本卡片必须修复。
  - `rustdesk-api/lib/cache/cache.go:15-35` 已经在 `New(typ string)` 中支持 `TypeMem` 与默认 `NewMemoryCache(0)`,但 `apimain.go` 没有调用它。
  - `rustdesk-api/lib/cache/redis.go:11-19` 中 `RedisCache` 无 `Ping` 方法,需要新增以便 healthcheck 复用。
  - `rustdesk-api/http/http.go:13-41` 是 gin 引擎装配点,路由通过 `router.WebInit/Init/ApiInit` 注册。新增 `/metrics` 应在此处或新文件中挂载,且要在 `Run(g, ...)` 之前完成。
  - `rustdesk-api/http/run.go:1-13`(非 Windows)调用 `endless.ListenAndServe(addr, g)`,即只监听一个地址。如果 metrics 走独立端口,必须新增一个 `go http.ListenAndServe(...)`,**且不能用 endless**(endless 是全局信号驱动,不能跑两个 endless 实例)。
  - `rustdesk-api/config/config.go:34-50` 是 `Config` 聚合结构,新增 `Metrics` 子段需要在此挂载,并按 `mapstructure` tag 约定使用短横线命名(参见 `config/cache.go:5-8`)。
  - `rustdesk-api/conf/config.yaml:20-24` 现有 `gin.api-addr` 默认 `0.0.0.0:21114`。Metrics 默认地址必须独立(建议 `127.0.0.1:21115`,见 §4)。
  - `rustdesk-api/go.mod:1-35` 当前未引入 `prometheus/client_golang`,需要 `go get`。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|---|---|---|---|
| `rustdesk-api/config/cache.go` | 修改 | +0/0 | 不改字段,但确认 `Type` 默认空串语义在 `apimain.go` 内被映射到 `memory`(由 §5 步骤实现) |
| `rustdesk-api/config/metrics.go` | 新建 | ~12 | 新增 `Metrics` 配置结构(`enable` / `bind` / `path`) |
| `rustdesk-api/config/config.go` | 修改 | +1 | 在 `Config` 中嵌入 `Metrics Metrics` |
| `rustdesk-api/conf/config.yaml` | 修改 | +5 | 增加默认 `metrics:` 节,默认 `enable: true`, `bind: 127.0.0.1:21115`, `path: /metrics` |
| `rustdesk-api/lib/cache/cache.go` | 修改 | +6 | 在 `Handler` 接口或单独 `Pinger` 接口中加入 `Ping(ctx) error`;`MemoryCache`/`FileCache` 实现返回 `nil` |
| `rustdesk-api/lib/cache/redis.go` | 修改 | +6 | 给 `RedisCache` 实现 `Ping(ctx) error`,调用 `c.rdb.Ping(ctx).Err()` |
| `rustdesk-api/lib/cache/memory.go` | 修改 | +3 | 实现 `Ping(ctx) error { return nil }` |
| `rustdesk-api/lib/cache/file.go` | 修改 | +3 | 实现 `Ping(ctx) error { return nil }`(若文件 healthcheck 失败则改为 `errors.New`,但默认实现保留 nil) |
| `rustdesk-api/cmd/apimain.go` | 修改 | +40 | 1) 用 `cache.New(...)` 替代 `if/else`;2) 对 redis cache 执行 `Ping`,失败 fallback 到内存 + Warn;3) 对 `global.Redis` 也 `Ping`,失败仅 Warn,不退出;4) 启动后调用 `http.StartMetricsServer()` |
| `rustdesk-api/http/metrics.go` | 新建 | ~50 | 包含 `StartMetricsServer()`、`metricsRegistry` 单例、`RegisterCollector(c prometheus.Collector)` 暴露给业务层 |
| `rustdesk-api/http/middleware/metrics.go` | 新建 | ~40 | 提供 gin 中间件 `MetricsMiddleware(reg *prometheus.Registry)`,导出 `http_requests_total{method,path,status}` 与 `http_request_duration_seconds` |
| `rustdesk-api/http/http.go` | 修改 | +3 | 在 `g.Use(...)` 链中加 `middleware.Metrics(...)`;返回前调用 `StartMetricsServer()` |
| `rustdesk-api/go.mod` / `go.sum` | 修改 | +N | `go get github.com/prometheus/client_golang@v1.20.x` |
| `rustdesk-api/http/metrics_test.go` | 新建 | ~80 | 测试 `/metrics` 暴露 + 中间件计数 + Registry 复用 |
| `rustdesk-api/lib/cache/redis_test.go` | 修改 | +20 | 新增 `TestRedisCache_PingFail`,使用错误 addr 验证 `Ping` 返回非 nil |
| `rustdesk-api/lib/cache/memory_test.go` | 修改 | +5 | `TestMemoryCache_Ping_Nil` |
| `rustdesk-api/cmd/apimain_healthcheck_test.go` | 新建 | ~80 | 用 mini test 隔离验证 `initCacheWithFallback` 行为(redis 不可达 → fallback memory) |
| `docs/ai-development-plan.md` | 修改 | +1 | 在 CE-M0-4 末尾追加完成状态行 |

## 4. 数据契约

### 4.1 YAML 配置项(`conf/config.yaml`)

新增节(建议命名,可调整):
```yaml
metrics:
  enable: true                # bool, 默认 true
  bind: "127.0.0.1:21115"     # string, 默认 127.0.0.1:21115; 建议保持 loopback
  path: "/metrics"            # string, 默认 /metrics
```

环境变量(沿用 `config/config.go:67-69` 的 `RUSTDESK_API_` 前缀,`.`→`_`,`-`→`_`):
- `RUSTDESK_API_METRICS_ENABLE=true|false`
- `RUSTDESK_API_METRICS_BIND=127.0.0.1:21115`
- `RUSTDESK_API_METRICS_PATH=/metrics`

### 4.2 Go 结构体

`rustdesk-api/config/metrics.go`(建议命名,可调整):
```go
package config

type Metrics struct {
    Enable bool   `mapstructure:"enable"`
    Bind   string `mapstructure:"bind"`
    Path   string `mapstructure:"path"`
}
```
`Config` 内嵌入 `Metrics Metrics`(参见 `config/config.go:34-50` 的模式)。

### 4.3 Handler 接口扩展

`rustdesk-api/lib/cache/cache.go:7-11` 当前:
```go
type Handler interface {
    Get(key string, value interface{}) error
    Set(key string, value interface{}, exp int) error
    Gc() error
}
```
扩展为:
```go
type Handler interface {
    Get(key string, value interface{}) error
    Set(key string, value interface{}, exp int) error
    Gc() error
    Ping(ctx context.Context) error
}
```
若担心破坏外部实现,可以拆为独立 `type Pinger interface { Ping(ctx context.Context) error }`,在 healthcheck 处类型断言。**推荐直接加进 Handler**,内部仅 3 个实现,改动可控。

### 4.4 HTTP 响应形状(`/metrics`)

标准 Prometheus 文本格式(`Content-Type: text/plain; version=0.0.4`),由 `promhttp.HandlerFor(registry, promhttp.HandlerOpts{})` 提供。

指标(建议命名,可调整,与 hbbs/hbbr 风格保持一致):
- `rustdesk_api_http_requests_total{method,path,status}` Counter
- `rustdesk_api_http_request_duration_seconds_bucket{method,path,le}` Histogram(buckets: `[.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10]`)
- `rustdesk_api_cache_backend{type}` Gauge=1,标识当前后端 (`memory|file|redis`)
- `rustdesk_api_cache_ping_failures_total{backend}` Counter
- 复用 `prometheus.NewGoCollector()` + `prometheus.NewProcessCollector()`(Go 运行时和进程指标)

## 5. 实现步骤

1. **新增依赖**:`cd rustdesk-api && go get github.com/prometheus/client_golang@latest && go mod tidy`。
2. **添加配置结构**:新建 `config/metrics.go`(见 §4.2);在 `config/config.go:34-50` 的 `Config` 结构里追加 `Metrics Metrics`;在 `conf/config.yaml` 末尾追加 `metrics:` 节(§4.1)。
3. **扩展 `Handler` 接口**:修改 `lib/cache/cache.go:7-11` 加入 `Ping(ctx context.Context) error`;在 `memory.go`、`file.go`、`redis.go` 分别实现(见 §3 行数估计);`redis.go` 中实现为 `return c.rdb.Ping(ctx).Err()`(参考已有 `ctx` 声明,`lib/cache/redis.go:9`)。
4. **抽取缓存初始化**:在 `cmd/apimain.go` 中,把现有 `apimain.go:134-144` 改写为新函数 `initCacheWithFallback(cfg *config.Config) cache.Handler`:
   - 用 `cache.New(cfg.Cache.Type)` 取代手写 switch,使空串/未知值落到 `MemoryCache`(`lib/cache/cache.go:31-33`)。
   - 对 redis cache,构造完成后 `ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)`,`if err := c.Ping(ctx); err != nil { Warn fallback to NewMemoryCache(0) }`。
   - 文件 / 内存 cache 仍调用 `Ping` 但永远 nil。
   - 返回值赋给 `global.Cache`。
5. **Redis 客户端 healthcheck**:在 `apimain.go:127-131` 之后立刻 `ctx,_:=context.WithTimeout(...,3*time.Second); if err := global.Redis.Ping(ctx).Err(); err != nil { global.Logger.Warnf("redis ping failed: %v (continuing without redis)", err) }`。**不退出进程**(`docs/ai-development-plan.md:174` 显式要求)。
6. **Metrics 注册中心**:新建 `http/metrics.go`,提供:
   - 包级 `Registry = prometheus.NewRegistry()` 单例;
   - `init()` 中 `Registry.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(...))`;
   - `RegisterCollector(c prometheus.Collector)` 暴露给业务层;
   - `StartMetricsServer(cfg config.Metrics, logger)`: 若 `!cfg.Enable` 直接返回;否则 `mux := http.NewServeMux(); mux.Handle(cfg.Path, promhttp.HandlerFor(Registry, promhttp.HandlerOpts{})); go http.ListenAndServe(cfg.Bind, mux)`;失败仅 Error 日志,不 panic。
7. **gin 中间件**:新建 `http/middleware/metrics.go`,导出 `Metrics()` 中间件,Counter+Histogram(见 §4.4),需要 `c.FullPath()`(避免高基数);label `path=""` 兜底。
8. **接入 gin**:`http/http.go:36` 处 `g.Use(...)` 末尾追加 `middleware.Metrics()`;`Run(g, ...)` 前调用 `StartMetricsServer(global.Config.Metrics, global.Logger)`。
9. **缓存后端指标**:在 §4(`initCacheWithFallback`)结尾根据最终选择的后端 `RegisterCollector` 一个 `prometheus.NewGaugeFunc` 暴露 `rustdesk_api_cache_backend`,失败计数器 `prometheus.NewCounter` 在每次 healthcheck 失败时 `.Inc()`。
10. **测试**:见 §6。
11. **文档**:在 `docs/ai-development-plan.md` 的 CE-M0-4 章节末追加 "状态: 完成 (commit <hash>)"(§10 最后一项 DoD)。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|---|---|---|---|
| 1 | `rustdesk-api/lib/cache/memory_test.go` | `TestMemoryCache_Ping_Nil` | `c := NewMemoryCache(0); c.Ping(ctx)` | 返回 `nil`(happy path / 默认部署兼容) |
| 2 | `rustdesk-api/lib/cache/redis_test.go` | `TestRedisCache_Ping_ReturnsErrorOnBadAddr` | `NewRedis(&redis.Options{Addr:"127.0.0.1:1"})` + `Ping(ctx, 500ms timeout)` | 返回非 nil(failure mode 1) |
| 3 | `rustdesk-api/lib/cache/redis_test.go` | `TestRedisCache_Ping_OK` | 走 `miniredis`(若不可用则 `t.Skip`) | 返回 nil(happy path,可选) |
| 4 | `rustdesk-api/cmd/apimain_healthcheck_test.go` | `TestInitCacheWithFallback_RedisUnreachable_FallsBackToMemory` | `cfg.Cache.Type="redis"`, `cfg.Cache.RedisAddr="127.0.0.1:1"` | 返回 `*MemoryCache` 而非 `*RedisCache`;日志含 "fallback" 关键字(failure mode 2) |
| 5 | `rustdesk-api/cmd/apimain_healthcheck_test.go` | `TestInitCacheWithFallback_EmptyType_DefaultsToMemory` | `cfg.Cache.Type=""`(老配置文件) | 返回 `*MemoryCache`,`global.Cache != nil`(backward-compat,修复当前 `apimain.go:134-144` 的隐藏 panic) |
| 6 | `rustdesk-api/cmd/apimain_healthcheck_test.go` | `TestInitCacheWithFallback_TypeFile_NoPing` | `cfg.Cache.Type="file"`,`FileDir=t.TempDir()` | 返回 `*FileCache`,无错误日志(backward-compat,与现有部署一致) |
| 7 | `rustdesk-api/http/metrics_test.go` | `TestMetricsHandler_ExposesGoMetrics` | 启动 metrics server 在随机端口,`GET /metrics` | `200`,body 含 `go_goroutines` 与 `rustdesk_api_cache_backend` |
| 8 | `rustdesk-api/http/metrics_test.go` | `TestMetricsMiddleware_CountsRequests` | gin 引擎挂 `middleware.Metrics()`,调用 `/api/version` 两次,再 `GET /metrics` | body 含 `rustdesk_api_http_requests_total{...path="/api/version"...} 2` |
| 9 | `rustdesk-api/http/metrics_test.go` | `TestMetricsServer_DisabledByConfig` | `cfg.Metrics.Enable=false` | 不监听端口,`net.Dial` 失败(failure mode 3,确保可关闭) |

## 7. 验证命令

按顺序执行(均在仓库根):
```bash
# 1. 依赖整理
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go mod tidy

# 2. 编译
go build ./...

# 3. 单测(对应 docs/ai-development-plan.md:179-182)
go test ./...
go test ./lib/cache ./utils

# 4. 启动后 smoke check(可选,macOS dev box 可跳过 systemd 部分)
./rustdesk-api &
sleep 1
curl -sf http://127.0.0.1:21115/metrics | grep -E '^rustdesk_api_http_requests_total|^go_goroutines'
curl -sf http://127.0.0.1:21114/api/version
kill %1
```

跳过说明:
- 步骤 4 中如果没有编译产物,可改用 `go run ./cmd`,但 macOS Apple Silicon 上的 `endless` 信号行为正常,毋须额外处理。
- 不需要在 macOS 上跑 systemd 相关命令(CE-M0-5 的范围)。

## 8. 兼容性 / 安全注意事项

- **接口扩展兼容**:修改 `cache.Handler` 接口会破坏潜在的下游自定义实现。当前仓库内只有 3 个实现(`memory.go`/`file.go`/`redis.go`),全部一并修改;如果有第三方插件,需要在 release notes 显式提示。或改为 `Pinger` 单独接口规避(见 §4.3 备选方案)。
- **YAML 老配置文件兼容**:不存在 `metrics:` 节时使用结构体零值;为此默认值必须在代码侧兜底(`if cfg.Metrics.Bind == "" { cfg.Metrics.Bind = "127.0.0.1:21115" }`),不能依赖 yaml 默认值。
- **Cache.Type 老配置兼容**:当前 `apimain.go:134-144` 把空串/"memory" 落到 `global.Cache=nil`;修复后改为内存缓存,**这是行为变更但属于 bug fix**。在 release notes 中提及。
- **Redis 不再强依赖**:即使 `cache.type=redis` 且 redis 不可达,进程必须启动,只 Warn 日志 + 自动降级到内存。这与 `docs/ai-development-plan.md:174` 一致。
- **端口安全**:metrics 默认绑 `127.0.0.1:21115`,**不要暴露到 0.0.0.0**。如需被远程 Prometheus 抓取,部署方应通过反向代理(配合 basic-auth)或 wireguard 暴露,而不是改默认值。
- **敏感字段不落盘**:metrics 不应含 user/token/IP label(高基数 + 隐私)。`path` label 必须用 `c.FullPath()`,不要用 `c.Request.URL.Path`(否则 `/api/peer/123` 会爆 cardinality)。
- **限流互动**:`middleware.Limiter()` 已在 `http/http.go:36` 链上,`middleware.Metrics()` 需要在 `Limiter` 之前注册以便统计被限流的 4xx 请求。
- **不与 21114 抢占**:对齐 CE-M0-3 (`docs/ai-development-plan.md:54, 528`),默认 bind 严格独立。

## 9. 回滚方案

- 代码:`git revert <commit>`。新增文件随之删除,`config/config.go` / `http/http.go` / `cmd/apimain.go` 回到原状。
- 配置:`conf/config.yaml` 中的 `metrics:` 节被视为可选;若用户已写入,旧二进制忽略未知键(viper 默认行为),无需手动清理。
- 依赖:`go.mod` 中 `prometheus/client_golang` 在 revert 时会被移除;运行 `go mod tidy`。
- 数据库:本卡片**不涉及数据库迁移**,无需 down migration。
- Feature flag:除上述 `metrics.enable: false` 可关闭 metrics 服务器外,Redis healthcheck 的 fallback 是无开关默认行为(因为它是修 bug)。若临时需要旧 panic 行为,可在 commit 内预留环境变量 `RUSTDESK_API_CACHE_STRICT=true`(建议命名,可调整)走 fatal 路径。

## 10. 完成定义 (DoD)

- [ ] `config/metrics.go` 新建,`Config` 嵌入 `Metrics`,`conf/config.yaml` 含默认 `metrics:` 节。
- [ ] `cache.Handler` 新增 `Ping(ctx) error`,三个实现全部通过。
- [ ] `cmd/apimain.go` 中 redis client 与 cache 后端均执行 healthcheck;失败不退出,降级到 memory 且 Warn 日志。
- [ ] `cmd/apimain.go` 修复 `cache.type` 为空/未知时 `global.Cache=nil` 的隐藏 panic(改走 `cache.New(...)`)。
- [ ] `http/metrics.go` + `http/middleware/metrics.go` 新建,`/metrics` 默认监听 `127.0.0.1:21115`,与 `21114` 完全独立。
- [ ] `go test ./...` 与 `go test ./lib/cache ./utils` 均通过。
- [ ] `curl http://127.0.0.1:21115/metrics` 返回非空,包含 `rustdesk_api_http_requests_total` 与 `go_goroutines`。
- [ ] `metrics.enable: false` 时进程不监听 21115 端口。
- [ ] Release notes / CHANGELOG 内记录 "Cache.Type 空值默认从 nil 改为 memory" 这一行为变更。
- [ ] 在 `docs/ai-development-plan.md` 的 CE-M0-4 任务卡末尾追加 "状态: 完成 (commit <hash>)"。
