#!/usr/bin/env python3
from pathlib import Path
import json,re,sys
from collections import Counter
ROOT=Path(__file__).resolve().parent; P=json.loads((ROOT/'protocol_v1.json').read_text()); INT=P['intents']; F=set(P['fields']); ISO=re.compile(r'^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2})?'); FILES=['train.jsonl','validation.jsonl','test.jsonl','adversarial.jsonl','router-train.jsonl','router-validation.jsonl','router-test.jsonl','golden_eval.jsonl']
def norm(s): return re.sub(r'[.!?]+$','',re.sub(r'\s+',' ',s.strip().lower()))
def ct(r,w):
 t=r.get('target'); b=r.get('expected_behavior');
 if b=='safe_failure': assert t is None,f'{w}: safe failure target'; return
 assert b=='emit_action' and isinstance(t,dict),f'{w}: action target'; i=t.get('intent'); assert i in INT,f'{w}: intent'; a=t.get('arguments'); assert isinstance(a,dict),f'{w}: args'; c=INT[i]; req=set(c['required']); allow=req|set(c['optional']); assert set(a)<=allow,f'{w}: illegal args';
 for x in req: assert x in a and isinstance(a[x],str) and a[x].strip(),f'{w}: missing {x}'
 for k,v in a.items(): assert k in F and isinstance(v,str) and v.strip(),f'{w}: field'; assert not(k=='timeExpression' and ISO.match(v.strip())),f'{w}: timestamp'
 ch=t.get('requestedChanges',{});
 if i=='calendar.update': assert isinstance(ch,dict) and ch and set(ch)<=set(c['changeable']),f'{w}: changes'
 else: assert not ch,f'{w}: unexpected changes'
def main():
 ids=set(); seen={'semantic_action':{},'router':{}}; errs=[]; C=Counter()
 for fn in FILES:
  for ln,line in enumerate((ROOT/fn).open(encoding='utf-8'),1):
   if not line.strip(): continue
   w=f'{fn}:{ln}'
   try:
    r=json.loads(line); rid=r['id']; task=r['task']; inp=r['input']; assert rid not in ids,f'{w}: duplicate id'; ids.add(rid); assert task in seen,f'{w}: task'; n=norm(inp); assert n not in seen[task],f'{w}: duplicate input with {seen[task].get(n)}'; seen[task][n]=w
    if task=='semantic_action': ct(r,w); C[(fn,r.get('expected_behavior'))]+=1
    else: assert r.get('target') in ('CHAT','ACTION'),f'{w}: route'; C[(fn,r['target'])]+=1
   except Exception as e: errs.append(str(e))
 if errs:
  print('DATASET INVALID'); [print('-',x) for x in errs[:100]]; return 1
 print('DATASET VALID'); [print(f'{k[0]:28s} {k[1]:12s} {C[k]}') for k in sorted(C)]; print('unique ids:',len(ids)); print('unique semantic_action inputs:',len(seen['semantic_action'])); print('unique router inputs:',len(seen['router'])); return 0
if __name__=='__main__': raise SystemExit(main())
