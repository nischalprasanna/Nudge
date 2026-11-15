import csv,sys,math
rows=list(csv.DictReader(open(sys.argv[1]+'/both.csv')))
for r in rows:
    for k in r:
        if k!='method': r[k]=float(r[k])
def q(v,f): v=sorted(v); return v[int((len(v)-1)*f)]
def show(name,sel,keys):
    if len(sel)<5: print(name,'n',len(sel)); return
    for k in keys:
        v=[r[k] for r in sel if r[k]==r[k]]
        print(f"{name:26s} n={len(v):3d} {k:7s} p10 {q(v,.1):6.1f} med {q(v,.5):6.1f} p90 {q(v,.9):6.1f}")
lid=[r for r in rows if r['method']=='lidar']
print('methods:',{m:sum(1 for r in rows if r['method']==m) for m in set(r['method'] for r in rows)})
show('image, all',rows,['along','across','dxmm','dymm'])
show('on screen (mm), lidar',lid,['du','dv'])
d=[math.hypot(r['du'],r['dv']) for r in lid]
print(f"on-screen distance from tracker (mm): median {q(d,.5):.1f} p75 {q(d,.75):.1f} p90 {q(d,.9):.1f} p95 {q(d,.95):.1f} max {max(d):.1f}")
for a,b,n in [(0,205,'dim 9/0'),(206,414,'dim Start'),(415,617,'bright 9/0'),(618,799,'bright Start')]:
    show(n,[r for r in lid if a<=r['i']<=b],['du','dv'])
