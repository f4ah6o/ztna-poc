FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/c_icap

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    bzip2 \
    build-essential \
    ca-certificates \
    curl \
    file \
    git \
    libarchive-dev \
    libcache-memcached-perl \
    libbz2-dev \
    libconfig-general-perl \
    libcurl4-openssl-dev \
    libdbd-mysql-perl \
    libdbi-perl \
    libdigest-sha-perl \
    libjson-perl \
    libmagic-dev \
    libmemcached-dev \
    libnet-ldap-perl \
    libssl-dev \
    libsys-syslog-perl \
    libtext-csv-xs-perl \
    libtool \
    perl \
    pkg-config \
    zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*

ARG CICAP_VERSION=0.5.10
RUN curl -fsSL -o /tmp/c_icap.tar.gz "https://downloads.sourceforge.net/project/c-icap/c-icap/0.5.x/c_icap-${CICAP_VERSION}.tar.gz" \
  && tar -xzf /tmp/c_icap.tar.gz -C /tmp \
  && cd "/tmp/c_icap-${CICAP_VERSION}" \
  && ./configure --prefix=/usr/local \
  && make -j"$(nproc)" \
  && make install \
  && rm -rf /tmp/c_icap* "/tmp/c_icap-${CICAP_VERSION}"

RUN git clone --depth 1 https://github.com/SeciossOpenSource/SquidSCAS.git /tmp/SquidSCAS \
  && cd /tmp/SquidSCAS/squidscas \
  && ./configure --with-c-icap=/usr/local \
  && make -j"$(nproc)" \
  && make install \
  && cp /tmp/SquidSCAS/scripts/*.pl /usr/local/sbin/ \
  && cp /tmp/SquidSCAS/scripts/*.sh /usr/local/sbin/ \
  && cp /tmp/SquidSCAS/scripts/cloud_discovery.db /usr/local/etc/ \
  && chmod +x /usr/local/sbin/*.pl /usr/local/sbin/*.sh \
  && rm -rf /tmp/SquidSCAS

RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/local-cicap.conf \
  && echo "/usr/local/lib/c_icap" >> /etc/ld.so.conf.d/local-cicap.conf \
  && ldconfig

COPY conf/c-icap.conf /usr/local/etc/c-icap.conf
COPY conf/squidscas.conf /usr/local/etc/squidscas.conf
COPY conf/scas_scan.conf /usr/local/etc/scas_scan.conf
COPY scripts/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
  && mkdir -p /var/log/c-icap /usr/local/var/scan /etc/squid \
  && touch /etc/squid/virus /etc/squid/blacklist_bump

EXPOSE 1344
ENTRYPOINT ["/entrypoint.sh"]
