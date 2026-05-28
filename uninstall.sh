#!/bin/bash
# =============================================================================
# CDPNI — DESINSTALADOR DO GATEWAY
# Remove todas as configurações e pacotes instalados pelo gateway-v37.x.sh
# Versão: 1.0 — Maio 2026
# Uso: bash desinstalar-gateway.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $*"; }
info()   { echo -e "${CYAN}[→]${NC} $*"; }
step()   { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }
remov()  { echo -e "${RED}[✘]${NC} Removido: $*"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Execute como root${NC}"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║    DESINSTALADOR DO GATEWAY — CDPNI          ║${NC}"
echo -e "${BOLD}${RED}║    Remove TUDO instalado pelo gateway-v37    ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}\n"

warn "Esta operação irá:"
echo "  • Parar e remover todos os serviços do gateway"
echo "  • Remover pacotes: squid, bind9, nftables, nginx, chrony, python3-venv"
echo "  • Apagar configurações em /etc/squid, /etc/bind, /etc/nftables"
echo "  • Apagar painel em /opt/gateway-panel e /var/www/gateway-wpad"
echo "  • Restaurar configurações de rede padrão"
echo ""
echo -en "${YELLOW}[?] Confirma a desinstalação completa? [s/N]: ${NC}"
read -r RESP
[[ "${RESP,,}" != "s" ]] && { echo "Cancelado."; exit 0; }

TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/gateway-backup-$TS"
mkdir -p "$BACKUP_DIR"
info "Backup das configurações em: $BACKUP_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step "1. Parando serviços"
# ─────────────────────────────────────────────────────────────────────────────
for svc in gateway-panel squid squid-openssl nginx bind9 named chrony chronyd nftables; do
    if systemctl is-active "$svc" &>/dev/null; then
        systemctl stop "$svc" 2>/dev/null && log "Parado: $svc" || warn "Falha ao parar: $svc"
    fi
    systemctl disable "$svc" 2>/dev/null || true
done

# ─────────────────────────────────────────────────────────────────────────────
step "2. Backup de configurações importantes"
# ─────────────────────────────────────────────────────────────────────────────
for f in \
    /etc/squid/squid.conf \
    /etc/squid/ips_totais.txt \
    /etc/squid/ips_parciais.txt \
    /etc/squid/ips_bloqueados.txt \
    /etc/squid/ips_excecao_horario.txt \
    /etc/squid/sites_liberados.txt \
    /etc/squid/sites_bloqueados.txt \
    /etc/squid/sites_bancos.txt \
    /etc/squid/sites_governo.txt \
    /etc/squid/sites_teams.txt \
    /etc/nftables/nat_1to1.txt \
    /etc/nftables/ips_externos_liberados.txt \
    /etc/nftables/ips_rede_wan.txt \
    /etc/bind/named.conf.local \
    /etc/bind/named.conf.options \
    /etc/gateway-panel.env \
    /etc/network/interfaces; do
    [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/" && log "Backup: $(basename $f)"
done
# Backup full dirs
[[ -d /etc/bind/zones  ]] && cp -r /etc/bind/zones  "$BACKUP_DIR/bind-zones"  && log "Backup: bind/zones"
[[ -d /etc/squid/ssl_cert ]] && cp -r /etc/squid/ssl_cert "$BACKUP_DIR/squid-ssl_cert" && log "Backup: squid CA"

# ─────────────────────────────────────────────────────────────────────────────
step "3. Removendo pacotes"
# ─────────────────────────────────────────────────────────────────────────────
PKGS=(
    squid squid-openssl squid-common
    nginx nginx-common nginx-full nginx-light
    bind9 bind9utils bind9-dnsutils dnsutils
    chrony
    nftables
    conntrack
    python3-venv python3-pam
    ipcalc
    fail2ban
)

for pkg in "${PKGS[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        apt-get remove -y --purge "$pkg" 2>/dev/null && remov "$pkg" || warn "Falha ao remover: $pkg"
    fi
done
apt-get autoremove -y --purge 2>/dev/null || true
log "Pacotes removidos"

# ─────────────────────────────────────────────────────────────────────────────
step "4. Removendo arquivos de configuração"
# ─────────────────────────────────────────────────────────────────────────────

# Serviço systemd do painel
rm -f /etc/systemd/system/gateway-panel.service
systemctl daemon-reload
remov "gateway-panel.service"

# Squid
rm -rf /etc/squid
rm -rf /var/log/squid
rm -rf /var/spool/squid
rm -rf /var/lib/squid
rm -f  /etc/cron.d/squid-schedule
rm -f  /etc/logrotate.d/squid-gateway
rm -f  /etc/tmpfiles.d/squid.conf
remov "/etc/squid /var/log/squid /var/spool/squid"

# BIND9 / DNS
rm -rf /etc/bind/zones
rm -f  /etc/bind/named.conf.local
rm -f  /etc/bind/named.conf.options
rm -f  /etc/bind/named.conf.root-hints
rm -f  /etc/bind/named.conf.default-zones
remov "/etc/bind (configurações do gateway)"

# nftables
rm -f  /etc/nftables.conf
rm -rf /etc/nftables
remov "/etc/nftables.conf e /etc/nftables/"

# Nginx / WPAD
rm -f  /etc/nginx/sites-enabled/gateway-wpad
rm -f  /etc/nginx/sites-available/gateway-wpad
rm -rf /var/www/gateway-wpad
remov "nginx gateway-wpad"

# Chrony
rm -f /etc/chrony/chrony.conf
remov "/etc/chrony/chrony.conf"

# Painel Flask
rm -rf /opt/gateway-panel
rm -f  /etc/gateway-panel.env
rm -f  /etc/gateway-panel.env.tmp
rm -f  /etc/sudoers.d/gateway-panel
rm -rf /var/log/gateway-panel
remov "/opt/gateway-panel"

# Scripts utilitários
rm -f /usr/local/bin/gateway-panel-senha.sh
rm -f /usr/local/bin/squid-force-block.sh
rm -f /usr/local/bin/squid-open-schedule.sh
rm -f /usr/local/bin/sync-gateway-ca.sh
rm -f /usr/local/bin/update-nat1to1.sh
remov "/usr/local/bin/gateway-*.sh"

# sysctl
rm -f /etc/sysctl.d/99-gateway.conf
sysctl --system &>/dev/null || true
remov "/etc/sysctl.d/99-gateway.conf"

# ─────────────────────────────────────────────────────────────────────────────
step "5. Restaurando configurações de rede"
# ─────────────────────────────────────────────────────────────────────────────

# Detectar interfaces
WAN_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
LAN_IF=$(ip link show | awk -F': ' '/^[0-9]+: e/{print $2}' | grep -v "$WAN_IF" | head -1)

warn "Interface WAN detectada: ${WAN_IF:-não detectada}"
warn "Interface LAN detectada: ${LAN_IF:-não detectada}"

# Remover interface de monitoramento se existir
rm -f /etc/network/interfaces.d/gateway-mon
ip link del dummy0 2>/dev/null || true

# Restaurar /etc/network/interfaces básico
if [[ -n "$WAN_IF" ]]; then
    cat > /etc/network/interfaces << NETEOF
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

# Interface WAN — edite conforme sua configuração
auto ${WAN_IF}
iface ${WAN_IF} inet dhcp
NETEOF
    log "interfaces restaurado para DHCP na $WAN_IF"
fi

# Restaurar resolv.conf para DNS público
cat > /etc/resolv.conf << RESEOF
nameserver 8.8.8.8
nameserver 1.1.1.1
RESEOF
log "resolv.conf restaurado"

# Restaurar ip_forward desativado
echo 0 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
sed -i 's/^net.ipv4.ip_forward=1/# net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || true

# Limpar regras de firewall residuais
if command -v nft &>/dev/null; then
    nft flush ruleset 2>/dev/null && log "nftables: regras limpas" || true
fi
log "Rede restaurada"

# ─────────────────────────────────────────────────────────────────────────────
step "6. Limpeza final"
# ─────────────────────────────────────────────────────────────────────────────
apt-get clean 2>/dev/null || true
systemctl daemon-reload

# Verificar o que ainda está instalado
echo ""
info "Verificando serviços restantes:"
for svc in squid nginx bind9 named chrony nftables gateway-panel; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "não instalado")
    echo "  $svc: $STATUS"
done

# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Desinstalação concluída!                    ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Backup das configurações salvo em:${NC}"
echo -e "  ${CYAN}$BACKUP_DIR${NC}"
echo ""
echo -e "  ${YELLOW}Para restaurar a rede manualmente edite:${NC}"
echo -e "  ${CYAN}nano /etc/network/interfaces${NC}"
echo ""
echo -e "  ${YELLOW}Reinicie o servidor para garantir limpeza completa:${NC}"
echo -e "  ${CYAN}reboot${NC}"
echo ""