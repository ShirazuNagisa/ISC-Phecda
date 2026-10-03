# ISC Phecda Product Architecture

## Product identity

- Display name: ISC Phecda
- Repository: ISC-Phecda
- macOS target: Apple Silicon, macOS 27
- Kernel boundary: Phecda uses the versioned `libisc.dylib` / `libisc.h` C ABI. It does not import ISC-Core Go packages.

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
