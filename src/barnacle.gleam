import barnacle/internal/local_epmd
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

pub opaque type Barnacle(error) {
  Barnacle(
    discover_nodes: fn() -> Result(List(atom.Atom), error),
    poll_interval: Int,
  )
}

fn default_barnacle() -> Barnacle(a) {
  Barnacle(discover_nodes: fn() { Ok([]) }, poll_interval: 5000)
}

pub fn local_epmd() -> Barnacle(Nil) {
  Barnacle(..default_barnacle(), discover_nodes: local_epmd.discover_nodes)
}

pub fn with_poll_interval(
  barnacle: Barnacle(error),
  poll_interval: Int,
) -> Barnacle(error) {
  Barnacle(..barnacle, poll_interval: poll_interval)
}

fn spec(
  barnacle: Barnacle(error),
  parent: Option(Subject(Subject(Message(error)))),
) {
  actor.Spec(init_timeout: 10_000, loop: handle_message, init: fn() {
    case refresh_nodes(barnacle) {
      Ok(_) -> {
        let self = process.new_subject()
        let selector =
          process.new_selector()
          |> process.selecting(self, function.identity)

        option.map(parent, process.send(_, self))

        let timer =
          process.send_after(self, barnacle.poll_interval, Refresh(None))
        actor.Ready(
          selector: selector,
          state: State(self:, barnacle:, timer: Some(timer)),
        )
      }
      Error(err) ->
        actor.Failed(case err {
          ConnectError(_) -> "Failed to connect to nodes"
          DisconnectError(_) -> "Failed to disconnect from nodes"
          StrategyError(err) ->
            "Failed to discover nodes: " <> string.inspect(err)
        })
    }
  })
}

pub fn start(
  barnacle: Barnacle(error),
  parent: Option(Subject(Subject(Message(error)))),
) {
  barnacle
  |> spec(parent)
  |> actor.start_spec
}

pub fn child_spec(
  barnacle: Barnacle(error),
  parent: Option(Subject(Subject(Message(error)))),
) {
  supervisor.worker(fn(_) { start(barnacle, parent) })
}

pub fn main() {
  let self = process.new_subject()
  let assert Ok(child) =
    local_epmd()
    |> start(None)

  process.send(child, Refresh(Some(self)))

  let assert Ok(msg) = process.receive(self, 10_000)

  process.sleep_forever()
}

pub type RefreshResult(error) =
  Result(List(atom.Atom), RefreshError(error))

pub opaque type Message(error) {
  Refresh(return: Option(Subject(RefreshResult(error))))
  Stop(return: Option(Subject(Nil)))
  Shutdown(return: Option(Subject(Nil)))
}

type State(error) {
  State(
    self: Subject(Message(error)),
    barnacle: Barnacle(error),
    timer: Option(process.Timer),
  )
}

pub type NodeDisconnectError {
  FailedToDisconnect
  LocalNodeIsNotAlive
}

@external(erlang, "barnacle_ffi", "disconnect_from_node")
fn disconnect_node(node: atom.Atom) -> Result(node.Node, NodeDisconnectError)

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
      send_response(return, refresh_result)

      let timer =
        process.send_after(self, barnacle.poll_interval, Refresh(None))
      actor.continue(State(..state, timer: Some(timer)))
    }
    Stop(return) -> {
      option.map(timer, process.cancel_timer)
      send_response(return, Nil)
      actor.continue(State(..state, timer: None))
    }
    Shutdown(return) -> {
      option.map(timer, process.cancel_timer)
      send_response(return, Nil)
      actor.Stop(process.Normal)
    }
  }
}

fn send_response(maybe_client: Option(Subject(a)), response: a) -> Nil {
  case maybe_client {
    Some(client) -> process.send(client, response)
    None -> Nil
  }
}

fn refresh_nodes(barnacle: Barnacle(error)) -> RefreshResult(error) {
  use available_nodes <- result.try(
    barnacle.discover_nodes()
    |> result.map(fn(nodes) {
      set.from_list(nodes)
      |> set.delete(node.self() |> node.to_atom)
    })
    |> result.map_error(StrategyError),
  )

  let current_nodes =
    node.visible()
    |> list.map(node.to_atom)
    |> set.from_list

  let nodes_to_add = set.difference(available_nodes, current_nodes)
  let nodes_to_remove = set.difference(current_nodes, available_nodes)

  let connect_results =
    nodes_to_add
    |> set.to_list
    |> list.map(fn(node) {
      case node.connect(node) {
        Ok(_) -> Ok(Nil)
        Error(err) -> Error(#(node, err))
      }
    })
    |> result_apply

  use _ <- result.try(connect_results |> result.map_error(ConnectError))

  let disconnect_results =
    nodes_to_remove
    |> set.to_list
    |> list.map(fn(node) {
      case disconnect_node(node) {
        Ok(_) -> Ok(Nil)
        Error(err) -> Error(#(node, err))
      }
    })
    |> result_apply

  use _ <- result.try(disconnect_results |> result.map_error(DisconnectError))

  Ok(node.visible() |> list.map(node.to_atom))
}

fn result_apply(results: List(Result(a, b))) -> Result(List(a), List(b)) {
  results
  |> list.fold(Ok([]), fn(acc, result) {
    case result {
      Ok(val) -> {
        case acc {
          Ok(vals) -> Ok([val, ..vals])
          Error(_) -> acc
        }
      }
      Error(err) -> {
        case acc {
          Ok(_) -> Error([err])
          Error(errs) -> Error([err, ..errs])
        }
      }
    }
  })
}