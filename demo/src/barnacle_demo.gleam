//// TODO: Make this a good example of Gleam code
//// This is _very_ naive. Please don't use as inspiration :)
//// It just listens for events from the barnacle, and prints them to stdout.

import argv
import barnacle
import barnacle_demo/node_list
import envoy
import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/element.{element}
import lustre/element/html.{html}
import lustre/server_component
import mist.{
  type Connection, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}
import pprint
import youid/uuid

const barnacle_poll_interval = 15_000

const listener_poll_interval = 1000

const default_port = 8080

pub fn main() {
  // Parse the port to run on from arguments
  let port = case argv.load().arguments {
    [port, ..] -> {
      case int.parse(port) {
        Ok(port) -> port
        Error(_) -> default_port
      }
    }
    _ -> default_port
  }

  // Get the basename of the current node
  let assert Ok(basename) = barnacle.get_node_basename(node.self())
  let listener = process.new_subject()

  // Get the Fly app name from the environment
  let assert Ok(app_name) = envoy.get("FLY_APP_NAME")

  let barnacle =
    // Use internal DNS to connect to the nodes
    barnacle.dns(basename, app_name <> ".internal", None)
    |> barnacle.with_listener(listener)
    |> barnacle.with_poll_interval(barnacle_poll_interval)

  let assert Ok(barnacle_subject) = barnacle.start(barnacle)

  let assert Ok(node_list) =
    lustre.start_server_component(node_list.component(), barnacle_subject.data)

  let assert Ok(_) = run_server(port, node_list)
  listen_and_publish(listener, node_list)
}

// ----- Server component updater ----- //

type NodeList =
  lustre.Runtime(node_list.Msg)

fn listen_and_publish(
  listener: Subject(barnacle.BarnacleResponse(a)),
  node_list: lustre.Runtime(_),
) {
  case process.receive(listener, listener_poll_interval) {
    Ok(barnacle.RefreshResponse(Ok(nodes))) -> {
      io.println("Connected to nodes:\n" <> pprint.format(nodes))
    }
    Ok(barnacle.RefreshResponse(Error(err))) -> {
      io.println("Error refreshing nodes:\n" <> pprint.format(err))
    }
    // We don't really care about anything else for this demo
    _ -> Nil
  }

  lustre.send(
    node_list,
    lustre.dispatch(node_list.UpdateNodes(
      [node.self(), ..node.visible()]
      |> fn(nodes) {
        nodes |> string.inspect |> io.println
        nodes
      }
      |> list.map(fn(node) { node |> node.name |> atom.to_string })
      |> list.sort(string.compare),
    )),
  )

  listen_and_publish(listener, node_list)
}

// ----- Mist server ----- //

fn run_server(port: Int, node_list: lustre.Runtime(_)) {
  fn(req: Request(Connection)) -> Response(ResponseData) {
    case request.path_segments(req) {
      ["node_list"] ->
        mist.websocket(
          request: req,
          on_init: socket_init(_, node_list),
          on_close: socket_close,
          handler: socket_update,
        )

      ["lustre-server-component.mjs"] -> {
        let assert Ok(priv) = application.priv_directory("lustre")
        let path = priv <> "/static/lustre-server-component.mjs"

        mist.send_file(path, offset: 0, limit: None)
        |> result.map(fn(script) {
          response.new(200)
          |> response.prepend_header("content-type", "application/javascript")
          |> response.set_body(script)
        })
        |> result.lazy_unwrap(fn() {
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
        })
      }

      _ ->
        response.new(200)
        |> response.prepend_header("content-type", "text/html")
        |> response.set_body(
          html([], [
            html.head([], [
              html.script(
                [
                  attribute.type_("module"),
                  attribute.src("/lustre-server-component.mjs"),
                ],
                "",
              ),
            ]),
            html.body([], [
              html.h1([], [html.text("Connected Nodes")]),
              element(
                "lustre-server-component",
                [server_component.route("/node_list")],
                [],
              ),
            ]),
          ])
          |> element.to_document_string()
          |> bytes_tree.from_string()
          |> mist.Bytes,
        )
    }
  }
  |> mist.new
  |> mist.bind("0.0.0.0")
  |> mist.port(port)
  |> mist.start()
}

type State {
  State(id: String, component: NodeList)
}

fn socket_init(
  _conn: WebsocketConnection,
  runtime: lustre.Runtime(_),
) -> #(State, Option(Selector(server_component.ClientMessage(node_list.Msg)))) {
  let self = process.new_subject()
  let id = uuid.v4() |> uuid.to_string

  let selector =
    process.new_selector()
    |> process.select(self)

  server_component.register_subject(self)
  |> lustre.send(to: runtime)

  #(State(id, runtime), Some(selector))
}

fn socket_update(
  state: State,
  msg: WebsocketMessage(server_component.ClientMessage(node_list.Msg)),
  conn: WebsocketConnection,
) -> mist.Next(State, server_component.ClientMessage(node_list.Msg)) {
  case msg {
    mist.Text(json) -> {
      let action = json.parse(json, server_component.runtime_message_decoder())

      case action {
        Ok(action) -> lustre.send(state.component, action)
        Error(_) -> Nil
      }

      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)
    mist.Custom(client_message) -> {
      let json = server_component.client_message_to_json(client_message)

      let assert Ok(_) = mist.send_text_frame(conn, json.to_string(json))

      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn socket_close(state: State) -> Nil {
  lustre.shutdown()
  |> lustre.send(to: state.component)
}
