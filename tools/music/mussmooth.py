"""Fine spectral trajectories for slow filter LFOs. No oscillator duplication.

The dictionary is built in a common gain and phase, at the existing loop size;
nearest-state transitions are checked in sampled waveform space. Compact one
carrier period permits more states under the same page budget.
"""
import math,copy
import musdsp

def install(owner,z,budget):
 import mussc as m
 per,f0,ls,H,nc,L,Rp,phase=z.morph_basis
 # Only used LFO regions, not an incidental harmonic basis on another zone.
 if not any(r.mod_lfo_fc for r in z.notes[0].layers):return
 phase0=2*math.pi*nc*phase/L
 cycles = max(nc if L == 255 else 1,min(8,max(1,int(255*f0*z.s_mid/16000))))
 # Fast filter-envelope transients belong in sampled attacks, not a pair
 # of held loop states. Detect their actual spectral change before choosing
 # a representation; retain the existing path when it is already small.
 first=min(z.attack/n.sp for n in z.notes)
 settle=max([sum(r.mod_env[:4]) for r in z.notes[0].layers
             if abs(r.mod_to_fc)>=1200 and sum(r.mod_env[:4])<.12] or [0.])
 bake=False
 if settle>first:
  saved=(list(z.mix_pow),z.mix_M)
  a,_=owner.mixed_harmonics(z,per,f0,ls,H,time=first)
  b,_=owner.mixed_harmonics(z,per,f0,ls,H,time=settle+.02)
  z.mix_pow,z.mix_M=saved
  relative=sum((x-y)**2 for x,y in zip(a,b))/max(1e-12,sum(x*x for x in a))
  bake=relative>.01
 if bake:
  # Several carrier periods lower the sampled attack rate while retaining
  # every audible harmonic. The attack and loop still use one frequency.
  cycles=max(cycles,min(8,max(1,int(255*f0*z.s_mid/16000))))
 newrate=255*f0/cycles
 if bake:
  z.attack=(settle+.025)*z.s_max
  saved=(list(z.mix_pow),z.mix_M)
  source=owner.mix_attack(z,int((z.attack+.03*z.s_max)*z.r.sample.rate)+64,z.s_mid,
                          sorted(n.vel for n in z.notes)[len(z.notes)//2])
  z.mix_pow,z.mix_M=saved
  att=musdsp.resample(source,z.r.sample.rate,newrate,taps=24)
 else:
  att=musdsp.resample(z.float_tab,Rp,newrate,taps=12)
 z.rate=newrate;z.loop_len=256;z.morph_basis=None
 size=256
 while size<len(att):size*=2
 z.size=size
 end=min(20.,max((n.stop-n.on)*m.TIC for n in z.notes))
 first=min(z.attack/n.sp for n in z.notes)
 times=[i*2*m.TIC for i in range(int(end/(2*m.TIC))+2) if i*2*m.TIC>=first]
 if not times:times=[first]
 saved=(list(z.mix_pow),z.mix_M)
 # Cache source partials once; mixed_harmonics caches these in z.mix_cache.
 amps=[]
 for t in times:
  a,ph=owner.mixed_harmonics(z,per,f0,ls,H,time=t);amps.append(a)
 z.mix_pow,z.mix_M=saved
 base,ph=owner.mixed_harmonics(z,per,f0,ls,H)
 z.mix_pow,z.mix_M=saved
 H=min(H,126//cycles)
 def err(a,b):return sum((x-y)**2 for x,y in zip(a[1:H+1],b[1:H+1]))
 selected=[amps[0]]
 # 16 levels replaces the former pair. Smooth physical LFO trajectories
 # need only a few additional wakes per second, not one per sample.
 z.table=bytes(size);z.ltable=bytes(256)
 owner.layout()
 count=max(1,min(16,1+budget-(255-owner.low)))
 # A zone whose variation is below the error floor needs no extra state.
 for j in range(count-1):
  i=max(range(len(amps)),key=lambda i:min(err(amps[i],a) for a in selected))
  power=sum(x*x for x in amps[i][1:H+1])
  if min(err(amps[i],a) for a in selected)<max(1e-12,power*1e-5):break
  selected.append(amps[i])
 ids=[]
 for _ in range(6):
  groups=[[] for _ in selected];ids=[]
  for a in amps:
   j=min(range(len(selected)),key=lambda j:err(a,selected[j]));ids.append(j);groups[j].append(a)
  for j,rows in enumerate(groups):
   if j and rows:selected[j]=[sum(row[h] for row in rows)/len(rows) for h in range(len(base))]
 def wave(a):
  x=[sum(a[h]*math.cos(2*math.pi*h*cycles*i/255+h*phase0+ph[h]) for h in range(1,H+1)) for i in range(255)]
  return x+[x[0]]
 loops=[wave(a) for a in selected]
 # Complete the resampled attack with the original steady loop, keeping the
 # phase at its original attack/loop switch. Do not rescale note times.
 # Join the sampled attack to the actual first LFO state, not the mean
 # steady-state spectrum. The former mean-to-first-state jump was much
 # larger than the subsequent fine changes. Finish before the earliest
 # legal attack/loop switch, and fill its scheduling margin with this loop.
 end_blend=max(0,int((z.attack-3*m.TIC*z.s_max)*newrate))
 blend=max(16,int(.012*newrate*z.s_min))
 for i in range(max(0,end_blend-blend),len(att)):
  w=min(1.,max(0.,(i-(end_blend-blend))/blend))
  att[i]=att[i]*(1-w)+loops[0][i%255]*w
 while len(att)<size:att.append(loops[0][len(att)%255])
 peak=max(abs(x) for x in att+[x for loop in loops for x in loop]) or 1
 q8=lambda x:max(1,min(255,128+round(x*127/peak)))
 z.table=bytes(map(q8,att));z.ltable=bytes(map(q8,loops[0]));z.gain=-32*math.log2(peak)
 z.float_tab=att;z.float_lt=loops[0]
 family=[]
 for j,loop in enumerate(loops):
  v=copy.copy(z);v.notes=[];v.name=z.name+'/smooth-filter';v.kind='loop';v.size=v.loop_len=256
  v.morph_basis=None;v.native_basis=None;v.extra_page=True;v.ltable=b''
  if j==0:v.alias_of=z;v.table=b''
  else:v.table=bytes(map(q8,loop));owner.extra_tables.append(v)
  family.append(v)
 z.morph_family=family;z.morph_times=times;z.morph_indices=ids
 z.morph_error=max(err(a,selected[j]) for a,j in zip(amps,ids))
 owner.layout()
 if budget and 255-owner.low>budget:raise ValueError(owner.name+': fine filter trajectory exceeds pages')
