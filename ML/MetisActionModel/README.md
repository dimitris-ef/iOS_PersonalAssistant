# Metis Action Model

Training material for the dedicated action model that Part 3 built the app-side
support for. Nothing in this directory ships in the iOS app, and nothing here is
compiled — it is outside `Sources/`, `Tests/` and `iOS/`, so neither Swift
Package Manager nor XcodeGen can see it.

## What is here

| Path | Contents |
| --- | --- |
| `Dataset/v1/` | The Metis Action Dataset v1 package — 63,500 records, its protocol snapshot, schemas, validator and statistics scripts |

## Models

Weights do not live in this repository — a model is hundreds of megabytes, and
git keeps every version forever. They are published as GitHub release assets
and listed in the app's catalog (`Sources/AIProviderLocal/Resources/local-models.json`)
with their size and SHA-256, so the phone verifies what it downloads.

| Model | Where | SHA-256 |
| --- | --- | --- |
| Metis Action 0.8B v0.1 (Qwen 3.5 0.8B, Q4_K_M, 529 MB) | `dimitris-ef/0.8b-training-001`, release `prerealse` | `e9ed51432be2140b93cd6232ef6b2aaddcecaf626d9a56020aacf4d07e10fa63` |

How it scores, and what the app changed because of it: `Docs/ACTION-ROUTING.md`
§12. In short, 85% right action on the golden set as the app now runs it, with
the remaining misses mostly on wording the training data never used.

Two things about the data, found while measuring it:

- **`Dataset/v1/train.jsonl` here is the original v1 file.** The model was most
  likely trained on the curated v2 file in `0.8b-training-001` (29,933
  records), which is cleaner and more varied. Bringing v2 in is a separate,
  pending decision.
- **Every `golden_eval.jsonl` action record starts with "Evaluation wording: "**,
  a generator artefact no training file contains. Strip it before scoring, or
  the exam measures the stray prefix rather than the model.

## What is not here

No training code, LoRA adapters or tokenizer files, and no Core ML conversion.
The v0.1 model was trained outside this repository.

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
against it will emit actions the app rejects. Re-verify before every training
round.

The training *format* is a contract too. The app now sends a model trained on
this protocol the bare sentence — no system prompt, no instruction page — as
`export_sft.py` frames it. A future round that trains with a system prompt
would need the app changed to match, or it will lose accuracy rather than gain
it.

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
on, and how to export for training.
