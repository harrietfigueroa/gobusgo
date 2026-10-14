# Vendored asset sources: the npm registry and GitHub

Gobusgo downloads front-end assets from two sources, at versions `assets/vendor.lock.json` pins, with no Node toolchain. The npm registry supplies the built files of JavaScript packages. GitHub supplies the archive of a repository at a commit, for assets that are published only as files in a repository: the basemap's fonts and sprites, `protomaps/basemaps-assets`, which has no npm package, release, or tag (checked 2026-10-04). Gobusgo publishes nothing to either and reads nothing private.

## Documentation sources

- npm registry API: https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md — checked 2026-10-04
- npm package names: https://docs.npmjs.com/cli/v11/configuring-npm/package-json#name — checked 2026-10-04
- GitHub "Download a repository archive (tar)": https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#download-a-repository-archive-tar — checked 2026-10-04

## Servers and credentials

The servers are `https://registry.npmjs.org` and `https://codeload.github.com`. No request carries a credential, so there is no secret to redact and no header to strip. The client follows no redirect, and a tarball address on another host, or over HTTP, is refused before a request is made.

## Shared request rules

`Gobusgo.VendorAssets.Http.get/2` is the only function that issues a request. It returns every response that is not retried away as `%{status: ..., body: ..., location: ...}`, and each source's module branches on the statuses its source has.

- A request makes at most three attempts within 120 seconds, each with a 10-second connect timeout and a 30-second receive timeout.
- The statuses 408, 429, 500, 502, 503, and 504 and network faults are retried. The delay before a retry is a random time inside a window that doubles from 500 ms to a cap of 8 seconds, and a `Retry-After` header takes its place, up to 30 seconds.
- Every request is a `GET`, so a retry repeats nothing.
- A body longer than the caller's bound is cut off and returned as `:body_too_large`.
- Nothing is listed, so no pagination applies.

## npm registry

| Request | Purpose |
| --- | --- |
| `GET /<package>/<version>` | The metadata of one version; `<version>` is a version number or `latest`, the version the `latest` tag names. A scoped package is `@scope/name`, with its slash as it is |
| `GET <tarball>` | The gzip-compressed tar archive of that version, at the address the metadata gives in `dist.tarball` |

Fields read from the metadata: `name`, `version`, `dist.tarball`, and `dist.integrity`. The API page documents `dist.tarball` and `dist.shasum`, a SHA-1. `dist.integrity`, a SHA-512 written `sha512-<base64>`, is not on that page; the live registry returned it for all three packages on 2026-10-04. Metadata without it is `:invalid_metadata`, so a package is never pinned by SHA-1. Metadata is bounded at 1 MiB and a tarball at 64 MiB.

| Status | Handling |
| --- | --- |
| 200 | The body is the metadata or the tarball |
| 404 | `:not_found`: the registry has no such package, version, or tarball. The API page documents no error status; observed on 2026-10-04 as `GET /maplibre-gl/99.0.0` answering 404 with the body `"version not found: 99.0.0"` |
| Any other | `{:http_status, status}`; a redirect is one of these |

The registry's rate limits are undocumented on the API page and none was met.

## GitHub

| Request | Purpose |
| --- | --- |
| `GET https://codeload.github.com/<owner>/<name>/tar.gz/<commit>` | The gzip-compressed tar archive of the repository at the commit, every entry under one directory named after the repository |

GitHub documents the archive as `GET /repos/{owner}/{repo}/tarball/{ref}` on `api.github.com`, which answers 302 with an address on `codeload.github.com`. The integration requests the archive host directly, which spends none of the API's 60 unauthenticated requests an hour. The address form above is not in GitHub's REST documentation; it answered 200 with `content-type: application/x-gzip` for the pinned commit on 2026-10-04. An archive is bounded at 64 MiB.

| Status | Handling |
| --- | --- |
| 200 | The body is the archive |
| 404 | `:not_found`: no such repository or commit. Undocumented; observed on 2026-10-04 for a commit of forty zeros |
| Any other | `{:http_status, status}` |

Nothing asks GitHub which commit is the newest: an archive moves only to a commit the update task is given, a decision recorded in GOB-125.

## Integrity

- A package's tarball is used only when its SHA-512 equals the integrity it is expected to have: the lock file's when fetching, the registry's own metadata when updating. An update therefore trusts the registry for the new version, and the lock file records what it returned. Each file taken from a tarball is also checked against its SHA-256 in the lock file when fetching.
- An archive is pinned by its commit, which is itself a hash of the repository's content, and by `contentSha256`, a hash of the files taken: one line per file in path order, holding the path and the SHA-256 of the content. The lock file pins the content and not the archive's bytes, so repacking the same files leaves the hash as it is. A fetch uses the files only when they hash to the lock file's value.
- Only regular files are taken from an archive. A symbolic link is skipped, and a path that would leave the directory it is written under is refused.
- Beside each `.json`, `.pbf`, and `.txt` file of an archive, the fetch and the update write a gzip copy named `<file>.gz`, which the endpoint answers to a client that accepts gzip; a fetch that finds an archive present writes the copies that are absent. The copies are no files of the archive: `contentSha256` leaves them out, and an archive that holds a file ending in `.gz` is refused as `{:reserved_path, name, path}`.

## Using the module

`Gobusgo.VendorAssets.fetch/2`, `update/2`, and `update_archive/2` are the entry points, and the Mix tasks `gobusgo.vendor.fetch` and `gobusgo.vendor.update` call them with the paths of `Gobusgo.VendorAssets.paths/0`. `Registry` and `Github` hold the requests of their sources; `Lock` and `Tarball` are pure. Nothing in the running application calls any of them: the assets are fetched when assets are built.

Tests answer the requests from a `Req.Test` stub through the `:plug` option and build archives with `Gobusgo.Test.VendorTarball`.
