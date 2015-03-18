%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(udp_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include("nkpacket.hrl").

udp_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		nkpacket_app:start(),
    		?debugMsg("Starting UDP test")
		end,
		fun(_) -> 
			ok 
		end,
	    fun(_) ->
		    [
				fun() -> basic() end,
				fun() -> listen() end,
				fun() -> stun() end
			]
		end
  	}.


basic() ->
	_ = test_util:reset_2(),
	Conn1 = {test_protocol, udp, {0,0,0,0}, 0},
	% First '0' port try to open default transport port (1234)
	{ok, UdpP1} = nkpacket:start_listener(dom1, Conn1, #{}),
	[
		#nkport{
			domain = dom1,transp = udp,
    	    local_ip = {0,0,0,0}, local_port = 1234,
    	    remote_ip = undefined, remote_port = undefined,
     		listen_ip = {0,0,0,0}, listen_port = 1234,
     		protocol = test_protocol, pid = UdpP1, 
     		meta = #{idle_timeout := 30000}
        }
	] = nkpacket:get_all(dom1),

	% Since '1234' is not available, a random one is used
	Conn2 = {test_protocol, udp, {0,0,0,0}, 0},
	{ok, UdpP2A} = nkpacket:start_listener(dom2, Conn2, 
										   #{udp_starts_tcp=>true, idle_timeout=>10000, 
						   			         tcp_listeners=>1}),
	timer:sleep(100),
	[
		#nkport{transp=tcp, local_port=P1, pid=TcpP2A, meta=#{idle_timeout:=10000}},
		#nkport{transp=udp, local_port=P1, pid=UdpP2A, meta=#{idle_timeout:=10000}}
	] = nkpacket:get_all(dom2),

	lager:warning("Some processes will be killed now..."),
	exit(TcpP2A, kill),
	timer:sleep(100),
	[
		#nkport{transp=tcp, local_port=P2, pid=TcpP2B, meta=#{idle_timeout:=10000}},
		#nkport{transp=udp, local_port=P2, pid=UdpP2B, meta=#{idle_timeout:=10000}}
	] = nkpacket:get_all(dom2),
	true = P2/=P1,
	true = TcpP2B/=TcpP2A,
	true = UdpP2B/=UdpP2A,

	exit(UdpP2B, kill),
	timer:sleep(100),
	[
		#nkport{transp=tcp, local_port=P3, pid=Tcp2C},
		#nkport{transp=udp, local_port=P3, pid=UdpP2C}
	] = nkpacket:get_all(dom2),
	true = P3/=P2,
	true = Tcp2C/=TcpP2B,
	true = UdpP2C/=UdpP2B,
 	ok = nkpacket:stop_all(dom1),
 	ok = nkpacket:stop_all(dom2),
	timer:sleep(100),
	[] = nkpacket:get_all(dom1),
	[] = nkpacket:get_all(dom2),
	ok.


listen() ->
	{Ref1, M1, Ref2, M2} = test_util:reset_2(),
	{ok, Udp1} = nkpacket:start_listener(dom1, "<test://all:20000;transport=udp>", M1),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,

	{ok, Socket} = gen_udp:open(0, [binary, {active, false}]),
    {ok, {{0,0,0,0}, LocalPort}} = inet:sockname(Socket),
	ok = gen_udp:send(Socket, {127,0,0,1}, 20000, erlang:term_to_binary(<<"test1">>)),
	receive {Ref1, conn_init} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, {parse, <<"test1">>}} -> ok after 1000 -> error(?LINE) end,

	[
		#nkport{local_ip={0,0,0,0}, local_port=20000, remote_ip=undefined,
				 remote_port=undefined, pid=Udp1, socket=UdpS1} = Listen,
		#nkport{local_ip={0,0,0,0}, local_port=20000, remote_ip={127,0,0,1},
				 remote_port=LocalPort, socket=UdpS1, 
				 meta=#{idle_timeout:=30000}} = Conn1
	] = 
		lists:sort(nkpacket:get_all(dom1)),
	
	% Send a message back, directly through the connection
	ok = nkpacket_connection:send(Conn1, <<"test2">>),
	% receive {Ref1, {unparse, <<"test2">>}} -> ok after 1000 -> error(?LINE) end,
	% We use the parse in test_protocol:conn_parse/4
	{ok, {{127,0,0,1}, 20000, <<"test2">>}} = gen_udp:recv(Socket, 0, 5000),
	
	% Send a message directly from the listening process
	ok = nkpacket_transport_udp:send(Listen, {127,0,0,1}, LocalPort, <<"test3">>, 5000),
	% We use the parse in test_protocol:listen_parse
	{ok, {{127,0,0,1}, 20000, <<"test3">>}} = gen_udp:recv(Socket, 0, 5000),

	[Conn1] = nkpacket_transport:get_connected(dom1, {test_protocol, udp, {127,0,0,1}, LocalPort}),
	[Conn1] = nkpacket_connection:get_all(dom1),
	ok = nkpacket_connection:stop(Conn1#nkport.pid, normal),
	receive {Ref1, conn_stop} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(50),
	[] = nkpacket_transport:get_connected(dom1, {test_protocol, udp, {127,0,0,1}, LocalPort}),
	[] = nkpacket_connection:get_all(dom1),

	ok = nkpacket:stop_listener(Udp1),
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(50),
	[] = nkpacket:get_all(dom1),

	% Now testing UDP without creating connections
	{ok, Udp2} = nkpacket:start_listener(dom1, "<test://all;transport=udp>",
										 M2#{udp_no_connections=>true}),
	receive {Ref2, listen_init} -> ok after 1000 -> error(?LINE) end,
	ok = gen_udp:send(Socket, {127,0,0,1}, 1234, <<"test4">>),
	receive {Ref2, {listen_parse, <<"test4">>}} -> ok after 1000 -> error(?LINE) end,

	[] = nkpacket_transport:get_connected(dom1, {test_protocol, udp, {127,0,0,1}, LocalPort}),
	[] = nkpacket_connection:get_all(dom1),
	ok = nkpacket:stop_listener(Udp2),
	receive {Ref2, listen_stop} -> ok after 1000 -> error(?LINE) end,
	timer:sleep(50),
	[] = nkpacket:get_all(dom1),
	test_util:ensure([Ref1, Ref2]).


stun() ->
	{Ref1, M1} = test_util:reset_1(),
	ok = nkpacket_config:register_protocol(dom1, test, test_protocol),
	{ok, Udp1} = nkpacket:start_listener(dom1, "<test://all:20000;transport=udp>",
										 M1#{udp_stun_reply=>true, udp_no_connections=>true}),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
	{ok, Socket} = gen_udp:open(0, [binary, {active, false}]),
    {ok, {{0,0,0,0}, LocalPort}} = inet:sockname(Socket),
    {Id, Request} = nkpacket_stun:binding_request(),

    % We send a STUN request to our server, it replies
    ok = gen_udp:send(Socket, {127,0,0,1}, 20000, Request),

	{ok, {_, _, Raw}} = gen_udp:recv(Socket, 0, 5000),
    {response, binding, Id, Data} = nkpacket_stun:decode(Raw),
    {{127,0,0,1}, LocalPort} = nklib_util:get_value(xor_mapped_address, Data),

    % We start a second listener that does not reply to STUNS
	{ok, Udp2} = nkpacket:start_listener(dom1, "<test://all:20001;transport=udp>",
	 									 M1#{udp_no_connections=>true}),
	receive {Ref1, listen_init} -> ok after 1000 -> error(?LINE) end,
    ok = gen_udp:send(Socket, {127,0,0,1}, 20001, Request),
    receive {Ref1, {listen_parse, <<0, 1, _/binary>>}} -> ok after 1000 -> error(?LINE) end,

    % But we can use it to send STUNS to our first server
    {ok, {127,0,0,1}, 20001} = 
    	nkpacket_transport_udp:send_stun_sync(Udp2, {127,0,0,1}, 20000, 5000),
    ok = nkpacket:stop_listener(Udp1),
	ok = nkpacket:stop_listener(Udp2),
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	receive {Ref1, listen_stop} -> ok after 1000 -> error(?LINE) end,
	test_util:ensure([Ref1]).











