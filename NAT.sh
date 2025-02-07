#!/bin/bash

# Kiểm tra xem có nftables hay không
if command -v nft &> /dev/null; then
  NAT_CONFIG_CMD="nft list ruleset"
  NAT_TYPE_CHECK="nft"
else
  NAT_CONFIG_CMD="iptables -t nat -L -v"
  NAT_TYPE_CHECK="iptables"
fi

# Hàm kiểm tra NAT
check_nat() {
  local config_output
  config_output=$(eval "$NAT_CONFIG_CMD")

  # Check if the nat table is present at all (no NAT at all)
  if ! echo "$config_output" | grep -q "table ip nat"; then
      echo "No NAT"
      return
  fi


  # Check for NAT type 1 (Masquerade) - SNAT for a whole network on one interface on POSTROUTING chain
  if echo "$config_output" | grep -q "chain postrouting" &&  echo "$config_output" | grep -q 'masquerade'; then
      echo "NAT1"
      return
  fi


  # Check for NAT type 2 (SNAT with specific IP) on POSTROUTING chain
  if echo "$config_output" | grep -q "chain postrouting" && echo "$config_output" | grep -q 'snat to'; then
      echo "NAT2"
      return
   fi

  # Check for NAT type 3 (DNAT) on PREROUTING chain
  if echo "$config_output" | grep -q "chain prerouting" && echo "$config_output" | grep -q 'dnat to'; then
       echo "NAT3"
       return
  fi

  # If none of the above rules matched - still output "No NAT" because no common NAT rule found.
  echo "No NAT"
}

# Thực thi kiểm tra và in ra kết quả
check_nat
