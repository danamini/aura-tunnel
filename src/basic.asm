; A real ROM BASIC interlude. E000-E7FF is borrowed from the roto table;
; its three backups are dead scene workspaces. No live code is overwritten.
        INCLUDE "build/basic-registers.asm"
BASICENTER:
        IFNDEF TARGET128
        di
        ENDIF
        ld (BASICSAVEDSP),sp
        ld hl,$E000
        ld de,DOTS
        ld bc,1024
        ldir
        ld de,BSBUF
        ld bc,768
        ldir
        ld de,BSGLY
        ld bc,256
        ldir
        call STARSET
        ld hl,BASICLISTING
.list:
        ld a,(hl)
        cp $FF
        jr z,.listed
        call TXTSTR
        jr .list
.listed:
        ld hl,BASICCONTEXT
        ld de,$5C00
        ld bc,BASICCONTEXTEND-BASICCONTEXT
        ldir
        ld hl,BASICPROGRAM
        ld de,$E000
        ld bc,BASICPROGRAMEND-BASICPROGRAM
        ldir
        ld hl,BASICSTACK
        ld de,BASIC_SP
        ld bc,BASICSTACKEND-BASICSTACK
        ldir
        ld a,1
        ld (GBASICACTIVE),a
        ld hl,BASIC_PREVIEW_TICKS
        ld (BASICTICKS),hl
        xor a
        ld (BASICTIMEDOUT),a
        ld iy,BASIC_IY
        di
        ld a,$C3
        ld (IM2VEC),a
        ld hl,BASICIRQ
        ld (IM2VEC+1),hl
        ld a,HIGH IM2TAB
        ld i,a
        im 2
        ei
        exx
        ld bc,BASIC_BC2
        ld de,BASIC_DE2
        ld hl,BASIC_HL2
        exx
        ld hl,(BASIC_A2<<8)|BASIC_F2
        push hl
        pop af
        ex af,af'
        ld ix,BASIC_IX
        ld iy,BASIC_IY
        ld hl,(BASIC_A<<8)|BASIC_F
        push hl
        pop af
        ld bc,BASIC_BC
        ld de,BASIC_DE
        ld hl,BASIC_HL
        ld sp,BASIC_SP
        ei
        ret                     ; continue the ROM's USR expression and program
BASICSAVEDSP: dw 0
GBASICACTIVE: db 0
GREALDONE: db 0
BASICTICKS: dw 0
BASICTIMEDOUT: db 0

        ASSERT $ <= BASIC_EXIT
        ORG BASIC_EXIT               ; fixed USR destination in the tokenised program
BASICDONE:
        di
        ld sp,(BASICSAVEDSP)
        IFDEF TARGET128
        ld hl,AYIRQ
        ld (IM2VEC+1),hl
        ld a,HIGH IM2TAB
        ld i,a
        im 2
        ei
        ENDIF
        ld hl,DOTS
        ld de,$E000
        ld bc,1024
        ldir
        ld hl,BSBUF
        ld bc,768
        ldir
        ld hl,BSGLY
        ld bc,256
        ldir
        xor a
        ld (GBASICACTIVE),a
        ld (GIDX),a
        ld (GTIME),a
        inc a
        ld (GREALDONE),a
        ld a,HIGH IM2TAB
        ld i,a
        im 2
        IFDEF TARGET128
        ld hl,AYIRQ
        ld (IM2VEC+1),hl
        ELSE
        ld hl,$4DED
        ld (IM2VEC),hl
        ENDIF
        call GNEXT             ; display the real machine-code plot next
        IFDEF TARGET128
        ei
        ENDIF
        ret
BASICIRQ:
        push af
        push bc
        push de
        push hl
        IFDEF TARGET128
        call AYFRAME
        ENDIF
        ld hl,(BASICTICKS)
        dec hl
        ld (BASICTICKS),hl
        ld a,h
        or l
        jr z,.expired
        pop hl
        pop de
        pop bc
        pop af
        jp $0038                ; ROM keyboard and clock, with the AY score alive
.expired:
        ld a,1
        ld (BASICTIMEDOUT),a
        jp BASICDONE            ; abandon the interpreter stack, restore the demo
