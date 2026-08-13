NVIM ?= nvim
STYLUA ?= stylua
LUACHECK ?= luacheck

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TESTS_DIR := $(ROOT)/.tests
LUA_FILES := lua plugin tests

# Keep the test run out of the real Neovim directories.
export XDG_CONFIG_HOME := $(TESTS_DIR)/xdg/config
export XDG_DATA_HOME := $(TESTS_DIR)/xdg/data
export XDG_STATE_HOME := $(TESTS_DIR)/xdg/state
export XDG_CACHE_HOME := $(TESTS_DIR)/xdg/cache

.PHONY: all test lint fmt fmt-check clean help

all: fmt-check lint test

## test: run the plenary test suite headless
test:
	@mkdir -p $(XDG_CONFIG_HOME) $(XDG_DATA_HOME) $(XDG_STATE_HOME) $(XDG_CACHE_HOME)
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests { init = 'tests/minimal_init.lua', sequential = true }"

## lint: run luacheck, when it is installed
lint:
	@if command -v $(LUACHECK) >/dev/null 2>&1; then \
		$(LUACHECK) $(LUA_FILES); \
	else \
		echo "luacheck not found, skipping"; \
	fi

## fmt: format the Lua files with stylua
fmt:
	$(STYLUA) $(LUA_FILES)

## fmt-check: fail when a Lua file needs formatting
fmt-check:
	$(STYLUA) --check $(LUA_FILES)

## clean: remove the test sandbox
clean:
	rm -rf $(TESTS_DIR)

## help: list the targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'
