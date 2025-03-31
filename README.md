# Barnacle

[![Package Version](https://img.shields.io/hexpm/v/barnacle)](https://hex.pm/packages/barnacle)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/barnacle/)

Self-healing clusters for Gleam applications on the BEAM!

Connect to other BEAM nodes, and automatically reconnect when they go down.

## Features

- Discover nodes using different strategies. Built-in strategies:
  - Local EPMD
  - Remote EPMD
  - DNS
- Automatically reconnect to nodes when they come back online
- Supply your own strategies
- Listen to events
- Trigger refreshes manually

## Getting Started

```sh
gleam add barnacle
```

You'll also need to start your Gleam process with a node name, and set the cookie.
You can do this using the `ERL_FLAGS` environment variable.

> [!NOTE]
> Check out the Fly.io demo by clicking [here](https://barnacle-demo.fly.dev/) ([source](./demo)).

```sh
ERL_FLAGS="-name my_app@127.0.0.1 -setcookie my_cookie" gleam run
```

### Start Barnacle under a Supervisor (recommended)

```gleam
import barnacle
import gleam/erlang/process
import gleam/otp/supervisor

pub fn main() {
  // Configure your Barnacle
  let barnacle =
    barnacle.local_epmd()
    |> barnacle.with_poll_interval(15_000)
    |> barnacle.with_name("my_barnacle")

  // Create a subject to receive the child process later
  let self = process.new_subject()

  // Start the child process under a supervisor
  let barnacle_worker = barnacle.child_spec(barnacle, self)
  let assert Ok(_) = supervisor.start(supervisor.add(_, barnacle_worker))

  // Get a subject to send messages to the child process
  let assert Ok(barnacle_subject) = process.receive(self, 10_000)

  // Continue your setup...

  process.sleep_forever()
}
```

### Start Barnacle as a standalone actor

This is **not** recommended as your barnacle won't be restarted if it crashes for any
reason.

```gleam
import barnacle
import gleam/erlang/process

pub fn main() {
  // Configure your Barnacle
  let barnacle =
    barnacle.local_epmd()
    |> barnacle.with_poll_interval(15_000)
    |> barnacle.with_name("my_barnacle")

  // Start the actor
  let barnacle_subject = barnacle.start(barnacle)

  // Continue your setup...

  process.sleep_forever()
}
```

### Run the refresh function once

If you don't need any sort of polling, or want to manage your the refresh lifecycle
yourself, you can call the `run_once` function to run the refresh function a single
time.

In this case, most of the configuration options will be ignored.

```gleam
import barnacle

pub fn main() {
  // Configure your Barnacle
  let barnacle =
    barnacle.local_epmd()

  // Run the refresh function once
  barnacle.run_once(barnacle)

  // Continue your program...
}
```

## Strategies

Barnacle ships with a few built-in strategies, but you can also supply your own by
providing a single callback function.

### Local EPMD

Discover nodes using the local EPMD. This will automatically attempt to connect to
nodes that are running on the same machine.

```gleam
import barnacle

pub fn main() {
  barnacle.local_epmd()
  |> barnacle.start
}
```

### Remote EPMD

Connect to nodes using a known list.

```gleam
import barnacle
import gleam/erlang/atom

pub fn main() {
  barnacle.epmd(
    ["node1@192.168.1.1", "node2@192.168.1.2"]
    |> list.map(atom.create_from_string),
  )
  |> barnacle.start
}
```

### DNS

Discover nodes using DNS.

The first argument is the basename of the node. Currently, Barnacle only supports
connecting to nodes with the same basename.

Barnacle provides a helper function to get the basename of the current node.

```gleam
import barnacle
import gleam/option

pub fn main() {
  let assert Ok(basename) = barnacle.get_node_basename(node.self())
  barnacle.dns(
    basename,
    // The hostname to query against
    "my_app.example.com",
    // An optional timeout for the DNS lookup
    option.Some(7500),
  )
  |> barnacle.start
}
```

### Creating a custom strategy

You can create your own strategy using the `new_strategy` function.

```gleam
import barnacle

pub fn main() {
  barnacle.new_strategy(
    // Discover nodes
    fn() {
      Ok([])
    },
  )
  |> barnacle.custom
  |> barnacle.start
}
```

You can also supply your own functions for connecting, disconnecting, and listing nodes.
If these are not supplied, the built-in functions will be used.

This may be useful if you want to use an alternative to Distributed Erlang, such as
[Partisan](https://github.com/lasp-lang/partisan).

```gleam
import barnacle

pub fn main() {
  barnacle.new_strategy(my_discover_function)
  |> barnacle.with_connect_nodes_function(my_connect_function)
  |> barnacle.with_disconnect_nodes_function(my_disconnect_function)
  |> barnacle.with_list_nodes_function(my_list_function)
  |> barnacle.custom
  |> barnacle.start
}
```

You can find more information about creating custom strategies in the
[docs](/barnacle/barnacle.html#custom).

## Events

You can provide a custom subject to receive events from your barnacle.
This will be notified whenever the barnacle refreshes, is paused, or is shutdown.

```gleam
import barnacle
import gleam/erlang/process

pub fn main() {
  let self = process.new_subject()

  // Configure your Barnacle
  let barnacle =
    barnacle.local_epmd()
      |> barnacle.with_poll_interval(15_000)
      |> barnacle.with_name("my_barnacle")
      |> barnacle.with_listener(self)

  // Start the actor
  barnacle.start(barnacle)

  // Wait for the barnacle to refresh
  process.sleep(10_000)
  let assert Ok(barnacle.RefreshResponse(Ok(new_nodes))) = process.receive(self, 10_000)
}
```

## Manual interactions

You can interact with your barnacle manually by sending messages to it.

```gleam
import barnacle
import gleam/erlang/process
import gleam/otp/actor

pub fn main() {
  // Start a barnacle
  let barnacle_subject =
    barnacle.local_epmd()
    |> barnacle.start

  let assert Ok(_) = barnacle.pause(barnacle_subject, 1000)
  let assert Ok(_) = barnacle.refresh(barnacle_subject, 10_000)
  let assert Ok(_) = barnacle.shutdown(barnacle_subject, 1000)
}
```

Further documentation can be found at <https://hexdocs.pm/barnacle>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

If you would like to contribute, please open an issue or a PR. New strategies are
welcome, though try to keep dependencies to a minimum.

## TODO

- [ ] Tests!
- [ ] Add new strategies
  - [ ] Kubernetes
  - [ ] Kubernetes with DNS
  - [ ] Multicast UDP gossip
  - [ ] `.hosts.erlang` file
- [ ] Add a Fly.io example

## With thanks

A lot of inspiration came from the following projects:

- [libcluster](https://github.com/bitwalker/libcluster)
- [nessie_cluster](https://github.com/ckreiling/nessie_cluster)

Thanks!
