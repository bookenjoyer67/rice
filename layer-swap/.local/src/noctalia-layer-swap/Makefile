CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -fPIC -fvisibility=default
TARGET  := $(HOME)/.local/lib/noctalia-layer-swap.so

$(TARGET): shim.c
	@mkdir -p $(dir $(TARGET))
	$(CC) $(CFLAGS) -shared -o $@ shim.c -ldl

clean:
	rm -f $(TARGET)

.PHONY: clean
