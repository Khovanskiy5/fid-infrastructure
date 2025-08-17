FROM php:7.4-fpm-alpine

RUN set -eux; \
    apk add --no-cache bash curl tzdata; \
    docker-php-ext-install -j$(nproc) opcache

WORKDIR /var/www/html

# php.ini and www.conf are mounted from host via docker-compose

HEALTHCHECK --interval=5s --timeout=3s --retries=3 CMD ps | grep -q '[p]hp-fpm: master process'
