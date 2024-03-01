terraform {
  required_version = ">= 0.13.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.6"
    }
    ct = {
      source  = "poseidon/ct"
      version = "~> 0.13.0"
    }
    template = {
      source  = "hashicorp/template"
      version = "~> 2.2.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "null_resource" "prepare_directory" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
    mkdir -p /var/lib/libvirt/images/${var.cluster_name} &&
    sudo chown -R qemu:qemu /var/lib/libvirt/images/${var.cluster_name} &&
    sudo chmod -R 755 /var/lib/libvirt/images/${var.cluster_name}
    EOT
  }
}

resource "libvirt_pool" "volumetmp" {
  name = var.cluster_name
  type = "dir"
  path = "/var/lib/libvirt/images/${var.cluster_name}"
}

resource "libvirt_volume" "base" {
  name   = "${var.cluster_name}-base"
  source = var.base_image
  pool   = libvirt_pool.volumetmp.name
  format = "qcow2"
  depends_on = [null_resource.prepare_directory]
}

data "ct_config" "ignition" {
  for_each = toset(var.machines)
  content = templatefile("${path.module}/../configs/${each.key}-config.yaml.tmpl", {
    ssh_keys = var.ssh_keys,
    message  = "Custom message here"
  })
}

resource "libvirt_ignition" "vm_ignition" {
  for_each = toset(var.machines)
  name     = "${each.value}-${var.cluster_name}-ignition"
  pool     = libvirt_pool.volumetmp.name
  content  = data.ct_config.ignition[each.value].rendered
}

resource "libvirt_volume" "vm_disk" {
  for_each       = toset(var.machines)
  name           = "${each.value}-${var.cluster_name}.qcow2"
  base_volume_id = libvirt_volume.base.id
  pool           = libvirt_pool.volumetmp.name
  format         = "qcow2"
}

resource "libvirt_network" "kube_network" {
  name      = "k8snet"
  mode      = "nat"
  domain    = "k8s.local"
  addresses = ["10.17.3.0/24"]
  dns {
    enabled    = true
    local_only = true
  }
  dhcp {
    enabled = true
  }
}

resource "libvirt_domain" "machine" {
  for_each = toset(var.machines)

  name   = "${each.value}-${var.cluster_name}"
  vcpu   = var.virtual_cpus
  memory = var.virtual_memory

  disk {
    volume_id = libvirt_volume.vm_disk[each.value].id
  }

  disk {
    volume_id = libvirt_ignition.vm_ignition[each.value].id
  }

  network_interface {
    network_id = libvirt_network.kube_network.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  # Coloca depends_on dentro del recurso para asegurar que la red esté creada primero
  depends_on = [libvirt_network.kube_network]
}

resource "local_file" "flatcar" {
  for_each = data.ct_config.ignition
  content  = each.value.rendered
  filename = "${path.module}/outputs/${each.key}.ign"
}
