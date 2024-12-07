-module(barnacle_ffi).

-export([list_local_nodes/0, disconnect_from_node/1, lookup_a/2, lookup_aaaa/2]).

-include_lib("kernel/include/inet.hrl").

disconnect_from_node(Node) ->
  case disconnect_node(Node) of
    true ->
      {ok, Node};
    false ->
      {error, failed_to_disconnect};
    ignored ->
      {error, local_node_is_not_alive}
  end.

%% Local epmd functions

list_local_nodes() ->
  case erl_epmd:names() of
    {error, address} ->
      {error, nil};
    {ok, Names} ->
      {ok, [list_to_binary(Name) || {Name, _} <- Names]}
  end.

%% DNS functions

lookup_a(Name, Timeout) when is_binary(Name) ->
  lookup(Name, a, Timeout).

lookup_aaaa(Name, Timeout) when is_binary(Name) ->
  lookup(Name, aaaa, Timeout).

%% Erlang's internal DNS function throw with some inputs like
%% "ssssrtrssssssssstrtrtrtrdededuddmdidudmdidudmdidudmdidudmddfwddf.com"
%% so we just catch the error and return an unknown error. I'm not sure
%% what causes these.
lookup(Name, Type, Timeout) when is_binary(Name) ->
  try lookup_throws(Name, Type, Timeout) of
    Result ->
      Result
  catch
    _:_ ->
      {error, unknown}
  end.

lookup_throws(Name, Type, Timeout) when is_binary(Name) ->
  io:format("Name: ~p~n", [Name]),
  case inet_res:getbyname(binary_to_list(Name), Type, Timeout) of
    {ok, #hostent{h_addr_list = Addrs}} ->
      {ok, Addrs};
    {error, formerr} ->
      {error, format_error};
    {error, qfmterror} ->
      {error, query_format_error};
    {error, servfail} ->
      {error, server_failure};
    {error, nxdomain} ->
      {error, no_such_domain};
    {error, timeout} ->
      {error, timeout};
    {error, notimp} ->
      {error, not_implemented};
    {error, refused} ->
      {error, refused};
    {error, badvers} ->
      {error, bad_version};
    {error, PosixError} when is_atom(PosixError) ->
      {error, {posix_error, atom_to_binary(PosixError, utf8)}};
    _ ->
      {error, unknown}
  end.
