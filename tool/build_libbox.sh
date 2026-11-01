#!/usr/bin/env bash
# Builds sing-box as an iOS framework. Needs macOS, Xcode and Go.
# Usage: build_libbox.sh <sing-box version> <output directory>
#
# The tags leave out what the app never uses: Tailscale, Naive, USB/IP, OpenVPN and
# the like. A smaller binary leaves more of the tunnel's 50 MB for connections.
set -euo pipefail

version="$1"
output="$(cd "$2" && pwd)"
gomobile_version=v0.1.13
tags=with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0,grpcnotrace

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 "https://github.com/SagerNet/sing-box/archive/refs/tags/v$version.tar.gz" |
  tar -xz -C "$work" --strip-components=1

cd "$work"
go install "github.com/sagernet/gomobile/cmd/gomobile@$gomobile_version"
go install "github.com/sagernet/gomobile/cmd/gobind@$gomobile_version"
export PATH="$(go env GOPATH)/bin:$PATH"

gomobile bind -v -target ios -libname=box -iosversion=15.0 -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$version -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags "$tags" ./experimental/libbox

rm -rf "$output/Libbox.xcframework"
mv Libbox.xcframework "$output/"
