# CE-M0-2 hbbs PostgreSQL 后端

## 1. 任务目标

在 `rustdesk-server/src/database.rs` 中抽象出 SQLite / PostgreSQL 双后端,保持 SQLite 默认行为不变(老部署零迁移),通过 `DB_URL` 的 scheme 自动选择后端;当后端为 Postgres 时,连接池默认上限从 1 提升到 32。验收信号:`cd rustdesk-server && cargo check` 成功;`cargo test database` 通过;在仅设置 `DB_URL=postgres://...` 的环境下 hbbs 启动后 `peer` 表自动建立,`peer.rs` 中三处 DB 调用(`insert_peer` / `update_pk` / `get_peer`,见 `rustdesk-server/src/peer.rs:87,116,126,140`)行为与 SQLite 完全等价。

任务卡原文(`docs/ai-development-plan.md:123-144`):

> 目标:
> - `rustdesk-server/src/database.rs` 抽象出后端接口。
> - 保留 SQLite 默认行为。
> - 增加 PostgreSQL 后端,连接池默认上限可从 1 提升到 32。
>
> 执行步骤:
> 1. 先读 `database.rs` 当前 schema 与调用点。
> 2. 引入最小 trait 或 enum,不要大规模重写 PeerMap。
> 3. 所有 SQL 字段与 SQLite 语义保持一致。
> 4. 配置仍支持现有 `DB_URL`,新增 Postgres DSN 解析时保持向后兼容。

## 2. 上下文与依赖

- 上游依赖任务卡
  - CE-M0-1 hbb_common fork 对齐(`docs/ai-development-plan.md:101-121`)。本卡不会触碰 `hbb_common`,但 `sqlx` 依赖了 `tokio` runtime,务必在 M0-1 完成后再编译,避免与 hbb_common 的 tokio re-export 版本冲突。
- 下游会用到此输出的任务卡
  - CE-M0-3 metrics 独立端口(`docs/ai-development-plan.md:146-162`)。`Database` 需要在后端层暴露连接池占用、查询计数等指标钩子,本卡只预留 `pub fn backend_kind(&self) -> &'static str` 接口,不实装指标。
  - CE-M0-6 PeerMap GC 与 tcp_punch key(`docs/ai-development-plan.md:202-220`)。GC 可能扫描 `peer.created_at` 字段,本卡需要保证字段在两个后端语义一致。
  - 后续 M1 RBAC / 审计如要在 hbbs 写新表,会复用同一后端抽象。
- 关键背景事实
  - 当前 `Database` 单一基于 `SqliteConnection`,见 `rustdesk-server/src/database.rs:10-31`:`Pool = deadpool::managed::Pool<DbPool>`,`Manager::Type = SqliteConnection`。
  - 建表 SQL 使用 SQLite 方言:`blob`、`without rowid`、`tinyint`、`current_timestamp`,见 `rustdesk-server/src/database.rs:71-94`。
  - 三个 CRUD 查询均使用 `sqlx::query!` / `sqlx::query_as!` 编译期宏(`database.rs:97-104, 114-123, 134-141`),宏依赖 `DATABASE_URL`(已有 `.env: DATABASE_URL=sqlite://./db_v2.sqlite3`)。为支持双后端,**必须改为运行时 `sqlx::query` / `sqlx::query_as`**,放弃编译期校验。
  - `Database::new` 在 `database.rs:51-53` 用 `std::path::Path::new(url).exists()` 判断是否需要 `File::create(url)`,这对 sqlite 文件路径是合理的,对 `postgres://` URL 必须跳过。
  - `MAX_DATABASE_CONNECTIONS` 默认值字符串 `"1"`,见 `database.rs:54-58`,改造时不能直接破坏老 SQLite 默认。
  - `PeerMap` 在 `rustdesk-server/src/peer.rs:65` 持有 `db: database::Database`,要求 `Database: Clone`(见 `database.rs:33-36`),抽象后仍需 `Clone`。
  - `PeerMap::new` 在 `peer.rs:70-83` 通过 `std::env::var("DB_URL")` 读取 DSN,默认拼出 `./db_v2.sqlite3`(类 Unix)或 Windows 下基于 `Config::icon_path()` 的绝对路径。本卡保留这部分逻辑。
  - `database::Peer` 结构体字段全部为 `Option<...>` / `Vec<u8>` / `String` / `i64`,见 `database.rs:38-47`,需要在两个后端解码时保持一致。
  - `Cargo.toml:33` 当前 sqlx features 为 `["runtime-tokio-rustls", "sqlite", "macros", "chrono", "json"]`,需要增补 `postgres` 与可能的 `any`,并视需求去掉 `macros`(因为我们将不再用编译期宏)。但任务卡要求"最小 trait 或 enum,不要大规模重写",因此**保留 `macros` 不强删,只增量加 `postgres`**。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|------|------|----------|------|
| `rustdesk-server/Cargo.toml` | 修改 | +2 / -1 | 在 sqlx features 增加 `"postgres"`;新增 `url = "2"` 用于 DSN scheme 解析(建议命名,可调整,也可用 `str::starts_with` 不引入新依赖) |
| `rustdesk-server/src/database.rs` | 修改 | ~+200 / -80 | 拆出 `Backend` enum、`SqliteBackend` 与 `PostgresBackend` 两个分支;改 `sqlx::query!` 宏为运行时 `sqlx::query` / `sqlx::query_as`;`new` 内根据 scheme 分派;`create_tables` 内根据后端发不同方言 DDL |
| `rustdesk-server/src/peer.rs` | 修改 | +2 / -0 | 仅在日志 `log::info!("DB_URL={}", db)` 旁加一行 `log::info!("DB backend kind: {}", self.db.backend_kind())` 用于排障;不动 `db.get_peer / insert_peer / update_pk` 调用面 |
| `rustdesk-server/.env` | 不动 | 0 | 保留 `DATABASE_URL=sqlite://./db_v2.sqlite3`,仅供本地 sqlx CLI 离线准备使用;若改造彻底放弃 sqlx 宏,可在文档备注其已无强约束 |
| `rustdesk-server/tests/database_backend.rs` | 新建 | ~120 | 集成测试:SQLite 临时文件路径走 CRUD;Postgres 测试用 `#[ignore]` + `RUSTDESK_TEST_PG_URL` 环境变量(macOS 开发机默认跳过) |
| `docs/operations/database.md` | 新建 | ~80 | 运维文档:`DB_URL` 取值约定、PG schema 初始化方式、回滚到 SQLite 的步骤 |
| `docs/ai-development-plan.md` | 修改 | +1 | 在 CE-M0-2 任务卡末尾追加完成标记(DoD 最后一项) |

未找到:无。所有目标文件均存在。

## 4. 数据契约

### 4.1 后端选择(DSN 解析,建议命名,可调整)

输入:`DB_URL` 环境变量(已有约定,见 `peer.rs:70`)。规则按以下顺序判定:

1. `postgres://...` 或 `postgresql://...`  → `BackendKind::Postgres`
2. `sqlite://...`                          → `BackendKind::Sqlite`(剥离 scheme 后作为文件路径)
3. 其他(裸路径,例如 `./db_v2.sqlite3`)  → `BackendKind::Sqlite`,保持现有 `Path::exists` + `File::create` 旧行为

### 4.2 Backend enum(Rust)

```rust
// 仅签名;实现见 §5
#[derive(Clone)]
pub struct Database { inner: Backend }

#[derive(Clone)]
enum Backend {
    Sqlite(deadpool::managed::Pool<SqliteDbPool>),
    Postgres(sqlx::PgPool),
}

impl Database {
    pub async fn new(url: &str) -> ResultType<Database>;
    pub async fn get_peer(&self, id: &str) -> ResultType<Option<Peer>>;
    pub async fn insert_peer(&self, id: &str, uuid: &[u8], pk: &[u8], info: &str) -> ResultType<Vec<u8>>;
    pub async fn update_pk(&self, guid: &Vec<u8>, id: &str, pk: &[u8], info: &str) -> ResultType<()>;
    pub fn backend_kind(&self) -> &'static str; // "sqlite" | "postgres"
}
```

`Peer` 结构体字段不变(`database.rs:38-47`)。

### 4.3 SQL DDL

#### SQLite 方言(保持与 `database.rs:71-89` 字节级一致,不改一处)

```sql
create table if not exists peer (
    guid blob primary key not null,
    id varchar(100) not null,
    uuid blob not null,
    pk blob not null,
    created_at datetime not null default(current_timestamp),
    user blob,
    status tinyint,
    note varchar(300),
    info text not null
) without rowid;
create unique index if not exists index_peer_id on peer (id);
create index if not exists index_peer_user on peer (user);
create index if not exists index_peer_created_at on peer (created_at);
create index if not exists index_peer_status on peer (status);
```

#### PostgreSQL 方言(等价语义,字段名一一对应)

```sql
create table if not exists peer (
    guid          bytea       primary key not null,
    id            varchar(100) not null,
    uuid          bytea       not null,
    pk            bytea       not null,
    created_at    timestamptz not null default current_timestamp,
    "user"        bytea,
    status        smallint,
    note          varchar(300),
    info          text        not null
);
create unique index if not exists index_peer_id on peer (id);
create index if not exists index_peer_user on peer ("user");
create index if not exists index_peer_created_at on peer (created_at);
create index if not exists index_peer_status on peer (status);
```

注:`user` 是 PG 保留字,必须加双引号。`without rowid` 在 PG 无对应概念,直接省略。`tinyint` → `smallint`(PG 无 tinyint,smallint 占用最小)。

### 4.4 运行时 SQL 占位符

- SQLite:`?` 占位符,与 `database.rs:99,115,135` 保持一致。
- Postgres:`$1, $2, $3, ...` 占位符。

实现层不要共享一份 SQL 字符串,改为各后端持有各自字面量(见 §5 step 3)。

### 4.5 配置项

| 名称 | 类型 | 默认 | 含义 |
|------|------|------|------|
| `DB_URL` | env | `./db_v2.sqlite3`(Unix)/ icon_path 拼接(Windows) | 已存在,见 `peer.rs:70-83` |
| `MAX_DATABASE_CONNECTIONS` | env | SQLite=1,Postgres=32 | 现有变量,默认值按后端区分 |
| `RUSTDESK_TEST_PG_URL` | env | 未设置 | 仅测试用,集成测试在缺省时 skip |

## 5. 实现步骤

1. **`Cargo.toml` 添加 Postgres feature**(`rustdesk-server/Cargo.toml:33`)
   将
   `sqlx = { version = "0.6", features = [ "runtime-tokio-rustls", "sqlite", "macros", "chrono", "json" ] }`
   改为追加 `"postgres"`。不要移除 `"macros"`,以免影响其他可能存在的宏使用(目前没有,但保留以备旧 build cache 兼容)。可选:增 `url = "2"` 用于 scheme 判定;若不引入,改用 `url.starts_with("postgres://") || url.starts_with("postgresql://")`。

2. **重写 `Database::new`**(替换 `database.rs:50-69`)
   - 分支判定 backend kind。
   - SQLite 分支:保留 `Path::new(url).exists()` + `File::create` 旧行为(`database.rs:51-53`),但要先把 `sqlite://` 前缀剥离再传给 `Path::new`,否则会创建一个名为 `sqlite:/...` 的怪文件。
   - SQLite 池:沿用现有 `deadpool::managed::Pool<DbPool>`,默认 `MAX_DATABASE_CONNECTIONS=1`。
   - Postgres 分支:用 `sqlx::postgres::PgPoolOptions::new().max_connections(n).connect(url).await?`;`n` 默认 32,从 `MAX_DATABASE_CONNECTIONS` 解析覆盖。
   - 二者均调用各自 `create_tables`。

3. **拆分 `create_tables`**(替换 `database.rs:71-94`)
   - `create_tables_sqlite(conn: &mut SqliteConnection)`:照搬现有 DDL 字符串。
   - `create_tables_pg(pool: &PgPool)`:用 §4.3 Postgres DDL,**逐条** `sqlx::query(stmt).execute(pool).await?`(PG 默认 simple_query 不允许一条 prepare 带多 statement,逐条执行最稳)。

4. **改造 `get_peer`**(替换 `database.rs:96-104`)
   - 用 `sqlx::query_as::<_, Peer>(...)` 运行时变体。
   - 为 `Peer` 派生 `sqlx::FromRow`(注意 SQLite 与 PG 列类型映射差异:`tinyint` → `i64` 对应 `Option<i64>`,PG `smallint` 解码到 `i16` 后再 cast。建议在结构体 trait `FromRow` 中分别为两个后端写两个 impl,或者把 `status` 字段在 PG 端读为 `i16` 后转 `i64`。**最简方案**:保留 `status: Option<i64>`,在 PG 表中将 `status` 列类型改为 `bigint`?——不行,任务卡要求字段语义一致,smallint 更省。折中:为 `Peer` 写两个 `from_row_sqlite` / `from_row_pg` 自定义函数,避免 `FromRow` trait 直接套用。
   - 二选一根据 `self.inner` 分派。

5. **改造 `insert_peer`**(替换 `database.rs:106-125`)
   - 仍生成 `guid = uuid::Uuid::new_v4().as_bytes().to_vec()`。
   - SQLite 分支用现有 SQL 字面量 + `?` 占位符,通过 `sqlx::query(sql).bind(...).execute(conn).await?`。
   - Postgres 分支用 `insert into peer(guid, id, uuid, pk, info) values($1, $2, $3, $4, $5)`,`.bind(...)` 顺序与 SQLite 完全一致。

6. **改造 `update_pk`**(替换 `database.rs:127-144`)
   - 同 step 5 的双分支套路,SQL 仅 placeholder 不同。

7. **暴露 `backend_kind`**(新增方法,放在 `database.rs:145` impl 末尾)
   - 返回 `"sqlite"` / `"postgres"`,供 metrics 与日志使用。

8. **更新 `peer.rs` 日志**(`rustdesk-server/src/peer.rs:84` 之后)
   - 在 `log::info!("DB_URL={}", db)` 后追加
     `log::info!("DB backend kind: {}", pm.db.backend_kind());`
   - 注意要在 `PeerMap` 构造完毕后再打,避免借用问题。

9. **重写 `database.rs` 内嵌测试**(替换 `database.rs:147-181`)
   - 原 `test_insert` 是 10k 插入压测,运行很慢且需要写盘。
   - 保留它但加 `#[ignore]`(默认 `cargo test` 不跑,需要 `cargo test -- --ignored`),避免 CI 拖慢。
   - 新增一个轻量 happy-path 单测 `test_sqlite_crud`,使用 `tempfile::NamedTempFile` 或 `std::env::temp_dir()` 路径,完整覆盖 insert → get → update_pk → get 链。

10. **新增集成测试 `tests/database_backend.rs`**
    - 见 §6。
    - SQLite 用临时路径,默认运行。
    - PG 用 `#[ignore]` + 读取 `RUSTDESK_TEST_PG_URL`;未设置则 skip(避免阻塞 macOS 开发箱)。

11. **写运维文档 `docs/operations/database.md`**
    - `DB_URL` 三种取值示例。
    - PG 推荐 `max_connections >= 32`;hbbs 端 `MAX_DATABASE_CONNECTIONS` 配套配置。
    - 从 PG 回退到 SQLite 的回滚步骤(导出 `peer` 表 CSV → 用 `sqlite3` import)。

12. **追加任务卡完成状态**
    - 在 `docs/ai-development-plan.md` 第 144 行(CE-M0-2 任务卡末尾,即 "如果子模块未初始化导致无法构建,记录原因并给出可复现初始化命令。" 之后)追加一行:
      `状态: 完成 (commit <hash>)`。

## 6. 测试用例

| # | 测试文件路径 | 测试名 | 输入 | 期望 |
|---|--------------|--------|------|------|
| 1 | `rustdesk-server/src/database.rs` | `tests::test_sqlite_crud` | `Database::new("<tempdir>/t.sqlite3")` 之后:`insert_peer("alice", b"u", b"k", "{}")` → `get_peer("alice")` → `update_pk(guid, "alice", b"k2", "{\"ip\":\"1.1.1.1\"}")` → `get_peer("alice")` | 第一次 `get_peer` 返回 `Some(Peer)` 且 `pk == b"k"`,`update_pk` 后 `pk == b"k2"`、`info` 反映新值,`guid` 不变 |
| 2 | `rustdesk-server/src/database.rs` | `tests::test_sqlite_missing_peer` | `Database::new(...)` 之后 `get_peer("not-exist")` | 返回 `Ok(None)`,不报错 |
| 3 | `rustdesk-server/src/database.rs` | `tests::test_sqlite_path_with_scheme` | `Database::new("sqlite://<tempdir>/t2.sqlite3")` | 成功创建文件 `<tempdir>/t2.sqlite3`(剥离 scheme),不会生成 `sqlite:/...` 怪文件 |
| 4 | `rustdesk-server/src/database.rs` | `tests::test_insert` (旧测试,加 `#[ignore]`) | 10k 并发 insert/get | `cargo test -- --ignored` 通过;默认 `cargo test` 跳过 |
| 5 | `rustdesk-server/tests/database_backend.rs` | `sqlite_legacy_default_path` | 不设置 `DB_URL`(模拟旧部署),`Database::new("./db_v2.sqlite3")` | 行为与旧版本字节级一致:文件被创建、表被建好、`backend_kind() == "sqlite"` |
| 6 | `rustdesk-server/tests/database_backend.rs` | `postgres_crud` (`#[ignore]`) | `RUSTDESK_TEST_PG_URL` 指向本地 PG;同 #1 的 CRUD 序列 | 全链路通过;校验 `backend_kind() == "postgres"`;并发 32 个 insert 不报 `too many connections` |
| 7 | `rustdesk-server/tests/database_backend.rs` | `postgres_create_tables_idempotent` (`#[ignore]`) | 同一 PG URL 上连续 `Database::new` 两次 | 第二次不抛错(`create table if not exists` + `create index if not exists` 都幂等) |
| 8 (兼容) | `rustdesk-server/tests/database_backend.rs` | `sqlite_max_connections_env_respected` | 设 `MAX_DATABASE_CONNECTIONS=4`,SQLite 后端 | 池容量 == 4;默认无此 env 时 == 1(老行为) |

## 7. 验证命令

按顺序执行:

```bash
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-server

# 1. 编译。M0-1 没完成前可能因 hbb_common pin 失败,需先确认 submodule 状态
git submodule status

# 2. 构建检查
cargo check

# 3. 单元测试 + 集成测试(SQLite 部分)
cargo test database
cargo test --test database_backend sqlite

# 4. 旧 10k 压测(可选,慢)
cargo test database::tests::test_insert -- --ignored

# 5. Postgres 集成测试 —— macOS 开发箱默认跳过
# 如本机无 PG,可改用 docker:
# docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=test postgres:15
RUSTDESK_TEST_PG_URL=postgres://postgres:test@127.0.0.1:5432/postgres \
  cargo test --test database_backend postgres -- --ignored

# 6. 烟测:用 PG 启动 hbbs(可选,需要 PG)
DB_URL=postgres://postgres:test@127.0.0.1:5432/postgres \
MAX_DATABASE_CONNECTIONS=32 \
  cargo run --bin hbbs -- -k _
# 启动日志应有: DB_URL=postgres://...   DB backend kind: postgres
```

macOS 跳过项:
- 步骤 5、6 需要本机 PostgreSQL 实例。**macOS 开发箱默认无 PG 服务,可跳过**,但必须在 PR 描述里说明替代验证(例如在 Linux CI 用 docker compose 起 PG 跑同样命令);本地至少跑 1-4。
- 步骤 6 需要 hbbs key 与端口,纯启动验证用 `_` 占位 key 即可。

## 8. 兼容性 / 安全注意事项

- **protobuf 兼容**:本卡不动 protobuf,无需考虑。
- **老服务端 / 老客户端互通**:DB 后端是服务端内部细节,客户端不感知。无线协议变化。
- **老 SQLite 数据零迁移**:DSN 默认值 `./db_v2.sqlite3` 不变,`peer` 表结构与列顺序不动,`without rowid` 旧表继续可用。`Database::new` 的 `File::create(url).ok()` 行为对旧路径保持不变。
- **`sqlx::query!` 宏移除**:运行时 query 失去编译期校验,要靠测试保证 SQL 正确。**新增 #1-#5 单测就是为弥补这点**。
- **DSN 暴露日志**:`peer.rs:84` 现在打印 `DB_URL=...`,如果是 PG DSN 会把密码写入日志。本卡需要在打印前做一次脱敏(替换 `:.*@` 为 `:***@`),避免敏感信息落盘。
- **PG 连接池上限**:默认 32,但要尊重 PG 的 `max_connections`;文档要提醒运维 PG 端至少配 `max_connections=64`。
- **限流 / 拒绝服务**:hbbs 注册风暴 + PG 连接耗尽会让所有 `get_peer` 排队。任务卡 M0-3 metrics 出来后再补告警;本卡不引入新限流,保持现状。
- **回滚向前兼容**:回滚到旧版 hbbs 二进制时,若 DB_URL 指向 PG,会因不支持而启动失败 —— 这是预期(用户应同步改回 sqlite DSN)。
- **测试隔离**:集成测试在 PG 上跑 CRUD,**禁止使用生产 schema/库**。`postgres_crud` 测试每次在临时 schema `rustdesk_test_<rand>` 中建表,结束 drop;若实现成本过高,允许保留 `peer` 表但每个测试在用唯一 `id` 字符串。

## 9. 回滚方案

- **代码层**:本卡所有改动集中在 `database.rs` + `peer.rs` 一行日志 + `Cargo.toml` 一行 feature。回滚 = `git revert <commit>`,无需迁移。
- **数据层**:SQLite 用户零影响。已切到 PG 的用户:
  1. 把 hbbs 的 `DB_URL` 改回 SQLite 路径并重启;PG 中的 `peer` 表保留作冷备份。
  2. 如需把 PG 数据导回 SQLite,用 `psql -c "\copy peer to 'peer.csv' with csv"` 后 `sqlite3 db_v2.sqlite3 ".mode csv" ".import peer.csv peer"`。文档 `docs/operations/database.md` 写明此步骤。
- **feature flag**:不引入 feature flag —— 后端选择已经由 `DB_URL` 这一既有配置项控制,本身就是开关。
- **`Cargo.toml`**:sqlx 新增 `postgres` feature 会让产物体积略增(约 +1MB),回滚时去掉该 feature 即可恢复旧体积。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-server/Cargo.toml` 已添加 sqlx `postgres` feature。
- [ ] `rustdesk-server/src/database.rs` 已抽象出 `Backend` enum 且对外接口(`new` / `get_peer` / `insert_peer` / `update_pk`)签名与返回值不变。
- [ ] SQLite 默认 DSN(`./db_v2.sqlite3`、`sqlite://...`、裸路径)三种取值都能成功 `Database::new`。
- [ ] PG DSN(`postgres://...` 与 `postgresql://...`)能成功 `Database::new` 并自动建表。
- [ ] `MAX_DATABASE_CONNECTIONS` 在 SQLite 后端仍默认 1,在 PG 后端默认 32。
- [ ] `peer.rs` 日志增加 `DB backend kind`,且对 PG DSN 做密码脱敏。
- [ ] `cargo check` 通过,`cargo test database` 通过(SQLite 用例)。
- [ ] PG 集成测试(`#[ignore]`)在已配置 `RUSTDESK_TEST_PG_URL` 的环境通过;macOS 开发箱可跳过但需在 PR 中说明。
- [ ] `peer.rs` 中三处 db 调用面(`insert_peer` / `update_pk` / `get_peer`)未改签名。
- [ ] `docs/operations/database.md` 新建,涵盖配置、初始化、回滚。
- [ ] 在 `docs/ai-development-plan.md` 的对应任务卡末尾追加 "状态: 完成 (commit <hash>)"。
