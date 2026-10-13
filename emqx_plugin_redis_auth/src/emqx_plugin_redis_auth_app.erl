-module(emqx_plugin_redis_auth_app).

-behaviour(application).

-emqx_plugin(?MODULE).

%% for logging
-include_lib("emqx_plugin_helper/include/logger.hrl").

-export([
    start/2,
    stop/1
]).

-export([
    on_config_changed/2,
    on_health_check/1
]).

%% NOTE
%% Functions from EMQX are unavailable at compile time.
-dialyzer({no_unknown, [start/2, stop/1]}).

start(_StartType, _StartArgs) ->
    {ok, Sup} = emqx_plugin_redis_auth_sup:start_link(),
    emqx_plugin_redis_auth:hook(),
    emqx_ctl:register_command(emqx_plugin_redis_auth, {emqx_plugin_redis_auth_cli, cmd}),
    ?SLOG(debug, #{msg => "emqx_plugin_redis_auth_started"}),
    {ok, Sup}.

stop(_State) ->
    emqx_ctl:unregister_command(emqx_plugin_redis_auth),
    emqx_plugin_redis_auth:unhook(),
    ?SLOG(debug, #{msg => "emqx_plugin_redis_auth_stopped"}).

on_config_changed(OldConfig, NewConfig) ->
    emqx_plugin_redis_auth:on_config_changed(OldConfig, NewConfig).

on_health_check(Options) ->
    emqx_plugin_redis_auth:on_health_check(Options).