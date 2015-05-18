%%%-------------------------------------------------------------------
%%% @author 陈云星 <LambdaCat@lambda-cat.local>
%%% @copyright (C) 2015, 陈云星
%%% @doc
%%%
%%% @end
%%% Created : 29 Apr 2015 by 陈云星 <LambdaCat@lambda-cat.local>
%%%-------------------------------------------------------------------
-module(hello_erlang_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    Restart = permanent,
    Shutdown = 2000,
    Type = worker,

    {ok, SnList} = application:get_env(hello_erlang, probe_sn_list),
    {ok, ProbeInfo} = application:get_env(hello_erlang, probe_info),
    {ok, RssiRange} = application:get_env(hello_erlang, rssi_range),
    {ok, Scale } =application:get_env(hello_erlang, scale),
    AChild = {'probe_info_consumer', {probe_info_consumer, start_link, [[SnList, ProbeInfo, RssiRange, Scale]]},
	      Restart, Shutdown, Type, [probe_info_consumer]},
    {ok, {SupFlags, [AChild]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
