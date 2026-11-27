INSTALL ?= install

# ---- pinned OpenResty: patches/openresty-<ver>/ is keyed on this ----------
OPENRESTY_VERSION := 1.31.1.1
OPENRESTY_SHA256  := 23e7eae92b63a2252ff1a8b7a457df4c796fb7a921196c3714837991a1aecda8
OPENRESTY_URL     := https://openresty.org/download/openresty-$(OPENRESTY_VERSION).tar.gz
# local cache locations probed before downloading (offline-friendly)
OPENRESTY_CACHE   ?= $(wildcard ../openresty/openresty-$(OPENRESTY_VERSION).tar.gz)

PATCH_DIR := patches/openresty-$(OPENRESTY_VERSION)
BUILD     := build
SRC       := $(BUILD)/openresty-$(OPENRESTY_VERSION)
# OpenResty's configure resolves --prefix relative to its cwd, so the
# --prefix we pass must be absolute even though make targets stay relative.
SRC_ABS   := $(CURDIR)/$(BUILD)/openresty-$(OPENRESTY_VERSION)
TARBALL   := $(BUILD)/dl/openresty-$(OPENRESTY_VERSION).tar.gz
NGINX     := $(SRC)/work/nginx/sbin/nginx

# Where lib/resty/*.lua is installed. OpenResty loads Lua from <prefix>/lualib
# (never the system Lua paths), so this is an OpenResty root, not a /usr/local.
# Defaults to the tree `make build` produces; override to install elsewhere.
OPENRESTY_PREFIX ?= $(CURDIR)/$(SRC)/work
LUA_LIB_DIR      ?= $(OPENRESTY_PREFIX)/lualib

# ---- test harness: repo-local perl deps + submodule, never the system @INC --
DEPS_PERL := $(CURDIR)/deps/perl5/lib/perl5
DEPS_TN   := $(CURDIR)/deps/test-nginx
PROVE     ?= $(shell command -v prove 2>/dev/null || echo /usr/bin/core_perl/prove)
JOBS      ?= $(shell nproc)

.PHONY: all build deps test lint fmt install clean distclean

all: build ;

# ----------------------------------------------------------------------------
# build: fetch -> verify -> unpack -> patch -> configure -> make -> install
# ----------------------------------------------------------------------------
build: $(NGINX)

$(BUILD)/dl $(BUILD):
	mkdir -p $@

$(TARBALL): | $(BUILD)/dl
	@if [ -n "$(OPENRESTY_CACHE)" ]; then \
		echo ">>> using cached tarball $(OPENRESTY_CACHE)"; \
		cp "$(OPENRESTY_CACHE)" $@; \
	else \
		echo ">>> downloading $(OPENRESTY_URL)"; \
		curl -fL -o $@ "$(OPENRESTY_URL)"; \
	fi
	@echo "$(OPENRESTY_SHA256)  $@" | sha256sum -c - >/dev/null \
		|| { echo "sha256 mismatch for $@" >&2; rm -f $@; exit 1; }

$(SRC)/.unpacked: $(TARBALL)
	rm -rf $(SRC)
	mkdir -p $(BUILD)
	tar -xzf $< -C $(BUILD)
	@touch $@

# apply in sorted order (_01, _02, ...) with -p1; fail loudly on any offset
# beyond what `patch` will tolerate without fuzz, so a drifted patch is noticed
# Depends on the patch files themselves, so editing one re-runs this rule.
# Always start from a fresh unpack: patching an already-patched tree fails
# with "Reversed (or previously applied) patch detected".
$(SRC)/.patched: $(TARBALL) $(wildcard $(PATCH_DIR)/*.patch)
	rm -rf $(SRC)
	mkdir -p $(BUILD)
	tar -xzf $(TARBALL) -C $(BUILD)
	@[ -d "$(PATCH_DIR)" ] || { \
		echo "no patches for openresty-$(OPENRESTY_VERSION)" >&2; exit 1; }
	@for p in $(sort $(wildcard $(PATCH_DIR)/*.patch)); do \
		echo ">>> applying $$p"; \
		( cd $(SRC) && patch -p1 --fuzz=0 < "$(CURDIR)/$$p" ) || exit 1; \
	done
	@touch $@
	@rm -f $(SRC)/.unpacked

# -j for the nginx build; LUAJIT/XBUILD flags mirror util/build.sh defaults.
# Logs use absolute paths because the recipe cd's into $(SRC) first.
LOGDIR := $(CURDIR)/$(BUILD)
$(NGINX): $(SRC)/.patched
	cd $(SRC) && ./configure --prefix=$(SRC_ABS)/work \
		--with-pcre-jit --with-ipv6 --with-threads \
		--with-http_ssl_module --with-http_v2_module --with-http_v3_module \
		--with-stream --with-stream_ssl_module \
		--with-cc-opt='-DNGX_LUA_USE_ASSERT -g' \
		--with-debug \
		--with-luajit-xcflags='-DLUA_USE_APICHECK -DLUA_USE_ASSERT' \
		> $(LOGDIR)/configure.log 2>&1 \
		|| { echo "configure failed, see $(LOGDIR)/configure.log" >&2; exit 1; }
	cd $(SRC) && make -j$(JOBS) > $(LOGDIR)/make.log 2>&1 \
		|| { echo "make failed, see $(LOGDIR)/make.log" >&2; exit 1; }
	cd $(SRC) && make install > $(LOGDIR)/install.log 2>&1 \
		|| { echo "install failed, see $(LOGDIR)/install.log" >&2; exit 1; }
	@echo ">>> built $(NGINX)"
	@$(NGINX) -V 2>&1 | head -1

# ----------------------------------------------------------------------------
# deps: repo-local perl for Test::Nginx (re-run after any system perl bump)
# ----------------------------------------------------------------------------
# The stamp lives OUTSIDE deps/perl5 so make can see it after a reinstall.
deps/.perl5.stamp: $(DEPS_TN)/Makefile.PL $(DEPS_TN)/lib/Test/Nginx/Socket.pm
	rm -rf deps/perl5
	env -u PERL5LIB -u PERL_LOCAL_LIB_ROOT -u PERL_MB_OPT -u PERL_MM_OPT \
		cpanm --notest --local-lib-contained "$(CURDIR)/deps/perl5" "$(DEPS_TN)"
	@touch $@

deps: $(DEPS_TN)/Makefile.PL deps/.perl5.stamp ;

$(DEPS_TN)/Makefile.PL:
	git submodule update --init

# ----------------------------------------------------------------------------
# test: PERL5LIB points only at deps/, so the system @INC is never consulted
# ----------------------------------------------------------------------------
# Test::Nginx runs nginx with prefix t/servroot and resolves
# $TEST_NGINX_HTML_DIR to t/servroot/html. Link the built OpenResty's lualib
# there so resty.core/lrucache load from our own build, not a sibling repo.
SERVROOT := t/servroot
# Test::Nginx reaps its forked mock servers with SIGQUIT by default, which
# makes perl dump core and trips systemd-coredump's "Process crashed" alert
# on every run. FAST_SHUTDOWN switches that to SIGTERM: same result, no core.
test: build deps
	@test -x "$(NGINX)" || { echo "nginx not built: $(NGINX)" >&2; exit 1; }
	@mkdir -p $(SERVROOT)/html
	@ln -sfn $(CURDIR)/$(SRC)/work/lualib $(SERVROOT)/html/lualib
	PERL5LIB="$(DEPS_PERL)" \
	TEST_NGINX_FAST_SHUTDOWN=1 \
	TEST_NGINX_BINARY="$(NGINX)" \
	LD_LIBRARY_PATH="$(CURDIR)/../mockeagain:$(SRC_ABS)/work/luajit/lib" \
	"$(PROVE)" -v -I"$(DEPS_TN)/lib" $(if $(FILES),$(FILES),t/)

# No dependency on build: installing into a system OpenResty must not
# compile one. LUA_LIB_DIR is absolute, so no slash between the two.
install:
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty/
	$(INSTALL) lib/resty/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/

lint:
	luacheck .

# OpenResty convention, enforced by reindex from openresty-devel-utils:
# three blank lines between blocks, one after __DATA__, TEST numbers
# contiguous from 1. Set REINDEX to a checkout if it is not on PATH.
REINDEX  ?= $(wildcard ../openresty-devel-utils/reindex)
fmt:
	@test -n "$(REINDEX)" || { echo "reindex not found; set REINDEX=/path/to/reindex" >&2; exit 1; }
	@$(REINDEX) t/*.t

clean:
	rm -rf $(BUILD) $(SERVROOT)

distclean: clean
	rm -rf deps/perl5 deps/.perl5.stamp
