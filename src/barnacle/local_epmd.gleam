import gleam/erlang/atom
import gleam/erlang/node
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "barnacle_ffi", "list_local_nodes")
fn list_local_nodes() -> Result(List(String), Nil)

fn get_hostname() -> String {
  let host =
    node.self()
    |> node.to_atom
    |> atom.to_string

  let assert [_, hostname] = string.split(host, "@")
  hostname
}

/// Discover nodes using the local EPMD. This will discover nodes on the same
/// hostname as the current node.
pub fn discover_nodes() -> Result(List(atom.Atom), Nil) {
  let hostname = get_hostname()
  list_local_nodes()
  |> result.map(list.map(_, fn(n) {
    { n <> "@" <> hostname } |> atom.create_from_string
  }))
}
