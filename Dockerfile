FROM ghcr.io/osgeo/gdal:ubuntu-small-3.7.0 as builder
LABEL maintainer Camptocamp "info@camptocamp.com"
SHELL ["/bin/bash", "-o", "pipefail", "-cux"]

ARG APACHE_VERSION=2.4.57
ARG APR_VERSION=1.7.4
ARG APR_UTIL_VERSION=1.6.3
ARG FCGID_VERSION=2.3.9
ARG APACHE_BUILD_DIR=/src/httpd

RUN --mount=type=cache,target=/var/cache,sharing=locked \
    --mount=type=cache,target=/root/.cache \
    apt-get update \
    && apt-get upgrade --assume-yes \
    && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes --no-install-recommends bison \
        libpcre3-dev libapr1-dev libaprutil1-dev build-essential libssl-dev libexpat-dev lbzip2 \
        flex python3-lxml libfribidi-dev swig \
        cmake librsvg2-dev colordiff libpq-dev libpng-dev libjpeg-dev libgif-dev libgeos-dev libgd-dev \
        libfreetype6-dev libfcgi-dev libcurl4-gnutls-dev libcairo2-dev libxml2-dev \
        libxslt1-dev python3-dev php-dev libexempi-dev lcov lftp ninja-build git curl \
        clang libprotobuf-c-dev protobuf-c-compiler libharfbuzz-dev libcairo2-dev librsvg2-dev \
    && ln -s /usr/local/lib/libproj.so.* /usr/local/lib/libproj.so

RUN mkdir -p ${APACHE_BUILD_DIR} \
    && cd ${APACHE_BUILD_DIR} \
    && curl -sSLo /src/httpd/httpd.tar.bz2 https://dlcdn.apache.org/httpd/httpd-${APACHE_VERSION}.tar.bz2 \
    && tar -xf httpd.tar.bz2 \
    && curl -sSLo /src/httpd/apr.tar.bz2 https://dlcdn.apache.org/apr/apr-${APR_VERSION}.tar.bz2 \
    && curl -sSLo /src/httpd/apr-util.tar.bz2 https://dlcdn.apache.org/apr/apr-util-${APR_UTIL_VERSION}.tar.bz2 \
    && curl -sSLo /src/httpd/fcgid.tar.bz2 https://dlcdn.apache.org/httpd/mod_fcgid/mod_fcgid-${FCGID_VERSION}.tar.bz2 \
    && tar -xf apr.tar.bz2 \
    && tar -xf apr-util.tar.bz2 \
    && tar -xf fcgid.tar.bz2 \
    && mv apr-${APR_VERSION} ${APACHE_BUILD_DIR}/httpd-${APACHE_VERSION}/srclib/apr \
    && mv apr-util-${APR_UTIL_VERSION} ${APACHE_BUILD_DIR}/httpd-${APACHE_VERSION}/srclib/apr-util \
    && cd httpd-${APACHE_VERSION} \
    && mkdir /usr/local/apache \
    && ./configure \
      --with-included-apr --with-included-apr-util \
      -prefix=/usr/local/apache --enable-fcgid --enable-headers --enable-status \
      --disable-auth-basic --disable-authn-file --disable-authn-core --disable-authz-user --disable-autoindex --disable-dir \
    && make && make install \
    && cd ${APACHE_BUILD_DIR}/mod_fcgid-${FCGID_VERSION} \
    && APXS=/usr/local/apache/bin/apxs ./configure.apxs \
    && make && make install

ARG MAPSERVER_BRANCH
ARG MAPSERVER_REPO=https://github.com/mapserver/mapserver

RUN git clone ${MAPSERVER_REPO} --branch=${MAPSERVER_BRANCH} --depth=100 /src/mapserver

COPY checkout_release /tmp
RUN cd /src/mapserver \
    && /tmp/checkout_release ${MAPSERVER_BRANCH}

COPY instantclient /tmp/instantclient

ARG WITH_ORACLE=OFF

RUN --mount=type=cache,target=/var/cache,sharing=locked \
    --mount=type=cache,target=/root/.cache \
    (if test "${WITH_ORACLE}" = "ON"; then \
       apt-get update && \
       apt-get install --assume-yes --no-install-recommends \
       libarchive-tools libaio-dev && \
       mkdir -p /usr/local/lib && \
       cd /usr/local/lib && \
       (for i in /tmp/instantclient/*.zip; do bsdtar --strip-components=1 -xvf "$i"; done) && \
       ln -s libnnz19.so /usr/local/lib/libnnz18.so; \
     fi )

WORKDIR /src/mapserver/build
RUN if test "${WITH_ORACLE}" = "ON"; then \
      export ORACLE_HOME=/usr/local/lib; \
    fi; \
    cmake .. \
    -GNinja \
    -DCMAKE_C_FLAGS="-O2 -DPROJ_RENAME_SYMBOLS" \
    -DCMAKE_CXX_FLAGS="-O2 -DPROJ_RENAME_SYMBOLS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DWITH_CLIENT_WMS=1 \
    -DWITH_CLIENT_WFS=1 \
    -DWITH_OGCAPI=1 \
    -DWITH_KML=1 \
    -DWITH_SOS=1 \
    -DWITH_XMLMAPFILE=1 \
    -DWITH_POINT_Z_M=1 \
    -DWITH_CAIRO=1 \
    -DWITH_RSVG=1 \
    -DUSE_PROJ=1 \
    -DUSE_WFS_SVR=1 \
    -DUSE_OGCAPI_SVR=1 \
    -DWITH_ORACLESPATIAL=${WITH_ORACLE}

RUN ninja install \
    && if test "${WITH_ORACLE}" = "ON"; then rm -rf /usr/local/lib/sdk; fi

FROM ghcr.io/osgeo/gdal:ubuntu-small-3.7.0 as runner
LABEL maintainer Camptocamp "info@camptocamp.com"
SHELL ["/bin/bash", "-o", "pipefail", "-cux"]

# Let's copy a few of the settings from /etc/init.d/apache2
ENV APACHE_CONFDIR=/usr/local/apache/conf \
    # And then a few more from $APACHE_CONFDIR/envvars itself
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    MS_MAP_PATTERN=^\\/etc\\/mapserver\\/([^\\.][-_A-Za-z0-9\\.]+\\/{1})*([-_A-Za-z0-9\\.]+\\.map)$

COPY --from=builder /usr/local/apache /usr/local/apache/

RUN --mount=type=cache,target=/var/cache,sharing=locked \
    --mount=type=cache,target=/root/.cache \
    printf "deb http://security.ubuntu.com/ubuntu/ kinetic main restricted universe\ndeb http://security.ubuntu.com/ubuntu/ kinetic-security main restricted universe" > /etc/apt/sources.list.d/backports.list \
    && printf "Package: *\nPin: release n=jammy\nPin-Priority: -10\n\nPackage: *apache2*\nPin: release n=kinetic\nPin-Priority: 500" > /etc/apt/preferences.d/apache.pref \
    && apt-get update \
    && apt-get upgrade --assume-yes \
    && apt-get install --assume-yes --no-install-recommends ca-certificates \
        libfribidi0 librsvg2-2 libpng16-16 libgif7 libfcgi0ldbl \
        libxslt1.1 libprotobuf-c1 libaio1 glibc-tools

RUN mkdir --parent /etc/mapserver \
    && chmod o+w /usr/local/apache/logs \
    && find "$APACHE_CONFDIR" -type f -exec sed -ri ' \
    s!^(\s*CustomLog)\s+\S+!\1 /proc/self/fd/1!g; \
    s!^(\s*ErrorLog)\s+\S+!\1 /proc/self/fd/2!g; \
    ' '{}' ';' \
    && sed -ri 's!LogFormat "(.*)" combined!LogFormat "%{us}T %{X-Request-Id}i \1" combined!g' $APACHE_CONFDIR/httpd.conf \
    && echo 'ErrorLogFormat "%{X-Request-Id}i [%l] [pid %P] %M"' >> $APACHE_CONFDIR/httpd.conf \
    && sed -i -e 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' $APACHE_CONFDIR/httpd.conf \
    && sed -i -e 's/Listen 80$/Listen 8080/' $APACHE_CONFDIR/httpd.conf \
    && echo 'Include /etc/apache2/conf-enabled/mapserver.conf' >> $APACHE_CONFDIR/httpd.conf

EXPOSE 8080

COPY --from=builder /usr/local/bin /usr/local/bin/
COPY --from=builder /usr/local/lib /usr/local/lib/
COPY --from=builder /usr/local/share/mapserver /usr/local/share/mapserver/
COPY --from=builder /src/mapserver/share/ogcapi/templates/html-bootstrap4 /usr/local/share/mapserver/ogcapi/templates/html-bootstrap4/

COPY runtime /

RUN ldconfig

ENV MS_DEBUGLEVEL=0 \
    MS_ERRORFILE=stderr \
    MAPSERVER_CONFIG_FILE=/etc/mapserver.conf \
    MAX_REQUESTS_PER_PROCESS=1000 \
    MIN_PROCESSES=1 \
    MAX_PROCESSES=5 \
    BUSY_TIMEOUT=300 \
    IDLE_TIMEOUT=300 \
    IO_TIMEOUT=40 \
    APACHE_LIMIT_REQUEST_LINE=8190 \
    GET_ENV=env

CMD ["/usr/local/bin/start-server"]

WORKDIR /etc/mapserver
