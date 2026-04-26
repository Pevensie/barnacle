import barnacle
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
import lustre/event

pub fn component() {
  lustre.component(init, update, view, [])
}

pub opaque type Model(a) {
  Model(barnacle_subject: Subject(barnacle.Message(a)), nodes: List(String))
}

fn init(barnacle_subject: Subject(barnacle.Message(a))) {
  #(
    Model(barnacle_subject, [node.self() |> node.name |> atom.to_string]),
    effect.none(),
  )
}

pub type Msg {
  UpdateNodes(List(String))
  DisconnectCurrentNode
}

@external(erlang, "barnacle_demo_ffi", "disconnect_from_node")
fn disconnect_node(node: atom.Atom) -> Result(node.Node, Nil)

fn update(model: Model(a), msg: Msg) -> #(Model(a), effect.Effect(Msg)) {
  case msg {
    UpdateNodes(nodes) -> #(
      Model(..model, nodes: nodes |> list.sort(string.compare)),
      effect.none(),
    )
    DisconnectCurrentNode -> {
      let self = node.self() |> node.name |> atom.to_string
      list.each(model.nodes, fn(node) {
        case node == self {
          True -> Nil
          False -> {
            let _ = disconnect_node(node |> atom.create)
            Nil
          }
        }
      })

      #(Model(..model, nodes: [self]), effect.none())
    }
  }
}

fn view(model: Model(a)) -> element.Element(Msg) {
  html.div([attribute.styles([#("max-width", "100ch")])], [
    html.ul(
      [],
      list.map(model.nodes, fn(node) { html.li([], [html.text(node)]) }),
    ),
    html.p([], [
      html.text(
        "Open the site in a couple of browsers, check you're connected to different nodes, then click the button to disconnect the current node.",
      ),
    ]),
    html.p([], [
      html.text("Current node: "),
      html.span([attribute.styles([#("font-weight", "bold")])], [
        html.text(node.self() |> node.name |> atom.to_string),
      ]),
    ]),
    html.button(
      [
        event.on_click(DisconnectCurrentNode),
        ..case list.length(model.nodes) > 1 {
          True -> []
          False -> [attribute.disabled(True)]
        }
      ],
      [html.text("Disconnect current node")],
    ),
  ])
}
