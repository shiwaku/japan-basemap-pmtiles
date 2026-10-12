# GitHub Actions のランナー（ubuntu-24.04 + Java 21 + aws cli + jq + osmium + python3）と同じ道具をそろえたローカル実行用イメージ。
#   docker compose build
#   docker compose run --rm pipeline scripts/build-osm.sh
FROM ubuntu:24.04

ARG AWSCLI_VERSION=2.37.9
ARG PMTILES_VERSION=1.31.2
ARG PMTILES_SHA256=3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl jq unzip openjdk-21-jre-headless osmium-tool python3 \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip

# scripts/lib.sh の install_pmtiles は pmtiles が PATH にあれば何もしない
RUN curl -fsSL -o /tmp/pmtiles.tgz \
      "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz" \
 && echo "${PMTILES_SHA256}  /tmp/pmtiles.tgz" | sha256sum -c - \
 && tar -xzf /tmp/pmtiles.tgz -C /usr/local/bin pmtiles \
 && rm /tmp/pmtiles.tgz

WORKDIR /repo
