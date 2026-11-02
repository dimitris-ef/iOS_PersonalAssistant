import json, os, subprocess, sys, tempfile, random
from concurrent.futures import ThreadPoolExecutor
V, E, DATA = sys.argv[1], sys.argv[2], sys.argv[3]
ORDER = ["title","timeExpression","content","targetDescription","durationExpression","locationExpression"]
rows = [json.loads(l) for l in open(DATA, encoding="utf-8") if l.strip()]
texts = [json.dumps(r["target"], ensure_ascii=False, separators=(",", ":")) for r in rows]
tmp = tempfile.mkdtemp(dir=E)
def check(args):
    i, grammar = args
    p = os.path.join(tmp, f"{i}.txt")
    with open(p, "w", encoding="utf-8") as f: f.write(texts[i])
    out = subprocess.run([V, os.path.join(E, grammar), p], capture_output=True, text=True).stdout
    return i, "is valid" in out
def misordered(t):
    ch = list((t.get("requestedChanges") or {}).keys())
    return bool(ch) and ch != [k for k in ORDER if k in ch]
with ThreadPoolExecutor(4) as ex:
    strict = dict(ex.map(check, [(i, "strict.gbnf") for i in range(len(rows))]))
rejected = [i for i, ok in strict.items() if not ok]
predicted = {i for i, r in enumerate(rows) if misordered(r["target"])}
print(f"records: {len(rows)}")
print(f"APP'S CURRENT RULES  -> rejected {len(rejected)}")
print(f"   rejected set == my 'out of order' prediction: {set(rejected) == predicted}")
other = [i for i in rejected if i not in predicted]
print(f"   rejected for any OTHER reason: {len(other)}")
for i in other[:3]: print("     ", texts[i][:160])
sample = rejected + random.Random(0).sample([i for i in strict if strict[i]], 1000)
with ThreadPoolExecutor(4) as ex:
    relaxed = dict(ex.map(check, [(i, "relaxed.gbnf") for i in sample]))
print(f"WITH THE FIX         -> rejected {sum(not v for v in relaxed.values())} "
      f"(of the {len(rejected)} previously rejected + 1000 random accepted)")
if rejected: print("   example of a previously rejected answer:", texts[rejected[0]][:170])
