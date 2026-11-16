#!/usr/bin/env bash
#
# EXPERIMENTAL: make the UniFi OS build of the Network Application (11.x+) run standalone.
#
# Since 11.0 Ubiquiti only ships the Network Application as a UniFi OS package. Its
# ace.jar is a Spring Boot fat jar whose Start-Class (com.ubnt.ace.BootLauncher) is the
# UniFi OS entry point and needs UniFi Core. The classic standalone entry point
# (com.ubnt.ace.Launcher, "ace.jar start|stop") is still included, but:
#   1. it cannot be started from inside the fat jar (Tomcat's webapp classloader cannot
#      see the nested BOOT-INF/lib jars), and
#   2. the UOS build no longer bundles a few libraries the standalone path needs.
#
# This script repacks ace.jar into the pre-11 layout:
#   lib/ace.jar     thin jar, Main-Class com.ubnt.ace.Launcher, Class-Path -> jars/*
#   lib/jars/*.jar  former BOOT-INF/lib content plus the missing libraries
# It does nothing if ace.jar is not a UniFi OS fat jar (e.g. a 10.x standalone build).

set -euo pipefail

LIB=${1:-/usr/lib/unifi/lib}
ACE="${LIB}/ace.jar"

# Libraries that 10.x shipped but the UOS build dropped (used by cloud access / remote
# management). Fetched from Maven Central and verified against pinned sha256 sums.
EXTRA_JARS=(
    "ca/ryangreen/apigateway-generic-java-sdk/1.3/apigateway-generic-java-sdk-1.3.jar a9fcadfa0877d412b85297692a431d80d251e876dcc21c70930cf990a03d60b4"
    "com/amazonaws/aws-iot-device-sdk-java/1.2.0/aws-iot-device-sdk-java-1.2.0.jar a28b8b7930e71d8c36a2e77ec969bd7261c999c028acd2bb2981c2df8f2a8461"
    "com/amazonaws/aws-java-sdk-core/1.12.777/aws-java-sdk-core-1.12.777.jar 4c694161d897a5082132b062f6e3f1b50ac79af14c11d0eaf08e77fde49db646"
    "joda-time/joda-time/2.12.7/joda-time-2.12.7.jar 385282b005818cfaccdbe8bd2429811e7e641782f2b88932a6b8ff51d668f616"
    "org/json/json/20231013/json-20231013.jar 0f18192df289114e17aa1a0d0a7f8372cc9f5c7e4f7e39adcf8906fe714fa7d3"
    "org/eclipse/paho/org.eclipse.paho.client.mqttv3/1.1.0/org.eclipse.paho.client.mqttv3-1.1.0.jar b61e8455ba5f18fb021964268d32a0d7ebbdbfa7d87154a44e9e565248f08d86"
)
MAVEN=${MAVEN_MIRROR:-https://repo1.maven.org/maven2}

if ! unzip -p "${ACE}" META-INF/MANIFEST.MF | grep -q '^Start-Class: com.ubnt.ace.BootLauncher'; then
    echo "uos-repack: ${ACE} is not a UniFi OS build, nothing to do"
    exit 0
fi
if ! unzip -l "${ACE}" 'BOOT-INF/classes/com/ubnt/ace/Launcher.class' >/dev/null 2>&1 \
   && ! unzip -l "${ACE}" 'BOOT-INF/lib/internal-dependencies.jar' >/dev/null 2>&1; then
    echo "uos-repack: standalone launcher not found in ${ACE}" >&2
    exit 1
fi

W=$(mktemp -d)
trap 'rm -rf "${W}"' EXIT
cd "${W}"

unzip -q "${ACE}" 'BOOT-INF/*'
mkdir -p "${LIB}/jars"

# keep the classpath order Spring Boot would have used
if [ -f BOOT-INF/classpath.idx ]; then
    sed -n 's/^- "\(.*\)"$/\1/p' BOOT-INF/classpath.idx | sed 's|^BOOT-INF/lib/||' > order.txt
else
    ls BOOT-INF/lib > order.txt
fi
mv BOOT-INF/lib/*.jar "${LIB}/jars/"

for entry in "${EXTRA_JARS[@]}"; do
    path=${entry% *}
    sum=${entry#* }
    name=$(basename "${path}")
    curl -fsSL --retry 5 -o "${LIB}/jars/${name}" "${MAVEN}/${path}"
    echo "${sum}  ${LIB}/jars/${name}" | sha256sum -c --quiet -
    echo "${name}" >> order.txt
done

cd BOOT-INF/classes
mkdir -p META-INF
{
    printf 'Manifest-Version: 1.0\r\n'
    printf 'Main-Class: com.ubnt.ace.Launcher\r\n'
    printf 'Class-Path: \r\n'
    while read -r j; do
        [ -f "${LIB}/jars/${j}" ] || continue
        case "${j}" in spring-boot-jarmode-tools-*) continue ;; esac
        printf ' jars/%s \r\n' "${j}"
    done < ../../order.txt
    printf '\r\n'
} > META-INF/MANIFEST.MF
if awk 'length($0) > 72 {exit 1}' META-INF/MANIFEST.MF; then :; else
    echo "uos-repack: manifest line too long" >&2
    exit 1
fi

rm -f "${ACE}"
zip -q -X "${ACE}" META-INF/MANIFEST.MF
zip -q -X -r "${ACE}" . -x META-INF/MANIFEST.MF

echo "uos-repack: repacked ${ACE} ($(ls "${LIB}/jars" | wc -l) jars)"
