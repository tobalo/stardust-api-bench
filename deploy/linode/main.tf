# The server under test: one Linode (Nanode 1 GB, then Linode 2 GB), Ubuntu
# 24.04, no swap, behind a Cloud Firewall that admits only this machine and,
# when enabled, a k6 client Linode (client_type), which sends the load from a
# datacenter link instead of yours. deploy/linode/up.sh applies this, then
# deploys the server over SSH with deploy/host/spinup.sh.

terraform {
  required_version = ">= 1.6"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# The API token comes from $LINODE_TOKEN (Linodes and Firewalls: read/write).
provider "linode" {}

# ---------- variables (up.sh writes deploy.auto.tfvars.json) ----------

variable "region" {
  description = "Linode region: us-central is Dallas, TX."
  type        = string
  default     = "us-central"
}

variable "bench_type" {
  description = "The server under test: g6-nanode-1 (Nanode 1 GB) first, then g6-standard-1 (Linode 2 GB)."
  type        = string
  default     = "g6-nanode-1"
}

variable "image" {
  type    = string
  default = "linode/ubuntu24.04"
}

variable "bench_swap_mb" {
  description = "Swap disk at creation. The provider cannot request 0 (Linode then adds 512 MB); deploy/host/spinup.sh disables swap in the OS, as on the challenge box."
  type        = number
  default     = 0
}

variable "ssh_public_key" {
  description = "The deploy key's public half (up.sh generates deploy/linode/.ssh/id_ed25519)."
  type        = string
}

variable "operator_cidrs" {
  description = "The load client: the machine running up.sh and k6 (up.sh detects its public address)."
  type        = list(string)
}

variable "http_ipv4" {
  description = "Extra IPv4 ranges allowed on port 80. Empty: only operator_cidrs (the k6 client)."
  type        = list(string)
  default     = []
}

variable "prefix" {
  description = "Label prefix (Linode and firewall labels must be unique in the account)."
  type        = string
  default     = "sdbench"
}

variable "client_type" {
  description = "Optional k6 client Linode (up.sh --client): empty for none, e.g. g6-dedicated-4. Dedicated CPUs keep the load steady."
  type        = string
  default     = ""
}

variable "bench_ipv6_range" {
  description = "Route an IPv6 /64 to the server, so make connections can spread connections over more server addresses than one client can open to one (~64,500 ports each)."
  type        = bool
  default     = true
}

variable "client_region" {
  description = "Region of the k6 client; empty means the server's region."
  type        = string
  default     = ""
}

# ---------- resources ----------


locals {
  client = var.client_type != "" ? 1 : 0
}

resource "linode_firewall" "client" {
  count           = local.client
  label           = "${var.prefix}-client"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = ["stardust-api-bench"]

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.operator_cidrs
  }
}

resource "linode_instance" "client" {
  count                = local.client
  label                = "${var.prefix}-client"
  region               = var.client_region != "" ? var.client_region : var.region
  type                 = var.client_type
  image                = var.image
  authorized_keys      = [var.ssh_public_key]
  root_pass            = random_password.root.result
  interface_generation = "legacy_config"
  firewall_id          = linode_firewall.client[0].id
  tags                 = ["stardust-api-bench"]
}

locals {
  client_ip = local.client == 1 ? one([for ip in linode_instance.client[0].ipv4 : ip if !startswith(ip, "192.168.")]) : ""
  # SLAAC address as "<address>/128". The client reaches the server over both
  # IPv4 and IPv6 to open more than ~64,500 connections (bench/connections.js).
  client_ipv6 = local.client == 1 ? linode_instance.client[0].ipv6 : ""
}

resource "random_password" "root" {
  length  = 32
  special = true
}

resource "linode_firewall" "bench" {
  label           = "${var.prefix}-bench"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = ["stardust-api-bench"]

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.operator_cidrs
  }
  inbound {
    label    = "http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = distinct(concat(var.operator_cidrs, var.http_ipv4, local.client == 1 ? ["${local.client_ip}/32"] : []))
    ipv6     = local.client == 1 ? [local.client_ipv6] : null
  }
  inbound {
    label    = "icmp"
    action   = "ACCEPT"
    protocol = "ICMP"
    ipv4     = ["0.0.0.0/0"]
  }
}

resource "linode_instance" "bench" {
  label                = "${var.prefix}-bench"
  region               = var.region
  type                 = var.bench_type
  image                = var.image
  authorized_keys      = [var.ssh_public_key]
  root_pass            = random_password.root.result
  swap_size            = var.bench_swap_mb
  interface_generation = "legacy_config"
  firewall_id          = linode_firewall.bench.id
  tags                 = ["stardust-api-bench"]

  # The provider sends swap_size 0 as "unset", so Linode adds its 512 MB swap
  # disk anyway, and changing it later resizes (reboots) the box. deploy/host/spinup.sh
  # turns swap off in the OS instead.
  lifecycle {
    ignore_changes = [swap_size]
  }
}

# ---------- outputs ----------

output "bench_ip" {
  description = "Benchmark this address: http://<bench_ip>/"
  value       = one([for ip in linode_instance.bench.ipv4 : ip if !startswith(ip, "192.168.")])
}

output "bench_ipv6" {
  description = "The server's IPv6 address (bench/connections.js uses both)."
  value       = split("/", linode_instance.bench.ipv6)[0]
}

resource "linode_ipv6_range" "bench" {
  count         = var.bench_ipv6_range ? 1 : 0
  linode_id     = linode_instance.bench.id
  prefix_length = 64
}

output "bench_ipv6_extra" {
  description = "Eight addresses of the server's routed /64: up.sh adds them to eth0, bench.sh connects to them."
  value       = var.bench_ipv6_range ? [for i in range(1, 9) : "${trimsuffix(split("/", linode_ipv6_range.bench[0].range)[0], "::")}::${format("%x", i)}"] : []
}

output "bench_type" {
  value = linode_instance.bench.type
}

output "client_ip" {
  description = "The k6 client Linode, or empty when there is none."
  value       = local.client_ip
}

output "client_type" {
  value = var.client_type
}
