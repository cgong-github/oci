#cloud-config

write_files:
  # Create file to be used when enabling ip forwarding
  - path: /etc/sysctl.d/98-ip-forward.conf
    content: |
      net.ipv4.ip_forward = 1

runcmd:
  # Run firewall commands to enable masquerading and port forwarding
  # Enable ip forwarding by setting sysctl kernel parameter
  - wget -O /usr/local/bin/secondary_vnic_all_configure.sh https://raw.githubusercontent.com/cgong-github/oci/automation/secondary_vnic_all_configure.sh
  - chmod +x /usr/local/bin/secondary_vnic_all_configure.sh
  - firewall-offline-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -o ens3 -j MASQUERADE
  - /bin/systemctl restart firewalld
  - sysctl -p /etc/sysctl.d/98-ip-forward.conf

