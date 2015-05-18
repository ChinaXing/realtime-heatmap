%%%-------------------------------------------------------------------
%%% @author 陈云星 <LambdaCat@lambda-cat.local>
%%% @copyright (C) 2015, 陈云星
%%% @doc
%%%  This is a probe information consumer, use redis as pub/sub service
%%% @end
%%% Created : 28 Apr 2015 by 陈云星 <LambdaCat@lambda-cat.local>
%%%-------------------------------------------------------------------
-module(probe_info_consumer).
-behaviour(gen_server).

%% API
-export([start_link/1, register_callback/1, unregister_callback/1, initial_mnesia/0, load_initial_data/0]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

-define(SERVER, ?MODULE).

-record(state, {callback = [] , sn_no_map , probe_info_map, rssi_range, scale = 1 }).
-record(probe_dev_info, {dev_mac, probe_no, distance, phone}).  
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(StartArgs) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, StartArgs, [{debug, [trace,log]}]).

-spec register_callback(CallbackPid :: pid()) -> {ok, Pid :: pid()}.
register_callback(CallbackPid) ->
    gen_server:call(?SERVER,{register_callback, CallbackPid}). 
-spec unregister_callback(CallbackPid :: pid()) -> {ok, Pid :: pid()}.
unregister_callback(CallbackPid) ->
    gen_server:call(?SERVER, {unregister_callback, CallbackPid}).
-spec load_initial_data() -> {ok, Data :: [term()]}.
load_initial_data() ->
    gen_server:call(?SERVER, load_initial_data).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([SnList, ProbeInfo, RssiRange, Scale]) ->
    case initial_mnesia() of
	ok ->
	    SnMap = maps:from_list(SnList),
	    ProbeInfoMap = maps:from_list(ProbeInfo),
	    {ok, #state{sn_no_map = SnMap, probe_info_map = ProbeInfoMap, rssi_range = RssiRange, scale = Scale}};
	{error, Reason} ->
	    {stop, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({register_callback, CallBackPid}, _From, State) ->
    error_logger:error_msg("callback set to :~p~n", [CallBackPid]),
    {reply, self(), 
     State#state{ callback  = [CallBackPid|State#state.callback] }};

handle_call({unregister_callback, CallbackPid}, _From, State) ->
    error_logger:info_msg("unregister callback , Pid : ~p~n", [CallbackPid]),
    {reply, self(), 
     State#state { 
       callback = lists:delete(CallbackPid, State#state.callback)
      }}; 

handle_call(load_initial_data, _From, State) ->
    Reply = case load_initial_data_from_db(State) of
		{error, Reason} ->
		    {error, Reason};
		{ok, Data} ->
		    {ok, Data};
		Other ->
		    {error, Other}
	    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({set_callback, Pid}, _State) ->
    {noreply, #state{ callback = Pid} }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({_From, Data}, State) ->
    Json = jiffy:decode(Data),
    {L} = Json,
    M = maps:from_list(L),
    Sn = binary_to_list(maps:get(<<"sn">>,M)),
    DevMac = binary_to_list(maps:get(<<"devMac">>, M)),
    Rssi = maps:get(<<"rssi">>, M),
    Distance = get_distance_by_rssi(State#state.rssi_range, Rssi, State#state.scale),
    Arrive = maps:get(<<"arriveLeave">>, M),
    PhoneNum = maps:get(<<"phone">>, M),
    NewProbeNo = maps:get(Sn,State#state.sn_no_map),
    Record = #probe_dev_info{ probe_no = NewProbeNo, dev_mac = DevMac, distance = Distance, phone = PhoneNum },
    Response = case Arrive of 
		   1 -> do_enter(State, Record);
		   0 -> do_leave(State, Record);
		   _ -> error_logger:error_msg(" Unknown Arrive value : ~p~n",[Arrive]),
			{error, {unknown_arrive_value, Arrive}}
	       end,
    case Response of
	{ok, no_response} -> ok;
	{ok, ResponseData} ->
	    Msg = {self(), {position, ResponseData}},
	    [ CB ! Msg || CB <- State#state.callback ];
	Other ->
	    Other %% Ignored.
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    mnesia:stop(),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% 用户进入探针
%%
%% 可能的结果
%% 新加入 => new :: 之前未探测到该设备
%% 移动位置 => 之前探测到过，此次又被探测到 (下面1,2不做区分)
%%            1. move :: 与原来探针是同一个探针 
%%            2. move :: 移动到新的探针
%% 未变化 => keep :: 新的探测位置信号强度小于之前探测到的计算结果
%%
%%--------------------------------------------------------------------
do_enter(State, NewRecord) ->
    case mnesia:transaction(
	   fun() -> merge_new_dev_info(State, NewRecord) end
	  )  of
	{aborted, Reason} ->
	    error_logger:error_msg("~p: merge failed : ~p~n",[NewRecord, Reason]),
	    {error, Reason};
	{atomic, {keep, KeptProbeNo}} ->
	    error_logger:info_msg("~p: < keep > probe : [~p] ~n",[NewRecord, KeptProbeNo]),
	    {ok, no_response};
	{atomic, {new, {NewProbeNo, [X, Y]}}} ->
	    error_logger:info_msg("~p: < new > probe : [~p] ~n", [NewRecord, NewProbeNo]),
	    {ok, [
		  { devMac, list_to_binary(NewRecord#probe_dev_info.dev_mac)},
		  { type, new },
		  { probeNo, NewProbeNo },
		  { phone, NewRecord#probe_dev_info.phone },
		  { x, round(X, 2) },
		  { y, round(Y, 2) }
		 ]};
	{atomic, {move, {ProbeNo, [X, Y]}}} ->
	    error_logger:info_msg("~p: < move > probe : [~p] ~n", [NewRecord, ProbeNo]),
	    {ok, [
		  { devMac, list_to_binary(NewRecord#probe_dev_info.dev_mac) },
		  { type, move },
		  { probeNo, ProbeNo },
		  { phone, NewRecord#probe_dev_info.phone },
		  { x, round(X, 2) },
		  { y, round(Y, 2) }
		 ]}
    end.

%%--------------------------------------------------------------------
%% 用户离开探针
%%
%% 可能的结果：
%% 用户彻底离开   => 之前只被该探针探测到
%% 移动到新的探针  => 除了被该探针探测到，还被别的探测到
%% 位置保持不变   => 离开的探针不影响之前的位置计算
%%--------------------------------------------------------------------
do_leave(State, LeaveRecord) ->
    DevMac = LeaveRecord#probe_dev_info.dev_mac,
    case mnesia:transaction(
	   fun() -> remove_dev_from_probe(State, LeaveRecord) end
	  ) of
	{aborted, Reason} ->
	    error_logger:error_msg("~p: remove failed : [~p] ~n",[LeaveRecord, Reason]),
	    {error, Reason};
	{atomic,  {leave, LeaveProbeNo}} ->
	    error_logger:info_msg("~p: < leave > probe : [~p] ~n",[LeaveRecord, LeaveProbeNo]),
	    {ok, [
		  {devMac, list_to_binary(DevMac)},
		  {type, leave},
		  {probeNo, LeaveProbeNo}
		 ]};
	{atomic, {move, {ProbeNo,[X,Y]}}} ->
	    error_logger:info_msg("~p: < move > probe : [~p] ~n",[LeaveRecord, ProbeNo]),
	    {ok, [
		  { devMac, list_to_binary(DevMac) },
		  { type, move },
		  { probeNo, ProbeNo },
		  { phone, LeaveRecord#probe_dev_info.phone },
		  { x, round(X,2) },
		  { y, round(Y,2) }
		 ]};
	{atomic, {keep, KeptProbeNo}} ->
	    error_logger:info_msg("~p: < keep > probe : [~p] ~n", [LeaveRecord, KeptProbeNo]),
	    {ok, no_response}
    end.

%%--------------------------------------------------------------------
%% 计算新进入的设备的的坐标
%% 返回：
%%     new => 新设备
%%     move => 坐标发生变化
%%     keep => 未变化
%%--------------------------------------------------------------------
merge_new_dev_info(State, NewRecord) ->
    case  mnesia:read(probe_dev_info, NewRecord#probe_dev_info.dev_mac, write) of
	[] ->
	    mnesia:write(NewRecord),
	    [X, Y] = get_position_random(NewRecord),
	    {new, {NewRecord#probe_dev_info.probe_no, [X, Y]}};
	OldPositionList -> 
	    process_add(State, NewRecord, OldPositionList)
    end.

%%--------------------------------------------------------------------
%% 处理已有列表的更新情况
%%--------------------------------------------------------------------
process_add(State, NewRecord, OldPositionList) ->
    % 按照距离排序,降序
    NewPositionListOrdered = 
	case lists:keysearch(NewRecord#probe_dev_info.probe_no, 3, OldPositionList) of
	    {value, OldRecord} ->
		mnesia:delete_object(OldRecord),
		mnesia:write(NewRecord),
		lists:keysort(4, lists:keyreplace(OldRecord#probe_dev_info.probe_no, 3, OldPositionList, NewRecord));
	    false ->
		mnesia:write(NewRecord),
		lists:keysort(4, [NewRecord|OldPositionList])
	end,
    case NewPositionListOrdered of
	[NewRecord, SecondRecord|_] -> 
	    [X, Y] = get_position(State, NewRecord, SecondRecord),
	    {move, {NewRecord#probe_dev_info.probe_no, [X, Y]}};
	[NewRecord] ->
	    [X, Y] = get_position_random(NewRecord),
	    {move, {NewRecord#probe_dev_info.probe_no, [X, Y]}};
	[FirstRecord, NewRecord|_] ->
	    [X, Y] = get_position(State, FirstRecord, NewRecord),
	    {move, {FirstRecord#probe_dev_info.probe_no, [X, Y]}} ;
	_ ->
	    Target = lists:nth(1, NewPositionListOrdered),
	    {keep, Target#probe_dev_info.probe_no}
    end.

%%--------------------------------------------------------------------
%% 设备从探针离开，调整
%% 0. 从数据库删除记录
%% 1. 此设备在此探针是最近 => 从次近列表计算新的坐标
%% 2. 否则 => 仅仅是更新数据库，位置坐标不变
%%
%% 返回：
%%  keep => 位置未变化
%%  move => 位置发送变化
%%  leave => 离开
%%--------------------------------------------------------------------
remove_dev_from_probe(State, LeaveRecord) ->
    case mnesia:read(probe_dev_info,LeaveRecord#probe_dev_info.dev_mac) of
	[] ->
	    {leave, LeaveRecord#probe_dev_info.probe_no};
	OldPositionList ->
	    process_remove(State, LeaveRecord, OldPositionList)
    end.
%%--------------------------------------------------------------------
%% 处理从原来集合中删除的情况
%%--------------------------------------------------------------------
process_remove(State, LeaveRecord, OldPositionList) ->
    case lists:keytake(LeaveRecord#probe_dev_info.probe_no, 3, OldPositionList) of
	{value, Tuple, []} ->
	    mnesia:delete_object(Tuple),
	    {leave, LeaveRecord#probe_dev_info.probe_no};
	{value, Tuple, [LastOne]} ->
	    mnesia:delete_object(Tuple),
	    [X, Y] = get_position_random(LastOne),
	    {move, {LastOne#probe_dev_info.probe_no, [X, Y]}};
	{value, Tuple, ListRemoved} ->
	    mnesia:delete_object(Tuple),
	    [First, Second|_] = lists:keysort(4, ListRemoved),
	    [X, Y] = get_position(State, First, Second),
	    {move, {First#probe_dev_info.probe_no, [X, Y]}};
	_Other ->
	    {keep, LeaveRecord} % not quite right, but just display .
    end.

%%--------------------------------------------------------------------
%% 根据半径计算45度偏移的相对圆心坐标
%%--------------------------------------------------------------------
get_position_random(Record) ->
    random:seed(erlang:now()),
    Pi = math:pi(),
    Angle =  Pi * (2 - random:uniform()) / 6, % [π/6, π/3]
    X = Record#probe_dev_info.distance * math:sin(Angle),
    Y = Record#probe_dev_info.distance * math:cos(Angle),
    [X , Y].

%%--------------------------------------------------------------------
%% 根据Rssi 换算为半径
%%--------------------------------------------------------------------
get_distance_by_rssi([Min, Max] = _RssiRange, Rssi, Scale) ->
    if 
	Rssi >= Max ->
	    (Max - Min) div 15 * Scale; 
	Rssi =< Min  ->
	    (Max - Min) * Scale;
	true ->
	    (Max - Rssi) * Scale
    end.

%%--------------------------------------------------------------------
%% 根据圆心和半径，计算交点离半径较小的圆心的相对坐标
%% First_r < Second_r 
%%--------------------------------------------------------------------
get_position(State, First, Second) ->
    {X0, Y0} = maps:get(First#probe_dev_info.probe_no, State#state.probe_info_map),
    {X1, Y1} = maps:get(Second#probe_dev_info.probe_no, State#state.probe_info_map),
    if
	% 对角线情况
	(X0 /= X1) and (Y0 /= Y1) -> 
	    get_position_random(First);
	true ->
	    Dx = abs(X0 - X1),
	    Dy = abs(Y0 - Y1),
	    D = math:sqrt(Dx*Dx + Dy*Dy),
	    R0 = First#probe_dev_info.distance,
	    R1 = Second#probe_dev_info.distance,
	    if 
		R0 + R1 < D ->
		    get_position_random(First);
		R1 - R0 > D ->
		    get_position_random(First);
		true ->
		    [Xt,Yt] = calculate_intersection_point(R0, R1, D),
		    if 
			X1 =:= X0 ->
			    [Yt, Xt];
			true ->
			    [Xt, Yt]
		    end
	    end
    end.

%%--------------------------------------------------------------------
%% 根据半径，圆心距离，计算交点坐标
%% R0 位于原点
%%--------------------------------------------------------------------
calculate_intersection_point(R0, R1, D) -> 
    X = abs(D*D + R0*R0 - R1*R1) / (2 * D),
    Y = math:sqrt(R0*R0 - X*X),
    [X, Y].

%%--------------------------------------------------------------------
%% 初始化Mnesia数据库
%%--------------------------------------------------------------------
initial_mnesia() ->
    mnesia:info(),
    CreateSchema = case mnesia:create_schema([node()]) of
		       ok ->
			   ok;
		       {error, {_, {already_exists, _}}} ->
			   ok;
		       Reason ->
			   {error, Reason}
		   end,
    case CreateSchema of
	ok ->
	    mnesia:info(),
	    ok = mnesia:start(),
	    mnesia:info(),
	    case  mnesia:create_table(
		    probe_dev_info,
		    [
		     {attributes, record_info(fields, probe_dev_info)},
		     {disc_copies, [node()]},
		     {type, bag} 
		    ]) of
		{atomic, ok} ->
		    ok;
		{aborted, {already_exists, probe_dev_info}} ->
		    ok;
		R1 ->
		    {error, R1}
	    end;
	R ->
	    R
    end.
%%--------------------------------------------------------------------
%% 对float进行取固定精度
%%--------------------------------------------------------------------
round(F,Num) ->
    Pow = math:pow(10, Num),
    FF = F * Pow,
    FFF = round(FF),
    FFF / Pow.

%%--------------------------------------------------------------------
%% load 所有当前在线设备及其位置
%%--------------------------------------------------------------------
load_initial_data_from_db(State) ->
    F = fun() ->
		AllKeys = mnesia:all_keys(probe_dev_info),
		Data  = lists:foldl(
			  fun(DevMac, Acc) ->
				  DevProbes = mnesia:read(probe_dev_info, DevMac),
				  [{ DevMac, DevProbes } | Acc]
			  end,
			  [], AllKeys),
		{AllKeys, Data}
	end,
    case mnesia:transaction(F) of
	{aborted, Reason} ->
	    {error, Reason};
	{atomic, {_Keys, Data}} ->
	    R = [ calculate_position(State, I) || I <- Data ],
	    {ok, R}
    end.
%%--------------------------------------------------------------------
%% 根据所在探针的状况，计算出坐标
%%--------------------------------------------------------------------
calculate_position(_State, {_Key, [Value]}) ->
    [X, Y] = get_position_random(Value),
    [list_to_binary(Value#probe_dev_info.dev_mac), Value#probe_dev_info.probe_no, round(X,2), round(Y,2), Value#probe_dev_info.phone];
    
calculate_position(State, {_Key, Values}) ->
    [V1,V2|_] = lists:keysort(4, Values),
    [X, Y] = get_position(State, V1, V2),
    [list_to_binary(V1#probe_dev_info.dev_mac), V1#probe_dev_info.probe_no, round(X,2), round(Y,2), V1#probe_dev_info.phone ].
    






