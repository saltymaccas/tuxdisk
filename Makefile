BINARY_NAME := tuxdisk
BIN_DIR := bin
TARGET_BIN := $(BIN_DIR)/$(BINARY_NAME)
MODULE_CACHE := /tmp/tuxdisk-module-cache
SOURCES := $(wildcard Sources/tuxdisk/*.swift)
PREFIX ?= /usr/local

.PHONY: all build sign setup list doctor clean install

all: sign

build: $(SOURCES)
	@mkdir -p $(BIN_DIR) $(MODULE_CACHE)
	swiftc -module-cache-path $(MODULE_CACHE) -O -framework Virtualization $(SOURCES) -o $(TARGET_BIN)

sign: build
	codesign --entitlements entitlements.plist --force -s - $(TARGET_BIN)
	@ln -sf $(BINARY_NAME) $(BIN_DIR)/linux-disk-vm
	@echo "==> Built and signed $(TARGET_BIN)"

setup: sign
	./$(TARGET_BIN) setup

list: sign
	./$(TARGET_BIN) list

doctor: sign
	./$(TARGET_BIN) doctor

install: sign
	install -d $(PREFIX)/bin
	install -m 0755 $(TARGET_BIN) $(PREFIX)/bin/$(BINARY_NAME)
	codesign --entitlements entitlements.plist --force -s - $(PREFIX)/bin/$(BINARY_NAME)
	@echo "==> Installed to $(PREFIX)/bin/$(BINARY_NAME)"

clean:
	rm -rf $(BIN_DIR) $(MODULE_CACHE) .build
