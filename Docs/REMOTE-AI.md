# Remote AI

How the assistant talks to a real model, and why the rest of the app cannot
tell which one.

## The layering

```
AssistantEngine          knows: AIProvider
      ↓
RemoteAIProvider         knows: adapter, transport, configuration, credential
      ↓
OpenAICompatibleAdapter  knows: chat/completions, tool_calls, Bearer auth
      ↓
HTTPTransport            knows: URLSession
      ↓
any OpenAI-compatible HTTP API
```

`OpenAICompatibleAdapter` is the **only** type in the repository that knows what
`tool_calls` or `finish_reason` mean. The wire DTOs are `internal` to
`AIProviderRemote` and never appear above it. Pointing the app at a different
service — a proxy, a self-hosted server, another vendor implementing the same
protocol — is a configuration change. A vendor with a *different* protocol is
one new adapter and nothing else.

It is called "compatible" rather than "OpenAI" deliberately: the protocol is the
contract, not the company.

## Configuring it

Settings → AI Model → Cloud Model → **Set up**.

| Field | Example | Stored in |
| --- | --- | --- |
| Endpoint | `api.openai.com/v1` | `UserDefaults` |
| Model | any opaque string | `UserDefaults` |
| API key | — | **Keychain** |

The provider reports `Ready` only when all three are present and the endpoint
parses. Until then it reports `configurationRequired`, the model selector shows
"Setup needed", and the Assistant screen says replies are coming from the
scripted development stand-in.

### Endpoint handling

`RemoteAIEndpoint` normalises what people actually paste. All of these produce
`https://api.example.com/v1/chat/completions`:

- `https://api.example.com/v1`
- `api.example.com/v1` (a bare host is assumed HTTPS)
- `https://api.example.com` (`/v1` is appended)
- `https://api.example.com/v1/` (trailing slashes ignored)
- `https://api.example.com/v1/chat/completions` (the full path is tolerated)

`/v1` is appended only when the root does not already end in a version segment,
so `/v1/v1/chat/completions` cannot happen. `http` is accepted so a local
inference server on a LAN stays usable; the UI shows the host so it is obvious.

### Configuration priority

1. **What the user saved.** Keychain for the key, `UserDefaults` for endpoint
   and model.
2. **A development xcconfig**, if one exists (see below).
3. Nothing — the provider reports what is missing.

A development file can never override a value entered in Settings. The
credential chain is ordered, not merged.

## Development secrets

For running against a real service without retyping credentials:

```bash
cp Config/LocalSecrets.example.xcconfig Config/LocalSecrets.xcconfig
# edit it, then regenerate the project
xcodegen generate
```

`Config/App.xcconfig` pulls it in with `#include?` — the optional form, so the
build works when the file is absent, which is the case in CI and for anyone who
has not made one.

Two things to know:

- **`//` starts a comment in xcconfig.** Write the endpoint without a scheme
  (`api.openai.com/v1`); the app assumes HTTPS for a bare host.
- **These values are compiled into the app's Info.plist.** That is fine for a
  development key on your own machine and wrong for anything else. For normal
  use, type the key into Settings — it goes to the Keychain instead.

`Config/LocalSecrets.xcconfig` is gitignored. The example template is not, and
contains only placeholders.

## What the model can and cannot do

The model proposes; the application disposes. Nothing changes about that when a
real model is connected:

```
model returns tool_calls
  → OpenAICompatibleAdapter    deserialises into AIToolCall (no validation)
  → ToolRequestDecoder         types it, or rejects it
  → SettingsToolAuthorizer     allowed / requiresConfirmation / denied
  → PermissionService          does the OS even allow this?
  → PlatformService (mock)     the only code that causes an effect
  → ToolResult
```

Specifically:

- **Unknown tools cannot execute.** The adapter passes the name through
  unchanged so the decoder rejects it *by name* and the rejection is visible in
  the plan, rather than the call disappearing silently in the network layer.
  There is no dynamic dispatch to an arbitrary function anywhere.
- **Malformed arguments cannot execute.** Arguments that are not a JSON object
  become `.null`, which every typed input fails to decode, so the call is
  rejected with the reason shown.
- **The model never sees an OS API.** Actions run against the mock platform
  services, which report `.simulated`. That is still true with a real model
  connected, and the tool result sent back to the model says so in words, so it
  cannot tell the user their phone did something it did not.

## Tool schemas

The tools offered to the model are the application's existing ones. There is no
second set of definitions: `AIToolSchema.parameters` is the same `JSONSchema`
the app already uses, rendered by the same `jsonValue()`. Adding a tool to
`ToolCatalog` automatically offers it to the model with its real parameters,
types, enums and required fields.

## Tool results

A provider that declares `supportsToolResultContinuation` gets a second round:
it sees an `assistant` message carrying its own tool calls, then one `tool`
message per call describing what happened, and writes a closing reply.

The loop is bounded by `AIGenerationOptions.maximumToolRounds` (default 2) *and*
by the capability flag. `ScriptedDevProvider` does not set the flag, so it gets
exactly one round and cannot be re-asked the same question — which would
otherwise duplicate every action it proposed.

If the closing request fails, the actions already taken are kept and the earlier
text is used. Work is never thrown away because the summary failed.

## Errors

`RemoteAIError` is typed, because the answer to each case is different:

| Case | Cause |
| --- | --- |
| `notConfigured` | Endpoint, key or model missing — reported before any request |
| `invalidEndpoint` | The configured URL does not parse |
| `authenticationFailed` | 401 / 403 |
| `notFound` | 404 — usually a wrong endpoint path or model name |
| `rateLimited` | 429, with `Retry-After` when the service sends it |
| `requestRejected` | Other 4xx |
| `serverError` | 5xx |
| `toolCallingUnsupported` | The service says the model cannot do tools |
| `network` | Offline, DNS, TLS, connection reset |
| `timedOut` | Past the configured timeout |
| `cancelled` | The turn was abandoned |
| `malformedResponse` | HTTP 200 with a body we cannot use |

Structured API error bodies are parsed when present, with fallbacks to a bare
`{"message": …}`, to plain text, and finally to the HTTP status. **Parsing an
error never throws** — a service returning HTML must not turn a useful status
into a crash.

## Credentials, and what is never logged

- The key lives in the Keychain via `CredentialStore`, with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — no backups, no other
  devices.
- It is not in `RemoteAIConfiguration`, so it cannot reach a plist, a
  `description` or an encoded snapshot.
- `RemoteAIError` carries no case that could hold it.
- `HTTPRequest.redactedHeaders` is what logging uses; `Authorization` reads
  `<redacted>`.
- `RemoteAILogger` records host, model, status, duration, tool names and error
  category. Never the key, never message content.
- The Settings field is a `SecureField` and shows `••••••••••••` when a key is
  stored. The app never reads a stored key back for display.

There is a test asserting no error description contains the credential.

## CI

The GitHub Actions simulator build needs no credentials and gets none. With no
`LocalSecrets.xcconfig` and an empty Keychain, the remote provider reports
`configurationRequired`, routing falls back to `ScriptedDevProvider`, and the
app launches and screenshots exactly as before.

Every test uses a stub transport. No test opens a socket.

## Known limitations with specific servers

- **Streaming is not implemented.** Requests are non-streaming, so a long reply
  arrives all at once.
- **Only the chat-completions shape is supported.** Services that expose only a
  newer responses-style API need their own adapter.
- **Tool-calling support is assumed.** `availableModels` reports
  `supportsNativeToolCalling: true` without asking. A service that disagrees
  surfaces as `toolCallingUnsupported` rather than being predicted.
- **`content` is sent as a plain string**, not the array-of-parts form some
  services now prefer. Compatible servers accept the string form; a strict one
  might not.
- **The tool-call id is regenerated.** Service ids like `call_abc123` are not
  UUIDs, so the app substitutes its own and uses them consistently within a
  turn. Each request is stateless, so the service never sees a mismatch.
- **No retry or backoff.** A 429 is reported, not waited out.
