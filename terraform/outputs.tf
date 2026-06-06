output "server_ip" {
  description = "Public IPv4 of the Kratix IDP server"
  value       = hcloud_server.kratix.ipv4_address
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh root@${hcloud_server.kratix.ipv4_address}"
}
