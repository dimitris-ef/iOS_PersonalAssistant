#!/usr/bin/env python3
from pathlib import Path
import argparse,json
ap=argparse.ArgumentParser(); ap.add_argument('input'); ap.add_argument('output'); ap.add_argument('--task',choices=['semantic_action','router'],required=True); a=ap.parse_args(); n=0
with Path(a.input).open(encoding='utf-8') as fi,Path(a.output).open('w',encoding='utf-8') as fo:
 for line in fi:
  if not line.strip(): continue
  r=json.loads(line)
  if r['task']!=a.task: continue
  if a.task=='semantic_action':
   if r.get('expected_behavior')!='emit_action': continue
   out={'prompt':r['input'],'completion':json.dumps(r['target'],ensure_ascii=False,separators=(',',':')),'id':r['id']}
  else: out={'prompt':r['input'],'completion':r['target'],'id':r['id']}
  fo.write(json.dumps(out,ensure_ascii=False,separators=(',',':'))+'\n'); n+=1
print('wrote',n,'records')
