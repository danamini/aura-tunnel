; ----------------------------------------------------------------------------
; AURA TUNNEL 128K - AY music and the lower-third console
;
; Included by src/main.asm inside IFDEF TARGET128.  Deliberately contains no
; ORG: the include site picks the address, so this file never argues with the
; 48K memory map.  It must land in the $8000-$BFFF window (page 2, uncontended
; on every 128K model) because it runs with page MUSBANK swapped into $C000.
;
; Depends on four symbols from main.asm: SCROLATT, MUSON, and WIPEF/TRMODE
; (the transition state - see AYCON, which must stand down during a slide).
;
; THE MUSIC.  tools/gen_ay128.py bakes the whole tune down to a per-frame AY
; register stream - pitch, harmony and all three volume envelopes are resolved
; in Python, so the player is a copy loop with no sequencer and no maths.
; Frame layout:
;
;     [volA][volB][volC][n]  then n x [reg, val]   (regs 0-7 only)
;
; volA = $FF is the loop point.  The three volumes sit at a fixed offset
; because they change nearly every frame anyway and because the console wants
; them - reading them off the stream is cheaper than interrogating the chip.
;
; THE CONSOLE.  Three VU bars in the scroller window, one per channel,
; spreading from the centre.  It lives in rows 21-23 for a timing reason: the
; interrupt fires at the top of the frame and the beam does not reach the
; lower third until roughly 43,500 T-states later, against 14,400 for the top
; row.  Down here a full attribute repaint cannot be caught mid-write, so the
; console never tears no matter how late in the frame it runs - which is why
; MAIN calls it last of all.
; ----------------------------------------------------------------------------

AYSEL    EQU $FF                ; register-select port, high byte ($FFFD)
AYDAT    EQU $BF                ; register-write port,  high byte ($BFFD)

; ----------------------------------------------------------------- AYFRAME
; One frame of music, then the console.  NOTHING in here may touch the stack
; between the two paging OUTs: the demo's stack lives at $FA00, inside the
; window being swapped out.  Interrupts are already off (MAIN runs di between
; halts), so the IM2 table going with it is harmless.
AYFRAME:
        ld a,(MUSON)
        or a
        jr z,AYHUSH             ; silenced with the M key
        ld bc,PORT7FFD
        ld a,PAGEBASE|MUSBANK
        out (c),a               ; music page in - no CALL or PUSH past here

        ld hl,(AYPTR)
        ld a,(hl)
        cp $FF
        jr nz,.go
        ld hl,AYMUS             ; end of the stream: back to the top, where
        ld a,(hl)               ; frame 0 rewrites every register
.go:
        inc hl
        ld (AYBAR+0),a          ; the levels feed the console on the way past
        ld a,(hl)
        inc hl
        ld (AYBAR+3),a
        ld a,(hl)
        inc hl
        ld (AYBAR+6),a
        ld a,(hl)
        inc hl
        ld (AYPAIRS),a          ; n: register pairs waiting behind the volumes

        ld c,$FD                ; volumes first - regs 8, 9, 10 every frame
        ld b,AYSEL
        ld a,8
        out (c),a
        ld b,AYDAT
        ld a,(AYBAR+0)
        out (c),a
        ld b,AYSEL
        ld a,9
        out (c),a
        ld b,AYDAT
        ld a,(AYBAR+3)
        out (c),a
        ld b,AYSEL
        ld a,10
        out (c),a
        ld b,AYDAT
        ld a,(AYBAR+6)
        out (c),a

        ld a,(AYPAIRS)          ; then whatever else changed this frame:
        or a                    ; tone periods, noise, the mixer
        jr z,.done
        ld e,a
.pair:
        ld b,AYSEL
        ld a,(hl)
        inc hl
        out (c),a
        ld b,AYDAT
        ld a,(hl)
        inc hl
        out (c),a
        dec e
        jr nz,.pair
.done:
        ld (AYPTR),hl           ; a page-1 address, valid again next frame
        ld bc,PORT7FFD
        ld a,PAGEBASE
        out (c),a               ; resident page back: stack is live again
        jr AYCON

; ------------------------------------------------------------------ AYHUSH
; M pressed: park the chip and collapse the bars.  The stream pointer is left
; where it is, so the tune resumes mid-phrase rather than restarting.
AYHUSH:
        xor a
        ld (AYBAR+0),a
        ld (AYBAR+3),a
        ld (AYBAR+6),a
        ld c,$FD
        ld d,8
.mute:
        ld b,AYSEL
        ld a,d
        out (c),a
        ld b,AYDAT
        xor a
        out (c),a
        inc d
        ld a,d
        cp 11
        jr nz,.mute
        ; fall through to the console, which now paints three empty rows

; ------------------------------------------------------------------- AYCON
; Three 32-cell bars, one attribute row per channel, spreading from the centre.
; Unlit cells keep white ink on black paper so the scroller reads straight
; across the gap; lit cells swap in the channel's paper colour.
;
; It repaints only the cells that actually changed.  Blanking all 96 and
; redrawing cost up to 4.8k T-states, which measured a clean 4 fps off the
; pixel-scroller scene - the tightest in the demo.  A level normally moves one
; or two steps per frame, so the edges alone are two to four cells: the same
; erase-from-what-you-know trick the dot renderer uses, and it takes the
; typical frame under 300T.
;
; The catch with incremental drawing is that scene transitions blank rows 21-23
; from under us (CLRBOTTOM, GROUNDSET) and would leave a stale half-bar behind.
; So each row keeps the level it last painted and checks one canary cell before
; trusting it; anything unexpected there forces a full repaint of that row, and
; the window heals within a single frame.
AYCON:
        ld a,(WIPEF)            ; A SLIDE IS DIFFERENT.  The dissolve writes
        cp 24                   ; cells in place, so repainting over it just
        jr nc,.paint            ; leaves the strip standing - which looks
        ld a,(TRMODE)           ; deliberate, and we keep it.  SLIDER shifts
        or a                    ; the whole screen up instead, so it drags
        ret nz                  ; our bars with it and we repaint fresh ones
                                ; underneath - the two together smear a
                                ; growing block of colour up the display.
                                ; Stand down and let the bars slide away with
                                ; everything else; the canary repaints them
                                ; when the new scene lands.
.paint:
        ld ix,AYBAR
        ld de,SCROLATT
.row:
        ld a,(ix+0)             ; the level the music wants...
        and 15
        ld c,a
        ld b,(ix+2)             ; ...against the one already on screen

        ld h,d                  ; the canary: the centre cell, which is lit
        ld a,e                  ; whenever the painted level is non-zero
        add a,16
        ld l,a
        ld a,b
        or a
        ld a,(ix+1)
        jr nz,.canary
        ld a,$07                ; a silent row should be all backdrop
.canary:
        cp (hl)
        jp nz,.full             ; someone repainted the window: start over

        ld a,c
        cp b
        jp z,.next              ; level unchanged: nothing to draw at all
        jr nc,.grow
        ld a,$07                ; shrinking: hand the cells back to backdrop
        jr .edges
.grow:
        ld a,(ix+1)             ; growing: light them in the bar colour
.edges:
        ld (.val+1),a           ; the two runs are symmetric about the centre,
        ld a,b                  ; so sort the pair and walk each side once
        cp c
        jr c,.sorted
        ld a,b
        ld b,c
        ld c,a                  ; now B = lower level, C = higher
.sorted:
        ld a,b
        ld (.lo+1),a
        ld a,c
        sub b
        ld (.cnt+1),a           ; cells to touch on each side

        ld a,16                 ; left run: 16-hi .. 16-lo
        sub c
        add a,e
        ld l,a
        ld h,d
.cnt:   ld b,0
.val:   ld a,0
.left:
        ld (hl),a
        inc l
        djnz .left

        ld a,16                 ; right run: 16+lo .. 16+hi
.lo:    add a,0
        add a,e
        ld l,a
        ld h,d
        ld a,(.cnt+1)
        ld b,a
        ld a,(.val+1)
.right:
        ld (hl),a
        inc l
        djnz .right
        jr .done

.full:                          ; the slow path: blank the row, redraw the bar
        ld h,d
        ld l,e
        ld a,$07
        REPT 32                 ; unrolled - a DJNZ here would cost more than
        ld (hl),a               ; the whole bar it is clearing for
        inc l
        EDUP
        ld a,c
        or a
        jr z,.done              ; silent channel: an empty row is correct
        ld b,a
        add a,a
        ld (.fcnt+1),a          ; 2*level cells wide
        ld a,16
        sub b
        add a,e                 ; centred on the row
        ld l,a
        ld h,d
.fcnt:  ld b,0
        ld a,(ix+1)
.fbar:
        ld (hl),a
        inc l
        djnz .fbar
.done:
        ld a,(ix+0)             ; remember what is on screen now.  Re-read it:
        and 15                  ; the edge path sorts B/C, so C is the higher
        ld (ix+2),a             ; of the two levels by now, not the new one
.next:
        ld a,e
        add a,32                ; next row - and zero once the third is done
        ld e,a
        inc ix
        inc ix
        inc ix
        jp nz,.row              ; JP, not JR: this routine outgrew JR's reach
        ret

; [level, bar attr, level last painted] per channel.  BRIGHT paper with white
; ink: strong enough to read as a level meter, dark enough to keep the
; scroller legible over it.
AYBAR:
        db 0,$4F,0              ; A  melody     bright blue
        db 0,$57,0              ; B  bass       bright red
        db 0,$5F,0              ; C  percussion bright magenta
AYPTR:   dw 0                   ; cursor into the stream, set by AYINIT
AYPAIRS: db 0

; ------------------------------------------------------------------ AYINIT
; Called once at boot, after the paging port is known good.  AYHUSH parks the
; chip and paints an empty console; MUSON takes over from the next frame.
AYINIT:
        ld hl,AYMUS
        ld (AYPTR),hl
        jp AYHUSH
