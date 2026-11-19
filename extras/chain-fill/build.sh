#!/usr/bin/env bash
# Rebuilds chain-fill.jar (Java 8 bytecode) from src/. Needs a JDK 11-17.
set -euo pipefail
cd "$(dirname "$0")"
JDK=${JDK:-/usr/lib/jvm/java-17-openjdk-amd64}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
"$JDK/bin/javac" --release 8 -d "$t/c" src/railwaydsc/ChainFillAgent.java
printf 'Premain-Class: railwaydsc.ChainFillAgent\nAgent-Class: railwaydsc.ChainFillAgent\nMain-Class: railwaydsc.ChainFillAgent\n' > "$t/m"
"$JDK/bin/jar" --create --file chain-fill.jar --manifest "$t/m" --date=2026-11-18T00:00:00Z -C "$t/c" .
sha256sum chain-fill.jar
