# ISC Phecda Product Architecture

## Product identity

- Display name: ISC Phecda
- Repository: ISC-Phecda
- macOS target: Apple Silicon, macOS 27
- Kernel boundary: Phecda uses the versioned `libisc.dylib` / `libisc.h` C ABI. It does not import ISC-Core Go packages.

## Kernel boundary

Phecda links ISC-Core through the versioned `libisc.dylib` / `libisc.h` C ABI and nothing
else. It contains no Go code, no `go.mod`, and never shells out to the `isc` CLI. The C
pointers are confined to a single file, `Sources/ISCCore/KernelClient.swift`; the rest of the
app reaches the kernel through kernel HTTP paths.

The kernel starts inside the GUI process. `isc_call` hands each request straight to the
kernel's own handler rather than over a socket, and the bearer token is read by the library
and never passed to the GUI.

Two build-time guards keep that boundary honest:

- `Scripts/verify-vendor.sh` checks `Vendor/ISC` against the pinned digests in
  `Vendor/ISC/SHA256SUMS`, which are copied from the ISC-Core release. Both `Scripts/test.sh`
  and `Scripts/build-app.sh` run it first, so a mismatched kernel fails the build instead of
  shipping.
- Kernel lookup paths are relative to the loading binary (`@executable_path/../Frameworks`
  for the bundle, `@loader_path/...` for the checkout and test bundle). No absolute path from
  the building machine is baked into the product.

### Who owns what

| State | Owner |
| --- | --- |
| Projects, deployments, scan evidence, presets | ISC-Core (`/v1/phecda/*`) |
| Published services, their ordering, favorites, verification stamp | ISC-Core (`/v1/public-services`) |
| DNS, DDNS, proxy, ACME, reachability, verification, jobs, audit | ISC-Core |
| Runtime downloads, dependencies, builds, process and container lifecycle | Phecda Supervisor |
| Deployment execution state (release ledger) | Phecda Supervisor |

A Phecda deployment stores only a *reference* to a published service, `public_service_id`, and
the record it points at lives in the same kernel database. The kernel clears that reference in
the same transaction that removes a service, so it cannot dangle — the GUI does not, and
cannot, leave a stale pointer behind. Materializing a binding still goes through the kernel's
own DDNS, reverse-proxy and certificate APIs.

A `services.json` written by a build that predates this split is read once at startup and
imported into the kernel, then renamed to `services.json.migrated`. It is never written again;
the archive type is deliberately read-only.

## Server creation modes

Phecda deliberately separates these flows:

### Non-Docker applications

The user supplies a directory, archive, or Git source. Phecda performs a read-only scan, reports evidence and confidence, recommends a preset, then asks for confirmation before downloading a runtime, installing dependencies, building, or starting the service.

Initial website presets:

- Static HTML/CSS/JavaScript
- Node.js
- Python
- PHP
- Go
- Java
- Custom non-Docker server

The scanner never executes source-provided scripts during detection. Secrets, `.env` files, certificates, SSH material, VCS metadata, and build output are excluded from scan results.

### Docker applications

Docker is a separate creation mode. A Docker service does not require a source directory by default. The user chooses one of:

- Docker Compose / Compose file
- Dockerfile project
- Existing image reference
- Simple Docker command
- Advanced custom Docker command

The preview must show image sources, commands, ports, volumes, environment variable names, restart policy, network mode, and privilege implications. Host networking, privileged containers, and arbitrary host mounts require explicit confirmation. Phecda detects Docker availability but does not silently install Docker Desktop.

## Deployment model

The public service view connects these independent objects:

```text
PhecdaProject -> PhecdaDeployment -> PublishedService -> DDNS / Proxy / Certificate
```

A project is not the same thing as a DNS record or proxy route. A project can have multiple deployments; a deployment can expose multiple domains; runtimes can be shared but dependencies and workspaces remain isolated.

The supervisor layer owns runtime downloads, checksums, dependency installation, build processes, application lifecycle, health checks, logs, ports, cancellation, retry, and recovery. ISC-Core owns DNS, DDNS, proxy, ACME, reachability, firewall plans, external verification, and kernel events.

## Future products

### ISC Mizar

Future mobile monitoring and limited configuration client. It must use a dedicated authenticated remote management layer and never expose the local kernel token.

### ISC Dubhe

Future multi-host cluster control plane. It requires agents, node identity, scheduling, placement, cluster state, multi-node logs, and failure handling. No remote listener or cluster protocol is enabled by the current Phecda version.
