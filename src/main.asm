; ----------------------------------------------------------------------------
; AURA TUNNEL - a 48K ZX Spectrum demo
;
; Fourteen playlist slots, eleven scenes, one philosophy: every expensive
; computation is paid for at build time (tools/gen_tables.py bakes maps,
; palettes, projections, sprites and note tables); the Z80 only ever
; copies, pops and looks things up.  All scenes hold 50 fps (the runner
; concedes ~4% on bass notes), single-buffered, racing the beam.
;
; The running order:
;   BRIEFING      double-height ROM-font mission text, type-on
;   TUBE          chunky attribute tunnel (SP pops baked maps, 43T/cell)
;   STAR SNAKE    sine-wave text scroller under a drifting starfield
;   BOX           the tunnel again, square geometry
;   BIG TYPE      64x64 gradient letters bouncing on a sine
;   STAR          the tunnel, star-shaped
;   SUNSET RUN    articulated stick man, parallax floor and companion
;   VECTOR CUBE   Bresenham wireframe + four baked companion cubes
;   DEEP SPACE    48 coloured stars, three parallax layers
;   3D GRAPHS     the classic BASIC surface plot, then machine code
;   THE DOJO      two Yie Ar Kung-Fu fighters, scripted bout
;
; House tricks, used throughout:
;   * Chunky 32x42 half-block mode: PAPER colours the top of a cell, INK
;     the bottom - a full tunnel frame is 672 attribute writes.
;   * SP as a data pointer: renderers POP baked bytes two at a time with
;     interrupts off; returns from SP-walking code are self-modified JPs,
;     never CALLs.
;   * Per-frame 256-byte LUTs rebuilt from baked shade/pattern tables;
;     motion and rotation are 8.8 fixed-point accumulators.
;   * Self-modifying code for per-scene renderer dispatch, per-line plot
;     direction, colour masks and loop bounds.
;   * Beeper music from each frame's slack: one baked note burst per
;     frame, halved in the three tightest scenes (MHALF).
;   * Everything hot runs above 0x8000 (uncontended); cold one-shot code
;     and baked data live at 0x5E00 and after the maps.
;
; Keys:  M toggles the music, Q resets to BASIC.
;
; Build:  make            (sjasmplus + python3; see README.md)
; Test:   make test       (needs ZEsarUX for the emulator smoke test)
; ----------------------------------------------------------------------------
        DEVICE ZXSPECTRUM48

SCREEN   EQU $4000
ATTRS    EQU $5800
SCROLATT EQU $5AA0              ; attribute rows 21-23 (the scroller window)
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
STACK    EQU $FA00
IM2TAB   EQU $FB00              ; 257 bytes of $FC
IM2VEC   EQU $FCFC              ; RETI
ETAB     EQU $FD00              ; texture-coordinate step table
LUT      EQU $FF00              ; the per-frame lookup table:
                                ;   LUT[0aaadddd] = paper bits / top pattern
                                ;   LUT[1aaadddd] = ink bits   / bottom pattern

        ORG $8000

START:
        di
        ld sp,STACK
        xor a
        out ($FE),a             ; black border
        ld a,HIGH IM2TAB
        ld i,a
        im 2
        call INITSCREEN
        call TITLESET
        call BRIEFSET

MAIN:
        ei
        halt                    ; sync to 50Hz frame interrupt
        di
        call UPDATE
.bld:   call BUILDLUT           ; self-modified: BUILDLUT / BUILDPAT
.rnd:   call RENDER             ; self-modified: per-scene renderer
        call ROWCOLOURS
        call SCROLLER
        call TITLE
        call MUSIC              ; honours the M-key toggle
        call KEYS               ; M toggles music, Q quits to BASIC
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
        ld a,(BUILDLUT.pal+1)
        xor $70                 ; HIGH SHADEP0 <-> HIGH SHADEP1
        ld (BUILDLUT.pal+1),a
        ld a,(SCENE)
        cp 3
        jr nc,.nott             ; any tunnel scene: clean bottom rows and
        call CLRBOTTOM          ; re-lay the chunky half-blocks (they now
        call CHUNKALL           ; arrive from all kinds of dark stages)
.nott:
        ld a,(SCENE)
        cp 3
        call z,CUBESET          ; entering the cube: dark, ringed stage
        ld a,(SCENE)
        cp 4
        call z,STARSET          ; snake stage: dark, star-ready bitmap
        ld a,(SCENE)
        cp 5
        call z,CHUNKALL         ; giant letters need chunky halves back
        ld a,(SCENE)
        cp 5
        call z,BLANKATTRS
        ld a,(SCENE)
        cp 5
        call z,CLRBOTTOM
        ld a,(SCENE)
        cp 6
        call z,CHUNKALL         ; stick man: his cells need the chunky
        ld a,(SCENE)            ; halves whatever played before him
        cp 6
        call z,BLANKATTRS       ; sunset stage,
        ld a,(SCENE)
        cp 6
        call z,GROUNDSET        ;   with the parallax floor beneath
        ld a,(SCENE)
        cp 7
        call z,STARSET          ; deep space
        ld a,(SCENE)
        cp 8
        call z,STARSET          ; the dojo: dark stage,
        ld a,(SCENE)
        cp 8
        call z,YATTRS           ;   fighters' colours and the mat
        ld a,(SCENE)
        cp 9
        call z,STARSET          ; the briefing: darkness,
        ld a,(SCENE)
        cp 9
        call z,BRIEFSET         ;   then the type-on begins
        call TITLESET           ; and every fresh scene announces itself
.steady:

        ld a,(FRAMES)           ; bob: next of the scene's 4 maps every 8 frames
        rrca
        rrca
        rrca
        and 3
        add a,a
        ld e,a
        ld a,(SCENE)
        cp 3                    ; scenes 3+ (hi-res, giant) ride the circle maps
        jr c,.geo
        xor a
.geo:
        add a,a
        add a,a
        add a,a
        add a,e
        ld e,a
        ld d,0
        ld hl,MAPTABS
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,(TITLEF)           ; while a title card is up, the tunnel
        cp 164                  ; surrenders its top row - otherwise its
        jr nc,.nt               ; attr repaint beats the beam to row 0
        ld hl,64                ; and the card shows in tunnel colours
        add hl,de
        ex de,hl
        ld hl,ATTRS+32
        ld (RENDER.dst+1),hl
        ld a,20
        ld (RENDER.rows+1),a
        jr .tt
.nt:
        ld hl,ATTRS
        ld (RENDER.dst+1),hl
        ld a,21
        ld (RENDER.rows+1),a
.tt:
        ld (RENDER.spload+1),de

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
        jr z,.stars             ; scene 7: deep space
        cp 8
        jr z,.yiear             ; scene 8: the dojo
        cp 9
        jr z,.brief             ; scene 9: the mission briefing
        cp 10
        jr z,.graph             ; scene 10: hidden-line surface plots
        ld hl,BUILDLUT          ; scenes 0-2: plain chunky tunnel
        ld (MAIN.bld+1),hl
        ld hl,RENDER
        ld (MAIN.rnd+1),hl
        jr .vec
.solo:
        ld hl,NOOP              ; no tunnel, no LUT - but a few stars
        ld (MAIN.bld+1),hl      ; drift above the snake
        ld hl,STARSFEW
        ld (MAIN.rnd+1),hl
        jr .vec
.hires:
        ld hl,NOOP              ; scene 3: the vector cube, all pixels
        ld (MAIN.bld+1),hl
        ld hl,CUBE
        ld (MAIN.rnd+1),hl
        jr .vec
.big:
        ld hl,NOOP              ; no tunnel, no LUT: letters on black
        ld (MAIN.bld+1),hl
        ld hl,RENDER4S
        ld (MAIN.rnd+1),hl
        jr .vec
.stick:
        ld hl,NOOP
        ld (MAIN.bld+1),hl
        ld hl,STICKMAN
        ld (MAIN.rnd+1),hl
        jr .vec
.stars:
        ld hl,NOOP
        ld (MAIN.bld+1),hl
        ld hl,STARS
        ld (MAIN.rnd+1),hl
        jr .vec
.yiear:
        ld hl,NOOP
        ld (MAIN.bld+1),hl
        ld hl,YIEAR
        ld (MAIN.rnd+1),hl
        jr .vec
.brief:
        ld hl,NOOP
        ld (MAIN.bld+1),hl
        ld hl,BRIEF
        ld (MAIN.rnd+1),hl
        jr .vec
.graph:
        ld hl,NOOP
        ld (MAIN.bld+1),hl
        ld hl,GRAPH
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
        ret

; --------------------------------------------------------------- BUILDLUT
; Rebuild the 256-byte LUT for this frame's (rotation, motion, palette).
; For each of 8 wedges x 16 depths: fetch the shaded colour from the
; 2KB tables at (a+rot, d, (d+move)&15) and store paper/ink bytes.
; The texture coordinate walk uses ETAB - no arithmetic, no branches.
BUILDLUT:
        ld hl,LUT               ; L walks 0..127
        ld b,HIGH ETAB
        ld ixl,0                ; wedge counter
.wedge:
        ld a,(ROT)
        add a,ixl
        and 7
.pal:   add a,HIGH SHADEP0      ; self-modified: current palette page
        ld d,a                  ; D = shade page for this wedge
        ld a,(MOVE)
        ld e,a                  ; E = d<<4 | d2, starting at depth 0
        DUP 16
        ld a,(de)               ; paper bits
        ld (hl),a
        set 7,l
        set 3,d                 ; PAPER page -> INK page
        ld a,(de)               ; ink bits
        ld (hl),a
        res 3,d
        res 7,l
        inc l
        ld c,e                  ; E = ETAB[E]: next (d, d2) pair
        ld a,(bc)
        ld e,a
        EDUP
        inc ixl
        ld a,ixl
        cp 8
        jp nz,.wedge
        ret

; ---------------------------------------------------------------- RENDCORE
; The chunky row loop: B' rows of 32 cells.  SP pops [Ptop,Pbot] pairs from
; the map, H is pinned to the LUT page, attrs are written ascending so the
; writes race just ahead of the raster.  43 T-states per cell.
; SP is the map walker, so this can NEVER be CALLed - callers set .out+1
; to their continuation and jp here.
RENDCORE:
.row:
        DUP 31
        pop bc                  ; C = Ptop, B = Pbot
        ld l,c
        ld a,(hl)               ; paper bits
        ld l,b
        or (hl)                 ; | ink bits
        ld (de),a
        inc e                   ; rows are 32-aligned: E never wraps mid-row
        EDUP
        pop bc                  ; 32nd cell: inc de handles page crossings
        ld l,c
        ld a,(hl)
        ld l,b
        or (hl)
        ld (de),a
        inc de
        exx
        dec b
        exx
        jp nz,.row
.out:   jp 0                    ; self-modified continuation

; ----------------------------------------------------------------- RENDER
; Scenes 0-2: the whole 21-row chunky tunnel.
RENDER:
        ld (.rest+1),sp
        ld hl,.back
        ld (RENDCORE.out+1),hl
.spload:
        ld sp,MAPS              ; self-modified: current scene/bob map
.dst:   ld de,ATTRS             ; self-modified: +1 row while a title shows
        ld h,HIGH LUT
        exx
.rows:  ld b,21                 ; self-modified likewise
        exx
        jp RENDCORE
.back:
.rest:
        ld sp,0                 ; self-modified: restore real stack
        ret

; ---------------------------------------------------------------- RENDER4S
; The giant-scroller scene, solo: no tunnel - the letters stand on a black
; stage.  With attrs pre-blanked, the cell attr IS the orm mask (base 0
; ANDed with anything is 0), so rows 16-19 are a straight copy of BBUF's
; odd bytes.  Full 50 fps, a fraction of the old cost.
RENDER4S:
        call BIGBBUF            ; build this frame's text masks
        ld a,(FRAMES)           ; bounce: band top row rides the sine
        add a,a
        ld h,HIGH SINTAB
        ld l,a
        ld c,(hl)               ; C = top row of the 8-row band
        ld a,c
        cp 14                   ; the taller band bounces 0..13
        jr c,.fit
        ld c,13
.fit:
        ld a,(TITLEF)
        cp 164
        jr nc,.free
        ld a,c                  ; title up: keep the band off row 0
        or a
        jr nz,.free
        inc c
.free:
        ld de,ATTRS
        ld hl,BBUF+1            ; orm bytes
        ld a,c
        or a
        jr z,.band
        ld b,a                  ; zero the rows above the letters
.z1:
        push bc
        call ZROW32
        pop bc
        djnz .z1
.band:
        ld b,8                  ; the letters: BBUF holds finished attrs
.b1:
        push bc
        REPT 32
        ld a,(hl)
        ld (de),a
        inc l                   ; BBUF is one page: L walks it alone
        inc de
        EDUP
        pop bc
        dec b
        jp nz,.b1
        ld a,13                 ; backdrop rows below (down to row 20)
        sub c
        ret z                   ; band at the bottom: nothing below it
        ld b,a
.z2:
        push bc
        call ZROW32
        pop bc
        djnz .z2
        ret

ZROW32:                         ; one backdrop-coloured attr row at DE
        ld a,$09
        REPT 32
        ld (de),a
        inc de
        EDUP
        ret

; ---------------------------------------------------------------- BIGBBUF
; Build the giant scroller's 8x32 attr bytes from BIGPOS: one FULL attr
; cell per font pixel now (64x64 letters), so BBUF holds finished attr
; values - the row's gradient colour where the bit is set, backdrop blue
; where it isn't.
BIGBBUF:
        ld hl,ROMFONT
        ld (.fj+1),hl           ; font row pointer base, +1 per giant row
        ld de,BBUF
        ld ixl,8                ; giant row counter
.grow:
        ld a,(FRAMES)           ; row colour: rolling vertical gradient
        rrca
        rrca
        rrca
        add a,ixl
        and 7
        add a,LOW CTAB
        ld l,a
        ld a,HIGH CTAB
        adc a,0
        ld h,a
        ld a,(hl)
        or $40                  ; solid bright cell for letter pixels
        ld (.cm+1),a
        ld hl,(BIGPOS)
        ld a,l
        and 7
        ld c,a                  ; C = bit within char column
        srl h                   ; char index = (BIGPOS>>3) & 63
        rr l
        srl l
        srl l
        ld a,l
        and 63
        ld ixh,a                ; IXH = char index walker
        push de
        ld a,LOW MASKS
        add a,c
        ld l,a
        ld a,HIGH MASKS
        adc a,0
        ld h,a
        ld b,(hl)               ; B = pixel mask, rotates right per column
        call .font              ; HL = font base + row for the current char
        pop de
        ld c,32                 ; column counter
.col:
        ld a,(hl)               ; this giant row's font byte
        and b
        jr z,.bg
.cm:    ld a,0                  ; self-modified: gradient colour, bright
        jr .put
.bg:
        ld a,$09                ; deep-blue backdrop
.put:
        ld (de),a
        inc e                   ; BBUF is one page: E walks it alone
        rrc b                   ; next pixel column
        jr nc,.nc
        ld a,ixh                ; mask wrapped: next character
        inc a
        and 63
        ld ixh,a
        push de
        call .font
        pop de
.nc:
        dec c
        jp nz,.col
        ld hl,(.fj+1)           ; next giant row: font row + 1
        inc hl
        ld (.fj+1),hl
        dec ixl
        jp nz,.grow
        ret
.font:
        ld a,ixh                ; HL = ROMFONT + char*8 + row
        ld h,HIGH BIGTEXT
        ld l,a
        ld l,(hl)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
.fj:    ld de,ROMFONT           ; self-modified: + giant row
        add hl,de
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
        ld de,SCROLATT
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
        ld a,(FRAMES)
        ld h,HIGH SINTAB
        ld l,a
        ld a,(hl)               ; 0..16
        rrca
        rrca
        and 7                   ; 0..4
        cp 4
        jr c,.sok
        ld a,3
.sok:
        add a,2                 ; 2..5 px/frame: the 50 fps ceiling
        ld b,a
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
        ld a,$A0                ; DE = window top of this column
        or b
        ld e,a
        ld d,$50
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

NOOP:   ret                     ; the scroller scenes' "LUT builder"

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
        jp MINIWALK             ; and the distant companion behind him

GPATFAST:
        INCBIN "build/gpat.bin"
GPATSLOW EQU GPATFAST+128

CLRBOTTOM:                      ; rows 21-23 attrs black: tunnels run clean
        ld hl,SCROLATT
        ld de,SCROLATT+1
        ld bc,95
        ld (hl),0
        ldir
        ret

; ------------------------------------------------------------------ MUSIC
; 1-bit beeper, paid for entirely out of the frame's slack: one ~10.5k
; T-state burst of the current pattern note, then back to the halt.  The
; note table is baked (half-period wait count + burst length), so this is
; pure loops - no runtime pitch math.  OUT bit 4 is the speaker; the low
; bits stay 0 so the border stays black.
MUSIC:
        ld a,(MUSON)
        or a
        ret z                   ; silenced with the M key
        ld hl,(FRAMES)          ; pattern step, 0.16s each - taken from
        ld a,l                  ; the FULL frame counter, so all 8 bars
        rrca                    ; get their turn (the low byte alone
        rrca                    ; wraps after just two)
        rrca
        and 31
        ld e,a
        ld a,h
        rrca
        rrca
        rrca
        and $60
        or e                    ; 7-bit step 0..127
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,MUSTAB
        add hl,de
        ld e,(hl)               ; half-period wait count (26T/iteration)
        inc l
        ld d,(hl)
        inc l
        ld b,(hl)               ; half-periods in this burst
        ld a,d
        or e
        ret z                   ; rest step: silence
        ld a,(MHALF)
        or a
        jr z,.full
        srl b                   ; tight scene: half-length notes
        jr nz,.full
        inc b                   ; but never less than one half-period
.full:
        ld c,$10
.hp:
        ld a,c
        xor $10                 ; toggle the speaker bit
        ld c,a
        out ($FE),a
        push de
.w:
        dec de
        ld a,d
        or e
        jr nz,.w
        pop de
        djnz .hp
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
        ld a,16
        jr STARGO
STARSFEW:                       ; snake scene: one bright layer only -
        ld a,$00                ; the frame budget goes to the wave
        ld (STARGRP.dxl+1),a
        ld a,3
        ld (STARGRP.dxh+1),a
        ld ix,STARDAT
        ld b,8
        jp STARGRP
STARGO:
        ld iyl,a
        ld a,$00                ; near layer: 3.0 px/frame
        ld (STARGRP.dxl+1),a
        ld a,3
        ld (STARGRP.dxh+1),a
        ld ix,STARDAT
        ld b,iyl
        call STARGRP
        ld a,$80                ; mid layer: 1.5 px/frame
        ld (STARGRP.dxl+1),a
        ld a,1
        ld (STARGRP.dxh+1),a
        ld ix,STARDAT+64
        ld b,iyl
        call STARGRP
        ld a,$A0                ; far layer: 0.625 px/frame
        ld (STARGRP.dxl+1),a
        xor a
        ld (STARGRP.dxh+1),a
        ld ix,STARDAT+128
        ld b,iyl
        ; fall through
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
        ld b,104
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
        ld b,104
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

YATTRS:                         ; the dojo stage: just the mat (fighter
        ld hl,$5040             ;   rects repaint every frame as they move)
        ld b,32
.mat:
        ld (hl),$FF
        inc l
        djnz .mat
        ld hl,ATTRS+18*32       ; coloured dim red
        ld b,32
.mata:
        ld (hl),$02
        inc hl
        djnz .mata
        ret

        MACRO PDOWN             ; HL = screen byte one scanline down
        inc h
        ld a,h
        and 7
        jr nz,.pd
        ld a,l
        add a,32
        ld l,a
        jr c,.pd
        ld a,h
        sub 8
        ld h,a
.pd:
        ENDM

; ------------------------------------------------------------------- LINE
; Bresenham between (X0,Y0)-(X1,Y1), always drawn downward.  The pixel
; op at .pl/.pl2 is a 4-byte template patched by the cube (OR to draw,
; AND-NOT to erase); the x-step direction is patched per line.
LINE:
        ld a,(X0)
        ld d,a
        ld a,(X1)
        ld e,a
        ld a,(Y0)
        ld b,a
        ld a,(Y1)
        ld c,a
        cp b
        jr nc,.ord
        ld a,b                  ; draw downward: swap endpoints
        ld b,c
        ld c,a
        ld a,d
        ld d,e
        ld e,a
.ord:
        ld a,c
        sub b
        ld (DYV),a
        ld a,e
        sub d
        jr nc,.right
        neg
        ld (DXV),a
        ld a,$02                ; leftward: rlc d / dec l
        ld (.xstep+1),a
        ld (.xstep2+1),a
        ld a,$2D
        ld (.xadj),a
        ld (.xadj2),a
        jr .setup
.right:
        ld (DXV),a
        ld a,$0A                ; rightward: rrc d / inc l
        ld (.xstep+1),a
        ld (.xstep2+1),a
        ld a,$2C
        ld (.xadj),a
        ld (.xadj2),a
.setup:
        ld e,d                  ; PIXADDR wants D=y, E=x
        ld d,b
        call PIXADDR
        ld d,a                  ; D = pixel mask from here on
        ld a,(DYV)
        ld b,a
        ld a,(DXV)
        cp b
        jr c,.ymaj
        inc a                   ; x-major: count = dx+1
        ld b,a
        dec a
        ld c,a                  ; err = dx
        add a,a
        ld (.xa+1),a            ; err += 2*dx on minor step
        ld a,(DYV)
        add a,a
        ld e,a                  ; err -= 2*dy each step
.xl:
        ld a,(hl)
        or d
        ld (hl),a
.xstep: rrc d
        jr nc,.nx1
.xadj:  inc l
.nx1:
        ld a,c
        sub e
        ld c,a
        jr nc,.nx2
.xa:    add a,0
        ld c,a
        PDOWN
.nx2:
        djnz .xl
        ret
.ymaj:
        ld a,b                  ; y-major: count = dy+1
        ld c,b                  ; err = dy
        inc a
        ld b,a
        ld a,c
        add a,a
        ld (.ya+1),a
        ld a,(DXV)
        add a,a
        ld e,a
.yl:
        ld a,(hl)
        or d
        ld (hl),a
        PDOWN
        ld a,c
        sub e
        ld c,a
        jr nc,.ny
.ya:    add a,0
        ld c,a
.xstep2: rrc d
        jr nc,.ny
.xadj2: inc l
.ny:
        djnz .yl
        ret

X0:     db 0
Y0:     db 0
X1:     db 0
Y1:     db 0
DXV:    db 0
DYV:    db 0

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
        and 7
        ld c,a
        ld b,0
        push hl
        ld hl,MASKS
        add hl,bc
        ld a,(hl)
        pop hl
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

MAPTABS:                        ; 4 bob steps ping-pong over 2 maps: 0,1,0,1
        dw MAPS+0*MAPSIZE,  MAPS+1*MAPSIZE,  MAPS+0*MAPSIZE,  MAPS+1*MAPSIZE
        dw MAPS+2*MAPSIZE,  MAPS+3*MAPSIZE,  MAPS+2*MAPSIZE,  MAPS+3*MAPSIZE
        dw MAPS+4*MAPSIZE,  MAPS+5*MAPSIZE,  MAPS+4*MAPSIZE,  MAPS+5*MAPSIZE

MASKS:  db $80,$40,$20,$10,$08,$04,$02,$01
SEQ:    db 9,0,4,4,1,5,5,2,6,3,7,10,10,8 ; briefing, then a tunnel
SEQLEN  EQU 14                  ;   breathing between every feature:
SEQPOS: db 0                    ;   snake, type, runner, cube, space...
XOFF:   db 0                    ; stick man: this frame's x offset
SROW:   ds 4                    ; stick man: current sprite row scratch
CTAB:                           ; giant-text row colours, (c<<3)|c pairs:
        db $36,$36,$12,$12      ; yellow, yellow, red, red,
        db $1B,$1B,$2D,$2D      ; magenta, magenta, cyan, cyan
BITCNT: db 1                    ; solo scroller: glyph bits left to feed
GBUF:   ds 8                    ; solo scroller: current glyph

        ASSERT $ <= SHADEP1     ; code must stay below the warm palette

; -------- big tables and generated code, in the tail after the maps -------
        ORG MAPSEND
        INCLUDE "build/snake.asm"

; ------------------------------------------------------------------ GRAPH
; The surface-plot double act.  Act one: the classic BASIC listing on
; screen, plodding out one point every other frame below it, the way we
; all first met this graph.  Act two: wiped clean, the same baked points
; swept on at machine-code pace with height-mapped colour.
GRAPH:
        ld a,(FRAMES+1)
        and 1
        jr z,.fast
        ld a,(FRAMES)           ; ---- act one: BASIC ----
        or a
        jr nz,.slow
        call STARSET
        ld hl,LDATA             ; the listing goes up
.ll:
        ld a,(hl)
        cp $FF
        jr z,.linit
        call TXTSTR
        jr .ll
.linit:
        inc hl
        ld hl,G3D0
        ld (GPTR),hl
        xor a
        ld (GCNT),a
        ld (GFAST),a
        ld a,3
        ld (GXS),a
        ld hl,ATTRS+16*32       ; dim green plot strip under the listing
        ld de,ATTRS+16*32+1
        ld (hl),$04
        ld bc,5*32-1
        ldir
        ret
.slow:
        ld a,(FRAMES)
        and 1
        ret nz
        ld b,1                  ; one point, every other frame: 1982 speed
        jr GSTEP
.fast:
        ld a,(FRAMES)           ; ---- act two: machine code ----
        or a
        jr nz,.frun
        xor a                   ; slot start: first showcase surface
        ld (GIDX),a
        ld (GTIME),a
        jp GNEXT
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
        ld b,12
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

MCTXT:  db "MACHINE CODE"

HCOL:   db $47,$46,$44,$45,$43,$41,$41,$41  ; height bands, peak first
GFAST:  db 0
GIDX:   db 0
GTIME:  db 0
GXS:    db 3

LDATA:                          ; the listing, as we all typed it in
        db  1, 1,$07,13
        db "10 DIM M(255)"
        db  1, 2,$07,19
        db "15 LET A=COS (PI/4)"
        db  1, 3,$07,24
        db "20 FOR Y=0 TO 140 STEP 5"
        db  1, 4,$07,12
        db "30 LET E=A*Y"
        db  1, 5,$07,24
        db "40 FOR X=0 TO 140 STEP 3"
        db  1, 6,$07,25
        db "50 LET C=X-70: LET D=Y-70"
        db  1, 7,$07,26
        db "60 LET Z=78*EXP (-(C*C+D*D"
        db  1, 8,$07,10
        db ")/1400)   "
        db  1, 9,$07,25
        db "70 LET X1=X+E: LET Y1=Z+E"
        db  1,10,$07,31
        db "80 IF Y1>=M(X1) THEN PLOT X1,Y1"
        db  1,11,$07,15
        db "85 LET M(X1)=Y1"
        db  1,12,$07,17
        db "90 NEXT X: NEXT Y"
        db  3,14,$C6,24
        db "RUNNING... PLEASE WAIT.."
        db $FF

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

        ALIGN 256               ; BIGBBUF addresses it as page | charindex
BIGTEXT:                        ; exactly 64 chars, cyclic
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
MUSTAB:
        INCBIN "build/mustab.bin"
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

; --------------------------------------------------------------- MINIWALK
; The distant companion: half-size (8x20 chunky), drifting right-to-left
; behind the big fella - opposite relative motion, deeper parallax.  He
; leaves the stage entirely for part of each pass.
MINIWALK:
        ld a,(TITLEF)           ; he waits in the wings until the title
        cp 164                  ; card has gone - those are the scene's
        ret c                   ; most expensive frames
        ld a,(FRAMES)           ; then hurries past at a step per 2
        srl a                   ; frames, timed so the whole crossing
        add a,44                ; fits in what's left of the slot
        and 127
        cp 40
        ret nc                  ; resting off stage
        ld b,a
        ld a,31
        sub b                   ; logical x: 31 (entering right) .. -8
        jp m,.left
        cp 24
        jr c,.full
        ld (XSCR),a             ; entering: clipped by the right edge
        ld b,a
        ld a,32
        sub b
        ld (VISN),a
        xor a
        ld (CLIPN),a
        jr .draw
.full:
        ld (XSCR),a             ; fully on stage
        ld a,8
        ld (VISN),a
        xor a
        ld (CLIPN),a
        jr .draw
.left:
        neg                     ; leaving: clipped by the left edge -
        cp 8                    ; he stays until every column is gone
        ret nc
        ld (CLIPN),a
        ld b,a
        ld a,8
        sub b
        ld (VISN),a
        xor a
        ld (XSCR),a
.draw:
        ld a,(FRAMES)
        rrca
        rrca
        and 7                   ; pose, hurried to match the new pace
        ld l,a                  ; ptr = MINIDAT + pose*20
        ld h,0
        add hl,hl
        add hl,hl
        ld e,l
        ld d,h
        add hl,hl
        add hl,hl
        add hl,de
        ld de,MINIDAT
        add hl,de
        ex de,hl                ; DE = sprite bytes
        ld a,(XSCR)             ; dest = ATTRS + 11*32 + x
        add a,LOW (ATTRS+11*32)
        ld l,a
        ld a,HIGH (ATTRS+11*32)
        adc a,0
        ld h,a
        ld ixl,10               ; attr rows 11-20
.mrow:
        push hl
        ld a,(de)               ; top chunky row
        inc de
        ld b,a
        ld a,(de)               ; bottom chunky row
        inc de
        ld c,a
        ld a,(CLIPN)            ; discard the columns already off stage
        or a
        jr z,.ns
.sh:
        sla b
        sla c
        dec a
        jr nz,.sh
.ns:
        ld a,(VISN)
        ld ixh,a
.cells:
        MINICELL
        dec ixh
        jp nz,.cells
        pop hl
        ld bc,32
        add hl,bc
        dec ixl
        jp nz,.mrow
        ret

XSCR:   db 0                    ; mini walker: screen x, visible cells,
VISN:   db 0                    ;   and left-edge clip for this frame
CLIPN:  db 0

; --------------------------------------------------------------- STICKMAN
; A 128x160-pixel chunky stick man walking across a black stage: 8 baked
; poses, one screen crossing per scene slot, painted rows 0-19 top-down
; every frame (HL flows through the whole attr block, [x blanks][16
; sprite cells][16-x blanks] per row).  Same rolling gradient as the
; giant letters; the 16-bit sprite shift register renders branchless.
STICKMAN:
        ld a,(FRAMES)           ; pose 0-7, next every 4 frames
        rrca
        rrca
        and 7
        ld l,a                  ; HL' = STICKDAT + pose*80
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld e,l
        ld d,h
        add hl,hl
        add hl,hl
        add hl,de
        ld de,STICKDAT
        add hl,de
        push hl
        exx
        pop hl                  ; the alt set walks the sprite data
        exx
        ld a,(FRAMES)           ; x = 0..15: one crossing per slot
        rrca
        rrca
        rrca
        rrca
        and 15
        ld (XOFF),a
        ld hl,ATTRS+32          ; rows 1-20: his feet meet the floor
        ld ixl,20               ; row counter
.row:
        ld a,(FRAMES)           ; row colour: the rolling gradient
        rrca
        rrca
        rrca
        add a,ixl
        and 7
        add a,LOW CTAB
        ld e,a
        ld a,HIGH CTAB
        adc a,0
        ld d,a
        ld a,(de)
        ld e,a                  ; (c<<3)|c
        and $38
        ld ixh,a                ; IXH = paper mask
        ld a,e
        and $07
        ld iyh,a                ; IYH = ink mask
        ld a,LOW SKYREV         ; this row's stripe of the sunset
        add a,ixl
        ld e,a
        ld a,HIGH SKYREV
        adc a,0
        ld d,a
        ld a,(de)
        ld d,a                  ; wash the row in sky by stack-blast:
        ld e,a                  ; sixteen PUSHes beat thirty-two stores
        ld (.sps+1),sp
        ld bc,32
        add hl,bc
        ld sp,hl
        REPT 16
        push de
        EDUP
.sps:   ld sp,0                 ; self-modified restore
        push hl                 ; HL = next row base, stacked for later
        ld a,(XOFF)
        sub 32                  ; back to this row's base + x offset
        ld c,a
        ld b,$FF
        add hl,bc
        exx                     ; this row's 4 sprite bytes -> SROW
        ld de,SROW
        ldi
        ldi
        ldi
        ldi
        exx
        ld de,(SROW)            ; D = top cols 0-7, E = cols 8-15
        ld bc,(SROW+2)          ; B/C = the bottom chunky row
        REPT 16
        STCELL
        EDUP
        pop hl                  ; next row base
        dec ixl
        jp nz,.row
        jp GROUND               ; then the floor rushes past beneath him

        ASSERT $ <= BBUF        ; and below the giant-scroller mask page

        ORG $5E00               ; cold sprite data in the low free RAM
STARDAT:
        INCBIN "build/stars.bin"
STICKDAT:
        INCBIN "build/stickman.bin"
MINIDAT:
        INCBIN "build/ministick.bin"
; ------------------------------------------------------------------ TITLE
; Scene title cards: 12 chars top-left, sliding down from the screen edge
; (0.64s), holding two seconds, sliding back out.  Drawn after everything
; else so it floats over any scene; when it ends, the window is repaired
; to whatever bitmap the scene expects (chunky halves or darkness).
TITLE:
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
        ld bc,12
        ldir
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
TCHUNK: db 1,1,1,0,0,1,1,0,0,0,0 ; which scenes want chunky repair
TITLES:
        db "TUBE        "
        db "BOX         "
        db "STAR        "
        db "VECTOR CUBE "
        db "STAR SNAKE  "
        db "BIG TYPE    "
        db "SUNSET RUN  "
        db "DEEP SPACE  "
        db "THE DOJO    "
        db "BRIEFING    "
        db "3D GRAPHS   "
TSTRIP: ds 96
ZERO12: ds 12

; ------------------------------------------------------------------- CUBE
; The vector cube: erase last frame's 12 edges, draw this frame's, from
; 128 baked projections.  A full tumble every 2.56 seconds at 50 fps.
CUBE:
        ld a,(PREVK)
        inc a
        jr z,.fresh             ; new stage: nothing to wipe
        dec a
        call CUBEWIPE
.fresh:
        ld a,(FRAMES)
        and 127
        ld (PREVK),a
        call CUBEDRAW
        jp MINIS                ; then the companions in the corners

CUBEWIPE:                       ; A = frame idx: wipe cols 10-21 over just
        ld l,a                  ; that frame's vertical extent
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,CUBEDAT
        add hl,de
        ld b,8
        ld c,255                ; min sy
        ld e,0                  ; max sy
.scan:
        inc hl                  ; skip sx
        ld a,(hl)
        inc hl
        cp c
        jr nc,.a
        ld c,a
.a:
        cp e
        jr c,.b
        ld e,a
.b:
        djnz .scan
        ld b,c
.line:
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
        or 10
        ld l,a
        xor a
        REPT 12
        ld (hl),a
        inc l
        EDUP
        inc b
        ld a,e
        cp b
        jr nc,.line
        ret

CUBEDRAW:                       ; A = baked frame index
        ld l,a                  ; VB = CUBEDAT + A*16
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,CUBEDAT
        add hl,de
        ld (VB),hl
        ld iy,CEDGES
        ld a,12
        ld (EDGN),a
.el:
        ld e,(iy+0)
        ld d,0
        ld hl,(VB)
        add hl,de
        ld a,(hl)
        ld (X0),a
        inc hl
        ld a,(hl)
        ld (Y0),a
        ld e,(iy+1)
        ld hl,(VB)
        add hl,de
        ld a,(hl)
        ld (X1),a
        inc hl
        ld a,(hl)
        ld (Y1),a
        push iy
        call LINE
        pop iy
        inc iy
        inc iy
        ld a,(EDGN)
        dec a
        ld (EDGN),a
        jr nz,.el
        ret

MINIS:                          ; four corner cubes, two blitted per
        ld a,(FRAMES)           ; frame in alternating pairs
        and 1
        jr nz,.pair2
        ld a,(FRAMES)
        rrca
        rrca
        rrca
        and 31
        ld b,28                 ; top-left, forward
        ld c,3
        call MONE
        ld a,(FRAMES)
        rrca
        rrca
        rrca
        cpl                     ; bottom-right, reverse
        and 31
        ld b,140
        ld c,26
        jp MONE
.pair2:
        ld a,(TITLEF)
        cp 164
        ret c                   ; while the title card is up, two is plenty
        ld a,(FRAMES)
        rrca
        rrca
        rrca
        cpl
        add a,11                ; top-right: reverse, phase-shifted
        and 31
        ld b,28
        ld c,26
        call MONE
        ld a,(FRAMES)
        rrca
        rrca
        rrca
        add a,17                ; bottom-left: forward, phase-shifted
        and 31
        ld b,140
        ld c,3
        ; fall through
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

; ------------------------------------------------------------------ BRIEF
; The mission briefing: double-height ROM-font text (every glyph scanline
; written twice - 8x16 characters) typing on line by line in colour
; blocks, one character every other frame, ending on a flashing status.
BRIEF:
        ld a,(FRAMES)
        and 1
        ret nz                  ; one character every other frame
        ld a,(BLEFT)
        or a
        jr nz,.draw
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
        ret

BPTR:   dw BDATA
BLEFT:  db 0
BCX:    db 0
BROW:   db 0
BCOL:   db 0

BDATA:                          ; col, row, attr, len, text...
        db  2,3,$46,7
        db "MISSION"
        db  2,5,$46,7
        db "PROFILE"
        db 19,3,$43,6
        db "SYSTEM"
        db 19,5,$43,6
        db "ONLINE"
        db 11,9,$47,9
        db "LOCKED ON"
        db 13,11,$47,6
        db "TARGET"
        db 10,15,$C4,11
        db "ALL SYSTEMS"
        db 13,17,$C4,5
        db "GREEN"
        db  8,20,$05,15
        db "M=MUSIC  Q=QUIT"
        db $FF

CUBESET:                        ; scene entry: dark stage, rainbow rings
        call STARSET
        ld hl,CUBEATTR
        ld de,ATTRS
        ld bc,672
        ldir
        ld a,255
        ld (PREVK),a
        ret

CEDGES: db 0,2, 4,6, 8,10, 12,14
        db 0,4, 2,6, 8,12, 10,14
        db 0,8, 2,10, 4,12, 6,14
PREVK:  db 255
VB:     dw 0
EDGN:   db 0
CUBEDAT:
        INCBIN "build/cube.bin"
MCDAT:
        INCBIN "build/minicube.bin"
CUBEATTR:
        INCBIN "build/cubeattr.bin"

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
SKYREV:                         ; sunset stripes, indexed by the row
        db 0                    ;   counter (20 = top ... 1 = horizon)
        db $16,$16,$16          ; rows 18-20: red/yellow glow
        db $12,$12,$12          ; rows 15-17: red
        db $1A,$1A              ; rows 13-14: red/magenta
        db $1B,$1B              ; rows 11-12: magenta
        db $0B,$0B              ; rows  9-10: blue/magenta
        db $09,$09              ; rows  7-8:  blue
        db 0,0,0,0,0,0          ; rows  1-6:  night above
        ASSERT $ <= $8000

        ORG SHADEP1
        INCBIN "build/shadep1.bin"
        ORG SHADEI1
        INCBIN "build/shadei1.bin"
        ORG MAPS
        INCBIN "build/maps.bin"
        ORG SHADEP0
        INCBIN "build/shadep0.bin"
        ORG SHADEI0
        INCBIN "build/shadei0.bin"
        ORG IM2TAB
        DS 257, HIGH IM2VEC
        ORG IM2VEC
        DB $ED,$4D              ; reti
        ORG ETAB
        INCBIN "build/etab.bin"
        ORG LUT
        DS 256                  ; rebuilt every frame

        SAVESNA "build/aura-tunnel.sna",START
        SAVETAP "build/aura-tunnel.tap",START
