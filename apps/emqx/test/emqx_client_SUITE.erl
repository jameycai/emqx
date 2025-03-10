%%--------------------------------------------------------------------
%% Copyright (c) 2018-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_client_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-import(lists, [nth/2]).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(TOPICS, [
    <<"TopicA">>,
    <<"TopicA/B">>,
    <<"Topic/C">>,
    <<"TopicA/C">>,
    <<"/TopicA">>
]).

-define(WILD_TOPICS, [
    <<"TopicA/+">>,
    <<"+/C">>,
    <<"#">>,
    <<"/#">>,
    <<"/+">>,
    <<"+/+">>,
    <<"TopicA/#">>
]).

-define(WAIT(EXPR, ATTEMPTS), ?retry(1000, ATTEMPTS, EXPR)).

all() ->
    [
        {group, mqttv3},
        {group, mqttv4},
        {group, mqttv5},
        {group, others}
    ].

groups() ->
    [
        {mqttv3, [non_parallel_tests], [t_basic_v3]},
        {mqttv4, [non_parallel_tests], [
            t_basic_v4,
            t_cm,
            t_cm_registry,
            %% t_will_message,
            %% t_offline_message_queueing,
            t_overlapping_subscriptions,
            %% t_keepalive,
            %% t_redelivery_on_reconnect,
            %% subscribe_failure_test,
            t_dollar_topics,
            t_sub_non_utf8_topic
        ]},
        {mqttv5, [non_parallel_tests], [t_basic_with_props_v5]},
        {others, [non_parallel_tests], [
            t_username_as_clientid,
            t_certcn_as_clientid_default_config_tls,
            t_certcn_as_clientid_tlsv1_3,
            t_certcn_as_clientid_tlsv1_2
        ]}
    ].

init_per_suite(Config) ->
    emqx_common_test_helpers:boot_modules(all),
    emqx_common_test_helpers:start_apps([]),
    emqx_config:put_listener_conf(ssl, default, [ssl_options, verify], verify_peer),
    emqx_listeners:restart_listener('ssl:default'),
    Config.

end_per_suite(_Config) ->
    emqx_common_test_helpers:stop_apps([]).

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    emqx_config:put_zone_conf(default, [mqtt, idle_timeout], 15000).

%%--------------------------------------------------------------------
%% Test cases for MQTT v3
%%--------------------------------------------------------------------

t_basic_v3(_) ->
    t_basic([{proto_ver, v3}]).

%%--------------------------------------------------------------------
%% Test cases for MQTT v4
%%--------------------------------------------------------------------

t_basic_v4(_Config) ->
    t_basic([{proto_ver, v4}]).

t_cm(_) ->
    emqx_config:put_zone_conf(default, [mqtt, idle_timeout], 1000),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{clientid, ClientId}]),
    {ok, _} = emqtt:connect(C),
    ?WAIT(#{clientinfo := #{clientid := ClientId}} = emqx_cm:get_chan_info(ClientId), 2),
    emqtt:subscribe(C, <<"mytopic">>, 0),
    ?WAIT(
        begin
            Stats = emqx_cm:get_chan_stats(ClientId),
            ?assertEqual(1, proplists:get_value(subscriptions_cnt, Stats))
        end,
        2
    ),
    ok.

t_idle_timeout_infinity(_) ->
    emqx_config:put_zone_conf(default, [mqtt, idle_timeout], infinity),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{clientid, ClientId}]),
    {ok, _} = emqtt:connect(C),
    ?WAIT(#{clientinfo := #{clientid := ClientId}} = emqx_cm:get_chan_info(ClientId), 2),
    emqtt:subscribe(C, <<"mytopic">>, 0),
    ?WAIT(
        begin
            Stats = emqx_cm:get_chan_stats(ClientId),
            ?assertEqual(1, proplists:get_value(subscriptions_cnt, Stats))
        end,
        2
    ),
    ok.

t_cm_registry(_) ->
    Children = supervisor:which_children(emqx_cm_sup),
    {_, Pid, _, _} = lists:keyfind(emqx_cm_registry, 1, Children),
    ignored = gen_server:call(Pid, <<"Unexpected call">>),
    gen_server:cast(Pid, <<"Unexpected cast">>),
    Pid ! <<"Unexpected info">>.

t_will_message(_Config) ->
    {ok, C1} = emqtt:start_link([
        {clean_start, true},
        {will_topic, nth(3, ?TOPICS)},
        {will_payload, <<"client disconnected">>},
        {keepalive, 1}
    ]),
    {ok, _} = emqtt:connect(C1),

    {ok, C2} = emqtt:start_link(),
    {ok, _} = emqtt:connect(C2),

    {ok, _, [2]} = emqtt:subscribe(C2, nth(3, ?TOPICS), 2),
    timer:sleep(5),
    ok = emqtt:stop(C1),
    timer:sleep(5),
    ?assertEqual(1, length(recv_msgs(1))),
    ok = emqtt:disconnect(C2),
    ct:pal("Will message test succeeded").

t_offline_message_queueing(_) ->
    {ok, C1} = emqtt:start_link([
        {clean_start, false},
        {clientid, <<"c1">>}
    ]),
    {ok, _} = emqtt:connect(C1),

    {ok, _, [2]} = emqtt:subscribe(C1, nth(6, ?WILD_TOPICS), 2),
    ok = emqtt:disconnect(C1),
    {ok, C2} = emqtt:start_link([
        {clean_start, true},
        {clientid, <<"c2">>}
    ]),
    {ok, _} = emqtt:connect(C2),

    ok = emqtt:publish(C2, nth(2, ?TOPICS), <<"qos 0">>, 0),
    {ok, _} = emqtt:publish(C2, nth(3, ?TOPICS), <<"qos 1">>, 1),
    {ok, _} = emqtt:publish(C2, nth(4, ?TOPICS), <<"qos 2">>, 2),
    timer:sleep(10),
    emqtt:disconnect(C2),
    {ok, C3} = emqtt:start_link([{clean_start, false}, {clientid, <<"c1">>}]),
    {ok, _} = emqtt:connect(C3),

    timer:sleep(10),
    emqtt:disconnect(C3),
    ?assertEqual(3, length(recv_msgs(3))).

t_overlapping_subscriptions(_) ->
    {ok, C} = emqtt:start_link([]),
    {ok, _} = emqtt:connect(C),

    {ok, _, [2, 1]} = emqtt:subscribe(C, [
        {nth(7, ?WILD_TOPICS), 2},
        {nth(1, ?WILD_TOPICS), 1}
    ]),
    timer:sleep(10),
    {ok, _} = emqtt:publish(C, nth(4, ?TOPICS), <<"overlapping topic filters">>, 2),
    timer:sleep(10),

    Num = length(recv_msgs(2)),
    ?assert(lists:member(Num, [1, 2])),
    if
        Num == 1 ->
            ct:pal(
                "This server is publishing one message for all\n"
                "                   matching overlapping subscriptions, not one for each."
            );
        Num == 2 ->
            ct:pal(
                "This server is publishing one message per each\n"
                "                    matching overlapping subscription."
            );
        true ->
            ok
    end,
    emqtt:disconnect(C).

%% t_keepalive_test(_) ->
%%     ct:print("Keepalive test starting"),
%%     {ok, C1, _} = emqtt:start_link([{clean_start, true},
%%                                           {keepalive, 5},
%%                                           {will_flag, true},
%%                                           {will_topic, nth(5, ?TOPICS)},
%%                                           %% {will_qos, 2},
%%                                           {will_payload, <<"keepalive expiry">>}]),
%%     ok = emqtt:pause(C1),
%%     {ok, C2, _} = emqtt:start_link([{clean_start, true},
%%                                           {keepalive, 0}]),
%%     {ok, _, [2]} = emqtt:subscribe(C2, nth(5, ?TOPICS), 2),
%%     ok = emqtt:disconnect(C2),
%%     ?assertEqual(1, length(recv_msgs(1))),
%%     ct:print("Keepalive test succeeded").

t_redelivery_on_reconnect(_) ->
    ct:pal("Redelivery on reconnect test starting"),
    {ok, C1} = emqtt:start_link([{clean_start, false}, {clientid, <<"c">>}]),
    {ok, _} = emqtt:connect(C1),

    {ok, _, [2]} = emqtt:subscribe(C1, nth(7, ?WILD_TOPICS), 2),
    timer:sleep(10),
    ok = emqtt:pause(C1),
    {ok, _} = emqtt:publish(
        C1,
        nth(2, ?TOPICS),
        <<>>,
        [{qos, 1}, {retain, false}]
    ),
    {ok, _} = emqtt:publish(
        C1,
        nth(4, ?TOPICS),
        <<>>,
        [{qos, 2}, {retain, false}]
    ),
    timer:sleep(10),
    ok = emqtt:disconnect(C1),
    ?assertEqual(0, length(recv_msgs(2))),
    {ok, C2} = emqtt:start_link([{clean_start, false}, {clientid, <<"c">>}]),
    {ok, _} = emqtt:connect(C2),

    timer:sleep(10),
    ok = emqtt:disconnect(C2),
    ?assertEqual(2, length(recv_msgs(2))).

%% t_subscribe_sys_topics(_) ->
%%     ct:print("Subscribe failure test starting"),
%%     {ok, C, _} = emqtt:start_link([]),
%%     {ok, _, [2]} = emqtt:subscribe(C, <<"$SYS/#">>, 2),
%%     timer:sleep(10),
%%     ct:print("Subscribe failure test succeeded").

t_dollar_topics(_) ->
    ct:pal("$ topics test starting"),
    {ok, C} = emqtt:start_link([
        {clean_start, true},
        {keepalive, 0}
    ]),
    {ok, _} = emqtt:connect(C),

    {ok, _, [1]} = emqtt:subscribe(C, nth(6, ?WILD_TOPICS), 1),
    {ok, _} = emqtt:publish(
        C,
        <<<<"$">>/binary, (nth(2, ?TOPICS))/binary>>,
        <<"test">>,
        [{qos, 1}, {retain, false}]
    ),
    timer:sleep(10),
    ?assertEqual(0, length(recv_msgs(1))),
    ok = emqtt:disconnect(C),
    ct:pal("$ topics test succeeded").

t_sub_non_utf8_topic(_) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, 1883, [{active, true}, binary]),
    ConnPacket = emqx_frame:serialize(#mqtt_packet{
        header = #mqtt_packet_header{type = 1},
        variable = #mqtt_packet_connect{
            clientid = <<"abcdefg">>
        }
    }),
    ok = gen_tcp:send(Socket, ConnPacket),
    receive
        {tcp, _, _ConnAck = <<32, 2, 0, 0>>} -> ok
    after 3000 -> ct:fail({connect_ack_not_recv, process_info(self(), messages)})
    end,
    SubHeader = <<130, 18, 25, 178>>,
    SubTopicLen = <<0, 13>>,
    %% this is not a valid utf8 topic
    SubTopic = <<128, 10, 10, 12, 178, 159, 162, 47, 115, 1, 1, 1, 1>>,
    SubQoS = <<1>>,
    SubPacket = <<SubHeader/binary, SubTopicLen/binary, SubTopic/binary, SubQoS/binary>>,
    ok = gen_tcp:send(Socket, SubPacket),
    receive
        {tcp_closed, _} -> ok
    after 3000 -> ct:fail({should_get_disconnected, process_info(self(), messages)})
    end,
    timer:sleep(1000),
    ListenerCounts = emqx_listeners:shutdown_count('tcp:default', {{0, 0, 0, 0}, 1883}),
    TopicInvalidCount = proplists:get_value(topic_filter_invalid, ListenerCounts),
    ?assert(is_integer(TopicInvalidCount) andalso TopicInvalidCount > 0),
    ok.

%%--------------------------------------------------------------------
%% Test cases for MQTT v5
%%--------------------------------------------------------------------

t_basic_with_props_v5(_) ->
    t_basic([
        {proto_ver, v5},
        {properties, #{'Receive-Maximum' => 4}}
    ]).

%%--------------------------------------------------------------------
%% General test cases.
%%--------------------------------------------------------------------

t_basic(_Opts) ->
    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{proto_ver, v4}]),
    {ok, _} = emqtt:connect(C),
    {ok, _, [1]} = emqtt:subscribe(C, Topic, qos1),
    {ok, _, [2]} = emqtt:subscribe(C, Topic, qos2),
    {ok, _} = emqtt:publish(C, Topic, <<"qos 2">>, 2),
    {ok, _} = emqtt:publish(C, Topic, <<"qos 2">>, 2),
    {ok, _} = emqtt:publish(C, Topic, <<"qos 2">>, 2),
    ?assertEqual(3, length(recv_msgs(3))),
    ok = emqtt:disconnect(C).

t_username_as_clientid(_) ->
    emqx_config:put_zone_conf(default, [mqtt, use_username_as_clientid], true),
    Username = <<"usera">>,
    {ok, C} = emqtt:start_link([{username, Username}]),
    {ok, _} = emqtt:connect(C),
    #{clientinfo := #{clientid := Username}} = emqx_cm:get_chan_info(Username),
    erlang:process_flag(trap_exit, true),
    {ok, C1} = emqtt:start_link([{username, <<>>}]),
    ?assertEqual({error, {client_identifier_not_valid, undefined}}, emqtt:connect(C1)),
    receive
        {'EXIT', _, {shutdown, client_identifier_not_valid}} -> ok
    after 100 ->
        throw({error, "expect_client_identifier_not_valid"})
    end,
    emqtt:disconnect(C).

t_certcn_as_clientid_default_config_tls(_) ->
    tls_certcn_as_clientid(default).

t_certcn_as_clientid_tlsv1_3(_) ->
    tls_certcn_as_clientid('tlsv1.3').

t_certcn_as_clientid_tlsv1_2(_) ->
    tls_certcn_as_clientid('tlsv1.2').

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

recv_msgs(Count) ->
    recv_msgs(Count, []).

recv_msgs(0, Msgs) ->
    Msgs;
recv_msgs(Count, Msgs) ->
    receive
        {publish, Msg} ->
            recv_msgs(Count - 1, [Msg | Msgs]);
        %%TODO:: remove the branch?
        _Other ->
            recv_msgs(Count, Msgs)
    after 100 ->
        Msgs
    end.

confirm_tls_version(Client, RequiredProtocol) ->
    Info = emqtt:info(Client),
    SocketInfo = proplists:get_value(socket, Info),
    %% emqtt_sock has #ssl_socket.ssl
    SSLSocket = element(3, SocketInfo),
    {ok, SSLInfo} = ssl:connection_information(SSLSocket),
    Protocol = proplists:get_value(protocol, SSLInfo),
    RequiredProtocol = Protocol.

tls_certcn_as_clientid(default = TLSVsn) ->
    tls_certcn_as_clientid(TLSVsn, 'tlsv1.3');
tls_certcn_as_clientid(TLSVsn) ->
    tls_certcn_as_clientid(TLSVsn, TLSVsn).

tls_certcn_as_clientid(TLSVsn, RequiredTLSVsn) ->
    CN = <<"Client">>,
    emqx_config:put_zone_conf(default, [mqtt, peer_cert_as_clientid], cn),
    SslConf = emqx_common_test_helpers:client_ssl_twoway(TLSVsn),
    {ok, Client} = emqtt:start_link([{port, 8883}, {ssl, true}, {ssl_opts, SslConf}]),
    {ok, _} = emqtt:connect(Client),
    #{clientinfo := #{clientid := CN}} = emqx_cm:get_chan_info(CN),
    confirm_tls_version(Client, RequiredTLSVsn),
    %% verify that the peercert won't be stored in the conninfo
    [ChannPid] = emqx_cm:lookup_channels(CN),
    SysState = sys:get_state(ChannPid),
    ChannelRecord = lists:keyfind(channel, 1, tuple_to_list(SysState)),
    ConnInfo = lists:nth(2, tuple_to_list(ChannelRecord)),
    ?assertMatch(#{peercert := undefined}, ConnInfo),
    emqtt:disconnect(Client).
