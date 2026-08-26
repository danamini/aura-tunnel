SJ := bin/sjasmplus
ZESARUX := /Applications/ZEsarUX.app/Contents/MacOS/zesarux

# Two editions from one source: the 48K original, and a 128K build that adds
# AY music and the lower-third console (-DTARGET128).  The 128K edition joins
# `all` automatically once src/main.asm carries its hooks - see
# docs/128k-integration.md.
HAVE128 := $(shell grep -l TARGET128 src/main.asm 2>/dev/null)

all: build/aura-tunnel.sna $(if $(HAVE128),build/aura-tunnel-128.sna)

build/tables.stamp: tools/gen_tables.py
	python3 tools/gen_tables.py build
	@touch $@

build/aymus.bin: tools/gen_ay128.py
	python3 tools/gen_ay128.py build

build/aura-tunnel.sna: src/main.asm build/tables.stamp
	$(SJ) --inc=. --lst=build/aura-tunnel.lst \
	  --sld=build/aura-tunnel.sld --fullpath src/main.asm

build/aura-tunnel-128.sna: src/main.asm src/ay128.asm build/tables.stamp build/aymus.bin
	$(SJ) --inc=. -DTARGET128 --lst=build/aura-tunnel-128.lst \
	  --sld=build/aura-tunnel-128.sld --fullpath src/main.asm

# Launch ZEsarUX with the demo and the remote protocol the tools use.
emu: build/aura-tunnel.sna
	"$(ZESARUX)" --noconfigfile --machine 48k --enable-remoteprotocol \
	  --remoteprotocol-port 10777 "$(PWD)/build/aura-tunnel.sna" &

# The 128K edition, on its own port so both can run side by side.
emu128: build/aura-tunnel-128.sna
	"$(ZESARUX)" --noconfigfile --machine 128k --enable-remoteprotocol \
	  --remoteprotocol-port 10778 "$(PWD)/build/aura-tunnel-128.sna" &

# Static artifact checks always run; live frame-rate checks need `make emu`.
test: build/aura-tunnel.sna
	python3 tools/smoke_test.py

# Grab a tear-free PNG of whatever the emulator is showing.
shot:
	python3 tools/zrcp_scr.py shot.png

# A clean-room build catches what an incremental one cannot: a generator you
# deleted while something still depended on its output, or a baked file that
# only still exists because nobody ever cleaned build/.  Both editions must
# come out of an empty tree.  Destructive, so it is never part of `make test` -
# it would pull build/ out from under a running emulator.
cleanbuild:
	rm -rf build
	$(MAKE) all
	@echo "clean-room build ok:"
	@ls -l build/aura-tunnel.sna build/aura-tunnel-128.sna

clean:
	rm -f build/*

.PHONY: all emu emu128 test shot cleanbuild clean
