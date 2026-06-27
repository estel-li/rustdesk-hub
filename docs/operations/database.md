# hbbs 数据库后端运维指南

> 适用范围:CE-M0-2 之后的 `rustdesk-server`(hbbs)。
> 该任务卡引入了 SQLite / PostgreSQL 双后端,默认仍为 SQLite,老部署零迁移。

## 1. 配置项

| 变量 | 默认值 | 含义 |
|------|--------|------|
| `DB_URL` | `./db_v2.sqlite3`(Unix) / `<icon_path>\\db_v2.sqlite3`(Windows release) | 数据源 DSN。详见 §2 |
| `MAX_DATABASE_CONNECTIONS` | SQLite=`1`,Postgres=`32` | 连接池上限。Postgres 后端默认远高于 SQLite。建议保留默认值,除非明确知道自己在做什么 |
| `RUSTDESK_TEST_PG_URL` | 未设置 | 仅用于 `cargo test` 时连接的 PG 实例;生产环境无需关心 |

## 2. `DB_URL` 取值

后端通过 DSN 的 scheme 自动选择:

| DSN 形态 | 后端 | 说明 |
|----------|------|------|
| `./db_v2.sqlite3`(裸路径) | SQLite | 老部署默认;启动时若文件不存在会自动创建 |
| `sqlite:///var/lib/hbbs/db.sqlite3` | SQLite | `sqlite://` 前缀会被剥离,后面部分作为文件路径 |
| `postgres://user:pass@host:5432/dbname` | PostgreSQL | 标准 PG DSN |
| `postgresql://user:pass@host:5432/dbname` | PostgreSQL | 等价于 `postgres://`,sqlx 内部接受两种形式 |

启动日志会同时打印 DSN 与后端类型,密码会被脱敏:

```
INFO hbbs::peer: DB_URL=postgres://hbbs:***@10.0.0.2:5432/rustdesk
INFO hbbs::peer: DB backend kind: postgres
```

## 3. 初始化

无论哪种后端,hbbs 启动时都会执行 `create table if not exists peer (...)` 与四个 `create index if not exists ...` 语句,**幂等**,可安全重复执行。

PG 上的表结构等价于 SQLite,但因方言差异做了如下映射:

| SQLite | PostgreSQL | 备注 |
|--------|------------|------|
| `blob` | `bytea` | 二进制 |
| `datetime` | `timestamptz` | 默认 `current_timestamp` 保留 |
| `tinyint` | `smallint` | PG 没有 tinyint,smallint(2 字节)最接近 |
| `without rowid` | (省略) | PG 无对应概念 |
| 字段名 `user` | `"user"` | PG 保留字,必须加双引号 |

PG 端建议至少:

```sql
ALTER SYSTEM SET max_connections = 64;
```

并保留 32 余量给 hbbs 之外的运维 / 监控连接。

## 4. 从 SQLite 切换到 PostgreSQL

1. **创建 PG 库 + 账号**(示例):

   ```sql
   create database rustdesk;
   create user hbbs with password '...';
   grant all on database rustdesk to hbbs;
   ```

2. **(可选)迁移历史 `peer` 表数据**

   ```bash
   # SQLite 端导出
   sqlite3 db_v2.sqlite3 -header -csv "select guid, id, uuid, pk, created_at, user, status, note, info from peer" > peer.csv

   # PG 端导入(先在新库上启动一次 hbbs,以让表 / 索引创建好)
   psql -h <host> -U hbbs rustdesk -c "\copy peer from 'peer.csv' with csv header"
   ```

   注意 `guid`、`uuid`、`pk`、`user` 等字段是二进制(`blob` / `bytea`),CSV 中会是十六进制或 base64,导入前需校对格式。**首次切换建议直接让 hbbs 在 PG 上重新建表,不携带历史数据**;客户端会在下次握手时重新注册 `peer` 记录。

3. **更新 hbbs 启动环境变量**

   ```bash
   export DB_URL=postgres://hbbs:***@10.0.0.2:5432/rustdesk
   export MAX_DATABASE_CONNECTIONS=32
   systemctl restart hbbs
   ```

4. **验证**

   - 启动日志包含 `DB backend kind: postgres`。
   - `psql ... -c "select count(*) from peer;"` 能查询。
   - 客户端在线状态心跳后,`peer` 表会有对应行。

## 5. 回滚到 SQLite

1. 把 `DB_URL` 改回 SQLite 路径(典型 `./db_v2.sqlite3`),重启 hbbs。
2. 若需把 PG 上的 `peer` 数据带回 SQLite:

   ```bash
   psql -h <host> -U hbbs rustdesk -c "\copy peer to 'peer.csv' with csv header"
   sqlite3 db_v2.sqlite3 ".mode csv" ".import --skip 1 peer.csv peer"
   ```

3. SQLite 端老库不会被覆盖,导入失败时直接还原文件即可。

## 6. 故障排查

| 现象 | 排查方向 |
|------|----------|
| 启动报 `failed to connect to PostgreSQL` | DSN 是否正确;PG `pg_hba.conf` 是否允许 hbbs 的来源 IP;`max_connections` 是否充足 |
| `peer` 表存在但无新行 | 客户端是否能到达 hbbs `21116/UDP`;`MAX_DATABASE_CONNECTIONS` 是否过低导致阻塞 |
| 日志里 DSN 仍打印明文密码 | 升级到 CE-M0-2 之后版本(脱敏在 `peer.rs` 落地) |

## 7. 与其他任务卡的关系

- **CE-M0-3 metrics**:会基于 `Database::backend_kind()` 暴露后端类型 label。
- **CE-M0-6 PeerMap GC**:会读 `peer.created_at`,两个后端语义保持一致。
- **M1 RBAC / 审计**:新表 DDL 会复用同一后端抽象。
