# Metis Action Dataset v1

Part 4 dataset package for the Dedicated Metis Action Model System.

## Files
- `train.jsonl` — 30,000 semantic-action training examples
- `validation.jsonl` — 3,000 semantic-action validation examples
- `test.jsonl` — 4,000 held-out semantic-action examples
- `adversarial.jsonl` — 1,000 hard examples (600 valid actions + 400 safe-failure cases)
- `router-train.jsonl` — 20,000 CHAT/ACTION examples
- `router-validation.jsonl` — 2,000 router validation examples
- `router-test.jsonl` — 3,000 router test examples
- `golden_eval.jsonl` — 500 candidate golden evaluation examples; manually audit before treating as the final golden benchmark
- `protocol_v1.json` — exact model-facing protocol snapshot
- `record_schema.json` — dataset record schema
- `feedback_record_schema.json` — future like/dislike/edit personalization record schema
- `validate_dataset.py` — protocol, structure, duplicate and leakage checks
- `dataset_stats.py` — summary statistics
- `export_sft.py` — model-neutral SFT exporter for Part 5
- `VALIDATION_REPORT.txt` — generated validation results
- `checksums.sha256` — integrity hashes

## Training policy
Train only from `train.jsonl` and `router-train.jsonl`. Use validation files for early stopping/tuning. Never train on test, adversarial or golden evaluation files.

The semantic model learns only six action intents and six user-level fields defined in `protocol_v1.json`. It must never learn UUIDs, EventKit IDs, absolute timestamps, list/calendar names, notes, priorities or other app-owned implementation details.

`safe_failure` records are evaluation-only because Protocol v1 has no model-emittable failure intent on the constrained ACTION path. `export_sft.py` excludes them from SFT.

Router and semantic-action datasets are deliberately separate responsibilities.

The bulk data is deterministic synthetic/template data. It is useful for initial training and is structurally validated, but before production the candidate golden set should be manually audited and supplemented with consented real-world held-out utterances.

Validate with:
```bash
python validate_dataset.py
python dataset_stats.py
```

Export for Part 5:
```bash
python export_sft.py train.jsonl action-sft.jsonl --task semantic_action
python export_sft.py router-train.jsonl router-sft.jsonl --task router
```
Apply the chosen base model's tokenizer/chat template during Part 5; this dataset intentionally remains model-neutral.
