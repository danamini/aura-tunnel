SJ := bin/sjasmplus
ZESARUX := /Applications/ZEsarUX.app/Contents/MacOS/zesarux

all: build/aura-tunnel.sna

build/tables.stamp: tools/gen_tables.py
	python3 tools/gen_tables.py build
	@touch $@

build/aura-tunnel.sna: src/main.asm build/tables.stamp
	$(SJ) --inc=. --lst=build/aura-tunnel.lst src/main.asm

# Launch ZEsarUX with the demo and the remote protocol the tools use.
emu: all
	"$(ZESARUX)" --noconfigfile --machine 48k --enable-remoteprotocol \
	  --remoteprotocol-port 10777 "$(PWD)/build/aura-tunnel.sna" &

# Static artifact checks always run; live frame-rate checks need `make emu`.
test: all
	python3 tools/smoke_test.py

# Grab a tear-free PNG of whatever the emulator is showing.
shot:
	python3 tools/zrcp_scr.py shot.png

clean:
	rm -f build/*

.PHONY: all emu test shot clean
