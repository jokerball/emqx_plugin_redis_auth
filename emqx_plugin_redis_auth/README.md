# emqx_plugin_redis_auth

EMQX 5.x Redis 鉴权插件：将 Java 服务 `unmtr369auth` 的 `POST /mqtt/verify`
认证逻辑直接移植到 EMQX 插件内，EMQX 直连 Redis 完成设备接入校验，
不再依赖 Java 中间服务。

## 认证逻辑（与 Java AuthService.authDeviceInRedis 一致）

1. clientId / username / password 任一为空 → 拒绝
2. username 命中 `white_service_list` → 放行
3. username == `unm_username`（UNM2000）→ 用 `aes_key` 做
   AES-128-CBC/NoPadding（零 IV、零填充）解密 base64 密码，与
   `unm_expected_password` 比对
4. 其他设备：Redis `GET snindex:{realMac}` 必须存在，否则拒绝；
   clientId 含 `Tr369KeepAlived` 时提取真实 MAC（`MAC-Tag` 格式）
5. 保活通道：`HGET ap:{apId} status`：
   - 缺失或等于 `ap_status_offline`（"0"，主通道离线）→ 放行
   - 其他值（主通道在线）→ 拒绝（主通道在线，保活通道无需接入）
6. Redis 异常：默认 `fallback_allow_on_redis_error = true` 降级放行
   （与 Java catch 后 return allow 一致）

## 接入方式

插件以最高优先级注册到 EMQX 内置钩子 `client.authenticate`，
返回 `{stop, ...}` 终结认证链——**启用本插件后，EMQX 内置的
`authentication` 链（如原来的 HTTP 认证器）不会再被咨询**。
只需在平台侧把原 `/mqtt/verify` 的 HTTP 认证器删除，让设备直接
接入由本插件鉴权的 EMQX。

## 配置

插件启用后通过 Dashboard「插件扩展」页面或 REST API 修改：

```bash
# 查看当前配置
curl -u <apikey>:<secret> \
  http://127.0.0.1:18083/api/v5/plugins/emqx_plugin_redis_auth-1.0.0/config

# 更新配置（整体 PUT，会自动热生效并重连 Redis）
curl -u <apikey>:<secret> -X PUT \
  http://127.0.0.1:18083/api/v5/plugins/emqx_plugin_redis_auth-1.0.0/config \
  -H "Content-Type: application/json" -d '{ ... }'
```

关键参数（完整见 `priv/config.hocon`）：

| 参数 | 默认值 | 说明 |
|---|---|---|
| redis_host / redis_port | 127.0.0.1 / 6379 | Redis 地址 |
| redis_password / redis_database | "" / 0 | 密码与库号 |
| redis_pool_size | 8 | Redis 客户端连接数（eredis 无内置连接池，按 key 哈希分摊到 N 条连接） |
| redis_query_timeout_ms | 2000 | 单次查询超时 |
| snindex_key_prefix | snindex: | 设备索引键前缀（Java STR_INDEX_UID2ID） |
| ap_key_prefix / ap_status_field | ap: / status | AP 信息 hash 键前缀与字段 |
| ap_status_offline | 0 | 主通道"离线"的状态值 |
| keepalived_tag | Tr369KeepAlived | 保活通道 clientId 标记 |
| white_service_list | unmtr369service 等 | 白名单用户名 |
| unm_username / unm_expected_password / aes_key | UNM2000 / Umc2024@Adm / Fiber#Aes@369069 | 平台账号校验 |
| fallback_allow_on_redis_error | true | Redis 故障降级放行 |

CLI 排查：

```
emqx ctl emqx_plugin_redis_auth status      # Redis PING 检查
emqx ctl emqx_plugin_redis_auth get-config  # 当前配置
```

## 构建（参考 emqx_plugin_kafka）

在 EMQX 5.7.2 对应的 OTP 环境（builder 镜像）中：

```bash
cp rebar.config.5.7.2 rebar.config
chmod +x scripts/*.sh
make rel
```

产出 `_build/default/emqx_plugrel/emqx_plugin_redis_auth-1.0.0.tar.gz`，
安装到 EMQX 并在 Dashboard 启用。

## Release

An EMQX plugin release is a tar file including a subdirectory of this
plugin's name and its version.

In a shell from this plugin's working directory execute `make rel`
to have the package created like:

```
_build/default/emqx_plugrel/emqx_plugin_redis_auth-<vsn>.tar.gz
```

See [EMQX documentation](https://docs.emqx.com/en/enterprise/v5.0/extensions/plugins.html)
for details on how to deploy custom plugins.