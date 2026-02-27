resource "digitalocean_droplet" "aegis_proto" {
  name   = "aegis-vps-prototype"
  size   = "s-2vcpu-4gb"
  region = "fra1"
  image  = "ubuntu-22-04-x64"

  user_data = <<-EOF
              #!/bin/bash
              curl -sfL https://get.k3s.io | sh -s - --disable traefik
              EOF
}
