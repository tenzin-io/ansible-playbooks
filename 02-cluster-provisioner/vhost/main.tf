terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.8.1"
    }
  }
}

data "terraform_remote_state" "hypervisor" {
  backend = "s3"
  config = {
    bucket = "tenzin-io"
    key    = "terraform/01-hypervisor-setup/vhost.tfstate"
    region = "us-east-1"
  }
}

locals {
  hypervisor_hostname     = data.terraform_remote_state.hypervisor.outputs.hypervisor_connection.hostname
  hypervisor_ssh_user     = data.terraform_remote_state.hypervisor.outputs.hypervisor_connection.ssh_user
  hypervisor_ssh_key_name = data.terraform_remote_state.hypervisor.outputs.hypervisor_connection.ssh_key_name
}

provider "libvirt" {
  uri = "qemu+ssh://${local.hypervisor_ssh_user}@${local.hypervisor_hostname}/system?keyfile=${local.hypervisor_ssh_key_name}&sshauth=privkey&no_verify=1"
}

provider "vault" {
  address = "https://vault.tenzin.io"
}

data "vault_generic_secret" "dockerhub" {
  path = "secrets/dockerhub"
}

data "vault_generic_secret" "tailscale" {
  path = "secrets/tailscale"
}

resource "null_resource" "install_packages" {
  provisioner "local-exec" {
    command = <<-EOT
      sudo apt-get update
      sudo apt-get install -y mkisofs xsltproc
    EOT
  }
}

// virtual machines on vhost_1
module "cluster_1" {
  depends_on = [null_resource.install_packages]
  count      = 1
  source     = "git::https://github.com/tenzin-io/terraform-modules.git//libvirt/cluster?ref=main"

  cluster_name = var.cluster_name
  cluster_uuid = var.cluster_uuid

  vpc_network_mode = "nat"
  vpc_network_cidr = var.vpc_network_cidr

  base_volume = {
    id   = data.terraform_remote_state.hypervisor.outputs.base_cloud_image.id
    name = data.terraform_remote_state.hypervisor.outputs.base_cloud_image.name
    pool = data.terraform_remote_state.hypervisor.outputs.base_cloud_image.pool_name
  }

  # for container image pull
  docker_hub_user  = data.vault_generic_secret.dockerhub.data["username"]
  docker_hub_token = data.vault_generic_secret.dockerhub.data["api_token"]

  create_agent_node  = true
  tailscale_auth_key = data.vault_generic_secret.tailscale.data["auth_key"]

  worker_node_count      = 3
  worker_cpu_count       = 4
  worker_memory_size_mib = 16 * 1024 // gib
  worker_disk_size_mib   = 64 * 1024 // gib
}