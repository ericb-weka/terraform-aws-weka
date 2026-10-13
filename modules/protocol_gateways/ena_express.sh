#!/bin/bash
# ENA Express (SRD) host tuning for the primary (kernel/management) ENI.
# Rendered by Terraform (templatefile) and prepended to the protocol gateway
# user data when ena_express_enabled is true. Everything runs in a subshell so
# it cannot change the shell state or exit status of the WEKA bootstrap that
# follows it, and a tuning failure never blocks the bootstrap.
# Ref: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ena-express.html
(
  set -u
  exec >> /var/log/ena-express-setup.log 2>&1
  echo "$(date -u): ENA Express host setup starting"

  # Only the primary ENI exists at this point; the WEKA DPDK ENIs attached
  # later by the bootstrap are not touched.
  iface=$(ip -o -4 route show default | awk '{print $5; exit}')
  if [ -z "$iface" ]; then
    echo "$(date -u): no default-route interface found, skipping"
    exit 0
  fi
  echo "$(date -u): primary interface is $iface"

  # Runtime tuning, re-applied on every boot by ena-express-tune.service.
  cat > /usr/local/sbin/ena-express-tune.sh <<'EOF'
#!/bin/bash
# Applies MTU and ring sizes to the default-route interface for ENA Express.
mtu=${mtu}
tx_ring_target=1024
rx_ring_target=8192

iface=$(ip -o -4 route show default | awk '{print $5; exit}')
[ -z "$iface" ] && { echo "no default-route interface"; exit 0; }

ip link set dev "$iface" mtu "$mtu" && echo "$iface mtu set to $mtu"

if command -v ethtool >/dev/null 2>&1; then
  # Section 1 of `ethtool -g` is pre-set maximums, section 2 is current values.
  rx_max=$(ethtool -g "$iface" | awk '/^RX:/{print $2; exit}')
  tx_max=$(ethtool -g "$iface" | awk '/^TX:/{print $2; exit}')
  rx_cur=$(ethtool -g "$iface" | awk '/^RX:/{v=$2} END{print v}')
  tx_cur=$(ethtool -g "$iface" | awk '/^TX:/{v=$2} END{print v}')
  rx=$(( rx_max < rx_ring_target ? rx_max : rx_ring_target ))
  tx=$(( tx_max < tx_ring_target ? tx_max : tx_ring_target ))
  # Resizing resets the ENA device briefly, so only do it when needed.
  if [ "$rx_cur" -lt "$rx" ] || [ "$tx_cur" -lt "$tx" ]; then
    ethtool -G "$iface" rx "$rx" tx "$tx" && echo "$iface rings set to rx=$rx tx=$tx"
  fi
fi
exit 0
EOF
  chmod 0755 /usr/local/sbin/ena-express-tune.sh

  cat > /etc/systemd/system/ena-express-tune.service <<'EOF'
[Unit]
Description=ENA Express MTU and ring tuning for primary ENI
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ena-express-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # The VPC DHCP server advertises MTU 9001. Stop the network manager in use
  # from putting it back on lease renewal.
  if systemctl is-active --quiet systemd-networkd; then
    # Amazon Linux 2023 and other systemd-networkd distributions.
    network_file=$(networkctl status "$iface" 2>/dev/null | awk -F': ' '/Network File/{print $2; exit}')
    if [ -n "$network_file" ] && [ "$network_file" != "n/a" ]; then
      dropin_dir="/etc/systemd/network/$(basename "$network_file").d"
      mkdir -p "$dropin_dir"
      cat > "$dropin_dir/90-ena-express-mtu.conf" <<EOF
[Link]
MTUBytes=${mtu}

[DHCPv4]
UseMTU=false
EOF
      echo "$(date -u): wrote $dropin_dir/90-ena-express-mtu.conf"
      networkctl reload || true
    else
      echo "$(date -u): could not resolve the systemd-networkd file for $iface"
    fi
  elif systemctl is-active --quiet NetworkManager; then
    # RHEL / Rocky and other NetworkManager distributions. Match the profile by
    # UUID (names are not unique) and reapply so the live device picks the MTU
    # up now rather than at the next DHCP renewal.
    conn=$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null)
    if [ -n "$conn" ] && [ "$conn" != "--" ]; then
      if nmcli connection modify "$conn" 802-3-ethernet.mtu ${mtu}; then
        nmcli device reapply "$iface" || nmcli connection up "$conn" || true
        echo "$(date -u): set NetworkManager mtu ${mtu} on connection $conn"
      else
        echo "$(date -u): nmcli connection modify failed for $conn"
      fi
    else
      echo "$(date -u): could not resolve the NetworkManager connection for $iface"
    fi
  elif command -v dhclient >/dev/null 2>&1; then
    # Amazon Linux 2 and other dhclient/network-scripts distributions.
    # The enter hook covers the dhclient already running; dhclient.conf covers
    # every later start; ifcfg covers the network service itself.
    mkdir -p /etc/dhcp
    hook=/etc/dhcp/dhclient-enter-hooks
    if ! grep -q 'ENA Express' "$hook" 2>/dev/null; then
      # Append to any hook the AMI already ships rather than replacing it.
      [ -f "$hook" ] || echo '#!/bin/bash' > "$hook"
      cat >> "$hook" <<'EOF'

# ENA Express: keep the primary ENI MTU, ignore the DHCP-advertised 9001.
new_interface_mtu=${mtu}
EOF
      chmod 0755 "$hook"
    fi
    grep -q 'supersede interface-mtu' /etc/dhcp/dhclient.conf 2>/dev/null || echo "supersede interface-mtu ${mtu};" >> /etc/dhcp/dhclient.conf
    ifcfg="/etc/sysconfig/network-scripts/ifcfg-$iface"
    if [ -f "$ifcfg" ] && ! grep -q '^MTU=' "$ifcfg"; then
      echo "MTU=${mtu}" >> "$ifcfg"
    fi
    echo "$(date -u): configured dhclient to keep mtu ${mtu}"
  else
    echo "$(date -u): unknown network manager; mtu may be reset by DHCP"
  fi

  cat > /etc/sysctl.d/90-ena-express.conf <<'EOF'
# ENA Express recommended TCP settings
net.ipv4.tcp_limit_output_bytes = 1048576
net.ipv4.tcp_autocorking = 0
EOF
  sysctl -p /etc/sysctl.d/90-ena-express.conf || true

  systemctl daemon-reload
  systemctl enable --now ena-express-tune.service || /usr/local/sbin/ena-express-tune.sh

  # A ring resize briefly resets the ENA device. Make sure the link and IMDS
  # are back before the WEKA bootstrap (which curls IMDS under set -e) starts.
  # Bounded and never fatal.
  for _ in $(seq 1 30); do
    if ip link show "$iface" | grep -q 'state UP' && curl -s -m 2 -o /dev/null http://169.254.169.254/; then
      break
    fi
    sleep 1
  done

  ip link show "$iface"
  echo "$(date -u): ENA Express host setup done"
) || echo "ENA Express host setup failed; see /var/log/ena-express-setup.log"
