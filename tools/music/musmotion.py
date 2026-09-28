"""Compact moving halo timbres into phase-compatible one-period DOC tables.

The old harmonic mean discarded intrinsic sample modulation. Full long
loops preserve it but play slowly in DOC RAM and create zero-order-hold
images. Here offline harmonic snapshots retain the evolving partial levels; fixed
carrier phases allow pointer changes without halting the oscillator. Explicit
pitch LFOs and pitch envelopes are handled separately by mussc.
"""
import cmath
import copy
import math
import os
import bisect
import musdsp


def build(owner, z):
    import mussc as m
    z.mix = owner.mix_of(z)
    if not z.mix:
        return False
    main = z.mix_main
    rate = float(main.sample.rate)
    root = 440 * 2**((z.mix_ref[0]-69)/12) / 2**(main.tune/12)
    L = 255
    R = root * L
    refs = {}
    for n in z.notes:
        refs.setdefault((n.key,n.vel), n)
    end = min(10., max((n.stop-n.on)*m.TIC for n in z.notes))
    # Title: 21 ms timbre steps. VICTOR has short notes and a long stream:
    # retain onset samples, then 150 ms timbre steps to fit its head.
    times = [i*m.TIC for i in (range(8) if owner.name in m.ONCE else (0,1,4))]
    hop = 3 if owner.name in m.ONCE else 21
    times += [i*hop*m.TIC for i in range(1, int(end/(hop*m.TIC))+2)]
    times = sorted(set(times))
    H = min(24, int(.44*rate/root))
    fields = []
    sequences = {}
    attacks = {}
    hybrid = owner.name == "D_INTRO" and os.environ.get("MUSSC_CROSSFADE","1")=="1"
    for key,n in refs.items():
        # A 125 ms window separates neighbouring partials. A six-cycle-only
        # window converted nearby energy into a false 0.6 Hz F3 fluctuation.
        window = max(64, int(6*rate/root), int(.125*rate*n.sp))
        count = int((times[-1]+.05)*rate*n.sp)+window
        x = [0.]*count
        sm = 2**(main.tune/12)
        for r,w in z.mix:
            sl = 2**(r.tune/12)
            step = r.sample.rate/rate * sl/sm
            d = r.sample.data
            pos = float(r.start)
            y=[]
            for i in range(count):
                if r.mode in (1,3) and pos >= r.le:
                    pos = r.ls + (pos-r.le) % (r.le-r.ls)
                k=int(pos)
                y.append(d[k]+(d[min(k+1,r.end-1)]-d[k])*(pos-k) if k<r.end else 0.)
                pos += step
            y=m.biquad_tv(y,rate,lambda i,r=r: (m.fc_hz_of(r,n.vel,i/(rate*n.sp)) or 22000)/n.sp,
                          r.g.get('initialFilterQ',0))
            for i,v in enumerate(y):
                t=i/(rate*n.sp)
                # env_pow describes a held note; the sampled representation
                # must also preserve this layer's delay and linear attack.
                attack=max(0.,min(1.,(t-r.delay)/max(r.attack,1e-9)))
                x[i] += v*math.sqrt(m.env_pow(r,t,main))*attack
        if hybrid:
            # One complete opening attack per key, through the real layered
            # filter/envelope, before the reference synthesizer releases two spare voices.
            out_rate=4095/(152*m.TIC)
            att=musdsp.resample(x[:int(153*m.TIC*rate*n.sp)+32],rate*n.sp,out_rate,taps=24)
            attacks[key]=att[:4096]
        # Use the actual DOC carrier in the analysis. Slowly changing
        # coefficient phase corrects its frequency-register quantization.
        fc=round(512*R*n.sp/m.DOC_RATE)
        carrier=fc*m.DOC_RATE/(512*L*n.sp)
        win=[.5-.5*math.cos(2*math.pi*(j+.5)/window) for j in range(window)]
        norm=2/sum(win)
        basis=[[win[j]*cmath.exp(-2j*math.pi*h*carrier*j/rate)*norm for j in range(window)] for h in range(1,H+1)]
        ids=[]
        for t in times:
            start=int(t*rate*n.sp)-window//2
            segment=[x[i] if 0<=i<len(x) else 0. for i in range(start,start+window)]
            co=[]
            for h,b in enumerate(basis,1):
                if h*root*n.sp > min(owner.q.f_mel, .44*m.DOC_RATE):
                    co.append(0j)
                else:
                    co.append(sum(v*w for v,w in zip(segment,b))*cmath.exp(-2j*math.pi*h*carrier*start/rate))
            ids.append(len(fields));fields.append(co)
        sequences[key]=ids
    # The old, calibrated power-sum spectrum is retained on average; the
    # coefficient magnitudes above retain the motion lost by that old mean.
    per=round(rate/root)
    target,target_phase=owner.mixed_harmonics(z,per,rate/per,main.ls,H)
    rms=[math.sqrt(sum(abs(v[h])**2 for v in fields)/len(fields)) for h in range(H)]
    ratios=[target[h+1]/max(1e-12,rms[h]) for h in range(H)]
    base=ratios[0] or 1.
    gains=[min(4.,max(.25,r/base)) for r in ratios]
    fields=[[v*g for v,g in zip(row,gains)] for row in fields]
    # Hardware Halo upper partials move more deeply than the SF2-derived
    # states. Expand spectral-shape motion only, retaining each frame's
    # total power so the accepted title loudness contour does not change.
    if owner.name == "D_INTRO":
        strength=float(os.environ.get("MUSSC_HALO_CONTRAST","1.5"))
        amps=[math.sqrt(sum(abs(v)**2 for v in row)) for row in fields]
        norms=[[abs(v)/max(a,1e-12) for v in row] for row,a in zip(fields,amps)]
        means=[math.exp(sum(math.log(max(1e-6,row[h])) for row in norms)/len(norms)) for h in range(H)]
        affected={i for key,ids in sequences.items() if key[0]==53 for i in ids}
        for i,(row,a) in enumerate(zip(fields,amps)):
            if i not in affected:continue
            expanded=[v*(max(1e-6,norms[i][h])/max(1e-6,means[h]))**(strength-1 if h>=2 else 0) for h,v in enumerate(row)]
            k=a/max(1e-12,math.sqrt(sum(abs(v)**2 for v in expanded)))
            fields[i]=[v*k for v in expanded]
    # Factor out carrier phase and overall level before clustering. Otherwise
    # two equivalent waves half a cycle apart can select the silent entry.
    levels=[]
    aligned=[]
    for row in fields:
        amp=math.sqrt(sum(abs(v)**2 for v in row))
        aligned.append([abs(v)*cmath.exp(1j*target_phase[h+1])/max(amp,1e-12) for h,v in enumerate(row)])
        levels.append(amp)
    z.frame_scale=max(levels) or 1.
    z.hybrid_attacks={}
    if hybrid:
        for key,att in attacks.items():
            seq=sequences[key];amps=[levels[i] for i in seq]
            normalized=[]
            for j,x in enumerate(att):
                t=j/out_rate;i=max(0,min(len(times)-2,bisect.bisect_right(times,t)-1))
                f=(t-times[i])/(times[i+1]-times[i])
                amp=max(.01*z.frame_scale,amps[i]*(1-f)+amps[i+1]*f)
                normalized.append(x/amp)
            z.hybrid_attacks[key]=normalized
    z.frame_levels={key:[-20*math.log10(max(1e-9,levels[i]/z.frame_scale)) for i in seq]
                    for key,seq in sequences.items()}
    fields=aligned
    # An initially silent waveform permits the real 7-ms attack samples,
    # without storing thousands of redundant carrier periods.
    z.frame_fields=fields
    z.frame_sequences=sequences
    z.frame_times=times
    z.frame_native=True
    z.native=False
    z.has_sweep=False
    z.kind='attack'
    z.size=z.loop_len=256
    z.table=z.ltable=bytes([128])*256
    z.float_tab=z.float_lt=[0.]*256
    z.attack=0.
    z.dur=256/R
    z.rate=R
    z.gain=0.
    z.nat=z.nat_len=0.
    z.s_min=min(n.sp for n in z.notes)
    z.s_max=max(n.sp for n in z.notes)
    z.s_mid=m.geo_mean([n.sp for n in z.notes])
    z.fc_hz=None
    z.late_tics=0
    return True


def install(owner,z,budget,remaining):
    import mussc as m
    owner.layout()
    free_pages=max(1,budget-(255-owner.low)) if budget else 48
    hybrid=bool(getattr(z,"hybrid_attacks",None))
    if hybrid:free_pages-=32  # two attacks and two loop descriptors replace the old pair
    K=max(2,min(80,1+free_pages//remaining))
    fields=z.frame_fields
    H=len(fields[0])
    zero=[0j]*H
    power=[sum(abs(v[h])**2 for v in fields)/len(fields) for h in range(H)]
    floor=max(power)*.001
    weights=[1/math.sqrt(p+floor) for p in power]
    def distance(a,b):
        return sum(abs(x-y)**2*w for x,y,w in zip(a,b,weights))
    selected=[zero]
    nearest=[distance(row,zero) for row in fields]
    ids=[0]*len(fields)
    for j in range(1,K):
        i=max(range(len(fields)),key=lambda i:nearest[i])
        if nearest[i] < 1e-12:break
        selected.append(fields[i])
        for i,row in enumerate(fields):
            e=distance(row,selected[-1])
            if e<nearest[i]:nearest[i]=e;ids[i]=j
    # Refine representative waves against all frames. Farthest-point entries
    # alone favour extremes and can turn a smooth beat into flat plateaus.
    for iteration in range(12):
        groups=[[] for _ in selected]
        for i,row in enumerate(fields):
            j=min(range(1,len(selected)),key=lambda j:distance(row,selected[j]))
            ids[i]=j;groups[j].append(row)
        for j,rows in enumerate(groups):
            if j and rows:
                selected[j]=[sum(row[h] for row in rows)/len(rows) for h in range(H)]
        nearest=[distance(row,selected[j]) for row,j in zip(fields,ids)]
    waves=[]
    for row in selected:
        a=[sum((c*cmath.exp(2j*math.pi*(h+1)*i/255)).real for h,c in enumerate(row)) for i in range(255)]
        a.append(a[0]);waves.append(a)
    peak=max(abs(v) for wave in waves+list(getattr(z,"hybrid_attacks",{}).values()) for v in wave) or 1.
    def q8(v):return max(1,min(255,128+round(v*127/peak)))
    z.gain=-32*math.log2(peak*z.frame_scale)
    z.table=z.ltable=bytes(q8(v) for v in waves[0])
    family=[]
    for i,wave in enumerate(waves):
        v=copy.copy(z);v.name=z.name+'/motion';v.kind='loop';v.notes=[]
        v.frame_native=False;v.native_basis=None;v.morph_basis=None
        v.frame_fields=[]
        v.table=bytes(q8(x) for x in wave) if i else b''
        v.ltable=b''
        v.extra_page=True
        if i==0:
            v.alias_of=z
        else:
            owner.extra_tables.append(v)
        family.append(v)
    z.morph_family=family
    z.morph_times=z.frame_times
    z.morph_sequences={key:[ids[i] for i in seq] for key,seq in z.frame_sequences.items()}
    z.morph_indices=next(iter(z.morph_sequences.values()))
    if hybrid:
        notes=list(z.notes)
        for j,(key,attack) in enumerate(z.hybrid_attacks.items()):
            v=z if j==0 else copy.copy(z)
            v.notes=[n for n in notes if (n.key,n.vel)==key]
            v.table=bytes(q8(x) for x in attack)
            if len(v.table)<4096:v.table+=bytes([128])*(4096-len(v.table))
            v.size=4096;v.baked_attack_tics=150
            v.attack_rate=(4095/(152*m.TIC))/v.notes[0].sp
            v.attack=150*m.TIC*v.notes[0].sp;v.late_tics=0
            if j:owner.zones.append(v)
            for n in v.notes:n.z=v
    z.frame_error=math.sqrt(sum(nearest)/max(1e-12,sum(distance(row,zero) for row in fields)))
    owner.layout()
    if budget and 255-owner.low>budget:
        raise ValueError(owner.name+': moving waveform dictionary exceeds pages')
