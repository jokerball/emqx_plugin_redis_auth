-module(emqx_plugin_redis_auth_cli).

-export([cmd/1]).

%% NOTE
%% Functions from EMQX are unavailable at compile time.
-dialyzer({no_unknown, [cmd/1]}).

cmd(["get-config"]) ->
    Config = emqx_plugin_redis_auth:get_config(),
    emqx_ctl:print("~s~n", [emqx_utils_json:encode(Config)]);
cmd(["status"]) ->
    case emqx_plugin_redis_auth:ping() of
        {ok, <<"PONG">>} ->
            emqx_ctl:print("Redis auth: running (PONG)~n");
        Other ->
            emqx_ctl:print("Redis auth: unavailable (~p)~n", [Other])
    end;
cmd(_) ->
    emqx_ctl:usage([
        {"get-config", "get current plugin config"},
        {"status", "check Redis connectivity"}
    ]).