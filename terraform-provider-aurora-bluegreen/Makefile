BINARY    = terraform-provider-aurora-bluegreen
VERSION   = 1.0.0
REGISTRY  = registry.terraform.io/local/aurora-bluegreen
LOCK_FILE = ../okta-auth-sample/.terraform.lock.hcl

.PHONY: build install-darwin-arm64 install-darwin-amd64 install-linux-amd64 tidy clean

build:
	go build -ldflags "-X main.version=$(VERSION)" -o $(BINARY) .

tidy:
	go mod tidy

# Install for local macOS (Apple Silicon) + clear stale lock file.
# The lock file is gitignored but Terraform still creates it locally.
# Deleting it forces a fresh `terraform init` so the new binary's checksum
# is recorded (filesystem_mirror in ~/.terraformrc handles the lookup).
install-darwin-arm64: build
	mkdir -p ~/.terraform.d/plugins/$(REGISTRY)/$(VERSION)/darwin_arm64
	cp $(BINARY) ~/.terraform.d/plugins/$(REGISTRY)/$(VERSION)/darwin_arm64/$(BINARY)
	@rm -f $(LOCK_FILE) 2>/dev/null || true
	@echo "Installed → darwin_arm64"
	@echo "Lock file cleared (will be regenerated on next terraform init)"

install-darwin-amd64: build
	mkdir -p ~/.terraform.d/plugins/$(REGISTRY)/$(VERSION)/darwin_amd64
	cp $(BINARY) ~/.terraform.d/plugins/$(REGISTRY)/$(VERSION)/darwin_amd64/$(BINARY)
	@rm -f $(LOCK_FILE) 2>/dev/null || true
	@echo "Installed → darwin_amd64"

# Install for Linux amd64 — used by GitHub Actions ubuntu-latest runner.
# CI does not use dev_overrides, so the lock file must be absent (not committed).
install-linux-amd64: build
	mkdir -p ~/.terraform.d/plugins/$(REGISTRY)/$(VERSION)/linux_amd64
	cp $(BINARY) ~/.terraform.d/plugins/$(REGISTRY)/$(VERSION)/linux_amd64/$(BINARY)
	@echo "Installed → linux_amd64"

clean:
	rm -f $(BINARY)
