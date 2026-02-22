#!/bin/bash
# TITLE: Установить TrafficGuard
# SKYNET_HIDDEN: false
#
# Устанавливает TrafficGuard на удаленном сервере.
#

# --- Стандартные хелперы для плагинов Skynet ---
set -e
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m';
info() { echo -e "${C_RESET}[i] $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
err()  { echo -e "${C_RED}[✗] $*${C_RESET}"; exit 1; }
# --- Конец хелперов ---

if [[ $EUID -ne 0 ]]; then
    err "Этот плагин должен выполняться от имени root."
fi

info "Устанавливаю TrafficGuard..."

if ! command -v curl &>/dev/null; then
    info "curl не найден, устанавливаю..."
    apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null
fi

if curl -fsSL https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh | bash; then
    ok "TrafficGuard успешно установлен."
else
    err "Ошибка при установке TrafficGuard."
fi

exit 0
