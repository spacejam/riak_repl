-module(rt_source_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(SINK_PORT, 5007).
-define(all_remotes, ["a", "b", "c", "d", "e"]).

-record(state, {
    remotes_available = ?all_remotes,
    seq = 0,
    master_queue = [],
    sources = [] % [#src_state{}]
    }).

-record(src_state, {
    pids, % {SourcePid, SinkPid}
    version,
    unacked_objects = []
}).

prop_test_() ->
    {timeout, 30, fun() ->
        ?assert(eqc:quickcheck(?MODULE:prop_main()))
    end}.

prop_main() ->
    ?FORALL(Cmds, commands(?MODULE),
        aggregate(command_names(Cmds), begin
            {H, S, Res} = run_commands(?MODULE, Cmds),
            process_flag(trap_exit, false),
            pretty_commands(?MODULE, Cmds, {H,S,Res}, Res == ok)
        end)).

%% ====================================================================
%% Generators (including commands)
%% ====================================================================

command(S) ->
    oneof(
        [{call, ?MODULE, connect_to_v1, [remote_name(S), S#state.master_queue]} || S#state.remotes_available /= []] ++
        [{call, ?MODULE, connect_to_v2, [remote_name(S), S#state.master_queue]} || S#state.remotes_available /= []] ++
        [{call, ?MODULE, disconnect, [elements(S#state.sources)]} || S#state.sources /= []] ++
        % push an object that may already have been rt'ed
        % todo while pushing before remotes up is supported, disabling that
        % condition for ease of testing (for now)
        [{call, ?MODULE, push_object, [g_unique_remotes(), binary(), S]} || S#state.sources /= []] ++
        [?LET({_Remote, SrcState} = Source, elements(S#state.sources), {call, ?MODULE, ack_objects, [g_up_to_length(SrcState#src_state.unacked_objects), Source]}) || S#state.sources /= []]
    ).

g_up_to_length([]) ->
    0;
g_up_to_length(List) ->
    Max = length(List),
    choose(0, Max).

g_unique_remotes() ->
    ?LET(Remotes, list(g_remote_name()), lists:usort(Remotes)).

g_remote_name() ->
    oneof(?all_remotes).

% name of a remote
remote_name(#state{remotes_available = []}) ->
    erlang:error(no_name_available);
remote_name(#state{remotes_available = Remotes}) ->
    oneof(Remotes).

precondition(#state{sources = []}, {call, _, disconnect, _Args}) ->
    false;
precondition(#state{sources = Sources}, {call, _, disconnect, [{Remote, _}]}) ->
    is_tuple(lists:keyfind(Remote, 1, Sources));
precondition(S, {call, _, disconnect, _Args}) ->
    S#state.sources /= [];
precondition(#state{sources = []}, {call, _, ack_objects, _Args}) ->
    false;
precondition(#state{sources = Sources}, {call, _, ack_objects, [NumAck, {Remote, _}]}) ->
    case lists:keyfind(Remote, 1, Sources) of
        {_, #src_state{unacked_objects = UnAcked}} when length(UnAcked) >= NumAck ->
            true;
        _ ->
            false
    end;
precondition(S, {call, _, ack_objects, _Args}) ->
    S#state.sources /= [];
precondition(S, {call, _, push_object, [_, _, S]}) ->
    S#state.sources /= [];
precondition(S, {call, _, push_object, [_, _, NotS]}) ->
    ?debugFmt("Bad states.~n    State: ~p~nArg: ~p", [S, NotS]),
    false;
precondition(S, {call, _, Connect, [Remote, _]}) when Connect =:= connect_to_v1; Connect =:= connect_to_v2 ->
    lists:member(Remote, S#state.remotes_available);
precondition(_S, _Call) ->
    true.

%% ====================================================================
%% state generation
%% ====================================================================

initial_state() ->
    process_flag(trap_exit, true),
    riak_repl_test_util:abstract_gen_tcp(),
    riak_repl_test_util:abstract_stats(),
    riak_repl_test_util:abstract_stateful(),
    abstract_connection_mgr(),
    {ok, _RTPid} = start_rt(),
    {ok, _RTQPid} = start_rtq(),
    {ok, _TCPMonPid} = start_tcp_mon(),
    {ok, _FakeSinkPid} = start_fake_sink(),
    #state{}.

next_state(S, Res, {call, _, connect_to_v1, [Remote, MQ]}) ->
    SrcState = #src_state{pids = Res, version = 1},
    next_state_connect(Remote, SrcState, S);

next_state(S, Res, {call, _, connect_to_v2, [Remote, MQ]}) ->
    SrcState = #src_state{pids = Res, version = 2},
    next_state_connect(Remote, SrcState, S);

next_state(S, _Res, {call, _, disconnect, [{Remote, _}]}) ->
    Sources = lists:keydelete(Remote, 1, S#state.sources),
    Master = if
        Sources == [] ->
            [];
        true ->
            MasterKeys = [Seq || {Seq, _, _, _} <- S#state.master_queue],
            SourceQueues = [Source#src_state.unacked_objects || {_, Source} <- Sources],
            ExtractSeqs = fun(Elem, Acc) ->
                SrcSeqs = [SeqNum || {SeqNum, _} <- Elem],
                lists:usort(Acc ++ SrcSeqs)
            end,
            ActiveSeqs = lists:foldl(ExtractSeqs, [], SourceQueues),
            RemoveSeqs = MasterKeys -- ActiveSeqs,
            UpdateMaster = fun(RemoveSeq, Acc) ->
                lists:keydelete(RemoveSeq, 1, Acc)
            end,
            lists:foldl(UpdateMaster, S#state.master_queue, RemoveSeqs)
    end,
    S#state{master_queue = Master, sources = Sources, remotes_available = [Remote | S#state.remotes_available]};

next_state(S, Res, {call, _, push_object, [Remotes, Binary, _S]}) ->
    Seq = S#state.seq + 1,
    Sources = update_unacked_objects(Remotes, {Seq, Res}, S#state.sources),
    RoutingSources = [R || {R, _} <- Sources, not lists:member(R, Remotes)],
    Master2 = case RoutingSources of
        [] ->
            S#state.master_queue;
        _ ->
            Master = S#state.master_queue,
            [{Seq, Remotes, Binary, Res} | Master]
    end,
    S#state{sources = Sources, master_queue = Master2, seq = Seq};

next_state(S, _Res, {call, _, ack_objects, [NumAcked, {Remote, _Source}]}) ->
    case lists:keytake(Remote, 1, S#state.sources) of
        false ->
            S;
        {value, {Remote, RealSource}, Sources} ->
            UnAcked = RealSource#src_state.unacked_objects,
            {Updated, Chopped} = model_ack_objects(NumAcked, UnAcked),
            SrcState2 = RealSource#src_state{unacked_objects = Updated},
            Sources2 = [{Remote, SrcState2} | Sources],
            Master2 = remove_fully_acked(S#state.master_queue, Chopped, Sources2),
            S#state{sources = Sources2, master_queue = Master2}
    end.

next_state_connect(Remote, SrcState, State) ->
    case lists:keyfind(Remote, 1, State#state.sources) of
        false ->
            Remotes = lists:delete(Remote, State#state.remotes_available),
            NewQueue = [{Seq, {call, ?MODULE, fix_unacked_from_master, [Remote, Queued, RoutedRemotes, State]}} || {Seq, RoutedRemotes, _Binary, Queued} <- State#state.master_queue, not lists:member(Remote, RoutedRemotes)],
            SrcState2 = SrcState#src_state{unacked_objects = NewQueue},
            Sources = [{Remote, SrcState2} | State#state.sources],
            State#state{sources = Sources, remotes_available = Remotes};
        _Tuple ->
            State
    end.

fix_unacked_from_master(Remote, {N, Bin, Meta}, RoutedRemotes, #state{sources = Sources}) ->
    Active = [A || {A, _} <- Sources],
    Routed = lists:usort(RoutedRemotes ++ Active ++ [Remote]),
    Meta2 = orddict:store(routed_clusters, Routed, Meta),
    {N, Bin, Meta2}.

remove_fully_acked(Master, [], _Sources) ->
    Master;

remove_fully_acked(Master, [{Seq, _} | Chopped], Sources) ->
    case is_in_a_source(Seq, Sources) of
        true ->
            remove_fully_acked(Master, Chopped, Sources);
        false ->
            Master2 = lists:keydelete(Seq, 1, Master),
            remove_fully_acked(Master2, Chopped, Sources)
    end.

is_in_a_source(_Seq, []) ->
    false;
is_in_a_source(Seq, [{_Remote, #src_state{unacked_objects = UnAcked}} | Tail]) ->
    case lists:keymember(Seq, 1, UnAcked) of
        true ->
            true;
        false ->
            is_in_a_source(Seq, Tail)
    end.

update_unacked_objects(Remotes, Res, Sources) ->
    update_unacked_objects(Remotes, Res, Sources, []).

update_unacked_objects(_Remotes, _Res, [], Acc) ->
    lists:reverse(Acc);

update_unacked_objects(Remotes, Res, [{Remote, Source} = KV | Tail], Acc) ->
    case lists:member(Remote, Remotes) of
        true ->
            update_unacked_objects(Remotes, Res, Tail, [KV | Acc]);
        false ->
            Entry = model_push_object(Res, Source),
            update_unacked_objects(Remotes, Res, Tail, [{Remote, Entry} | Acc])
    end.

model_push_object(Res, SrcState = #src_state{unacked_objects = ObjQueue}) ->
    SrcState#src_state{unacked_objects = [Res | ObjQueue]}.

model_ack_objects(_Num, []) ->
    {[], []};
model_ack_objects(NumAcked, Unacked) when length(Unacked) >= NumAcked ->
    NewLength = length(Unacked) - NumAcked,
    lists:split(NewLength, Unacked).

%% ====================================================================
%% postcondition
%% ====================================================================

postcondition(_State, {call, _, connect_to_v1, _Args}, {error, _}) ->
    false;
postcondition(_State, {call, _, connect_to_v1, _Args}, {Source, Sink}) ->
    is_pid(Source) andalso is_pid(Sink);

postcondition(_State, {call, _, connect_to_v2, _Args}, {error, _}) ->
    false;
postcondition(_State, {call, _, connect_to_v2, _Args}, {Source, Sink}) ->
    is_pid(Source) andalso is_pid(Sink);

postcondition(_State, {call, _, disconnect, [_SourceState]}, Waits) ->
    lists:all(fun(ok) -> true; (_) -> false end, Waits);

postcondition(_State, {call, _, push_object, [Remotes, _Binary, State]}, Res) ->
    assert_sink_bugs(Res, Remotes, State#state.sources);

postcondition(State, {call, _, ack_objects, [NumAck, {Remote, Source}]}, AckedStack) ->
    RemoteLives = is_tuple(lists:keyfind(Remote, 1, State#state.sources)),
    #src_state{unacked_objects = UnAcked} = Source,
    {_, Acked} = lists:split(length(UnAcked) - NumAck, UnAcked),
    if
        RemoteLives == false ->
            AckedStack == [];
        length(Acked) =/= length(AckedStack) ->
            ?debugMsg("Acked length is not the same as AckedStack length"),
            false;
        true ->
            assert_sink_ackings(Source#src_state.version, Acked, AckedStack)
    end;

postcondition(_S, _C, _R) ->
    ?debugMsg("fall through postcondition"),
    false.

assert_sink_bugs(Object, Remotes, Sources) ->
    Active = [A || {A, _} <- Sources],
    assert_sink_bugs(Object, Remotes, Active, Sources, []).

assert_sink_bugs(_Object, _Remotes, _Active, [], Acc) ->
    lists:all(fun(true) -> true; (_) -> false end, Acc);

assert_sink_bugs(Object, Remotes, Active, [{Remote, SrcState} | Tail], Acc) ->
    Truthiness = assert_sink_bug(Object, Remotes, Remote, Active, SrcState),
    assert_sink_bugs(Object, Remotes, Active, Tail, [Truthiness | Acc]).

assert_sink_bug({_Num, ObjBin, Meta}, Remotes, Remote, Active, SrcState) ->
    {_, Sink} = SrcState#src_state.pids,
    Version = SrcState#src_state.version,
    History = gen_server:call(Sink, history),
    ShouldSkip = lists:member(Remote, Remotes),
    if
        ShouldSkip andalso length(History) == length(SrcState#src_state.unacked_objects) ->
            true;
        ShouldSkip ->
            ?debugFmt("assert sink history length failure!~n"
                "    Remote: ~p~n"
                "    Length Sink Hist: ~p~n"
                "    Length Model Hist: ~p~n"
                "    Sink:~n"
                "~p~n"
                "    Model:~n"
                "~p",[Remote, length(History), length(SrcState#src_state.unacked_objects), History, SrcState#src_state.unacked_objects]),
            false;
        true ->
            Frame = hd(History),
            case {Version, Frame} of
                {1, {objects, {_Seq, ObjBin}}} ->
                    true;
                {2, {objects_and_meta, {_Seq, ObjBin, Meta}}} ->
                    true;
                _ ->
                    ?debugFmt("assert sink bug failure!~n"
                        "    Remote: ~p~n"
                        "    Remotes: ~p~n"
                        "    Active: ~p~n"
                        "    ObjBin: ~p~n"
                        "    Meta: ~p~n"
                        "    ShouldSkip: ~p~n"
                        "    Version: ~p~n"
                        "    Frame: ~p~n"
                        "    Length Sink Hist: ~p~n"
                        "    Length Model Hist: ~p", [Remote, Remotes, Active, ObjBin, Meta, ShouldSkip, Version, Frame, length(History), length(SrcState#src_state.unacked_objects)]),
                    false
            end
    end.

assert_sink_ackings(Version, Expecteds, Gots) ->
    assert_sink_ackings(Version, Expecteds, Gots, []).

assert_sink_ackings(_Version, [], [], Acc) ->
    lists:all(fun(true) -> true; (_) -> false end, Acc);

assert_sink_ackings(Version, [Expected | ETail], [Got | GotTail], Acc) ->
    AHead = assert_sink_acking(Version, Expected, Got),
    assert_sink_ackings(Version, ETail, GotTail, [AHead | Acc]).

assert_sink_acking(Version, {_SomeSeq, {1, ObjBin, Meta}}, Got) ->
    case {Version, Got} of
        {1, {objects, {_Seq, ObjBin}}} ->
            true;
        {2, {objects_and_meta, {_Seq, ObjBin, Meta}}} ->
            true;
        _ ->
            ?debugFmt("Sink ack failure!~n    Version: ~p~n    ObjBin: ~p~n    Meta: ~p~n    Got: ~p", [Version, ObjBin, Meta, Got]),
            false
    end.

%% ====================================================================
%% test callbacks
%% ====================================================================

connect_to_v1(RemoteName, MasterQueue) ->
    stateful:set(version, {realtime, {1,0}, {1,0}}),
    stateful:set(remote, RemoteName),
    {ok, SourcePid} = riak_repl2_rtsource_conn:start_link(RemoteName),
    receive
        {sink_started, SinkPid} ->
            wait_for_valid_sink_history(SinkPid, RemoteName, MasterQueue),
            ok = ensure_registered(RemoteName),
            {SourcePid, SinkPid}
    after 1000 ->
        {error, timeout}
    end.

connect_to_v2(RemoteName, MasterQueue) ->
    stateful:set(version, {realtime, {2,0}, {2,0}}),
    stateful:set(remote, RemoteName),
    {ok, SourcePid} = riak_repl2_rtsource_conn:start_link(RemoteName),
    receive
        {sink_started, SinkPid} ->
            wait_for_valid_sink_history(SinkPid, RemoteName, MasterQueue),
            ok = ensure_registered(RemoteName),
            {SourcePid, SinkPid}
    after 1000 ->
        {error, timeout}
    end.

disconnect(ConnectState) ->
    {Remote, SrcState} = ConnectState,
    #src_state{pids = {Source, Sink}} = SrcState,
    riak_repl2_rtq:unregister(Remote),
    Out = [riak_repl_test_util:wait_for_pid(P, 3000) || P <- [Source, Sink]],
    Out.

push_object(Remotes, BinObjects, State) ->
    Meta = [{routed_clusters, Remotes}],
    Active = [A || {A, _} <- State#state.sources],
    ExpectedRouted = lists:usort(Remotes ++ Active),
    ExpectedMeta = [{routed_clusters, ExpectedRouted}],
    riak_repl2_rtq:push(1, BinObjects, Meta),
    wait_for_pushes(State, Remotes),
    {1, BinObjects, ExpectedMeta}.

ack_objects(NumToAck, {Remote, SrcState}) ->
    {_, Sink} = SrcState#src_state.pids,
    ProcessAlive = is_process_alive(Sink),
    if
        ProcessAlive ->
            {ok, Acked} = gen_server:call(Sink, {ack, NumToAck}),
            case Acked of
                [] ->
                    ok;
                [{objects_and_meta, {Seq, _, _}} | _] ->
                    riak_repl2_rtq:ack(Remote, Seq);
                [{objects, {Seq, _}} | _] ->
                    riak_repl2_rtq:ack(Remote, Seq)
            end,
            Acked;
        true ->
            []
    end.

%% ====================================================================
%% helpful utility functions
%% ====================================================================

ensure_registered(RemoteName) ->
    ensure_registered(RemoteName, 10).

ensure_registered(_RemoteName, N) when N < 1 ->
    {error, registration_timeout};
ensure_registered(RemoteName, N) ->
    Status = riak_repl2_rtq:status(),
    Consumers = proplists:get_value(consumers, Status),
    case proplists:get_value(RemoteName, Consumers) of
        undefined ->
            timer:sleep(100),
            ensure_registered(RemoteName, N - 1);
        _ ->
            ok
    end.

wait_for_valid_sink_history(Pid, Remote, MasterQueue) ->
    NewQueue = [{Seq, Queued} || {Seq, RoutedRemotes, _Binary, Queued} <- MasterQueue, not lists:member(Remote, RoutedRemotes)],
    if
        length(NewQueue) > 0 ->
            gen_server:call(Pid, {block_until, length(NewQueue)}, 30000);
        true ->
            ok
    end.

wait_for_pushes(State, Remotes) ->
    [wait_for_push(SrcState, Remotes) || SrcState <- State#state.sources].

wait_for_push({Remote, SrcState}, Remotes) ->
    case lists:member(Remote, Remotes) of
        true -> ok;
        _ ->
            WaitLength = length(SrcState#src_state.unacked_objects) + 1,
            {_, Sink} = SrcState#src_state.pids,
            gen_server:call(Sink, {block_until, WaitLength}, 3000)
    end.

plant_bugs(_Remotes, []) ->
    ok;
plant_bugs(Remotes, [{Remote, SrcState} | Tail]) ->
    case lists:member(Remote, Remotes) of
        true ->
            plant_bugs(Remotes, Tail);
        false ->
            {_, Sink} = SrcState#src_state.pids,
            ok = gen_server:call(Sink, bug),
            plant_bugs(Remotes, Tail)
    end.

abstract_connection_mgr() ->
    riak_repl_test_util:reset_meck(riak_core_connection_mgr, [passthrough]),
    meck:expect(riak_core_connection_mgr, connect, fun(_ServiceAndRemote, ClientSpec) ->
        proc_lib:spawn_link(fun() ->
            Version = stateful:version(),
            {_Proto, {TcpOpts, Module, Pid}} = ClientSpec,
            {ok, Socket} = gen_tcp:connect("localhost", ?SINK_PORT, [binary | TcpOpts]),
            ok = Module:connected(Socket, gen_tcp, {"localhost", ?SINK_PORT}, Version, Pid, [])
        end),
        {ok, make_ref()}
    end).

start_rt() ->
    riak_repl_test_util:kill_and_wait(riak_repl2_rt),
    riak_repl2_rt:start_link().

start_rtq() ->
    riak_repl_test_util:kill_and_wait(riak_repl2_rtq),
    riak_repl2_rtq:start_link().

start_tcp_mon() ->
    riak_repl_test_util:kill_and_wait(riak_core_tcp_mon),
    riak_core_tcp_mon:start_link().

start_fake_sink() ->
    riak_repl_test_util:reset_meck(riak_core_service_mgr, [passthrough]),
    WhoToTell = self(),
    meck:expect(riak_core_service_mgr, register_service, fun(HostSpec, _Strategy) ->
        riak_repl_test_util:kill_and_wait(fake_sink),
        {_Proto, {TcpOpts, _Module, _StartCB, _CBArgs}} = HostSpec,
        sink_listener(TcpOpts, WhoToTell)
    end),
    riak_repl2_rtsink_conn:register_service().

sink_listener(TcpOpts, WhoToTell) ->
    TcpOpts2 = [binary, {reuseaddr, true} | TcpOpts],
    Pid = proc_lib:spawn_link(fun() ->
        {ok, Listen} = gen_tcp:listen(?SINK_PORT, TcpOpts2),
        proc_lib:spawn(?MODULE, sink_acceptor, [Listen, WhoToTell]),
        receive
            _ -> ok
        end
    end),
    register(fake_sink, Pid),
    {ok, Pid}.

sink_acceptor(Listen, WhoToTell) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Version = stateful:version(),
    Pid = proc_lib:spawn_link(?MODULE, fake_sink, [Socket, Version, undefined, []]),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! start,
    WhoToTell ! {sink_started, Pid},
    sink_acceptor(Listen, WhoToTell).

fake_sink(Socket, Version, Bug, History) ->
    receive
        start ->
            inet:setopts(Socket, [{active, once}]),
            fake_sink(Socket, Version, Bug, History);
        stop ->
            ok;
        {'$gen_call', From, history} ->
            gen_server:reply(From, History),
            fake_sink(Socket, Version, Bug, History);
        {'$gen_call', From, {ack, Num}} when Num =< length(History) ->
            {NewHistory, Return} = lists:split(length(History) - Num, History),
            gen_server:reply(From, {ok, Return}),
            fake_sink(Socket, Version, Bug, NewHistory);
        {'$gen_call', {NewBug, _Tag} = From, bug} ->
            gen_server:reply(From, ok),
            fake_sink(Socket, Version, {once_bug, NewBug}, History);
        {'$gen_call', From, {block_until, HistoryLength}} when length(History) >= HistoryLength ->
            gen_server:reply(From, ok),
            fake_sink(Socket, Version, Bug, History);
        {'$gen_call', From, {block_until, HistoryLength}} ->
            fake_sink(Socket, Version, {block_until, From, HistoryLength}, History);
        {'$gen_call', From, Msg} ->
            gen_server:reply(From, {error, badcall}),
            fake_sink(Socket, Version, Bug, History);
        {tcp, Socket, Bin} ->
            History2 = fake_sink_nom_frames(Bin, History),
            NewBug = case Bug of
                {once_bug, Target} ->
                    Self = self(),
                    [Frame | _] = History2,
                    Target ! {got_data, Self, Frame},
                    undefined;
                {block_until, From, Length} when length(History2) >= Length ->
                    gen_server:reply(From, ok),
                    undefined;
                _ ->
                    Bug
            end,
            inet:setopts(Socket, [{active, once}]),
            fake_sink(Socket, Version, NewBug, History2);
        {tcp_error, Socket, Err} ->
            exit(Err);
        {tcp_closed, Socket} ->
            ok
    end.

fake_sink_nom_frames({ok, undefined, <<>>}, History) ->
    History;
fake_sink_nom_frames({ok, undefined, Rest}, History) ->
    ?debugFmt("Frame issues: binary left over: ~p", [Rest]),
    History;
fake_sink_nom_frames({ok, Frame, Rest}, History) ->
    fake_sink_nom_frames(Rest, [Frame | History]);
fake_sink_nom_frames(Bin, History) ->
    fake_sink_nom_frames(riak_repl2_rtframe:decode(Bin), History).