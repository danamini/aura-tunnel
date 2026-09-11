; ----------------------------------------------------------------------------
; AURA TUNNEL - 48K and 128K ZX Spectrum demo
;
; Most scenes use baked trajectories, projections, shaded sprites and
; generated drawing routines. The graph interlude executes real ROM BASIC
; for a bounded preview with its source listing visible.
; Animated scenes target 50 fps except the complete-pose roto at 25 fps.
; The 128K edition adds interrupt-driven AY music and level meters.
;
; The running order:
;   BRIEFING      double-height ROM-font mission text, type-on
;   DOT TUNNEL    rings of pixels streaming out along baked trajectories
;   ROTO GRID     a turning plane: attribute tiles under a dot lattice
;   STAR SNAKE    sine-wave text scroller under a drifting starfield
;   SINE SCROLL   32x24 pixel letters, one pixel a frame, per-column wave
;   SOLID CUBES   Driller-style solids, faces dithered at build time
;   DOT RUNNER    three runners derived from CMU motion-capture joints
;   DEEP SPACE    48 coloured stars, three parallax layers
;   3D GRAPHS     the classic BASIC surface plot, then machine code
;   NIGHT TRAIN   two Yie Ar Kung-Fu fighters, on a moving flatbed
;
; House tricks, used throughout:
;   * Bake it, don't compute it.  A live dither-filler for the cubes was
;     written, worked, and cost ~90k T-states against the 69,888 there
;     are; the shading moved to gen_tables and the Z80 got a flat blit.
;   * SP as a data pointer: renderers POP baked bytes two at a time, or
;     PUSH them (11T a pair beats 24T a byte); returns from SP-walking
;     code are self-modified JPs, never CALLs.
;   * Erase from what you know, never by clearing: dot renderers cache
;     each pixel's address and mask and unplot exactly those next frame,
;     so the sky behind them is painted once at scene entry.
;   * Generated Z80: one specialised routine per case, so the inner loop
;     branches on nothing (snake.asm, bigscr.asm, and the roto grid's
;     two unrolled row painters).
;   * Self-modifying code for per-scene renderer dispatch and loop bounds.
;   * Everything hot runs above 0x8000 (uncontended); cold one-shot code
;     and baked data live at 0x5E00 and in the reclaimed map region.
;
; Keys:  Q resets to BASIC.  On the 128K build, M mutes the music.
;
; Build:  make            (sjasmplus + python3; see README.md)
; Test:   make test-runtime  (SkoolKit; see README.md)
; ----------------------------------------------------------------------------
        IFDEF TARGET128
        DEVICE ZXSPECTRUM128
PORT7FFD EQU $7FFD              ; the pager.  Write-only: keep a shadow if
PAGEBASE EQU $10                ;   anything else ever writes it.  ROM 1 +
MUSBANK  EQU 1                  ;   bank 0 at $C000 is the resting state
        ELSE
        DEVICE ZXSPECTRUM48
        ENDIF
        SLDOPT COMMENT WPMEM, LOGPOINT, ASSERTION   ; DeZog source-level debug

SCREEN   EQU $4000
ATTRS    EQU $5800
SCROLATT EQU $5AA0              ; attribute rows 21-23: the runner's ground
                                ;   bands, and the 128K console's meters
SNAKATT  EQU $5960              ; middle band: attribute rows 11-13
SNAKROW  EQU $60                ; bitmap y=88, within the middle screen third
SNAKHI   EQU $48
ROMFONT  EQU $3C00              ; ROM font base (char 32 lives at $3D00)

MAPS     EQU $A000              ; 9 x 1344 byte tunnel maps (3 scenes x 3 bob)
MAPSIZE  EQU 21*64
MAPSEND  EQU MAPS+6*MAPSIZE     ; $BF80: big tables live in the tail space
SHADEP1  EQU $9000              ; warm palette shade tables (page-aligned;
SHADEI1  EQU $9800              ;   INK page = PAPER page with bit 3 set)
BBUF     EQU $DF00              ; giant-scroller overlay masks: 4 rows x 32
                                ;   cells x [and,or] (the page between the
                                ;   maps and the cool palette)
SHADEP0  EQU $E000              ; cool palette shade tables, same layout
SHADEI0  EQU $E800
CBUF     EQU $5B00              ; the cube's 8x64-byte off-screen raster
DOTS     EQU $A000              ; dot records, in the dead map region:
                                ;   64 x [angle|fast<<7, depth, prevaddr, mask, pad]
DOTTAB   EQU $F000              ; baked trajectories: 3 geometries
RDBOT    EQU $A000              ; roto grid: lattice records, pushed
RDTOP    EQU $A400              ;   downward from the top by the plotter
ROTAB    EQU $E000              ; 64 angles x 8 zooms x [A,B,DX,DY]
BITMSK   EQU $F900              ; one page of $80>>(x&7)
BSBUF    EQU $AC00              ; sine scroller: 24 rows x 32 bytes
BSGLY    EQU $B200              ; the current letter, 24 rows x 4 bytes
        IFDEF TARGET128
BANDTOP  EQU 120                ; lower screen, above the AY console at y=168
        ELSE
BANDTOP  EQU 72                 ; the letter band's top scanline
        ENDIF
STACK    EQU $FA00
IM2TAB   EQU $FB00              ; 257 bytes of $FC
IM2VEC   EQU $FCFC              ; RETI

        ORG $8000

START:
        di
        IFDEF TARGET128
        ld bc,PORT7FFD
        ld a,PAGEBASE
        out (c),a               ; bank 0 at $C000 before anything pushes
        ENDIF
        ld sp,STACK
        xor a
        out ($FE),a             ; black border
        ld a,HIGH IM2TAB
        ld i,a
        im 2
        call INITSCREEN
        call TITLESET
        call BRIEFSET
        IFDEF TARGET128
        call AYINIT
        ENDIF

MAIN:
        ei
        halt                    ; sync to 50Hz frame interrupt
        IFNDEF TARGET128
        di
        ENDIF
        call UPDATE
.rnd:   call DOTT               ; self-modified: per-scene renderer
        call ROWCOLOURS
        call SCROLLER
        call TITLE
        IFDEF TARGET128
        call AYCON              ; console only; music runs at the interrupt
        ELSE                    ;   on purpose: rows 21-23 are the last thing
        ;call MUSIC             ;   the beam reaches, so a full attr repaint
        ENDIF                   ;   down there can never be caught mid-write
        call KEYS               ; Q quits to BASIC
        jp MAIN

; ----------------------------------------------------------------- UPDATE
; Advance time, forward motion + rotation (both 8.8 fixed point), pick the
; bob map and render routines for the current scene, and every 256 frames
; change scene, swap palette and accelerate.
UPDATE:
        ld hl,(FRAMES)
        inc hl
        ld (FRAMES),hl

        ld hl,(MOVEF)           ; forward motion
        ld bc,(SPEED)
        add hl,bc
        ld (MOVEF),hl
        ld a,h
        and 15
        ld (MOVE),a

        ld hl,(ROTF)            ; rotation: smooth 8.8 accumulator
        ld bc,(ROTSPD)
        add hl,bc
        ld (ROTF),hl
        ld a,h
        and 7
        ld (ROT),a

        ld hl,(BIGPOS)          ; giant scroller: one chunky column/frame
        inc hl
        ld a,h
        and 1                   ; 64-char text = 512 columns, cyclic
        ld h,a
        ld (BIGPOS),hl

        ld a,(TITLEF)           ; the scene title's clock, parked at 255
        inc a
        jr z,.tf
        ld (TITLEF),a
.tf:
        ld a,(FRAMES)           ; 24 frames before a scene CHANGE, arm
        cp 232                  ; the transition on the outgoing image
        jr nz,.nwm
        ld a,(SEQPOS)           ; peek the next slot
        inc a
        cp SEQLEN
        jr c,.wpk
        xor a
.wpk:
        ld e,a
        ld d,0
        ld hl,SEQ
        add hl,de
        ld a,(hl)
        ld hl,SCENE
        cp (hl)
        jr z,.nwm               ; held scene: no transition
        xor a
        ld (WIPEF),a
        ld a,(SCENE)            ; the two take it in turns - except that
        cp 9                    ; the briefing always slides away.  Pinned
        jr nz,.tog              ; rather than left to the playlist's
        ld a,1                  ; parity, which happens to give a slide
        ld (TRMODE),a           ; today and would stop the day a scene is
        jr .nwm                 ; added or held
.tog:
        ld a,(TRMODE)
        xor 1
        ld (TRMODE),a
.nwm:

        ld a,(FRAMES)           ; every 256 frames: next playlist slot.
        or a                    ; This must happen BEFORE the vectors below,
        jp nz,.steady           ; or the old renderer runs one frame into
        ld a,(SPEED)            ; the new scene and tramples the transition
        cp $50                  ; work (BAKEHIATTR / CHUNKRESTORE).
        jr nc,.rspd             ; accelerate first, gently capped
        add a,$08
        ld (SPEED),a
.rspd:  ld a,(ROTSPD)
        cp $20
        jr nc,.seq
        add a,$04
        ld (ROTSPD),a
.seq:   ld a,(SEQPOS)
        inc a
        cp SEQLEN
        jr c,.sq
        xor a
.sq:    ld (SEQPOS),a
        ld e,a                  ; scene = SEQ[SEQPOS]: scenes listed twice
        ld d,0                  ; run twice as long
        ld hl,SEQ
        add hl,de
        ld a,(hl)
        ld hl,SCENE
        cp (hl)
        ld (hl),a
        jp z,.steady            ; same scene held: skip transition work
        ld a,(SCENE)
        cp 3
        jr nc,.nott             ; any tunnel scene: dark stage, ring
        call DOTSET             ; colours, a fresh spread of dots
        call CLRBOTTOM
.nott:
        ld a,(SCENE)
        cp 3
        call z,CUBESET          ; entering the cube: dark, ringed stage
        ld a,(SCENE)
        cp 4
        call z,STARSET          ; snake stage: dark, star-ready bitmap
        ld a,(SCENE)
        cp 5
        call z,BSSET            ; the pixel scroller: a bare black stage
        ld a,(SCENE)
        cp 6
        call z,RUNSET           ; the dot runner: sunset, floor, no dots
        ld a,(SCENE)
        cp 7
        call z,STARSET          ; deep space
        ld a,(SCENE)
        cp 8
        call z,STARSET          ; the night train: dark stage,
        ld a,(SCENE)
        cp 8
        call z,TRAINSET         ;   night, horizon, deck and track
        ld a,(SCENE)
        cp 9
        call z,STARSET          ; the briefing: darkness,
        ld a,(SCENE)
        cp 9
        call z,BRIEFSET         ;   then the type-on begins
        ld a,(SCENE)
        cp 10
        call z,GRAPHSET
        ld a,(SCENE)
        cp 11
        call z,ROTSET           ; the roto grid: a bare plane
        call TITLESET           ; and every fresh scene announces itself
.steady:


        ld a,(SCENE)            ; point MAIN at this scene's routines
        cp 3
        jr z,.hires
        cp 4
        jr z,.solo              ; scene 4: snake only, full budget
        cp 5
        jr z,.big               ; scene 5: bouncing giant letters
        cp 6
        jr z,.stick             ; scene 6: the big fella walks
        cp 7
        jp z,.stars             ; scene 7: deep space
        cp 8
        jp z,.yiear             ; scene 8: the night train
        cp 9
        jp z,.brief             ; scene 9: the mission briefing
        cp 10
        jp z,.graph             ; scene 10: hidden-line surface plots
        cp 11
        jp z,.roto              ; scene 11: the roto grid
        ld hl,DOTT
        ld (MAIN.rnd+1),hl
        ld a,(SCENE)            ; this tunnel's baked geometry (x768)
        ld b,a
        add a,a
        add a,b
        ld h,a
        ld l,0
        ld de,DOTTAB
        add hl,de
        ld (DGEO),hl
        ld a,(SCENE)            ; and its personality: [spin cadence,
        add a,a                 ; spin step, bend speed, dot speed]
        add a,a
        add a,a                 ; rows padded to eight bytes
        ld e,a
        ld d,0
        ld hl,PTAB
        add hl,de
        ld a,(hl)
        ld (DSPM),a
        inc hl
        ld a,(hl)
        ld (DSPD),a
        inc hl
        ld a,(hl)
        ld (DBST),a
        inc hl
        ld a,(hl)
        ld (DOTT.spd+1),a
        jr .vec
.solo:
        ld hl,STARSFEW
        ld (MAIN.rnd+1),hl
        jr .vec
.hires:
        ld hl,DOTCUBE
        ld (MAIN.rnd+1),hl
        jr .vec
.big:
        ld hl,BIGSCR
        ld (MAIN.rnd+1),hl
        jr .vec
.stick:
        ld hl,RUNNER
        ld (MAIN.rnd+1),hl
        jr .vec
.stars:
        ld hl,STARS
        ld (MAIN.rnd+1),hl
        jr .vec
.yiear:
        ld hl,YIEAR
        ld (MAIN.rnd+1),hl
        jr .vec
.brief:
        ld hl,BRIEF
        ld (MAIN.rnd+1),hl
        jr .vec
.graph:
        ld hl,GRAPH
        ld (MAIN.rnd+1),hl
        jr .vec
.roto:
        ld hl,ROTO
        ld (MAIN.rnd+1),hl
.vec:
        ld a,(SCENE)            ; the three tightest scenes take their
        cp 3                    ; notes at half length; everywhere else
        jr z,.mh                ; the beeper sings full bursts
        cp 4
        jr z,.mh
        cp 6
        jr z,.mh
        xor a
        jr .ms
.mh:
        ld a,1
.ms:
        ld (MHALF),a
        ld a,(WIPEF)            ; a transition overrides the scene: the
        cp 24                   ; old image freezes while it is consumed
        jr nc,.nw
        inc a
        ld (WIPEF),a
        ld hl,WIPER             ; dissolve, then slide, then dissolve...
        ld a,(TRMODE)
        or a
        jr z,.tr
        ld hl,SLIDER
.tr:
        ld (MAIN.rnd+1),hl
.nw:
        ret

; ------------------------------------------------------------- ROWCOLOURS
; Slide the rainbow ink strip under all three scroller rows (the strip is
; baked 4x cyclic, so three consecutive LDIRs never run off the end).
ROWCOLOURS:
        ld a,(SCENE)            ; rainbow only under the snake scene
        cp 4
        ret nz
        ld a,(FRAMES)
        rrca
        and 31
        ld h,HIGH RAINBOW
        ld l,a
        ld de,SNAKATT
        ld bc,32
        ldir
        ld bc,32
        ldir
        ld bc,32
        ldir
        ret

; --------------------------------------------------------------- SCROLLER
; True hi-res snake: 1px/frame left scroll runs in a column-major
; off-screen buffer (RL carry-chains right-to-left), then every 8px
; column is blitted at its own height from a travelling sine wave -
; via one specialised single-pass routine per (even) offset.
FETCHCHAR:                      ; A = next scrolltext char, wrapping
.tptr:
        ld hl,SCRTEXT
        ld a,(hl)
        inc hl
        or a
        jr nz,.ok
        ld hl,SCRTEXT           ; 0 terminator: wrap
        ld a,(hl)
        inc hl
.ok:
        ld (.tptr+1),hl
        ret

SCROLLER:                       ; each scroller has its own scene now:
        ld a,(SCENE)            ; the snake appears ONLY in scene 4
        cp 4
        ret nz
.surge:
        ld b,2                  ; constant speed; acceleration looked jumpy
.spx:
        push bc
        call SHIFT1
        pop bc
        djnz .spx
.wave:

; ---- snake blit: each column at its own sine height, one pass, top-down
        ld a,(FRAMES)
        add a,a
        cpl                     ; wave travels AGAINST the scroll: no text
        ld c,a                  ; speed can ride a crest and freeze flat
        ld b,0                  ; B = column
.col:
        ld h,HIGH SINTAB
        ld l,c
        ld a,(hl)
        and 30                  ; even offset 0..16 -> variant index
        ld l,a
        ld h,0
        ld de,JTAB
        add hl,de
        ld a,(hl)
        ld (.call+1),a
        inc hl
        ld a,(hl)
        ld (.call+2),a
        ld l,b                  ; HL = TBUF + col (source stride is 32)
        ld h,HIGH TBUF
        ld a,SNAKROW            ; DE = window top of this column
        or b
        ld e,a
        ld d,SNAKHI
.call:
        call 0                  ; self-modified: SNK0..SNK16
        ld a,c
        add a,8                 ; wavelength: one full sine across 32 chars
        ld c,a
        inc b
        ld a,b
        cp 32
        jp nz,.col
        ret

; ----------------------------------------------------------------- SHIFT1
; Scroll the snake buffer left one real pixel, feeding glyph columns bit
; by bit (the classic RL carry chain - DEC keeps the carry alive).
; Every scene calls this; faster scenes just call it more than once.
SHIFT1:
        ld a,(BITCNT)
        dec a
        ld (BITCNT),a
        jr nz,.sh
        call FETCHCHAR          ; consumed 8 bits: next character
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,ROMFONT
        add hl,bc
        ld de,GBUF
        ld bc,8
        ldir
        ld a,8
        ld (BITCNT),a
.sh:
        REPT 8, N
        ld hl,GBUF+N
        rl (hl)                 ; carry = incoming bit for this scanline
        ld hl,TBUF+N*32+31
        DUP 32
        rl (hl)
        dec l
        EDUP
        EDUP
        ret

; ------------------------------------------------------------- BLANKATTRS
; Entering the solo snake scene: rows 0-20 attrs black - an empty stage.
BLANKATTRS:
        ld hl,ATTRS
        ld de,ATTRS+1
        ld bc,21*32-1
        ld (hl),0
        ldir
        ret

NOOP:   ret                     ; scenes that need no per-frame setup

; ------------------------------------------------------------------ GROUND
; The stick man's parallax floor: two hi-res dash bands under his feet,
; the near band scrolling 8px/frame, the far band 2px/frame - he stays
; put, the world rushes by.
GROUNDSET:                      ; scene entry: wipe the floor bitmap and
        ld b,8                  ; lay the band colours
        ld hl,$50A0
.gz:
        xor a
.gzl:
        ld (hl),a
        inc l
        jr nz,.gzl
        inc h
        ld l,$A0
        djnz .gz
        ld hl,SCROLATT          ; row 21 dim cyan, 22 white, 23 bright
        ld b,32
.a1:
        ld (hl),$05
        inc hl
        djnz .a1
        ld b,32
.a2:
        ld (hl),$07
        inc hl
        djnz .a2
        ld b,32
.a3:
        ld (hl),$47
        inc hl
        djnz .a3
        ret

GLINE:                          ; A = pattern offset, DE = scanline -> copy
        push hl
        ld c,a
        ld b,0
        add hl,bc
        ld bc,32
        ldir
        pop hl
        ret

GROUND:
        ld a,(FRAMES)
        and 3
        jr nz,.fastonly         ; far band moves every 4th frame only -
        ld hl,GPATSLOW          ; no point repainting it in between
        ld a,(FRAMES)
        rrca
        rrca
        and 63
        ld de,$52A0
        call GLINE
        add a,17                ; de-correlate the second scanline
        and 63
        ld de,$55A0
        call GLINE
.fastonly:
        ld hl,GPATFAST          ; near band: rows 22-23, 8px/frame
        ld a,(FRAMES)
        and 63
        ld de,$52C0
        call GLINE
        add a,11
        and 63
        ld de,$54C0
        call GLINE
        add a,23
        and 63
        ld de,$51E0
        call GLINE
        add a,7
        and 63
        ld de,$55E0
        call GLINE
        ret                     ; (his companion is dots now, drawn with him)

GPATFAST:
        INCBIN "build/gpat.bin"
GPATSLOW EQU GPATFAST+128

WIPER:                          ; the transition: the old scene dissolves
; cell by cell into the new one's stage, on the same ordered-dither
; matrix the cubes are shaded with.  Sixteen steps, and each step touches
; only the 48 cells at its own level of the matrix - so both scenes are
; on screen together the whole way across, for about a thousand
; T-states a frame.  (A true sliding wipe would mean shifting all 6,144
; bitmap bytes per step, ~125k T - four frames' worth. Not at 50 fps.)
        ld a,(WIPEF)
        cp 16
        ret nc
        add a,a
        ld l,a
        ld h,0
        ld de,BPOS
        add hl,de
        ld d,(hl)               ; D = first row at this level
        inc hl
        ld e,(hl)               ; E = first column
        ld a,$7F
        call WCELLS             ; light this step's cells...
        ld a,(WIPEF)
        or a
        ret z
        dec a
        add a,a
        ld l,a
        ld h,0
        ld de,BPOS
        add hl,de
        ld d,(hl)
        inc hl
        ld e,(hl)
        xor a
        jp WCELLS               ; ...and put out the last step's

WCELLS:                         ; A = colour, D = row, E = col, step 4
        ld c,a
.row:
        ld a,d
        IFDEF TARGET128
        cp 21
        ELSE
        cp 24
        ENDIF
        ret nc
        push de
        ld l,d                  ; HL = ATTRS + row*32 + col
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld b,0
        push bc
        ld c,e
        add hl,bc
        pop bc
        ld de,ATTRS
        add hl,de
.col:
        ld (hl),c
        ld a,l
        add a,4
        ld l,a
        and 31
        cp 4
        jr nc,.col
        pop de
        ld a,d
        add a,4
        ld d,a
        jr .row

BPOS:                           ; where each dither level first appears
        db 0,0, 2,2, 0,2, 2,0
        db 1,1, 3,3, 1,3, 3,1
        db 0,1, 2,3, 0,3, 2,1
        db 1,0, 3,2, 1,2, 3,0

WIPEF:  db 255
TRMODE: db 0

CLRBOTTOM:                      ; rows 21-23 attrs black: tunnels run clean
        ld hl,SCROLATT
        ld de,SCROLATT+1
        ld bc,95
        ld (hl),0
        ldir
        ret

; --------------------------------------------------------------- CHUNKALL
; Re-lay the chunky half-block pattern over the whole bitmap (scene
; changes that need it back after a hi-res stage).  One-off; may run a
; frame long - a single skipped frame per occurrence.
CHUNKALL:
        ld hl,SCREEN
.fill:
        ld a,h
        and 7                   ; scanline within the cell = bits 0-2 of H
        cp 4
        ccf
        sbc a,a                 ; 0..3 -> $00, 4..7 -> $FF
        ld (hl),a
        inc hl
        ld a,h
        cp HIGH ATTRS
        jr nz,.fill
        ret

; ---------------------------------------------------------------- STARSET
; A dark stage for the star scenes: whole bitmap and every attr wiped.
STARSET:
        ld hl,SCREEN
        ld de,SCREEN+1
        ld bc,6143
        ld (hl),0
        ldir
        ld hl,ATTRS
        ld de,ATTRS+1
        ld bc,767
        ld (hl),0
        ldir
        ret

; ------------------------------------------------------------------ STARS
; The coloured star field: 48 single-pixel stars in three parallax
; layers - near ones bright and fast, far ones dim and slow.  Each star
; erases itself, drifts left (8.8 fixed point), replots, and drops its
; colour into the attr cell it occupies.  STARSFEW is the night sky over
; the snake scene: one bright layer, leaving the budget to the wave.
STARS:
        call TITLE.draw         ; draw the header before the beam reaches row 0
        ld a,16
        jr STARGO
STARSFEW:                       ; the snake's sky: two star layers and
        call SATERASE
        ld a,$00                ; a companion cube tumbling up there
        ld (STARGRP.dxl+1),a
        ld a,3
        ld (STARGRP.dxh+1),a
        ld ix,STARDAT
        ld b,8
        call STARGRP
        ld a,$80
        ld (STARGRP.dxl+1),a
        ld a,1
        ld (STARGRP.dxh+1),a
        ld ix,STARDAT+64
        ld b,8
        call STARGRP
        jp SATDRAW
STARGO:
        ld iyl,a
        ld a,$00                ; near layer: 3.0 px/frame
        ld (STREAKGRP.dxl+1),a
        ld a,3
        ld (STREAKGRP.dxh+1),a
        ld ix,STARDAT
        ld b,iyl
        call STREAKGRP
        ld a,$80                ; mid layer: 1.5 px/frame
        ld (STREAKGRP.dxl+1),a
        ld a,1
        ld (STREAKGRP.dxh+1),a
        ld ix,STARDAT+64
        ld b,iyl
        call STREAKGRP
        ld a,$A0                ; far layer: 0.625 px/frame
        ld (STREAKGRP.dxl+1),a
        xor a
        ld (STREAKGRP.dxh+1),a
        ld ix,STARDAT+128
        ld b,iyl
        jp STREAKGRP
STARGRP:
.st:
        push bc
        ld d,(ix+2)             ; unplot at the current position
        ld e,(ix+1)
        call PIXADDR
        cpl
        and (hl)
        ld (hl),a
        ld a,(ix+0)             ; drift left, 8.8 fixed point
.dxl:   sub 0                   ; self-modified per layer
        ld (ix+0),a
        ld a,(ix+1)
.dxh:   sbc a,0                 ; self-modified per layer
        ld (ix+1),a
        ld d,(ix+2)             ; replot
        ld e,a
        call PIXADDR
        or (hl)
        ld (hl),a
        ld a,(ix+2)             ; and colour the cell it sits in
        and $F8
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld a,(ix+1)
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ld de,ATTRS
        add hl,de
        ld a,(ix+3)
        ld (hl),a
        ld bc,4
        add ix,bc
        pop bc
        djnz .st
        ret

; ------------------------------------------------------------------ YIEAR
; Two Yie Ar Kung-Fu fighters sparring: 40x40 1-bit frames copied to
; fixed byte columns each frame (same box, so they self-erase), stepping
; through baked move sequences every 8 frames.
YSPRITE:                        ; DE = frame data, B = top y, C = x byte of
        ld ixl,40               ;   the LEFT BORDER (sprite starts at C+1);
.l:                             ;   blank flanks erase 1-byte steps
        ld a,b                  ; the standard y -> screen address dance
        and 7
        ld h,a
        ld a,b
        rra
        rra
        rra
        and 24
        or h
        or 64
        ld h,a
        ld a,b
        rla
        rla
        and $E0
        or c
        ld l,a
        xor a
        ld (hl),a
        inc l
        REPT 5
        ld a,(de)
        ld (hl),a
        inc de
        inc l
        EDUP
        xor a
        ld (hl),a
        inc b
        dec ixl
        jp nz,.l
        ret

YIEAR:
        call TRAIN              ; the wagon and the world going past it
        ld a,(FRAMES)           ; fight-script step, 0.16s each; the 32
        rrca                    ; steps span exactly one scene slot
        rrca
        rrca
        and 31
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,FIGHTS
        add hl,de
        ld a,(hl)               ; [px, pframe, ox, oframe]
        ld (PXCUR),a
        inc hl
        ld a,(hl)
        ld (PIDX),a
        inc hl
        ld a,(hl)
        ld (OXCUR),a
        inc hl
        ld a,(hl)
        ld (OIDX),a

        ld a,(PIDX)             ; a kicking fighter flickers white/yellow
        cp 2
        jr z,.pk
        cp 4
        jr z,.pk
        ld a,$47
        jr .ps
.pk:
        ld a,(FRAMES)
        and 4
        ld a,$47
        jr z,.ps
        ld a,$46
.ps:
        ld (PCOL),a
        ld a,(OIDX)
        cp 2
        jr z,.ok2
        cp 4
        jr z,.ok2
        ld a,$45
        jr .os
.ok2:
        ld a,(FRAMES)
        and 4
        ld a,$45
        jr z,.os
        ld a,$46
.os:
        ld (OCOL),a

        ld a,(PIDX)             ; player sprite
        add a,a
        ld e,a
        ld d,0
        ld hl,FOFF
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,YFRAMES
        add hl,de
        ex de,hl
        ld a,(PXCUR)
        dec a
        ld c,a
        ld a,(YROCK)            ; they ride the deck's rocking, feet
        add a,104               ; landing just on it
        ld b,a
        call YSPRITE
        ld a,(OIDX)             ; opponent sprite (mirrored set)
        add a,a
        ld e,a
        ld d,0
        ld hl,FOFF
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,YFRAMES+1200
        add hl,de
        ex de,hl
        ld a,(OXCUR)
        dec a
        ld c,a
        ld a,(YROCK)
        add a,104
        ld b,a
        call YSPRITE

        ld hl,ATTRS+13*32       ; colour rectangles follow the fighters
        ld ixl,5
.rrow:
        push hl
        xor a
        REPT 32
        ld (hl),a
        inc hl
        EDUP
        pop hl
        push hl
        ld a,(PXCUR)
        add a,l
        ld l,a
        ld a,(PCOL)
        REPT 5
        ld (hl),a
        inc l
        EDUP
        pop hl
        push hl
        ld a,(OXCUR)
        add a,l
        ld l,a
        ld a,(OCOL)
        REPT 5
        ld (hl),a
        inc l
        EDUP
        pop hl
        ld bc,32
        add hl,bc
        dec ixl
        jp nz,.rrow
        ret

PXCUR:  db 0
PIDX:   db 0
OXCUR:  db 0
OIDX:   db 0
PCOL:   db 0
OCOL:   db 0

        MACRO BUFDOWN           ; HL = buffer byte one scanline down
        ld a,l                  ; (the off-screen raster is linear:
        add a,8                 ;  8 bytes a row, no screen-third gymnastics)
        ld l,a
        jr nc,.bd
        inc h
.bd:
        ENDM

PIXADDR:                        ; D = y, E = x -> HL = bitmap byte, A = mask
        ld a,d
        and 7
        ld h,a
        ld a,d
        rra
        rra
        rra
        and 24
        or h
        or 64
        ld h,a
        ld a,e
        rrca
        rrca
        rrca
        and 31
        ld l,a
        ld a,d
        rla
        rla
        and $E0
        or l
        ld l,a
        ld a,e
        and 7                   ; the top of this page is also the normal stack
        ld c,a
        ld b,HIGH BITMSK
        ld a,(bc)
        ret

; --------------------------------------------------------------- INITSCREEN
; Chunky pattern: scanlines 0-3 of every cell clear (PAPER = top half),
; 4-7 set (INK = bottom half).  Then wipe rows 21-23 for the scroller.
INITSCREEN:
        call CHUNKALL
        ld b,8                  ; wipe char rows 21-23 (L = $A0..$FF on
        ld hl,$50A0             ;   each of the third's 8 scanline pages)
.clr:
        xor a
.clrl:
        ld (hl),a
        inc l
        jr nz,.clrl
        inc h
        ld l,$A0
        djnz .clr

        ld hl,ATTRS             ; all attrs black until frame 1 paints them
        ld de,ATTRS+1
        ld bc,767
        ld (hl),0
        ldir
        ret

; ------------------------------------------------------------------- data
FRAMES: dw 0
MOVEF:  dw 0
SPEED:  dw $001C                ; rings/frame, 8.8 fixed - ramps up to $50
ROTF:   dw 0
ROTSPD: dw $000C                ; wedges/frame, 8.8 fixed - ramps up to $20
BIGPOS: dw 0
MOVE:   db 0
ROT:    db 0
SCENE:  db 9                    ; boot into the briefing

        dw MAPS+2*MAPSIZE,  MAPS+3*MAPSIZE,  MAPS+2*MAPSIZE,  MAPS+3*MAPSIZE
        dw MAPS+4*MAPSIZE,  MAPS+5*MAPSIZE,  MAPS+4*MAPSIZE,  MAPS+5*MAPSIZE

SEQ:    db 9,0,0,11,11,4,5,5,5,5,5,5 ; ~31 seconds at 50 FPS
        db 3,3,6,7,10,10,8,8    ; briefing, one tunnel,
SEQEND:
SEQLEN  EQU SEQEND-SEQ                  ;   then a feature every slot, the
SEQPOS: db 0                    ;   snake, type, runner, cube, space...
XOFF:   db 0                    ; stick man: this frame's x offset
SROW:   ds 4                    ; stick man: current sprite row scratch
CTAB:                           ; giant-text row colours, (c<<3)|c pairs:
        db $36,$36,$12,$12      ; yellow, yellow, red, red,
        db $1B,$1B,$2D,$2D      ; magenta, magenta, cyan, cyan
BITCNT: db 1                    ; solo scroller: glyph bits left to feed
GBUF:   ds 8                    ; solo scroller: current glyph

        IFDEF TARGET128
        INCLUDE "src/ay128.asm"
        ENDIF
FONT0:  INCBIN "build/font0.bin"
        ASSERT $ <= SHADEP1     ; code must stay below the warm palette

; -------- big tables and generated code, in the tail after the maps -------
        ORG MAPSEND
        INCLUDE "build/snake.asm"

; ------------------------------------------------------------------ GRAPH
; A timed real ROM BASIC preview with a generated listing, followed by
; explicitly precalculated colour plots. BASICENTER restores borrowed
; workspace and sets GREALDONE before returning to this renderer.
GRAPHSET:
        xor a
        ld (GREALDONE),a
        ret
GRAPH:
        ld a,(GREALDONE)
        or a
        jp z,BASICENTER
.frun:
        ld a,(GTIME)            ; ~1.7s per surface, then the next
        inc a
        ld (GTIME),a
        cp 84
        jr c,.fdraw
        xor a
        ld (GTIME),a
        ld a,(GIDX)
        inc a
        cp 3
        jr c,.gi
        xor a
.gi:
        ld (GIDX),a
        jp GNEXT
.fdraw:
        ld b,64                 ; sixty-four points a frame
        ; fall through
GSTEP:
.pl:
        push bc
        ld a,(GCNT)
        or a
        jr nz,.pt
        ld hl,(GPTR)            ; next row header: count, sx0
        ld a,(hl)
        or a
        jr z,.done              ; the surface is complete
        ld (GCNT),a
        inc hl
        ld a,(hl)
        ld (GXC),a
        inc hl
        ld (GPTR),hl
.pt:
        ld hl,(GPTR)
        ld a,(hl)
        inc hl
        ld (GPTR),hl
        ld hl,GCNT
        dec (hl)
        cp $FF
        jr z,.skip              ; hidden behind the surface
        ld d,a                  ; py
        ld a,(GFAST)
        or a
        jr nz,.go
        ld a,d                  ; act one only plots below the listing
        cp 128
        jr c,.skip
.go:
        ld a,(GXC)
        ld e,a
        call PIXADDR
        or (hl)
        ld (hl),a
        ld a,(GFAST)
        or a
        jr z,.skip
        ld a,d                  ; act two: colour the cell by height
        rrca
        rrca
        rrca
        rrca
        rrca
        and 7
        add a,LOW HCOL
        ld l,a
        ld a,HIGH HCOL
        adc a,0
        ld h,a
        ld c,(hl)
        ld a,d
        and $F8
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld a,(GXC)
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ld de,ATTRS
        add hl,de
        ld (hl),c
.skip:
        ld hl,GXS
        ld a,(GXC)
        add a,(hl)
        ld (GXC),a
        pop bc
        djnz .pl
        ret
.done:
        pop bc
        ret

TXTSTR:                         ; HL -> [col,row,attr,len,text]; HL past it
        ld a,(hl)
        ld (BCX),a
        inc hl
        ld a,(hl)
        ld (BROW),a
        inc hl
        ld a,(hl)
        ld (BCOL),a
        inc hl
        ld b,(hl)
        inc hl
.c:
        ld a,(hl)
        inc hl
        push bc
        push hl
        call TXCHAR
        pop hl
        pop bc
        ld a,(BCX)
        inc a
        ld (BCX),a
        djnz .c
        ret

TXCHAR:                         ; A = char, single height at (BROW,BCX)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,ROMFONT
        add hl,bc
        ex de,hl
        ld a,(BROW)
        call ROWADDR
        REPT 8
        ld a,(de)
        ld (hl),a
        inc h
        inc de
        EDUP
        ld a,(BROW)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(BCX)
        ld c,a
        ld b,0
        add hl,bc
        ld bc,ATTRS
        add hl,bc
        ld a,(BCOL)
        ld (hl),a
        ret

GNEXT:                          ; wipe, caption, load surface GIDX
        call STARSET
        ld a,2                  ; the banner: why act two is quicker
        ld (BCX),a
        xor a
        ld (BROW),a
        ld a,$C6                ; flashing bright yellow, double height
        ld (BCOL),a
        ld hl,MCTXT
        ld b,MCTXTEND-MCTXT
.cap:
        ld a,(hl)
        inc hl
        push bc
        push hl
        call DHCHAR
        pop hl
        pop bc
        ld a,(BCX)
        inc a
        ld (BCX),a
        djnz .cap
        ld a,(GIDX)
        or a
        jr nz,.g1
        ld hl,G3D1              ; the eggbox
        ld a,4
        jr .set
.g1:
        cp 1
        jr nz,.g2
        ld hl,G3D2              ; the saddle
        ld a,4
        jr .set
.g2:
        ld hl,G3D0              ; and the ripple, now in colour
        ld a,3
.set:
        ld (GPTR),hl
        ld (GXS),a
        xor a
        ld (GCNT),a
        inc a
        ld (GFAST),a
        ret

MCTXT:  db "PRECALCULATED / Z80 PLOT"
MCTXTEND:

HCOL:   db $47,$46,$44,$45,$43,$41,$41,$41  ; height bands, peak first
GFAST:  db 0
GIDX:   db 0
GTIME:  db 0
GXS:    db 3

BASICPROGRAM:
        INCBIN "assets/basic/program.bin"
BASICPROGRAMEND:

GPTR:   dw 0
GCNT:   db 0
GXC:    db 0
G3D0:
        INCBIN "build/g3d0.bin"
G3D1:
        INCBIN "build/g3d1.bin"
G3D2:
        INCBIN "build/g3d2.bin"

SCRTEXT:
        db "        AURA TUNNEL        "
        db "TUBE... BOX... STAR... TRUE HI-RES... GIANT LETTERS...   "
        db "NO DOUBLE BUFFER - WE RACE THE BEAM...   "
        db "THE STACK POINTER IS THE RENDERER...   "
        db "SNAKE SNAKE SNAKE...   "
        db "SPECTRUM AURA GOES 8-BIT...      ", 0

BIGTEXT:                        ; (retired with the attribute giant letters)
        db "AURA TUNNEL      SPECTRUM AURA      GOES BIG      HELLO 8"
        db "-BIT   "
        ASSERT $-BIGTEXT == 64

        ALIGN 256
RAINBOW:
        INCBIN "build/rainbow.bin"
        ALIGN 256
SINTAB:
        INCBIN "build/sintab.bin"
        ALIGN 256
        ALIGN 256
TBUF:   ds 256                  ; column-major scroller buffer, 32 cols x 8

        MACRO STCELL            ; one stick-man cell: paint only his body,
        sla e                   ; the sky wash already owns the rest
        rl d
        sbc a,a
        and ixh                 ; -> paper colour if set
        ld iyl,a
        sla c
        rl b
        sbc a,a
        and iyh                 ; -> ink colour if set
        or iyl
        jr z,.sky               ; transparent: the sunset shows through
        or $40                  ; BRIGHT: also the depth marker that
        ld (hl),a               ;   occludes the background walker
.sky:
        inc hl
        ENDM

        MACRO MINICELL          ; one background-walker cell: dim cyan,
        sla b                   ; hidden wherever a BRIGHT cell (the big
        sbc a,a                 ; fella) already stands
        and $28
        ld iyl,a
        sla c
        sbc a,a
        and $05
        or iyl
        jr z,.skip
        ld iyl,a
        ld a,(hl)
        and $40
        jr nz,.skip
        ld a,iyl
        ld (hl),a
.skip:
        inc hl
        ENDM

CUBEATTR:
        INCBIN "build/cubeattr.bin"

        ASSERT $ <= $DC00
        ORG $5E00               ; cold sprite data in the low free RAM
STARDAT:
        INCBIN "build/stars.bin"
STREAKGRP:
.st:
        push bc
        ld d,(ix+2)             ; unplot at the current position
        ld e,(ix+1)
        call STARTAILADDR
        call STARTAIL
        cpl
        and (hl)
        ld (hl),a
        ld a,c
        inc l
        cpl
        and (hl)
        ld (hl),a
        call STAREXERASE
        ld a,(ix+0)             ; drift left, 8.8 fixed point
.dxl:   sub 0                   ; self-modified per layer
        ld (ix+0),a
        ld a,(ix+1)
.dxh:   sbc a,0                 ; self-modified per layer
        ld (ix+1),a
        ld d,(ix+2)             ; replot
        ld e,a
        call STARTAILADDR
        call STARTAIL
        or (hl)
        ld (hl),a
        ld a,c
        inc l
        or (hl)
        ld (hl),a
        call STAREXDRAW
        ld a,(ix+2)             ; and colour the cell it sits in
        and $F8
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld a,(ix+1)
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ld de,ATTRS
        add hl,de
        ld a,(ix+3)
        ld (hl),a
        ld bc,4
        add ix,bc
        pop bc
        djnz .st
        ret

STARTAILADDR:                   ; trails need an address, not PIXADDR's bit mask
        ld l,d
        ld h,HIGH ROWLO
        ld a,(hl)
        inc h
        ld h,(hl)
        ld l,a
        ld a,e
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ret

STARTAIL:                       ; two cached masks, never read through the stack
        ld a,e
        and 7
        add a,a
        add a,8
        ld e,a
        ld d,HIGH BITMSK
        ld a,(de)
        ld b,a
        inc de
        ld a,(de)
        ld c,a
        ld a,l
        and 31
        cp 31
        jr nz,.ok
        ld c,0
.ok:
        ld a,b
        ret

; ------------------------------------------------------------------ TITLE
; Scene title cards: 12 chars top-left, sliding down from the screen edge
; (0.64s), holding two seconds, sliding back out.  Drawn after everything
; else so it floats over any scene; when it ends, the window is repaired
; to whatever bitmap the scene expects (chunky halves or darkness).
TITLE:
        ld a,(SCENE)
        cp 7
        ret z                   ; starfield publishes its title before its stars
        cp 10
        ret z                   ; the graph owns its BASIC/ASSEMBLER headings
.draw:
        ld a,(TITLEF)
        cp 165
        ret nc                  ; long gone
        cp 164
        jp z,.repair
        cp 32                   ; slide in: 0 -> 8 over 32 frames
        jr c,.in
        cp 132                  ; hold
        jr c,.hold
        sub 132                 ; slide out: 8 -> 0
        rrca
        rrca
        and 7
        ld b,a
        ld a,8
        sub b
        jr .go
.in:
        rrca
        rrca
        and 7
        jr .go
.hold:
        ld a,8
.go:
        ld iyl,a                ; how far the text has descended (IYL:
        ld ixh,0                ; the line copy below eats BC)
.tl:
        ld a,ixh
        add a,8
        sub iyl                 ; glyph row entering this scanline
        cp 8
        jr c,.have
        ld hl,ZERO12
        jr .copy
.have:
        ld e,a                  ; * 12
        add a,a
        add a,e
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,TSTRIP
        add hl,de
.copy:
        ld a,ixh
        add a,$40
        ld d,a
        ld e,0
        DUP 12
        ldi
        EDUP
        inc ixh
        ld a,ixh
        cp 8
        jr nz,.tl
        ld hl,ATTRS             ; the card: white on black, and the rest
        ld a,$47                ; of row 0 dark while we borrow it
        REPT 12
        ld (hl),a
        inc l
        EDUP
        xor a
        REPT 20
        ld (hl),a
        inc l
        EDUP
        ret
.repair:                        ; one-shot: hand the window back
        ld a,(SCENE)
        ld e,a
        ld d,0
        ld hl,TCHUNK
        add hl,de
        ld a,(hl)
        or a
        jr z,.zrep
        ld d,$40                ; chunky scenes: re-lay the half-blocks
.crep:
        ld e,0
        ld a,d
        and 7
        cp 4
        ccf
        sbc a,a
        ld b,12
.crl:
        ld (de),a
        inc e
        djnz .crl
        inc d
        ld a,d
        cp $48
        jr nz,.crep
        jr .arep
.zrep:
        ld d,$40                ; dark scenes: back to black
.zr2:
        ld e,0
        xor a
        ld b,12
.zrl:
        ld (de),a
        inc e
        djnz .zrl
        inc d
        ld a,d
        cp $48
        jr nz,.zr2
.arep:
        ld hl,ATTRS
        xor a
        REPT 12
        ld (hl),a
        inc l
        EDUP
        ret

TITLESET:                       ; scene change: bake the strip, start the clock
        ld a,(SCENE)
        ld e,a                  ; * 12
        add a,a
        add a,e
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,TITLES
        add hl,de
        ld b,12
        ld ix,TSTRIP
.tc:
        ld a,(hl)
        inc hl
        push hl
        push bc
        ld l,a                  ; ROM font glyph
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,ROMFONT
        add hl,bc
        REPT 8, R
        ld a,(hl)
        ld (ix+R*12),a
        inc hl
        EDUP
        inc ix
        pop bc
        pop hl
        djnz .tc
        xor a
        ld (TITLEF),a
        ret

TITLEF: db 255
TCHUNK: db 0,0,0,0,0,0,0,0,0,0,0,0 ; which scenes want chunky repair
TITLES:
        db "DOT TUNNEL  "
        db "BOX         "
        db "STAR        "
        db "SOLID CUBES "
        db "STAR SNAKE  "
        db "SCROLL 50FPS"
        db "RUNNER 50FPS"
        db "DEEP SPACE  "
        db "NIGHT TRAIN "
        db "BRIEFING    "
        db "3D GRAPHS   "
        db "ROTO GRID   "
TSTRIP: ds 96
ZERO12: ds 12

; ------------------------------------------------------------------- CUBE
; Solid cubes, Driller style: one hero and four companions, every one a
; baked sprite whose faces were scan-filled through a Bayer matrix at
; build time.  A live scanline filler was built first and worked, but
; cost ~90k T-states a frame against the 69,888 there are - so the
; shading moved to gen_tables, where it is free, and the Z80 got back a
; flat blit that erases itself by storing rather than ORing.
; ------------------------------------------------------------------ BRIEF
; The mission briefing: double-height ROM-font text (every glyph scanline
; written twice - 8x16 characters) typing on line by line in colour
; blocks, one character every other frame, ending on a flashing status.
BRIEF:
        call BCURSOR            ; the cursor blinks every frame
        ld a,(FRAMES)
        and 1
        ret nz                  ; one character every other frame
        ld a,(BLEFT)
        or a
        jr nz,.draw
        call BCURSOR.clear
        ld hl,(BPTR)            ; next line header: col,row,attr,len
        ld a,(hl)
        cp $FF
        ret z                   ; briefing complete: hold (GREEN flashes)
        ld (BCX),a
        inc hl
        ld a,(hl)
        ld (BROW),a
        inc hl
        ld a,(hl)
        ld (BCOL),a
        inc hl
        ld a,(hl)
        ld (BLEFT),a
        inc hl
        ld (BPTR),hl
        ret                     ; a beat before each line starts
.draw:
        ld hl,(BPTR)
        ld a,(hl)
        inc hl
        ld (BPTR),hl
        call DHCHAR
        ld hl,BLEFT
        dec (hl)
        ld hl,BCX
        inc (hl)
        ret

DHCHAR:                         ; A = char -> double-height at (BROW,BCX)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,ROMFONT
        add hl,bc
        ex de,hl                ; DE = glyph rows
        ld a,(BROW)
        call ROWADDR
        call DH4                ; glyph rows 0-3, each written twice
        ld a,(BROW)
        inc a
        call ROWADDR
        call DH4                ; glyph rows 4-7 likewise
        ld a,(BROW)             ; both attr cells take the line colour
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(BCX)
        ld c,a
        ld b,0
        add hl,bc
        ld bc,ATTRS
        add hl,bc
        ld a,(BCOL)
        ld (hl),a
        ld bc,32
        add hl,bc
        ld (hl),a
        ret

ROWADDR:                        ; A = char row -> HL = its bitmap line 0 + BCX
        ld c,a
        rra
        rra
        rra
        and 3
        add a,a
        add a,a
        add a,a
        or $40
        ld h,a
        ld a,c
        and 7
        rrca
        rrca
        rrca
        and $E0
        ld c,a
        ld a,(BCX)
        or c
        ld l,a
        ret

DH4:                            ; four glyph rows -> eight scanlines
        REPT 4
        ld a,(de)
        ld (hl),a
        inc h
        ld (hl),a
        inc h
        inc de
        EDUP
        ret

KEYS:                           ; M: toggle the music.  Q: quit.
        ld a,$7F                ; half-row B N M SS SPACE
        in a,($FE)
        and 4                   ; M, active low
        jr z,.mdown
        xor a
        ld (MKPREV),a
        jr .q
.mdown:
        ld a,(MKPREV)
        or a
        jr nz,.q                ; still held from last frame
        ld a,1
        ld (MKPREV),a
        ld a,(MUSON)
        xor 1
        ld (MUSON),a
.q:
        ld a,$FB                ; half-row Q W E R T
        in a,($FE)
        and 1                   ; Q, active low
        ret nz
        di                      ; quit: a clean machine reset
        im 1
        jp 0

MUSON:  db 1
MKPREV: db 0
MHALF:  db 0

BRIEFSET:
        ld hl,BDATA
        ld (BPTR),hl
        xor a
        ld (BLEFT),a
        ld a,2                  ; park the cursor at the first line
        ld (BCX),a
        ld a,3
        ld (BROW),a
        ld a,$46
        ld (BCOL),a
        ret

BPTR:   dw BDATA
BLEFT:  db 0
BCX:    db 0
BROW:   db 0
BCOL:   db 0

BDATA:                          ; col, row, attr, len, text...
        db  2,3,$46,4
        db "AURA"
        db  2,5,$46,6
        db "TUNNEL"
        IFDEF TARGET128
        db 20,3,$43,4
        db "128K"
        ELSE
        db 21,3,$43,3
        db "48K"
        ENDIF
        db 17,5,$43,13
        db "50 FPS SCENES"
        db 10,9,$47,10
        db "TEN SCENES"
        db  7,11,$47,17
        db "EVERYTHING BAKED."
        db  8,14,$47,15
        db "RACING THE BEAM"
        db 13,17,$C4,5
        db "READY"
        IFDEF TARGET128
        db  9,19,$05,14         ; row 19 on the 128K: the font is double
        db "M=MUSIC Q=QUIT"     ;   height, so this occupies 19-20 and
        ELSE                    ;   leaves row 21 to the console's meters
        db 13,20,$05,6
        db "Q=QUIT"
        ENDIF
        db $FF

CUBESET:                        ; scene entry: dark stage, rainbow rings,
        call STARSET            ; empty off-screen raster
        ld hl,CUBEATTR
        ld de,ATTRS
        ld bc,672
        ldir
        ; Fixed white ink across the hero's full travel region: its face
        ; shading comes from the bitmap, not stationary rainbow colour cells.
        ld hl,ATTRS+7*32+12
        ld b,10
        ld a,$47
.heroink:
        DUP 8
        ld (hl),a
        inc hl
        EDUP
        ld de,24
        add hl,de
        djnz .heroink
        ld hl,CBUF
        ld de,CBUF+1
        ld bc,511
        ld (hl),0
        ldir
        call CBEXPAND
        ld hl,CBUF
        ld (CBFRONT),hl
        ld hl,DOTS
        ld (CBBACK),hl
        xor a
        ld (CBPART),a
        ret

CEDGES: db 0,2, 4,6, 8,10, 12,14
        db 0,4, 2,6, 8,12, 10,14
        db 0,8, 2,10, 4,12, 6,14
VB:     dw 0
EDGN:   db 0
YFRAMES:
        INCBIN "build/yiear.bin"

FOFF:   dw 0,200,400,600,800,1000  ; frame index -> data offset
                                ; frames: 0 guard, 1 guard2, 2 flying kick,
                                ;         3 sweep, 4 high kick, 5 jump
FIGHTS:                         ; 32 steps x [px, pframe, ox, oframe]
        db  4,0, 23,0           ; squaring up...
        db  5,0, 22,0
        db  6,1, 21,1
        db  7,0, 20,0
        db  8,1, 19,1
        db  9,0, 18,0
        db 10,1, 17,1           ; face-off
        db 10,4, 17,1           ; player high kick!
        db 10,4, 17,3           ; ...opponent drops into a sweep
        db 10,0, 17,3
        db  9,0, 17,5           ; opponent leaps
        db  8,0, 17,5           ; player gives ground
        db  7,0, 16,3           ; opponent presses, sweeping
        db  6,0, 15,3
        db  5,1, 14,3
        db  4,0, 13,1           ; cornered...
        db  4,2, 13,1           ; FLYING KICK back
        db  5,2, 14,1
        db  6,2, 15,1
        db  7,2, 16,1
        db  8,2, 17,5           ; opponent leaps clear
        db  9,0, 18,5
        db  9,4, 18,3           ; exchange: high kick over the sweep
        db  9,1, 18,4
        db  9,4, 18,4           ; both kick at once
        db  8,1, 19,1
        db  7,5, 20,2           ; player leaps the flying kick
        db  6,5, 21,2
        db  5,0, 22,0           ; and they reset
        db  4,0, 23,0
        db  4,1, 23,1
        db  4,0, 23,0
CBDAT:                          ; 32 poses of the hero cube, 32x32 each
        INCBIN "build/cubebig.bin"

SKYREV:                         ; the sunset, top row to horizon - FULL
        db $07,$07,$07          ;   attribute bytes, ink included, because
        db $0F,$0F              ;   the runner's dots take the ink colour
        db $4F,$4F              ;   of whatever cell they land in.  White
        db $1F,$1F              ;   ink reads against every dark band...
        db $5F,$5F
        db $17,$17
        db $57,$57,$57,$57      ;   ...but not against yellow, so the two
        db $30,$30              ;   yellow bands at the horizon - exactly
        db $70,$70              ;   where his legs are - take BLACK ink
BASICCONTEXT: INCBIN "assets/basic/context.bin"
BASICCONTEXTEND:
BASICSTACK: INCBIN "assets/basic/stack.bin"
BASICSTACKEND:
BASICLISTING:
        INCLUDE "build/basic-listing.asm"
        ASSERT $ <= $8000

        ORG SHADEP1             ; the warm shade tables died with the
; ------------------------------------------------------------------- DOTT
; The dot-flow tunnel: 72 dots in six coherent rings streaming outward
; along baked trajectories.  A travelling sine indexed by DEPTH bends the
; whole tube as it flies; each geometry has its own spin cadence and
; direction, bend speed and dot velocity (PTAB), so tube, box and star
; each move differently.
DOTT:
        ld ix,DOTS
        ld b,72
.dt:
        push bc
        ld l,(ix+2)             ; unplot at the cached address
        ld h,(ix+3)
        ld a,(ix+4)
        cpl
        and (hl)
        ld (hl),a
        ld a,(ix+1)
.spd:   add a,1                 ; self-modified: this tunnel's velocity
        and 31
        ld (ix+1),a
        ld a,(ix+0)             ; angle + the field's spin, mod 12
        ld e,a
        ld a,(DROT)
        add a,e
        cp 12
        jr c,.am
        sub 12
.am:
        ld l,a                  ; HL = table row (angle * 64 + depth * 2)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(ix+1)
        add a,a
        ld e,a
        ld d,0
        add hl,de
        ld de,(DGEO)
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,(ix+1)             ; the bend: a sine travelling down the
        add a,a                 ; tube, sampled by depth - near and far
        add a,a                 ; rings sway out of phase
        ld c,a
        ld a,(BPH)
        add a,c
        ld l,a
        ld h,HIGH SINTAB
        ld a,(hl)
        add a,a
        sub 16                  ; a broad bend, sampled differently by depth
        add a,e
        ld e,a
        ld a,l
        add a,a
        add a,64
        ld l,a
        ld a,(hl)
        sub 8                   ; two vertical turns for each horizontal bend
        add a,d
        ld d,a
        call PIXADDR
        ld c,a
        or (hl)
        ld (hl),a
        ld (ix+2),l             ; remember where we are for next frame
        ld (ix+3),h
        ld (ix+4),c
        ld bc,6
        add ix,bc
        pop bc
        djnz .dt
        ld a,(DBST)             ; the bend crawls down the tube
        ld e,a
        ld a,(BPH)
        add a,e
        ld (BPH),a
        ld a,(DSPM)             ; spin at this tunnel's cadence...
        ld e,a
        ld a,(FRAMES)
        and e
        ret nz
        ld a,(DSPD)             ; ...in its own direction (11 = -1 mod 12)
        ld e,a
        ld a,(DROT)
        add a,e
        cp 12
        jr c,.dr
        sub 12
.dr:
        ld (DROT),a
        ret

DGEO:   dw DOTTAB
DROT:   db 0
BPH:    db 0
DSPM:   db 7
DSPD:   db 1
DBST:   db 2
PTAB:                           ; spin cadence mask, spin step, bend, speed
        db 7,1,2,1, 0,0,0,0     ; TUBE: stately clockwise, gentle bend
        db 3,11,5,1, 0,0,0,0    ; BOX: busy anticlockwise, strong bend
        db 7,1,3,2, 0,0,0,0     ; STAR: double-speed dots


BCURSOR:                        ; a double-height block leading the
        ld hl,(BPTR)            ; type-on; solid off the beat, gone on it
        ld a,(hl)
        cp $FF
        jr nz,.live
        xor a                   ; message complete: cursor rests
        jr .draw
.live:
        ld a,(FRAMES)
        and 16
        jr nz,.draw             ; A = 16 -> blank phase? no: draw solid
        ld a,$FF
        jr .draw2
.clear:
.draw:
        xor a
.draw2:
        ld d,a
        ld a,(BROW)
        call ROWADDR
        ld a,d
        REPT 8
        ld (hl),a
        inc h
        EDUP
        ld a,(BROW)
        inc a
        call ROWADDR
        ld a,d
        REPT 8
        ld (hl),a
        inc h
        EDUP
        ld a,(BROW)             ; the cursor cell takes the line colour
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(BCX)
        ld c,a
        ld b,0
        add hl,bc
        ld bc,ATTRS
        add hl,bc
        ld a,(BCOL)
        ld (hl),a
        ld bc,32
        add hl,bc
        ld (hl),a
        ret

DOTSET:                         ; tunnel stage: dark, ringed, dots spread
        call STARSET
        ld hl,CUBEATTR
        ld de,ATTRS
        ld bc,672
        ldir
        ld ix,DOTS
        ld b,72
        ld c,0                  ; angle round-robin
        ld d,0                  ; ring depth
.i:
        ld a,c
        ld (ix+0),a
        ld a,d
        and 31
        ld (ix+1),a
        ld a,LOW CBUF           ; harmless first unplot target
        ld (ix+2),a
        ld a,HIGH CBUF
        ld (ix+3),a
        xor a
        ld (ix+4),a
        push bc
        ld bc,6
        add ix,bc
        pop bc
        inc c
        ld a,c
        cp 12
        jr c,.k
        ld c,0                  ; ring complete: the next one is five
        ld a,d                  ; depth steps behind - coherent rings
        add a,5                 ; flying at you, not a starburst
        ld d,a
.k:
        djnz .i
        xor a
        ld (DROT),a
        ret
RZBLUE:                         ; one row of tiles, blue on black
        DUP 32
        IFDEF TARGET128
        add hl,de               ; u, with v in the alternate register set
        ld a,h
        exx
        add hl,de
        and h
        and 8
        or $47
        exx
        ld (bc),a
        inc c
        ELSE
        add hl,sp
        add ix,bc
        ld a,h
        and ixh
        and 8
        or $47
        ld (de),a
        inc e
        ENDIF
        EDUP
        jp ROTZOOM.back

RZRED:
        DUP 32
        IFDEF TARGET128
        add hl,de
        ld a,h
        exx
        add hl,de
        and h
        and 8
        add a,a
        or $47
        exx
        ld (bc),a
        inc c
        ELSE
        add hl,sp
        add ix,bc
        ld a,h
        and ixh
        and 8
        add a,a
        or $47
        ld (de),a
        inc e
        ENDIF
        EDUP
        jp ROTZOOM.back


; ---------------------------------------------------------------- RUNNER
; Three articulated dot figures with independent travel and gait clocks.
; Erase every old figure before drawing any new one so overlaps stay intact.
RUNNER:
        ld (.rsp+1),sp
        ld a,(RDCNT)            ; unplot last frame's figures
        or a
        jr z,.draw
        ld b,a
        ld sp,(RDEND)
.er:
        pop af                  ; A = mask
        pop hl                  ; HL = the upper of the dot's two rows;
        ld c,a                  ; the lower one is recomputed, not stored
        cpl
        and (hl)
        ld (hl),a
        ld a,h
        and 7
        cp 7
        jr z,.e1
        inc h
        ld a,c
        cpl
        and (hl)
        ld (hl),a
.e1:
        djnz .er
.draw:
        ld sp,RDTOP
        ld a,(FRAMES)           ; the companion, half size and further
        rrca                    ; back.  Four frames a pose against the
        rrca                    ; runner's two, which is exactly the ratio
        rrca
        and 7                   ; of their ground speeds - so his legs keep
        add a,3                 ; time with his own drift, and the two are
        and 7                   ; never in step.  Mask AFTER the offset too:
        ld c,12                 ; companion descriptors follow the hero
        call RUNPOSE
        ld a,(FRAMES)           ; slower companion advances along the road,
        rrca                    ; with a different stride clock
        rrca
        and 127
        add a,16
        ld (RFX),a
        ld a,100                ; and his feet meet the same ground
        ld (RFY),a
        xor a                   ; dark too: a colour would vanish into
        ld (RFINK),a            ; the yellow bands the way white did
        ld hl,.third
        ld (RUNFIG.out+1),hl
        jp RUNFIG
.third:
        ld a,(FRAMES)
        rrca
        rrca
        and 7
        add a,5
        and 7
        ld c,12
        call RUNPOSE
        ld a,(FRAMES)
        rrca
        and 127
        add a,76
        ld (RFX),a
        ld a,94
        ld (RFY),a
        ld hl,.two
        ld (RUNFIG.out+1),hl
        jp RUNFIG
.two:
        ld a,(FRAMES)
        and 31
        ld l,a
        ld h,0
        ld de,RUNPHASE
        add hl,de
        ld a,(hl)
        ld c,0
        call RUNPOSE
        ld a,(FRAMES)           ; he crosses the screen once a slot
        rrca
        and 127
        add a,20
        ld (RFX),a
        ld a,36                 ; and his feet land on the horizon
        ld (RFY),a
        xor a                   ; and the runner himself is a silhouette
        ld (RFINK),a
        ld hl,.done
        ld (RUNFIG.out+1),hl
        jp RUNFIG
.done:
        ld (RDEND),sp
        ld hl,RDTOP
        ld de,(RDEND)
        or a
        sbc hl,de
        srl h
        rr l
        srl h
        rr l
        ld a,l
        ld (RDCNT),a
.rsp:   ld sp,0
        jp GROUND               ; then the floor rushes past beneath them

RUNPOSE:                        ; A = pose, C = descriptor base (0 / 12)
        add a,c
        ld l,a
        ld h,0
        ld e,l
        ld d,h
        add hl,hl
        add hl,de               ; 3 bytes per generated descriptor
        ld de,RUNPOSES
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        ld (RUNFIG.count+1),a
        push de
        pop ix
        ret
        INCLUDE "build/runner-index.asm"

RUNFIG:                         ; IX = pose, RFX/RFY = where.  Never
.count: ld b,0           ; CALLed: SP is carrying the record stack
.dl:
        ld a,(ix+0)
        ld c,a
        ld a,(RFX)
        add a,c
        ld e,a                  ; E = screen x
        ld a,(ix+1)
        ld c,a
        ld a,(RFY)
        add a,c
        ld d,a                  ; D = screen y
        ld l,d
        ld h,HIGH ROWLO
        ld a,(hl)
        inc h
        ld h,(hl)
        ld l,a
        ld a,e
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ld a,e
        and 7
        ld e,a
        ld d,HIGH BITMSK
        ld a,(de)
        ld e,a
        srl a                   ; two pixels wide, and two tall: a single
        or e                    ; pixel is lost against a lit sky
        ld c,a
        or (hl)
        ld (hl),a
        push hl                 ; the record: where, and with what
        ld a,c
        push af
        ld a,h                  ; the second row, unless this dot landed
        and 7                   ; on a cell's last scanline
        cp 7
        jr z,.one
        inc h
        ld a,c
        or (hl)
        ld (hl),a
.one:
        inc ix
        inc ix
        djnz .dl
.out:   jp 0                    ; self-modified continuation

RUNSET:                         ; scene entry: the sunset, painted once
        call STARSET
        ld hl,ATTRS+32
        ld c,1                  ; SKYREV is indexed by attr row, 0 at the top
.r:
        ld a,LOW SKYREV
        add a,c
        ld e,a
        ld a,HIGH SKYREV
        adc a,0
        ld d,a
        ld a,(de)               ; paper, bright and ink all baked in
        ld e,a
        DUP 32
        ld (hl),e
        inc hl
        EDUP
        inc c
        ld a,c
        cp 21
        jp nz,.r
        call GROUNDSET
        xor a
        ld (RDCNT),a
        ret

RFX:    db 0
RFY:    db 0
RFINK:  db 0
RUNDAT:
        INCBIN "build/runner.bin"

; ---------------------------------------------------------------- TRAIN
; The bout, moved onto a flatbed wagon at speed.  Three bands of scenery
; tear past at three different rates, and the deck rocks a pixel either
; way on the rails with the fighters rocking with it - so the fight reads
; as happening ON something moving, rather than in front of something
; moving.  All of it rides GLINE, the same cyclic-strip copier the
; runner's floor uses.
TRAIN:
        ld a,(FRAMES)           ; how the wagon is sitting this frame
        add a,a
        add a,a
        ld l,a
        ld h,HIGH SINTAB
        ld a,(hl)
        rrca
        rrca
        rrca
        and 3                   ; 0..2
        ld (YROCK),a
        ld hl,GPATSLOW          ; far scenery, barely moving
        ld a,(FRAMES)
        rrca
        rrca
        and 63
        ld de,$4860
        call GLINE
        ld hl,GPATFAST          ; nearer posts whipping past
        ld a,(FRAMES)
        add a,a
        and 63
        ld de,$4C80
        call GLINE
        ld hl,GPATFAST          ; sleepers under the wagon
        ld a,(FRAMES)
        add a,a
        add a,a
        and 63
        ld de,$5060
        call GLINE
        ld hl,GPATFAST
        ld a,(FRAMES)
        add a,a
        add a,a
        add a,11
        and 63
        ld de,$5660
        call GLINE
        ld hl,GPATSLOW          ; and the rail itself, a blur
        ld a,(FRAMES)
        rrca
        and 63
        ld de,$5480
        call GLINE
        ld hl,DECKW             ; wipe the deck's whole rocking range -
        ld b,6                  ;   six scanlines, addressed from a table
.dw:                            ;   because a bitmap row's successor is
        push bc                 ;   never just the next address
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ex de,hl
        xor a
        REPT 32
        ld (hl),a
        inc l
        EDUP
        pop hl
        pop bc
        djnz .dw
        ld a,(YROCK)
        add a,a
        ld e,a
        ld d,0
        ld hl,DECKW             ; the deck where it sits this frame...
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld h,b
        ld l,c
        ld a,$FF
        REPT 32
        ld (hl),a
        inc l
        EDUP
        ld hl,DECKW+6           ; ...and the wagon's edge three below it
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld h,b
        ld l,c
        ld a,$99
        REPT 32
        ld (hl),a
        inc l
        EDUP
        ret

DECKW:  dw $5040, $5140, $5240  ; deck at y = 144, 145, 146 - all inside
        dw $5440, $5540, $5640  ; attr row 18, where the deck colour is;
                                ; edge at y = 148, 149, 150
YROCK:  db 0

TRAINSET:                       ; scene entry: night, horizon, deck, track
        call STARSET
        ld hl,ATTRS
        ld b,11                 ; rows 0-10: night, and nothing in it
        ld c,$00
        call TRROWS
        ld b,1                  ; row 11: far lights going by
        ld c,$07
        call TRROWS
        ld b,1                  ; row 12: the near posts
        ld c,$05
        call TRROWS
        ld b,5                  ; rows 13-17: the fighters' own rows
        ld c,$00
        call TRROWS
        ld b,1                  ; row 18: the deck
        ld c,$06
        call TRROWS
        ld b,2                  ; rows 19-20: sleepers and rail
        ld c,$05
        call TRROWS
        ret

TRROWS:                         ; B rows of colour C from HL
.r:
        push bc
        ld a,c
        REPT 32
        ld (hl),a
        inc hl
        EDUP
        pop bc
        djnz .r
        ret


        ASSERT $ <= MAPS        ; the reclaimed map region starts here

        ORG RDTOP               ; the reclaimed map region
; ------------------------------------------------------------------ ROTO
; The roto grid: a plane seen from above, turning and breathing, built
; from two layers off ONE rotation.  The attribute layer is a rotozoom
; chequer - two colours a paper-bit apart, so the texture test is an XOR,
; a mask and an ADD.  The bitmap layer is a lattice of single pixels
; sitting exactly on that chequer's corners, because the same table
; carries both the texel step and the lattice step.
;
; Budget: the chequer costs 63T a cell and there are 32 to a row, so a
; row lands in 2016T against the beam's 1792T - but the top border hands
; us a 14000T head start, which the paint never gives back.  Dots go
; first: they are bitmap writes, and the beam reads bitmap and attrs
; together.
ROTO:
        call ROTDOTS            ; keep the depth layer, using the prepared pose
        call ROTCOPY            ; publish matching colours ahead of the beam
        call ROTPICK
        jp ROTZOOM

ROTPICK:                        ; this frame's angle, zoom and steps
        ld hl,(FRAMES)          ; the zoom breathes over ~10 seconds
        srl h
        rr l
        ld h,HIGH SINTAB
        ld a,(hl)               ; 0..16
        srl a
        cp 8
        jr c,.zk
        ld a,7
.zk:
        ld e,a                  ; E = zoom level
        ld hl,(RANG)            ; the turn: an 8.8 accumulator over 64
        ld bc,(RASPD)           ; wedges, so one revolution is ~3.4s
        add hl,bc
        ld (RANG),hl
        ld a,h
        and 63
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl               ; angle * 8
        ld a,e
        add a,a                 ; zoom * 512
        add a,h
        add a,HIGH ROTAB
        ld h,a
        ld e,(hl)               ; A: the u step per column
        inc hl
        ld d,(hl)
        inc hl
        ld (RA),de
        ld e,(hl)               ; B: the v step per column, negated
        inc hl
        ld d,(hl)
        inc hl
        ld (RB),de
        push hl
        ld hl,0
        or a
        sbc hl,de
        ld (RNB),hl
        pop hl
        ld e,(hl)               ; DX, DY: the lattice step per i
        inc hl
        ld d,(hl)
        inc hl
        ld (RDX),de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (RDY),de

        ld hl,(RUORG)           ; the floor drifts as well as turns
        ld bc,96
        add hl,bc
        ld (RUORG),hl
        ld hl,(RVORG)
        ld bc,48
        add hl,bc
        ld (RVORG),hl
                                ; row 0 col 0 = origin - 16A - 10B (u)
        ld hl,(RA)              ;                      + 16B - 10A (v)
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld (RT1),hl             ; 16A
        ld hl,(RB)
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld (RT2),hl             ; 16B
        ld hl,(RA)
        add hl,hl
        ld (RT3),hl             ; 2A
        add hl,hl
        add hl,hl
        ld de,(RT3)
        add hl,de
        ld (RT3),hl             ; 10A
        ld hl,(RB)
        add hl,hl
        ld (RT4),hl
        add hl,hl
        add hl,hl
        ld de,(RT4)
        add hl,de
        ld (RT4),hl             ; 10B
        ld hl,(RUORG)
        ld de,(RT1)
        or a
        sbc hl,de
        ld de,(RT4)
        or a
        sbc hl,de
        ld (RU0),hl
        ld hl,(RVORG)
        ld de,(RT2)
        add hl,de
        ld de,(RT3)
        or a
        sbc hl,de
        ld (RV0),hl
        ret

; ---------------------------------------------------------------- ROTDOTS
; The lattice: 7x7 points stepped in 9.7 fixed point, so the integer part
; spans 0..511 and a point that has left the screen falls out on a single
; carry.  Records are PUSHed - address then mask - which makes next
; frame's erase a pop, a cpl and an and.
ROTDOTS:
        ld (.rsp+1),sp
        ld a,(RDCNT)            ; unplot last frame's lattice
        or a
        jr z,.draw
        ld b,a
        ld sp,(RDEND)
.er:
        pop af                  ; A = mask
        pop hl                  ; HL = where it went
        cpl
        and (hl)
        ld (hl),a
        djnz .er
.draw:
        ld sp,RDTOP
        ld hl,(RDX)
        add hl,hl
        ld (RT1),hl             ; 3DX
        add hl,hl
        ld de,(RT1)
        or a
        sbc hl,de
        ld (RT1),hl
        ld hl,(RDY)
        add hl,hl
        ld (RT2),hl
        add hl,hl
        ld de,(RT2)
        or a
        sbc hl,de
        ld (RT2),hl             ; 3DY
        ld hl,16384             ; i=-3, j=-3: 128.0 - 3DX + 3DY
        ld de,(RT1)
        or a
        sbc hl,de
        ld de,(RT2)
        add hl,de
        ld (RJX),hl
        ld hl,12288             ; original fixed 96-pixel camera height
        ld de,(RT2)
        or a
        sbc hl,de
        ld de,(RT1)
        or a
        sbc hl,de
        ld (RJY),hl
        ld a,7
        ld (RJN),a
.jrow:
        ld hl,(RJX)
        ld ix,(RJY)
        ld bc,(RDX)
        ld de,(RDY)
        ld iyl,7
.icol:
        ld a,l                  ; x: (HL<<1)>>8, carry = off screen
        rla
        ld a,h
        rla
        jr c,.skip
        ld (RXT),a
        ld a,ixl                ; y likewise
        rla
        ld a,ixh
        rla
        jr c,.skip
        cp 168                  ; the bottom three rows stay dark
        jr nc,.skip
        exx
        ld d,a
        ld a,(RXT)
        ld e,a
        ld l,d
        ld h,HIGH ROWLO
        ld a,(hl)
        inc h
        ld h,(hl)
        ld l,a
        ld a,e
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ld a,e
        and 7
        ld e,a
        ld d,HIGH BITMSK
        ld a,(de)
        ld e,a
        srl a                   ; two pixels wide (the left column of the
        or e                    ; screen loses its second - no matter)
        ld c,a
        or (hl)
        ld (hl),a
        push hl                 ; the record: where, and with what
        ld a,c
        push af
        ld a,h                  ; and two pixels tall, unless the cell's
        and 7                   ; last scanline is where we landed
        cp 7
        jr z,.one
        inc h
        ld a,c
        or (hl)
        ld (hl),a
        push hl
        ld a,c
        push af
.one:
        exx
.skip:
        add hl,bc               ; next i
        add ix,de
        dec iyl
        jp nz,.icol
        ld hl,(RJX)             ; next j: the perpendicular step
        ld de,(RDY)
        or a
        sbc hl,de
        ld (RJX),hl
        ld hl,(RJY)
        ld de,(RDX)
        add hl,de
        ld (RJY),hl
        ld a,(RJN)
        dec a
        ld (RJN),a
        jp nz,.jrow
        ld (RDEND),sp           ; how many actually landed
        ld hl,RDTOP
        ld de,(RDEND)
        or a
        sbc hl,de
        srl h
        rr l
        srl h
        rr l
        ld a,l
        ld (RDCNT),a
.rsp:   ld sp,0
        ret

; ---------------------------------------------------------------- ROTZOOM
; The chequer.  SP carries the u step so that HL, IX, BC and DE can hold
; the two accumulators, the v step and the attribute pointer at once -
; nothing is spilled inside the 32-cell run.
ROTZOOM:
        IFNDEF TARGET128
        ld (.rsp+1),sp
        ENDIF
        ld a,(FRAMES)           ; the wash creeps down a row every four
        and 3                   ; frames, then flips which colour leads,
        jr nz,.nw               ; so the plane goes blue-red-blue for ever
        ld a,(RWASH)
        inc a
        cp 22
        jr c,.ws
        ld a,(RWASHC)
        xor 1
        ld (RWASHC),a
        xor a
.ws:
        ld (RWASH),a
.nw:
        ld hl,(RU0)
        ld (RU),hl
        ld hl,(RV0)
        ld (RV),hl
        ld de,BSBUF
        ld a,21
        ld (RROW),a
        xor a
        ld (RRI),a
        ld a,(TITLEF)           ; the title card owns row 0 while it shows
        cp 164
        jr nc,.row
        ld de,BSBUF+32
        ld a,20
        ld (RROW),a
.row:
        ld a,(RWASH)            ; which side of the wash is this row on?
        ld c,a
        ld a,(RRI)
        cp c
        ld a,0
        jr nc,.s
        inc a
.s:
        ld c,a
        ld a,(RWASHC)
        xor c
        ld hl,RZBLUE            ; the two painters differ by one ADD: the
        jr z,.pk                ; texture bit lands on paper 1 or paper 2,
        ld hl,RZRED             ; over a paper that is always black
.pk:
        ld (.disp+1),hl
        ld hl,(RU)
        ld ix,(RV)
        ld bc,(RNB)
        IFDEF TARGET128
        ld b,d
        ld c,e
        exx
        ld hl,(RV)
        ld de,(RNB)
        exx
        ld de,(RA)
        ELSE
        ld sp,(RA)
        ENDIF
.disp:  jp 0                    ; RZBLUE / RZRED - never CALLed: SP is
.back:                          ; carrying the u step
        IFDEF TARGET128
        ld d,b
        ld e,c
        ENDIF
        ld a,e                  ; rows are 32-aligned: E wraps every 8
        or a
        jr nz,.ne
        inc d
.ne:
        ld hl,(RU)              ; next row: u += B, v += A
        ld bc,(RB)
        add hl,bc
        ld (RU),hl
        ld hl,(RV)
        ld bc,(RA)
        add hl,bc
        ld (RV),hl
        ld a,(RRI)
        inc a
        ld (RRI),a
        ld a,(RROW)
        dec a
        ld (RROW),a
        jp nz,.row
        IFNDEF TARGET128
.rsp:   ld sp,0
        ENDIF
        ret

ROTSET:                         ; scene entry: an empty plane, no records
        call STARSET
        xor a
        ld (RDCNT),a
        ld hl,0
        ld (RUORG),hl
        ld (RVORG),hl
        call ROTPICK
        jp ROTZOOM              ; prime both layers before the first displayed frame

RANG:   dw 0
RASPD:  dw $0060
RA:     dw 0
RB:     dw 0
RNB:    dw 0
RDX:    dw 0
RDY:    dw 0
RU0:    dw 0
RV0:    dw 0
RU:     dw 0
RV:     dw 0
RUORG:  dw 0
RVORG:  dw 0
RJX:    dw 0
RJY:    dw 0
RT1:    dw 0
RT2:    dw 0
RT3:    dw 0
RT4:    dw 0
RDEND:  dw 0
RDCNT:  db 0
RWASH:  db 0
RWASHC: db 0
RRI:    db 0
RJN:    db 0
RXT:    db 0
RROW:   db 0
        ASSERT $ <= BSBUF

; ---------------------------------------------------------------- BIGSCR
; Native 32x24 glyphs scroll through a 24-row buffer at one pixel per
; 50Hz frame. The 128K version sits above the console.
; Each byte column follows the sine wave independently.
BIGSCR:
        call BSFEED
        call BSCOLS
        jp BSPAINT

BSGLYPH:                        ; A = ASCII -> a baked 32x24 glyph
        sub 32
        add a,a
        ld l,a
        ld h,0
        ld de,BSFONTINDEX
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        ld de,BSGLY
        ld bc,96
        ldir
        ret

BSFETCH:                        ; the big scroller keeps its own text:
.tptr:  ld hl,BSTEXT            ; at 32 pixels a letter it reads a quarter
        ld a,(hl)               ; as fast as the snake, so it needs its
        inc hl                  ; own words and no long runs of space
        or a
        jr nz,.ok
        ld hl,BSTEXT
        ld a,(hl)
        inc hl
.ok:
        ld (.tptr+1),hl
        ret

        INCLUDE "build/font-index.asm"

BSFEED:                         ; one pixel of scroll
        ld a,(BSBIT)
        or a
        jr nz,.sh
        call BSFETCH            ; the letter is used up: build the next
        call BSGLYPH
        ld a,32
        ld (BSBIT),a
.sh:
        ld hl,BSBIT
        dec (hl)
        ld ix,BSGLY
        ld c,0                  ; buffer row
.row:
        ld a,c                  ; HL = last byte of this row: rows are
        and 7                   ; 32 bytes and the buffer is page aligned,
        rrca                    ; so neither ever crosses the other
        rrca
        rrca
        or 31
        ld l,a
        ld a,c
        rrca
        rrca
        rrca
        and 31
        add a,HIGH BSBUF
        ld h,a
        or a                    ; no stray bit into the glyph
        rl (ix+3)               ; the glyph row shifts left and its top
        rl (ix+2)               ; pixel falls out into the carry
        rl (ix+1)
        rl (ix+0)
        DUP 32
        ld a,(hl)               ; register rotate is cheaper than RL (HL)
        rla                     ; carry rides the chain right to left
        ld (hl),a
        dec l
        EDUP
        push bc
        ld bc,4
        add ix,bc
        pop bc
        inc c
        ld a,c
        cp 24
        jp nz,.row
        ret

BSCOLS:                         ; spread the colour wash over eight frames
        ld a,(FRAMES)
        and 7
        cp 6                    ; six rows cover the letters and their wave
        ret nc
        ld b,a
        add a,BANDTOP/8-1
        ld l,a
        ld h,0
        DUP 5
        add hl,hl
        EDUP
        ld de,ATTRS
        add hl,de
        ld a,(FRAMES)
        rrca
        rrca
        rrca
        sub b
        and 7
        add a,LOW CTAB
        ld e,a
        ld a,HIGH CTAB
        adc a,0
        ld d,a
        ld a,(de)
        and $38
        rrca
        rrca
        rrca
        or $40
        DUP 32
        ld (hl),a
        inc l
        EDUP
        ret

BSPAINT:                        ; 32 columns, each at its own height
; The column index lives in C for the whole run and the frame's wave
; phase is computed once, not thirty-two times.  The generated descent
; variants touch only A, HL and DE, which is what makes that safe.
        ld a,(FRAMES)           ; the wave travels along the text
        add a,a
        ld (BSPH),a
        ld c,0
.col:
        ld a,c                  ; three sine steps a column, so a letter
        ld b,a                  ; rides the wave whole
        add a,a
        add a,b
        ld b,a
        ld a,(BSPH)
        add a,b
        ld l,a
        ld h,HIGH SINTAB
        ld a,(hl)               ; 0..16
        add a,BANDTOP-1         ; start on the guard row above the letter
        ld b,a
        and 7
        ld d,a
        ld a,b
        rra
        rra
        rra
        and 24
        or d
        or 64
        ld d,a
        ld a,b
        rla
        rla
        and $E0
        or c
        ld e,a                  ; DE = where this column starts
        ld a,b
        and 7                   ; and which descent variant fits it
        add a,a
        ld l,a
        ld h,0
        push bc
        ld bc,SDJ
        add hl,bc
        ld a,(hl)
        ld (.cw+1),a
        inc hl
        ld a,(hl)
        ld (.cw+2),a
        pop bc
        ld l,c
        ld h,HIGH BSBUF
.cw:    call 0                  ; SD0..SD7 - these use A, HL and DE only
        inc c
        ld a,c
        cp 32
        jp nz,.col
        ret

BSPH:   db 0

BSSET:                          ; scene entry: empty buffer, first letter
        call STARSET
        ld hl,BSTEXT
        ld (BSFETCH.tptr+1),hl
        ld hl,BSBUF
        ld de,BSBUF+1
        ld bc,767
        ld (hl),0
        ldir
        call BSFETCH
        call BSGLYPH
        ld a,32
        ld (BSBIT),a
        ret

BSBIT:  db 32
FONT1:  INCBIN "build/font1.bin"
        ASSERT $ <= BSBUF

        ORG $AF00
RUNSMALL: INCBIN "build/runner-small.bin"
        ASSERT $ <= BSGLY
        ORG $B300
        INCLUDE "build/bigscr.asm"
MCDAT:
        INCBIN "build/minicube.bin"

; --------------------------------------------------------------- SLIDER
; The other transition: the outgoing image slides up and off a character
; row at a time, the incoming stage following it in from the bottom.
;
; This one is NOT free, and cannot be.  There is no hardware scroll, so
; sliding means physically moving 5,888 bytes of bitmap and 736 of attrs
; every step.  Instruction timings alone say ~140k T-states, two frames -
; but the screen is CONTENDED and LDIR touches it at both ends, so the
; measured cost is nearer four frames a step: 12-13 fps across the ~2
; seconds a slide lasts.  It alternates with the dissolve, which costs a
; thousandth of it, so the show only pays this every other scene change.
; If it needs to be cheaper, the lever is the copy itself: a stack-based
; block move (POP/PUSH, ~12T a byte) beats LDIR's 21T by nearly half.
SLIDER:
        IFDEF TARGET128
        ld a,(WIPEF)
        cp 21
        ret nc
        ENDIF
; The incoming scene's stage slides DOWN over the outgoing image, which
; stays where it is.  That is the cheap direction and it was the one
; asked for: you see old and new at once, and the new one is static.
;
; Cost is one character row a step - 256 bitmap bytes and 32 attributes,
; about 6k T-states - because rows already covered stay covered.  The
; first version of this dragged the whole 5,888-byte image upward every
; step instead, which measured 12-17 fps over 1.7 seconds.  Moving the
; curtain rather than the picture is the entire difference.
        ld a,(WIPEF)
        cp 24
        ret nc
        ld c,a                  ; C = the row the leading edge is on
        and 24
        or 64
        ld (SLDH),a
        ld a,c
        and 7
        rrca
        rrca
        rrca
        ld (SLDL),a
        xor a
        ld (SLS),a
        ld b,8                  ; blank that row's eight scanlines
.bl:
        ld a,(SLS)
        ld h,a
        ld a,(SLDH)
        or h
        ld h,a
        ld a,(SLDL)
        ld l,a
        push bc
        ld b,32
        xor a
.bll:
        ld (hl),a
        inc l
        djnz .bll
        pop bc
        ld a,(SLS)
        inc a
        ld (SLS),a
        djnz .bl
        ld a,(WIPEF)            ; the image below thins as the curtain
        srl a                   ; comes down, so the edge is not a hard
        cp 16                   ; line - at HALF the curtain's rate, or
        jr nc,.edge             ; it eats the picture before the curtain
        add a,a                 ; ever gets there
        ld l,a
        ld h,0
        ld de,BPOS
        add hl,de
        ld d,(hl)
        inc hl
        ld e,(hl)
        xor a
        push bc
        call WCELLS
        pop bc
.edge:
        ld a,c                  ; the row behind the edge goes dark
        or a
        jr z,.lit
        dec a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,ATTRS
        add hl,de
        ld b,32
        xor a
.eb:
        ld (hl),a
        inc hl
        djnz .eb
.lit:
        ld l,c                  ; and the leading edge is painted LAST,
        ld h,0                  ; so the dissolve cannot punch holes in
        add hl,hl               ; it - it stays a clean bright line
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,ATTRS
        add hl,de
        ld b,32
        ld a,$7F
.ea:
        ld (hl),a
        inc hl
        djnz .ea
        ret

SLDH:   db 0
SLDL:   db 0
SLSH:   db 0
SLSL:   db 0
SLS:    db 0
        ASSERT $ <= MAPSEND

        ORG $DC00
ROWLO:  INCBIN "build/rowlo.bin"
ROWHI:  INCBIN "build/rowhi.bin"
DBLTAB: INCBIN "build/dbltab.bin"
        ASSERT $ <= $E000

        ORG DOTTAB
        INCBIN "build/dots.bin"
        ORG ROTAB
        INCBIN "build/roto.bin"
        ORG $F300
DOTCUBE:
        ; Corner orbits do not overlap the hero or each other. Erase and
        ; repaint each companion together, before the beam reaches its rows.
        ld ix,CBOLD+4
        ld iy,CBPHASE
        ld a,4
        ld (CBLEFT),a
.mini:
        ld b,(ix+0)
        ld c,(ix+1)
        ld d,(ix+2)
        ld e,(ix+3)
        call CBCLEAR
        ld a,(FRAMES)
        add a,(iy+0)
        ld l,a
        ld h,HIGH SINTAB
        ld a,(hl)
        add a,(iy+1)
        ld b,a
        ld a,l
        add a,64
        ld l,a
        ld a,(hl)
        rrca
        rrca
        rrca
        and 3
        add a,(iy+2)
        ld c,a
        ld (ix+0),b
        ld (ix+1),c
        ld a,(FRAMES)
        add a,(iy+0)
        bit 7,a
        jr z,.small
        rrca
        rrca
        and 31
        ld l,a
        ld h,0
        DUP 7
        add hl,hl
        EDUP
        ld de,CBDAT
        add hl,de
        ex de,hl
        ld (ix+2),32
        ld (ix+3),4
        push ix
        call CBBLIT
        pop ix
        jr .next
.small:
        rrca
        rrca
        and 31
        ld (ix+2),16
        ld (ix+3),2
        push ix
        call MONE
        pop ix
.next:
        ld de,4
        add ix,de
        ld de,3
        add iy,de
        ld hl,CBLEFT
        dec (hl)
        jp nz,.mini
        call CBHERO             ; small cubes must reach the beam first
        jp CBPREP

CBHERO:
        push ix
        ld hl,(FRAMES)
        srl h
        rr l                    ; divide the full counter: no odd-frame phase flip
        ld h,HIGH SINTAB
        ld a,(hl)
        add a,56
        ld (CBY),a
        ld c,a
        ld a,(CBOLD)
        cp c
        jr z,.draw
        jr c,.edge              ; moving down exposes only the old top row
        add a,63                ; moving up exposes only the old bottom row
.edge:
        ld b,a
        ld c,12
        ld d,1
        ld e,8
        call CBCLEAR
.draw:
        ld a,(CBY)
        ld b,a
        ld c,12
        ld a,b
        ld (CBOLD),a
        ld a,c
        ld (CBOLD+1),a
        ld de,(CBFRONT)
        ld ixl,64
.hero:
        call CBROW
        DUP 8
        ld a,(de)
        ld (hl),a
        inc de
        inc l
        EDUP
        inc b
        dec ixl
        jr nz,.hero
        pop ix
        ret

; B=y, C=byte column; preserve BC/DE and all index registers.
CBROW:
        ld l,b
        ld h,HIGH ROWLO
        ld a,(hl)
        or c
        inc h
        ld h,(hl)
        ld l,a
        ret

CBCLEAR:                        ; B,C top/left, D height, E byte width
.row:
        call CBROW
        ld a,e
        cp 8
        jr z,.eight
        cp 4
        jr z,.four
        xor a
        jr .two
.eight:
        xor a
        DUP 4
        ld (hl),a
        inc l
        EDUP
.four:
        xor a
        DUP 2
        ld (hl),a
        inc l
        EDUP
.two:
        ld (hl),a
        inc l
        ld (hl),a
        inc b
        dec d
        jr nz,.row
        ret

CBEXPAND:
        ld a,(FRAMES)
        rrca
        rrca
        and 31
        ld l,a
        ld h,0
        DUP 7
        add hl,hl
        EDUP
        ld de,CBDAT
        add hl,de
        ld de,CBUF
        ld b,32
.row:
        DUP 4
        ld a,(hl)
        inc hl
        exx
        ld l,a
        ld h,HIGH DBLTAB
        ld a,(hl)
        exx
        ld (de),a
        inc de
        exx
        inc h
        ld a,(hl)
        exx
        ld (de),a
        inc de
        EDUP
        push hl
        push bc
        ld hl,-8
        add hl,de
        ld bc,8
        ldir
        pop bc
        pop hl
        djnz .row
        ret

CBPREP:
        ld a,(CBPART)
        or a
        jr nz,.resume
        ld a,(FRAMES)
        rrca
        rrca
        inc a
        and 31
        ld l,a
        ld h,0
        DUP 7
        add hl,hl
        EDUP
        ld de,CBDAT
        add hl,de
        ld de,(CBBACK)
        jr .paint
.resume:
        ld hl,(CBSRC)
        ld de,(CBDST)
.paint:
        ld b,8
        call CBEXPAND.row
        ld (CBSRC),hl
        ld (CBDST),de
        ld a,(CBPART)
        inc a
        and 3
        ld (CBPART),a
        ret nz
        ld hl,(CBFRONT)
        ld de,(CBBACK)
        ld (CBFRONT),de
        ld (CBBACK),hl
        ret
CBFRONT: dw CBUF
CBBACK: dw DOTS
CBPART: db 0
CBSRC: dw 0
CBDST: dw 0

; Old bounds [y, byte-x, height, byte-width]; all are safe to clear on entry.
CBOLD: db 56,12,64,8, 24,2,32,4, 24,25,32,4, 120,2,32,4, 120,25,32,4
CBPHASE: db 0,24,2, 64,24,25, 128,120,2, 192,120,25
CBLEFT: db 0
CBY: db 0

CBBLIT:                         ; DE = 32 rows x 4 bytes, B = top y, C = x
        ld ixl,32
.l:
        ld a,b
        and 7
        ld h,a
        ld a,b
        rra
        rra
        rra
        and 24
        or h
        or 64
        ld h,a
        ld a,b
        rla
        rla
        and $E0
        or c
        ld l,a
        ld a,(de)
        ld (hl),a
        inc de
        inc l
        ld a,(de)
        ld (hl),a
        inc de
        inc l
        ld a,(de)
        ld (hl),a
        inc de
        inc l
        ld a,(de)
        ld (hl),a
        inc de
        inc b
        dec ixl
        jp nz,.l
        ret

MONE:                           ; A = frame, B = top y, C = x byte
        ld l,a                  ; DE = MCDAT + frame*32
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,MCDAT
        add hl,de
        ex de,hl
MCBLIT:                         ; DE = 32 bytes, B = top y, C = x byte
        ld ixl,16
.l:
        ld a,b
        and 7
        ld h,a
        ld a,b
        rra
        rra
        rra
        and 24
        or h
        or 64
        ld h,a
        ld a,b
        rla
        rla
        and $E0
        or c
        ld l,a
        ld a,(de)
        ld (hl),a
        inc de
        inc l
        ld a,(de)
        ld (hl),a
        inc de
        inc b
        dec ixl
        jp nz,.l
        ret

SATERASE:
        ld bc,(SATPOS)
        push bc
        ld d,32
        ld e,4
        call CBCLEAR
        pop bc
        xor a
        jp SATATTR
SATDRAW:
        ld a,(FRAMES)
        ld l,a
        ld h,HIGH SINTAB
        ld a,(hl)
        add a,24
        ld b,a
        ld a,l
        add a,64
        ld l,a
        ld a,(hl)
        srl a
        add a,8
        ld c,a
        ld (SATPOS),bc
        push bc
        ld a,(FRAMES)
        rrca
        rrca
        and 31
        ld l,a
        ld h,0
        DUP 7
        add hl,hl
        EDUP
        ld de,CBDAT
        add hl,de
        ex de,hl
        call CBBLIT
        pop bc
        ld a,$45
        jp SATATTR
SATATTR:
        push af
        ld a,b
        and $F8
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld e,c
        ld d,0
        add hl,de
        ld de,ATTRS
        add hl,de
        pop af
        ld b,5
.row:
        DUP 4
        ld (hl),a
        inc hl
        EDUP
        ld de,28
        add hl,de
        djnz .row
        ret
SATPOS: db 8,24                  ; byte x, pixel y

STAREXERASE:
        ld a,ixl
        sub LOW STARDAT
        cp 16                   ; four nearest stars have the larger core
        ret nc
        call STAREXADDR
        cpl
        and (hl)
        ld (hl),a
        ret
STAREXDRAW:
        ld a,ixl
        sub LOW STARDAT
        cp 16
        ret nc
        call STAREXADDR
        or (hl)
        ld (hl),a
        ret
STAREXADDR:
        ld a,(ix+2)
        inc a
        ld l,a
        ld h,HIGH ROWLO
        ld a,(hl)
        inc h
        ld h,(hl)
        ld l,a
        ld a,(ix+1)
        rrca
        rrca
        rrca
        and 31
        or l
        ld l,a
        ld a,(ix+1)
        and 7
        ld e,a
        ld d,HIGH BITMSK
        ld a,(de)
        ld c,a
        srl a
        or c                    ; 2-pixel core beneath the 6-pixel trail
        ret

ROTCOPY:                        ; complete prepared plane, before scanout
        ld hl,BSBUF
        ld de,ATTRS
        ld bc,672
        ld a,21
.row:
        DUP 32
        ldi
        EDUP
        dec a
        jp nz,.row
        ret

        INCLUDE "src/basic.asm"
        ASSERT $ <= BITMSK

        ORG BITMSK
        INCBIN "build/bitmask.bin"

        ORG IM2TAB
        DS 257, HIGH IM2VEC
        ORG IM2VEC
        IFDEF TARGET128
        jp AYIRQ
        ELSE
        DB $ED,$4D              ; reti
        ENDIF

        ORG $FD00
FONT2:  INCBIN "build/font2.bin"
        ASSERT $ <= $10000

        IFDEF TARGET128
        SLOT 3
        PAGE MUSBANK
        ORG $C000
AYMUS:  INCBIN "build/aymus.bin"
        ASSERT $ <= $FFFF
        SLOT 3
        PAGE 0
        SAVESNA "build/aura-tunnel-128.sna",START
        SAVETAP "build/aura-tunnel-128.tap",START
        ELSE
        SAVESNA "build/aura-tunnel.sna",START
        SAVETAP "build/aura-tunnel.tap",START
        ENDIF
