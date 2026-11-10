from pathlib import Path
import subprocess,sys,json,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False)
original=ROOT/'learn/sxm_mem_bankstriped_20261109/scripts/check_schedule.js'
s=original.read_text().split('function checkRead(B)')[0]
s=s.replace('const check = (T,M,fp32)=>{','''const check = (T,M,fp32,mapped=false,negative=0)=>{
if(![2,4,8].includes(T)||M<1||M*T>1024)throw Error('admission range');
const map=Array.from({length:T},(_,a)=>mapped?T-1-a:a);
const inv=Array.from({length:T},(_,d)=>map.indexOf(d));
const lanes=Array.from({length:8},(_,l)=>mapped?(l*3+1)%8:l);
''')
s=s.replace('let n=k-d;', 'let n=k-inv[d];')
s=s.replace('sl.data[r*8+q]','sl.data[lanes[r]*8+q]')
s=s.replace('${e.a}/${st}', '${map[e.a]}/${st}')
s=s.replace('word(e.m,e.a,e.s,e.r,q)', 'word(e.m,e.a,e.s,e.r,q)')
s=s.replace('word(m,d,s,r,q)', 'word(m,inv[d],s,lanes[r],q)')
s=s.replace("traffic.set(key,{arr,tag:e,q,b});", "if(!(negative===1 && e.m===0 && e.a===0 && e.s===0 && q===0 && b===0))traffic.set(key,{arr,tag:e,q,b});")
s=s.replace("roots.set(key,{addr:n,stream:g*8+bank,issue:time});", "roots.set(key,{addr:n+(negative===2?1:0),stream:g*8+bank,issue:time});")
# In addition to matching every present stream, enforce exact expected bytes.
s=s.replace("if(seen.size!==traffic.size)", "if(writes!==M*T*T*8*B)throw Error('missing target Tap');\nif(seen.size!==traffic.size)")
s+='''
const runs=[],negative=[];
for(const T of [2,4,8])for(const fp of [false,true])for(const M of [1,2,3,32,100]){
 runs.push({...check(T,M,fp),mapped:false,status:'PASS_MODEL'});
 if(M===3)runs.push({...check(T,M,fp,true),mapped:true,status:'PASS_MODEL'});
}
for(const T of [2,4,8])for(const fault of [1,2]){
 try{check(T,2,true,false,fault);throw Error('negative unexpectedly accepted');}
 catch(e){if(e.message==='negative unexpectedly accepted')throw e;negative.push({T,fault,rejected:true,error:e.message});}
}
fs.writeFileSync(process.argv[2],JSON.stringify({scope:'Independent model, NOT RTL',runs,negative},null,2));
console.log('PASS_MODEL',runs.length,'negative',negative.length);
'''
script=out/'model.js';script.write_text(s)
(out/'manifest.json').write_text(json.dumps(dict(generator=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),source=hashlib.sha256(original.read_bytes()).hexdigest(),generated=hashlib.sha256(script.read_bytes()).hexdigest()),indent=2))
p=subprocess.run(['node',str(script),str(out/'summary.json')],capture_output=True,text=True)
(out/'run.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr);raise SystemExit(p.returncode)
