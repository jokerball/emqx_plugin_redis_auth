-module(emqx_plugin_redis_auth).

%% EMQX 5.x Redis authentication plugin.
%%
%% This plugin mirrors the logic of the TR369 auth service
%% `unmtr369auth`'s POST /mqtt/verify endpoint:
%%
%%   1. clientid/username/password missing          -> deny
%%   2. username in `white_service_list`            -> allow
%%   3. username == unm_username (UNM2000):
%%      AES-128-CBC(no padding, zero IV) decrypt of the base64 password
%%      must equal unm_expected_password           -> allow / deny
%%   4. otherwise: redis GET `snindex:{mac}` must exist -> allow / deny
%%   5. clientid containing keepalived_tag: HGET `ap:{apId}` `status`
%%      - missing value or "0" (offline)  -> allow
%%      - any other value (online)        -> deny (main channel online)
%%
%% Registered on the built-in hook 'client.authenticate' with the highest
%% priority; returning {stop, ...} makes the verdict terminal, so the
%% built-in EMQX authenticator chain is not consulted for this plugin.

-define(PLUGIN_NAME, "emqx_plugin_redis_auth").
-define(PLUGIN_VSN, "1.0.0").

%% for hook priority constants
-include_lib("emqx_plugin_helper/include/emqx_hooks.hrl").

%% for logging
-include_lib("emqx_plugin_helper/include/logger.hrl").

-export([
    hook/0,
    unhook/0
]).

-export([
    on_config_changed/2,
    on_health_check/1,
    get_config/0
]).

%% 'client.authenticate' hook callback
-export([
    authenticate/2
]).

%% gen_server callbacks
-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% NOTE: Functions from EMQX are unavailable at compile time.
-dialyzer({no_unknown, [hook/0, unhook/0]}).

%%--------------------------------------------------------------------
%% Plugin lifecycle
%%--------------------------------------------------------------------

%% @doc Register the authentication hook with the highest priority so that
%% this plugin is consulted before the built-in authentication chain.
hook() ->
    emqx_hooks:add('client.authenticate', {?MODULE, authenticate, []}, ?HP_HIGHEST).

%% @doc Unregister the authentication hook.
unhook() ->
    emqx_hooks:del('client.authenticate', {?MODULE, authenticate}).

%%--------------------------------------------------------------------
%% 'client.authenticate' hook callback
%%--------------------------------------------------------------------

%% The hook is a fold: the callback receives (Credential, Acc).
%% Returning {stop, NewAcc} ends the chain with NewAcc as the final result.
authenticate(Credential, _AuthResult) ->
    case do_verify(Credential) of
        allow ->
            {stop, {ok, #{is_superuser => false}}};
        {deny, Reason} ->
            ?SLOG(debug, #{
                msg => "redis_auth_denied",
                reason => Reason,
                clientid => maps:get(clientid, Credential, undefined),
                username => maps:get(username, Credential, undefined)
            }),
            {stop, {error, not_authorized}}
    end.

%%--------------------------------------------------------------------
%% Verify logic (mirrors Java AuthService.authDeviceInRedis)
%%--------------------------------------------------------------------

do_verify(Credential) ->
    ClientId = cred_bin(maps:get(clientid, Credential, undefined)),
    Username = cred_bin(maps:get(username, Credential, undefined)),
    Password = cred_bin(maps:get(password, Credential, undefined)),
    Config = get_config(),
    case ClientId =:= <<>> orelse Username =:= <<>> orelse Password =:= <<>> of
        true ->
            {deny, conn_info_incomplete};
        false ->
            do_verify(Config, ClientId, Username, Password)
    end.

do_verify(Config, ClientId, Username, Password) ->
    WhiteList = conf(<<"white_service_list">>, Config, []),
    case lists:member(Username, WhiteList) of
        true ->
            ?SLOG(debug, #{msg => "redis_auth_whitelist_allow", username => Username}),
            allow;
        false ->
            UnmUser = conf(<<"unm_username">>, Config, <<"UNM2000">>),
            case Username =:= UnmUser of
                true ->
                    verify_unm_password(Config, Password);
                false ->
                    verify_device(Config, ClientId)
            end
    end.

%% UNM2000: AES/CBC/NoPadding with zero IV, decrypt and compare.
verify_unm_password(Config, Password) ->
    Key = conf(<<"aes_key">>, Config, <<"Fiber#Aes@369069">>),
    Expected = conf(<<"unm_expected_password">>, Config, <<"Umc2024@Adm">>),
    case aes_decrypt(Password, Key) of
        {ok, Expected} ->
            allow;
        _ ->
            {deny, unm_password_mismatch}
    end.

verify_device(Config, ClientId) ->
    RealMac = get_real_mac(ClientId, Config),
    IsKeepalive = has_keepalive_tag(ClientId, Config),
    SnPrefix = conf(<<"snindex_key_prefix">>, Config, <<"snindex:">>),
    Key = <<SnPrefix/binary, RealMac/binary>>,
    case redis_q(Config, ["GET", Key]) of
        {ok, undefined} ->
            {deny, device_not_exists};
        {ok, ApId} when is_binary(ApId) ->
            case IsKeepalive of
                true -> verify_keepalive(Config, ApId);
                false -> allow
            end;
        {error, Reason} ->
            degrade_on_redis_error(Config, Reason)
    end.

verify_keepalive(Config, ApId) ->
    ApPrefix = conf(<<"ap_key_prefix">>, Config, <<"ap:">>),
    Field = conf(<<"ap_status_field">>, Config, <<"status">>),
    Offline = conf(<<"ap_status_offline">>, Config, <<"0">>),
    Key = <<ApPrefix/binary, ApId/binary>>,
    case redis_q(Config, ["HGET", Key, Field]) of
        %% missing status -> UNKNOWN -> allow (same as Java)
        {ok, undefined} ->
            allow;
        %% main channel offline -> the keepalived channel is allowed
        {ok, Offline} ->
            allow;
        %% any other status (online) -> deny, main channel is online
        {ok, _Online} ->
            {deny, main_channel_online};
        {error, Reason} ->
            degrade_on_redis_error(Config, Reason)
    end.

%% Java catches redis errors and falls back to 'allow' to avoid locking out
%% every device when redis is unavailable. Kept configurable.
degrade_on_redis_error(Config, Reason) ->
    case conf(<<"fallback_allow_on_redis_error">>, Config, true) of
        true ->
            ?SLOG(warning, #{msg => "redis_auth_redis_error_fallback_allow", reason => Reason}),
            allow;
        false ->
            {deny, redis_error}
    end.

%%--------------------------------------------------------------------
%% Helpers (mirrors Java CommonUtils.getRealMac)
%%--------------------------------------------------------------------

get_real_mac(ClientId, Config) ->
    Tag = conf(<<"keepalived_tag">>, Config, <<"Tr369KeepAlived">>),
    case binary:match(ClientId, Tag) of
        nomatch ->
            ClientId;
        _ ->
            %% Java: split("-") and take the first part only when there
            %% are exactly 2 segments.
            case binary:split(ClientId, <<"-">>, [global]) of
                [Mac, _TagPart] -> Mac;
                _ -> ClientId
            end
    end.

has_keepalive_tag(ClientId, Config) ->
    Tag = conf(<<"keepalived_tag">>, Config, <<"Tr369KeepAlived">>),
    binary:match(ClientId, Tag) =/= nomatch.

cred_bin(undefined) -> <<>>;
cred_bin(B) -> iolist_to_binary(B).

%% AES/CBC/NoPadding, zero IV, zero-padded plaintext.
%% Mirrors Java AESUtil.decrypt(AES/CBC/NoPadding).
aes_decrypt(Base64Text, KeyBin) ->
    try
        Cipher = base64:decode(Base64Text),
        IV = <<0:128>>,
        Padded = crypto:crypto_one_time(aes_128_cbc, KeyBin, IV, Cipher, false),
        {ok, trim_zero_padding(Padded)}
    catch
        _:_ ->
            {error, decrypt_failed}
    end.

trim_zero_padding(Bin) ->
    trim_zero_padding(byte_size(Bin), Bin).

trim_zero_padding(0, _) ->
    <<>>;
trim_zero_padding(N, Bin) ->
    case binary:at(Bin, N - 1) of
        0 -> trim_zero_padding(N - 1, Bin);
        _ -> binary:part(Bin, 0, N)
    end.

redis_q(Config, Command) ->
    Timeout = conf(<<"redis_query_timeout_ms">>, Config, 2000),
    try
        eredis:q(eredis_pool, Command, Timeout)
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% Plugin config callbacks
%%--------------------------------------------------------------------

on_health_check(_Options) ->
    case catch eredis:q(eredis_pool, ["PING"], 2000) of
        {ok, <<"PONG">>} ->
            ok;
        Other ->
            {error, {redis_unreachable, Other}}
    end.

on_config_changed(_OldConfig, NewConfig) ->
    case maps:get(<<"redis_host">>, NewConfig, undefined) of
        undefined ->
            {error, <<"Missing redis_host">>};
        _ ->
            ok = gen_server:cast(?MODULE, {on_changed, NewConfig}),
            ok
    end.

%%--------------------------------------------------------------------
%% Config access
%%--------------------------------------------------------------------

get_config() ->
    persistent_term:get(?MODULE, #{}).

conf(Key, Config, Default) ->
    maps:get(Key, Config, Default).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:process_flag(trap_exit, true),
    PluginNameVsn = <<?PLUGIN_NAME, "-", ?PLUGIN_VSN>>,
    try
        Config = emqx_plugin_helper:get_config(PluginNameVsn),
        case map_size(Config) of
            0 ->
                ?SLOG(warning, #{
                    msg => "redis_auth_plugin_config_empty",
                    hint => "Please ensure the plugin config file exists"
                });
            _ ->
                ?SLOG(debug, #{
                    msg => "redis_auth_plugin_config_loaded",
                    keys => maps:keys(Config)
                })
        end,
        persistent_term:put(?MODULE, Config),
        {ok, #{config => Config}}
    catch
        InitClass:InitReason:InitStack ->
            ?SLOG(error, #{
                msg => "redis_auth_plugin_init_crashed",
                class => InitClass,
                reason => InitReason,
                stack => InitStack
            }),
            {stop, {init_failed, InitClass, InitReason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({on_changed, NewConfig}, State) ->
    persistent_term:put(?MODULE, NewConfig),
    %% Restart the redis pool with the new connection parameters.
    try
        ok = emqx_plugin_redis_auth_sup:restart_pool()
    catch
        Class:Reason:Stack ->
            ?SLOG(error, #{
                msg => "redis_auth_pool_restart_failed",
                class => Class,
                reason => Reason,
                stack => Stack
            })
    end,
    {noreply, State#{config => NewConfig}};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Request, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    persistent_term:erase(?MODULE),
    ok.