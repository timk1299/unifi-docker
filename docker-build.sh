#!/usr/bin/env bash

# fail on error
set -e

# Retry 5 times with a wait of 10 seconds between each retry
tryfail() {
    for i in $(seq 1 5);
        do [ $i -gt 1 ] && sleep 10; $* && s=0 && break || s=$?; done;
    (exit $s)
}

# Try multiple keyservers in case of failure
addKey() {
    for server in $(shuf -e ha.pool.sks-keyservers.net \
        hkp://p80.pool.sks-keyservers.net:80 \
        keyserver.ubuntu.com \
        hkp://keyserver.ubuntu.com:80 \
        pgp.mit.edu) ; do \
        if apt-key adv --keyserver "$server" --recv "$1"; then
            exit 0
        fi
    done
    return 1
}

if [ "x${1}" == "x" ]; then
    echo please pass PKGURL as an environment variable
    exit 0
fi

apt-get update
apt-get install -qy --no-install-recommends \
    apt-transport-https \
    curl \
    dirmngr \
    gpg \
    gpg-agent \
    openjdk-25-jre-headless \
    procps \
    libcap2-bin \
    tzdata \
    binutils \
    logrotate \
    zip \
    unzip
echo 'deb https://www.ui.com/downloads/unifi/debian stable ubiquiti' | tee /etc/apt/sources.list.d/100-ubnt-unifi.list
tryfail curl -o /etc/apt/trusted.gpg.d/unifi-repo.gpg https://dl.ui.com/unifi/unifi-repo.gpg
if [ -d "/usr/local/docker/pre_build/$(dpkg --print-architecture)" ]; then
    find "/usr/local/docker/pre_build/$(dpkg --print-architecture)" -type f -exec '{}' \;
fi

curl -L -o ./unifi.deb "${1}"
# unifi-core and unifi-matter-controller are UniFi OS components required by the
# 11.x UniFi OS package; they are not needed (or available) for standalone use.
dpkg -i --ignore-depends=mongodb-org-server,unifi-core,unifi-matter-controller ./unifi.deb
rm -f ./unifi.deb

# EXPERIMENTAL: convert a UniFi OS build back into a standalone launchable layout
# (zip/unzip were installed above; removed with dpkg since apt refuses while unifi has ignored deps)
bash /usr/local/bin/uos-repack.sh "${BASEDIR}/lib"
dpkg --purge zip unzip
rm -f /usr/local/bin/uos-repack.sh
# hide the "Upgrade to UniFi OS Server" modal shown after every login
bash /usr/local/bin/uos-webui-patch.sh "${BASEDIR}/webapps/ROOT"
rm -f /usr/local/bin/uos-webui-patch.sh

chown -R unifi:unifi /usr/lib/unifi
rm -rf /var/lib/apt/lists/*

rm -rf ${ODATADIR} ${OLOGDIR} ${ORUNDIR} ${BASEDIR}/data ${BASEDIR}/run ${BASEDIR}/logs
mkdir -p ${DATADIR} ${LOGDIR} ${RUNDIR}
ln -s ${DATADIR} ${BASEDIR}/data
ln -s ${RUNDIR} ${BASEDIR}/run
ln -s ${LOGDIR} ${BASEDIR}/logs
ln -s ${DATADIR} ${ODATADIR}
ln -s ${LOGDIR} ${OLOGDIR}
ln -s ${RUNDIR} ${ORUNDIR}
mkdir -p /var/cert ${CERTDIR}
ln -s ${CERTDIR} /var/cert/unifi

rm -rf "${0}"
