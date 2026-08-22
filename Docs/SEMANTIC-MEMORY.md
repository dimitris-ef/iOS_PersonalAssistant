# Semantic memory

Recalling by meaning, consolidating what repeats, and forgetting carefully.

`MEMORY.md` describes the memory system Part 3 built: categories, confidence,
source, salience, recency, deduplication and a bounded prompt budget. This
describes what Part 9 added on top of it. Nothing there was replaced.

## The sentence this exists for

> Stored: *It usually takes me about half an hour to drive to work.*
> Asked: *How long should I allow for my commute?*

Two content words in common, at best — and one of them is a preposition. Lexical
overlap cannot connect these, and no amount of stemming will. What connects them
is that they are about the same thing.

---

## 1. The shape

```
user request
      ↓
ContextAssembler              orchestration; knows nothing about vectors
      ↓
MemoryRetrievalService        candidates, cached vectors, one query vector
      ↓
MemoryRanker                  hybrid score, threshold, count, budget
      ↓
AIRequest → whichever provider is selected
```

Unchanged from Part 3, deliberately. Semantic retrieval slotted in behind
`MemoryRetrievalService` because that is what the layer was for.

---

## 2. Provider independence

**The conversational provider is never the embedding service.** This is the
hardest requirement in the memory system and it is worth being explicit about
why: using the remote model to index memories would mean uploading the user's
entire memory store to a third party in order to search it. Not a selected
subset, chosen for relevance — all of it, on a schedule.

So `SemanticEncoder` is its own abstraction, composed at launch, and nothing in
retrieval reads which AI provider is selected. Switching from the on-device model
to a cloud one changes which model writes the reply and nothing about what the
assistant can recall.

```swift
protocol SemanticEncoder: Sendable {
    var identity: SemanticEncoderIdentity { get }
    var isAvailable: Bool { get async }
    func embedding(for text: String) async throws -> SemanticVector
}
```

---

## 3. The two local encoders

| | `AppleNaturalLanguageEncoder` | `LexiconSemanticEncoder` |
| --- | --- | --- |
| What | `NLEmbedding.sentenceEmbedding` | Text projected onto everyday concepts |
| Where | `PersonalMemoryApple` | `PersonalMemory` |
| Available | Apple platforms with a model | Everywhere, always |
| Quality | Real sentence embeddings | Concept overlap, no more |

`SemanticEncoderResolver.best()` picks Apple's where the device has it and the
lexicon encoder otherwise — never neither, because a device with no encoder would
fall back to lexical ranking for its whole life and the lexicon encoder is a good
deal better than that at no cost.

### Why `NaturalLanguage` and not a Core ML model

It is on every supported device, needs no download, no entitlement, no network
and no credential. A bundled embedding model would be better at nuance and would
cost tens of megabytes, a conversion pipeline and a second thing to keep working
across OS versions — for a store of a few hundred sentences about somebody's
commute. Swapping one in later is a new conformance and a version bump; that is
what the protocol is for.

### Why the lexicon encoder is real code and not a test double

Because a mock that returns "similar" for the pair a test names is a test of the
mock. The lexicon encoder is deterministic, offline, and the same code that runs
on a device with no Apple model — so an assertion against it is an assertion
about behaviour somebody will actually get. It is also the reason the whole
memory architecture still builds and tests on Linux.

Each dimension is a concept a personal assistant actually deals in — travelling,
working, getting ready, money, people, health — plus a block of hashed dimensions
so words outside the lexicon still tell two texts apart. *Commute*, *drive* and
*work* point at the same few concepts, which is what makes the example at the top
of this document work.

---

## 4. Hybrid ranking

Meaning is **added** to the existing signals, not put in their place.

```
finalScore =
      1.0  × semantic          cosine, 0…1
    + 0.7  × lexical           shared words, phrases, durations
    + 0.3  × sourceTrust       said > typed-by-us > observed > inferred
    + 0.25 × salience
    + 0.2  × confidence
    + 0.2  × categoryAffinity
    + 0.15 × recency
    + 0.1  × relationBoost     one hop, best neighbour only
    − 0.5  × conflictPenalty
```

Every weight lives in `MemoryRelevancePolicy`. There is no threshold constant
anywhere else in the system.

### Why cosine does not get the whole decision

Section 8's example says it best. To a vector model, "the user said their commute
is 30 minutes" and "the app guessed it might be 20" are the same sentence. Cosine
cannot see who said it, when, or how sure anyone was. Those are what the other
weights answer, and they are the difference between a memory system and a search
index.

### The gate

A memory reaches the prompt only if it is **on topic** — and there are two ways
to be, either of which will do:

```
lexical ≥ 0.05   OR   semantic ≥ 0.34
```

The disjunction is the whole of Part 9's promise. Requiring both would reject
exactly the memory semantic retrieval was added for. Requiring only meaning would
lose the case a vector model is worst at: an exact phrase it has never seen.

And the threshold is not optional. A vector model always returns *some*
similarity, so "the top three matches" is never a selection criterion — there are
always three. "What's the weather?" selects nothing, and that is correct.

---

## 5. Falling back

Every step degrades, and the fallback is the ordinary Part 3 behaviour:

| When | What happens |
| --- | --- |
| No encoder composed in | Lexical ranking |
| Encoder unavailable on this device | Lexical ranking |
| Encoder throws for this text | That memory ranks on words |
| Vector not generated yet | That memory ranks on words |
| Vector stale (edited, or new encoder) | Treated as absent; regenerated later |

`MemoryRelevancePolicy.withoutSemantics` also restores lexical weight to 1.0 when
the semantic channel is off — without that the fallback would not merely be
blinder, every score would drop by the semantic share and the strength threshold
would start rejecting perfectly relevant memories.

---

## 6. The vector cache

Vectors are **derived data**, not domain state. They live beside the memories,
never on `MemoryItem`:

```
SDMemoryEmbedding
  memoryID          one vector per memory
  vector, dimension little-endian floats
  encoderProviderID + encoderVersion
  contentHash       FNV-1a of the normalised text
```

A vector is valid only if **both** the content hash and the encoder identity
match. Each failure means something different and both mean regenerate:

- **Hash changed** — the user edited the memory. The vector describes text they
  no longer believe.
- **Encoder changed** — the vector is in a different space. Comparing it against
  a current one produces a number that looks like a similarity and is noise.

Losing the whole cache costs milliseconds, never information. That is the
property that makes it legitimate for the snapshot backend not to persist it at
all, and for schema migration not to populate it.

### Lazy, never eager

Generation happens on write, on edit, in a bounded backfill during retrieval (12
per turn), and in maintenance (40 per pass). Migration generates **nothing** —
section 105, and the right instruction: a migration that has to encode every
memory in the store is one that can be slow, can fail halfway, and turns a
version bump into a data-loss risk.

Bumping an encoder's version invalidates every stored vector at a stroke. Nobody's
memories are deleted, no launch is blocked, and retrieval carries on with whatever
mixture of fresh vectors and lexical matching it has.

---

## 7. What must never merge

The failure mode of semantic deduplication is losing a distinction the user made.
So four guards run **before** any similarity is consulted, each covering a case a
score would get wrong:

| Guard | Example | Why a vector cannot see it |
| --- | --- | --- |
| **Polarity** | "I like coffee" / "I don't like coffee" | Negation is one function word |
| **Qualifiers** | "…30 minutes" / "…45 minutes during rush hour" | Different situations, both true |
| **Quantities** | "Normal commute 30 min" / "Rush-hour 45 min" | The number *is* the distinction |
| **Entities** | commute to work / walk to the gym | Both are journeys |

Polarity is checked first, and a polarity disagreement can only ever become a
*conflict* — never a duplicate, never a merge.

---

## 8. Consolidation

Three statements of one fact become one active memory, three superseded ones, and
edges joining them.

```
"I take about 30 minutes to get to work."       → superseded
"My commute is usually half an hour."           → superseded   ─ supports →  ┐
"It normally takes 30 minutes to drive to work" → superseded                 │
                                                                             ↓
                         "I take about 30 minutes to get to work."  (active, ×3)
```

**The wording is chosen, never generated.** No model is consulted — and not only
to avoid a network call. A generated summary is a sentence the user never said,
presented in their own memory store as if they had. Picking the clearest
statement they actually made keeps the store truthful and consolidation
deterministic enough to test.

**Confidence rises with agreement, within limits.** Each extra statement adds a
little; the total bonus is capped; and a cluster with no explicit statement in it
cannot climb past 0.85 — below `MemorySource.user.defaultConfidence`, so no pile
of inferences ever reaches the standing of one sentence the user said.

### Loop prevention is structural

Section 100's runaway — A+B→C, then C+A→D, then D+B→E — cannot be *expressed*,
and not because a guard rejects it:

- consolidated memories are excluded from clustering (`isConsolidated`);
- sources leave the pool the moment they become `superseded`.

After one pass there is nothing left for a second pass to see. A fourth statement
arriving later does not restart it either: the write path finds it a near-
duplicate of the active consolidated memory and folds it in, which is where that
belongs.

---

## 9. Lifecycle

```
                 ┌──────────── restore ────────────┐
                 ↓                                 │
   active ──→ stale ──→ archived ───────────────────┘
      │
      ├──→ superseded     replaced by something newer
      └──→ conflicting    disagrees, and the app could not tell which is right
```

Only `active` reaches a prompt. Everything else stays in the store, stays visible
in the Memory screen, and — for `stale` and `archived` — comes back in one tap.

**Nothing here deletes.** Deleting is a thing the user does.

`superseded` and `conflicting` are not "restorable": there is nothing to restore
them *to* while the memory that replaced them stands. The way back is to edit or
delete that one, which is a decision rather than an undo.

---

## 10. Aging

The naive version — *older than N days, delete* — is wrong in both directions at
once. It throws away the commute time somebody stated two years ago while keeping
last month's guess about a café.

So `MemoryAgingPolicy` reads six things, and age is only one:

| Signal | Effect |
| --- | --- |
| Source | Explicit is never archived by age. Inferred fades at 120 days, archived at a year |
| Salience & confidence | Both low is what makes a memory a candidate at all |
| User edit (`isProtected`) | Never aged |
| Supports an active routine | Never aged — the commute behind a live "leave for work" routine is load-bearing |
| Consolidated | Never aged; fading it would fade every statement behind it |
| Recent use | Postpones fading, **capped at 60 days** |

The cap on usage matters. Without it a memory that surfaced once would refresh
its own lease every time it surfaced, and ranking would spend forever defending
its earliest guesses.

Aging never stamps `updatedAt` — that would reset the very clock the next pass
measures, and a memory would become stale, look freshly modified, and never
reach archived.

---

## 11. Relations

Six types, one hop, no inference:

`relatedTo` · `aboutPerson` · `aboutPlace` · `supports` · `refines` ·
`contradicts` · `derivedFrom`

A relation boost is a nudge from the *best single neighbour*, applied once after
scoring, reading only pre-boost scores. Because of that ordering it cannot
propagate: B cannot be lifted by C's boost from D, because C's boost does not
exist yet when B reads it. Retrieval explosion is not something this has to be
careful about; it is something it cannot express.

`contradicts` and `derivedFrom` never boost. Surfacing both sides of a settled
disagreement in one prompt is the behaviour the conflict handling exists to
prevent.

Relation identity is derived from source, target and type — so writing the same
edge on every maintenance pass updates one row.

---

## 12. Maintenance

`MemoryMaintenanceService` runs on foreground, beside the routine and follow-up
reconcilers: **vectors → consolidation → aging**, in that order, because
consolidation reads vectors and aging should see a consolidated fact rather than
the three memories it replaced.

Every operation is idempotent by construction rather than by checking, and every
one is bounded. Nothing here is required for correctness: an app that never calls
it still has a working assistant, just a blunter one.

---

## 13. Privacy

- No memory is sent anywhere to be indexed. Both encoders are on-device.
- No memory store is sent to a model for ranking. Retrieval is local.
- No external vector service, and none is coming.
- Metrics and logs carry counts and durations. Never memory text.
- Score breakdowns exist for tests and debugging and are never shown to the user
  or sent to a provider.

---

## What this deliberately does not do

| Not built | Why |
| --- | --- |
| Cloud vector database | The store is hundreds of sentences on one phone |
| Approximate nearest-neighbour index | Exhaustive comparison is microseconds at this scale, and the seam for one is behind `MemoryRetrievalService` |
| A trained embedding model | `NLEmbedding` is on every device and needs no download |
| LLM-written consolidation | A generated summary is a sentence the user never said |
| A knowledge graph | Six typed edges answer the two questions that mattered |
| An address book | `person:dr_smith` is a string, and there is no record behind it |

---

## Where to look

| Thing | File |
| --- | --- |
| Vectors and cosine | `Sources/PersonalMemory/SemanticVector.swift` |
| The abstraction, versioning, content hash | `Sources/PersonalMemory/SemanticEncoder.swift` |
| The always-available encoder | `Sources/PersonalMemory/LexiconSemanticEncoder.swift` |
| Apple's encoder | `Sources/PersonalMemoryApple/AppleNaturalLanguageEncoder.swift` |
| Weights and thresholds | `Sources/PersonalMemory/MemoryRelevancePolicy.swift` |
| Hybrid scoring | `Sources/PersonalMemory/MemoryRanker.swift` |
| Merge guards | `Sources/PersonalMemory/MemoryDeduplicator.swift` |
| Consolidation | `Sources/PersonalMemory/MemoryConsolidator.swift` |
| Aging | `Sources/PersonalMemory/MemoryAgingPolicy.swift` |
| Retrieval, cache, lazy backfill | `Sources/AssistantCore/MemoryRetrievalService.swift` |
| Maintenance | `Sources/AssistantCore/MemoryMaintenanceService.swift` |
| Schema V7 | `Sources/AssistantPersistenceSwiftData/Schema/PersonalAssistantSchemaV7.swift` |
