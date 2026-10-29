#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/llm-server/results}"
TP1_BENCH="${TP1_BENCH:-$ROOT/tp1/bench-concurrency-tp1.csv}"
TP2_BENCH="${TP2_BENCH:-$ROOT/tp2/bench-concurrency-tp2.csv}"
TP1_GPU0="${TP1_GPU0:-$ROOT/tp1/xpu-concurrency-tp1-gpu0.csv}"
TP2_GPU0="${TP2_GPU0:-$ROOT/tp2/xpu-concurrency-tp2-gpu0.csv}"
TP2_GPU1="${TP2_GPU1:-$ROOT/tp2/xpu-concurrency-tp2-gpu1.csv}"
OUT_CSV="${OUT_CSV:-$ROOT/comparison.csv}"
OUT_MD="${OUT_MD:-$ROOT/comparison.md}"
for f in "$TP1_BENCH" "$TP2_BENCH"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }; done
python3 - "$TP1_BENCH" "$TP2_BENCH" "$TP1_GPU0" "$TP2_GPU0" "$TP2_GPU1" "$OUT_CSV" "$OUT_MD" <<'PY'
import csv, math, os, re, statistics, sys
from pathlib import Path
p1,p2,x10,x20,x21,outcsv,outmd=sys.argv[1:]
def n(v):
    if v is None:return None
    s=str(v).strip()
    if not s or s.lower() in {'n/a','na','nan','none','-','null'}:return None
    s=s.replace('%','').replace('MiB','').replace('MHz','').replace('W','').strip()
    try:
        x=float(s);return x if math.isfinite(x) else None
    except:return None
def f(v,d=2):return 'N/A' if v is None else f'{v:.{d}f}'
def pc(a,b):return None if a in (None,0) or b is None else (b/a-1)*100
def pr(a,b):return None if a in (None,0) or b is None else (1-b/a)*100
def cc(s):
    m=re.search(r'\(c(\d+)\)',s);return int(m.group(1)) if m else 1
def bench(path):
    o={}
    with open(path,newline='') as fh:
        for r in csv.DictReader(fh):
            c=cc(r['test_name']);o.setdefault(c,{})
            if r['test_name'].startswith('pp'):o[c].update(pp=n(r.get('t_s_mean')),ppr=n(r.get('t_s_req_mean')),ttft=n(r.get('e2e_ttft_mean') or r.get('ttfr_mean')),ppt=n(r.get('est_ppt_mean')))
            elif r['test_name'].startswith('tg'):o[c].update(tg=n(r.get('t_s_mean')),tgr=n(r.get('t_s_req_mean')),peak=n(r.get('peak_ts_mean')))
    return o
PAT={'power':[r'power.*draw',r'gpu.*power',r'power.*\(w\)'],'memory':[r'memory.*used'],'mempct':[r'memory.*util'],'freq':[r'frequency',r'clock.*graphics']}
def xpu(path):
    if not os.path.isfile(path):return {'ok':False}
    with open(path,newline='',errors='replace') as fh:
        rd=csv.DictReader(fh); names=rd.fieldnames or []; mp={}
        for h in names:
            lo=h.lower()
            for k,ps in PAT.items():
                if k not in mp and any(re.search(p,lo) for p in ps):mp[k]=h
        vals={k:[] for k in PAT}
        for r in rd:
            for k,h in mp.items():
                v=n(r.get(h))
                if v is not None:vals[k].append(v)
    o={'ok':True}
    for k,v in vals.items():o[k+'avg']=statistics.mean(v) if v else None;o[k+'peak']=max(v) if v else None
    return o
a,b=bench(p1),bench(p2);g10,g20,g21=xpu(x10),xpu(x20),xpu(x21);cs=sorted(set(a)|set(b))
def knee(d):
    z=sorted(c for c in d if d[c].get('tg') is not None)
    for x,y in zip(z,z[1:]):
        gain=(d[y]['tg']/d[x]['tg']-1)*100
        if gain<5:return x,y,gain
k1,k2=knee(a),knee(b)
with open(outcsv,'w',newline='') as fh:
    cols=['concurrency','tp1_pp_tps','tp2_pp_tps','pp_gain_pct','tp1_tg_tps','tp2_tg_tps','tg_gain_pct','tp1_tg_req_tps','tp2_tg_req_tps','tp1_ttft_ms','tp2_ttft_ms','ttft_reduction_pct'];w=csv.DictWriter(fh,fieldnames=cols);w.writeheader()
    for c in cs:
        x,y=a.get(c,{}),b.get(c,{})
        w.writerow(dict(concurrency=c,tp1_pp_tps=x.get('pp'),tp2_pp_tps=y.get('pp'),pp_gain_pct=pc(x.get('pp'),y.get('pp')),tp1_tg_tps=x.get('tg'),tp2_tg_tps=y.get('tg'),tg_gain_pct=pc(x.get('tg'),y.get('tg')),tp1_tg_req_tps=x.get('tgr'),tp2_tg_req_tps=y.get('tgr'),tp1_ttft_ms=x.get('ttft'),tp2_ttft_ms=y.get('ttft'),ttft_reduction_pct=pr(x.get('ttft'),y.get('ttft'))))
md=['# TP=1 vs TP=2 Comparison','','| C | TP1 PP | TP2 PP | PP gain | TP1 TG | TP2 TG | TG gain | TP1 TTFT ms | TP2 TTFT ms | TTFT reduction |','|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
for c in cs:
    x,y=a.get(c,{}),b.get(c,{})
    md.append(f"| {c} | {f(x.get('pp'))} | {f(y.get('pp'))} | {f(pc(x.get('pp'),y.get('pp')),1)}% | {f(x.get('tg'))} | {f(y.get('tg'))} | {f(pc(x.get('tg'),y.get('tg')),1)}% | {f(x.get('ttft'))} | {f(y.get('ttft'))} | {f(pr(x.get('ttft'),y.get('ttft')),1)}% |")
Path(outmd).write_text('\n'.join(md)+'\n')
USE=sys.stdout.isatty() and os.environ.get('NO_COLOR') is None;R='\033[0m' if USE else '';CY='\033[96m' if USE else '';GR='\033[92m' if USE else '';YE='\033[93m' if USE else '';BD='\033[1m' if USE else ''
def color(s,c):return f'{c}{s}{R}' if USE and c else str(s)
def vl(s):return len(re.sub(r'\x1b\[[0-9;]*m','',str(s)))
def pad(s,w,a='<'):
 s=str(s);q=max(0,w-vl(s));return (' '*q+s) if a=='>' else ((' '*(q//2)+s+' '*(q-q//2)) if a=='^' else s+' '*q)
def line(w=106,ch='='):print('+'+ch*w+'+')
def title(s):line();print('|'+pad(color(s,BD+CY),106,'^')+'|');line()
def msg(s,c=None):print('|'+pad(' '+color(s,c),106)+'|')
def sep(ws,ch='-'):print('+'+'+'.join(ch*(w+2) for w in ws)+'+')
def row(v,ws,al=None):
 al=al or ['<']*len(ws);print('|'+'|'.join(' '+pad(x,w,z)+' ' for x,w,z in zip(v,ws,al))+'|')
print();title('Qwen3.8-27B-FP8 | TP=1 vs TP=2');msg('Workload: PP512 / TG128 | llama-benchy + XPU-SMI');line();print();title('PERFORMANCE COMPARISON');ws=[5,28,28,36];sep(ws);row(['C','TP=1','TP=2','TP=2 vs TP=1'],ws,['^']*4);sep(ws,'=')
for c in cs:
 x,y=a.get(c,{}),b.get(c,{})
 tg='N/A' if not x.get('tg') or y.get('tg') is None else f"{y['tg']/x['tg']:.2f}x ({pc(x['tg'],y['tg']):+.1f}%)"
 pp='N/A' if not x.get('pp') or y.get('pp') is None else f"{y['pp']/x['pp']:.2f}x ({pc(x['pp'],y['pp']):+.1f}%)"
 tt='N/A' if not x.get('ttft') or y.get('ttft') is None else f"-{pr(x['ttft'],y['ttft']):.1f}%"
 row([f'C{c}',f"TG {f(x.get('tg'))} tok/s",f"TG {f(y.get('tg'))} tok/s",tg],ws);row(['',f"PP {f(x.get('pp'))} tok/s",f"PP {f(y.get('pp'))} tok/s",pp],ws);row(['',f"TTFT {f(x.get('ttft'))} ms",f"TTFT {f(y.get('ttft'))} ms",tt],ws);row(['',f"TG/req {f(x.get('tgr'))}",f"TG/req {f(y.get('tgr'))}",''],ws);sep(ws)
print();title('SATURATION ANALYSIS');msg(f'TP=1 | Knee C{k1[0]} -> C{k1[1]}, TG change {k1[2]:+.1f}%.',YE) if k1 else msg('TP=1 | Saturation not detected.',YE);msg(f'TP=2 | Knee C{k2[0]} -> C{k2[1]}, TG change {k2[2]:+.1f}%.',YE) if k2 else msg('TP=2 | Saturation NOT reached at highest concurrency tested.',GR);line();print();title('GPU TELEMETRY');ws2=[10,7,15,15,17,20];sep(ws2);row(['Topology','GPU','Avg Power','Peak Power','Peak Memory','Avg Memory Util'],ws2,['^']*6);sep(ws2,'=')
def tr(t,g,d):row([t,g,f(d.get('poweravg'))+' W' if d.get('ok') and d.get('poweravg') is not None else 'N/A',f(d.get('powerpeak'))+' W' if d.get('ok') and d.get('powerpeak') is not None else 'N/A',f(d.get('memorypeak'))+' MiB' if d.get('ok') and d.get('memorypeak') is not None else 'N/A',f(d.get('mempctavg'))+' %' if d.get('ok') and d.get('mempctavg') is not None else 'N/A'],ws2,['^','^','>','>','>','>'])
tr('TP=1','GPU 0',g10);sep(ws2);tr('TP=2','GPU 0',g20);tr('TP=2','GPU 1',g21);sep(ws2);msg('N/A means unavailable; it is never treated as zero.');line();print();title('TAKEAWAY');common=sorted(set(a)&set(b))
if common:
 c=max(common);x,y=a[c],b[c]
 if x.get('tg') and y.get('tg'):msg(f"At C{c}, TP=2 delivered {y['tg']/x['tg']:.2f}x total decode throughput.",GR)
 if x.get('pp') and y.get('pp'):msg(f"At C{c}, TP=2 delivered {y['pp']/x['pp']:.2f}x prompt-processing throughput.",GR)
 r=pr(x.get('ttft'),y.get('ttft'))
 if r is not None:msg(f'At C{c}, TP=2 reduced TTFT by {r:.1f}%.',GR)
if k1:msg('TP=1 reaches a throughput plateau beyond its useful concurrency knee.',YE)
if not k2:msg('TP=2 was still scaling at the highest concurrency tested.',GR)
line();print();print(f'CSV report:      {outcsv}');print(f'Markdown report: {outmd}');print()
PY
