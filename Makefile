BINARY_NAME := tuxdisk
BIN_DIR := bin
TARGET_BIN := $(BIN_DIR)/$(BINARY_NAME)
MODULE_CACHE := /tmp/tuxdisk-module-cache
SOURCES := $(wildcard Sources/tuxdisk/*.swift)
PREFIX ?= /usr/local

.PHONY: all build sign test setup list doctor clean install

all: sign

build: $(SOURCES)
	@mkdir -p $(BIN_DIR) $(MODULE_CACHE)
	swiftc -module-cache-path $(MODULE_CACHE) -O -framework Virtualization $(SOURCES) -o $(TARGET_BIN)

sign: build
	codesign --entitlements entitlements.plist --force -s - $(TARGET_BIN)
	@ln -sf $(BINARY_NAME) $(BIN_DIR)/linux-disk-vm
	@echo "==> Built and signed $(TARGET_BIN)"

test: $(SOURCES) Tests/tuxdiskTests/tuxdiskTests.swift
	@mkdir -p $(BIN_DIR) $(MODULE_CACHE)
	swiftc -module-cache-path $(MODULE_CACHE) -DTUXDISK_TEST_RUNNER -framework Virtualization $(SOURCES) Tests/tuxdiskTests/tuxdiskTests.swift -o $(BIN_DIR)/tuxdisk-tests
	codesign --entitlements entitlements.plist --force -s - $(BIN_DIR)/tuxdisk-tests
	./$(BIN_DIR)/tuxdisk-tests

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
