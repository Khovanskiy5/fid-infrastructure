#!/usr/bin/env bash

# Скрипт установки репозитория Tarantool с учетом НОВОЙ политики релизов
# ---------------------------------------------------------------
# Кратко о политике (2023+):
# - Репозиторий 'live' для series-2 БОЛЬШЕ НЕ ДОСТУПЕН.
# - Для series-2 используйте только 'release' (например, 2.10 LTS).
# - Начиная с series-3 используются статические сборки и единые репозитории
#   для всех deb- и rpm-систем:
#     deb:  https://download.tarantool.org/tarantool/release/series-3/linux-deb static main
#     rpm:  https://download.tarantool.org/tarantool/release/series-3/linux-rpm/static/$ARCH/
# - Репозиторий modules подключается отдельно (для deb: modules/<os>/<dist>; для rpm: modules/<os>/<dist>/<arch>/).
#
# Использование:
#   sudo bash installer.sh                # Установит репозиторий Tarantool 3 (release, static)
#   sudo VER=2 bash installer.sh          # Установит репозиторий Tarantool 2 (release)
#   sudo VER=3 bash installer.sh          # Установит репозиторий Tarantool 3 (release, static)
#
# Переменные окружения (необязательно):
#   VER   — основная версия/серия (2 или 3). По умолчанию: 3.
#   GC64  — для x86_64 и series-2: если true, репозиторий series-2-gc64 (опционально).
#
# Поддерживаемые системы:
#   - Debian (buster, bullseye, bookworm) / Ubuntu (bionic, focal, jammy, noble)
#   - CentOS 7, Alma/RHEL 8+, Amazon Linux 2, Fedora 34+
#
# Примечание для Ubuntu/Debian: используется современная схема signed-by (без apt-key).
set -euo pipefail

# --------------------- Вспомогательные функции ---------------------
err() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[INFO] $*"; }

unsupported_os() { err "К сожалению, ваша ОС пока не поддерживается этим скриптом."; }

# Определение ОС и дистрибутива
OS=""; DIST=""; ARCH="$(uname -m)";

detect_os() {
  if [ -e /etc/os-release ]; then
    . /etc/os-release
    local id_like=${ID_LIKE:-}

    case "$ID" in
      ubuntu)
        OS="ubuntu"
        DIST="${UBUNTU_CODENAME:-}";
        if [ -z "$DIST" ]; then
          case "$VERSION_ID" in
            18.04) DIST=bionic;; 20.04) DIST=focal;; 22.04) DIST=jammy;; 24.04) DIST=noble;;
            *) unsupported_os;;
          esac
        fi
        ;;
      debian|devuan)
        OS="debian"
        DIST="${VERSION_CODENAME:-}"
        if [ -z "$DIST" ]; then
          # fallback по /etc/debian_version
          if grep -q bullseye /etc/debian_version 2>/dev/null; then DIST=bullseye; fi
          if grep -q bookworm /etc/debian_version 2>/dev/null; then DIST=bookworm; fi
          [ -z "$DIST" ] && unsupported_os
        fi
        ;;
      amzn)
        OS="amzn"
        DIST="$VERSION_ID" # 2
        [ "$DIST" != "2" ] && unsupported_os
        ;;
      rhel|almalinux|rocky)
        OS="rhel"
        DIST="${VERSION_ID%%.*}" # 8/9
        ;;
      centos)
        OS="centos"
        DIST="${VERSION_ID%%.*}"
        ;;
      fedora)
        OS="fedora"
        DIST="$VERSION_ID"
        ;;
      *)
        # Попытка нормализовать Ubuntu-подобные
        if [ "${id_like:-}" = "ubuntu" ]; then
          OS="ubuntu"; DIST="${UBUNTU_CODENAME:-}"; [ -z "$DIST" ] && unsupported_os
        else
          unsupported_os
        fi
        ;;
    esac
  else
    unsupported_os
  fi

  OS=${OS// /}; DIST=${DIST// /}
  log "Обнаружена система: ${OS}/${DIST} (${ARCH})"
}

# Определение версии Tarantool
setup_ver() {
  VER="${VER:-3}"
  if [ -z "$VER" ]; then VER=3; fi
  case "$VER" in
    2|3) :;;
    *) err "Неподдерживаемая серия VER='$VER'. Разрешены 2 или 3.";;
  esac
}

# --------------------- Установка для APT ---------------------
install_apt_repo() {
  export DEBIAN_FRONTEND=noninteractive

  # Пакеты для https и gpg
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg apt-transport-https >/dev/null

  local base="https://download.tarantool.org/tarantool"
  local key_main_url="$base/release/series-${VER}/gpgkey"
  local key_modules_url="$base/modules/gpgkey"
  local key_main="/usr/share/keyrings/tarantool-${VER}.gpg"
  local key_modules="/usr/share/keyrings/tarantool-modules.gpg"

  curl -fsSL "$key_main_url"   | gpg --dearmor -o "$key_main"
  curl -fsSL "$key_modules_url" | gpg --dearmor -o "$key_modules"

  local list="/etc/apt/sources.list.d/tarantool_series_${VER}.list"
  rm -f /etc/apt/sources.list.d/*tarantool*.list || true

  local dist_path dist_ver modules_os modules_dist
  if [ "$VER" -ge 3 ]; then
    dist_path="release/series-${VER}/linux-deb"
    dist_ver="static"
    modules_os="$OS"; modules_dist="$DIST"
  else
    # series-2: репозитории на уровне ОС и кода нейма
    local gc64_suffix=""
    if [ "${ARCH}" = "x86_64" ] && [ "${GC64:-false}" = "true" ]; then
      log "GC64 включен"
      gc64_suffix="-gc64"
    fi
    dist_path="release/series-${VER}${gc64_suffix}/${OS}"
    dist_ver="$DIST"
    modules_os="$OS"; modules_dist="$DIST"
  fi

  {
    echo "deb [signed-by=${key_main}] ${base}/${dist_path}/ ${dist_ver} main"
    echo "deb-src [signed-by=${key_main}] ${base}/${dist_path}/ ${dist_ver} main"
    echo "deb [signed-by=${key_modules}] ${base}/modules/${modules_os}/ ${modules_dist} main"
    echo "deb-src [signed-by=${key_modules}] ${base}/modules/${modules_os}/ ${modules_dist} main"
  } > "$list"

  mkdir -p /etc/apt/preferences.d/
  cat > /etc/apt/preferences.d/tarantool <<'EOF'
Package: tarantool
Pin: origin download.tarantool.org
Pin-Priority: 1001

Package: tarantool-common
Pin: origin download.tarantool.org
Pin-Priority: 1001

Package: tarantool-dev
Pin: origin download.tarantool.org
Pin-Priority: 1001
EOF

  apt-get update -qq
  log "Репозиторий Tarantool ${VER} настроен. Можно устанавливать пакеты: 'apt-get install tarantool'."
}

# --------------------- Установка для YUM/DNF ---------------------
install_yum_dnf_repo() {
  local base="https://download.tarantool.org/tarantool"
  local repo="/etc/yum.repos.d/tarantool_series_${VER}.repo"
  rm -f /etc/yum.repos.d/*tarantool*.repo || true

  local os_code dist_code dist_ver source_enabled modules_enabled
  local os_name arch_rpm
  arch_rpm="${ARCH}"

  case "$OS" in
    centos|rhel)
      os_name="EnterpriseLinux"; os_code="el"; modules_enabled=1; source_enabled=1;
      dist_code="$os_code";
      dist_ver="${DIST}"
      ;;
    amzn)
      os_name="AmazonLinux"; os_code="el"; modules_enabled=1; source_enabled=1;
      dist_code="$os_code"; dist_ver="7" # для репозитория series-2/3 используется el7 совместимость
      ;;
    fedora)
      os_name="Fedora"; os_code="fedora"; modules_enabled=1; source_enabled=1;
      dist_code="$os_code"; dist_ver="${DIST}"
      ;;
    *) unsupported_os;;
  esac

  local repo_ver_path
  if [ "$VER" -ge 3 ]; then
    repo_ver_path="release/series-${VER}"
    dist_code="linux-rpm"; dist_ver="static"; source_enabled=0
  else
    local gc64_suffix=""
    if [ "${ARCH}" = "x86_64" ] && [ "${GC64:-false}" = "true" ]; then
      log "GC64 включен"
      gc64_suffix="-gc64"
    fi
    repo_ver_path="release/series-${VER}${gc64_suffix}"
  fi

  cat > "$repo" <<EOF
[tarantool_series_${VER}]
name=${os_name}-${DIST} - Tarantool
baseurl=${base}/${repo_ver_path}/${dist_code}/${dist_ver}/${arch_rpm}/
gpgkey=${base}/${repo_ver_path}/gpgkey
repo_gpgcheck=1
gpgcheck=0
enabled=1
priority=1

[tarantool_series_${VER}-source]
name=${os_name}-${DIST} - Tarantool Sources
baseurl=${base}/${repo_ver_path}/${dist_code}/${dist_ver}/SRPMS
gpgkey=${base}/${repo_ver_path}/gpgkey
repo_gpgcheck=1
gpgcheck=0
enabled=${source_enabled}
priority=1

[tarantool_modules]
name=${os_name}-${DIST} - Tarantool Modules
baseurl=${base}/modules/${os_code}/${DIST}/${arch_rpm}/
gpgkey=${base}/modules/gpgkey
repo_gpgcheck=1
gpgcheck=0
enabled=${modules_enabled}
priority=1

[tarantool_modules-source]
name=${os_name}-${DIST} - Tarantool Modules Sources
baseurl=${base}/modules/${os_code}/${DIST}/SRPMS
gpgkey=${base}/modules/gpgkey
repo_gpgcheck=1
gpgcheck=0
enabled=${modules_enabled}
priority=1
EOF

  # Обновление метаданных (yum/dnf)
  if command -v dnf >/dev/null 2>&1; then
    dnf -q makecache -y --disablerepo='*' --enablerepo="tarantool_series_${VER}" --enablerepo="tarantool_modules" || true
  else
    yum makecache -y --disablerepo='*' --enablerepo="tarantool_series_${VER}" --enablerepo="tarantool_modules" --enablerepo='epel' || true
  fi

  log "Репозиторий Tarantool ${VER} настроен. Можно устанавливать пакеты: 'yum install tarantool' или 'dnf install tarantool'."
}

# --------------------- Главная логика ---------------------
main() {
  detect_os
  setup_ver

  case "$OS" in
    ubuntu|debian) install_apt_repo ;;
    centos|rhel|amzn|fedora) install_yum_dnf_repo ;;
    *) unsupported_os ;;
  esac

  log "Готово. Напоминание: 'live' репозитории для series-2 недоступны. Используйте 'release'."
}

main "$@"
