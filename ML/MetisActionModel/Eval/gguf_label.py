"""Minimal GGUF header reader (no dependencies), mirroring what
Sources/AIProviderLocal/GGUFHeader.swift extracts, plus an exact parameter
count from the tensor table. Reads only the front of the file, like the app.
"""
import struct, sys
from collections import Counter

FILE_TYPES = {0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1",
              10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M",
              16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K", 32: "BF16"}
TENSOR_TYPES = {0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1", 8: "Q8_0",
                10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K", 14: "Q6_K", 30: "BF16"}

class R:
    def __init__(self, b): self.b, self.p = b, 0
    def take(self, fmt):
        v = struct.unpack_from("<" + fmt, self.b, self.p); self.p += struct.calcsize("<" + fmt)
        return v[0]
    def string(self):
        n = self.take("Q"); s = self.b[self.p:self.p + n]; self.p += n
        return s.decode("utf-8", "replace")
    SCALARS = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}
    def value(self, t):
        if t in self.SCALARS: return self.take(self.SCALARS[t])
        if t == 8: return self.string()
        if t == 9:
            et, n = self.take("I"), self.take("Q")
            items = [self.value(et) for _ in range(n)]
            return ("<array>", et, n, items[:3])
        raise ValueError(f"unknown type {t}")

def main(path):
    with open(path, "rb") as f:
        data = f.read(32 * 1024 * 1024)  # GGUFReader.inspectionWindowBytes
    r = R(data)
    assert data[:4] == b"GGUF", "not a GGUF file"
    r.p = 4
    version, n_tensors, n_kv = r.take("I"), r.take("Q"), r.take("Q")
    kv = {}
    for _ in range(n_kv):
        k = r.string(); t = r.take("I"); kv[k] = r.value(t)
    params, types = 0, Counter()
    for _ in range(n_tensors):
        name = r.string(); nd = r.take("I")
        dims = [r.take("Q") for _ in range(nd)]
        tt = r.take("I"); r.take("Q")
        n = 1
        for d in dims: n *= d
        params += n; types[TENSOR_TYPES.get(tt, str(tt))] += n
    arch = kv.get("general.architecture", "?")
    def a(suffix): return kv.get(f"{arch}.{suffix}")
    print(f"GGUF version        {version}")
    print(f"tensors             {n_tensors}")
    for k in ("general.name", "general.basename", "general.size_label", "general.finetune",
              "general.base_model.0.name", "general.base_model.0.organization",
              "general.base_model.0.repo_url", "general.license", "general.quantized_by"):
        if k in kv: print(f"{k:<20}{kv[k]}")
    print(f"architecture        {arch}")
    print(f"file type           {FILE_TYPES.get(kv.get('general.file_type'), kv.get('general.file_type'))}")
    print(f"parameters          {params:,}  ({params/1e9:.3f} B)")
    print(f"weights by type     " + ", ".join(f"{t} {n/params:.0%}" for t, n in types.most_common()))
    print(f"trained context     {a('context_length')}")
    print(f"layers (blocks)     {a('block_count')}")
    print(f"embedding length    {a('embedding_length')}")
    print(f"kv heads            {a('attention.head_count_kv')}")
    tok = kv.get("tokenizer.ggml.model"); vocab = kv.get("tokenizer.ggml.tokens")
    print(f"tokenizer           {tok}, vocab {vocab[2] if isinstance(vocab, tuple) else '?'}")
    for k in ("tokenizer.ggml.bos_token_id", "tokenizer.ggml.eos_token_id", "tokenizer.ggml.add_bos_token"):
        if k in kv: print(f"{k:<20}{kv[k]}")
    tmpl = kv.get("tokenizer.chat_template")
    print(f"chat template       {'present, ' + str(len(tmpl)) + ' chars' if tmpl else 'ABSENT'}")
    other = sorted(k for k in kv if not k.startswith(("tokenizer.ggml.tokens", "tokenizer.ggml.merges",
                                                    "tokenizer.ggml.token_type", "tokenizer.ggml.scores")))
    print("all metadata keys   " + ", ".join(other))
    if tmpl and "--template" in sys.argv:
        print("\n----- chat template -----\n" + tmpl + "\n----- end -----")

if __name__ == "__main__":
    main(sys.argv[1])
