import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A DNS error that can occur when discovering nodes.
pub type LookupError {
  FormatError
  QueryFormatError
  ServerFailure
  NoSuchDomain
  Timeout
  NotImplemented
  Refused
  BadVersion
  PosixError(String)
  Unknown
}

@external(erlang, "barnacle_ffi", "lookup_a")
fn lookup_a(
  hostname: String,
  timeout: Int,
) -> Result(List(#(Int, Int, Int, Int)), LookupError)

@external(erlang, "barnacle_ffi", "lookup_aaaa")
fn lookup_aaaa(
  hostname: String,
  timeout: Int,
) -> Result(List(#(Int, Int, Int, Int, Int, Int, Int, Int)), LookupError)

pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Perform a DNS lookup against a hostname. This will return a list of IP
/// addresses. Queries will be performed using the `A` and `AAAA` record types.
pub fn dns_lookup(
  hostname: String,
  timeout: Int,
) -> Result(List(IpAddress), LookupError) {
  use a_records <- result.try(lookup_a(hostname, timeout))

  let a_records =
    a_records
    |> list.map(fn(ip) {
      let #(a, b, c, d) = ip
      IpV4(a, b, c, d)
    })

  use aaaa_records <- result.try(lookup_aaaa(hostname, timeout))

  let aaaa_records =
    aaaa_records
    |> list.map(fn(ip) {
      let #(a, b, c, d, e, f, g, h) = ip
      IpV6(a, b, c, d, e, f, g, h)
    })

  Ok(list.append(a_records, aaaa_records))
}

fn format_ip_address(ip: IpAddress) -> String {
  case ip {
    IpV4(a, b, c, d) -> {
      [a, b, c, d]
      |> list.map(int.to_string)
      |> string.join(".")
    }
    IpV6(a, b, c, d, e, f, g, h) -> {
      [a, b, c, d, e, f, g, h]
      |> list.map(fn(value) {
        case value {
          0 -> ""
          _ -> int.to_base16(value)
        }
      })
      |> string.join(":")
      |> string.lowercase
    }
  }
}

/// Discover nodes using DNS. The first argument is the basename of the nodes.
/// Currently, Barnacle only supports connecting to nodes with the same basename.
///
/// The second argument is the hostname to query against. Both A and AAAA records
/// will be queried. The final argument is an optional timeout for the DNS
/// lookup. This defaults to 5000ms if not supplied.
pub fn discover_nodes(
  basename: String,
  hostname_query: String,
  timeout: Int,
) -> Result(List(atom.Atom), LookupError) {
  use ip_addresses <- result.try(dns_lookup(hostname_query, timeout))

  ip_addresses
  |> list.map(fn(ip) {
    let ip_string = format_ip_address(ip)
    { basename <> "@" <> ip_string } |> atom.create_from_string
  })
  |> Ok
}
