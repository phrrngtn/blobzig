# CI and Runners

How CI works for the `blob*` family, and the things that broke setting it up —
recorded because all three failures were environmental rather than in the
workflow, and none of them would be obvious from a red build.

## The runners

Three are registered with Forgejo; CI uses two.

| label | machine | mode | image |
| --- | --- | --- | --- |
| `linux-x86_64` | dc1 | Docker | `blob-builder` |
| `macos-arm64` | gfe (laptop) | **host** — native Apple Silicon | — |
| `linux-arm64` | gfe | Docker | `node:20-bookworm` |

`linux-arm64` is deliberately unused: it duplicates dc1's coverage on slower
hardware, and it has been unable to reach the server for days
(`failed to fetch task ... connection reset by peer`).

`ubuntu-latest` is an alias for the dc1 runner, kept so older workflows still
resolve.

## The workflow

`blobzig/tools/ci-workflow.yml` is the source of truth;
`blobzig/tools/sync_ci.sh` copies it to every repo as
`.forgejo/workflows/ci.yml`. Nothing in it is repo-specific, so one file
genuinely serves all twelve.

    tools/sync_ci.sh            # write it everywhere
    tools/sync_ci.sh --check    # report drift, exit non-zero if any

Steps: **build → test → artifacts exist → extensions load**. The last two matter
because `zig build` exiting 0 proves neither that anything was produced nor that
it can be `dlopen`'d.

Two things are discovered rather than hardcoded, because guessing them wrong is
how this went red twice:

- **The test step.** Repos use `test`, `test-c`, `test-core`, or none.
  `zig build --list-steps` is asked; a fixed name would fail most repos.
- **The artifact directory.** Extension repos install into `zig-out/lib`;
  blobzig installs tools into `zig-out/bin`. Either satisfies the check.

## Seeing the status

Forgejo has **no cross-repository CI dashboard** — its Actions view is per-repo.

    tools/ci_status.sh           # latest run per repo, rolled up across jobs
    tools/ci_status.sh --watch   # refresh until everything settles
    tools/ci_status.sh --urls    # just the links

Per repo: `http://dc1:3000/phrrngtn/<repo>/actions`

The API endpoint that actually works is
`/api/v1/repos/{owner}/{repo}/actions/tasks` — it returns one entry per *job*,
newest first, so a repo is green only when every job of its newest `run_number`
succeeded. `actions/runs` returns something different and much older;
`actions/workflows` 404s on this version (Forgejo 14.0.3).

Job logs are not exposed through the API at all. They are on disk on dc1, zstd
compressed:

    /home/phrrngtn/forgejo/data/actions_log/{owner}/{repo}/{shard}/{task}.log.zst

`zstdcat` them. This is the only way to see why a job failed without the web UI.

## Three things that broke, none of them the workflow

### Squid was dead, so every fetch was ConnectionRefused

The dc1 runner injects `http_proxy=http://localhost:3128` into every container
(SSL-bumped caching, from the CMake era). Squid was `enabled` but `failed`: it
could not resolve its own hostname, spent its entire startup window retrying
rDNS, and systemd killed it as a timeout.

Fixed by setting `visible_hostname dc1.phrrngtn.arpa` in `/etc/squid/squid.conf`
— which is exactly what its own journal warning recommends. Original backed up
to `squid.conf.bak`.

### Zig cannot use that proxy anyway

With Squid alive the error became `HttpConnectionClosing`. Zig's HTTP client
uses a proxy when `http_proxy`/`https_proxy` are set, does **not** honour
`no_proxy`, and does not survive the SSL-bumped tunnel.

The workflow therefore clears the proxy variables. Deliberately done in the
workflow rather than the runner config, so the change is scoped to these jobs
and other work on that runner keeps its proxy. The container has direct outbound
access, and Zig's content-addressed global cache is the caching layer that
actually matters for these builds.

### Homebrew's node was broken, so every mac job aborted

Unrelated, and nothing to do with this repo. `node` linked
`libsimdjson.29.dylib` while the linked simdjson was 4.6.4, which ships `.33`.
Since `checkout` runs on node, every job died before reaching a build step, with
`signal: abort trap`. `brew reinstall node` fixed it.

Worth remembering as a class: **the host runner inherits the laptop's Homebrew
state.** A routine `brew upgrade` can take CI down without a commit being
involved. The Docker runner on dc1 does not have this exposure, which is an
argument for the container even though it is slower.

## The builder image

`~/forgejo-runner/Dockerfile` on dc1, built as `blob-builder`. It had no Zig at
all — it predates the migration — and now carries:

| tool | version | why |
| --- | --- | --- |
| Zig | 0.16.0, pinned | the only build system the family needs |
| Go | 1.23.4 | blobd2's D2 c-archive, on first build |
| DuckDB | v1.5.5 | so CI can load an extension, not just compile it |
| SQLite | 3.45.1 | same |

Zig is pinned because `zig build` output is version-sensitive and a silent
toolchain bump would surface as an unexplained CI failure.

Rebuild with `docker build -t blob-builder ~/forgejo-runner`.

## Related

- [[Building the Blob Family]] — the build instructions CI is exercising
- [[Zig Build vs CMake — An Honest Assessment]]
