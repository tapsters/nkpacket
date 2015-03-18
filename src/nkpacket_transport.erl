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

%% @doc NkPACKET Transport control module
-module(nkpacket_transport).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([connect/3, send/4, get_connected/2, get_connected/3]).
-export([get_listener/1, open_port/2, get_defport/2]).

-export_type([socket/0]).

-compile({no_auto_import,[get/1]}).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-type socket() :: 
    port() | ssl:sslsocket() | {port(), integer()} | pid().

-define(CONN_TRIES, 100).
-define(OPEN_ITERS, 5).


%% ===================================================================
%% Public
%% ===================================================================


%% @private Finds a connected transport
-spec get_connected(nkpacket:domain(), nkpacket:raw_connection()) ->
    [nkpacket:nkport()].

get_connected(Domain, Conn) ->
    get_connected(Domain, Conn, #{}).


%% @private Finds a connected transport
-spec get_connected(nkpacket:domain(), nkpacket:raw_connection(), map()) ->
    [nkpacket:nkport()].

get_connected(Domain, {_Proto, Transp, _Ip, _Port}=Conn, Opts) 
              when Transp==ws; Transp==wss ->
    Path = maps:get(path, Opts, <<"/">>),
    [
        NkPort || 
        {#nkport{meta=Meta}=NkPort, _} 
            <- nklib_proc:values({nkpacket_connection, Domain, Conn}),
            maps:get(path, Meta, <<"/">>)==Path
    ];

get_connected(Domain, {_, _, _, _}=Conn, _Opts) ->
    [NkPort || 
        {NkPort, _} <- nklib_proc:values({nkpacket_connection, Domain, Conn})].


%% @private
-spec send(nkpacket:domain(), [nkpacket:send_spec()], term(), nkpacket:send_opts()) ->
    ok | {error, term()}.

send(Domain, [Uri|Rest], Msg, Opts) when is_binary(Uri); is_list(Uri) ->
    case nklib_parse:uris(Uri) of
        PUris when is_list(PUris) ->
            send(Domain, [PUri || PUri <- PUris]++Rest, Msg, Opts);
        error ->
            send(Domain, Rest, Msg, Opts#{last_error=>{invalid_uri, Uri}})
    end;
     
send(Domain, [#uri{domain=Host}=Uri|Rest], Msg, Opts) ->
    case nkpacket:resolve(send, Domain, Uri) of
        {ok, RawConns, UriOpts} ->
            ?debug(Domain, "Transport send to ~p (~p)", [RawConns, Rest]),
            Opts1 = maps:merge(UriOpts, Opts),
            % Opts2 = Opts1#{transport_uri => Uri},
            Opts2 = case maps:is_key(host, Opts1) of
                false -> Opts1#{host=>Host};
                true -> Opts1
            end,
            send(Domain, RawConns++Rest, Msg, Opts2);
        {error, Error} ->
            ?notice(Domain, "Error sending to ~p: ~p", [Uri, Error]),
            send(Domain, Rest, Msg, Opts#{last_error=>Error})
    end;

send(Domain, [#nkport{domain=Domain}=NkPort|Rest], Msg, Opts) ->
    ?debug(Domain, "Transport send to flow ~p", [NkPort]),
    case do_send(Msg, [NkPort], Opts#{udp_to_tcp=>false}) of
        {ok, NkPort1} -> {ok, NkPort1};
        {error, Opts1} -> send(Domain, Rest, Msg, Opts1)
    end;

send(Domain, [{current, {Protocol, udp, Ip, Port}}|Rest], Msg, Opts) ->
    send(Domain, [{Protocol, udp, Ip, Port}|Rest], Msg, Opts);

send(Domain, [{current, Conn}|Rest], Msg, Opts) ->
    NkPorts = get_connected(Domain, Conn, Opts),
    send(Domain, NkPorts++Rest, Msg, Opts);

send(Domain, [{Protocol, Transp, Ip, 0}|Rest], Msg, Opts) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} ->
            send(Domain, [{Protocol, Transp, Ip, Port}|Rest], Msg, Opts);
        error ->
            send(Domain, Rest, Msg, Opts#{last_error=>invalid_default_port})
    end;

send(Domain, [{_, _, _, _}=Conn|Rest], Msg, #{force_new:=true}=Opts) ->
    RemoveOpts = [force_new, udp_to_tcp, last_error],
    ConnOpts = maps:without(RemoveOpts, Opts),
    ?debug(Domain, "Transport connecting to ~p (~p)", [Conn, ConnOpts]),
    case connect(Domain, [Conn], ConnOpts) of
        {ok, NkPort} ->
            case do_send(Msg, [NkPort], Opts) of
                {ok, NkPort1} ->
                    {ok, NkPort1};
                retry_tcp ->
                    Conn1 = setelement(2, Conn, tcp), 
                    send(Domain, [Conn1|Rest], Msg, Opts);
                {error, Opts1} ->
                    send(Domain, Rest, Msg, Opts1)
            end;
        {error, Error} ->
            ?notice(Domain, "Error connecting to ~p: ~p", [Conn, Error]),
            send(Domain, Rest, Msg, Opts#{last_error=>Error})
    end;

send(Domain, [{_, _, _, _}=Conn|Rest]=Spec, Msg, Opts) ->
    ?debug(Domain, "Transport trying previous connection to ~p (~p)", [Conn, Opts]),
    NkPorts = get_connected(Domain, Conn, Opts),
    case do_send(Msg, NkPorts, Opts) of
        {ok, NkPort1} -> 
            {ok, NkPort1};
        retry_tcp ->
            Conn1 = setelement(2, Conn, tcp), 
            send(Domain, [Conn1|Rest], Msg, Opts);
        {error, Opts1} -> 
            send(Domain, Spec, Msg, Opts1#{force_new=>true})
    end;

send(Domain, [Term|Rest], Msg, Opts) ->
    ?warning(Domain, "Invalid send specification: ~p", [Term]),
    send(Domain, Rest, Msg, Opts#{last_error=>{invalid_send_specification, Term}});

send(_Domain, [], _Msg, #{last_error:=Error}) -> 
    {error, Error};

send(_Domain, [], _, _) ->
    {error, no_transports}.


%% @private
-spec do_send(term(), [#nkport{}], nkpacket:send_opts()) ->
    {ok, #nkport{}} | retry_tcp | {error, nkpacket:send_opts()}.

do_send(_Msg, [], Opts) ->
    {error, Opts};

do_send(Msg, [#nkport{domain=Domain}=NkPort|Rest], Opts) ->
    case unparse(Msg, NkPort) of
        {ok, RawMsg} ->
            case nkpacket_connection:send(NkPort, RawMsg) of
                ok ->
                    {ok, NkPort};
                {error, udp_too_large} ->
                    case Opts of
                        #{udp_to_tcp:=true} ->
                            retry_tcp;
                        _ ->
                            ?notice(Domain, "Error sending msg: udp_too_large", []),
                            do_send(Msg, Rest, Opts#{last_error=>udp_too_large})
                    end;
                {error, Error} ->
                    ?notice(Domain, "Error sending msg: ~p", [Error]),
                    do_send(Msg, Rest, Opts#{last_error=>Error})
            end;
        error ->
            {error, Opts#{last_error=>unparse_error}}
    end.
 

%% @private
unparse(Term, #nkport{domain=Domain, protocol=Protocol}=NkPort) -> 
    case erlang:function_exported(Protocol, unparse, 2) of
        true ->
            case Protocol:unparse(Term, NkPort) of
                {ok, RawMsg} ->
                    {ok, RawMsg};
                continue ->
                    unparse2(Term, NkPort);
                {error, Error} ->
                    ?notice(Domain, "Error unparsing msg: ~p", [Error]),
                    error

            end;
        false ->
            unparse2(Term, NkPort)
    end.


%% @private
unparse2(Term, #nkport{domain=Domain, protocol=Protocol}=NkPort) -> 
    case erlang:function_exported(Protocol, conn_unparse, 2) of
        true ->
            case nkpacket_connection:unparse(NkPort, Term) of
                {ok, RawMsg} ->
                    {ok, RawMsg};
                {error, Error} ->
                    ?notice(Domain, "Error unparsing msg: ~p", [Error]),
                    error
            end;
        false ->
            {ok, Term}
    end.

        
%% @private Starts a new outbound connection.
-spec connect(nkpacket:domain(), [nkpacket:raw_connection()], nkpacket:connect_opts()) ->
    {ok, nkpacket:nkport()} | {error, term()}.

connect(_Domain, [], _Opts) ->
    {error, no_transports};

connect(Domain, [Conn|Rest], Opts) ->
    case try_connect(Domain, Conn, Opts, ?CONN_TRIES) of
        {ok, NkPort} ->
            {ok, NkPort};
        {error, Error} when Rest==[] ->
            {error, Error};
        {error, _} ->
            connect(Domain, Rest, Opts)
    end.


%% @private
try_connect(_, _, _, 0) ->
    {error, connection_busy};

try_connect(Domain, {Protocol, Transp, Ip, 0}, Opts, Tries) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} -> 
            try_connect(Domain, {Protocol, Transp, Ip, Port}, Opts, Tries);
        error ->
            {error, invalid_default_port}
    end;

try_connect(Domain, {Protocol, udp, Ip, Port}, Opts, _Tries) ->
    raw_connect(Domain, {Protocol, udp, Ip, Port}, Opts);

try_connect(Domain, {_Protocol, Transp, Ip, Port}=Conn, Opts, Tries) ->
    ConnId = {Transp, Ip, Port},
    case nklib_store:put_dirty_new({nkpacket_connect_block, ConnId}, true) of
        true ->
            try 
                raw_connect(Domain, Conn, Opts)
            catch
                error:Value -> 
                    ?warning(Domain, "Exception ~p launching connection: ~p", 
                                  [Value, erlang:get_stacktrace()]),
                    {error, Value}
            after
                catch nklib_store:del_dirty({nkpacket_connect_block, ConnId})
            end;
        false ->
            timer:sleep(100),
            try_connect(Domain, Conn, Opts, Tries-1)
    end.
                

%% @private Starts a new connection to a remote server
%% Tries to find an associated listening transport, 
%% to use the listening address, port and meta from it
-spec raw_connect(nkpacket:domain(), nkpacket:raw_connection(), nkpacket:connect_opts()) ->
    {ok, nkpacket:nkport()} | {error, term()}.
         
raw_connect(Domain, {Protocol, Transp, Ip, Port}, Opts) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    Listening = nkpacket:get_listening(Domain, Protocol, Transp, Class),
    BasePort = case Opts of
        #{listen_ip:=ListenIp, listen_port:=ListenPort} ->
            case 
                [
                    NkPort || #nkport{listen_ip=LIp, listen_port=LPort}=NkPort
                    <- Listening, LIp==ListenIp, LPort==ListenPort
                ]
            of
                [NkPort|_] -> NkPort;
                [] -> #nkport{}
            end;
        _ ->
            case Listening of
                [NkPort|_] -> NkPort;
                [] -> #nkport{}
            end
    end,
    #nkport{
        pid = ListenPid,
        meta = Meta
    } = BasePort,
    NkPort1 = BasePort#nkport{
        domain = Domain,
        transp = Transp,
        remote_ip = Ip, 
        remote_port = Port, 
        protocol = Protocol,
        meta = maps:merge(Meta, Opts)
    },
    case Transp of
        udp when is_pid(ListenPid) -> nkpacket_transport_udp:connect(NkPort1);
        udp -> {error, no_listening_transport};
        tcp -> nkpacket_transport_tcp:connect(NkPort1);
        tls -> nkpacket_transport_tcp:connect(NkPort1);
        sctp when is_pid(ListenPid) -> nkpacket_transport_sctp:connect(NkPort1);
        sctp -> {error, no_listening_transport};
        ws -> nkpacket_transport_ws:connect(NkPort1);
        wss -> nkpacket_transport_ws:connect(NkPort1);
         _ -> {error, {unknown_transport, Transp}}
    end.


-spec get_listener(nkpacket:nkport()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_listener(#nkport{transp=udp}=NkPort) ->
    {ok, nkpacket_transport_udp:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==tcp; Transp==tls ->
    {ok, nkpacket_transport_tcp:get_listener(NkPort)};

get_listener(#nkport{transp=sctp}=NkPort) ->
    {ok, nkpacket_transport_sctp:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    {ok, nkpacket_transport_ws:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==http; Transp==https ->
    {ok, nkpacket_transport_http:get_listener(NkPort)};

get_listener(_) ->
    {error, invalid_transport}.


%% @doc Gets the default port for a protocol
-spec get_defport(nkpacket:protocol(), nkpacket:transport()) ->
    {ok, inet:port_number()} | error.

get_defport(Protocol, Transp) ->
    case erlang:function_exported(Protocol, default_port, 1) of
        true ->
            case Protocol:default_port(Transp) of
                Port when is_integer(Port), Port > 0 -> 
                    {ok, Port};
                Other -> 
                    lager:warning("Error calling ~p:default_port(~p): ~p",
                                  [Protocol, Transp, Other]),
                    error
            end;
        false ->
            error
    end.


%% @private Tries to open a network port
%% If Port==0, it first tries the "default" port for this transport, if defined
%% If port is in use if tries again after a while
-spec open_port(nkpacket:nkport(),list()) ->
    {ok, port()} | {error, term()}.

open_port(NkPort, Opts) ->
    #nkport{
        domain = Domain, 
        transp = Transp,
        local_ip = Ip, 
        local_port = Port, 
        protocol = Protocol
    } = NkPort,
    {Module, Fun} = case Transp of
        udp -> {gen_udp, open};
        tcp -> {gen_tcp, listen};
        tls -> {ssl, listen};
        sctp -> {gen_sctp, open};
        ws -> {gen_tcp, listen};
        wss -> {ssl, listen};
        http -> {gen_tcp, listen};
        https -> {ssl, listen}
    end,

    DefPort = case erlang:function_exported(Protocol, default_port, 1) of
        true -> 
            case Protocol:default_port(Transp) of
                DefPort0 when is_integer(DefPort0) -> DefPort0;
                _ -> undefined
            end;
        false ->
            undefined
    end,
    case Port of
        0 when is_integer(DefPort) ->
            case Module:Fun(DefPort, Opts) of
                {ok, Socket} ->
                    {ok, Socket};
                {error, _} ->
                    open_port(Domain, Ip, 0, Module, Fun, Opts, ?OPEN_ITERS)
            end;
        _ ->
            open_port(Domain, Ip, Port, Module, Fun, Opts, ?OPEN_ITERS)
    end.


%% @private Checks if a port is available for UDP and TCP
-spec open_port(nkpacket:domain(), inet:ip_address(), inet:port_number(),
                module(), atom(), list(), pos_integer()) ->
    {ok, port()} | {error, term()}.

open_port(Domain, Ip, Port, Module, Fun, Opts, Iter) ->
    case Module:Fun(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            ?warning(Domain, "~p port ~p is in use, waiting (~p)", 
                     [Module, Port, Iter]),
            timer:sleep(1000),
            open_port(Domain, Ip, Port, Module, Fun, Opts, Iter-1);
        {error, Error} ->
            {error, Error}
    end.





