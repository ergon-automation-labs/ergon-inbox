MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: help deps test check clean release publish-release push-and-publish

help:
	@echo "Bot Army Inbox"
	@echo ""
	@echo "  make deps             - Fetch dependencies"
	@echo "  make test             - Run tests"
	@echo "  make check            - Run validation checks"
	@echo "  make release          - Build OTP release"
	@echo "  make publish-release  - Package and publish GitHub release"
	@echo "  make push-and-publish - Push branch then publish release"

deps:
	$(MIX) deps.get

test:
	$(MIX) test

check: test
	@echo "All checks passed!"

clean:
	$(MIX) clean
	rm -rf _build

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/bot_army_inbox
	MIX_ENV=prod $(MIX) release

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then echo "Failed to resolve version from mix.exs"; exit 1; fi; \
	TARBALL="bot_army_inbox-$$VERSION.tar.gz"; \
	tar -czf "$$TARBALL" -C _build/prod/rel bot_army_inbox/; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Bot Army Inbox Elixir release v$$VERSION." \
			--draft=false; \
	fi

push-and-publish:
	@git push && $(MAKE) publish-release
