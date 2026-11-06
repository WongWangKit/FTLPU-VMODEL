"""Capacity arithmetic and an independent reduced MoE model. NOT CModel, RTL or a cycle scheduler."""
import argparse,hashlib,json,math,shutil
from pathlib import Path
import numpy as np
EXP=Path(__file__).resolve().parents[1];FPGA=EXP.parents[1]

def bf16(x):
    a=np.asarray(x,dtype=np.float32);u=a.view(np.uint32)
    return ((u+np.uint32(0x7fff)+((u>>16)&1))&np.uint32(0xffff0000)).view(np.float32)

def quantize(w):
    n,k=w.shape;assert n%8==k%8==0
    t=w.reshape(n//8,8,k//8,8).transpose(0,2,1,3)
    peak=np.max(np.abs(t),axis=(2,3))
    scales=bf16(np.where(peak==0,np.float32(1),peak/127))
    q=np.clip(np.rint(t/scales[:,:,None,None]),-127,127).astype(np.int8)
    deq=bf16(q.astype(np.float32)*scales[:,:,None,None])
    return q,scales,deq.transpose(0,2,1,3).reshape(n,k)

def softmax(x):
    e=np.exp(x-np.max(x,axis=-1,keepdims=True));return e/np.sum(e,axis=-1,keepdims=True)

def routes(logits,k):
    # Demo tie policy: smaller expert ID wins. HF topk tie behavior is not assumed.
    ids=np.argsort(-logits,axis=-1,kind='stable')[...,:k]
    return ids,bf16(softmax(np.take_along_axis(logits,ids,axis=-1)))

def capacity(c):
    d,f,L,E,k,V,h,kv=[c[x] for x in ['hidden_size','intermediate_size','num_hidden_layers','num_local_experts','num_experts_per_tok','vocab_size','num_attention_heads','num_key_value_heads']]
    hd=d//h;attn=2*d*d+2*d*kv*hd;expert=3*d*f;router=d*E
    norms=2*d*L+d;embed=V*d
    params=L*(attn+E*expert+router)+norms+embed
    pack=L*(attn+E*expert);scales=pack//64*2;unquant=(router*L+norms+embed)*2
    rows={str(s):2*L*s*kv*hd*2 for s in [24,32,64,128]}
    per_token=L*(attn+k*expert+router)+V*d
    stream_bytes=L*((attn+k*expert)*33//32+router*2)+embed*2
    return dict(parameters=params,all_bf16_weight_bytes=params*2,w8_matrix_bytes=pack,scale_bf16_bytes=scales,
      bf16_router_norm_tied_embedding_bytes=unquant,mixed_weight_bytes=pack+scales+unquant,
      one_expert_w8_bytes=expert,one_expert_scale_bytes=expert//64*2,
      layer_w8_matrix_bytes=attn+E*expert,active_experts_w8_bytes=k*expert,
      kv_cache_bytes=rows,decode_linear_MACs=per_token,decode_attention_MACs_at_context24=2*L*24*d,
      prefill16_linear_MACs_no_all_token_lm_head=16*L*(attn+k*expert+router)+V*d,
      no_cache_decode_weight_stream_bytes=stream_bytes,
      illustrative_weight_stream_lower_bound_ms_at_GBps={str(b):stream_bytes/(b*1e9)*1000 for b in [0.125,1,8,16]},
      tile128_w8_bytes=128*128,tile128_scale_bytes=128*128//64*2,tile128_dequant_bf16_bytes=128*128*2,
      prefill16_route_count=16*k,prefill16_routed_input_bytes=16*k*d*2,
      prefill16_worst_tokens_per_expert=16,
      mem_group_plan=dict(group_bytes=131072,total_groups=26,kv_groups=12,weight_staging_groups=4,scratch_groups=6,reserve_groups=4),
      caveat='Byte-capacity plan only. No bank/port schedule, SRAM placement, real-weight accuracy or throughput validation.')

class TinyMoE:
    def __init__(self,seed=20261104):
        self.d,self.f,self.L,self.E,self.k,self.h,self.kv,self.V=128,256,2,4,2,4,2,512
        r=np.random.default_rng(seed);self.hd=self.d//self.h
        self.emb=bf16(r.normal(0,.04,(self.V,self.d)));self.layers=[]
        def w(n,k):return quantize(bf16(r.normal(0,.04,(n,k))))[2]
        for i in range(self.L):
            self.layers.append(dict(q=w(self.d,self.d),k=w(self.kv*self.hd,self.d),v=w(self.kv*self.hd,self.d),o=w(self.d,self.d),router=bf16(r.normal(0,.04,(self.E,self.d))),experts=[(w(self.f,self.d),w(self.f,self.d),w(self.d,self.f)) for _ in range(self.E)]))
    def lin(self,x,w):return bf16(np.einsum('tk,nk->tn',x,w,optimize=False))
    def norm(self,x):return bf16(x/np.sqrt(np.mean(x*x,axis=-1,keepdims=True)+1e-6))
    def rope(self,x,pos):
        angles=np.asarray(pos)[:,None]/(1500000.0**(np.arange(0,self.hd,2)/self.hd))[None,:]
        co=np.cos(angles).astype(np.float32)[:,None,:];si=np.sin(angles).astype(np.float32)[:,None,:]
        a,b=x[...,:self.hd//2],x[...,self.hd//2:]
        return bf16(np.concatenate([a*co-b*si,b*co+a*si],axis=-1))
    def forward(self,tokens,cache=None):
        if cache is None:cache=[None]*self.L
        x=bf16(self.emb[tokens]*12);newcache=[];routing=[]
        for li,w in enumerate(self.layers):
            n=self.norm(x);old=cache[li];start=0 if old is None else len(old[0]);positions=np.arange(start,start+len(tokens))
            q=self.rope(self.lin(n,w['q']).reshape(-1,self.h,self.hd),positions)
            key=self.rope(self.lin(n,w['k']).reshape(-1,self.kv,self.hd),positions)
            val=self.lin(n,w['v']).reshape(-1,self.kv,self.hd)
            if old is not None:key=np.concatenate([old[0],key]);val=np.concatenate([old[1],val])
            newcache.append((key,val));kk=np.repeat(key,self.h//self.kv,axis=1);vv=np.repeat(val,self.h//self.kv,axis=1)
            scores=np.einsum('thd,shd->hts',q,kk,optimize=False)/np.float32(self.hd)
            mask=np.arange(len(key))[None,:]<=positions[:,None]
            scores=np.where(mask[None,:,:],scores,-np.inf)
            probs=bf16(softmax(scores));a=np.einsum('hts,shd->thd',probs,vv,optimize=False).reshape(-1,self.d)
            x=bf16(x+np.float32(.22)*self.lin(bf16(a),w['o']))
            n=self.norm(x);ids,gates=routes(self.lin(n,w['router']).astype(np.float32),self.k);routing.append(ids)
            y=np.zeros_like(n)
            for t in range(len(tokens)):
                for slot,e in enumerate(ids[t]):
                    wg,wu,wd=w['experts'][e];g=self.lin(n[t:t+1],wg);u=self.lin(n[t:t+1],wu)
                    hidden=bf16(bf16(g/(1+np.exp(-g)))*u)
                    y[t]+=self.lin(hidden,wd)[0]*gates[t,slot]
            x=bf16(x+np.float32(.22)*bf16(y))
        logits=np.einsum('tk,nk->tn',self.norm(x),self.emb,optimize=False)/np.float32(6)
        return logits,newcache,routing

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--run',required=True);a=ap.parse_args();assert a.run.replace('_','').isalnum()
    out=EXP/'results'/a.run;out.mkdir();shutil.copy2(__file__,out/'braincheck.py')
    c=json.loads((EXP/'results/baseline001/granite_config.json').read_text(encoding='utf-8-sig'))
    cap=capacity(c);assert cap['kv_cache_bytes']['32']==1572864
    gp=cap['mem_group_plan'];assert sum(gp[x] for x in ['kv_groups','weight_staging_groups','scratch_groups','reserve_groups'])==gp['total_groups']
    assert gp['group_bytes']*gp['total_groups']==3407872
    (out/'capacity.json').write_text(json.dumps(cap,indent=2))
    r=np.random.default_rng(20261104);tests=[]
    def check(name,condition,**metrics):
        tests.append(dict(name=name,passed=bool(condition),**metrics))
    check('bf16_known',bool(np.array_equal(bf16([1,2,-1,.5]),[1,2,-1,.5])))
    q,s,dq=quantize(np.zeros((16,16),np.float32));check('zero_weight_block',np.all(q==0) and np.all(dq==0) and np.all(s==1))
    w=bf16(r.normal(0,.2,(128,128)));q,s,dq=quantize(w)
    check('int8_range_and_block_shape',q.min()>=-127 and q.max()<=127 and s.shape==(16,16))
    x=bf16(r.normal(0,.3,(16,128)));ref=x@dq.T;blocked=np.zeros_like(ref)
    for n in range(0,128,16):
        for k in range(0,128,16):blocked[:,n:n+16]+=x[:,k:k+16]@dq[n:n+16,k:k+16].T
    err=float(np.max(np.abs(blocked-ref)));check('gemm16_capacity_tiling_vs_quantized_dense',np.allclose(blocked,ref,rtol=1e-4,atol=1e-5),max_abs_error=err)
    ids,g=routes(np.zeros((16,4),np.float32),2);check('stable_tie_and_dropless_worst_bucket',np.all(ids==[0,1]) and np.all(np.bincount(ids.ravel(),minlength=4)==[16,16,0,0]))
    tiny=TinyMoE();tokens=r.integers(0,tiny.V,24).tolist()
    full,_,full_routes=tiny.forward(tokens)
    first,cache,_=tiny.forward(tokens[:16]);outputs=[first];observed=[]
    for i in range(16,24):
        y,cache,rr=tiny.forward(tokens[i:i+1],cache);outputs.append(y);observed.append(rr)
    sequential=np.concatenate(outputs);error=float(np.max(np.abs(full-sequential)))
    # Same independent model under two execution decompositions; not RTL equivalence.
    check('two_layer_prefill16_decode8_vs_causal_full',np.allclose(full,sequential,rtol=2e-3,atol=2e-3),max_abs_error=error)
    check('decode_routes_agree',all(np.array_equal(observed[j][i][0],full_routes[i][j+16]) for j in range(8) for i in range(2)))
    check('kv_cache_lengths',all(len(k)==24 and len(v)==24 for k,v in cache))
    check('finite_outputs',np.isfinite(full).all())
    cache=None;generated=tokens[:16].copy()
    y,cache,_=tiny.forward(generated)
    for i in range(8):
        token=int(np.argmax(y[-1]));generated.append(token);y,cache,_=tiny.forward([token],cache)
    check('greedy_smoke_eight_tokens',len(generated)==24 and np.isfinite(y).all())
    np.savez_compressed(out/'tiny_evidence.npz',tokens=tokens,full_logits=full,sequential_logits=sequential,generated=generated)
    result=dict(passed=all(t['passed'] for t in tests),tests=tests,numpy_version=np.__version__,seed=20261104,
        model=dict(layers=2,hidden=128,intermediate=256,experts=4,top_k=2,heads=4,kv_heads=2,vocab=512),
        generated_token_ids=generated[16:],teacher_forced_tokens=tokens,
        limitations=['Independent NumPy brain model, not RTL or CModel','Deterministic synthetic weights, no downloaded trained weights or language-quality validation','Not bit-exact legacy floating point; GEMM comparison uses tolerances','No cycle/port/conflict schedule proof'])
    (out/'brain_results.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(dict(capacity=cap,brain=result),indent=2));raise SystemExit(0 if result['passed'] else 1)

if __name__=='__main__':main()
