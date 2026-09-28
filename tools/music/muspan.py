"""Stereo amplitude pan for automated channels and E1M1's opposing guitars.

Both oscillators share table, pitch, onset and envelope. Panning changes only
amplitudes; its attenuation follows the soft knee, so the knee cannot pull a
quiet side back towards the centre. Auxiliary voices never displace a primary.
The existing BF command routes a physical oscillator after its ordinary note-on.
"""
import bisect,copy,math

def prepare(s, groups):
    histories={ch:[(0,64)] for ch in range(16)}
    for t,events in groups:
        for k,ch,a,b in events:
            if k=='ctl' and a==10:
                if histories[ch][-1][0]==t:histories[ch][-1]=(t,b)
                elif histories[ch][-1][1]!=b:histories[ch].append((t,b))
    channels={ch for ch,hs in histories.items() if len({p for _,p in hs})>1}
    # A restored timpani body needs its written stereo position too.
    channels.update(n.ch for n in s.notes if getattr(n.z,'baked_timpani',False))
    if s.name in ('D_E1M4','D_E1M8'):channels.add(9)  # centred kick partners
    if s.name=='D_E1M3':channels.add(9)  # exposed ride-bell partner
    if s.name=='D_E1M5':channels.add(6)
    if s.name=='D_E1M8':channels.update((1,2,3))
    if s.name=='D_VICTOR':channels.update((2,9))  # protect centred rhythm partners
    if s.name=='D_E1M7':channels.add(5)  # centre harp, shared native carrier
    if s.name=='D_E1M4':channels.update((1,2))  # opposing guitars retain written amplitudes
    if s.name=='D_E1M6':channels.update((2,6,7))  # music box: stable pan34, shared tables
    if s.name=='D_E1M5':channels.add(0)  # exposed strings: preserve pan and mono sum
    if s.name=='D_E1M1':channels.update(n.ch for n in s.notes if n.preset in ((0,29),(0,30)))
    if not channels:return
    original=list(s.notes)
    primary=[n for n in original if n.half==0]
    optional=[]
    stats=dict(channels=sorted(channels),targets=0,paired=0,unpaired=0,short_mirror_tails=0,
               primary_release_tails_shortened=0,optional_sides_removed=0,optional_sides_shortened=0)
    aux=[]
    for n in original:n.route_side=n.voice&1
    for n in primary:
        if n.ch not in channels:continue
        hs=histories[n.ch];ts=[t for t,_ in hs];i=max(0,bisect.bisect_right(ts,n.on)-1)
        track=[(n.on,hs[i][1])]+[(t,p) for t,p in hs[i+1:] if t<n.stop]
        if all(p==64 for _,p in track) and not (s.name=='D_E1M5' and n.ch==6 or s.name=='D_E1M8' and n.ch in (1,2,3) or s.name=='D_E1M7' and n.ch==5 or s.name=='D_VICTOR' and n.ch==2 or s.name in ('D_E1M4','D_E1M8') and n.ch==9 and n.key==36 or s.name=='D_E1M6' and n.ch==7 or s.name=='D_E1M3' and n.ch==9 and n.key==53 or s.name=='D_VICTOR' and (n.preset==(0,47) or n.ch==9 and n.key in (35,36,38,40,81))):continue  # already centred, no pan motion
        n.pan_track=track
        if n.ch==9:
            offset=127*n.r.pan
            n.pan_track=[(t,0 if p==0 else 127 if p==127 else max(0,min(127,p+offset))) for t,p in n.pan_track]
        if s.name=='D_E1M2' and n.ch==9 and n.key==75:
            # Exposed hardware clicks keep a quiet opposite-side room return.
            # Shared sample, static amplitudes: no pages or effect-update wakes.
            n.pan_track=[(t,max(16,min(111,p))) for t,p in n.pan_track]
        if s.name=='D_E1M5' and n.ch==0 and n.preset==(0,48):
            # Hardware opening has a narrower direct/room blend than dry CC10.
            n.pan_track=[(t,round(64+(p-64)*.6)) for t,p in n.pan_track]
        n.pan_side=int(n.pan_track[0][1]>=64);n.route_side=n.pan_side
        n.pair=False;n.partner=None;stats['targets']+=1
        if len({p for _,p in n.pan_track})==1 and n.pan_track[0][1] in (0,127):continue
        m=copy.copy(n);m.half=1;m.pan_side=1-n.pan_side;m.route_side=m.pan_side
        n.partner=m;m.partner=n;n.pair=m.pair=True;aux.append(m)
    target_keys={(n.ch,n.key,n.on,n.vel) for n in primary if hasattr(n,"pan_track")}
    optional=[n for n in original if n.half==1 and (n.ch,n.key,n.on,n.vel) not in target_keys]
    # Colour the complete note intervals anew. An arbitrary old physical voice
    # assignment must not prevent a mirror when another oscillator is idle.
    # Priority: all primary notes, their required pan mirrors, optional sides.
    # Only an already released primary can be shortened, never a held note.
    active={};kept=[];aux_ids={id(n) for n in aux}
    def priority(n):return 0 if n.half==0 else 1 if id(n) in aux_ids else 2
    def tail_level(n,t):
        if s.name=='D_E1M5' and n.preset==(0,119):
            import musnoise
            return 40*math.log10(max(1,n.vel)/127)+40*math.log10(116/127)-n.r.atten-musnoise.wet_db((t-n.on)/140,n.on)
        age=max(0,(min(t,n.off)-n.on)/140)
        db=__import__('mussc').layers_db(n,age)
        if t>=n.off:db+=100*(t-n.off)/140/max(n.r.release,.001)
        return 40*math.log10(max(1,n.vel)/127)+40*math.log10(max(1,n.vol)/127)-n.r.atten-db
    for n in sorted(primary+aux+optional,key=lambda n:(n.on,priority(n),n.ch,n.key)):
        if n.stop<=n.on:continue
        active={v:m for v,m in active.items() if m.stop>n.on}
        free=[v for v in range(14) if v not in active]
        if not free and priority(n)<2:
            discard=[(v,m) for v,m in active.items() if priority(m)==2]
            if not discard:discard=[(v,m) for v,m in active.items() if m.off<=n.on]
            if discard:
                v,m=min(discard,key=lambda vm:tail_level(vm[1],n.on))
                m.stop=m.end=n.on;free=[v];del active[v]
                key='optional_sides_shortened' if priority(m)==2 else 'short_mirror_tails' if priority(m)==1 else 'primary_release_tails_shortened'
                stats[key]+=1
        if not free:
            if n.half==0:raise ValueError('pan allocation would cut a held primary note')
            if priority(n)==1:raise ValueError('pan allocation cannot preserve a held mirror')
            n.stop=n.on;stats['optional_sides_removed']+=1;continue
        same=[v for v in free if (v&1)==n.route_side]
        v=n.voice if n.voice in same else min(same or free)
        n.voice=v;active[v]=n;kept.append(n)
        if priority(n)==1:stats['paired']+=1
    s.notes=sorted(kept,key=lambda n:(n.on,n.voice));s.pan_stats=stats

def levels(s,tracks,exact):
    if not getattr(s,'pan_stats',None):return
    import musbank
    vals={musbank.vol_of(i):i for i in range(128)}
    cache={}
    def split(k,p):
        key=(k,p)
        if key not in cache:
            total=musbank.vol_of(k);theta=(p/128 if p<=64 else .5+(p-64)/126)*math.pi/2
            l=total*math.cos(theta);r=total*math.sin(theta)
            aa=sorted(vals,key=lambda v:abs(v-l))[:3];bb=sorted(vals,key=lambda v:abs(v-r))[:3]
            a,b=min(((a,b) for a in aa for b in bb),key=lambda z:((z[0]**2+z[1]**2-total**2)/max(total,1))**2+(z[0]-l)**2+(z[1]-r)**2)
            if p==0:a,b=total,0
            if p==127:a,b=0,total
            cache[key]=vals[a],vals[b]
        return cache[key]
    for vt in tracks:
        for tr in vt:
            on,end,n,fq,qs,nstep=tr
            if not hasattr(n,'pan_track'):continue
            hs=n.pan_track;ii=0;partner=n.partner
            exact.update(t for t,_ in hs)
            n.level_wait=1
            for j,k in enumerate(qs):
                t=on+j
                while ii+1<len(hs) and hs[ii+1][0]<=t:ii+=1
                if not isinstance(k,int):continue
                if partner is not None and t<min(n.stop,partner.stop):qs[j]=split(k,hs[ii][1])[n.pan_side]
                # When only one side remains in a release, keep its total level.

def route(s):
    if not (getattr(s,'pan_stats',None) or getattr(s,'fixed_route_count',0)):return
    active={};out={}
    wakes=dict(s.wakes)
    for n in s.notes:
        for t,_ in getattr(n,"pan_track",[]):wakes.setdefault(t,[])
    for t,writes in sorted(wakes.items()):
        cmd=[]
        for kind,v,value in writes:
            cmd.append((kind,v,value))
            if kind=='on':
                n=value[0];active[v]=n
                if hasattr(n,'route_side'):
                    side=n.route_side
                    if hasattr(n,'pan_track') and n.partner is None:
                        side=int(n.pan_track[max(0,bisect.bisect_right([x[0] for x in n.pan_track],t)-1)][1]>=64)
                    if side!=(v&1):cmd.append(('ctl',v,(side<<4)|(2 if n.z.kind=='oneshot' else 0)))
            elif kind=='off':active.pop(v,None)
        # Hard-panned one-oscillator notes may cross sides while held.
        for v,n in active.items():
            if not hasattr(n,'pan_track') or n.partner is not None:continue
            for i,(tt,p) in enumerate(n.pan_track):
                if tt==t and i and (p>=64)!=(n.pan_track[i-1][1]>=64):cmd.append(('ctl',v,(int(p>=64)<<4)|(2 if n.z.kind=='oneshot' else 0)))
        if cmd or t==0:out[t]=cmd
    s.wakes=out

def fixed(s,groups):
    """Repair physical-voice fallback for fixed pan with one route write.

    Keep the existing oscillator allocation and sample/envelope. Centred
    pairs retain opposite outputs. Continuous pan continues to use paired
    gain ramps; a fixed route does not pretend to reproduce room width.
    """
    histories={ch:[(0,64)] for ch in range(16)}
    for t,events in groups:
        for k,ch,a,b in events:
            if k=='ctl' and a==10:histories[ch].append((t,b))
    count=0
    for n in s.notes:
        if hasattr(n,'pan_track'):continue
        p=next(p for t,p in reversed(histories[n.ch]) if t<=n.on)
        side=0 if p<48 else 1 if p>80 else (0 if n.r.pan<-.05 else 1 if n.r.pan>.05 else None) if n.ch==9 and not n.pair else None
        if n.pair and (n.preset==(0,81) or s.name=='D_E1M9' and n.ch in (2,6) or s.name=='D_INTER' and n.ch==9 and n.key==36) and 48<=p<=80:side=n.half
        if side is not None:
            n.route_side=side
            count+=int(side!=(n.voice&1))
    s.fixed_route_count=count
