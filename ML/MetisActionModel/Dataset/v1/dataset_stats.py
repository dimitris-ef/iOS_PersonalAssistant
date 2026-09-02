#!/usr/bin/env python3
from pathlib import Path
import json
from collections import Counter
R=Path(__file__).resolve().parent
for fn in ['train.jsonl','validation.jsonl','test.jsonl','adversarial.jsonl','router-train.jsonl','router-validation.jsonl','router-test.jsonl','golden_eval.jsonl']:
 rows=[json.loads(x) for x in (R/fn).read_text(encoding='utf-8').splitlines() if x.strip()]; print(f'\n{fn}: {len(rows)}'); sa=[r for r in rows if r['task']=='semantic_action']; rr=[r for r in rows if r['task']=='router'];
 if sa: print('  intents:',dict(Counter((r.get('target') or {}).get('intent','SAFE_FAILURE') for r in sa)))
 if rr: print('  routes:',dict(Counter(r['target'] for r in rr)))
