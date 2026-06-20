# release.mk — Blueberry Desktop release versioning (Ubuntu-style cadence)
#
# Scheme:  YY.MM   where MM = 04 (April) or 10 (October)
#   * Two releases per year: .04 (April) and .10 (October).
#   * LTS every two years, on the April release of even-numbered years.
#   * Standard releases: 9 months of updates. LTS: 2 years.
#
# Examples:  26.04 LTS, 26.10, 27.04, 27.10, 28.04 LTS …
#
# Override any BBD_* on the command line to pin a build, e.g.
#   make desktop-iso BBD_VERSION=26.10 BBD_CODENAME="Crisp Cranberry"

# ── Derive the cycle from the build date unless pinned ────────────────────────
# BBD_VERSION is authoritative: if pinned on the command line, year/rel follow
# it; otherwise it is derived from the build date. The .04 release ships in
# April (dev cycle Nov–Apr), the .10 in October (dev cycle May–Oct).
BBD_VERSION ?= $(shell printf '%s.%s' "$$(date +%y)" \
  "$$(m=$$(date +%m); if [ $$m -ge 5 ] && [ $$m -le 10 ]; then echo 10; else echo 04; fi)")

# Split the (possibly pinned) version into year + release.
BBD_YEAR := $(word 1,$(subst ., ,$(BBD_VERSION)))
BBD_REL  := $(word 2,$(subst ., ,$(BBD_VERSION)))

# LTS = the April release of an even-numbered year.
BBD_IS_LTS := $(shell [ "$(BBD_REL)" = "04" ] && [ $$(( $(BBD_YEAR) % 2 )) -eq 0 ] && echo yes || echo no)
ifeq ($(BBD_IS_LTS),yes)
  BBD_SUFFIX  := LTS
  BBD_CHANNEL := lts
  BBD_EOL_MONTHS := 24
else
  BBD_SUFFIX  :=
  BBD_CHANNEL := stable
  BBD_EOL_MONTHS := 9
endif

# Full marketing string, e.g. "Blueberry Desktop 26.04 LTS"
BBD_FULLVERSION := $(strip $(BBD_VERSION) $(BBD_SUFFIX))
BBD_NAME        := Blueberry Desktop

# ── Codename ──────────────────────────────────────────────────────────────────
# Looked up from editions/desktop/codenames (version<TAB>codename). Kept in a
# data file rather than a make `case` because GNU make balances parens inside
# $(shell ...) and a bare `26.04)` would close the call early. Pin BBD_CODENAME
# to override.
_BBD_CODENAMES := $(TOPDIR)/editions/desktop/codenames
BBD_CODENAME ?= $(shell awk -F'\t' -v v="$(BBD_VERSION)" \
  '/^#/{next} $$1==v{print $$2; found=1} END{if(!found) print "Blueberry Desktop " v}' \
  $(_BBD_CODENAMES) 2>/dev/null)

.PHONY: desktop-version
desktop-version:
	@echo "$(BBD_NAME) $(BBD_FULLVERSION) ($(BBD_CODENAME))"
	@echo "  channel : $(BBD_CHANNEL)   support: $(BBD_EOL_MONTHS) months"
