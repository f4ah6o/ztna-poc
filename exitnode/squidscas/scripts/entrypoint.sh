#!/bin/sh
set -eu

mkdir -p /var/log/c-icap /var/run/c-icap /usr/local/var/scan /etc/squid
[ -f /etc/squid/virus ] || touch /etc/squid/virus
[ -f /etc/squid/blacklist_bump ] || touch /etc/squid/blacklist_bump
if command -v scas_service.pl >/dev/null 2>&1; then
  scas_service.pl > /etc/squid/scas_service.conf || true
fi

exec c-icap -N -D -f /usr/local/etc/c-icap.conf
