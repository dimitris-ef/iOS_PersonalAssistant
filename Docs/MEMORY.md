# Personal memory

What the assistant remembers, and how it decides what to bring back.

## The problem this solves

Memory used to be retrieved by keyword overlap and capped by a settings number.
That produced two failures at once: a question about a bill could arrive at the
model carrying the user's camera preference, and a question about leaving for
work could miss the commute time because it shared no literal word with the
request.

Both are the same mistake — treating "what do I know?" as the question, when the
question is "what is worth knowing *right now*?"

## The chain

```
user request
      ↓
ContextAssembler          orchestration: profile, tasks, events, memories
      ↓
MemoryRetrievalService    loads candidates, delegates the judgement
      ↓
MemoryRanker              scores, thresholds, bounds
      ↓
MemoryContextFormatter    concise, provider-neutral lines
      ↓
AIRequest → whichever provider is selected
```

No provider is asked which memories matter. Retrieval is local, deterministic
and offline, so it behaves identically with the remote model, the Apple model, a
local model, the scripted stand-in and in CI.

## Ranking

Five factors, weighted in `MemoryRelevancePolicy` — one value type, so tuning
retrieval means editing one file:

| Factor | Weight | What it asks |
| --- | --- | --- |
| Relevance | 1.0 | Does this relate to the request? |
| Salience | 0.25 | Does it matter generally? |
| Confidence | 0.2 | Is it even true? |
| Category | 0.2 | Is this kind of memory likely to help here? |
| Recency | 0.15 | How fresh is it? |

Relevance dominates by design. The others reorder things that are *already* on
topic; none can carry an unrelated memory into the prompt on its own.

**Recency decays gently** — a 180-day half-life with a floor of 0.25. A commute
time learned a year ago must still beat yesterday's note about shampoo, or the
assistant gets worse the longer it knows someone.

**Category is a thumb on the scale, not a gate.** A scheduling question prefers
routines and places; a reminder question prefers preferences. A memory of the
"wrong" category that genuinely matches the words still ranks, because people do
not file their lives the way an enum does. Intent detection is a handful of cue
words (`MemoryQueryIntent`), and anything unrecognised is `.general`, which
weights every category equally.

## Relevance

`MemorySemanticMatcher` is the abstraction; `LexicalSemanticMatcher` is today's
implementation. Four things lift it above exact overlap:

- **Normalisation and stemming**, so "leaving for work" finds "drive to work".
- **Directional coverage** — how much of the *query* the memory explains, not
  how much of a long memory the query covers. Verbose memories are not punished
  for being detailed.
- **Bigram bonus**, so "get ready" beats a memory mentioning "get" and "ready"
  separately.
- **Shared durations**, because "how long" questions and memories about
  durations are usually about the same thing.

It is deliberately not a natural-language library: a few hundred bytes of rules
that behave identically everywhere, run offline, and can be read in one sitting.

## Selection

Ordering is not enough — what reaches the prompt is what matters.

1. Score every candidate.
2. Drop anything below `minimumScore` (0.18).
3. Take at most `maximumMemories` (5), or the user's `memoryContextLimit` if
   lower.
4. Stop at `characterBudget` (600 characters), skipping any single memory too
   long to fit rather than letting it block shorter ones.

**The quota is not a target.** If one memory is relevant, one is sent. If none
is, the memory section is omitted entirely — not replaced with "no memories
found", which is just something for the model to remark on.

## What the model sees

```
# What you remember about this person
- [Routine] I usually need 45 minutes to get ready for work
- [Place] Work is normally 30 minutes from home
```

Identifiers, confidence, salience, timestamps and source labels are **not** sent.
They decide what gets selected; telling the model would spend context on nothing
useful and invite it to reason about them ("you said you were only 60%
sure..."). The model gets facts.

## Trust

`MemorySource` records how a memory was learned, and confidence defaults follow
from it — centralised on the enum, so "how much do we trust an inference?" has
one answer:

| Source | Confidence | Meaning |
| --- | --- | --- |
| `manual` | 1.0 | Typed into the Memory screen |
| `user` | 0.95 | Said in conversation |
| `legacy` | 0.8 | Stored before the app recorded provenance |
| `observation` | 0.75 | Derived from repeated behaviour |
| `assistant` | 0.6 | Inferred by the model |

Confidence and salience are different questions and often opposites. "My
girlfriend's name is Anna" is near-certain and rarely relevant; "probably
prefers evening workouts" is worth acting on and might be wrong.

## Writing memories

Everything goes through `MemoryService` — the Memory screen, the assistant's
`storeMemory` tool, and the demo seeder. Deduplication behind a single door or
it does not exist: put it in the tool and the screen creates duplicates, put it
in the screen and the assistant does.

### Deduplication

`MemoryDeduplicator` classifies a candidate as exact duplicate, near duplicate,
conflicting, or distinct. The bias is conservative: storing a redundant memory
costs a little context, but merging away a real distinction loses something the
user said.

Three guards, in order:

1. **Qualifiers.** "Commute takes 30 minutes" and "commute takes 45 minutes
   during rush hour" are both true. A conditional word on one side and not the
   other means they are left alone, whatever the word overlap.
2. **Quantities.** Same subject, different duration, means the facts disagree —
   a conflict to resolve, never a duplicate to discard.
3. **Similarity.** Only then does strong overlap mean "said twice".

There is a fourth path worth naming because it is a workaround. "It takes me 30
minutes to drive to work" and "my commute to work is roughly half an hour" share
one content word; no lexical matcher can see they are the same statement. What
connects them is that they are the same category, about the same subject, and
name the same quantity (written durations are normalised — "half an hour" is
1800 seconds). Requiring all three keeps it conservative. **This is a stand-in
for semantic matching, and the first thing to replace when a real matcher
exists.**

### Conflicts

One rule, on the only evidence available: a newer *explicit* statement replaces
an older one in place, keeping the identifier. Anything weaker is stored
alongside, where the user can see the disagreement and delete the wrong one.
Not a truth-maintenance system, and not trying to be.

### Edits and deletes

A user edit is authoritative and **never** deduplicated — they are changing that
exact record, and folding their edit into a similar memory would look like the
app refusing to save. It becomes `.manual` with full confidence.

Deletes are final. A deleted memory is gone from the repository, never ranked,
never injected, and stays gone after relaunch. Nothing recreates memories from
cached ranking state.

Nothing is hidden: inferred memories appear in the Memory screen like any other
and can be deleted there.

## Persistence

`MemoryItem` gained one field, `confidence`. Schema **V3** adds
`SDMemory.confidenceValue` as a nullable column, migrated by an inferred
`.lightweight` stage.

A row written before V3 has no recorded confidence, so the mapper derives one
from the `source` it *did* record — an explicit statement stays trusted, an
inference stays less so. Better evidence than a blanket default, and it keeps
the distinction the app had already made. An unrecognised source becomes
`.legacy`, trusted enough not to drop out of ranking. Nothing is deleted.

`MemoryItem` remains storage-independent: no `@Model`, no SwiftData import.

## Privacy

Memories are the most sensitive data in the app.

- **Nothing logs memory content.** No production logging of memories, ranking
  candidates or selected context.
- **`MemoryScoreBreakdown` is for tests and tuning.** It carries the memory it
  scored, so it never travels to a model, into a log, or into the UI.
- **Only selected memories reach a provider**, and only their text and category.

## Performance

Candidates are loaded and scored in full. For the sizes this app deals in —
hundreds of memories, low thousands at worst — that is microseconds, once per
turn. `MemoryTextProfile` is built once per comparison rather than per factor,
so scoring is linear in the number of memories.

Deliberately no vector database, search engine or index. If scoring ever stops
being cheap, the fix is a term-overlap prefilter before scoring, not a different
architecture. Pre-filtering by category would be faster and wrong: a "when
should I leave" question is answered by a `place` memory that shares no cue word
with it.

## Future: on-device embeddings

The extension point is `MemorySemanticMatcher`. A better matcher is a new
conformance and nothing else — `ContextAssembler`, the repositories, the
providers and the ranker are all written against the protocol.

Any implementation has to honour three constraints, because memory cannot depend
on them being met:

- **No network.** Retrieval runs before every turn, including offline ones.
- **No API key.** Memory must work with the Apple and local providers, and in CI.
- **A synchronous answer.** Ranking happens inside assembling one request; it
  cannot become a second round trip.

The shape that satisfies all three: compute an embedding when a memory is
*written*, store it alongside the row, and compare vectors at query time. That
makes retrieval a dot product and keeps the write path the only place a model is
involved. Apple's `NLEmbedding` is the obvious first candidate; a small
quantised sentence model bundled with the app is the next.

When that lands, the duration-plus-subject rule in `MemoryDeduplicator` should be
the first thing reconsidered — it exists precisely because lexical matching
cannot see paraphrase.
