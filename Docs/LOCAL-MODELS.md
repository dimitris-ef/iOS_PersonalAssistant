# Local AI

Downloadable on-device models, run by llama.cpp. This is the document for
anyone changing the local-model system, adding a model to the catalog, or
swapping the inference runtime.

---

## 1. The shape of it

```
AssistantEngine
    ↓  AIProvider
LocalModelProvider
    ↓  LocalModelRuntime
LlamaCppRuntime
    ↓
the downloaded GGUF file
    ↓
local inference
    ↓
AIResponse / AIToolCall
    ↓
decode → validate → authorize → confirm → execute
```

Everything above `LocalModelProvider` is the code that already served the cloud
model and Apple's on-device model: the same system prompt, the same assembled
context, the same Part 9 semantic memory, the same tool schemas, the same
Part 7 agent loop, the same validation and authorization. Nothing in the engine,
the tools, the repositories or the UI knows what GGUF is.

**The local model never executes anything.** It emits text. That text becomes
`AIToolCall` values, and `AgentRunner` decides — exactly as it does for every
other provider — whether any of them run. `AIProviderLocal` depends on
`AssistantDomain`, `AssistantAI` and `AssistantPersistence`; `EventKit`,
`UserNotifications` and `AlarmKit` are not in its dependency graph, so the
guarantee is structural rather than promised.

---

## 2. Where things live

| Concern | Type | Target |
| --- | --- | --- |
| Runtime abstraction | `LocalModelRuntime` | `AIProviderLocal` |
| llama.cpp adapter | `LlamaCppRuntime` | `AIProviderLocalLlama` |
| Provider | `LocalModelProvider` | `AIProviderLocal` |
| Catalog | `LocalModelCatalog`, `Resources/local-models.json` | `AIProviderLocal` |
| Compatibility | `LocalModelCompatibilityPolicy`, `LocalModelResourceEstimator` | `AIProviderLocal` |
| Downloads | `LocalModelDownloadManager`, `ModelDownloadTransport` | `AIProviderLocal` |
| Verification | `LocalModelInstaller`, `GGUFReader`, `SHA256Hash` | `AIProviderLocal` |
| Files on disk | `LocalModelStore` | `AIProviderLocal` |
| Orchestration | `LocalModelManager` | `AIProviderLocal` |
| Prompting and parsing | `LocalToolPromptAdapter`, `LocalChatTemplate` | `AIProviderLocal` |
| Installed rows | `LocalModelRecord`, `LocalModelRepository` | `AssistantDomain`, `AssistantPersistence` |
| Test double | `MockLocalModelRuntime` | `AIProviderLocal` |

Only `AIProviderLocalLlama` imports `llama`. Everything else — every policy,
every check, every test — builds and runs on Linux and Windows, which is where
the core of this project is developed.

---

## 3. llama.cpp

**Pinned to build `b10506`**, consumed as the XCFramework that build publishes:

```
https://github.com/ggml-org/llama.cpp/releases/download/b10506/llama-b10506-xcframework.zip
sha256 4a8ce464f3743d5035906ed1f5d7e3474b086ee1e082779be2268510cdcddf7c
```

A build tag, never a branch. `master` moves several times a day, and a
dependency that changes underneath CI fails for reasons nobody here can
reproduce.

### It is opt-in, and here is why

The published artifact contains **two slices: `ios-arm64` and
`macos-arm64_x86_64`.** There is no iOS Simulator slice. An app target that
links it cannot be built for the simulator at all — the link fails outright,
which would take the simulator CI lane and every SwiftUI preview with it.

So the binary target is added to the package graph only when
`PPAI_LLAMA_RUNTIME=1` is set at manifest-evaluation time:

```bash
PPAI_LLAMA_RUNTIME=1 swift build              # links llama.cpp
PPAI_LLAMA_RUNTIME=1 xcodegen generate        # device builds get it
swift build                                    # everything else, no download
```

`AIProviderLocalLlama` is *always* a target and always compiles. What changes is
whether it has a `llama` module to import, which it detects with
`#if canImport(llama)`. Without it, `LlamaCppRuntime` reports itself unavailable
and Local AI shows as unsupported in Settings — the same graceful path a device
with no downloaded model already takes.

The `Local model runtime` CI workflow builds with the flag on, so the
integration is compiled and linked on every change to it rather than only when
somebody remembers.

### Licences

llama.cpp is MIT, and its notice travels with the framework. That is the
*runtime's* licence and has nothing to do with any model's — those are recorded
per entry in the catalog and shown on the model detail screen (§84).

---

## 4. The runtime abstraction

```swift
protocol LocalModelRuntime: Sendable {
    var runtimeCapabilities: LocalRuntimeCapabilities { get }
    func runtimeAvailability() async -> LocalRuntimeAvailability
    func loadedModel() async -> LoadedModelInfo?
    func loadModel(_ request: LocalModelLoadRequest) async throws -> LoadedModelInfo
    func unloadModel() async
    func generate(_ prompt: LocalPrompt, options: LocalGenerationOptions) async throws
        -> LocalGenerationOutput
    func cancelGeneration() async
}
```

Six members, all of which MLX, ExecuTorch or a Core ML pipeline could implement.
That is the test the protocol has to pass: nothing in it is llama.cpp-specific.
GPU layer counts, batch sizes, sampler chains and tokenizers are configured
inside the adapter and never appear here.

Adding a runtime later is a new conformance plus a branch in
`LocalRuntimeResolver`. Nothing in `AssistantEngine` changes.

### Concurrency

`LlamaCppRuntime` is an actor, and that is load-bearing. A `llama_context`
holds a KV cache that `llama_decode` mutates in place; two turns decoding into
one context produce a corrupted cache and, fairly often, a crash inside GGML.

Native pointers are `private` fields of that actor. `releaseNativeResources()`
is the only place `llama_free` and `llama_model_free` are called; it nils what
it frees, so it is idempotent, and every path that ends a model's life goes
through it.

---

## 5. Memory, storage and the numbers

`LocalModelResourceEstimator` owns every constant, and each one is named:

| Constant | Default | What it is |
| --- | --- | --- |
| `usableMemoryFraction` | 0.45 | Share of physical RAM the app plans around. **Not** all of it — see below. |
| `reservedApplicationBytes` | 320 MB | SwiftUI, SwiftData, the conversation, memory, the OS's share. |
| `runtimeOverheadBytes` | 96 MB | Backend registry, tokenizer, sampler. |
| `minimumComputeBufferBytes` | 128 MB | Floor for activations and Metal buffers. |
| `computeBufferWeightFraction` | 0.12 | Compute buffers also scale with the model. |
| `fallbackKVBytesPerToken` | 48 KB | Used only when the file did not say. Deliberately pessimistic. |
| `storageHeadroomBytes` | 1 GB | Free space wanted beyond the file itself. |

**An 8 GB device does not have 8 GB for this app.** iOS reserves memory for
itself, other processes stay resident, and an app that grows past its jetsam
limit is killed outright with no error to catch. The fraction is deliberately
low: being wrong downwards costs the user a smaller model, being wrong upwards
costs them the app disappearing mid-sentence.

The KV cache is linear in context length and the weights are not, so the same
model loads at 2048 and fails at 16384. Rather than refusing outright,
`largestFittingContext` halves the context until it fits — a shorter
conversation is a better outcome than no model.

Where the file's own header records block count, KV head count and key length,
the KV figure is *measured* rather than guessed, and
`LocalModelMemoryEstimate.kvCacheIsMeasured` says which happened.

### The term that was missing

A 3B model used to take the app down when a conversation *started*, not when it
loaded — and that timing is the whole diagnosis. `llama_init_from_model`
allocates the weights and the KV cache; the compute buffers are allocated
lazily on the first `llama_decode` and are sized from the **micro batch**, not
from the weights. The preflight modelled weights, KV, a flat overhead and 12% of
the weights, and never modelled the micro batch — while the runtime opened
contexts at `n_batch = n_ubatch = 512`, llama.cpp's desktop default, on a phone
whose GPU is also drawing the interface. So the model passed the check, loaded,
reported itself ready, and was killed by iOS on the first decode. Nothing in the
Local AI path force-unwraps or traps, which is consistent with jetsam rather
than a Swift crash.

`LocalInferenceConfiguration` now holds every number the runtime is opened with,
tiered on physical memory rather than a device-name table:

| Physical memory | Context | Batch | Micro batch | Reply cap |
| --- | --- | --- | --- | --- |
| ≥ 7.5 GB | 4096 | 256 | 128 | 768 |
| ≥ 5.5 GB | 3072 | 192 | 96 | 640 |
| below | 2048 | 128 | 64 | 512 |

Threads are half the cores, floored at 2 and capped at 4 — inference that
saturates the CPU starves SwiftUI and reads as the app hanging.
`computeBufferBytesPerMicroBatchTokenPerBillion` adds the missing term to the
estimate, so the preflight now sees the allocation that happens on the first
decode. None of this is user-editable (§106).

### Bounding the prompt

`LocalPromptBudget` trims a prompt to `maximumPromptTokens` for the
configuration the runtime **actually got** — read from
`LocalModelManager.activeConfiguration()`, because the adaptive reduction means
a model whose record says 4096 may be running at 1024, and only one of those
numbers is real. Every system turn survives, the newest user turn survives
(truncated in place rather than dropped), and history goes oldest-first. The
reply length is bounded by what is left of the context, because bounding the
prompt alone still allows a full context to be handed a nearly-full prompt and
asked for 640 tokens back.

The token count is `characters / 4` plus per-turn template overhead, rounded up
everywhere. There is no tokenizer at this layer on purpose: reaching for the
real one means coupling the provider to llama.cpp for a number it needs only
approximately, and erring toward trimming one turn too many costs a line of old
conversation while erring the other way costs the app.

---

## 6. Download, verify, install

```
compatibility (RAM, storage, format, licence, runtime)
    ↓  refuse here, before any bytes move
URLSession download → throttled progress → cancellable → resumable
    ↓
SHA-256, when the catalog declares one
    ↓
GGUF header: magic, version, tensor count, metadata
    ↓
does it match the catalog's claim about architecture and size?
    ↓
atomic move into Application Support/Models
    ↓
installed
```

Nothing says **Ready** before every step above it has passed. A file that fails
any of them is deleted rather than left where a later launch might find it.

### GGUF validation without llama.cpp

`GGUFReader` parses the header in pure Swift: magic, version, counts, and a
bounded walk of the metadata table. It exists because "is this a model" must be
answerable *before* anything tries to load it, and on builds with no llama.cpp
linked — and because a 2 GB HTML error page named `model.gguf` is an entirely
ordinary thing for a broken CDN to return.

It is bounded everywhere: a 32 MB inspection window, a 1 MB cap on any string,
a 4 M cap on any array. The input is an untrusted file and the code runs on a
phone; a parser that traps on a short read crashes the app when a download is
interrupted.

### Checksums

`checksumSHA256` is optional in the catalog format and **enforced whenever it is
present**. The entries currently shipped do not carry one — see
`Docs/OPEN-ITEMS.md` entry 31a, and `Sources/AIProviderLocal/Resources/README.md`
for how to add them. Verification is not skipped for those: the file must still
be a structurally valid GGUF of the declared architecture and roughly the
declared size, and the digest of what arrived is computed and recorded so a
later integrity check has a baseline. What is missing is detection of a
*substituted* but well-formed file — which is why the transport refuses plain
HTTP.

### Where files live

`Application Support/Models/<model-id>.gguf`, excluded from backup, with iOS
data protection `completeUntilFirstUserAuthentication`.

Not Documents (the user would see a blob they cannot read and might delete), not
Caches (iOS empties it under pressure, and a model that vanishes on a full phone
is one the user has to download again having been told it was installed), and
not SwiftData (§26 — a database designed for rows should not carry gigabytes of
tensors through every future migration).

Paths are stored **relative**. iOS relocates app containers on restore, so an
absolute path recorded today may name nothing tomorrow.

---

## 7. Prompting and tool calls

The system prompt is the app's own, unchanged (§41). There is no separate
"local AI personality".

When tools are on offer, `LocalToolPromptAdapter` appends a short protocol
block generated from the request's existing `AIToolSchema` values — the same
ones the cloud adapter and the Foundation Models adapter receive. There is no
second tool catalogue.

The model is asked for:

```json
{"tool_calls":[{"name":"createTask","arguments":{"title":"Call the dentist"}}],
 "message":"I'll add that."}
```

The parser is strict (§57): unknown tool name, non-object arguments, too many
calls or unparseable JSON all produce `AIProviderError.invalidResponse`. It
rejects rather than repairs — a model that gets the syntax wrong gets an error
the turn can report, never a best guess at which action it meant.

Prose with no envelope is a reply, not a failure. Otherwise every conversational
turn would be an error.

Call identifiers are minted by the app, never taken from the model: a
model-supplied id would be a model-supplied handle into the execution ledger,
which is what stops the same action running twice.

### Chat templates

`llama_chat_apply_template` with the template inside the model file is preferred
— it is the only source of truth still correct for a model released after this
code was written. `LocalChatTemplate` is the fallback for a file carrying none,
covering ChatML, Llama 3, Gemma, Mistral, Phi-3 and labelled plain text.

Gemma and Mistral have no system role, so the system prompt is folded into the
first user turn rather than dropped — dropping it would silently remove every
instruction the assistant runs on.

A model whose catalog entry says `toolSupport: unsupported` is never shown the
protocol at all, and the UI says "Chat only" (§55, §56).

---

## 7a. Download, load and selection are three things

The rule, stated once because it is the one most easily reintroduced: **a
completed download does not load the model, does not select it, and does not
change which assistant answers** (§15, §16). The convenient thing to write is
`download(); load(); select()`, and it looks helpful right up until a phone with
three downloaded models is holding two gigabytes it was never asked to hold,
answering from a model nobody picked.

Three separate states, three separate controls:

| State | What it means | Row says |
| --- | --- | --- |
| Downloaded | The file is on disk and verified | `Downloaded · Not loaded` |
| Loaded | The weights are in memory | `Loaded · Not in use` |
| Selected | This is what answers the next message | `Loaded · In use` |

`LocalModelRowPresenter` derives what each row says and which of Download,
Cancel, Use, Load, Unload, Retry and Delete it offers. It lives in the package
rather than the view because `iOS/` has no test target and this is a table with
a silent wrong answer in every cell — a Load button on a model whose file is
missing looks exactly like one on a model that will load.

Retry means the thing that failed: another *load* after a load failure, another
*download* after a transfer failure. Re-fetching two gigabytes because a load
ran out of memory is the wrong repair and an expensive one.

`LocalTurnPreflight` decides what pressing Send does when Local AI is chosen:
proceed, load first (with a named "Loading Qwen3 1.7B…" on screen, because an
anonymous spinner during a two-gigabyte mmap is what made Send look frozen), or
refuse with a sentence and a route to Manage Models. It never downloads, and it
never falls back to the cloud — §128, asserted as a test.

---

## 8. Testing

`MockLocalModelRuntime` scripts load success, load failure, text, tool calls,
malformed output, cancellation and out-of-memory. CI never downloads a model
and never runs real inference (§88, §89).

GGUF fixtures are *generated* — `GGUFFixture` writes a valid header in a few
hundred bytes. A repository with a hundred-megabyte model in it is a repository
every clone pays for forever (§90).

The mock renders its tool envelopes through `LocalToolPromptAdapter`'s own
renderer, so a test that scripts a tool call exercises the real parser rather
than a shortcut around it.

---

## 9. What is not done here

Real-device performance. Tokens per second, first-token latency, peak RAM,
sustained thermals and battery are questions only a real iPhone answers, and
nothing in this codebase claims a figure for any of them (§121). See the
"Real-device performance validation remaining" section of the Part 10 report.

Also deliberately absent, per §116 and §126–§128: model conversion or
quantization on device, a Hugging Face browser, a cloud vector service, and any
silent fallback from a failed local turn to a remote model.
