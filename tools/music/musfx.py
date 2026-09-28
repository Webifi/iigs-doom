"""Build-time room/body samples: no new player opcode or runtime DSP.

The stationary inharmonic loop discarded almost all of sample320's long,
changing timpani body. A1.365s one-shot retains it, including its envelope,
early reflections and a damped room tail. At E2 this uses8192 bytes. The
brief brighter attack is retained to2.7kHz; the original source is used,
not a waveform lifted from the mixed hardware recording.
"""
import math
import musdsp

SONGS=('D_E1M6','D_E1M7','D_VICTOR')

def compact(owner,z):
    """Trade redundant bass carrier samples for the longer drum, same pitch.

    Large loops retain their complete time period at half the rate. A256
    byte one-period loop instead holds two periods; attack and loop share
    the new rate and maintain the same phase at the existing switch time.
    """
    old=z.rate;L=len(z.ltable)-1
    newL=(L+1)//2-1 if L>=511 else L
    rate=old*newL/L if L>=511 else old/2
    tab=musdsp.resample(z.float_tab,old,rate,taps=16)
    loop=(musdsp.resample(z.float_lt[:-1],old,rate,taps=16,periodic=True)[:newL]
          if L>=511 else [z.float_lt[(2*i)%L] for i in range(L)])
    loop.append(loop[0]);z.loop_len=newL+1
    owner.finish(z,tab,loop,rate)
    z.room_storage_compacted=True

def room_sample(owner,z):
    import mussc as m
    speed=z.s_mid;r=z.r;rate=12000;effective_rate=6000;duration=8191/effective_rate
    x=m.play_through(z.s.data[r.start:r.end],r.ls,r.le,
                     round(duration*speed*z.s.rate)+128)
    x=m.biquad(x,z.s.rate,z.fc_hz/speed,r.g.get('initialFilterQ',0))
    x=musdsp.resample(x,z.s.rate*speed,rate,taps=16)[:round(duration*rate)]
    # Hardware E1M6 exposed50-240Hz tail/attack is-9.1dB. Native SF2
    # alone gives-10.8; its effective decay is too fast for this recording.
    # Keep this measured response correction local to that song.
    decay=.82 if owner.name=='D_E1M6' else 1.
    gain=10**(-2/20) if owner.name=='D_E1M6' else 1.
    x=[v*10**(-m.env_held_db(r,i/rate)*decay/20) for i,v in enumerate(x)]
    rev=[0.]*len(x)
    # Approximate room, not a claim to identify the reference synthesizer's original preset.
    for seconds,level in ((.047,.48),(.083,-.34),(.127,.26),(.173,.20)):
        delay=round(seconds*rate)
        for i in range(delay,len(x)):rev[i]+=level*x[i-delay]
    for seconds in (.0297,.0371,.0411,.0437):
        delay=round(seconds*rate);feedback=10**(-3*seconds/1.05)
        buf=[0.]*len(x);lp=0.
        for i in range(delay,len(x)):
            lp+=.48*(buf[i-delay]-lp)
            buf[i]=x[i-delay]+feedback*lp
            rev[i]+=.15*buf[i]
    y=[gain*(a+.30*b) for a,b in zip(x,rev)]
    tab=musdsp.resample(y,rate,effective_rate,taps=16)[:8191]
    #20ms terminal fade below the useful body, and DOC zero terminator.
    for i in range(120):tab[-120+i]*=(119-i)/120
    z.kind='oneshot';z.loop_len=0;z.nat=z.nat_len=0.;z.morph_basis=None
    z.baked_timpani=True
    owner.finish(z,tab,None,effective_rate/speed)

def install(owner):
    if owner.name not in SONGS:return
    for z in owner.zones:
        if z.notes and z.notes[0].preset==(0,47):room_sample(owner,z)
    for z in owner.zones:
        if not z.notes or not z.ltable:continue
        p=z.notes[0].preset
        if (owner.name=='D_E1M6' and p==(0,33) or
            owner.name=='D_VICTOR' and p==(0,32)):
            compact(owner,z)
    owner.layout()
