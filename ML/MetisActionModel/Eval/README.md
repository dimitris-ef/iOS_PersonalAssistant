# Evaluating a Metis action model off-device

How Metis Action 0.8B v0.1 was measured (results: `Docs/ACTION-ROUTING.md` §12,
raw numbers: `baseline-v0.1-golden.json`). Re-run this for every new model
before it ships, and compare against the baseline.

| File | What it does |
| --- | --- |
| `metis_grammar.py` | Python port of the app's grammar (`SemanticActionGrammar.swift`) and action prompt. `gbnf(True)` = the app's current any-order changes rule; `gbnf(False)` = the old fixed order. **Must be kept in step with the Swift.** |
| `run_eval.py` | Asks the model every action question in a dataset file through llama-server and scores it. Modes A–F = (instruction page / bare sentence / bare + empty think block) × (old / current grammar). **The app today = mode D.** |
| `gguf_label.py` | Reads a GGUF's header (architecture, size, context, chat template) without dependencies |
| `grammar_check.py` | Runs every training answer through llama.cpp's own grammar checker |

## Steps (Linux, about 10 minutes of setup)

```bash
# 1. llama.cpp at the version the app pins (b10506), CPU build
git clone --depth 1 --branch b10506 https://github.com/ggml-org/llama.cpp
cmake -S llama.cpp -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
cmake --build build -j --target llama-server

# 2. The model, from its GitHub release (see the catalog for URL + SHA-256)

# 3. Serve it the way the phone runs it: no Jinja (the app uses
#    llama_chat_apply_template), the action policy's context and batches
build/bin/llama-server -m model.gguf --no-jinja -c 1024 -b 128 -ub 64 -t 2 --port 8080

# 4. The exam
python3 run_eval.py --data ../Dataset/v1/golden_eval.jsonl --strip-golden-prefix \
    --modes D --out golden.jsonl
```

Limits to state with any result: CPU, not Metal (scores close, speed not
comparable); the grammar and prompt are Python copies of the Swift.
