ok "PAM configurado para autenticação via usuário Linux"

#!/bin/bash
# =============================================================================
# GATEWAY CDPNI — v1.0
# Debian 13 | NAT 1:1 | BIND9 | nftables | Squid SSL Bump | Chrony
# Execute como root: sudo bash gw-v1.sh
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
IFS=$'\n\t'
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }
hdr()  { echo -e "\n${BLD}${CYN}══════════════════════════════════════════════${NC}";
         echo -e "${BLD}${CYN}  $*${NC}";
         echo -e "${BLD}${CYN}══════════════════════════════════════════════${NC}"; }
[[ $EUID -ne 0 ]] && { err "Execute como root: sudo bash $0"; exit 1; }

# =============================================================================
# PASSO 0 — DETECÇÃO AUTOMÁTICA DE REDE
# =============================================================================
hdr "0. DETECÇÃO AUTOMÁTICA DE REDE"

# Inicializar todas as variáveis globais
WAN_IFACE="" LAN_IFACE="" WAN_IP="" LAN_IP="" GW_IP=""
WAN_MODE="static" LAN_MODE="static"
NET_INT="192.168.0.0/24"
NET_EXT="10.14.29.0/24"

detect_and_confirm() {
    # ── Coletar interfaces (exceto loopback e interfaces virtuais) ────────────
    local ifaces=()
    mapfile -t ifaces < <(
        ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^lo$|^docker|^br-|^veth|^virbr'
    ) 2>/dev/null || true

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        err "Nenhuma interface de rede detectada. Verifique: ip link show"
        exit 1
    fi

    # ── Detectar WAN e LAN automaticamente por faixa de IP ───────────────────
    local auto_wan="" auto_wan_ip="" auto_wan_cidr=""
    local auto_lan="" auto_lan_ip="" auto_lan_cidr=""
    local auto_gw=""

    for iface in "${ifaces[@]}"; do
        local cidr ip4
        cidr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        ip4="${cidr%%/*}"
        [[ -z "$ip4" ]] && continue
        if [[ "$ip4" == 192.168.* ]]; then
            auto_lan="$iface"; auto_lan_ip="$ip4"; auto_lan_cidr="$cidr"
        elif [[ "$ip4" != 127.* ]]; then
            auto_wan="$iface"; auto_wan_ip="$ip4"; auto_wan_cidr="$cidr"
        fi
    done

    # Gateway: rota default
    auto_gw=$(ip route show 2>/dev/null | awk '/^default/{print $3}' | head -1)

    # LAN sem IP (DOWN): usar segunda interface
    if [[ -z "$auto_lan" ]]; then
        for iface in "${ifaces[@]}"; do
            [[ "$iface" == "$auto_wan" ]] && continue
            auto_lan="$iface"; auto_lan_ip="(sem ip — DOWN)"; break
        done
    fi

    # Sub-rede WAN calculada pelo CIDR detectado
    local auto_net_wan=""
    if [[ -n "$auto_wan_cidr" ]]; then
        local wan_base; wan_base=$(echo "$auto_wan_ip" | cut -d. -f1-3)
        auto_net_wan="${wan_base}.0/${auto_wan_cidr##*/}"
    fi

    # Detectar se WAN está em DHCP
    local auto_wan_mode="static"
    ip route show dev "$auto_wan" 2>/dev/null | grep -q "proto dhcp" && auto_wan_mode="dhcp"

    # ── Exibir tabela de interfaces ───────────────────────────────────────────
    echo ""
    printf "  ${BLD}%-14s %-19s %-18s %-8s %s${NC}
" "Interface" "IP/Máscara" "MAC" "Estado" "Função"
    echo "  ──────────────────────────────────────────────────────────────────────"
    for iface in "${ifaces[@]}"; do
        local cidr mac state fn
        cidr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        mac=$(ip link show "$iface" 2>/dev/null | awk '/ether/{print $2}')
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "?")
        fn=""
        [[ "$iface" == "$auto_wan" ]] && fn="${GRN}← WAN${NC}"
        [[ "$iface" == "$auto_lan" ]] && fn="${CYN}← LAN${NC}"
        printf "  %-14s %-19s %-18s %-8s " "$iface" "${cidr:-(sem ip)}" "${mac:-(?)}" "$state"
        echo -e "$fn"
    done

    # ── Exibir configuração detectada ────────────────────────────────────────
    echo ""
    echo -e "  ${BLD}${CYN}Configuração detectada automaticamente:${NC}"
    echo ""
    printf "  ${GRN}  %-14s${NC} %-18s %s
" "WAN" "${auto_wan:-(não detectada)}" "${auto_wan_ip:-(sem ip)}"
    printf "  ${GRN}  %-14s${NC} %-18s %s
" "Gateway" "" "${auto_gw:-(não detectado)}"
    printf "  ${CYN}  %-14s${NC} %-18s %s
" "LAN" "${auto_lan:-(não detectada)}" "192.168.0.1 (fixo)"
    printf "  ${CYN}  %-14s${NC} %-18s %s
" "Rede WAN" "" "${auto_net_wan:-(calculando...)}"
    echo ""

    # ── Confirmação das interfaces ───────────────────────────────────────────
    echo -e "  ${BLD}Pressione ENTER para confirmar ou 'n' para editar manualmente:${NC}"
    echo -ne "  Confirmar? [ENTER/n]: "
    local resp; read -r resp

    if [[ -n "$resp" && "${resp,,}" != "s" && "${resp,,}" != "y" ]]; then
        echo ""
        warn "Modo manual — selecione as interfaces:"
        local n=1
        for iface in "${ifaces[@]}"; do
            local cidr
            cidr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
            printf "    ${BLD}[%d]${NC} %-12s  %s
" "$n" "$iface" "${cidr:-(sem ip)}"
            ((n++))
        done
        echo ""
        local _p
        echo -ne "${YLW}  Interface WAN [padrão: ${auto_wan:-enp0s3}]: ${NC}"
        read -r _p; _p="${_p:-${auto_wan:-enp0s3}}"
        [[ "$_p" =~ ^[0-9]+$ ]] && auto_wan="${ifaces[$((_p-1))]:-$_p}" || auto_wan="$_p"
        echo -ne "${YLW}  Interface LAN [padrão: ${auto_lan:-enp0s8}]: ${NC}"
        read -r _p; _p="${_p:-${auto_lan:-enp0s8}}"
        [[ "$_p" =~ ^[0-9]+$ ]] && auto_lan="${ifaces[$((_p-1))]:-$_p}" || auto_lan="$_p"
    fi

    WAN_IFACE="$auto_wan"
    LAN_IFACE="$auto_lan"
    [[ -n "$auto_net_wan" ]] && NET_EXT="$auto_net_wan"

    # ── Validação ────────────────────────────────────────────────────────────
    if [[ -z "$WAN_IFACE" || -z "$LAN_IFACE" ]]; then
        err "Interfaces não definidas. Abortando."; exit 1
    fi
    if [[ "$WAN_IFACE" == "$LAN_IFACE" ]]; then
        err "WAN e LAN são a mesma interface ($WAN_IFACE). Abortando."; exit 1
    fi

    # ── WAN: DHCP ou estático ────────────────────────────────────────────────
    echo ""
    hdr "0b. ENDEREÇAMENTO — WAN ($WAN_IFACE)"
    local wan_dhcp_hint=""
    [[ "$auto_wan_mode" == "dhcp" ]] && wan_dhcp_hint=" ${YLW}(detectado: DHCP)${NC}"
    echo -e "  IP atual: ${BLD}${auto_wan_ip:-(sem ip)}${NC}${wan_dhcp_hint}"
    echo ""
    echo -e "  ${BLD}[1]${NC} ${GRN}DHCP${NC}     — IP obtido automaticamente do roteador"
    echo -e "  ${BLD}[2]${NC} ${CYN}Estático${NC} — IP fixo configurado manualmente"
    echo ""
    local wan_default; [[ "$auto_wan_mode" == "dhcp" ]] && wan_default=1 || wan_default=2
    echo -ne "  ${YLW}Escolha [1/2, padrão: $wan_default]: ${NC}"
    local wan_choice; read -r wan_choice; wan_choice="${wan_choice:-$wan_default}"

    if [[ "$wan_choice" == "1" ]]; then
        WAN_MODE="dhcp"
        WAN_IP="${auto_wan_ip:-dhcp}"
        GW_IP="${auto_gw:-}"
        ok "WAN: $WAN_IFACE — DHCP"
    else
        WAN_MODE="static"
        echo ""
        echo -ne "  ${YLW}  IP WAN     [padrão: ${auto_wan_ip:-10.14.29.1}]: ${NC}"
        read -r WAN_IP; WAN_IP="${WAN_IP:-${auto_wan_ip:-10.14.29.1}}"
        echo -ne "  ${YLW}  Máscara    [padrão: /24]: /${NC}"
        local wan_prefix; read -r wan_prefix; wan_prefix="${wan_prefix:-24}"
        local wan_base; wan_base=$(echo "$WAN_IP" | cut -d. -f1-3)
        NET_EXT="${wan_base}.0/${wan_prefix}"
        echo -ne "  ${YLW}  Gateway    [padrão: ${auto_gw:-10.14.29.1}]: ${NC}"
        read -r GW_IP; GW_IP="${GW_IP:-${auto_gw:-10.14.29.1}}"
        ok "WAN: $WAN_IFACE — estático | $WAN_IP/$wan_prefix | GW: $GW_IP"
    fi

    # ── LAN: DHCP ou estático ────────────────────────────────────────────────
    echo ""
    hdr "0c. ENDEREÇAMENTO — LAN ($LAN_IFACE)"
    echo -e "  IP atual: ${BLD}${auto_lan_ip:-(sem ip)}${NC}"
    echo ""
    echo -e "  ${BLD}[1]${NC} DHCP     — IP obtido automaticamente ${YLW}(não recomendado para gateway)${NC}"
    echo -e "  ${BLD}[2]${NC} ${CYN}Estático${NC} — IP fixo ${GRN}(recomendado)${NC}"
    echo ""
    echo -ne "  ${YLW}Escolha [1/2, padrão: 2]: ${NC}"
    local lan_choice; read -r lan_choice; lan_choice="${lan_choice:-2}"

    if [[ "$lan_choice" == "1" ]]; then
        LAN_MODE="dhcp"
        LAN_IP="${auto_lan_ip:-dhcp}"
        warn "LAN em DHCP — configure reserva no DHCP server"
        ok "LAN: $LAN_IFACE — DHCP"
    else
        LAN_MODE="static"
        echo ""
        echo -ne "  ${YLW}  IP LAN     [padrão: 192.168.0.1]: ${NC}"
        read -r LAN_IP; LAN_IP="${LAN_IP:-192.168.0.1}"
        echo -ne "  ${YLW}  Máscara    [padrão: /24]: /${NC}"
        local lan_prefix; read -r lan_prefix; lan_prefix="${lan_prefix:-24}"
        ok "LAN: $LAN_IFACE — estático | $LAN_IP/$lan_prefix"
    fi

    # ── Resumo e confirmação final ───────────────────────────────────────────
    echo ""
    echo -e "${BLD}${CYN}══ Resumo — /etc/network/interfaces ══${NC}"
    echo ""
    if [[ "$WAN_MODE" == "dhcp" ]]; then
        echo -e "  auto $WAN_IFACE
  iface $WAN_IFACE inet ${GRN}dhcp${NC}"
    else
        echo -e "  auto $WAN_IFACE
  iface $WAN_IFACE inet ${CYN}static${NC}"
        echo -e "      address $WAN_IP/${wan_prefix:-24}
      gateway $GW_IP"
    fi
    echo ""
    if [[ "$LAN_MODE" == "dhcp" ]]; then
        echo -e "  auto $LAN_IFACE
  iface $LAN_IFACE inet ${GRN}dhcp${NC}"
    else
        echo -e "  auto $LAN_IFACE
  iface $LAN_IFACE inet ${CYN}static${NC}"
        echo -e "      address $LAN_IP/${lan_prefix:-24}"
    fi
    echo ""
    echo -ne "  ${BLD}Prosseguir com a instalação? [ENTER/n]: ${NC}"
    local final_resp; read -r final_resp
    [[ "${final_resp,,}" == "n" ]] && { warn "Instalação cancelada."; exit 0; }

    ok "WAN : $WAN_IFACE | ${WAN_IP} | modo: ${WAN_MODE} | GW: ${GW_IP}"
    ok "LAN : $LAN_IFACE | ${LAN_IP} | modo: ${LAN_MODE}"
    ok "NET : WAN=${NET_EXT} | LAN=${NET_INT}"
}

detect_and_confirm

# =============================================================================
# VARIÁVEIS GLOBAIS DE CONFIGURAÇÃO
# =============================================================================
PROXY_PORT=3128
PROXY_PORT_PLAIN=3129
DNS1="10.14.8.20"
DNS2="10.1.6.222"
DNS3="10.14.8.16"
DNS4="8.8.8.8"
DNS5="1.1.1.1"
GW_CONF="/etc/gateway"
LIST_DIR="/etc/squid/lists"
CA_DIR="/etc/squid/ssl_cert"
SSL_DB="/var/lib/squid/ssl_db"
mkdir -p "${GW_CONF}" "${LIST_DIR}"

# Salvar config
cat > "${GW_CONF}/config" << CFGEOF
WAN_IFACE=${WAN_IFACE}
LAN_IFACE=${LAN_IFACE}
WAN_IP=${WAN_IP}
LAN_IP=${LAN_IP}
GW_IP=${GW_IP}
WAN_MODE=${WAN_MODE}
LAN_MODE=${LAN_MODE}
NET_INT=${NET_INT}
NET_EXT=${NET_EXT}
DNS1=${DNS1}
DNS2=${DNS2}
DNS3=${DNS3}
DNS4=${DNS4}
DNS5=${DNS5}
PROXY_PORT=${PROXY_PORT}
PROXY_PORT_PLAIN=${PROXY_PORT_PLAIN}
CFGEOF
ok "Config salvo em ${GW_CONF}/config"

# =============================================================================
# PASSO 1 — PACOTES
# =============================================================================
hdr "1. INSTALANDO PACOTES"
apt-get update -qq
apt-get install -y \
    squid-openssl openssl \
    bind9 bind9utils dnsutils \
    nftables \
    nginx \
    chrony \
    fail2ban \
    python3 python3-venv python3-pip \
    curl wget net-tools iproute2 \
    apt-utils ca-certificates gnupg \
    2>/dev/null && ok "Pacotes instalados"

# Python3-venv correto para Debian 13
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
apt-get install -y "python3${PY_VER}-venv" 2>/dev/null || apt-get install -y python3.13-venv 2>/dev/null || true
ok "python3${PY_VER}-venv instalado"

# =============================================================================
# PASSO 2 — CERTIFICADO CA (SSL Bump)
# =============================================================================
hdr "2. CERTIFICADO CA"
CA_DIR="/etc/squid/ssl_cert"
SSL_DB="/var/lib/squid/ssl_db"
mkdir -p "${CA_DIR}"

if [[ ! -f "${CA_DIR}/cdpni-ca.crt" ]]; then
    openssl req -new -newkey rsa:4096 -sha256 -days 3650 -nodes -x509 \
        -keyout "${CA_DIR}/cdpni-ca.key" \
        -out    "${CA_DIR}/cdpni-ca.crt" \
        -subj   "/C=BR/ST=SP/O=CDPNI/CN=CDPNI-Gateway-CA" 2>/dev/null
    chmod 600 "${CA_DIR}/cdpni-ca.key"
    ok "CA gerado: ${CA_DIR}/cdpni-ca.crt"
else
    ok "CA existente mantido"
fi

# Instalar CA no sistema
cp "${CA_DIR}/cdpni-ca.crt" /usr/local/share/ca-certificates/cdpni-ca.crt
update-ca-certificates 2>/dev/null && ok "CA instalado no sistema"

# Banco SSL do Squid
CERTGEN=$(find /usr -name "security_file_certgen" 2>/dev/null | head -1)
if [[ -n "$CERTGEN" ]]; then
    # Recriar banco SSL sempre — evita sslcrtd_program crashing (banco corrompido)
    rm -rf "${SSL_DB}" 2>/dev/null || true
    mkdir -p "${SSL_DB}"
    chown -R proxy:proxy "${SSL_DB}" 2>/dev/null || true
    chmod 750 "${SSL_DB}" 2>/dev/null || true
    if id proxy &>/dev/null; then
        sudo -u proxy "${CERTGEN}" -c -s "${SSL_DB}" -M 256MB 2>/dev/null &&             ok "Banco SSL criado como proxy" ||             { "${CERTGEN}" -c -s "${SSL_DB}" -M 256MB 2>/dev/null && ok "Banco SSL criado" || warn "Banco SSL com problema"; }
    else
        "${CERTGEN}" -c -s "${SSL_DB}" -M 256MB 2>/dev/null && ok "Banco SSL criado" || warn "Banco SSL com problema"
    fi
    chown -R proxy:proxy "${SSL_DB}" 2>/dev/null || true
    chmod -R 750 "${SSL_DB}" 2>/dev/null || true
fi

# =============================================================================
# PASSO 3 — SQUID
# =============================================================================
hdr "3. SQUID"

# Criar listas de ACL
cat > "${LIST_DIR}/ips_livres.acl"     << 'ACLEOF'
# IPs com acesso total à internet, sem restrição de horário
# Adicione um IP por linha: Ex: 192.168.0.5
ACLEOF

cat > "${LIST_DIR}/ips_parciais.acl"   << 'ACLEOF'
# IPs com internet liberada, exceto streaming/social fora do horário
ACLEOF

cat > "${LIST_DIR}/ips_restritos.acl"  << 'ACLEOF'
# IPs com acesso só a gov/bancos fora do horário
ACLEOF

cat > "${LIST_DIR}/sites_liberados.acl" << 'ACLEOF'
# Sites sempre liberados para todos
ACLEOF

cat > "${LIST_DIR}/sites_bloqueados.acl" << 'ACLEOF'
# Sites bloqueados para todos, sempre
ACLEOF

cat > "${LIST_DIR}/sites_governo.acl" << 'ACLEOF'
# Domínios PAI cobrem todos os subdomínios automaticamente
.gov.br
.jus.br
.mp.br
.def.br
.leg.br
ACLEOF

cat > "${LIST_DIR}/sites_bancos.acl" << 'ACLEOF'
.bradesco.com.br
.itau.com.br
.santander.com.br
.bb.com.br
.caixa.gov.br
.nubank.com.br
.inter.co
.c6bank.com.br
.sicoob.com.br
.sicredi.com.br
.picpay.com
.stone.com.br
.cielo.com.br
.xpi.com.br
.btgpactual.com
.safra.com.br
ACLEOF

cat > "${LIST_DIR}/ssl_nobump.acl" << 'ACLEOF'
# Domínios sem SSL Bump — domínio PAI cobre subdomínios automaticamente
# .gov.br já cobre: .sp.gov.br, .sap.sp.gov.br, .cartoriosap.sp.gov.br etc.
# .jus.br já cobre: .tjsp.jus.br, .esaj.tjsp.jus.br, .pje.jus.br etc.
.gov.br
.jus.br
.mp.br
.bradesco.com.br
.itau.com.br
.bb.com.br
.caixa.gov.br
.nubank.com.br
ACLEOF

ok "Listas de ACL criadas"

# Detectar certgen
CERTGEN=$(find /usr -name "security_file_certgen" 2>/dev/null | head -1)

# Flags de configuração SSL (usadas na geração do squid.conf abaixo)
if [[ -n "$CERTGEN" && -f "${CA_DIR}/cdpni-ca.crt" ]]; then
    SSL_BUMP_ENABLED=1
    warn "SSL Bump ATIVO — usando certgen: ${CERTGEN}"
else
    SSL_BUMP_ENABLED=0
    warn "SSL Bump INATIVO (certgen não encontrado)"
fi

# Gerar squid.conf linha-a-linha — evita quebra do http_port ssl-bump
# Iniciar geração do squid.conf
# Criar squid.conf
# Gerar squid.conf — método seguro com Python para garantir linha única no http_port
python3 - << SQPYEOF
import os, subprocess, pathlib

# Garantir que os arquivos de lista existem antes de referenciar no squid.conf
list_dir = pathlib.Path("/etc/squid/lists")
list_dir.mkdir(parents=True, exist_ok=True)

# Criar arquivos vazios se não existirem
for lst in ["ips_livres", "ips_parciais", "ips_restritos",
            "sites_liberados", "sites_bloqueados", "sites_governo", "sites_bancos"]:
    p = list_dir / f"{lst}.acl"
    if not p.exists():
        p.touch()

# ssl_nobump.acl — criar com domínios gov/bancos se não existir
ssl_nobump = list_dir / "ssl_nobump.acl"
if not ssl_nobump.exists() or ssl_nobump.stat().st_size == 0:
    ssl_nobump.write_text("""# Domínios sem SSL Bump (splice direto)
# Usar apenas domínios PAI — subdomínios são cobertos automaticamente
# NÃO duplicar: .gov.br já cobre .sp.gov.br, .sap.sp.gov.br, .cartoriosap.sp.gov.br etc.
# NÃO duplicar: .jus.br já cobre .tjsp.jus.br, .esaj.tjsp.jus.br, .pje.jus.br etc.
.gov.br
.jus.br
.mp.br
.bradesco.com.br
.itau.com.br
.bb.com.br
.caixa.gov.br
.nubank.com.br
""")

PROXY_PORT       = "${PROXY_PORT}"
PROXY_PORT_PLAIN = "${PROXY_PORT_PLAIN}"
CA_DIR           = "${CA_DIR}"
CERTGEN          = "${CERTGEN}"
SSL_DB           = "${SSL_DB}"
NET_INT          = "${NET_INT}"
NET_EXT          = "${NET_EXT}"
DNS1             = "${DNS1}"
DNS2             = "${DNS2}"
DNS3             = "${DNS3}"
DNS4             = "${DNS4}"
DNS5             = "${DNS5}"
WAN_IP           = "${WAN_IP}"
LAN_IP           = "${LAN_IP}"
SSL_ENABLED      = "${SSL_BUMP_ENABLED}" == "1"
from datetime import datetime

# Forwarders DNS — só incluir IPs válidos
import re as _re
dns_servers = []
for ip in [DNS1, DNS2, DNS3, DNS4, DNS5, "8.8.8.8", "1.1.1.1"]:
    if ip and _re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip):
        if ip not in dns_servers:
            dns_servers.append(ip)
dns_line = " ".join(dns_servers[:5])

lines = []
lines.append(f"# squid.conf — CDPNI Gateway v1.0 — {datetime.now().strftime('%d/%m/%Y %H:%M')}")
lines.append("")

# http_port — UMA LINHA POR PORTA, garantido pelo Python
if SSL_ENABLED and CERTGEN and os.path.exists(f"{CA_DIR}/cdpni-ca.crt"):
    lines.append(f"http_port {PROXY_PORT} ssl-bump cert={CA_DIR}/cdpni-ca.crt key={CA_DIR}/cdpni-ca.key generate-host-certificates=on dynamic_cert_mem_cache_size=256MB")
    lines.append(f"http_port {PROXY_PORT_PLAIN}")
    lines.append("")
    lines.append(f"sslcrtd_program {CERTGEN} -s {SSL_DB} -M 256MB")
    lines.append("sslcrtd_children 4 startup=2 idle=1")
    lines.append("")
    # ACLs SSL Bump — DEVEM vir antes das http_access rules, mas DEPOIS das acl src
    # ssl_nobump usa arquivo de lista — subdomínios redundantes já foram removidos do arquivo
    ssl_acls = """acl ssl_nobump dstdomain "/etc/squid/lists/ssl_nobump.acl"
acl step1 at_step SslBump1
acl step2 at_step SslBump2"""
    ssl_bump_rules = """ssl_bump peek step1
ssl_bump peek   step2 ssl_nobump
ssl_bump stare  step2 !ssl_nobump
ssl_bump splice ssl_nobump
ssl_bump bump   all
sslproxy_cert_error allow all"""
else:
    lines.append(f"http_port {PROXY_PORT}")
    lines.append(f"http_port {PROXY_PORT_PLAIN}")
    ssl_acls = ""
    ssl_bump_rules = ""

lines.append("")
lines.append("visible_hostname gateway.local")
lines.append("")
lines.append("# Redes")
lines.append("acl localnet    src 127.0.0.0/8")
lines.append(f"acl localnet    src {NET_INT}")
lines.append(f"acl localnet    src {NET_EXT}")
lines.append(f"acl dst_local    dst {NET_INT}")
lines.append(f"acl dst_wan      dst {NET_EXT}")
lines.append("acl dst_loopback dst 127.0.0.0/8")
lines.append("acl dst_intranet dst 10.0.0.0/8")
lines.append("acl SSL_ports   port 443")
lines.append("acl Safe_ports  port 80 443 5000 8080 21 70 210 280 488 591 777 1025-65535")
lines.append("acl CONNECT     method CONNECT")
lines.append("")
lines.append("# Grupos de IPs")
lines.append('acl ips_livres    src "/etc/squid/lists/ips_livres.acl"')
lines.append('acl ips_parciais  src "/etc/squid/lists/ips_parciais.acl"')
lines.append('acl ips_restritos src "/etc/squid/lists/ips_restritos.acl"')
lines.append("")
lines.append("# Horários liberados (dias úteis): 07-08h | 11-13h | 17-18h | 19-23h")
lines.append("acl h_livre time MTWHF 07:00-08:00")
lines.append("acl h_livre time MTWHF 11:00-13:00")
lines.append("acl h_livre time MTWHF 17:00-18:00")
lines.append("acl h_livre time MTWHF 19:00-23:00")
lines.append("acl h_livre time SA 00:00-24:00")
lines.append("acl h_livre time A  00:00-24:00")
lines.append("")
lines.append("# Sites")
lines.append('acl sempre_livre     dstdomain "/etc/squid/lists/sites_governo.acl"')
lines.append('acl sempre_livre     dstdomain "/etc/squid/lists/sites_bancos.acl"')
lines.append('acl sites_governo    dstdomain "/etc/squid/lists/sites_governo.acl"')
lines.append('acl sites_bancos     dstdomain "/etc/squid/lists/sites_bancos.acl"')
lines.append('acl sites_liberados  dstdomain "/etc/squid/lists/sites_liberados.acl"')
lines.append('acl sites_bloqueados dstdomain "/etc/squid/lists/sites_bloqueados.acl"')
lines.append("acl conteudo_restrito url_regex -i youtube|netflix|instagram|facebook|tiktok|twitch|spotify|deezer|telegram|whatsapp")
lines.append("")

# ACLs SSL — após definição de ips_livres
if ssl_acls:
    lines.append(ssl_acls)
    lines.append("")

# SSL Bump rules — após TODAS as ACLs
if ssl_bump_rules:
    lines.append(ssl_bump_rules)
    lines.append("")

lines.append("# =============================================================================")
lines.append("# REGRAS DE ACESSO")
lines.append("# =============================================================================")
lines.append("http_access deny !Safe_ports")
lines.append("http_access deny CONNECT !SSL_ports")
lines.append("")
lines.append("# R00: Redes locais e intranet 10.0.0.0/8")
lines.append("http_access allow localnet dst_local")
lines.append("http_access allow localnet dst_wan")
lines.append("http_access allow localnet dst_loopback")
lines.append("http_access allow localnet dst_intranet")
lines.append("")
lines.append("# always_direct para intranet gov SP")
lines.append("always_direct allow dst_intranet")
lines.append("always_direct allow dst_local")
lines.append("always_direct allow dst_wan")
lines.append("")
lines.append("# R01: IPs livres")
lines.append("http_access allow ips_livres")
lines.append("")
lines.append("# R02: Sites sempre liberados")
lines.append("http_access allow sempre_livre")
lines.append("http_access allow sites_liberados")
lines.append("")
lines.append("# R03: Blacklist")
lines.append("http_access deny sites_bloqueados")
lines.append("")
lines.append("# R04: IPs parciais")
lines.append("http_access allow ips_parciais h_livre")
lines.append("http_access deny  ips_parciais conteudo_restrito !h_livre")
lines.append("http_access allow ips_parciais")
lines.append("")
lines.append("# R05: IPs restritos")
lines.append("http_access allow ips_restritos h_livre")
lines.append("http_access deny  ips_restritos")
lines.append("")
lines.append("# R06: Sem categoria — só passou em R02")
lines.append("http_access deny localnet")
lines.append("# R07: Negar tudo")
lines.append("http_access deny all")
lines.append("")
lines.append("# Cache")
lines.append("cache_mem 256 MB")
lines.append("maximum_object_size_in_memory 512 KB")
lines.append("maximum_object_size 128 MB")
lines.append("cache_dir ufs /var/cache/squid 4096 16 256")
lines.append("no_cache deny CONNECT")
lines.append("positive_dns_ttl 1 hour")
lines.append("negative_dns_ttl 15 minutes")
lines.append("")
lines.append("# DNS")
lines.append(f"dns_nameservers {dns_line}")
lines.append("dns_retransmit_interval 2 seconds")
lines.append("dns_timeout 30 seconds")
if WAN_IP and WAN_IP != "dhcp":
    lines.append(f"tcp_outgoing_address {WAN_IP}")
lines.append("")
lines.append("# Logs")
lines.append("access_log /var/log/squid/access.log")
lines.append("cache_log  /var/log/squid/cache.log")
lines.append("cache_store_log none")
lines.append("")
lines.append("# Performance")
lines.append("client_lifetime    65 minutes")
lines.append("shutdown_lifetime  10 seconds")
lines.append("connect_timeout    60 seconds")
lines.append("read_timeout       300 seconds")
lines.append("request_timeout    300 seconds")
lines.append("forward_timeout    240 seconds")
lines.append("pconn_timeout      60 seconds")
lines.append("half_closed_clients off")
lines.append("max_filedescriptors 65536")

with open("/etc/squid/squid.conf", "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"squid.conf gerado: {len(lines)} linhas")
# Verificar linha do http_port
for i, l in enumerate(lines):
    if "http_port" in l:
        print(f"  L{i+1}: {l[:80]}")
SQPYEOF

# Validar e corrigir automaticamente se houver linha quebrada
python3 << 'SQFIX'
import re, sys
with open('/etc/squid/squid.conf', 'r') as f:
    content = f.read()

fixed = False
lines = content.splitlines()
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    # Detectar linha http_port ssl-bump quebrada (sem número de porta ou com fragmento)
    if re.match(r'^m_cache_size=', line):
        # Fragmento de linha anterior — juntar com a anterior
        if new_lines:
            new_lines[-1] = new_lines[-1].rstrip() + ' dynamic_cert_' + line
            fixed = True
        i += 1
        continue
    if line.strip() == 'http_port':
        # http_port sem porta — corrigir para porta plain
        new_lines.append('http_port 3129')
        fixed = True
        i += 1
        continue
    new_lines.append(line)
    i += 1

if fixed:
    with open('/etc/squid/squid.conf', 'w') as f:
        f.write('\n'.join(new_lines) + '\n')
    print("squid.conf: linhas quebradas corrigidas automaticamente")
else:
    print("squid.conf: OK")
SQFIX

squid -k parse 2>&1 | grep -i "fatal\|error" | grep -v "IPv6\|BCP 177" | head -5
squid -k parse 2>/dev/null && ok "squid.conf válido" || warn "Verificar squid.conf — rode: squid -k parse"

# =============================================================================
# PASSO 4 — BIND9 (DNS)
# =============================================================================
hdr "4. BIND9 (DNS)"
mkdir -p /etc/bind/zones

SERIAL=$(date +%Y%m%d01)
lan_oct="${LAN_IP##*.}"

# Validar IPs dos forwarders — IP inválido causa FATAL no named
_fw_list=""
for _ip in "${DNS1}" "${DNS2}" "${DNS3}" "${DNS4}" "${DNS5}"; do
    [[ -z "$_ip" ]] && continue
    # Verificar formato básico de IP
    if [[ "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        _fw_list="${_fw_list}        ${_ip};\n"
    else
        warn "DNS inválido ignorado: '${_ip}'"
    fi
done
# Garantir pelo menos um forwarder válido
[[ -z "$_fw_list" ]] && _fw_list="        8.8.8.8;\n        1.1.1.1;\n"

cat > /etc/bind/named.conf.options << OPTEOF
options {
    directory "/var/cache/bind";
    listen-on { 127.0.0.1; ${LAN_IP}; };
    allow-query { 127.0.0.1; ${NET_INT}; };
    recursion yes;
    forwarders {
$(printf "%b" "${_fw_list}")    };
    forward first;
    dnssec-validation no;
    minimal-responses yes;
};
OPTEOF

cat > /etc/bind/named.conf.local << LOCALEOF
# Zonas locais
zone "gateway.local" {
    type master;
    file "/etc/bind/zones/gateway.local.zone";
};
zone "cdpni.local" {
    type master;
    file "/etc/bind/zones/cdpni.local.zone";
};
zone "0.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/192.168.0.rev";
};

# ==========================================================================
# ZONAS FORWARD CONDICIONAIS — Intranet Gov SP
# Cada domínio encaminhado para o DNS que o resolve corretamente
# ==========================================================================

# policiapenal.sp.gov.br — resolve apenas em 10.14.8.20
zone "policiapenal.sp.gov.br" {
    type forward;
    forwarders { ${DNS1}; };
    forward only;
};
zone "gpu.policiapenal.sp.gov.br" {
    type forward;
    forwarders { ${DNS1}; };
    forward only;
};

# cartoriosap.sp.gov.br — resolve apenas em 10.1.6.222
zone "cartoriosap.sp.gov.br" {
    type forward;
    forwarders { ${DNS2}; };
    forward only;
};
zone "new.cartoriosap.sp.gov.br" {
    type forward;
    forwarders { ${DNS2}; };
    forward only;
};

# sap.sp.gov.br (sistema de administração penitenciária) — DNS2
zone "sap.sp.gov.br" {
    type forward;
    forwarders { ${DNS2}; ${DNS1}; };
    forward only;
};

# sp.gov.br geral — tenta DNS1 depois DNS2
zone "sp.gov.br" {
    type forward;
    forwarders { ${DNS1}; ${DNS2}; ${DNS3}; };
    forward only;
};

# tjsp.jus.br — DNS interno
zone "tjsp.jus.br" {
    type forward;
    forwarders { ${DNS1}; ${DNS2}; };
    forward only;
};
zone "esaj.tjsp.jus.br" {
    type forward;
    forwarders { ${DNS1}; ${DNS2}; };
    forward only;
};
zone "pje.jus.br" {
    type forward;
    forwarders { ${DNS1}; ${DNS2}; };
    forward only;
};
LOCALEOF

cat > /etc/bind/zones/gateway.local.zone << ZONEOF
\$TTL 3600
@   IN SOA ns1.gateway.local. admin.gateway.local. (
              ${SERIAL} 3600 1800 604800 300 )
    IN NS   ns1.gateway.local.
ns1     IN A ${LAN_IP}
gateway IN A ${LAN_IP}
proxy   IN A ${LAN_IP}
dns     IN A ${LAN_IP}
wpad    IN A ${LAN_IP}
; Servidor Samba CDPNI
cdpni       IN A 192.168.0.11
samba       IN A 192.168.0.11
arquivos    IN A 192.168.0.11
ZONEOF

cat > /etc/bind/zones/cdpni.local.zone << ZONEOF
\$TTL 3600
@   IN SOA ns1.gateway.local. admin.gateway.local. (
              ${SERIAL} 3600 1800 604800 300 )
    IN NS   ns1.gateway.local.
@           IN A 192.168.0.11
cdpni       IN A 192.168.0.11
samba       IN A 192.168.0.11
arquivos    IN A 192.168.0.11
ZONEOF

cat > /etc/bind/zones/192.168.0.rev << RZONEOF
\$TTL 3600
@   IN SOA ns1.gateway.local. admin.gateway.local. (
              ${SERIAL} 3600 1800 604800 300 )
    IN NS   ns1.gateway.local.
${lan_oct}  IN PTR gateway.local.
11          IN PTR cdpni.cdpni.local.
RZONEOF

bind_user=$(id -un bind 2>/dev/null || echo root)
bind_grp=$(id -gn bind 2>/dev/null || echo root)
chown -R "${bind_user}:${bind_grp}" /etc/bind/zones/
chmod 644 /etc/bind/zones/*.zone /etc/bind/zones/*.rev

named-checkconf /etc/bind/named.conf 2>&1
if named-checkconf /etc/bind/named.conf 2>/dev/null; then
    ok "named.conf válido"
else
    warn "named.conf com erro — verificando named.conf.options..."
    # Fallback: usar apenas forwarders seguros
    cat > /etc/bind/named.conf.options << SAFE_OPT
options {
    directory "/var/cache/bind";
    listen-on { 127.0.0.1; ${LAN_IP}; };
    allow-query { 127.0.0.1; ${NET_INT}; };
    recursion yes;
    forwarders { 8.8.8.8; 1.1.1.1; };
    forward first;
    dnssec-validation no;
    minimal-responses yes;
};
SAFE_OPT
    named-checkconf /etc/bind/named.conf 2>/dev/null && ok "named.conf corrigido com fallback DNS" || warn "Verificar manualmente: named-checkconf"
fi

# resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << RESEOF
nameserver 127.0.0.1
nameserver ${DNS1}
nameserver ${DNS2}
nameserver ${DNS3}
nameserver ${DNS4}
search gateway.local cdpni.local
RESEOF
chattr +i /etc/resolv.conf 2>/dev/null || true

# =============================================================================
# PASSO 5 — NFTABLES (Firewall + NAT)
# =============================================================================
hdr "5. NFTABLES"
cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state invalid drop
        ct state {established, related} accept
        iif lo accept
        iif ${LAN_IFACE} accept
        ip protocol icmp accept
        tcp dport 22 ct state new accept
        counter drop
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state {established, related} accept
        iif ${LAN_IFACE} oif ${WAN_IFACE} accept
        iif ${WAN_IFACE} oif ${LAN_IFACE} ct state {established, related} accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;
        # Redirecionar HTTP/HTTPS para Squid (proxy transparente)
        iif ${LAN_IFACE} ip protocol tcp tcp dport 80 redirect to :${PROXY_PORT_PLAIN}
        iif ${LAN_IFACE} ip protocol tcp tcp dport 443 redirect to :${PROXY_PORT}
    }
    chain postrouting {
        type nat hook postrouting priority 100;
        oif ${WAN_IFACE} masquerade
    }
}
NFTEOF

# =============================================================================
# SYSCTL — IP Forwarding + hardening
# =============================================================================
cat > /etc/sysctl.d/99-gateway.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
net.ipv4.conf.all.rp_filter              = 1
net.ipv4.conf.default.rp_filter          = 1
net.ipv4.conf.all.accept_redirects       = 0
net.ipv4.conf.all.send_redirects         = 0
net.ipv4.conf.all.accept_source_route    = 0
net.ipv4.icmp_echo_ignore_broadcasts     = 1
net.ipv4.tcp_syncookies                  = 1
net.core.somaxconn           = 65535
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog  = 5000
net.ipv4.tcp_fin_timeout     = 30
SYSCTL
sysctl -p /etc/sysctl.d/99-gateway.conf >/dev/null 2>&1 && ok "sysctl: IP forwarding ativo, IPv6 desabilitado"

# =============================================================================
# REDE — /etc/network/interfaces
# =============================================================================
command -v ifup &>/dev/null || apt-get install -y ifupdown 2>/dev/null || true
if systemctl is-active NetworkManager &>/dev/null; then
    warn "NetworkManager detectado — configure interfaces via nmcli/nmtui se necessário"
fi

[[ -f /etc/network/interfaces ]] && cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"

wan_pfx=$(echo "${NET_EXT:-10.14.29.0/24}" | cut -d/ -f2)
{
    echo "# Gerado pelo gw-v1.sh — $(date '+%d/%m/%Y %H:%M')"
    echo "source /etc/network/interfaces.d/*"
    echo ""
    echo "auto lo"
    echo "iface lo inet loopback"
    echo ""
    if [[ "${WAN_MODE:-static}" == "dhcp" ]]; then
        echo "# WAN — DHCP"
        echo "auto ${WAN_IFACE}"
        echo "iface ${WAN_IFACE} inet dhcp"
    else
        echo "# WAN — estático | ${NET_EXT}"
        echo "auto ${WAN_IFACE}"
        echo "iface ${WAN_IFACE} inet static"
        echo "    address ${WAN_IP}/${wan_pfx}"
        echo "    gateway ${GW_IP}"
        echo "    dns-nameservers ${DNS1} ${DNS2} ${DNS3}"
    fi
    echo ""
    if [[ "${LAN_MODE:-static}" == "dhcp" ]]; then
        echo "# LAN — DHCP"
        echo "auto ${LAN_IFACE}"
        echo "iface ${LAN_IFACE} inet dhcp"
    else
        echo "# LAN — estático | ${NET_INT}"
        echo "auto ${LAN_IFACE}"
        echo "iface ${LAN_IFACE} inet static"
        echo "    address ${LAN_IP}/24"
    fi
} > /etc/network/interfaces
ok "interfaces configurado: WAN=${WAN_IFACE} (${WAN_MODE}) | LAN=${LAN_IFACE} (${LAN_MODE})"
warn "Reinicie o sistema para aplicar as configurações de rede"

# =============================================================================
# PASSO 6 — CHRONY (NTP)
# =============================================================================
hdr "6. CHRONY"
cat > /etc/chrony/chrony.conf << CHREOF
pool a.ntp.br iburst
pool b.ntp.br iburst
pool c.ntp.br iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow ${NET_INT}
local stratum 10
CHREOF
ok "Chrony configurado"

# =============================================================================
# PASSO 7 — NGINX (CA + WPAD)
# =============================================================================
hdr "7. NGINX"
CA_WEB="/var/www/html/ca"
mkdir -p "${CA_WEB}"
cp "${CA_DIR}/cdpni-ca.crt" "${CA_WEB}/"

cat > /var/www/html/wpad.dat << WPADEOF
function FindProxyForURL(url, host) {
    var no_proxy = ["192.168.0.", "10.", "127.", "localhost", ".gateway.local", ".cdpni.local"];
    for (var i = 0; i < no_proxy.length; i++) {
        if (shExpMatch(host, no_proxy[i] + "*")) return "DIRECT";
    }
    if (isPlainHostName(host)) return "DIRECT";
    return "PROXY ${LAN_IP}:${PROXY_PORT}; DIRECT";
}
WPADEOF

cat > /var/www/html/index.html << IDXEOF
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="UTF-8">
<meta http-equiv="refresh" content="0;url=http://${LAN_IP}:5000">
<title>Gateway CDPNI</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#0d2a45}
.b{background:#fff;padding:40px;border-radius:12px;text-align:center}
h2{color:#1c3557}p{color:#666;font-size:13px;margin:10px 0 20px}
a{background:#1c3557;color:#fff;padding:10px 22px;border-radius:6px;text-decoration:none;font-size:13px}
</style></head><body><div class="b">
<h2>Gateway CDPNI</h2>
<p>Redirecionando para o painel...</p>
<a href="http://${LAN_IP}:5000">Acessar Painel</a>
</div></body></html>
IDXEOF

cat > /etc/nginx/sites-available/gateway << NGINXEOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    autoindex off;
    index index.html;
    location /ca/ {
        location ~\.(crt|der|p12)$ { add_header Content-Disposition "attachment"; }
    }
    location = /wpad.dat { add_header Content-Type "application/x-ns-proxy-autoconfig"; }
    location = /proxy.pac { add_header Content-Type "application/x-ns-proxy-autoconfig"; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/gateway /etc/nginx/sites-enabled/gateway
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>/dev/null && ok "Nginx OK" || warn "Verificar nginx.conf"

# =============================================================================
# PASSO 8 — PAINEL WEB (Flask — porta 5000)
# =============================================================================
hdr "8. PAINEL WEB"
PANEL_DIR="/opt/gateway-panel"
PANEL_VENV="${PANEL_DIR}/venv"
mkdir -p "${PANEL_DIR}"

# Senha padrão
[[ ! -f "${GW_CONF}/panel_pass" ]] && { echo "admin" > "${GW_CONF}/panel_pass"; chmod 600 "${GW_CONF}/panel_pass"; }

# Virtualenv
python3 -m venv --system-site-packages "${PANEL_VENV}" 2>/dev/null || {
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
    apt-get install -y "python3${PY_VER}-venv" 2>/dev/null || apt-get install -y python3.13-venv 2>/dev/null || true
    python3 -m venv --system-site-packages "${PANEL_VENV}" || python3 -m venv "${PANEL_VENV}"
}
"${PANEL_VENV}/bin/pip" install --quiet flask 2>/dev/null || true
ok "Flask instalado"

# Instalar app.py do painel (instalado pelo gw-panel-v1.sh separado)
cat > "${PANEL_DIR}/README.txt" << 'RDEOF'
Painel do Gateway CDPNI
Execute: bash gw-panel-v1.sh
RDEOF

# Serviço systemd
cat > /etc/systemd/system/gateway-panel.service << SVCEOF
[Unit]
Description=Gateway CDPNI — Painel Web
After=network.target

[Service]
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_VENV}/bin/python ${PANEL_DIR}/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable gateway-panel 2>/dev/null || true
ok "Serviço gateway-panel registrado"

# Liberar porta 5000 no nftables
nft add rule inet filter input ip saddr ${NET_INT} tcp dport 5000 ct state new accept 2>/dev/null || true
nft list ruleset > /etc/nftables.conf

# =============================================================================
# PASSO 9 — FERRAMENTAS CLI
# =============================================================================
hdr "9. FERRAMENTAS CLI"

# nat-manager
cat > /usr/local/bin/nat-manager << 'NATEOF'
#!/bin/bash
source /etc/gateway/config 2>/dev/null
NAT_FILE="/etc/gateway/nat_entries.conf"
[[ ! -f "$NAT_FILE" ]] && touch "$NAT_FILE"

case "$1" in
    list)
        echo "╔════════════════════════════════════════════════════╗"
        echo "║              NAT 1:1 — Entradas ativas            ║"
        echo "╠══════════════════╦══════════════════╦═════════════╣"
        echo "║ IP Interno       ║ IP Externo       ║ Descrição   ║"
        echo "╠══════════════════╬══════════════════╬═════════════╣"
        grep -v '^#' "$NAT_FILE" | while IFS=' ' read -r int ext desc; do
            [[ -z "$int" ]] && continue
            printf "║ %-16s ║ %-16s ║ %-11s ║\n" "$int" "$ext" "${desc:0:11}"
        done
        echo "╚══════════════════╩══════════════════╩═════════════╝"
        ;;
    add)
        INT_IP="$2"; EXT_IP="$3"; DESC="${4:-NAT}"
        [[ -z "$INT_IP" ]] && { echo "Uso: nat-manager add <ip_interno> [ip_externo] [desc]"; exit 1; }
        [[ -z "$EXT_IP" ]] && EXT_IP="${WAN_IP}"
        grep -q "^${INT_IP} " "$NAT_FILE" && { echo "Já existe NAT para ${INT_IP}"; exit 1; }
        echo "${INT_IP} ${EXT_IP} ${DESC}" >> "$NAT_FILE"
        nft add rule ip nat prerouting ip daddr "${EXT_IP}" dnat to "${INT_IP}" 2>/dev/null || true
        nft add rule ip nat postrouting ip saddr "${INT_IP}" snat to "${EXT_IP}" 2>/dev/null || true
        nft list ruleset > /etc/nftables.conf
        echo "NAT adicionado: ${INT_IP} <-> ${EXT_IP}"
        ;;
    del)
        INT_IP="$2"; [[ -z "$INT_IP" ]] && { echo "Uso: nat-manager del <ip_interno>"; exit 1; }
        sed -i "/^${INT_IP} /d" "$NAT_FILE"
        systemctl restart nftables
        echo "NAT removido: ${INT_IP}"
        ;;
    reload)
        systemctl restart nftables && echo "nftables recarregado"
        ;;
    *)
        echo "Uso: nat-manager {list|add|del|reload}"
        ;;
esac
NATEOF
chmod +x /usr/local/bin/nat-manager

# gateway-status
cat > /usr/local/bin/gateway-status << 'STATEOF'
#!/bin/bash
source /etc/gateway/config 2>/dev/null
echo ""
echo "════════════════════════════════════════════"
echo "  GATEWAY CDPNI — Status v1.0"
echo "════════════════════════════════════════════"
for svc in squid named nftables nginx chrony fail2ban gateway-panel; do
    st=$(systemctl is-active "$svc" 2>/dev/null)
    [[ "$st" == "active" ]] && echo " ✔ $svc" || echo " ✘ $svc ($st)"
done
echo ""
echo " LAN: ${LAN_IP} (${LAN_IFACE})"
echo " WAN: ${WAN_IP} (${WAN_IFACE})"
echo " Proxy: ${LAN_IP}:${PROXY_PORT}"
echo " Painel: http://${LAN_IP}:5000"
echo "════════════════════════════════════════════"
STATEOF
chmod +x /usr/local/bin/gateway-status

# squid-fix
cat > /usr/local/bin/squid-fix << 'SQFEOF'
#!/bin/bash
echo "=== Diagnóstico Squid ==="
squid -k parse 2>&1 | tail -5
echo "--- Status ---"
systemctl is-active squid && echo "ATIVO" || echo "INATIVO"
echo "--- Últimos erros ---"
tail -10 /var/log/squid/cache.log 2>/dev/null
echo "--- Reiniciando ---"
systemctl restart squid && echo "OK"
SQFEOF
chmod +x /usr/local/bin/squid-fix

# reload-gateway
cat > /usr/local/bin/reload-gateway << 'RLEOF'
#!/bin/bash
echo "Recarregando serviços..."
squid -k reconfigure 2>/dev/null && echo " ✔ Squid" || echo " ✘ Squid"
systemctl reload named 2>/dev/null && echo " ✔ DNS" || echo " ✘ DNS"
systemctl reload nginx 2>/dev/null && echo " ✔ Nginx" || echo " ✘ Nginx"
echo "Pronto."
RLEOF
chmod +x /usr/local/bin/reload-gateway
ok "Ferramentas CLI instaladas"

# =============================================================================
# PASSO 10 — CRON (transições de horário)
# =============================================================================
hdr "10. CRON"
cat > /etc/cron.d/gateway-horarios << CRONEOF
# Gateway CDPNI — revalidar ACLs nas transições de horário (seg-sex)
0  7 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0  8 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 11 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 13 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 17 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 18 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 19 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 23 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
CRONEOF
ok "Cron configurado"


# =============================================================================
# PASSO 12 — PAINEL WEB (Flask — porta 5000)
# =============================================================================
hdr "12. PAINEL WEB DE ADMINISTRAÇÃO"

# Recarregar config atualizada
source /etc/gateway/config 2>/dev/null || true
PANEL_DIR="/opt/gateway-panel"
VENV="${PANEL_DIR}/venv"
GW_CONF="/etc/gateway"
LIST_DIR="/etc/squid/lists"
PORT="5000"

hdr "1. Dependências"
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
apt-get install -y python3 python3-pip python3-pam "python3${PY_VER}-venv" 2>/dev/null || \
    apt-get install -y python3 python3-pip python3-pam python3.13-venv 2>/dev/null || true
mkdir -p "${PANEL_DIR}"
if [[ ! -d "${VENV}" ]]; then
    python3 -m venv --system-site-packages "${VENV}" 2>/dev/null &&         ok "Venv criado com system-site-packages" || {
        warn "Falhou com system-site-packages — instalando python3-venv específico..."
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
        apt-get install -y "python3${PY_VER}-venv" 2>/dev/null ||             apt-get install -y python3.13-venv 2>/dev/null || true
        python3 -m venv --system-site-packages "${VENV}" 2>/dev/null ||             python3 -m venv "${VENV}"
    }
else
    ok "Venv existente mantido"
fi
"${VENV}/bin/pip" install --quiet flask 2>/dev/null || true
# Tentar instalar python-pam via pip como fallback adicional
"${VENV}/bin/pip" install --quiet python-pam 2>/dev/null || true
# PAM: autenticação via usuário/senha do sistema Linux
# Adicionar grupo shadow para acessar /etc/shadow
SHADOW_GRP=""
for g in shadow _shadow; do getent group "$g" &>/dev/null && { SHADOW_GRP="$g"; break; }; done
[[ -z "$SHADOW_GRP" ]] && { groupadd shadow 2>/dev/null||true; SHADOW_GRP="shadow"; }
chmod g+r /etc/shadow 2>/dev/null || true
chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true
# Serviço roda como root, mas garantir que pam pode ser usado
cat > /etc/pam.d/gateway-panel << 'PAMEOF'
auth    required   pam_unix.so
account required   pam_unix.so
PAMEOF
# Verificar se python3-pam está acessível no venv
"${VENV}/bin/python3" -c "import pam" 2>/dev/null && ok "pam acessível no venv" || {
    warn "pam não encontrado no venv — copiando do sistema..."
    PAM_FILE=$(python3 -c "import pam; print(pam.__file__)" 2>/dev/null || true)
    SITE_PKG=$("${VENV}/bin/python3" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
    if [[ -n "$PAM_FILE" && -n "$SITE_PKG" ]]; then
        cp "$PAM_FILE" "$SITE_PKG/" 2>/dev/null && ok "pam copiado para venv" || true
        # Copiar também _pam se existir
        PAM_SO=$(find /usr/lib/python3 -name "_pam*.so" 2>/dev/null | head -1)
        [[ -n "$PAM_SO" ]] && cp "$PAM_SO" "$SITE_PKG/" 2>/dev/null || true
    fi
    # Tentar novamente
    "${VENV}/bin/python3" -c "import pam" 2>/dev/null && ok "pam OK após cópia" ||         warn "pam ainda não disponível — verificar python3-pam instalado"
}

hdr "2. Criando app.py"
cat > "${PANEL_DIR}/app.py" << 'PYEOF'
#!/usr/bin/env python3
"""Gateway CDPNI — Painel v1.0"""
import os, re, subprocess, json
from functools import wraps
from pathlib import Path
from flask import Flask, request, session, redirect, url_for, render_template_string, jsonify

app = Flask(__name__)
# Chave secreta persistente (não muda ao reiniciar o serviço)
_key_file = Path("/etc/gateway/panel_secret")
if _key_file.exists():
    app.secret_key = _key_file.read_bytes()
else:
    _key = os.urandom(64)
    _key_file.write_bytes(_key)
    _key_file.chmod(0o600)
    app.secret_key = _key

app.config["PERMANENT_SESSION_LIFETIME"] = 28800  # 8 horas
app.config["SESSION_COOKIE_HTTPONLY"]    = True    # JS não acessa o cookie
app.config["SESSION_COOKIE_SAMESITE"]   = "Lax"   # Proteção CSRF

GW_CONF  = Path("/etc/gateway")
LIST_DIR = Path("/etc/squid/lists")
SQUID_CONF = Path("/etc/squid/squid.conf")

try:
    import pam as _pam
except ImportError:
    try:
        import _pam
    except ImportError:
        class _pam:
            class pam:
                def authenticate(self, user, passwd, service=None):
                    import subprocess
                    nl = chr(10)
                    r = subprocess.run(['su', '-c', 'true', user],
                        input=passwd+nl, capture_output=True, text=True, timeout=5)
                    return r.returncode == 0
import time, hashlib, hmac
from collections import defaultdict

# Usuários autorizados a acessar o painel (deve ser admin do sistema)
ALLOWED_USERS = {"root", "jpfagiani", "rcborges", "sambadmin", "cpd", "supervisao"}

# Proteção brute-force: bloqueia IP após 5 tentativas em 5 minutos
_fail_log = defaultdict(list)   # {ip: [timestamps]}
_blocked   = {}                 # {ip: unblock_timestamp}
MAX_TRIES  = 5
WINDOW     = 300   # 5 minutos
BLOCK_TIME = 900   # 15 minutos bloqueado

def get_client_ip():
    return request.headers.get("X-Real-IP") or            request.headers.get("X-Forwarded-For","").split(",")[0].strip() or            request.remote_addr or "unknown"

def is_blocked(ip):
    if ip in _blocked:
        if time.time() < _blocked[ip]:
            return True
        else:
            del _blocked[ip]
            _fail_log.pop(ip, None)
    return False

def record_fail(ip):
    now = time.time()
    _fail_log[ip] = [t for t in _fail_log[ip] if now - t < WINDOW]
    _fail_log[ip].append(now)
    if len(_fail_log[ip]) >= MAX_TRIES:
        _blocked[ip] = now + BLOCK_TIME
        _fail_log.pop(ip, None)
        run(f"logger -t gateway-panel 'BLOQUEADO: {ip} após {MAX_TRIES} tentativas falhas'")
        return True
    return False

def record_ok(ip):
    _fail_log.pop(ip, None)
    _blocked.pop(ip, None)

def pam_auth(user, passwd):
    """Autentica via PAM — usa credenciais do sistema Linux."""
    if not user or not passwd: return False
    if user not in ALLOWED_USERS: return False
    try:
        p = _pam.pam()
        ok = p.authenticate(user, passwd, service="gateway-panel")
        if not ok:
            # Fallback serviço padrão
            p2 = _pam.pam()
            ok = p2.authenticate(user, passwd)
        return ok
    except Exception:
        return False

def auth_required(f):
    @wraps(f)
    def d(*a, **k):
        if not session.get("auth"):
            return redirect(url_for("login"))
        # Verificar se a sessão expirou (8 horas)
        last = session.get("last_activity", 0)
        if time.time() - last > 28800:
            session.clear()
            return redirect(url_for("login"))
        session["last_activity"] = time.time()
        return f(*a, **k)
    return d

def run(cmd, t=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t)
        return r.stdout.strip(), r.stderr.strip(), r.returncode
    except Exception as e:
        return "", str(e), 1

def svc_ok(name):
    _, _, rc = run(f"systemctl is-active {name}")
    return rc == 0

def read_list(name):
    for ext in [".acl", ".conf"]:
        p = LIST_DIR / f"{name}{ext}"
        if p.exists():
            return [l.strip() for l in p.read_text().splitlines() if l.strip() and not l.startswith("#")]
    return []

def write_list(name, lines):
    p = LIST_DIR / f"{name}.acl"
    if not p.exists(): p = LIST_DIR / f"{name}.conf"
    p.write_text("\n".join(lines) + "\n")

def squid_reload():
    _, _, rc = run("squid -k reconfigure")
    return rc == 0

CSS = """
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
:root{--bg:#0f1923;--bg2:#162030;--bg3:#1c2d3f;--bd:#2a3f52;--ac:#3b82f6;--acb:#1e3a5f;
  --tx:#e2e8f0;--txs:#94a3b8;--txm:#64748b;--gn:#22c55e;--gnb:#14532d;
  --rd:#ef4444;--rdb:#450a0a;--am:#f59e0b;--amb:#451a03}
body{background:var(--bg);color:var(--tx);height:100vh;display:flex;flex-direction:column;overflow:hidden}
a{color:inherit;text-decoration:none}
.tb{background:var(--bg2);border-bottom:1px solid var(--bd);height:48px;padding:0 20px;
    display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.tb-brand{display:flex;align-items:center;gap:10px;font-size:13px;font-weight:500}
.tb-user{display:flex;align-items:center;gap:5px;background:rgba(59,130,246,.15);border:1px solid rgba(59,130,246,.3);border-radius:20px;padding:3px 10px;font-size:11px;color:#93c5fd}
.tb-brand i{font-size:20px;color:var(--ac)}
.tb-right{display:flex;gap:8px}
.tb-btn{display:flex;align-items:center;gap:4px;padding:5px 11px;border:1px solid var(--bd);
        border-radius:6px;font-size:11px;color:var(--txs);cursor:pointer;background:transparent}
.tb-btn:hover{background:var(--bg3)}
.layout{display:flex;flex:1;overflow:hidden}
.sb{width:210px;background:var(--bg2);border-right:1px solid var(--bd);padding:8px 0;overflow-y:auto;flex-shrink:0}
.ns{font-size:9px;font-weight:600;color:var(--txm);text-transform:uppercase;letter-spacing:1px;padding:12px 16px 5px}
.ni{display:flex;align-items:center;gap:9px;padding:8px 16px;color:var(--txs);cursor:pointer;
    border-left:2px solid transparent;font-size:12px}
.ni:hover{background:var(--bg3)}
.ni.on{background:var(--acb);border-left-color:var(--ac);color:#fff;font-weight:500}
.ni i{font-size:13px}
.main{flex:1;padding:20px;overflow-y:auto;background:var(--bg)}
.pt{font-size:15px;font-weight:500;margin-bottom:16px;display:flex;align-items:center;gap:8px}
.pt i{font-size:18px;color:var(--ac)}
.card{background:var(--bg2);border:1px solid var(--bd);border-radius:10px;padding:16px;margin-bottom:14px}
.ct{font-size:10px;font-weight:500;color:var(--txs);text-transform:uppercase;letter-spacing:.6px;
    margin-bottom:12px;display:flex;align-items:center;justify-content:space-between}
.ct span{display:flex;align-items:center;gap:6px}
.g3{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}
.g2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.stat{background:var(--bg3);border:1px solid var(--bd);border-radius:8px;padding:12px}
.sl{font-size:9px;color:var(--txm);text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
.badge{display:inline-flex;align-items:center;gap:4px;padding:3px 9px;border-radius:20px;font-size:10px;font-weight:500}
.bon{background:var(--gnb);color:var(--gn)}.boff{background:var(--rdb);color:var(--rd)}
.bwarn{background:var(--amb);color:var(--am)}
.dot{width:6px;height:6px;border-radius:50%;display:inline-block;margin-right:2px}
.don{background:var(--gn)}.doff{background:var(--rd)}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:var(--bg3);padding:7px 10px;text-align:left;font-size:10px;font-weight:500;
   color:var(--txm);text-transform:uppercase;border-bottom:1px solid var(--bd)}
td{padding:7px 10px;border-bottom:1px solid var(--bd);vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--bg3)}
.btn{display:inline-flex;align-items:center;gap:4px;padding:6px 12px;border-radius:6px;font-size:11px;
     cursor:pointer;border:1px solid var(--bd);background:var(--bg3);color:var(--txs);font-family:inherit}
.btn:hover{background:var(--bd)}
.bp{background:var(--ac);border-color:var(--ac);color:#fff}.bp:hover{background:#2563eb}
.bg{background:var(--gnb);border-color:var(--gn);color:var(--gn)}
.br{background:var(--rdb);border-color:var(--rd);color:var(--rd)}
.bs{padding:3px 8px;font-size:10px}
input,textarea,select{width:100%;border:1px solid var(--bd);border-radius:6px;padding:8px 10px;
    font-size:12px;color:var(--tx);background:var(--bg3);font-family:inherit;outline:none}
input:focus,textarea:focus{border-color:var(--ac)}
label{display:block;font-size:11px;font-weight:500;color:var(--txs);margin:10px 0 4px}
pre{background:var(--bg3);border:1px solid var(--bd);border-radius:6px;padding:10px;
    font-size:10px;color:var(--txs);overflow:auto;max-height:250px;white-space:pre-wrap}
.mono{font-family:monospace;font-size:10px;color:var(--txs)}
.tag{display:inline-flex;align-items:center;gap:3px;background:var(--acb);border:1px solid var(--bd);
     border-radius:4px;padding:2px 7px;font-size:11px;color:var(--ac);margin:2px}
.tag button{background:none;border:none;color:var(--rd);cursor:pointer;font-size:12px;padding:0;line-height:1}
.ip-wrap{display:flex;flex-wrap:wrap;min-height:36px;background:var(--bg3);border:1px solid var(--bd);
         border-radius:6px;padding:4px 6px;gap:2px;cursor:text;align-items:center}
.ip-wrap input{border:none;outline:none;padding:2px 4px;min-width:130px;flex:1;background:transparent}
.tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
.tab{padding:5px 12px;border-radius:6px;font-size:11px;cursor:pointer;border:1px solid var(--bd);
     background:var(--bg3);color:var(--txs)}
.tab.on{background:var(--ac);border-color:var(--ac);color:#fff}
.hbar{display:flex;gap:8px;align-items:center;margin-bottom:10px}
.hbar input{flex:1}
.pg{display:none}.pg.on{display:block}
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:900;display:flex;
          align-items:center;justify-content:center;padding:16px}
.modal{background:var(--bg2);border:1px solid var(--bd);border-radius:10px;padding:24px;
       width:460px;max-width:100%;max-height:90vh;overflow-y:auto}
.modal h3{font-size:14px;font-weight:500;margin-bottom:14px}
.mf{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
.mf button{padding:7px 16px;border-radius:6px;font-size:12px;cursor:pointer;border:none;font-family:inherit}
.mc{background:var(--bg3);color:var(--txs)}.mo{background:var(--ac);color:#fff}
.alert{padding:10px 14px;border-radius:6px;font-size:12px;margin-bottom:12px;border:1px solid}
.aok{background:var(--gnb);color:var(--gn);border-color:var(--gn)}
.aerr{background:var(--rdb);color:var(--rd);border-color:var(--rd)}
#toast{position:fixed;bottom:20px;right:20px;z-index:999;display:flex;flex-direction:column;gap:6px}
.ti{padding:10px 14px;border-radius:8px;font-size:12px;min-width:220px;background:var(--bg2);
    border:1px solid var(--bd);animation:si .2s ease}
.ti.ok{border-left:3px solid var(--gn);color:var(--gn)}
.ti.err{border-left:3px solid var(--rd);color:var(--rd)}
.ti.warn{border-left:3px solid var(--am);color:var(--am)}
@keyframes si{from{transform:translateX(20px);opacity:0}to{opacity:1}}
"""

BASE = r"""<!DOCTYPE html><html lang="pt-BR"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gateway CDPNI — Painel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>{{ css }}</style></head><body>
{% if logged %}
<div class="tb">
  <div class="tb-brand"><i class="ti ti-router"></i>Gateway CDPNI — Painel</div>
  <div class="tb-right">
    <a href="https://192.168.0.11" target="_blank" class="tb-btn"><i class="ti ti-external-link"></i>Portal Arquivos</a>
    <span class="tb-user"><i class="ti ti-user-circle" style="font-size:13px"></i>{{ session.get("user","root") }}</span>
    <a href="/logout" class="tb-btn"><i class="ti ti-logout"></i>Sair</a>
  </div>
</div>
<div class="layout">
  <div class="sb">
    <div class="ns">Principal</div>
    <a href="/?p=dash"   class="ni {{ 'on' if p=='dash'   }}"><i class="ti ti-dashboard"></i>Dashboard</a>
    <a href="/?p=svc"    class="ni {{ 'on' if p=='svc'    }}"><i class="ti ti-settings-2"></i>Serviços</a>
    <div class="ns">Proxy / Squid</div>
    <a href="/?p=hor"    class="ni {{ 'on' if p=='hor'    }}"><i class="ti ti-clock"></i>Horários</a>
    <a href="/?p=ips"    class="ni {{ 'on' if p=='ips'    }}"><i class="ti ti-network"></i>Grupos de IPs</a>
    <a href="/?p=sites"  class="ni {{ 'on' if p=='sites'  }}"><i class="ti ti-world"></i>Listas de Sites</a>
    <div class="ns">Rede</div>
    <a href="/?p=nat"    class="ni {{ 'on' if p=='nat'    }}"><i class="ti ti-arrows-exchange"></i>NAT 1:1</a>
    <a href="/?p=dns"    class="ni {{ 'on' if p=='dns'    }}"><i class="ti ti-dns"></i>DNS</a>
    <div class="ns">Sistema</div>
    <a href="/?p=logs"   class="ni {{ 'on' if p=='logs'   }}"><i class="ti ti-file-text"></i>Logs</a>
    <a href="/?p=tools"  class="ni {{ 'on' if p=='tools'  }}"><i class="ti ti-tool"></i>Ferramentas</a>
    <a href="/?p=passwd" class="ni {{ 'on' if p=='passwd' }}"><i class="ti ti-key"></i>Senha</a>
  </div>
  <div class="main">
    {% if msg %}<div class="alert {{ 'aok' if mt=='ok' else 'aerr' }}">{{ msg }}</div>{% endif %}
    {{ content }}
  </div>
</div>
{% else %}
<div style="min-height:100vh;background:linear-gradient(135deg,#0a1628,#1c3557);display:flex;align-items:center;justify-content:center">
<div style="background:#162030;border:1px solid #2a3f52;border-radius:14px;padding:40px;width:380px;box-shadow:0 20px 60px rgba(0,0,0,.5)">
  <div style="text-align:center;margin-bottom:28px">
    <div style="width:64px;height:64px;background:#1e3a5f;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;margin-bottom:12px">
      <i class="ti ti-router" style="font-size:28px;color:#3b82f6"></i>
    </div>
    <h1 style="font-size:16px;font-weight:600;color:#e2e8f0">Gateway CDPNI</h1>
    <p style="font-size:12px;color:#64748b;margin-top:4px">Painel de Administração</p>
  </div>
  {% if error %}<div class="alert aerr" style="margin-bottom:12px">{{ error }}</div>{% endif %}
  <form method="post" action="/login">
    <label style="font-size:11px;color:#94a3b8;font-weight:500;display:block;margin-bottom:5px">Usuário</label>
    <input type="text" name="user" value="root" autocomplete="username" required
      style="width:100%;padding:11px 13px;font-size:14px;background:#1c2d3f;border:1px solid #2a3f52;border-radius:6px;color:#e2e8f0;font-family:inherit;outline:none;margin-bottom:10px">
    <label style="font-size:11px;color:#94a3b8;font-weight:500;display:block;margin-bottom:5px">Senha</label>
    <input type="password" name="pass" placeholder="••••••" autofocus required autocomplete="current-password"
      style="width:100%;padding:11px 13px;font-size:14px;background:#1c2d3f;border:1px solid #3b82f6;border-radius:6px;color:#e2e8f0;font-family:inherit;outline:none">
    <button type="submit" class="btn bp" style="width:100%;margin-top:16px;padding:11px;justify-content:center;font-size:13px">Entrar</button>
  </form>
  <p style="text-align:center;font-size:10px;color:#334155;margin-top:20px;line-height:1.5">
    Gateway Control Panel • Debian 13<br>
    <span style="color:#1e3a5f">Use as credenciais do sistema Linux</span>
  </p>
</div></div>
{% endif %}
<div id="toast"></div>
<script>
function toast(m,t='ok',ms=3000){const el=document.createElement('div');el.className=`ti ${t}`;el.textContent=m;document.getElementById('toast').appendChild(el);setTimeout(()=>el.remove(),ms);}
async function api(path,data,method='POST'){const r=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:data?JSON.stringify(data):undefined});return r.json();}
</script>
{{ scripts }}
</body></html>"""

def render(p, content, scripts="", msg="", mt="ok"):
    from flask import render_template_string as rts
    import datetime
    now = datetime.datetime.now()
    libre = now.weekday() >= 5
    if not libre:
        for line in SQUID_CONF.read_text().splitlines() if SQUID_CONF.exists() else []:
            m = re.search(r'acl h_livre time MTWHF (\d+):(\d+)-(\d+):(\d+)', line)
            if m:
                h1,m1,h2,m2 = int(m.group(1)),int(m.group(2)),int(m.group(3)),int(m.group(4))
                if h1*60+m1 <= now.hour*60+now.minute <= h2*60+m2: libre = True; break
    svcs = [{"n":"squid","ok":svc_ok("squid")},{"n":"named","ok":svc_ok("named")},
            {"n":"nftables","ok":svc_ok("nftables")},{"n":"nginx","ok":svc_ok("nginx")},
            {"n":"chrony","ok":svc_ok("chrony")},{"n":"fail2ban","ok":svc_ok("fail2ban")},
            {"n":"gateway-panel","ok":True}]
    return rts(BASE, css=CSS, logged=True, p=p, content=content, scripts=scripts,
               msg=msg, mt=mt, svcs=svcs, libre=libre, hora=now.strftime("%H:%M"))

@app.route("/login", methods=["GET","POST"])
def login():
    from flask import render_template_string as rts
    err = ""
    ip  = get_client_ip()

    if is_blocked(ip):
        remaining = int((_blocked.get(ip, 0) - time.time()) / 60) + 1
        err = f"IP bloqueado por tentativas excessivas. Aguarde {remaining} minuto(s)."
        return rts(BASE, css=CSS, logged=False, p="", content="", scripts="",
                   msg="", mt="ok", error=err, svcs=[], libre=False, hora=""), 429

    if request.method == "POST":
        user   = request.form.get("user","").strip().lower()
        passwd = request.form.get("pass","")

        # Delay fixo para dificultar timing attack
        time.sleep(0.4)

        if pam_auth(user, passwd):
            record_ok(ip)
            session.clear()
            session["auth"]          = True
            session["user"]          = user
            session["last_activity"] = time.time()
            session.permanent        = True
            run(f"logger -t gateway-panel 'LOGIN OK: usuario={user} ip={ip}'")
            return redirect("/")
        else:
            blocked = record_fail(ip)
            run(f"logger -t gateway-panel 'LOGIN FALHOU: usuario={user} ip={ip}'")
            if blocked:
                err = f"Muitas tentativas. IP bloqueado por 15 minutos."
            else:
                remaining_tries = MAX_TRIES - len(_fail_log.get(ip, []))
                err = f"Usuário ou senha inválidos. ({remaining_tries} tentativa(s) restante(s))"

    return rts(BASE, css=CSS, logged=False, p="", content="", scripts="",
               msg="", mt="ok", error=err, svcs=[], libre=False, hora="")

@app.route("/logout")
def logout():
    session.clear(); return redirect("/login")

@app.route("/")
@auth_required
def index():
    p = request.args.get("p","dash")
    msg = request.args.get("msg","")
    mt  = request.args.get("mt","ok")

    if p == "dash":
        ifaces, _, _ = run("ip -4 addr show | grep -E 'inet |^[0-9]' | grep -v 127")
        routes,  _, _ = run("ip route | head -6")
        content = f"""
<div class="pt"><i class="ti ti-dashboard"></i>Dashboard</div>
<div class="g3">
  <div class="stat"><div class="sl">Squid</div><span class="badge {'bon' if svc_ok('squid') else 'boff'}"><span class="dot {'don' if svc_ok('squid') else 'doff'}"></span>{'Ativo' if svc_ok('squid') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">DNS</div><span class="badge {'bon' if svc_ok('named') else 'boff'}"><span class="dot {'don' if svc_ok('named') else 'doff'}"></span>{'Ativo' if svc_ok('named') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">nftables</div><span class="badge {'bon' if svc_ok('nftables') else 'boff'}"><span class="dot {'don' if svc_ok('nftables') else 'doff'}"></span>{'Ativo' if svc_ok('nftables') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">Nginx</div><span class="badge {'bon' if svc_ok('nginx') else 'boff'}"><span class="dot {'don' if svc_ok('nginx') else 'doff'}"></span>{'Ativo' if svc_ok('nginx') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">Chrony</div><span class="badge {'bon' if svc_ok('chrony') else 'boff'}"><span class="dot {'don' if svc_ok('chrony') else 'doff'}"></span>{'Ativo' if svc_ok('chrony') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">Fail2ban</div><span class="badge {'bon' if svc_ok('fail2ban') else 'boff'}"><span class="dot {'don' if svc_ok('fail2ban') else 'doff'}"></span>{'Ativo' if svc_ok('fail2ban') else 'Inativo'}</span></div>
</div>
<div class="g2">
  <div class="card"><div class="ct"><span><i class="ti ti-network"></i>Interfaces</span></div><pre>{ifaces}</pre></div>
  <div class="card"><div class="ct"><span><i class="ti ti-route"></i>Rotas</span></div><pre>{routes}</pre></div>
</div>
<div class="card"><div class="ct"><span><i class="ti ti-clock"></i>Acesso agora</span></div>
  <span id="hst">Verificando...</span></div>"""
        scripts = """<script>fetch('/api/h_status').then(r=>r.json()).then(d=>{
  document.getElementById('hst').innerHTML=`<span class="badge ${d.ok?'bon':'bwarn'}">${d.ok?'Horário Livre':'Horário Restrito'}</span> <span style="color:var(--txs);font-size:11px">${d.hora} — ${d.msg}</span>`;});</script>"""

    elif p == "svc":
        svcs = [("squid","Proxy + SSL Bump"),("named","DNS (BIND9) — named.service"),
                ("nftables","Firewall/NAT"),("nginx","Web"),("chrony","NTP"),("fail2ban","Brute-force")]
        rows = "".join(f"""<tr><td><strong>{n}</strong></td>
          <td><span class="badge {'bon' if svc_ok(n) else 'boff'}">{'Ativo' if svc_ok(n) else 'Inativo'}</span></td>
          <td class="mono">{d}</td>
          <td style="text-align:right">
            <button class="btn bg bs" onclick="svcAct('restart','{n}')">↺ Reiniciar</button>
            <button class="btn bs" onclick="svcLog('{n}')">📋 Log</button>
          </td></tr>""" for n,d in svcs)
        content = f"""<div class="pt"><i class="ti ti-settings-2"></i>Serviços</div>
<div class="card"><table><thead><tr><th>Serviço</th><th>Status</th><th>Descrição</th><th></th></tr></thead>
<tbody>{rows}</tbody></table></div>
<div class="card" id="log-card" style="display:none"><div class="ct"><span id="log-title">Log</span>
<button class="btn bs" onclick="document.getElementById('log-card').style.display='none'">✕</button></div>
<pre id="log-pre"></pre></div>"""
        scripts = """<script>
async function svcAct(a,n){const r=await api('/api/svc',{action:a,name:n});toast(r.msg,r.ok?'ok':'err');if(r.ok)setTimeout(()=>location.reload(),1200);}
async function svcLog(n){const r=await api('/api/svc_log',{name:n});document.getElementById('log-title').textContent='Log — '+n;document.getElementById('log-pre').textContent=r.log||'(vazio)';document.getElementById('log-card').style.display='block';}
</script>"""

    elif p == "hor":
        horarios = []
        if SQUID_CONF.exists():
            for line in SQUID_CONF.read_text().splitlines():
                m = re.search(r'acl h_livre time MTWHF (\d+:\d+-\d+:\d+)', line)
                if m: horarios.append(m.group(1))
        htxt = "\n".join(horarios) or "07:00-08:00\n11:00-13:00\n17:00-18:00\n19:00-23:00"
        content = f"""<div class="pt"><i class="ti ti-clock"></i>Horários de Acesso</div>
<div class="card"><div class="ct"><span>Horários livres (seg-sex)</span>
<button class="btn bp" onclick="saveHor()">💾 Salvar e Aplicar</button></div>
<p style="font-size:11px;color:var(--txm);margin-bottom:10px">Fora desses horários, IPs restritos são bloqueados. Formato: HH:MM-HH:MM</p>
<textarea id="hor-txt" rows="8" style="font-family:monospace">{htxt}</textarea>
<div style="margin-top:8px;font-size:11px;color:var(--txm)">
  Sábado/domingo: sempre livre &nbsp;|&nbsp; Atual: <strong id="hstatus">—</strong>
</div></div>"""
        scripts = """<script>
fetch('/api/h_status').then(r=>r.json()).then(d=>{document.getElementById('hstatus').textContent=d.hora+' — '+(d.ok?'Livre':'Restrito');});
async function saveHor(){const r=await api('/api/horarios',{horarios:document.getElementById('hor-txt').value});toast(r.msg,r.ok?'ok':'err');}
</script>"""

    elif p == "ips":
        grupos = [
            ("ips_livres","IPs Livres","Acesso total à internet sem restrição de horário"),
            ("ips_parciais","IPs Parciais","Internet sempre; streaming/social bloqueado fora do horário"),
            ("ips_restritos","IPs Restritos","Só gov+bancos fora do horário; internet total no horário livre"),
        ]
        gdata = {n: read_list(n) for n,_,__ in grupos}
        cards = ""
        for name, label, desc in grupos:
            tags = "".join(f'<span class="tag">{ip}<button onclick="rmIp(\'{name}\',\'{ip}\')">×</button></span>' for ip in gdata[name])
            cards += f"""<div class="card"><div class="ct"><span>{label}</span>
<button class="btn bp" onclick="saveGrp('{name}')">💾 Salvar</button></div>
<p style="font-size:11px;color:var(--txm);margin-bottom:8px">{desc}</p>
<div class="ip-wrap" id="wrap-{name}" onclick="document.getElementById('inp-{name}').focus()">
{tags}<input id="inp-{name}" placeholder="Ex: 192.168.0.50 (Enter para adicionar)"
onkeydown="if(event.key==='Enter'){{addIp('{name}');event.preventDefault()}}">
</div></div>"""
        content = f'<div class="pt"><i class="ti ti-network"></i>Grupos de IPs</div>{cards}'
        scripts = f"""<script>
const D={json.dumps(gdata)};
function renderTags(n){{const w=document.getElementById('wrap-'+n);const inp=w.querySelector('input');w.innerHTML='';D[n].forEach(ip=>{{const s=document.createElement('span');s.className='tag';s.innerHTML=ip+'<button onclick="rmIp(\\\''+n+'\\\',\\\''+ip+'\\\')">×</button>';w.appendChild(s);}});w.appendChild(inp);}}
function addIp(n){{const inp=document.getElementById('inp-'+n);const v=inp.value.trim().replace(/,$/,'');if(!v)return;if(!D[n].includes(v)){{D[n].push(v);renderTags(n);}}inp.value='';}}
function rmIp(n,ip){{D[n]=D[n].filter(x=>x!==ip);renderTags(n);}}
async function saveGrp(n){{addIp(n);const r=await api('/api/ips',{{name:n,ips:D[n]}});toast(r.msg,r.ok?'ok':'err');}}
</script>"""

    elif p == "sites":
        tabs = [
            ("sites_governo","Governo","Sites gov sempre liberados"),
            ("sites_liberados","Liberados","Sempre acessíveis para todos"),
            ("sites_bloqueados","Bloqueados","Bloqueados para todos, sempre"),
            ("ssl_nobump","SSL NoBump","Sem interceptação SSL"),
        ]
        tab_btns_parts = []
        for i,(n,l,_) in enumerate(tabs):
            active = "on" if i==0 else ""
            tab_btns_parts.append(f'<button class="tab {active}" data-t="{n}" onclick="swTab(\'{n}\')">{l}</button>')
        tab_btns = "".join(tab_btns_parts)
        panels_parts = []
        for pi,(n,l,d) in enumerate(tabs):
            disp = "block" if pi==0 else "none"
            cnt = chr(10).join(read_list(n))
            p1 = '<div id="tp-' + n + '" style="display:' + disp + '">' 
            p2 = '<div class="card"><div class="ct"><span>' + l + " - " + d + '</span>'
            p3 = '<button class="btn bp" onclick="saveTab(\'\'\'\'\\\'\'\'\'\')">' + chr(128190) + ' Salvar</button></div>'
            p4 = '<textarea id="txt-' + n + '" rows="10" style="font-family:monospace;font-size:11px">' + cnt + '</textarea></div></div>'
            panels_parts.append((p1+p2+p3+p4).replace("\'\'\'\'\\\'\'\'\'\'", n))
        panels = "".join(panels_parts)
        content = f'<div class="pt"><i class="ti ti-world"></i>Listas de Sites</div><div class="tabs">{tab_btns}</div>{panels}'
        scripts = """<script>
function swTab(n){document.querySelectorAll('[id^="tp-"]').forEach(el=>el.style.display='none');document.getElementById('tp-'+n).style.display='block';document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('on',t.dataset.t===n));}
async function saveTab(n){const r=await api('/api/sites',{name:n,content:document.getElementById('txt-'+n).value});toast(r.msg,r.ok?'ok':'err');}
</script>"""

    elif p == "nat":
        out, _, _ = run("cat /etc/gateway/nat_entries.conf 2>/dev/null")
        entries = []
        for line in out.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    entries.append({"int":parts[0],"ext":parts[1],"desc":parts[2] if len(parts)>2 else ""})
        rows = "".join(f'<tr><td class="mono">{e["int"]}</td><td class="mono">{e["ext"]}</td><td style="color:var(--txs)">{e["desc"]}</td><td style="text-align:right"><button class="btn br bs" onclick="delNat(\'{e["int"]}\')">Remover</button></td></tr>' for e in entries)
        content = f"""<div class="pt"><i class="ti ti-arrows-exchange"></i>NAT 1:1</div>
<div class="card"><div class="ct"><span>Entradas ativas</span><button class="btn bp" onclick="document.getElementById('natm').style.display='flex'">+ Adicionar</button></div>
<table><thead><tr><th>IP Interno</th><th>IP Externo</th><th>Descrição</th><th></th></tr></thead>
<tbody>{rows or '<tr><td colspan="4" style="text-align:center;color:var(--txm);padding:16px">Nenhuma entrada</td></tr>'}</tbody></table></div>
<div id="natm" class="modal-bg" style="display:none"><div class="modal"><h3>Adicionar NAT 1:1</h3>
<label>IP Interno</label><input id="ni" placeholder="192.168.0.50">
<label>IP Externo (vazio = automático)</label><input id="ne" placeholder="10.14.29.50">
<label>Descrição</label><input id="nd" placeholder="Ex: Servidor Web">
<div class="mf"><button class="mc" onclick="document.getElementById('natm').style.display='none'">Cancelar</button>
<button class="mo" onclick="addNat()">Adicionar</button></div></div></div>"""
        scripts = """<script>
async function addNat(){const r=await api('/api/nat',{action:'add',int:document.getElementById('ni').value,ext:document.getElementById('ne').value,desc:document.getElementById('nd').value});toast(r.msg,r.ok?'ok':'err');if(r.ok)setTimeout(()=>location.reload(),1200);}
async function delNat(ip){if(!confirm('Remover NAT para '+ip+'?'))return;const r=await api('/api/nat',{action:'del',int:ip});toast(r.msg,r.ok?'ok':'err');if(r.ok)setTimeout(()=>location.reload(),1200);}
</script>"""

    elif p == "dns":
        zones = []
        lconf = Path("/etc/bind/named.conf.local")
        if lconf.exists():
            import re as _re
            for m in _re.finditer(r'zone "([^"]+)"[^{]*\{[^}]*file "([^"]+)"', lconf.read_text()):
                zn, zf = m.group(1), m.group(2)
                _, _, rc = run(f"named-checkzone {zn} {zf} 2>/dev/null")
                zones.append((zn, zf, rc==0))
        rows = "".join(f'<tr><td class="mono">{z}</td><td class="mono" style="color:var(--txm)">{f}</td><td><span class="badge {"bon" if ok else "boff"}">{("OK" if ok else "Erro")}</span></td></tr>' for z,f,ok in zones)
        content = f"""<div class="pt"><i class="ti ti-dns"></i>DNS</div>
<div class="card"><div class="ct"><span>Testar resolução</span></div>
<div class="hbar"><input id="dns-h" placeholder="Ex: new.cartoriosap.sp.gov.br"><button class="btn bp" onclick="testDns()">Testar</button></div>
<pre id="dns-out" style="min-height:50px">—</pre></div>
<div class="card"><div class="ct"><span>Zonas configuradas</span></div>
<table><thead><tr><th>Zona</th><th>Arquivo</th><th>Status</th></tr></thead><tbody>{rows}</tbody></table></div>"""
        scripts = """<script>
async function testDns(){const h=document.getElementById('dns-h').value.trim();if(!h)return;document.getElementById('dns-out').textContent='Resolvendo...';const r=await api('/api/dns',{host:h});document.getElementById('dns-out').textContent=r.out||r.err||'Sem resposta';}
</script>"""

    elif p == "logs":
        content = """<div class="pt"><i class="ti ti-file-text"></i>Logs</div>
<div class="tabs">
  <button class="tab on" data-l="squid" onclick="loadLog('squid')">Squid</button>
  <button class="tab" data-l="squid_cache" onclick="loadLog('squid_cache')">Squid Cache</button>
  <button class="tab" data-l="named" onclick="loadLog('named')">DNS</button>
  <button class="tab" data-l="nft" onclick="loadLog('nft')">Firewall</button>
</div>
<div class="card"><div class="ct"><span id="log-t">Squid — últimas 100 linhas</span>
<button class="btn bs" onclick="loadLog(curLog)">↺ Atualizar</button></div>
<pre id="log-out" style="max-height:350px">Carregando...</pre></div>"""
        scripts = """<script>
let curLog='squid';
async function loadLog(n){curLog=n;document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('on',t.dataset.l===n));document.getElementById('log-t').textContent=n+' — últimas 100 linhas';document.getElementById('log-out').textContent='Carregando...';const r=await api('/api/log',{name:n});const el=document.getElementById('log-out');el.textContent=r.log||'(vazio)';el.scrollTop=el.scrollHeight;}
loadLog('squid');
</script>"""

    elif p == "tools":
        tools = [("squid_reconfigure","↺ Recarregar Squid","bg"),("reload_dns","↺ Recarregar DNS","bg"),
                 ("reload_nginx","↺ Recarregar Nginx","bg"),("squid_fix","🔧 squid-fix",""),
                 ("gateway_status","📊 gateway-status",""),("restart_squid","⚠ Reiniciar Squid","br")]
        btns = "".join(f'<button class="btn {c}" style="justify-content:flex-start;margin-bottom:6px" onclick="runTool(\'{n}\')">{l}</button>' for n,l,c in tools)
        content = f"""<div class="pt"><i class="ti ti-tool"></i>Ferramentas</div>
<div class="g2">
  <div class="card"><div class="ct"><span>Ações</span></div>
  <div style="display:flex;flex-direction:column">{btns}</div></div>
  <div class="card"><div class="ct"><span>Resultado</span></div>
  <pre id="tool-out" style="min-height:200px;max-height:400px">—</pre></div>
</div>"""
        scripts = """<script>
async function runTool(n){document.getElementById('tool-out').textContent='Executando...';const r=await api('/api/tool',{name:n});document.getElementById('tool-out').textContent=r.out||r.err||'Concluído';}
</script>"""

    elif p == "passwd":
        content = """<div class="pt"><i class="ti ti-key"></i>Senha do Painel</div>
<div class="card" style="max-width:380px">
<label>Senha atual</label><input type="password" id="co">
<label>Nova senha</label><input type="password" id="cn">
<label>Confirmar</label><input type="password" id="cn2">
<button class="btn bp" style="margin-top:14px;width:100%;justify-content:center" onclick="chgPass()">Salvar senha</button></div>"""
        scripts = """<script>
async function chgPass(){const o=document.getElementById('co').value,n=document.getElementById('cn').value,n2=document.getElementById('cn2').value;if(n!==n2){toast('Senhas não coincidem','err');return;}if(n.length<4){toast('Senha muito curta','err');return;}const r=await api('/api/passwd',{old:o,new:n});toast(r.msg,r.ok?'ok':'err');}
</script>"""
    else:
        content = '<div class="pt">Página não encontrada</div>'
        scripts = ""

    return render(p, content, scripts, msg, mt)

# ── API ────────────────────────────────────────────────────────────────────
@app.route("/api/h_status", methods=["POST"])
@auth_required
def api_h():
    import datetime
    now = datetime.datetime.now()
    livre = now.weekday() >= 5
    msg = "Final de semana — livre" if livre else ""
    if not livre and SQUID_CONF.exists():
        for line in SQUID_CONF.read_text().splitlines():
            m = re.search(r'acl h_livre time MTWHF (\d+):(\d+)-(\d+):(\d+)', line)
            if m:
                h1,m1,h2,m2 = int(m.group(1)),int(m.group(2)),int(m.group(3)),int(m.group(4))
                if h1*60+m1 <= now.hour*60+now.minute <= h2*60+m2:
                    livre = True; msg = f"Livre até {h2:02d}:{m2:02d}"; break
    if not livre: msg = "Acesso restrito"
    return jsonify(ok=livre, hora=now.strftime("%H:%M"), msg=msg)

@app.route("/api/svc", methods=["POST"])
@auth_required
def api_svc():
    d = request.json; n = d.get("name"); a = d.get("action")
    allowed = ["squid","named","nftables","nginx","chrony","fail2ban","gateway-panel"]
    if n not in allowed: return jsonify(ok=False, msg="Não permitido")
    out, err, rc = run(f"systemctl {'restart' if a=='restart' else 'reload'} {n} 2>/dev/null || systemctl restart {n}")
    return jsonify(ok=rc==0, msg=f"{n} {'reiniciado' if a=='restart' else 'recarregado'}" if rc==0 else f"Erro: {err[:80]}")

@app.route("/api/svc_log", methods=["POST"])
@auth_required
def api_svc_log():
    n = request.json.get("name","")
    out, _, _ = run(f"journalctl -u {n} --no-pager -n 60 --output=short 2>/dev/null")
    return jsonify(log=out)

@app.route("/api/horarios", methods=["POST"])
@auth_required
def api_horarios():
    if not SQUID_CONF.exists(): return jsonify(ok=False, msg="squid.conf não encontrado")
    lines = request.json.get("horarios","").strip().splitlines()
    content = SQUID_CONF.read_text()
    new_lines = [l for l in content.splitlines() if not re.match(r'acl h_livre time MTWHF', l)]
    idx = next((i for i,l in enumerate(new_lines) if "time SA" in l), len(new_lines))
    new_acls = [f"acl h_livre time MTWHF {h.strip()}" for h in lines if h.strip()]
    new_lines[idx:idx] = new_acls
    SQUID_CONF.write_text("\n".join(new_lines))
    return jsonify(ok=squid_reload(), msg="Horários salvos e Squid recarregado" if squid_reload() else "Salvo — Squid recarregue manualmente")

@app.route("/api/ips", methods=["POST"])
@auth_required
def api_ips():
    d = request.json; n = d.get("name"); ips = d.get("ips",[])
    if n not in ["ips_livres","ips_parciais","ips_restritos"]: return jsonify(ok=False, msg="Inválido")
    write_list(n, ips); squid_reload()
    return jsonify(ok=True, msg=f"{n} salvo")

@app.route("/api/sites", methods=["POST"])
@auth_required
def api_sites():
    d = request.json; n = d.get("name"); content = d.get("content","")
    if n not in ["sites_governo","sites_liberados","sites_bloqueados","ssl_nobump"]: return jsonify(ok=False, msg="Inválido")
    p = LIST_DIR / f"{n}.acl"
    if not p.exists(): p = LIST_DIR / f"{n}.conf"
    p.write_text(content); squid_reload()
    return jsonify(ok=True, msg=f"{n} salvo e Squid recarregado")

@app.route("/api/nat", methods=["POST"])
@auth_required
def api_nat():
    d = request.json; action = d.get("action")
    if action == "add":
        ip_i = d.get("int","").strip(); ip_e = d.get("ext","").strip() or None; desc = d.get("desc","")
        if not ip_i: return jsonify(ok=False, msg="IP interno obrigatório")
        out, err, rc = run(f"nat-manager add {ip_i}{' '+ip_e if ip_e else ''} '{desc}'")
        return jsonify(ok=rc==0, msg=out or err or f"NAT {ip_i} adicionado")
    elif action == "del":
        out, err, rc = run(f"nat-manager del {d.get('int','')}")
        return jsonify(ok=rc==0, msg=out or err)
    return jsonify(ok=False, msg="Ação inválida")

@app.route("/api/dns", methods=["POST"])
@auth_required
def api_dns():
    h = request.json.get("host","").strip()
    if not h: return jsonify(err="Host inválido")
    out, err, _ = run(f"host {h} 127.0.0.1 2>&1 | head -6")
    return jsonify(out=out or err)

@app.route("/api/log", methods=["POST"])
@auth_required
def api_log():
    n = request.json.get("name","squid")
    cmds = {"squid":"tail -100 /var/log/squid/access.log 2>/dev/null",
            "squid_cache":"tail -100 /var/log/squid/cache.log 2>/dev/null",
            "named":"journalctl -u named --no-pager -n 80 2>/dev/null || journalctl -u bind9 --no-pager -n 80 2>/dev/null",
            "nft":"journalctl -k --no-pager -n 80 2>/dev/null | tail -80"}
    if n not in cmds: return jsonify(log="Log inválido")
    out, _, _ = run(cmds[n])
    return jsonify(log=out or "(sem dados)")

@app.route("/api/tool", methods=["POST"])
@auth_required
def api_tool():
    n = request.json.get("name","")
    tools = {"squid_reconfigure":"squid -k reconfigure 2>&1 && echo OK",
             "reload_dns":"systemctl reload named 2>/dev/null && echo OK",
             "reload_nginx":"nginx -t && systemctl reload nginx && echo OK",
             "restart_squid":"systemctl restart squid && echo OK",
             "squid_fix":"squid-fix 2>&1 | tail -40",
             "gateway_status":"gateway-status 2>&1"}
    if n not in tools: return jsonify(err="Inválido")
    out, err, rc = run(tools[n], t=30)
    return jsonify(ok=rc==0, out=out or err)

@app.route("/api/passwd", methods=["POST"])
@auth_required
def api_passwd():
    d = request.json
    if d.get("old") != get_pass(): return jsonify(ok=False, msg="Senha atual incorreta")
    if len(d.get("new","")) < 4: return jsonify(ok=False, msg="Senha muito curta")
    p = GW_CONF / "panel_pass"; p.write_text(d["new"]); p.chmod(0o600)
    return jsonify(ok=True, msg="Senha alterada")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
PYEOF

chmod 750 "${PANEL_DIR}/app.py"

hdr "3. Serviço systemd"
cat > /etc/systemd/system/gateway-panel.service << SVCEOF
[Unit]
Description=Gateway CDPNI — Painel Web v1.0
After=network.target

[Service]
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${VENV}/bin/python ${PANEL_DIR}/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

# Liberar porta 5000
source /etc/gateway/config 2>/dev/null || NET_INT="192.168.0.0/24"
nft add rule inet filter input ip saddr ${NET_INT} tcp dport 5000 ct state new accept 2>/dev/null || true
nft list ruleset > /etc/nftables.conf 2>/dev/null || true

systemctl daemon-reload
systemctl enable gateway-panel
systemctl restart gateway-panel
sleep 3

if systemctl is-active gateway-panel &>/dev/null; then
    ok "Painel ativo: http://${LAN_IP}:5000"
else
    warn "Painel não iniciou — verificando..."
    journalctl -u gateway-panel --no-pager -n 20
fi



# =============================================================================
# PASSO 11 — INICIAR SERVIÇOS
# =============================================================================
hdr "11. INICIANDO SERVIÇOS"
for svc in nftables chrony nginx fail2ban; do
    systemctl enable "$svc" 2>/dev/null || true
    systemctl restart "$svc" 2>/dev/null && ok "$svc iniciado" || warn "$svc falhou"
done

# BIND9/named — iniciar após validar config
if named-checkconf 2>/dev/null; then
    systemctl enable named 2>/dev/null || true
    systemctl restart named 2>/dev/null
    sleep 1
    systemctl is-active named 2>/dev/null && ok "named iniciado" || warn "named falhou"rn "named falhou — verificar: named-checkconf"
else
    warn "named.conf com erro — BIND9 não iniciado. Verifique: named-checkconf"
fi

# Squid — criar cache dir e iniciar com verificação prévia
squid -k parse 2>/dev/null && {
    # Criar e configurar diretório de cache com permissões corretas
    mkdir -p /var/cache/squid /var/log/squid /var/run/squid
    chown -R proxy:proxy /var/cache/squid /var/log/squid /var/run/squid 2>/dev/null ||         chown -R nobody:nogroup /var/cache/squid /var/log/squid /var/run/squid 2>/dev/null || true
    chmod 750 /var/cache/squid
    # Inicializar estrutura de cache (necessário antes do primeiro start)
    [[ ! -d "/var/cache/squid/00" ]] && {
        ok "Inicializando cache do Squid..."
        squid -z --foreground 2>/dev/null || squid -z 2>/dev/null || true
        sleep 2
    }
    systemctl enable squid 2>/dev/null || true
    systemctl restart squid 2>/dev/null && ok "squid iniciado" || {
        warn "squid falhou — verificando logs..."
        journalctl -u squid --no-pager -n 10 2>/dev/null || true
    }
} || warn "squid.conf com erros — corrija antes de iniciar: squid -k parse"

# =============================================================================
# RESUMO
# =============================================================================
echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${GRN}║   GATEWAY CDPNI v1.0 — INSTALAÇÃO CONCLUÍDA        ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Proxy     : ${LAN_IP}:${PROXY_PORT}                          ║${NC}"
echo -e "${BLD}${GRN}║  Painel    : http://${LAN_IP}:5000                          ║${NC}"
echo -e "${BLD}${GRN}║  Login     : root + senha do sistema Linux          ║${NC}"
echo -e "${BLD}${GRN}║  Segurança : PAM + bloqueio após 5 tentativas       ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  DNS       : ${LAN_IP}                                ║${NC}"
echo -e "${BLD}${GRN}║  CA cert   : http://${LAN_IP}/ca/cdpni-ca.crt         ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Próximos passos:                                   ║${NC}"
echo -e "${BLD}${GRN}║  1. sudo bash gw-panel-v1.sh   (painel web)         ║${NC}"
echo -e "${BLD}${GRN}║  2. Instalar CA nos clientes Windows                ║${NC}"
echo -e "${BLD}${GRN}║  3. Configurar proxy nos browsers: ${LAN_IP}:3128    ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Logs painel: journalctl -u gateway-panel -f        ║${NC}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════╝${NC}"