# npm registry integration (vendored front-end packages)

The npm registry is the public package index of the JavaScript ecosystem. Gobusgo reads it for one purpose: to download the built files of the front-end packages the pages use, at pinned versions, with no Node toolchain. It publishes nothing and reads no private package.

## Documentation sources

- Registry API: https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md — checked 2026-10-04
- Package names: https://docs.npmjs.com/cli/v11/configuring-npm/package-json#name — checked 2026-10-04

## Server and credentials

The server is `https://registry.npmjs.org`. The requests carry no credential, so there is no secret to redact and no header to strip. The client follows no redirect, and a tarball address on any other host, or over HTTP, is refused before a request is made.

## Requests

| Request | Purpose |
| --- | --- |
| `GET /<package>/<version>` | The metadata of one version; `<version>` is a version number or `latest`, the version the `latest` tag names. A scoped package is `@scope/name`, with its slash as it is |
| `GET <tarball>` | The gzip-compressed tar archive of that version, at the address the metadata gives in `dist.tarball` |

Fields read from the metadata: `name`, `version`, `dist.tarball`, and `dist.integrity`. The API page documents `dist.tarball` and `dist.shasum`, a SHA-1. `dist.integrity`, a SHA-512 written `sha512-<base64>`, is not on that page; the live registry returned it for all three packages on 2026-10-04. Metadata without it is `:invalid_metadata`, so a package is never pinned by SHA-1.

Neither request lists anything, so no pagination applies. Metadata is bounded at 1 MiB and a tarball at 64 MiB; a longer body is cut off and returned as `:body_too_large`.

## Statuses

| Status | Handling |
| --- | --- |
| 200 | The body is the metadata or the tarball |
| 404 | `:not_found`: the registry has no such package, version, or tarball. The API page documents no error status; observed on 2026-10-04 as `GET /maplibre-gl/99.0.0` answering 404 with the body `"version not found: 99.0.0"` |
| 408, 429, 500, 502, 503, 504 | Retried, then `{:http_status, status}` |
| Any other | `{:http_status, status}`, with no retry; a redirect is one of these |

A request makes at most three attempts within 120 seconds, each with a 10-second connect timeout and a 30-second receive timeout. The delay before a retry is a random time inside a window that doubles from 500 ms to a cap of 8 seconds, and a `Retry-After` header takes its place, up to 30 seconds. Both requests are `GET`, so a retry repeats nothing. The registry's rate limits are undocumented on the API page and none was met.

## Integrity

A tarball is used only when its SHA-512 equals the integrity it is expected to have: the lock file's when fetching, the registry's own metadata when updating. An update therefore trusts the registry for the new version, and the lock file records what it returned; a fetch trusts only the lock file. Each file taken from a tarball is checked against its SHA-256 in the lock file when fetching.

## Using the module

`Gobusgo.VendorAssets.fetch/2` and `update/2` are the entry points, and the Mix tasks `gobusgo.vendor.fetch` and `gobusgo.vendor.update` call them with the paths of `Gobusgo.VendorAssets.paths/0`. `Gobusgo.VendorAssets.Registry` is the only module that issues requests; `Lock` and `Tarball` are pure. Nothing in the running application calls any of them: the packages are fetched when assets are built.

Tests answer the requests from a `Req.Test` stub through the `:plug` option and build tarballs with `Gobusgo.Test.VendorTarball`.
