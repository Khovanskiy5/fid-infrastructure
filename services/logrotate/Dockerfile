FROM alpine:3.19
RUN apk add --no-cache logrotate busybox-suid tzdata bash \
    && mkdir -p /etc/logrotate.d /var/log/infra /var/lib \
    && echo '*/15 * * * * /usr/sbin/logrotate -s /var/lib/logrotate.status /etc/logrotate.conf' > /etc/crontabs/root

CMD ["crond", "-f", "-l", "8"]
