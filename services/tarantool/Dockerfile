FROM tarantool/tarantool:2.10.5-centos7

# Установка репозитория Tarantool -- Требуется для сборки зависимостей cartridge и так далее
COPY installer.sh /tmp/installer.sh
RUN VER=2 bash /tmp/installer.sh && rm -f /tmp/installer.sh

# Базовые репозитории и cartridge-cli
RUN set -eux && \
    sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-* && \
    sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* && \
    yum -y install epel-release curl ca-certificates cartridge-cli && \
    yum makecache -y

# Инструменты сборки + zsh (LuaRocks устанавливаем отдельно из исходников)
RUN set -eux && \
    yum -y install \
        gcc gcc-c++ git make cmake cmake3 unzip curl wget \
        python python-pip nodejs \
        libsodium-devel lua lua-devel zlib-devel readline-devel ncurses-devel openssl-devel libunwind-devel libicu-devel \
        gtk3 xorg-x11-server-Xvfb libXScrnSaver GConf2 alsa-lib lsof \
        zsh shadow-utils && \
    ln -sf /usr/bin/cmake3 /usr/bin/cmake && \
    yum clean all && rm -rf /var/cache /root/.cache

# Установка LuaRocks 3.12.2 из исходников
RUN set -eux && \
    curl -fSL https://luarocks.github.io/luarocks/releases/luarocks-3.12.2.tar.gz -o /tmp/luarocks-3.12.2.tar.gz && \
    tar -xzf /tmp/luarocks-3.12.2.tar.gz -C /tmp && \
    cd /tmp/luarocks-3.12.2 && \
    ./configure --with-lua=/usr --with-lua-include=/usr/include --prefix=/usr/local && \
    make && make install && \
    ln -sf /usr/local/bin/luarocks /usr/bin/luarocks && \
    ln -sf /usr/local/bin/luarocks-admin /usr/bin/luarocks-admin && \
    rm -rf /tmp/luarocks-3.12.2 /tmp/luarocks-3.12.2.tar.gz && \
    mkdir -p /usr/local/etc/luarocks && \
    printf 'rocks_servers = { "https://rocks.tarantool.org", "https://luarocks.org" }\nrocks_provided = { tarantool = "2.10.5" }\n' > /usr/local/etc/luarocks/config-5.1.lua

RUN yum install netcat -y

WORKDIR /opt/tarantool/voting/

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
