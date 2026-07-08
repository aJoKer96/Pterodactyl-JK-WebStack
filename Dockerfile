FROM debian:13-slim

ARG PHPMYADMIN_VERSION=5.2.3
ARG PHPMYADMIN_SHA256=12ba1c425fa4071abbd4e7668c9ebdeac0b0755a467a6d6d5026122bb47c102b

ENV DEBIAN_FRONTEND=noninteractive \
    USER=container \
    HOME=/home/container \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN set -eux; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod +x /usr/sbin/policy-rc.d; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        apache2 \
        ca-certificates \
        curl \
        gettext-base \
        libapache2-mod-php \
        mariadb-client \
        mariadb-server \
        openssl \
        php \
        php-bcmath \
        php-curl \
        php-gd \
        php-mbstring \
        php-mysql \
        php-xml \
        php-zip \
        tar; \
    rm -f /usr/sbin/policy-rc.d; \
    a2dismod mpm_event || true; \
    a2enmod mpm_prefork rewrite headers expires; \
    useradd --create-home --home-dir /home/container --shell /bin/bash container; \
    mkdir -p /opt/webstack/phpmyadmin /opt/webstack/templates; \
    curl -fsSL "https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.gz" -o /tmp/phpmyadmin.tar.gz; \
    echo "${PHPMYADMIN_SHA256}  /tmp/phpmyadmin.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/phpmyadmin.tar.gz --strip-components=1 -C /opt/webstack/phpmyadmin; \
    rm -f /tmp/phpmyadmin.tar.gz; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/lib/mysql/* /var/log/apache2/* /var/log/mysql/*

COPY docker/entrypoint.sh /opt/webstack/entrypoint.sh
COPY docker/start.sh /opt/webstack/start.sh
COPY docker/templates/apache2.conf.template /opt/webstack/templates/apache2.conf.template
COPY docker/templates/my.cnf /opt/webstack/templates/my.cnf
COPY docker/templates/phpmyadmin-config.inc.php /opt/webstack/phpmyadmin/config.inc.php

RUN set -eux; \
    chmod 0755 /opt/webstack/entrypoint.sh /opt/webstack/start.sh; \
    chown -R root:root /opt/webstack; \
    chown -R container:container /home/container

USER container
WORKDIR /home/container

CMD ["/bin/bash", "/opt/webstack/entrypoint.sh"]
