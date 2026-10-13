-module(emqx_plugin_redis_auth_sup).

-behaviour(supervisor).

%% for logging
-include_lib("emqx_plugin_helper/include/logger.hrl").

-export([start_link/0]).
-export([init/1]).
-export([restart_pool/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },
    ChildSpecs = [
        #{
            id => emqx_plugin_redis_auth,
            start => {emqx_plugin_redis_auth, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [emqx_plugin_redis_auth]
        },
        redis_pool_spec()
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% @doc Rebuild the eredis pool child spec from the current plugin config.
%% Used to hot-apply redis connection parameter changes.
restart_pool() ->
    Spec = redis_pool_spec(),
    _ = supervisor:terminate_child(?MODULE, eredis_pool),
    _ = supervisor:delete_child(?MODULE, eredis_pool),
    {ok, _} = supervisor:start_child(?MODULE, Spec),
    ok.

redis_pool_spec() ->
    Config = get_plugin_config(),
    Host = binary_to_list(maps:get(<<"redis_host">>, Config, <<"127.0.0.1">>)),
    Port = maps:get(<<"redis_port">>, Config, 6379),
    Database = maps:get(<<"redis_database">>, Config, 0),
    Password =
        case maps:get(<<"redis_password">>, Config, <<>>) of
            <<>> -> "";
            P when is_binary(P) -> binary_to_list(P);
            _ -> ""
        end,
    PoolSize = maps:get(<<"redis_pool_size">>, Config, 8),
    ReconnectSleep = maps:get(<<"redis_reconnect_sleep_ms">>, Config, 1000),
    ?SLOG(debug, #{
        msg => "redis_auth_pool_starting",
        host => list_to_binary(Host),
        port => Port,
        database => Database,
        pool_size => PoolSize
    }),
    #{
        id => eredis_pool,
        start => {eredis, start_link, [PoolSize, Host, Port, Database, Password, ReconnectSleep]},
        restart => permanent,
        shutdown => 5000,
        type => supervisor,
        modules => [eredis]
    }.

%% Read config straight from emqx_plugin_helper: at supervisor startup the
%% plugin gen_server has not cached the config yet, and on config change
%% emqx_plugins updates this value before invoking on_config_changed.
get_plugin_config() ->
    case emqx_plugin_helper:get_config(<<"emqx_plugin_redis_auth-1.0.0">>) of
        Config when is_map(Config) ->
            Config;
        _ ->
            #{}
    end.