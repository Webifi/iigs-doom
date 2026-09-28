"""Offline spectral calibration for the compact p81 saw carrier.

A captured solo's 400 Hz+ fraction is 11–17%; the old DOC carrier has
1.6–2.8%. Restore upper partials while retaining the low fundamental.
Zero-phase FIR on the attack and periodic FIR on the loop; no player EQ.
This is a measured approximation, not the original filter model.
"""
import math
import musdsp

def shelf(owner,z,cut,db):
    rate=z.rate*z.s_mid;fc=cut/rate;N=129;h=[];gain=10**(db/20)
    for k in range(-(N//2),N//2+1):
        h.append((2*fc if k==0 else math.sin(2*math.pi*fc*k)/(math.pi*k))*(.42+.5*math.cos(2*math.pi*k/(N-1))+.08*math.cos(4*math.pi*k/(N-1))))
    norm=sum(h);h=[v/norm for v in h]
    def filt(x,periodic):
        if not x:return []
        L=len(x)-(1 if periodic else 0);y=[]
        for i,a in enumerate(x[:L]):
            lp=sum(v*x[(i+k-N//2)%L] if periodic else v*x[max(0,min(L-1,i+k-N//2))] for k,v in enumerate(h))
            y.append(a+(gain-1)*(a-lp))
        if periodic:y.append(y[0])
        return y
    # Filter and quantize the entire moving family at ONE common gain.
    # Updating only z.table/ltable leaves the later pointer states uncorrected.
    peak0=2**(-z.gain/32)
    att=filt(z.float_tab,False);base=filt(z.float_lt,True)
    family=getattr(z,'morph_family',[])
    extra=[(v,filt([(q-128)*peak0/127 for q in v.table],True))
           for v in family if getattr(v,'extra_page',False) and v.table]
    peak=max(abs(x) for x in att+base+[x for _,loop in extra for x in loop]) or 1.
    quant=lambda x:max(1,min(255,128+round(x*127/peak)))
    z.float_tab=att;z.float_lt=base;z.table=bytes(map(quant,att))+(bytes([0]) if z.kind=='oneshot' else b'');z.ltable=bytes(map(quant,base));z.gain=-32*math.log2(peak)
    for v,loop in extra:v.table=bytes(map(quant,loop));v.gain=z.gain
    for v in family:v.gain=z.gain

def closed_hat(owner,z,play_rate):
    import mussc
    r=z.r; R=play_rate/z.s_mid; cap=len(z.table)-1
    raw=z.s.data[r.start:r.end]
    shaped=[v*10**(-mussc.env_held_db(r,i/z.s.rate/z.s_mid)/20) for i,v in enumerate(raw)]
    attack=musdsp.resample(shaped,z.s.rate,R,taps=24)[:cap]
    fade=min(int(.003*R),len(attack))
    for i in range(fade):attack[-1-i]*=i/(.003*R)
    owner.finish(z,attack,None,R)

def _late(owner):
    """Same-size tom body and closed-hat brightness for the remaining ranks."""
    if owner.name=='D_INTER':
        for z in owner.zones:
            if z.drum and z.r.sample.name=='gm - 583':shelf(owner,z,300.,6.)
    rates={'D_E1M2':28000.,'D_E1M3':24000.,'D_E1M4':28000.,'D_INTER':26000.}
    if owner.name in rates:
        for z in owner.zones:
            if z.drum and z.notes and all(n.key==42 for n in z.notes):
                closed_hat(owner,z,rates[owner.name])
    if owner.name=='D_INTER' or owner.name in rates:
        owner.layout()

def install(owner):
    if owner.name in ('D_E1M1','D_E1M4','D_E1M6'):
        for z in owner.zones:
            if z.drum and z.r.sample.name=='gm - 583':shelf(owner,z,300.,6.)
        owner.layout()
        if owner.name!='D_E1M6':
            _late(owner);return
    if owner.name=='D_E1M9':
        for z in owner.zones:
            if z.drum and z.r.sample.name=='gm - 583':
                # Preserve peak headroom: brighter body must not suppress guitars.
                peak=max(abs(v) for v in z.float_tab)
                shelf(owner,z,300.,6.)
                scale=peak/max(abs(v) for v in z.float_tab)
                owner.finish(z,[v*scale for v in z.float_tab],None,z.rate)
        for z in owner.zones:
            if z.drum and all(n.key==42 for n in z.notes):closed_hat(owner,z,28000.)
        # Splash: retain the already matched onset, soften excess body after25ms.
        for z in owner.zones:
            if z.drum and any(n.key==55 for n in z.notes):
                attack=[v*10**(-1.5*max(0,min(1,(i/z.rate/z.s_mid-.025)/.03))/20)
                        for i,v in enumerate(z.float_tab)]
                owner.finish(z,attack,[v*10**(-1.5/20) for v in z.float_lt],z.rate)
        owner.layout()
        return
    if owner.name=='D_VICTOR':
        # Acoustic bass: restore the softer first25ms measured in reference-synthesizer solos.
        # The existing native attack holds the entire return to unity at55ms.
        for z in owner.zones:
            if z.notes and z.notes[0].preset==(0,32):
                attack=[v*10**(-2.5*max(0,min(1,(.055-i/z.rate/z.s_mid)/.03))/20)
                        for i,v in enumerate(z.float_tab)]
                owner.finish(z,attack,z.float_lt,z.rate)
        owner.layout()
        return
    settings={'D_E1M7':(300.,10.),'D_E1M2':(250.,6.),'D_E1M6':(1000.,-2.)}
    if owner.name not in settings:
        _late(owner);return
    cut,db=settings[owner.name]
    for z in owner.zones:
        if z.notes and z.notes[0].preset==(0,81):
            zone_cut,zone_db=(300.,9.) if owner.name=='D_E1M2' and z.r.sample.name=='gm - 410' else (cut,db)
            shelf(owner,z,zone_cut,zone_db)
    owner.layout()
    _late(owner)
