;;; The Doom keys: the index of gamekeydown and data1 of the key events
;;; (i_iigs65.s makes them from the ADB keys, g_game65.s uses them). A key
;;; event with data1 >= NUMKEYS is a character for the menus and the cheats.

KEY_SPEED     .equ    0               ; run
KEY_USE       .equ    1               ; use, menu enter
KEY_FIRE      .equ    2
KEY_STRAFELEFT .equ   3
KEY_STRAFERIGHT .equ  4
KEY_UP        .equ    5               ; forward, menu up
KEY_DOWN      .equ    6
KEY_LEFT      .equ    7               ; turn left
KEY_RIGHT     .equ    8
KEY_ESCAPE    .equ    9               ; menu
KEY_MAP       .equ    10              ; automap
KEY_ZOOMOUT   .equ    11
KEY_ZOOMIN    .equ    12
KEY_WEAPONDOWN .equ   13
KEY_WEAPONUP  .equ    14
KEY_STRAFE    .equ    15              ; turn keys strafe
KEY_WEAPON1   .equ    16              ; the weapon keys 1-7
NUMKEYS       .equ    23
KEYC_UP       .equ    0x80            ; the menu keys: characters of the
KEYC_DOWN     .equ    0x81            ;   arrows, Return and Delete, so a
KEYC_LEFT     .equ    0x82            ;   new key of an action does not
KEYC_RIGHT    .equ    0x83            ;   change the menus
KEYC_ENTER    .equ    0x84
KEYC_BACK     .equ    0x85
