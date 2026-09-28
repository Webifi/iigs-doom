"""Title Halo: sampled opening, then paired phase-aligned spectral crossfades.

The opening chord uses all 14 oscillators. Existing voice-reserve cuts
free voices 1 and 3 at tics 150 and 120. Only then may they become fade partners.
Both partners start together at a short faded attack/loop handover. Afterwards
only an oscillator at zero volume receives a waveform pointer change.
"""
def install(s):
 import musbank
 halo={n.voice:n for n in s.notes if getattr(n.z,'baked_attack_tics',0)}
 if len(halo)!=2:raise ValueError('title crossfade needs the two sampled Halo attacks')
 start=max(n.on+n.z.baked_attack_tics for n in halo.values())
 buddy={v:1 if n.key==47 else 3 for v,n in halo.items()}
 for n in s.notes:
  if n.voice in (1,3) and n.stop>start:
   raise ValueError('crossfade would cut a primary note')
 waves=s.wakes
 states={v:dict(on=False,lev=127,fc=0,epoch=start,swap=0,old=None,new=None) for v in halo}
 vols=[musbank.vol_of(i) for i in range(128)]
 unique={x:i for i,x in enumerate(vols)};pairs={}
 def levels(level,weight):
  total=vols[level];key=(total,round(weight,6))
  if key not in pairs:
   a=total*(1-weight);b=total*weight
   ca=sorted(unique,key=lambda x:abs(x-a))[:4];cb=sorted(unique,key=lambda x:abs(x-b))[:4]
   x,y=min(((x,y) for x in ca for y in cb),key=lambda p:4*(sum(p)-total)**2+(p[0]-a)**2+(p[1]-b)**2)
   pairs[key]=(unique[x],unique[y])
  return pairs[key]
 def page(n,t):return n.z.morph_family[s.morph_at(n,t)]
 lastlev={v:127 for v in list(halo)+list(buddy.values())}
 out={};stats=dict(page_changes=0,level_changes=0,fade_tics=11,handover_tic=start)
 for tic in range(s.length+1):
  commands=[]
  for kind,v,val in waves.get(tic,[]):
   if v not in halo:
    if v in (1,3) and tic>=start:continue
    commands.append((kind,v,val));continue
   st=states[v];b=buddy[v];n=halo[v]
   if kind=='on':st.update(on=True,lev=val[1],fc=val[2])
   elif kind=='lev':st['lev']=val
   elif kind=='fc':st['fc']=val
   elif kind=='off':st['on']=False
   if tic<start:
    commands.append((kind,v,val))
    if kind in ('on','lev'):lastlev[v]=st['lev']
   elif kind=='off':
    commands.extend([('off',v,None),('off',b,None)]);lastlev[v]=lastlev[b]=127
   elif kind=='fc' and tic>start:
    commands.extend([('fc',v,val),('fc',b,val)])
  for v,n in halo.items():
   st=states[v]
   if not st['on']:continue
   b=buddy[v]
   if tic<start:
    if tic in (start-2,start-1):
     k=levels(st['lev'],.5 if tic==start-2 else 1)[0]
     commands.append(('lev',v,k));lastlev[v]=k
    continue
   if tic==start:
    st.update(epoch=tic,swap=0,old=page(n,tic),new=page(n,tic+1))
    commands.extend([('off',b,None),('on',v,(n,127,st['fc'])),('on',b,(n,127,st['fc'])),
     ('sw',v,None),('sw',b,None),('morph',v,st['old']),('morph',b,st['new']),('ctl',b,(v&1)<<4)])
    lastlev[v]=lastlev[b]=127;stats['page_changes']+=2
   epoch=st['epoch'];duration=1 if epoch==start else 11
   if tic>=epoch+duration:
    active=b if st['swap']==0 else v;muted=v if st['swap']==0 else b
    for u,k in [(muted,127),(active,st['lev'])]:
     if lastlev[u]!=k:commands.append(('lev',u,k));lastlev[u]=k;stats['level_changes']+=1
    st['swap']^=1;st['epoch']=tic;epoch=tic;duration=11
    st['old']=st['new'];st['new']=page(n,min(n.stop,tic+duration))
    commands.append(('morph',muted,st['new']));stats['page_changes']+=1
   if tic>start and (tic-epoch)%2 and tic<epoch+duration:
    continue  # paired volume ramps at 14 ms; note onsets stay exact
   w=min(1.,max(0.,(tic-epoch)/duration))
   la,lb=levels(st['lev']+8 if tic==start else st['lev'],w)
   va,vb=(v,b) if st['swap']==0 else (b,v)
   for u,k in [(va,la),(vb,lb)]:
    if lastlev[u]!=k:commands.append(('lev',u,k));lastlev[u]=k;stats['level_changes']+=1
  if commands or tic==0:out[tic]=commands
 s.wakes=out;s.crossfade_stats=stats
