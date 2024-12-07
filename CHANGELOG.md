# Changelog

## v2.0.0 - 2024-12-07

- Use the more permissive `inet_res:getbyname` function for DNS lookups.

  - This uses the `search` option, which will allow things like `service.namespace`
    to be used in Kubernetes, as opposed to `service.namespace.svc.cluster.local`.
    Thanks to @tsoughter in #3.

- Exposes the `barnacle/dns` and `barnacle/local_epmd` modules.
  - Users can now use the functions in these modules to create custom strategies.

## v1.1.0 - 2024-10-25

- Add `run_once` function for when polling is not needed.

## v1.0.0 - 2024-10-21

- Initial release with `local_epmd`, `epmd` and `dns` strategies, as well as support
  for custom strategies.
