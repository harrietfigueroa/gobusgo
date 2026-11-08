# Amazon S3: the bucket the backends store in

Gobusgo stores every destination of the writer, the reader, and the deleter as one object of one S3 general purpose bucket, when a bucket is configured: the raw OneBusAway responses, the usage records, and the route and stop tile archives, which production serves to browsers from the bucket through CloudFront (GOB-218). With no bucket configured the three use their local file backends, and nothing in this directory runs. The application creates no bucket and changes no bucket setting; the bucket and the role that reaches it belong to the infrastructure repository.

## Documentation sources

- `PutObject`: <https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html> — checked 2026-11-08
- Conditional writes: https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html — checked 2026-10-11
- `GetObject`: <https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html> — checked 2026-11-08
- `HeadObject`: https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html — checked 2026-10-11
- `DeleteObject`: https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObject.html — checked 2026-10-11
- `ListObjectsV2`: https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html — checked 2026-10-11
- Container credential provider: https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html — checked 2026-10-11
- Task IAM role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html — checked 2026-10-11
- Error responses: https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html — the page did not load on 2026-10-11, so the transient statuses below are taken from the operation pages and the conditional writes page, and the error codes are not verified against it.

## Settings

| Variable | Meaning |
| --- | --- |
| `GOBUSGO_S3_BUCKET` | The bucket. Unset or blank, the local file backends are used and the other variables are not read. |
| `GOBUSGO_S3_REGION` | The bucket's region, which requests are signed for. Required with a bucket. |
| `GOBUSGO_S3_PREFIX` | The key prefix: empty, or destination segments that end in `/`, such as `production/`. |
| `GOBUSGO_S3_ENDPOINT` | The address the bucket is reached at, an `https` address with no path. Unset, it is `https://<bucket>.s3.<region>.amazonaws.com`. |
| `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` | Set by ECS: the path of the task's credentials at `http://169.254.170.2`. |
| `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN` | The whole credentials address and the `Authorization` header it asks for, read when the relative one is unset. |

`config/runtime.exs` reads them and selects the three S3 backends when a bucket is named. `Gobusgo.Config.fetch_storage/1` validates them, and the application refuses to start on a value that is missing or not valid.

## Credentials

The credentials are the temporary ones of the task's role, never a setting. `Gobusgo.S3.Credentials` is a process that fetches them from the container credentials endpoint with one `GET`, at most two attempts, and holds them until five minutes before their `Expiration`. A refresh that fails while the credentials held are still valid returns those and logs `S3 credentials refresh failed` at `warning`; with none to return it answers `{:error, :unavailable}` and logs `S3 credentials unavailable` at `error`.

No credential is logged or put into an error, and the process reports its state without them. Req signs each request with AWS Signature Version 4 and masks the signing options where it prints a request. The client follows no redirect, so the `Authorization` header never reaches another origin.

## Requests

`Gobusgo.S3.Client.request/2` is the only function that sends a request to the bucket. It returns every response that is not retried away as `%{status: ..., body: ...}`, and each backend branches on the statuses its operation documents.

- A request makes at most three attempts within 15 seconds, each with a 2-second connect timeout and a 5-second receive timeout.
- The statuses 409, 500, 502, 503, and 504 are retried. The delay before a retry is a random time inside a window that doubles from 100 ms to a cap of 2 seconds, and a `Retry-After` header takes its place, up to 5 seconds.
- A network fault is retried for a read, a listing, a lookup, and a deletion. It is not retried for a write: the object may be stored, and a second conditional write would then answer 412.
- A body longer than the caller's bound is cut off and returned as `:body_too_large`.

## Operations and outcomes

A key is the key prefix followed by the destination (`Gobusgo.S3.Key`).

| Contract call | Request | Outcomes |
| --- | --- | --- |
| `Writer.write/2` | `PUT /<key>` with `If-None-Match: *`, and `Cache-Control: public, max-age=<seconds>, immutable` for a request that names `reader_keep_seconds` | 200 `:ok`; 412 `:already_exists`; 403 `:permission_denied`; 404 and the transient statuses `:io_failure` |
| `Reader.read/2` | `GET /<key>` | 200 the content; 404 `:not_found`; 403 `:permission_denied`; a body over 16 MB `:content_too_large` |
| `Reader.discover/2` | `GET /?list-type=2&encoding-type=url&max-keys=<at most 100>&prefix=<key prefix and prefix>`, with `start-after` on the first request and `continuation-token` on the next | 200 a page; 403 `:permission_denied`; 404 `:io_failure` |
| `Deleter.delete/2` | `HEAD /<key>`, then `DELETE /<key>` | `HEAD` 404 `:not_found`; `DELETE` 204 `:ok`; 403 `:permission_denied` |

Every call answers `:io_failure` for a transient status that outlasts the retries, a network fault, the client's deadline, and unavailable credentials. A status outside an operation's rows raises `Gobusgo.Assert.AssertionError`.

- `PutObject` stores a request's `Cache-Control` with the object, and `GetObject` answers with it. The route and stop tile archives are written with a year (GOB-221). Neither page says whether a ranged `GetObject` or an error for a key carries the header; both are unverified.
- S3 answers 403 in place of 404 for a key that holds no object when the role may not list the bucket, so a role without `s3:ListBucket` turns every `:not_found` into `:permission_denied`.
- S3 lists keys in ascending order only. A descending discovery lists the whole prefix first, at most 100 requests of 100 keys, and answers `:discovery_too_large` past that. Nothing in the application discovers in descending order.
- A listing is one lazy stream of pages; discovery takes pages until its own page of destinations is full. A key whose remainder after the key prefix is no valid destination is left out.
- The role needs `s3:PutObject`, `s3:GetObject`, and `s3:DeleteObject` on the keys under the prefix, and `s3:ListBucket` on the bucket.

## Using the module

Callers use `Gobusgo.Writer`, `Gobusgo.Reader`, and `Gobusgo.Deleter` and name no backend. Only `config/runtime.exs` names the S3 backends. Tests reach the backends through `Gobusgo.Test.FakeS3`, a bucket held in memory that answers the client through a plug; no test sends a request to AWS, and the local environment has no S3 mock.

## Open items

- The production network reaches the bucket's default regional address through its S3 gateway endpoint, so `GOBUSGO_S3_ENDPOINT` is unset there (observed on 2026-10-12, GOB-204).
- The time two S3 requests add to each recorded fetch, which is not measured.
- Retention in the bucket is its lifecycle rules, declared in the infrastructure repository with the days of `Gobusgo.RetentionPolicy`; the application schedules no cleanup with a bucket configured, and the deleter's S3 backend has no scheduled caller.
