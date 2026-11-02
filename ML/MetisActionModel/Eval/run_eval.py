"""Evaluate a Metis action model through llama-server, the way the app would use it.

Modes (prompt x grammar):
  A  app system prompt + app's current grammar   (what the phone does today)
  B  app system prompt + relaxed changes grammar (Problem 1 fix)
  C  bare sentence     + app's current grammar   (training-like framing)
  D  bare sentence     + relaxed changes grammar

Server must be started with --no-jinja so the chat template goes through
llama_chat_apply_template, the same C function LlamaCppRuntime calls.
Temperature 0 and a 192-token cap match ActionInferenceProductionPolicy.
"""
import argparse, json, random, re, sys, time, urllib.request
from collections import Counter, defaultdict

sys.path.insert(0, __import__("os").path.dirname(__file__))
from metis_grammar import gbnf, ACTION_SYSTEM_PROMPT  # noqa: E402

GRAMMARS = {"strict": gbnf(False), "relaxed": gbnf(True)}
MODES = {"A": (True, "strict"), "B": (True, "relaxed"), "C": (False, "strict"), "D": (False, "relaxed"),
         # E/F: bare sentence with the model's own answer opening (empty think block), as the
         # model's Jinja template renders it with thinking off — the training-faithful framing.
         "E": ("think", "strict"), "F": ("think", "relaxed")}

THINK_PROMPT = "<|im_start|>user\n{s}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
FIELDS = ["title", "timeExpression", "content", "targetDescription", "durationExpression", "locationExpression"]


def norm(v):
    return re.sub(r"[.!?,;:]+$", "", re.sub(r"\s+", " ", str(v).strip().lower()))


def ask(server, sentence, use_system, grammar):
    if use_system == "think":
        body = json.dumps({"prompt": THINK_PROMPT.format(s=sentence), "grammar": GRAMMARS[grammar],
                           "temperature": 0, "n_predict": 192, "seed": 0, "cache_prompt": True}).encode()
        req = urllib.request.Request(server + "/completion", body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.load(r)["content"], {}
    messages =([{"role": "system", "content": ACTION_SYSTEM_PROMPT}] if use_system else [])
    messages.append({"role": "user", "content": sentence})
    body = json.dumps({"messages": messages, "grammar": GRAMMARS[grammar], "temperature": 0,
                       "max_tokens": 192, "seed": 0, "cache_prompt": True}).encode()
    req = urllib.request.Request(server + "/v1/chat/completions", body,
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        out = json.load(r)
    return out["choices"][0]["message"]["content"], out.get("usage", {})


def score(target, raw):
    """Returns a dict of judgements for one prediction."""
    res = {"parsed": False, "intent": False, "exact": False, "lost_changes": 0, "extra_changes": 0,
           "field_hits": {}, "field_miss": {}}
    try:
        pred = json.loads(raw)
    except Exception:
        return res
    res["parsed"] = True
    res["intent"] = pred.get("intent") == target["intent"]
    ta, pa = target.get("arguments", {}), pred.get("arguments", {}) or {}
    tc, pc = target.get("requestedChanges", {}) or {}, pred.get("requestedChanges", {}) or {}
    for f in FIELDS:
        for scope, t, p in (("arg", ta, pa), ("chg", tc, pc)):
            if f in t or f in p:
                k = f"{scope}.{f}"
                if f in t and f in p and norm(t[f]) == norm(p[f]):
                    res["field_hits"][k] = 1
                else:
                    res["field_miss"][k] = 1
    res["lost_changes"] = sum(1 for k in tc if k not in pc)
    res["extra_changes"] = sum(1 for k in pc if k not in tc)
    res["exact"] = (res["intent"] and {k: norm(v) for k, v in ta.items()} == {k: norm(v) for k, v in pa.items()}
                    and {k: norm(v) for k, v in tc.items()} == {k: norm(v) for k, v in pc.items()})
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://127.0.0.1:8080")
    ap.add_argument("--data", required=True)
    ap.add_argument("--modes", default="ABCD")
    ap.add_argument("--per-intent", type=int, default=0, help="stratified sample size per intent (0 = all)")
    ap.add_argument("--only-multi-change", action="store_true", help="calendar.update with 2+ changes only")
    ap.add_argument("--out", required=True)
    ap.add_argument("--strip-golden-prefix", action="store_true",
                    help='remove the stray "Evaluation wording: " prefix every golden_eval.jsonl '
                         'action record carries (a generator artefact no training file contains)')
    a = ap.parse_args()

    rows = [json.loads(l) for l in open(a.data, encoding="utf-8") if l.strip()]
    if a.strip_golden_prefix:
        for r in rows:
            if r["input"].startswith("Evaluation wording: "):
                r["input"] = r["input"][len("Evaluation wording: "):]
    rows = [r for r in rows if r.get("task") == "semantic_action" and r.get("expected_behavior") == "emit_action"]
    if a.only_multi_change:
        rows = [r for r in rows if len(r["target"].get("requestedChanges") or {}) > 1]
    if a.per_intent:
        by = defaultdict(list)
        for r in rows:
            by[r["target"]["intent"]].append(r)
        rng = random.Random(0)
        rows = [x for k in sorted(by) for x in rng.sample(by[k], min(a.per_intent, len(by[k])))]

    summary = {}
    with open(a.out, "w", encoding="utf-8") as fo:
        for m in a.modes:
            use_system, grammar = MODES[m]
            agg, fh, fm, per_intent, t0 = Counter(), Counter(), Counter(), defaultdict(Counter), time.time()
            for i, r in enumerate(rows, 1):
                raw, usage = ask(a.server, r["input"], use_system, grammar)
                s = score(r["target"], raw)
                for k in ("parsed", "intent", "exact"):
                    agg[k] += s[k]
                agg["lost_changes"] += s["lost_changes"]
                agg["extra_changes"] += s["extra_changes"]
                fh.update(s["field_hits"]); fm.update(s["field_miss"])
                per_intent[r["target"]["intent"]]["n"] += 1
                per_intent[r["target"]["intent"]]["exact"] += s["exact"]
                fo.write(json.dumps({"mode": m, "id": r["id"], "input": r["input"], "target": r["target"],
                                     "raw": raw, "score": {k: s[k] for k in ("parsed", "intent", "exact",
                                     "lost_changes", "extra_changes")}}, ensure_ascii=False) + "\n")
                if i % 50 == 0:
                    print(f"  [{m}] {i}/{len(rows)} exact={agg['exact']/i:.1%} ({time.time()-t0:.0f}s)", flush=True)
            n = len(rows)
            summary[m] = {
                "n": n, "seconds": round(time.time() - t0),
                "valid_json": agg["parsed"] / n, "intent_acc": agg["intent"] / n, "exact_match": agg["exact"] / n,
                "lost_changes": agg["lost_changes"], "extra_changes": agg["extra_changes"],
                "per_intent_exact": {k: v["exact"] / v["n"] for k, v in sorted(per_intent.items())},
                "field_acc": {k: fh[k] / (fh[k] + fm[k]) for k in sorted(set(fh) | set(fm))},
            }
            print(json.dumps({m: summary[m]}, indent=1), flush=True)
    json.dump(summary, open(a.out.replace(".jsonl", ".summary.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
