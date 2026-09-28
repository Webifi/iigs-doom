;;; The shared state of the renderer in 65816 assembly, Doom8088: Apple IIgs
;;; Edition.
;;;
;;; The variables of r_draw.c that several renderer files use (in
;;; the order of the C file): the drawsegs and their clip lists, the column
;;; clips of the floors and the ceilings, the view of the frame, the seg that
;;; R_StoreWallRange (src/iigs/r_wall65.s) sets up for the column loop of
;;; src/iigs/r_seg65.s, the sprite clips and the vissprites.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

MAXDRAWSEGS   .equ    128
MAXOPENINGS   .equ    CONST_VIEWWIDTH * 16

              .section znear, bss
              .public _s_drawsegs, openings, lastopening, floorclip, ceilingclip
              .public viewx, viewy, viewz, viewcos, viewsin, viewangle16, solidcol
              .public curline, sidedef, linedef, frontsector, backsector, ds_p
              .public floorplane_color, ceilingplane_color, rw_angle1, rw_normalangle
              .public rw_distance, rw_stopx, rw_scale, rw_scalestep, worldtop, worldbottom
              .public didsolidcol, maskedtexture, toptexture, bottomtexture, midtexture
              .public textoptexture, texbottomtexture, texmidtexture, rw_midtexturemid
              .public rw_toptexturemid, rw_bottomtexturemid, extralight, mfloorclip
              .public mceilingclip, spryscale, sprtopscreen, rw_centerangle, rw_offset
              .public rw_lightlevel, maskedtexturecol, topfrac, topstep, bottomfrac, viewtop
              .public bottomstep, pixhigh, pixlow, pixhighstep, pixlowstep, worldhigh
              .public worldlow, num_vissprite, vissprites, viewangle
;;; The walls drawn in this frame, for the clips of the sprites and the
;;; masked textures, and the clip lists they point to.
_s_drawsegs:  .space  MAXDRAWSEGS * SIZEOF_DS
openings:     .space  MAXOPENINGS * 2
lastopening:  .space  4               ; the next free opening
;;; The rows above the floor and below the ceiling of each column.
floorclip:    .space  CONST_VIEWWIDTH * 2
ceilingclip:  .space  CONST_VIEWWIDTH * 2
;;; The view (R_SetupFrame).
viewx:        .space  4
viewy:        .space  4
viewz:        .space  4
viewcos:      .space  4
viewsin:      .space  4
viewangle16:  .space  2
solidcol:     .space  CONST_VIEWWIDTH ; the columns that a solid wall fills
;;; The seg of R_StoreWallRange: its line, side and sectors, the flat colors,
;;; the angles, the scale and its step, the heights, the textures and their
;;; middle rows, the light, and the steps of the column edges.
curline:      .space  4
sidedef:      .space  4
linedef:      .space  4
frontsector:  .space  4
backsector:   .space  4
ds_p:         .space  4               ; the drawseg of the seg
floorplane_color: .space 2
ceilingplane_color: .space 2
rw_angle1:    .space  2
rw_normalangle: .space 2
rw_distance:  .space  2
rw_stopx:     .space  2
rw_scale:     .space  4
rw_scalestep: .space  4
worldtop:     .space  4
worldbottom:  .space  4
didsolidcol:  .space  2
maskedtexture: .space 2
toptexture:   .space  2
bottomtexture: .space 2
midtexture:   .space  2
textoptexture: .space 4
texbottomtexture: .space 4
texmidtexture: .space 4
rw_midtexturemid: .space 4
rw_toptexturemid: .space 4
rw_bottomtexturemid: .space 4
extralight:   .space  2               ; the light of a gun flash
;;; The sprite being drawn: its clip lists, scale and top.
mfloorclip:   .space  4
mceilingclip: .space  4
spryscale:    .space  4
sprtopscreen: .space  4
rw_centerangle: .space 2
rw_offset:    .space  2
rw_lightlevel: .space 2
viewtop:      .space  2               ; the row above the view: -1, or 9 with
                                      ;   the message strip (d_main65.s)
maskedtexturecol: .space 4
topfrac:      .space  4
topstep:      .space  4
bottomfrac:   .space  4
bottomstep:   .space  4
pixhigh:      .space  4
pixlow:       .space  4
pixhighstep:  .space  4
pixlowstep:   .space  4
worldhigh:    .space  4
worldlow:     .space  4
;;; The things to draw in this frame (R_ProjectSprite).
num_vissprite: .space 2
vissprites:   .space  CONST_MAXVISSPRITES * SIZEOF_VIS
viewangle:    .space  4

;;; The clip lists of a sprite that no wall clips: the whole view (to
;;; viewbottom, set by R_RenderPlayerView). The clip arrays hold the clips
;;; + 1 (src/iigs/segvar.inc): viewbottom + 1 and -1 + 1.
              .section near, data
              .public screenheightarray, negonearray, viewbottom
viewbottom:   .word   CONST_VIEWHEIGHT        ; the row after the 3D view
screenheightarray:
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .word   (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1), (CONST_VIEWHEIGHT + 1)
              .section cnear, rodata
negonearray:  .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
