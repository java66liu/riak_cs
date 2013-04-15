%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
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
%% ---------------------------------------------------------------------

%% TODO:
%% 1. maybe `objects' should be called `manifests'

-module(riak_cs_list_objects_fsm_v2).

-behaviour(gen_fsm).

-include("riak_cs.hrl").
-include("list_objects.hrl").

-compile(export_all).

%%%===================================================================
%%% Exports
%%%===================================================================

%% API
-export([list_objects/2]).
%% API
-export([start_link/2,
         get_object_list/1,
         get_internal_state/1]).

%% Observability
-export([]).

%% gen_fsm callbacks
-export([init/1,
         prepare/2,
         waiting_object_list/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

%%%===================================================================
%%% Records and Types
%%%===================================================================

-record(state, {riakc_pid :: pid(),
                req :: list_object_request(),
                reply_ref :: undefined | {pid(), any()},
                key_multiplier :: float(),
                object_list_req_id :: undefined | non_neg_integer(),
                reached_end_of_keyspace=false :: boolean(),
                object_buffer=[] :: list(),
                objects :: list(),
                last_request_start_key :: undefined | binary(),
                object_list_ranges=[] :: object_list_ranges(),
                response :: undefined |
                            {ok, list_object_response()} |
                            {error, term()},
                common_prefixes=ordsets:new() :: list_objects_common_prefixes()}).

%% some useful shared types

-type state() :: #state{}.

-type fsm_state_return() :: {next_state, atom(), state()} |
                            {next_state, atom(), state(), non_neg_integer()} |
                            {stop, term(), state()}.

-type list_objects_event() :: {ReqID :: non_neg_integer(), done} |
                              {ReqID :: non_neg_integer(), {objects, list()}} |
                              {ReqID :: non_neg_integer(), {error, term()}}.

-type manifests_and_prefixes() :: {list(lfs_manifest()), ordsets:ordset(binary())}.

%% `Start' and `End' are inclusive
-type object_list_range()  :: {Start :: binary(), End :: binary()}.
-type object_list_ranges() :: [object_list_range()].

%%-type tagged_item() :: {prefix, binary()} |
%%                       {manifest, {binary(), lfs_manifest()}}.

%%-type tagged_item_list() :: list(tagged_item()).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(pid(), list_object_request()) ->
    {ok, pid()} | {error, term()}.
start_link(RiakcPid, ListKeysRequest) ->
    gen_fsm:start_link(?MODULE, [RiakcPid, ListKeysRequest], []).

-spec get_object_list(pid()) ->
    {ok, list_object_response()} |
    {error, term()}.
get_object_list(FSMPid) ->
    gen_fsm:sync_send_all_state_event(FSMPid, get_object_list, infinity).

get_internal_state(FSMPid) ->
    gen_fsm:sync_send_all_state_event(FSMPid, get_internal_state, infinity).

%%%===================================================================
%%% Observability
%%%===================================================================

-spec get_key_list_multiplier() -> float().
get_key_list_multiplier() ->
    riak_cs_utils:get_env(riak_cs, key_list_multiplier,
                          ?KEY_LIST_MULTIPLIER).

-spec set_key_list_multiplier(float()) -> 'ok'.
set_key_list_multiplier(Multiplier) ->
    application:set_env(riak_cs, key_list_multiplier,
                        Multiplier).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

-spec init(list()) -> {ok, prepare, state(), 0}.
init([RiakcPid, Request]) ->
    %% TODO: this should not be hardcoded. Maybe there should
    %% be two `start_link' arities, and one will use a default
    %% val from app.config and the other will explicitly
    %% take a val
    KeyMultiplier = get_key_list_multiplier(),

    State = #state{riakc_pid=RiakcPid,
                   key_multiplier=KeyMultiplier,
                   req=Request},
    {ok, prepare, State, 0}.

-spec prepare(timeout, state()) -> fsm_state_return().
prepare(timeout, State=#state{riakc_pid=RiakcPid}) ->
    case make_2i_request(RiakcPid, State) of
        {NewStateData, {ok, ReqId}} ->
            {next_state, waiting_object_list,
             NewStateData#state{object_list_req_id=ReqId}};
        {NewStateData, {error, _Reason}}=Error ->
            try_reply(Error, NewStateData)
    end.

-spec waiting_object_list(list_objects_event(), state()) -> fsm_state_return().
waiting_object_list({ReqId, {objects, ObjectList}},
                    State=#state{object_list_req_id=ReqId,
                                 object_buffer=ObjectBuffer}) ->
    NewStateData = State#state{object_buffer=ObjectBuffer ++ ObjectList},
    {next_state, waiting_object_list, NewStateData};
waiting_object_list({ReqId, done}, State=#state{object_list_req_id=ReqId}) ->
    handle_done(State);
waiting_object_list({ReqId, {error, _Reason}=Error},
                    State=#state{object_list_req_id=ReqId}) ->
    try_reply(Error, State).

handle_event(_Event, StateName, State) ->
    %% TODO: log unknown event
    {next_state, StateName, State}.

handle_sync_event(get_object_list, From, StateName, State=#state{response=undefined}) ->
    NewStateData = State#state{reply_ref=From},
    {next_state, StateName, NewStateData};
handle_sync_event(get_object_list, _From, _StateName, State=#state{response=Resp}) ->
    {stop, normal, Resp, State};
handle_sync_event(get_internal_state, _From, StateName, State) ->
    Reply = {StateName, State},
    {reply, Reply, StateName, State};
handle_sync_event(Event, _From, StateName, State) ->
    _ = lager:debug("got unknown event ~p in state ~p", [Event, StateName]),
    Reply = ok,
    {reply, Reply, StateName, State}.

%% the responses from `riakc_pb_socket:get_index_range'
%% come back as regular messages, so just pass
%% them along as if they were gen_server events.
handle_info(Info, waiting_object_list, State) ->
    waiting_object_list(Info, State);
handle_info(Info, StateName, _State) ->
    _ = lager:debug("Received unknown info message ~p"
                    "in state ~p", [Info, StateName]),
    ok.

terminate(_Reason, _StateName, State) ->
    _ = lager:info("terminating state is ~p", [State#state.object_list_ranges]),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%====================================================================
%%% Internal helpers
%%%====================================================================

handle_done(State=#state{object_buffer=ObjectBuffer,
                         req=?LOREQ{max_keys=MaxKeys}=Request}) ->
    RangeUpdatedStateData = update_last_request_state(State, ObjectBuffer),
    FilteredObjects = exclude_key_from_state(State, ObjectBuffer),
    Manifests = [riak_cs_utils:manifests_from_riak_object(O) ||
                 O <- FilteredObjects],
    ReachedEnd = length(ObjectBuffer) < MaxKeys,
    NewStateData = RangeUpdatedStateData#state{objects=Manifests,
                                               reached_end_of_keyspace=ReachedEnd,
                                               object_buffer=[]},
    case enough_results(NewStateData) of
        true ->
            Response = response_from_manifests(Request, Manifests),
            try_reply({ok, Response}, NewStateData);
        false ->
            %% TODO: fill this in
            ok
    end.

enough_results(#state{req=?LOREQ{max_keys=MaxKeys},
                      reached_end_of_keyspace=EndofKeyspace,
                      objects=Objects,
                      common_prefixes=CommonPrefixes}) ->
    manifests_and_prefix_length({Objects, CommonPrefixes}) >= MaxKeys
    orelse EndofKeyspace.

response_from_manifests(Request, Manifests) ->
    Active = map_active_manifests(Manifests),
    KeyContent = lists:map(fun riak_cs_list_objects:manifest_to_keycontent/1,
                           Active),
    case KeyContent of
        [] ->
            riak_cs_list_objects:new_response(Request, false, [], []);
        _Else ->
            riak_cs_list_objects:new_response(Request, true, [], KeyContent)
    end.

-spec list_objects(pid(), list_object_request()) -> list_object_response().
list_objects(RiakcPid, Request) ->
    RiakObjects = make_2i_request(RiakcPid, Request),
    Manifests = [riak_cs_utils:manifests_from_riak_object(O) ||
                 O <- RiakObjects],
    Active = map_active_manifests(Manifests),
    Filtered = exclude_marker(Request, Active),
    KeyContent = lists:map(fun riak_cs_list_objects:manifest_to_keycontent/1,
                           Filtered),
    case KeyContent of
        [] ->
            riak_cs_list_objects:new_response(Request, false, [], []);
        _Else ->
            riak_cs_list_objects:new_response(Request, true, [], KeyContent)
    end.

-spec make_2i_request(pid(), state()) -> [riakc_obj:riakc_obj()].
make_2i_request(RiakcPid, State=#state{req=?LOREQ{name=BucketName,
                                                          max_keys=MaxKeys}}) ->
    ManifestBucket = riak_cs_utils:to_bucket_name(objects, BucketName),
    StartKey = make_start_key(State),
    EndKey = big_end_key(128),
    Opts = [{return_terms, true}, {max_results, MaxKeys + 1}, {stream, true}],
    NewStateData = State#state{last_request_start_key=StartKey},
    Ref = riakc_pb_socket:get_index_range(RiakcPid,
                                          ManifestBucket,
                                          <<"$key">>,
                                          StartKey,
                                          EndKey,
                                          Opts),
    {NewStateData, Ref}.

-spec receive_objects(term()) -> list().
receive_objects(ReqID) ->
    receive_objects(ReqID, []).

receive_objects(ReqId, Acc) ->
    receive
        {ReqId, {objects, List}} ->
            receive_objects(ReqId, Acc ++ List);
        {ReqId, done} ->
            Acc;
        {ReqId, {error, Reason}} ->
            _ = lager:error("yikes, error ~p", [Reason]),
            throw({list_objects_error, Reason});
        Else ->
            throw({unknown_message, Else})
    end.

-spec make_start_key(state()) -> binary().
make_start_key(#state{object_list_ranges=[], req=Request}) ->
    make_start_key_from_marker(Request);
make_start_key(#state{object_list_ranges=PrevRanges}) ->
    element(2, lists:last(PrevRanges)).

-spec make_start_key_from_marker(list_object_request()) -> binary().
make_start_key_from_marker(?LOREQ{marker=undefined}) ->
    <<0:8/integer>>;
make_start_key_from_marker(?LOREQ{marker=Marker}) ->
    Marker.

big_end_key(NumBytes) ->
    MaxByte = <<255:8/integer>>,
    iolist_to_binary([MaxByte || _ <- lists:seq(1, NumBytes)]).

-spec map_active_manifests([orddict:orddict()]) -> list(lfs_manifest()).
map_active_manifests(Manifests) ->
    ActiveTuples = [riak_cs_manifest_utils:active_manifest(M) ||
                    M <- Manifests],
    [A || {ok, A} <- ActiveTuples].

-spec exclude_key_from_state(state(), list(riakc_obj:riakc_obj())) ->
    list(riakc_obj:riakc_obj()).
exclude_key_from_state(_State, []) ->
    [];
exclude_key_from_state(#state{object_list_ranges=[],
                              req=Request}, Objects) ->
    exclude_marker(Request, Objects);
exclude_key_from_state(#state{last_request_start_key=StartKey}, Objects) ->
    exclude_key(StartKey, Objects).

-spec exclude_marker(list_object_request(), list()) -> list().
exclude_marker(?LOREQ{marker=undefined}, Objects) ->
    Objects;
exclude_marker(?LOREQ{marker=Marker}, Objects) ->
    exclude_key(Marker, Objects).

-spec exclude_key(binary(), list(riakc_obj:riakc_obj())) ->
    list(riakc_obj:riakc_obj()).
exclude_key(Key, [H | T]=Objects) ->
    case riakc_obj:key(H) == Key of
        true ->
            T;
        false ->
            Objects
    end.

-spec skip_past_prefix_and_delimiter(binary()) -> binary().
skip_past_prefix_and_delimiter(<<>>) ->
    <<0:8/integer>>;
skip_past_prefix_and_delimiter(Key) ->
    PrefixSize = byte_size(Key) - 1,
    <<Prefix:PrefixSize/binary, LastByte/binary>> = Key,
    NextByte = next_byte(LastByte),
    <<Prefix/binary, NextByte/binary>>.

-spec next_byte(binary()) -> binary().
next_byte(<<Integer:8/integer>>=Byte) when Integer == 255 ->
    Byte;
next_byte(<<Integer:8/integer>>) ->
    <<(Integer+1):8/integer>>.

%% TODO: this was c/p from other module
%% well, not quite anymore
-spec manifests_and_prefix_length(manifests_and_prefixes()) -> non_neg_integer().
manifests_and_prefix_length({Manifests, Prefixes}) ->
    length(Manifests) + ordsets:size(Prefixes).

-spec try_reply(Response :: {ok, list_object_response()} | {error, term()},
                State :: state()) ->
    fsm_state_return().
try_reply(Response, State) ->
    NewStateData = State#state{response=Response},
    reply_or_wait(Response, NewStateData).

reply_or_wait(_Response, State=#state{reply_ref=undefined}) ->
    {next_state, waiting_req, State};
reply_or_wait(Response, State=#state{reply_ref=Ref}) ->
    gen_fsm:reply(Ref, Response),
    Reason = make_reason(Response),
    {stop, Reason, State}.

make_reason({ok, _Response}) ->
    normal;
make_reason({error, Reason}) ->
    Reason.

update_last_request_state(State=#state{last_request_start_key=StartKey,
                                       object_list_ranges=PrevRanges},
                          []) ->
    NewRange = {StartKey, StartKey},
    State#state{object_list_ranges=PrevRanges ++ [NewRange]};
update_last_request_state(State=#state{last_request_start_key=StartKey,
                                       object_list_ranges=PrevRanges},
                          RiakObjects) ->
    LastObject = lists:last(RiakObjects),
    LastKey = riakc_obj:key(LastObject),
    NewRange = {StartKey, LastKey},
    State#state{object_list_ranges=PrevRanges ++ [NewRange]}.
