#!/usr/bin/env bash
# Builds amp-sleep.jar (Java 8 bytecode). Needs a JDK 9+ (javac --release 8).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/classes
javac --release 8 -encoding UTF-8 -d build/classes AmpSleep.java
printf 'Main-Class: AmpSleep\n' > build/manifest.txt
# fixed timestamps so the same source gives the same jar
find build/classes -exec touch -d '2026-01-01 00:00:00' {} +
(cd build/classes && jar --create --file ../amp-sleep.jar --manifest ../manifest.txt --date=2026-01-01T00:00:00Z *.class)
sha256sum build/amp-sleep.jar
