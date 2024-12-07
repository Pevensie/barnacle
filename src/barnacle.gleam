import barnacle/dns
import barnacle/local_epmd
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/result
import gleam/set
import gleam/string

// ----- Setup functions ----- //

/// The entrypoint for creating a barnacle. Generic over the error returned by
/// strategy-specific functions.
pub opaque type Barnacle(error) {
  Barnacle(
    name: Option(atom.Atom),
    strategy: Strategy(error),
    poll_interval: Int,
    listener: Option(Subject(BarnacleResponse(error))),
  )
}

fn default_barnacle() -> Barnacle(error) {
  Barnacle(
    name: None,
    strategy: default_strategy(),
    poll_interval: 5000,
    listener: None,
  )
}

/// Give the barnacle actor process a custom name.
pub fn with_name(barnacle: Barnacle(error), name: String) -> Barnacle(error) {
  Barnacle(..barnacle, name: Some(name |> atom.create_from_string))
}

/// Set the poll interval for the barnacle actor. Defaults to 5000ms.
pub fn with_poll_interval(
  barnacle: Barnacle(error),
  poll_interval: Int,
) -> Barnacle(error) {
  Barnacle(..barnacle, poll_interval: poll_interval)
}

/// Set the listener subject for your barnacle. This will be notified whenever
/// the barnacle refreshes, is paused, or is shutdown.
pub fn with_listener(
  barnacle: Barnacle(error),
  listener: Subject(BarnacleResponse(error)),
) -> Barnacle(error) {
  Barnacle(..barnacle, listener: Some(listener))
}

// ----- Strategies ----- //

/// A custom strategy for discovering and connecting to nodes.
pub opaque type Strategy(error) {
  Strategy(
    discover_nodes: fn() -> Result(List(atom.Atom), error),
    connect_nodes: fn(List(atom.Atom)) ->
      Result(List(atom.Atom), List(#(atom.Atom, node.ConnectError))),
    disconnect_nodes: fn(List(atom.Atom)) ->
      Result(List(atom.Atom), List(#(atom.Atom, NodeDisconnectError))),
    list_nodes: fn() -> Result(List(atom.Atom), error),
  )
}

/// An error that can occur when disconnecting from a node.
pub type NodeDisconnectError {
  FailedToDisconnect
  LocalNodeIsNotAlive
}

fn default_strategy() -> Strategy(error) {
  Strategy(
    discover_nodes: fn() { Ok([]) },
    connect_nodes:,
    disconnect_nodes:,
    list_nodes:,
  )
}

/// Create a new custom strategy with a single function to discover nodes.
pub fn new_strategy(
  discover_nodes: fn() -> Result(List(atom.Atom), error),
) -> Strategy(error) {
  Strategy(..default_strategy(), discover_nodes:)
}

/// Add a custom node connection function to your strategy.
/// Useful if you want to use an alternative to Distributed Erlang, such as
/// [Partisan](https://github.com/lasp-lang/partisan).
pub fn with_connect_nodes_function(
  strategy: Strategy(error),
  connect_nodes: fn(List(atom.Atom)) ->
    Result(List(atom.Atom), List(#(atom.Atom, node.ConnectError))),
) -> Strategy(error) {
  Strategy(..strategy, connect_nodes:)
}

/// Add a custom node disconnection function to your strategy.
/// Useful if you want to use an alternative to Distributed Erlang, such as
/// [Partisan](https://github.com/lasp-lang/partisan).
pub fn with_disconnect_nodes_function(
  strategy: Strategy(error),
  disconnect_nodes: fn(List(atom.Atom)) ->
    Result(List(atom.Atom), List(#(atom.Atom, NodeDisconnectError))),
) -> Strategy(error) {
  Strategy(..strategy, disconnect_nodes:)
}

/// Add a custom node listing function to your strategy.
/// Useful if you want to use an alternative to Distributed Erlang, such as
/// [Partisan](https://github.com/lasp-lang/partisan).
pub fn with_list_nodes_function(
  strategy: Strategy(error),
  list_nodes: fn() -> Result(List(atom.Atom), error),
) -> Strategy(error) {
  Strategy(..strategy, list_nodes:)
}

// ----- Default Strategy ----- //

@external(erlang, "barnacle_ffi", "disconnect_from_node")
fn disconnect_node(node: atom.Atom) -> Result(node.Node, NodeDisconnectError)

fn list_nodes() -> Result(List(atom.Atom), error) {
  [node.self(), ..node.visible()]
  |> list.map(node.to_atom)
  |> Ok
}

fn connect_nodes(nodes: List(atom.Atom)) {
  nodes
  |> list.map(fn(node) {
    case node.connect(node) {
      Ok(_) -> Ok(node)
      Error(err) -> Error(#(node, err))
    }
  })
  |> result_apply
}

fn disconnect_nodes(nodes: List(atom.Atom)) {
  nodes
  |> list.map(fn(node) {
    case disconnect_node(node) {
      Ok(_) -> Ok(node)
      Error(err) -> Error(#(node, err))
    }
  })
  |> result_apply
}

// ----- Built-in Strategies ----- //

/// Create a barnacle with a custom strategy. This requires at least one function
/// to discover nodes.
///
/// You can also supply your own functions for connecting, disconnecting, and
/// listing nodes. If these are not supplied, the default Distributed Erlang
/// functions will be used.
///
/// Barnacles are generic over their error type, known as the strategy error.
/// Your strategy functions may use this to return custom errors.
pub fn custom(strategy: Strategy(error)) -> Barnacle(error) {
  Barnacle(..default_barnacle(), strategy:)
}

/// Create a barnacle that uses the local EPMD to discover nodes. This will discover
/// nodes on the same hostname as the current node.
pub fn local_epmd() -> Barnacle(Nil) {
  Barnacle(
    ..default_barnacle(),
    strategy: Strategy(
      ..default_strategy(),
      discover_nodes: local_epmd.discover_nodes,
    ),
  )
}

/// Create a barnacle that connects to a known list of nodes. These may be
/// remote nodes, or nodes on the same hostname as the current node.
pub fn epmd(nodes: List(atom.Atom)) -> Barnacle(Nil) {
  Barnacle(
    ..default_barnacle(),
    strategy: Strategy(..default_strategy(), discover_nodes: fn() { Ok(nodes) }),
  )
}

/// Create a barnacle that discovers nodes using DNS. The first argument is the
/// basename of the nodes. Currently, Barnacle only supports connecting to nodes
/// with the same basename.
///
/// The second argument is the hostname to query against. Both A and AAAA records
/// will be queried. The final argument is an optional timeout for the DNS
/// lookup. This defaults to 5000ms if not supplied.
pub fn dns(
  basename: String,
  hostname_query: String,
  timeout: Option(Int),
) -> Barnacle(dns.LookupError) {
  Barnacle(
    ..default_barnacle(),
    strategy: Strategy(
      ..default_strategy(),
      discover_nodes: fn() {
        dns.discover_nodes(
          basename,
          hostname_query,
          option.unwrap(timeout, 5000),
        )
      },
    ),
  )
}

// ----- Actor ----- //

/// The result of a barnacle refresh.
pub type RefreshResult(error) =
  Result(List(atom.Atom), RefreshError(error))

/// A message that can be sent to a barnacle actor.
pub opaque type Message(error) {
  Refresh(return: Option(Subject(RefreshResult(error))))
  Pause(return: Option(Subject(Nil)))
  Shutdown(return: Option(Subject(Nil)))
}

/// A response from a barnacle actor. This will be sent to the listener subject.
pub type BarnacleResponse(error) {
  RefreshResponse(RefreshResult(error))
  PauseResponse(Nil)
  ShutdownResponse(Nil)
}

type State(error) {
  State(
    self: Subject(Message(error)),
    barnacle: Barnacle(error),
    timer: Option(process.Timer),
  )
}

/// Start a barnacle actor. This will start the actor, and begin polling for
/// nodes.
pub fn start(barnacle: Barnacle(error)) {
  barnacle
  |> spec(None)
  |> actor.start_spec
}

/// Create a child spec for your barnacle for use in a supervision tree.
pub fn child_spec(
  barnacle: Barnacle(error),
  parent: Subject(Subject(Message(error))),
) {
  supervisor.worker(fn(_) {
    barnacle
    |> spec(Some(parent))
    |> actor.start_spec
  })
}

/// Run the refresh function once only. This will not start the actor, and will
/// not do any polling.
///
/// In this case, most configuration options are irrelevant and will be ignored.
pub fn run_once(barnacle: Barnacle(error)) {
  barnacle
  |> refresh_nodes
}

/// Refresh a barnacle actor. This will attempt to connect to new nodes, and
/// disconnect from nodes that are no longer available.
///
/// This will reset the poll timer.
pub fn refresh(subject: Subject(Message(error)), timeout: Int) {
  actor.call(subject, fn(subj) { Refresh(Some(subj)) }, timeout)
}

/// Pause a barnacle actor. Sending a [`refresh`](#refresh) will restart the actor.
pub fn pause(subject: Subject(Message(error)), timeout: Int) {
  actor.call(subject, fn(subj) { Pause(Some(subj)) }, timeout)
}

/// Shutdown a barnacle actor. This will stop the actor, and stop any future
/// refreshes.
pub fn shutdown(subject: Subject(Message(error)), timeout: Int) {
  actor.call(subject, fn(subj) { Shutdown(Some(subj)) }, timeout)
}

/// The error type for a barnacle refresh.
pub type RefreshError(error) {
  StrategyError(error)
  ConnectError(List(#(atom.Atom, node.ConnectError)))
  DisconnectError(List(#(atom.Atom, NodeDisconnectError)))
}

fn handle_message(message: Message(error), state: State(error)) {
  let State(self:, barnacle:, timer:) = state
  case message {
    Refresh(return) -> {
      let refresh_result = refresh_nodes(barnacle)

      cancel_timer(timer)
      let timer =
        process.send_after(self, barnacle.poll_interval, Refresh(None))

      send_response(return, refresh_result)
      send_response(barnacle.listener, RefreshResponse(refresh_result))
      actor.continue(State(..state, timer: Some(timer)))
    }
    Pause(return) -> {
      cancel_timer(timer)
      send_response(return, Nil)
      send_response(barnacle.listener, PauseResponse(Nil))
      actor.continue(State(..state, timer: None))
    }
    Shutdown(return) -> {
      cancel_timer(timer)
      send_response(return, Nil)
      send_response(barnacle.listener, ShutdownResponse(Nil))
      actor.Stop(process.Normal)
    }
  }
}

fn spec(
  barnacle: Barnacle(error),
  parent: Option(Subject(Subject(Message(error)))),
) {
  actor.Spec(init_timeout: 10_000, loop: handle_message, init: fn() {
    option.map(barnacle.name, process.register(process.self(), _))
    let self = process.new_subject()
    let selector =
      process.new_selector()
      |> process.selecting(self, function.identity)

    option.map(parent, process.send(_, self))

    let timer = process.send_after(self, barnacle.poll_interval, Refresh(None))

    actor.Ready(
      selector: selector,
      state: State(self:, barnacle:, timer: Some(timer)),
    )
  })
}

fn send_response(maybe_client: Option(Subject(a)), response: a) -> Nil {
  option.map(maybe_client, process.send(_, response))
  Nil
}

fn cancel_timer(timer: Option(process.Timer)) -> Nil {
  option.map(timer, process.cancel_timer)
  Nil
}

fn refresh_nodes(barnacle: Barnacle(error)) -> RefreshResult(error) {
  use available_nodes_list <- result.try(
    barnacle.strategy.discover_nodes()
    |> result.map_error(StrategyError),
  )

  use current_nodes_list <- result.try(
    barnacle.strategy.list_nodes()
    |> result.map_error(StrategyError),
  )

  let self = node.self() |> node.to_atom

  let available_nodes =
    available_nodes_list
    |> set.from_list
    |> set.delete(self)

  let current_nodes =
    current_nodes_list
    |> set.from_list
    |> set.delete(self)

  let nodes_to_add = set.difference(available_nodes, current_nodes)
  let nodes_to_remove = set.difference(current_nodes, available_nodes)

  let connect_results =
    barnacle.strategy.connect_nodes(nodes_to_add |> set.to_list)
  use _ <- result.try(connect_results |> result.map_error(ConnectError))

  let disconnect_results =
    barnacle.strategy.disconnect_nodes(nodes_to_remove |> set.to_list)
  use _ <- result.try(disconnect_results |> result.map_error(DisconnectError))

  barnacle.strategy.list_nodes()
  |> result.map_error(StrategyError)
}

// ----- Utils ----- //

fn result_apply(results: List(Result(a, b))) -> Result(List(a), List(b)) {
  case result.partition(results) {
    #(vals, []) -> Ok(vals)
    #(_, errs) -> Error(errs)
  }
}

/// Get the basename of a node.
///
/// Useful for getting the basename of the current node for use with the DNS
/// strategy.
///
/// Example:
/// ```gleam
/// import barnacle
/// import gleam/erlang/node
///
/// pub fn main() {
///   let assert Ok(basename) = barnacle.get_node_basename(node.self())
/// }
/// ```
pub fn get_node_basename(node: node.Node) -> Result(String, Nil) {
  node
  |> node.to_atom
  |> atom.to_string
  |> string.split_once("@")
  |> result.map(fn(tuple) { tuple.0 })
}
