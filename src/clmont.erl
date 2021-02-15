%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2021, Tony Rogvall
%%% @doc
%%%    Run mongomery operations on openCL
%%% @end
%%% Created : 12 Feb 2021 by Tony Rogvall <tony@rogvall.se>

-module(clmont).

-compile(export_all).

-include_lib("cl/include/cl.hrl").
-include("mont.hrl").

build() ->
    E = clu:setup(all),
    Filename = filename:join(code:priv_dir(mpa),"clmont.cl"),
    Include  = filename:join(code:lib_dir(mpa),"c_src"),
    case clu:build_source_file(E,Filename,"-I"++Include) of
	{error,{[{ok,error}],
		[Message]}} ->
	    io:put_chars(Message),
	    error;
	Res ->
	    Res
    end.

-define(P_1024, 1191703890297837857254846218124820162520314254482239260141586246493315566589245659462156276340012962327654624865776671922725912417154643528357403702766406672783187741039499777500937664819366321506835371609274218842538110523885904400885445461904752292635899168049169243216400297218378136654191604761801220538347).

mont() ->
    %% N = (1 bsl 63)+13,
    N = ?P_1024,
    mpz:mont_w(cios, N, 32).

format() ->
    mpz:format_mont(mont()).

%% Run 1000 pow operations

test() ->
    test(gpu).

test(DevType) ->
    test(DevType, 1).

test(DevType, Count) ->
    M = mont(),

    As = [random_a(M) || _ <- lists:seq(1, Count)],
    Ams = [mpz:to_mont(Ai,M) || Ai <- As],
    AsData = list_to_binary([encode_number(Am,32,M#mont.k) || Am <- Ams]),

    X = random_x(M),
    XBits = gmp_nif:big_bits(X),
    XData = encode_number(X, 32, XBits),
    case run(AsData,XData,XBits,DevType,Count) of
	{ok,ResData} ->
	    Rs = decode_numbers(ResData,32,M#mont.k),
	    Rs1 = [mpz:from_mont(Rm,M) || Rm <- Rs],
	    %% FIXME: does not return correct result!
	    lists:foreach(
	      fun({R,Ai}) ->
		      io:format("Ai=~w,X=~w,R=~w\n", [Ai,X,R]),
		      io:format("Ri=~w\n", [mpz:powm(Ai, X, M#mont.n)])
	      end, lists:zip(Rs1, As)),
	    Rs1;
	Error ->
	    Error
    end.

run(AsData,XData,XBits,DevType,Count) ->
    E = clu:setup(DevType),
    io:format("platform created\n"),

    Filename = filename:join(code:priv_dir(mpa),"clmont.cl"),
    Include  = filename:join(code:lib_dir(mpa),"c_src"),

    io:format("build: ~s\n", [Filename]),
    {ok,Program} = clu:build_source_file(E, Filename, "-I"++Include),
    io:format("program built\n"),
    
    N = byte_size(AsData),

    %% Create input/output data memory (implicit copy_host_ptr)
    {ok,Amem} = cl:create_buffer(E#cl.context,[read_only],N),
    io:format("input Amem memory ~w created\n", [N]),

    %% Create input data memory (implicit copy_host_ptr)
    NX = byte_size(XData),
    {ok,Xmem} = cl:create_buffer(E#cl.context,[read_only],NX),
    io:format("input Xmem memory ~w created\n", [NX]),

    %% Create output data memory (implicit copy_host_ptr)
    {ok,Rmem} = cl:create_buffer(E#cl.context,[write_only],N),
    io:format("output Rmem memory ~w created\n", [N]),

    %% Create the command queue for the first device
    {ok,Queue} = cl:create_queue(E#cl.context,hd(E#cl.devices),[]),
    io:format("queue created\n"),

    %% Create the pow kernel object
    {ok,Kernel} = cl:create_kernel(Program, "montpow"),
    io:format("kernel created: ~p\n", [Kernel]),

    %% Write data into input array 
    {ok,Event1} = cl:enqueue_write_buffer(Queue, Amem, 0, N, AsData, []),
    io:format("write ~w bytes to Amem data enqueued\n", [N]),

    {ok,Event2} = cl:enqueue_write_buffer(Queue, Xmem, 0, NX, XData, []),
    io:format("write ~w bytes X data enqueued\n", [NX]),

    %% Set kernel arguments
    clu:apply_kernel_args(Kernel, [Amem,Xmem,{uint,XBits},Rmem,{uint,Count}]),
    io:format("kernel args set\n"),

    Device = hd(E#cl.devices),
    {ok,MaxUnits} = cl:get_device_info(Device, max_compute_units),
    io:format("max_compute_units = ~w\n", [MaxUnits]),
    {ok,WGSize} = cl:get_kernel_workgroup_info(Kernel, Device, work_group_size),

    EGlobal = global_size(Count,WGSize),
    ELocal = local_size(EGlobal,WGSize),

    T0 = erlang:monotonic_time(),

    {ok,Event3} = cl:enqueue_nd_range_kernel(Queue, Kernel,
					     [EGlobal], [ELocal], 
					     [Event1,Event2]),
    io:format("nd range [~w, ~w] kernel enqueued\n",
	      [[EGlobal],[ELocal]]),
    
    %% Enqueue the read from device memory (wait for kernel to finish)
    {ok,Event4} = cl:enqueue_read_buffer(Queue,Rmem,0,N,[Event3]),
    io:format("read Rmem buffer ~w enqueued\n", [N]),

    %% Now flush the queue to make things happend 
    ok = cl:flush(Queue),
    io:format("flushed\n"),

    %% Wait for Result buffer to be written
    io:format("wait\n"),

    Res = cl:wait(Event4,10000),

    T1 = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(T1-T0,native,microsecond),
    TimeS = Time/1000000,
    PPS = Count/TimeS,
    io:format("time=~f,  #pow/s = ~f\n", [TimeS,PPS]),

    %%
    cl:release_mem_object(Amem),
    cl:release_mem_object(Xmem),
    cl:release_mem_object(Rmem),
    cl:release_queue(Queue),
    cl:release_kernel(Kernel),
    cl:release_program(Program),

    clu:teardown(E),
    Res.

-define(GET(M,X), maps:get((X),(M))).

test_mul_loop() ->
    test_mul_loop(1000).

test_mul_loop(N) ->
    K = 1056,  %% max number of bits set in clmont.cl
    W = 32,
    C = mul0_setup(W, K),
    test_mul_loop_(C,N,W,K),
    mul0_teardown(C).


test_mul_loop_(_C,0,_W,_K) ->
    ok;
test_mul_loop_(C,I,W,K) ->
    Count = 1,
    A = uniform(1, (1 bsl K))-1,
    B = uniform(1, (1 bsl K))-1,
    AData = encode_number(A, W, K),
    BData = encode_number(B, W, K),
    N = ?GET(C,n),
    {ok,Event1} = cl:enqueue_write_buffer(?GET(C,q),?GET(C,a),0,N,AData,[]),
    {ok,Event2} = cl:enqueue_write_buffer(?GET(C,q),?GET(C,b),0,N,BData, []),
    clu:apply_kernel_args(?GET(C,k),[?GET(C,a),?GET(C,b),?GET(C,r),
				     {uint,Count}]),
    {ok,WGSize} = cl:get_kernel_workgroup_info(?GET(C,k),?GET(C,d),
					       work_group_size),
    EGlobal = global_size(Count,WGSize),
    ELocal = local_size(EGlobal,WGSize),
    {ok,Event3} = cl:enqueue_nd_range_kernel(?GET(C,q), ?GET(C,k),
					     [EGlobal], [ELocal], 
					     [Event1,Event2]),
    {ok,Event4} = cl:enqueue_read_buffer(?GET(C,q),?GET(C,r),0,N,[Event3]),
    ok = cl:flush(?GET(C,q)),
    Res = cl:wait(Event4,10000),
    case Res of
	{ok, RData} ->
	    R = decode_number(RData,32),
	    R = (A*B) band ((1 bsl K)-1),  %% verify 
	    {ok,R};
	_ ->
	    Res
    end,
    test_mul_loop_(C,I-1,W,K).



%% multiply two K-bit numbers
test_mul(A, B) ->
    Count = 1,
    K = 1056,  %% max number of bits set in clmont.cl
    W = 32,
    C = mul0_setup(W, K),

    AData = encode_number(A, W, K),
    BData = encode_number(B, W, K),
    N = ?GET(C,n),

    {ok,Event1} = cl:enqueue_write_buffer(?GET(C,q),?GET(C,a),0,N,AData,[]),
    {ok,Event2} = cl:enqueue_write_buffer(?GET(C,q),?GET(C,b),0,N,BData, []),

    clu:apply_kernel_args(?GET(C,k),[?GET(C,a),?GET(C,b),?GET(C,r),
				     {uint,Count}]),

    {ok,WGSize} = cl:get_kernel_workgroup_info(?GET(C,k),?GET(C,d),
					       work_group_size),
    EGlobal = global_size(Count,WGSize),
    ELocal = local_size(EGlobal,WGSize),
    {ok,Event3} = cl:enqueue_nd_range_kernel(?GET(C,q), ?GET(C,k),
					     [EGlobal], [ELocal], 
					     [Event1,Event2]),

    {ok,Event4} = cl:enqueue_read_buffer(?GET(C,q),?GET(C,r),0,N,[Event3]),
    ok = cl:flush(?GET(C,q)),
    Res = cl:wait(Event4,10000),

    mul0_teardown(C),

    case Res of
	{ok, RData} ->
	    R = decode_number(RData,32),
	    R = (A*B) band ((1 bsl 1056)-1),  %% verify 
	    {ok,R};
	_ ->
	    Res
    end.

mul0_setup(W,K) ->
    E = clu:setup(gpu),
    Filename = filename:join(code:priv_dir(mpa),"clmont.cl"),
    Include  = filename:join(code:lib_dir(mpa),"c_src"),
    S = (K+W-1) div W,
    N = S*(W div 8),
    {ok,Program} = clu:build_source_file(E, Filename, "-I"++Include),
    {ok,Amem} = cl:create_buffer(E#cl.context,[read_only],  N),
    {ok,Bmem} = cl:create_buffer(E#cl.context,[read_only],  N),
    {ok,Rmem} = cl:create_buffer(E#cl.context,[write_only], N),
    {ok,Queue} = cl:create_queue(E#cl.context,hd(E#cl.devices),[]),
    {ok,Kernel} = cl:create_kernel(Program, "mul0"),
    Device = hd(E#cl.devices),
    #{ n => N,
       w => W,
       a => Amem,
       b => Bmem,
       r => Rmem,
       q => Queue,
       k => Kernel,
       p => Program,
       d => Device,
       clu => E }.

mul0_teardown(C) ->
    cl:release_mem_object(?GET(C,a)),
    cl:release_mem_object(?GET(C,b)),
    cl:release_mem_object(?GET(C,r)),
    cl:release_queue(?GET(C,q)),
    cl:release_kernel(?GET(C,k)),
    cl:release_program(?GET(C,p)),
    clu:teardown(?GET(C,clu)).

    

local_size(N, WorkGroupSize) when N > WorkGroupSize -> WorkGroupSize;
local_size(N, _WorkGroupSize) -> N.

global_size(N, WorkGroupSize) when N > WorkGroupSize -> 
    ((N+WorkGroupSize+1) div WorkGroupSize)*WorkGroupSize;
global_size(N, _WorkGroupSize) -> N.


random_a(M) ->
    %% P = M#mont.n,
    %% uniform(0, P-1).
    %% uniform(1,10).
    2.

random_x(M) ->
    %% Q = (M#mont.n - 1) div 2,
    %% uniform(1, Q),
    10.



uniform(Min, Max) ->
    Min1 = Min - 1,
    N = Max-Min1,
    R = rand:uniform(N),
    R+Min1.

%% encode a K bit number in W bit digits
encode_number(N, W, K) ->
    Wm = (1 bsl W)-1,
    encode_number_(N, W, Wm, K, []).

encode_number_(_N, _W, _Wm, K, Acc) when K =< 0 ->
    %% io:format("~w\n", [lists:reverse(Acc)]),
    << << ?cl_uint(N) >> || N <- lists:reverse(Acc) >>;
encode_number_(N, W, Wm, K, Acc) ->
    encode_number_(N bsr W, W, Wm, K-W, [(N band Wm)|Acc]).

%% decode numbers
decode_numbers(Data, W, K) ->
    Size = (((K+W-1) div W)*W) div 8,  %% byte size
    decode_numbers_(Data, Size, W, K, []).

decode_numbers_(Data, Size, W, K, Acc) ->
    case Data of
	<<>> ->
	    lists:reverse(Acc);
	<<Bin:Size/binary,Data1/binary>> ->
	    decode_numbers_(Data1,Size,W,K,[decode_number(Bin,W)|Acc])
    end.

decode_number(Bin, W) ->
    decode_number(Bin, W, 0, 0).

decode_number(<<>>, _W, _Shift, Num) ->
    Num;
decode_number(Bin, W, Shift, Num) ->
    <<?cl_uint(N),Bin1/binary>> = Bin,
    decode_number(Bin1, W, Shift+W, Num bor (N bsl Shift)).
    
