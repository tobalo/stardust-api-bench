# StardustDB Nanode and Linode 2GB Challenge: an embedded StardustDB database behind a Rust
# io_uring HTTP server, benchmarked with the $12 server challenge's API and k6 load test.
#
# Needs the StardustDB release bundle in third_party/ and a license (see README).

SHELL := /bin/bash
.PHONY: help seed check unit up bench redline connections report down

help: ## list targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

seed: ## build the seed database (~80 s, ~8 GB RAM) and its compressed upload copy
	bash seed/make-seed.sh
	zstd -T0 -3 -q -f seed/feed.stardust -o seed/feed.stardust.zst

check: ## build the server and run the 42 API checks on this machine
	bash bench/check.sh

unit: ## the server's unit tests
	cd server && STARDUST_LIBRARY_DIR=$(CURDIR)/third_party/stardust/lib cargo test --release --locked -q

up: ## provision and deploy on Linode: make up [TYPE=g6-standard-1] [CLIENT=g6-dedicated-4] [ARGS=--stock]
	bash deploy/linode/up.sh $(if $(TYPE),--type $(TYPE)) $(if $(CLIENT),--client $(CLIENT)) $(ARGS)

bench: ## score the server with the challenge procedure, or one run: make bench [VUS=1000]
	bash deploy/linode/bench.sh $(if $(filter command line,$(origin VUS)),--vus $(VUS))

redline: ## score, then keep adding users to find the peak throughput and the breaking point
	bash deploy/linode/bench.sh --redline

connections: ## keep-alive connections over every server address, step by step until one fails: make connections [CONNS="70000 125000"]
	$(if $(CONNS),CONNECTIONS="$(CONNS)") bash deploy/linode/bench.sh --connections

report: ## charts for result folders: make report RESULTS="bench/results/A [bench/results/B ...]"
	python3 bench/report.py $(RESULTS) $(if $(word 2,$(RESULTS)),-o bench/results/compare.html)

down: ## destroy the Linode server, client and firewalls
	bash deploy/linode/up.sh --down
