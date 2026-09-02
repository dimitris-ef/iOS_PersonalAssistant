# Metis Action Model

Training material for the dedicated action model that Part 3 built the app-side
support for. Nothing in this directory ships in the iOS app, and nothing here is
compiled — it is outside `Sources/`, `Tests/` and `iOS/`, so neither Swift
Package Manager nor XcodeGen can see it.

## What is here

| Path | Contents |
| --- | --- |
| `Dataset/v1/` | The Metis Action Dataset v1 package — 63,500 records, its protocol snapshot, schemas, validator and statistics scripts |

## What is not here

Training. No weights, no LoRA adapters, no tokenizer, no Core ML conversion, no
benchmark harness. **That is Part 5.** Part 4 is the dataset landing in the
repository, verified against the protocol the app actually enforces.

Nor is there any personalization data. `Dataset/v1/feedback_record_schema.json`
is a *format specification* for a possible future like/dislike/edit signal; no
record of that kind exists in this repository, and per
`Dataset/v1/PERSONALIZATION.md` such feedback is meant to stay on the user's
device.

## The protocol is the contract

`Dataset/v1/protocol_v1.json` is a snapshot of the model-facing protocol defined
in Swift by `LocalSemanticIntent`, `LocalSemanticField`, `LocalSemanticContract`
and `LocalSemanticActionSchema` (`Sources/AssistantAI/Actions/`). Six action
intents, six user-level fields, and the per-intent required / optional /
changeable sets.

It was verified equal to those Swift definitions when the dataset was added. If
the Swift protocol ever changes — a new intent, a new field, a field moving
between required and optional — this snapshot is stale, and a model trained
against it will emit actions the app rejects. Re-verify before Part 5 trains
anything.

The snapshot deliberately omits the `chat` intent, matching
`LocalSemanticActionSchema.universal`, which filters to `isAction`: the
constrained path is entered only after the router has already decided the
message is an action, so a grammar that permits "no action" would let the model
decline by mistake. CHAT/ACTION routing is a separate task with its own
`router-*.jsonl` files.

## Verifying it

```bash
cd Dataset/v1
python3 validate_dataset.py    # must print DATASET VALID
python3 dataset_stats.py
sha256sum -c checksums.sha256
```

The validator checks structure, per-intent field legality, duplicate ids,
duplicate inputs, and that no `timeExpression` has been resolved to an absolute
timestamp. Note that it validates against `protocol_v1.json`, not against the
Swift source — so a passing validator says the data matches the snapshot, and it
is the snapshot that has to be checked against the app.

See `Dataset/v1/DATASET.md` for the training policy, which files may be trained
on, and how to export for Part 5.
