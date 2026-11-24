FROM golang:tip-trixie AS permset
WORKDIR /src
RUN git clone https://github.com/jacobalberty/permset.git /src && \
    mkdir -p /out && \
    go build -ldflags "-X main.chownDir=/unifi" -o /out/permset

# EXPERIMENTAL (11.x): the UniFi OS build no longer ships the WebRTC JNI library used
# for remote access. Its native interface is unchanged, so take it from the last
# standalone release (official Ubiquiti package, verified by sha256).
FROM golang:tip-trixie AS webrtc
ARG WEBRTC_PKGURL=https://dl.ui.com/unifi/10.6.109/unifi_sysvinit_all.deb
ARG WEBRTC_PKGSHA256=bbbd514b786c27bfc13c2e075e0ecd3b279dab12aa80077b4b351c3501662bf2
RUN curl -fsSL --retry 5 -o /tmp/unifi.deb "${WEBRTC_PKGURL}" && \
    echo "${WEBRTC_PKGSHA256}  /tmp/unifi.deb" | sha256sum -c - && \
    dpkg-deb -x /tmp/unifi.deb /tmp/unifi && \
    mkdir -p /out && \
    cd /tmp/unifi/usr/lib/unifi/lib/native && \
    find . -name 'libubnt_webrtc_jni.so' -exec cp --parents {} /out/ \; && \
    find /out -type f && \
    rm -rf /tmp/unifi /tmp/unifi.deb

FROM ubuntu:26.04

LABEL maintainer="Jacob Alberty <jacob.alberty@foundigital.com>"

ARG DEBIAN_FRONTEND=noninteractive

# EXPERIMENTAL: 11.x is only published as a UniFi OS package (fw-update.ubnt.com, product
# "unifi"). The package is Architecture: all and the amd64/arm64 uploads are identical
# (same sha256), so this URL is used for every platform.
ARG PKGURL=https://fw-download.ubnt.com/data/unifi/6a2b-uos-deb13-amd64-11.0.104-37279-1-8369db7e-bc57-520b-b8be-fbdf9b734bda.deb

ENV BASEDIR=/usr/lib/unifi \
    DATADIR=/unifi/data \
    LOGDIR=/unifi/log \
    CERTDIR=/unifi/cert \
    RUNDIR=/unifi/run \
    ORUNDIR=/var/run/unifi \
    ODATADIR=/var/lib/unifi \
    OLOGDIR=/var/log/unifi \
    CERTNAME=cert.pem \
    CERT_PRIVATE_NAME=privkey.pem \
    CERT_IS_CHAIN=false \
    GOSU_VERSION=1.19 \
    BIND_PRIV=true \
    RUNAS_UID0=true \
    UNIFI_GID=999 \
    UNIFI_UID=999

# Install gosu
# https://github.com/tianon/gosu/blob/master/INSTALL.md
# This should be integrated with the main run because it duplicates a lot of the steps there
# but for now while shoehorning gosu in it is seperate
RUN set -eux; \
	apt-get update; \
	apt-get install -y gosu; \
	rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/unifi \
     /usr/local/unifi/init.d \
     /usr/unifi/init.d \
     /usr/local/docker
COPY docker-entrypoint.sh /usr/local/bin/
COPY docker-healthcheck.sh /usr/local/bin/
COPY docker-build.sh /usr/local/bin/
COPY uos-repack.sh uos-webui-patch.sh /usr/local/bin/
COPY functions /usr/unifi/functions
COPY import_cert /usr/unifi/init.d/
COPY pre_build /usr/local/docker/pre_build
RUN chmod +rx /usr/local/bin/docker-entrypoint.sh \
 && chmod +rx /usr/unifi/init.d/import_cert \
 && chmod +r  /usr/unifi/functions \
 && chmod +rx /usr/local/bin/docker-healthcheck.sh \
 && chmod +rx /usr/local/bin/docker-build.sh \
 && chmod -R +rx /usr/local/docker/pre_build

RUN set -ex \
 && mkdir -p /usr/share/man/man1/ \
 && groupadd -r unifi -g $UNIFI_GID \
 && useradd --no-log-init -r -u $UNIFI_UID -g $UNIFI_GID unifi \
 && bash /usr/local/bin/docker-build.sh "${PKGURL}"

COPY --from=webrtc --chown=unifi:unifi /out/ /usr/local/unifi/webrtc-native/
RUN set -e; \
    for so in $(cd /usr/local/unifi/webrtc-native && find . -type f); do \
        [ -e "${BASEDIR}/lib/native/${so}" ] || install -D -o unifi -g unifi -m 0644 \
            "/usr/local/unifi/webrtc-native/${so}" "${BASEDIR}/lib/native/${so}"; \
    done; \
    rm -rf /usr/local/unifi/webrtc-native

COPY --from=permset /out/permset /usr/local/bin/permset
RUN chown 0.0 /usr/local/bin/permset && \
    chmod +s /usr/local/bin/permset

RUN mkdir -p /unifi && chown unifi:unifi -R /unifi

# Apply any hotfixes that were included
COPY hotfixes /usr/local/unifi/hotfixes

RUN chmod +x /usr/local/unifi/hotfixes/* && run-parts /usr/local/unifi/hotfixes

VOLUME ["/unifi", "${RUNDIR}"]

EXPOSE 6789/tcp 8080/tcp 8443/tcp 8880/tcp 8843/tcp 3478/udp 10001/udp

WORKDIR /unifi

HEALTHCHECK --start-period=5m CMD /usr/local/bin/docker-healthcheck.sh || exit 1

# execute controller using JSVC like original debian package does
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

CMD ["unifi"]

# execute the conroller directly without using the service
#ENTRYPOINT ["/usr/bin/java", "-Xmx${JVM_MAX_HEAP_SIZE}", "-jar", "/usr/lib/unifi/lib/ace.jar"]
  # See issue #12 on github: probably want to consider how JSVC handled creating multiple processes, issuing the -stop instraction, etc. Not sure if the above ace.jar class gracefully handles TERM signals.
#CMD ["start"]
