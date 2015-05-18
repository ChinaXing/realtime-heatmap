-module(spark_handler).
-behaviour(cowboy_websocket_handler).
-export([init/3]).
-export([websocket_handle/3]).
-export([websocket_init/3]).
-export([websocket_terminate/3]).
-export([websocket_info/3]).
-record(state, {}).

init(_, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init(_Type, Req, _Opts) ->
    probe_info_consumer:register_callback(self()),
    {ok, Req, #state{}}.

websocket_handle(_Frame = {text, Data}, Req, State) ->
    error_logger:info_msg("Receive client Msg : ~p~n", [ Data ]), 
    Resp = case jiffy:decode(Data) of
	       {[{<<"action">>,<<"loadInitailData">>}]} ->
		   case probe_info_consumer:load_initial_data() of
		       {ok, TargetData} ->
			   [{action, totalData}, {data, TargetData}];
		       {error, Reason} ->
			   [{action, initial_error},{data, Reason}];
		       Other ->
			   [{action, initial_error}, {data, Other}]
		   end;
	       Other ->
		   [{action, initial_error}, {data, {unknown_command, Other}}]
	   end,
    {reply, {text, jiffy:encode({Resp})}, Req, State};
websocket_handle(_Frame, Req, State) ->
    {ok, Req, State}.

websocket_info({_Pid, {position, Data}}, Req, State) ->
%    error_logger:info_msg("got data => ~p~n", [Data]),
    JsonData = jiffy:encode({[{action, incData}, {data, {Data}}]}),
    {reply, {text, JsonData}, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, _State) ->
    probe_info_consumer:unregister_callback(self()),
    ok.

