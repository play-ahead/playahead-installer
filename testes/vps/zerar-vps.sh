#!/bin/bash
#
# testes/vps/zerar-vps.sh
#
# Desmonta a VPS de TESTE até o estado de máquina nova: as três stacks
# (com os volumes), o Docker, o swap e as pastas do instalador. Serve
# para repetir um teste do zero sem recriar a VPS na DigitalOcean.
#
# DESTRUTIVO: apaga bancos e volumes. Só numa VPS descartável, nunca
# numa instalação de verdade. Uso, como root na VPS:
#
#     bash zerar-vps.sh
#
for d in mautic portainer traefik; do [ -d /opt/playahead/$d ] && (cd /opt/playahead/$d && docker compose down -v >/dev/null 2>&1); done
docker network rm traefik_public >/dev/null 2>&1 || true
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras >/dev/null 2>&1
apt-get autoremove -y -qq >/dev/null 2>&1
rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /opt/containerd /opt/playahead
apt-get update -qq >/dev/null 2>&1
swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab
sed -i '/\.ci\.test/d' /etc/hosts
rm -rf /tmp/teste-instalador /root/repo
hash -r
echo "docker: $(command -v docker || echo ausente) | swap: $(swapon --show | wc -l) | /opt: $(ls /opt | tr '\n' ' ')| 80/443: $(ss -ltn | grep -cE ':(80|443) ')"
