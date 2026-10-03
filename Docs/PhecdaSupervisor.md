# PhecdaSupervisor

`PhecdaSupervisor` is an independent executable depending only on `ISCSupervisor`.
It accepts one JSON object per UTF-8 stdin line and writes exactly one JSON
response per line to stdout. Malformed requests return an error and the loop
continues. EOF cancels this service's managed jobs and exits.

```sh
swift run PhecdaSupervisor --state-directory /absolute/path/to/supervisor-state
```

The default state directory is `~/Library/Application Support/PhecdaSupervisor`.
Relative argument paths resolve against the launching process's working directory.
Startup/argument errors are JSON responses before the process exits. Release
metadata uses `DeploymentLedger` in the state directory; job state and process
ownership are in memory and do not survive a service restart. Use one service
process per state directory; the existing ledger is not a multi-process store.

## Requests

`requestID` is an optional string echoed on decoded requests. `command` is one
of `ping`, `list`, `submit`, `cancel`, or `rollback`.

```json
{"command":"ping","requestID":"health-1"}
{"command":"list","requestID":"jobs-1"}
{"command":"submit","requestID":"deploy-1","plan":{"id":"A20414A0-DF90-4075-A707-4CF1B904E70A","workspace":"file:///absolute/path/to/project/","installCommands":[],"runCommand":"serveStatic","localPort":8080}}
{"command":"cancel","deploymentID":"A20414A0-DF90-4075-A707-4CF1B904E70A"}
{"command":"rollback","deploymentID":"A20414A0-DF90-4075-A707-4CF1B904E70A"}
```

The `plan` follows `DeploymentPlan`'s Codable schema. Optional `buildCommand`,
`runtimeArtifact`, and `runtimeRoot` fields may be omitted. URL fields are URL
strings, not bare paths. Runtime downloads require HTTPS, a local file URL root,
a SHA-256 checksum, and safe single-component runtime/version/archive names.
Plan invariants are checked again after decoding. Deployment IDs cannot be
submitted twice in one service instance.

Only existing `PresetCommand` values are accepted; this boundary never invokes
a shell or accepts free-form executable paths/arguments. Presets may execute
project code (for example `npm start`), so this is a **trusted local client**
boundary, not a sandbox for untrusted projects. Child processes receive null
stdin and captured stdout/stderr, keeping the JSON-lines stream separate.
Actual process ports remain determined by the existing presets; `localPort` is
coordinator metadata and does not rewrite preset arguments.

`submit` acknowledges scheduling, not successful deployment. Use `list` to
observe queued/running/failed/cancelled states. `cancel` acknowledges a cooperative
cancellation request. `rollback` delegates to `DeploymentCoordinator.rollback`
and requires an owned process and previous activated release records. The initial
protocol does not generate, checkpoint, or activate releases; existing deployment
integration must populate the ledger. Missing rollback prerequisites return an
error rather than fabricating a release.

## Responses

Every response includes `protocolVersion: 1` and `ok`. Optional fields include
`requestID`, `deploymentID`, `jobs`, `ledger`, and `release`. Dates are ISO-8601.
Errors have a stable `code` and human-readable `message`; messages are not an API.
Malformed input cannot reliably supply a request ID, so it is omitted.

```json
{"ok":true,"protocolVersion":1,"requestID":"health-1"}
{"error":{"code":"invalid_request","message":"submit requires a plan."},"ok":false,"protocolVersion":1}
```

Codes: `invalid_request`, `invalid_plan`, `duplicate_deployment`,
`unknown_deployment`, `operation_failed`, `invalid_arguments`, `startup_failed`,
and `encoding_failed`. After EOF or a closed output stream, no further response
can be delivered.
