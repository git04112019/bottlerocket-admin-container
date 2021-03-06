#!/bin/bash
# This file is part of Bottlerocket.
# Copyright Amazon.com, Inc., its affiliates, or other contributors. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -e

mkdir -p /home/ec2-user/.ssh/
chmod 700 /home/ec2-user/.ssh/
ssh_host_key_dir="/.bottlerocket/host-containers/admin/etc/ssh"
ssh_config_dir="/home/ec2-user/.ssh"

# Populate authorized_keys with all the public keys found in instance meta-data
# The URLs for keys include an index and the keypair name, e.g.
# http://169.254.169.254/latest/meta-data/public-keys/0=mykeypair/openssh-key
ssh_authorized_keys="${ssh_config_dir}/authorized_keys"
touch ${ssh_authorized_keys}
chmod 600 ${ssh_authorized_keys}
public_key_base_url="http://169.254.169.254/latest/meta-data/public-keys/"
imds_session_token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
imds_request_add_header="X-aws-ec2-metadata-token: ${imds_session_token}"
public_key_indexes=($(curl -H "${imds_request_add_header}" -sf "${public_key_base_url}" \
    | cut -d= -f1 \
    | xargs))

for public_key_index in "${public_key_indexes[@]}"; do
  public_key_data="$(curl -H "${imds_request_add_header}" -sf "${public_key_base_url}/${public_key_index}/openssh-key")"
  if [[ ! "${public_key_data}" =~ ^"ssh" ]]; then
    echo "Key ${public_key_data} with index ${public_key_index} looks invalid" >&2
    continue
  fi
  echo "${public_key_data}" >> "${ssh_authorized_keys}"
  if ! grep -q "${public_key_data}" "${ssh_authorized_keys}"; then
    echo "Failed to write key with index ${public_key_index} to authorized_keys" >&2
    continue
  fi
done

# If we didn't write any keys at all, there's not much point in continuing
if [ ! -s "${ssh_authorized_keys}" ]; then
  echo "Failed to write any valid public keys to authorized_keys" >&2
  exit 1
fi

chown ec2-user -R "${ssh_config_dir}"

# Generate the server keys
mkdir -p "${ssh_host_key_dir}"
for key in rsa ecdsa ed25519; do
    # If both of the keys exist, don't overwrite them
    if [ -s "${ssh_host_key_dir}/ssh_host_${key}_key" ] && [ -s "${ssh_host_key_dir}/ssh_host_${key}_key.pub"  ]; then
        echo "${key} key already exists, will use existing key." >&2
        continue
    fi

    rm -rf \
       "${ssh_host_key_dir}/ssh_host_${key}_key" \
       "${ssh_host_key_dir}/ssh_host_${key}_key.pub"
    if ssh-keygen -t "${key}" -f "${ssh_host_key_dir}/ssh_host_${key}_key" -q -N ""; then
        chmod 600 "${ssh_host_key_dir}/ssh_host_${key}_key"
        chmod 644 "${ssh_host_key_dir}/ssh_host_${key}_key.pub"
    else
        echo "Failure to generate host ${key} ssh keys" >&2
        exit 1
    fi
done

# Start a single sshd process in the foreground
exec /usr/sbin/sshd -e -D
