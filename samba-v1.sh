#!/bin/bash
# =============================================================================
# SERVIDOR SAMBA CDPNI — v1.0
# Debian 13 | RAID 5 | 33 compartilhamentos | PHP Panel 8443
# Execute como root: sudo bash samba-v1.sh
# =============================================================================
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GRN}[$(date '+%H:%M:%S')] ✔ $*${NC}"; }
warn()   { echo -e "${YLW}[$(date '+%H:%M:%S')] ⚠ $*${NC}"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}"; exit 1; }
header() { echo -e "\n${BLD}${CYN}══════════════════════════════${NC}";
           echo -e "${BLD}${CYN}  $*${NC}";
           echo -e "${BLD}${CYN}══════════════════════════════${NC}"; }
[[ $EUID -ne 0 ]] && error "Execute como root: sudo bash $0"

# ---------------------------------------------------------------------------
# CONFIGURAÇÕES
# ---------------------------------------------------------------------------
SAMBA_IP="192.168.0.11"
GATEWAY="192.168.0.1"
DNS_SERVER="192.168.0.1"
WORKGROUP="WORKGROUP"
SERVERNAME="CDPNI"
REALM="cdpni.local"
RAID_MOUNT="/mnt/raid"
RAID_DEVICE="/dev/md0"
SAMBA_ROOT="${RAID_MOUNT}/shares"
RECYCLE_DIR="${RAID_MOUNT}/recycle"
SSL_DIR="/etc/nginx/ssl"
PANEL_DIR="/var/www/samba-panel"
DEFAULT_PASS="1234"

# 33 compartilhamentos: "Pasta:grupo:visivel"
declare -a ALL_SHARES=(
    "Administrativo:grp_administrativo:yes"
    "Aevp:grp_aevp:yes"
    "Almoxarifado:grp_almoxarifado:yes"
    "Cadastro:grp_cadastro:yes"
    "Canil:grp_canil:yes"
    "Chefia_Turno_I:grp_chefia_1:yes"
    "Chefia_Turno_II:grp_chefia_2:yes"
    "Chefia_Turno_III:grp_chefia_3:yes"
    "Chefia_Turno_IV:grp_chefia_4:yes"
    "Cipa:grp_cipa:yes"
    "Conexao_Familiar:grp_conexao_familiar:yes"
    "CPD:grp_cpd:no"
    "csd:grp_csd:yes"
    "Diretoria_Geral:grp_diretoria:yes"
    "Educacao:grp_educacao:yes"
    "Financas:grp_financas:yes"
    "Inclusao:grp_inclusao:yes"
    "Infraestrutura:grp_infraestrutura:yes"
    "Nucleo_de_Pessoal:grp_nucleo_pessoal:yes"
    "Papel_de_Parede:grp_papel_parede:yes"
    "Planilhas:grp_planilhas:yes"
    "Portaria_Turno_I:grp_portaria:yes"
    "Portaria_Turno_II:grp_portaria:yes"
    "Portaria_Turno_III:grp_portaria:yes"
    "Portaria_Turno_IV:grp_portaria:yes"
    "Publico:grp_publico:yes"
    "Rol_de_Visitas:grp_rol_visitas:yes"
    "Saude:grp_saude:yes"
    "Scanner:grp_scanner:yes"
    "Simic:grp_simic:yes"
    "Sindicancia:grp_sindicancia:yes"
    "Supervisao:grp_supervisao:yes"
    "Chefia_Turno_Geral:grp_chefia_turno:yes"
)

declare -a ALL_GROUPS=(
    grp_administrativo grp_aevp grp_almoxarifado grp_cadastro grp_canil
    grp_chefia_1 grp_chefia_2 grp_chefia_3 grp_chefia_4 grp_chefia_turno
    grp_cipa grp_conexao_familiar grp_cpd grp_csd grp_diretoria
    grp_educacao grp_financas grp_inclusao grp_infraestrutura
    grp_nucleo_pessoal grp_papel_parede grp_planilhas grp_portaria
    grp_publico grp_rol_visitas grp_saude grp_scanner grp_simic
    grp_sindicancia grp_supervisao
)

ROOT_USERS="sambadmin jpfagiani rcborges cpd supervisao"

declare -a INITIAL_USERS=(
    "sambadmin:grp_administrativo"
    "jpfagiani:grp_administrativo"
    "rcborges:grp_administrativo"
    "cpd:grp_cpd"
    "supervisao:grp_supervisao"
    "chefia1:grp_chefia_1"
    "chefia2:grp_chefia_2"
    "chefia3:grp_chefia_3"
    "chefia4:grp_chefia_4"
    "simic:grp_simic"
    "cadastro:grp_cadastro"
    "csd:grp_csd"
    "adm:grp_administrativo"
    "aevp:grp_aevp"
    "almoxarifado:grp_almoxarifado"
    "canil:grp_canil"
    "cipa:grp_cipa"
    "conexao:grp_conexao_familiar"
    "dg:grp_diretoria"
    "educacao:grp_educacao"
    "financas:grp_financas"
    "inclusao:grp_inclusao"
    "infra:grp_infraestrutura"
    "npessoal:grp_nucleo_pessoal"
    "planilhas:grp_planilhas"
    "portaria:grp_portaria"
    "publico:grp_publico"
    "rol:grp_rol_visitas"
    "saude:grp_saude"
    "scanner:grp_scanner"
    "sindicancia:grp_sindicancia"
)

# ===========================================================================
# 1. PACOTES
# ===========================================================================
header "1. PACOTES"
apt-get update -qq
apt-get install -y \
    samba smbclient cifs-utils \
    mdadm smartmontools hdparm \
    nginx php8.3-fpm php8.3-cli php8.3-mbstring \
    python3 python3-venv python3-pip python3-pam acl \
    ufw fail2ban \
    sudo curl wget net-tools \
    2>/dev/null && log "Pacotes instalados"

PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
apt-get install -y "python3${PY_VER}-venv" 2>/dev/null || apt-get install -y python3.13-venv 2>/dev/null || true

# ===========================================================================
# 2. DETECÇÃO DE DISCOS E RAID
# ===========================================================================
header "2. DETECÇÃO DE DISCOS E CONFIGURAÇÃO RAID"

# ── 2a. Listar todos os discos ───────────────────────────────────────────────
info "Detectando discos no sistema..."
mapfile -t ALL_DISKS < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | sort)
[[ ${#ALL_DISKS[@]} -eq 0 ]] && error "Nenhum disco detectado. Verifique: lsblk"

# Identificar disco do sistema (onde está /)
_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
_PKNAME=$(lsblk -no PKNAME "$_SRC" 2>/dev/null | head -1 || true)
SYS_DISK="/dev/${_PKNAME:-$(basename "${_SRC:-/dev/sda}" | sed 's/[0-9]*$//')}"
info "Disco do sistema (SO): ${SYS_DISK}"

# ── 2b. Tabela completa dos discos ───────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║              DISCOS DETECTADOS NO SERVIDOR                          ║${NC}"
echo -e "${BOLD}${CYAN}╠═══════════╦══════════╦══════════════════════════╦═════════════════╣${NC}"
printf "${BOLD}${CYAN}║${NC} %-9s ${BOLD}${CYAN}║${NC} %-8s ${BOLD}${CYAN}║${NC} %-24s ${BOLD}${CYAN}║${NC} %-15s ${BOLD}${CYAN}║${NC}\n" \
    "DISCO" "TAMANHO" "MODELO" "STATUS"
echo -e "${BOLD}${CYAN}╠═══════════╬══════════╬══════════════════════════╬═════════════════╣${NC}"

RAID_CANDIDATES=()
declare -A DISK_SIZE
declare -A DISK_MODEL

for disk in "${ALL_DISKS[@]}"; do
    SIZE=$(lsblk -dno SIZE "$disk" 2>/dev/null || echo "?")
    MODEL=$(cat /sys/block/"$(basename "$disk")"/device/model 2>/dev/null | xargs 2>/dev/null || echo "N/D")
    ROTA=$(cat /sys/block/"$(basename "$disk")"/queue/rotational 2>/dev/null || echo "?")
    TYPE_HINT=$([[ "$ROTA" == "0" ]] && echo "SSD/NVMe" || echo "HDD")
    MPTS=$(lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' | head -1 || true)
    RAID_MEMBER=$(lsblk -no TYPE "$disk" 2>/dev/null | grep -q "raid" && echo "SIM" || echo "")

    DISK_SIZE[$disk]="$SIZE"
    DISK_MODEL[$disk]="${MODEL:0:24}"

    if [[ "$disk" == "$SYS_DISK" ]]; then
        STATUS="${YELLOW}SISTEMA (SO)${NC}"
    elif [[ -n "$RAID_MEMBER" ]]; then
        STATUS="${CYAN}RAID existente${NC}"
    elif [[ -n "$MPTS" ]]; then
        STATUS="${RED}Em uso (${MPTS})${NC}"
    else
        STATUS="${GREEN}Disponível${NC}"
        RAID_CANDIDATES+=("$disk")
    fi

    printf "${BOLD}${CYAN}║${NC} %-9s ${BOLD}${CYAN}║${NC} %-8s ${BOLD}${CYAN}║${NC} %-24s ${BOLD}${CYAN}║${NC} " \
        "$disk" "$SIZE" "${MODEL:0:24}"
    echo -e "${STATUS} ${BOLD}${CYAN}║${NC}"
done
echo -e "${BOLD}${CYAN}╚═══════════╩══════════╩══════════════════════════╩═════════════════╝${NC}"
echo ""

TOTAL_DISKS=${#ALL_DISKS[@]}
AVAIL_DISKS=${#RAID_CANDIDATES[@]}

echo -e "  Total de discos   : ${BOLD}${TOTAL_DISKS}${NC}"
echo -e "  Disco do sistema  : ${BOLD}${SYS_DISK}${NC}"
echo -e "  Disponíveis RAID  : ${BOLD}${AVAIL_DISKS}${NC}"
echo ""

# ── 2c. Verificar RAID existente ─────────────────────────────────────────────
if cat /proc/mdstat 2>/dev/null | grep -q "^md"; then
    echo -e "${YELLOW}⚠  RAID(s) já existentes detectados:${NC}"
    cat /proc/mdstat | grep -E "^md|blocks"
    echo ""
    echo -ne "${YELLOW}  Deseja recriar o RAID (APAGA TUDO) ou manter o existente? [recriar/manter, padrão: manter]: ${NC}"
    read -r RAID_ACTION; RAID_ACTION="${RAID_ACTION:-manter}"
    if [[ "${RAID_ACTION,,}" != "recriar" ]]; then
        log "RAID existente mantido."
        # Apenas garantir montagem
        if ! mountpoint -q "${RAID_MOUNT}" 2>/dev/null; then
            mkdir -p "${RAID_MOUNT}"
            mount "${RAID_DEVICE}" "${RAID_MOUNT}" 2>/dev/null && log "RAID montado em ${RAID_MOUNT}" || \
                warn "Não foi possível montar ${RAID_DEVICE} — verifique manualmente"
        else
            log "RAID já montado em ${RAID_MOUNT}"
        fi
        SKIP_RAID_CREATE=1
    else
        SKIP_RAID_CREATE=0
    fi
else
    SKIP_RAID_CREATE=0
fi

# ── 2d. Recomendação de RAID ──────────────────────────────────────────────────
if [[ "${SKIP_RAID_CREATE:-0}" == "0" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║           RECOMENDAÇÃO DE RAID PARA ${AVAIL_DISKS} DISCO(S) DISPONÍVEL(S)        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Calcular tamanho útil baseado no menor disco disponível
    SMALLEST_SIZE=""
    for disk in "${RAID_CANDIDATES[@]}"; do
        SZ=$(lsblk -dno SIZE "$disk" 2>/dev/null | tr -d ' ')
        [[ -z "$SMALLEST_SIZE" ]] && SMALLEST_SIZE="$SZ"
    done

    case "$AVAIL_DISKS" in
        0)
            echo -e "  ${RED}✘ Nenhum disco disponível para RAID.${NC}"
            echo -e "  ${YELLOW}  Remova discos em uso ou adicione novos discos.${NC}"
            error "Sem discos disponíveis para RAID"
            ;;
        1)
            echo -e "  ${YELLOW}⚠  Apenas 1 disco disponível — SEM REDUNDÂNCIA${NC}"
            echo ""
            echo -e "  ${BOLD}Opção disponível:${NC}"
            echo -e "  ${BOLD}[1]${NC} Sem RAID (disco único) — ${DISK_SIZE[${RAID_CANDIDATES[0]}]} úteis | ${RED}SEM proteção contra falha${NC}"
            echo ""
            echo -e "  ${YELLOW}  Recomendação: adicione pelo menos 2 discos para ter redundância.${NC}"
            echo -e "  ${CYAN}  Para RAID 5 (recomendado): adicione mais $(( 5 - AVAIL_DISKS )) disco(s).${NC}"
            echo ""
            echo -ne "  ${BOLD}Usar disco único sem RAID? [s/N]: ${NC}"
            read -r USE_SINGLE; [[ "${USE_SINGLE,,}" != "s" ]] && error "Adicione mais discos e execute novamente."
            RAID_LEVEL="none"
            ;;
        2)
            echo -e "  ${YELLOW}⚠  2 discos disponíveis — RAID 1 (espelho)${NC}"
            echo ""
            echo -e "  ${BOLD}[1]${NC} ${CYAN}RAID 1${NC}  — Espelho | Capacidade: ${SMALLEST_SIZE} | Tolera: 1 falha"
            echo -e "       Cada arquivo gravado nos 2 discos simultaneamente."
            echo ""
            echo -e "  ${YELLOW}  Para maior capacidade: adicione mais $(( 5 - AVAIL_DISKS )) disco(s) para RAID 5.${NC}"
            echo ""
            RAID_LEVEL="1"; RAID_NDISKS=2
            ;;
        3)
            echo -e "  ${CYAN}3 discos disponíveis — RAID 5 possível (mínimo)${NC}"
            echo ""
            echo -e "  ${BOLD}[1]${NC} ${GREEN}RAID 5${NC}  — Paridade | Capacidade: ~${SMALLEST_SIZE}×2 | Tolera: 1 falha ${GREEN}(recomendado)${NC}"
            echo -e "       2 discos de dados + 1 disco de paridade."
            echo -e "  ${BOLD}[2]${NC} ${CYAN}RAID 1${NC}  — Espelho (usa só 2 discos) | Capacidade: ${SMALLEST_SIZE} | Tolera: 1 falha"
            echo ""
            echo -e "  ${YELLOW}  Para máxima capacidade: adicione mais $(( 5 - AVAIL_DISKS )) disco(s) para RAID 5 com 5 discos.${NC}"
            echo ""
            echo -ne "  ${BOLD}Escolha [1/2, padrão: 1]: ${NC}"
            read -r RCHOICE; RCHOICE="${RCHOICE:-1}"
            [[ "$RCHOICE" == "2" ]] && { RAID_LEVEL="1"; RAID_NDISKS=2; } || { RAID_LEVEL="5"; RAID_NDISKS=3; }
            ;;
        4)
            echo -e "  ${CYAN}4 discos disponíveis${NC}"
            echo ""
            echo -e "  ${BOLD}[1]${NC} ${GREEN}RAID 5${NC}  — 4 discos | Capacidade: ~${SMALLEST_SIZE}×3 | Tolera: 1 falha ${GREEN}(recomendado)${NC}"
            echo -e "  ${BOLD}[2]${NC} ${CYAN}RAID 6${NC}  — 4 discos | Capacidade: ~${SMALLEST_SIZE}×2 | Tolera: 2 falhas"
            echo -e "  ${BOLD}[3]${NC} ${CYAN}RAID 10${NC} — 4 discos | Capacidade: ~${SMALLEST_SIZE}×2 | Tolera: 1 por par"
            echo ""
            echo -e "  ${YELLOW}  Falta 1 disco para RAID 5 com 5 discos (configuração ideal do CDPNI).${NC}"
            echo ""
            echo -ne "  ${BOLD}Escolha [1/2/3, padrão: 1]: ${NC}"
            read -r RCHOICE; RCHOICE="${RCHOICE:-1}"
            case "$RCHOICE" in
                2) RAID_LEVEL="6"; RAID_NDISKS=4 ;;
                3) RAID_LEVEL="10"; RAID_NDISKS=4 ;;
                *) RAID_LEVEL="5"; RAID_NDISKS=4 ;;
            esac
            ;;
        5|*)
            echo -e "  ${GREEN}✔ 5+ discos disponíveis — configuração ideal para CDPNI!${NC}"
            echo ""
            echo -e "  ${BOLD}[1]${NC} ${GREEN}RAID 5${NC}  — 5 discos | Capacidade: ~${SMALLEST_SIZE}×4 (~8TB) | Tolera: 1 falha ${GREEN}(RECOMENDADO)${NC}"
            echo -e "       Configuração padrão do CDPNI."
            echo -e "  ${BOLD}[2]${NC} ${CYAN}RAID 6${NC}  — 5 discos | Capacidade: ~${SMALLEST_SIZE}×3 (~6TB) | Tolera: 2 falhas simultâneas"
            echo -e "       Maior proteção, menor capacidade."
            echo -e "  ${BOLD}[3]${NC} ${CYAN}RAID 10${NC} — 4 discos | Capacidade: ~${SMALLEST_SIZE}×2 (~4TB) | Tolera: 1 por par"
            echo -e "       Melhor desempenho em escrita."
            echo ""
            echo -ne "  ${BOLD}Escolha [1/2/3, padrão: 1]: ${NC}"
            read -r RCHOICE; RCHOICE="${RCHOICE:-1}"
            case "$RCHOICE" in
                2) RAID_LEVEL="6"; RAID_NDISKS=5 ;;
                3) RAID_LEVEL="10"; RAID_NDISKS=4 ;;
                *) RAID_LEVEL="5"; RAID_NDISKS=5 ;;
            esac
            ;;
    esac

    # ── 2e. Selecionar discos para o RAID ────────────────────────────────────
    if [[ "${RAID_LEVEL:-none}" != "none" ]]; then
        SELECTED_DISKS=("${RAID_CANDIDATES[@]:0:${RAID_NDISKS}}")

        echo ""
        echo -e "${BOLD}Discos selecionados para RAID ${RAID_LEVEL}:${NC}"
        for i in "${!SELECTED_DISKS[@]}"; do
            echo -e "  ${GREEN}[$((i+1))]${NC} ${SELECTED_DISKS[$i]} — ${DISK_SIZE[${SELECTED_DISKS[$i]}]} — ${DISK_MODEL[${SELECTED_DISKS[$i]}]}"
        done
        echo ""

        # Permitir trocar a seleção
        echo -ne "  ${BOLD}Confirmar esses discos? [ENTER/n]: ${NC}"
        read -r DCONF
        if [[ "${DCONF,,}" == "n" ]]; then
            echo ""
            warn "Seleção manual — informe os discos separados por espaço:"
            echo -e "  Discos disponíveis: ${RAID_CANDIDATES[*]}"
            echo -ne "  ${YELLOW}Discos (${RAID_NDISKS} necessários): ${NC}"
            read -r -a SELECTED_DISKS
            [[ ${#SELECTED_DISKS[@]} -lt "$RAID_NDISKS" ]] && \
                error "Necessários ${RAID_NDISKS} discos para RAID ${RAID_LEVEL}. Informados: ${#SELECTED_DISKS[@]}"
        fi

        # ── 2f. Confirmação final e aviso de perda de dados ──────────────────
        echo ""
        echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}${BOLD}║  ⚠  ATENÇÃO — TODOS OS DADOS SERÃO APAGADOS!                    ║${NC}"
        echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}${BOLD}║  RAID  : ${RAID_LEVEL}                                                     ║${NC}"
        printf "${RED}${BOLD}║  Discos: %-54s ║${NC}\n" "${SELECTED_DISKS[*]}"
        echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -ne "${RED}${BOLD}  Digite 'CONFIRMO' para prosseguir: ${NC}"
        read -r FINAL_CONF
        [[ "$FINAL_CONF" != "CONFIRMO" ]] && error "Instalação cancelada pelo usuário."

        # ── 2g. Criar RAID ────────────────────────────────────────────────────
        header "2g. CRIANDO RAID ${RAID_LEVEL}"

        for disk in "${SELECTED_DISKS[@]}"; do
            info "Zerando superbloco: ${disk}"
            mdadm --zero-superblock --force "$disk" 2>/dev/null || true
            wipefs -af "$disk" 2>/dev/null || true
        done

        MDADM_EXTRA=""
        [[ "$RAID_LEVEL" == "5" || "$RAID_LEVEL" == "6" ]] && \
            MDADM_EXTRA="--chunk=512K --layout=left-symmetric"

        mdadm --create "${RAID_DEVICE}" \
            --level="${RAID_LEVEL}" \
            --raid-devices="${RAID_NDISKS}" \
            --metadata=1.2 \
            --name=data \
            --force \
            --run \
            ${MDADM_EXTRA} \
            "${SELECTED_DISKS[@]}" || error "Falha ao criar RAID ${RAID_LEVEL}"

        sleep 3
        echo ""
        echo -e "${CYAN}Status do RAID:${NC}"
        cat /proc/mdstat
        echo ""

        # Acelerar sincronização inicial
        echo 200000 > /proc/sys/dev/raid/speed_limit_min 2>/dev/null || true
        echo 400000 > /proc/sys/dev/raid/speed_limit_max 2>/dev/null || true

        # Salvar configuração do mdadm
        mkdir -p /etc/mdadm
        mdadm --detail --scan > /etc/mdadm/mdadm.conf
        echo "MAILADDR root" >> /etc/mdadm/mdadm.conf
        update-initramfs -u -k all 2>/dev/null || update-initramfs -u 2>/dev/null || true

        log "RAID ${RAID_LEVEL} criado com ${RAID_NDISKS} discos"

        # ── 2h. Formatar e montar ─────────────────────────────────────────────
        header "2h. FORMATAÇÃO XFS E MONTAGEM"

        info "Aguardando array estar disponível..."
        for i in {1..30}; do [[ -b "${RAID_DEVICE}" ]] && break; sleep 2; done
        [[ -b "${RAID_DEVICE}" ]] || error "${RAID_DEVICE} não disponível após 60s"

        mkfs.xfs -f -L "SAMBA_DATA" "${RAID_DEVICE}" 2>/dev/null || \
            mkfs.ext4 -F -L "SAMBA_DATA" "${RAID_DEVICE}"

        mkdir -p "${RAID_MOUNT}"
        RAID_UUID=$(blkid -s UUID -o value "${RAID_DEVICE}" 2>/dev/null)
        [[ -z "$RAID_UUID" ]] && error "UUID não encontrado após formatação"

        # Atualizar fstab
        grep -v "SAMBA_DATA\|${RAID_DEVICE}" /etc/fstab > /tmp/fstab.tmp && mv /tmp/fstab.tmp /etc/fstab
        echo "# RAID ${RAID_LEVEL} Samba CDPNI" >> /etc/fstab
        echo "UUID=${RAID_UUID}  ${RAID_MOUNT}  xfs  defaults,noatime,nofail  0  2" >> /etc/fstab
        mount "${RAID_MOUNT}" && log "Montado: ${RAID_MOUNT} | UUID: ${RAID_UUID}"
    fi
fi

# Garantir que o ponto de montagem existe mesmo sem RAID
mkdir -p "${RAID_MOUNT}" "${SAMBA_ROOT}" "${RECYCLE_DIR}"

# ===========================================================================
# 3. GRUPOS E USUÁRIOS
# ===========================================================================
header "3. GRUPOS E USUÁRIOS"
for grp in "${ALL_GROUPS[@]}"; do
    getent group "$grp" &>/dev/null || groupadd "$grp" 2>/dev/null
done
log "Grupos criados"

for entry in "${INITIAL_USERS[@]}"; do
    usr="${entry%%:*}"
    grp="${entry##*:}"
    if ! id "$usr" &>/dev/null; then
        useradd -m -s /bin/bash -g "$grp" "$usr" 2>/dev/null
        echo "${usr}:${DEFAULT_PASS}" | chpasswd 2>/dev/null
    fi
done

# Root users — adicionar a todos os grupos
for usr in ${ROOT_USERS}; do
    id "$usr" &>/dev/null || { useradd -m -s /bin/bash "$usr"; echo "${usr}:${DEFAULT_PASS}" | chpasswd; }
    for grp in "${ALL_GROUPS[@]}"; do
        usermod -aG "$grp" "$usr" 2>/dev/null || true
    done
done
log "Usuários criados (senha padrão: ${DEFAULT_PASS})"

# ===========================================================================
# 4. PASTAS COMPARTILHADAS
# ===========================================================================
header "4. PASTAS"
mkdir -p "${SAMBA_ROOT}" "${RECYCLE_DIR}"
for entry in "${ALL_SHARES[@]}"; do
    IFS=':' read -r folder group visible <<< "$entry"
    dir="${SAMBA_ROOT}/${folder}"
    mkdir -p "$dir"
    chown root:"$group" "$dir" 2>/dev/null || true
    chmod 777 "$dir"
done
chmod 1777 "${RECYCLE_DIR}"
log "Pastas criadas em ${SAMBA_ROOT}"

# ===========================================================================
# 5. SAMBA (smb.conf)
# ===========================================================================
header "5. SAMBA"
cat > /etc/samba/smb.conf << SMBEOF
[global]
   workgroup = ${WORKGROUP}
   server string = ${SERVERNAME}
   netbios name = ${SERVERNAME}
   server role = standalone server
   log file = /var/log/samba/%m.log
   max log size = 50
   passdb backend = tdbsam
   map to guest = Bad User
   usershare allow guests = no
   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
   read raw = yes
   write raw = yes
   max xmit = 65536
   dead time = 15
   getwd cache = yes

SMBEOF

# Adicionar cada compartilhamento
for entry in "${ALL_SHARES[@]}"; do
    IFS=':' read -r folder group visible <<< "$entry"
    dir="${SAMBA_ROOT}/${folder}"
    label="${folder//_/ }"
    cat >> /etc/samba/smb.conf << SHAREEOF

[${folder}]
   comment = ${label}
   path = ${dir}
   valid users = @${group} ${ROOT_USERS}
   read only = no
   browseable = ${visible}
   create mask = 0777
   directory mask = 0777
   force create mode = 0777
   force directory mode = 0777
   vfs objects = recycle
   recycle:repository = ${RECYCLE_DIR}/%U
   recycle:keeptree = yes
   recycle:versions = yes

SHAREEOF
done

# [Publico] — sem restrição
cat >> /etc/samba/smb.conf << 'PUBEOF'
[Publico]
   comment = Pasta Pública
   path = /mnt/raid/shares/Publico
   read only = no
   browseable = yes
   guest ok = no
   create mask = 0777
   directory mask = 0777
PUBEOF

testparm -s 2>/dev/null && log "smb.conf válido" || warn "Verificar smb.conf"

# Senhas Samba
for entry in "${INITIAL_USERS[@]}"; do
    usr="${entry%%:*}"
    (echo "${DEFAULT_PASS}"; echo "${DEFAULT_PASS}") | smbpasswd -s -a "$usr" 2>/dev/null || true
done
for usr in ${ROOT_USERS}; do
    (echo "${DEFAULT_PASS}"; echo "${DEFAULT_PASS}") | smbpasswd -s -a "$usr" 2>/dev/null || true
done
log "Senhas Samba definidas (padrão: ${DEFAULT_PASS})"

# ===========================================================================
# 6. SSL
# ===========================================================================
header "6. SSL"
mkdir -p "${SSL_DIR}"
if [[ ! -f "${SSL_DIR}/cdpni.crt" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${SSL_DIR}/cdpni.key" -out "${SSL_DIR}/cdpni.crt" \
        -subj "/C=BR/ST=SP/O=CDPNI/CN=${REALM}" \
        -addext "subjectAltName=DNS:${REALM},DNS:cdpni,DNS:cdpni.local,IP:${SAMBA_IP}" \
        2>/dev/null
    chmod 600 "${SSL_DIR}/cdpni.key"
    log "Certificado SSL gerado"
fi

# ===========================================================================
# 7. NGINX (painel PHP em 8443, portal Flask em 80/443)
# ===========================================================================
header "7. NGINX"
mkdir -p "${PANEL_DIR}/public" "${PANEL_DIR}/logs"

# Painel PHP admin — porta 8443
cat > /etc/nginx/sites-available/samba-panel << NGINXEOF
server {
    listen 8443 ssl;
    server_name ${SAMBA_IP} ${REALM} cdpni cdpni.local;
    ssl_certificate     ${SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    root  ${PANEL_DIR}/public;
    index index.php;
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
    location ~ /\.                   { deny all; }
    location ~* \.(sh|conf|log|key)$ { deny all; }
}
NGINXEOF

# Portal Flask arquivos — porta 80/443 (instalado por portal-v1.sh)
cat > /etc/nginx/sites-available/cdpni-portal << NGINXEOF
server {
    listen 80;
    server_name ${SAMBA_IP} ${REALM} cdpni cdpni.local;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${SAMBA_IP} ${REALM} cdpni cdpni.local;
    ssl_certificate     ${SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    client_max_body_size 512M;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/samba-panel  /etc/nginx/sites-enabled/samba-panel
ln -sf /etc/nginx/sites-available/cdpni-portal /etc/nginx/sites-enabled/cdpni-portal
nginx -t 2>/dev/null && log "Nginx OK" || warn "Verificar Nginx"

# ===========================================================================
# 8. SUDOERS
# ===========================================================================
header "8. SUDOERS"
cat > /etc/sudoers.d/cdpni << 'SUDOEOF'
# Portal Flask — usuário cdpni
cdpni ALL=(ALL) NOPASSWD: /usr/bin/pdbedit
cdpni ALL=(ALL) NOPASSWD: /usr/bin/smbpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/useradd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/usermod
cdpni ALL=(ALL) NOPASSWD: /usr/bin/gpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/bin/chpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/chpasswd
# Painel PHP
www-data ALL=(ALL) NOPASSWD: /usr/bin/pdbedit
www-data ALL=(ALL) NOPASSWD: /usr/bin/smbpasswd
SUDOEOF
chmod 440 /etc/sudoers.d/cdpni
visudo -c -f /etc/sudoers.d/cdpni && log "sudoers OK" || warn "Verificar sudoers"

# ===========================================================================
# 9. PAM
# ===========================================================================
header "9. PAM"
SHADOW_GRP=""
for g in shadow _shadow; do getent group "$g" &>/dev/null && { SHADOW_GRP="$g"; break; }; done
[[ -z "$SHADOW_GRP" ]] && { groupadd shadow 2>/dev/null || true; SHADOW_GRP="shadow"; }
chmod g+r /etc/shadow 2>/dev/null || true
chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true

# Usuário cdpni para o portal Flask
id cdpni &>/dev/null || useradd -r -s /bin/false -d /opt/cdpni-portal cdpni
usermod -aG "${SHADOW_GRP}" cdpni 2>/dev/null || true
for grp in "${ALL_GROUPS[@]}"; do usermod -aG "$grp" cdpni 2>/dev/null || true; done

cat > /etc/pam.d/cdpni-portal << 'PAMEOF'
auth    required   pam_unix.so
account required   pam_unix.so
PAMEOF
log "PAM configurado"

# ===========================================================================
# 10. FAIL2BAN
# ===========================================================================
header "10. FAIL2BAN"
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[sshd]
enabled = true
bantime  = 3600
findtime = 600
maxretry = 5

[samba]
enabled = true
bantime  = 7200
findtime = 600
maxretry = 5
F2BEOF
log "Fail2ban configurado"

# ===========================================================================
# 11. FIREWALL (UFW)
# ===========================================================================
header "11. FIREWALL"
ufw --force reset 2>/dev/null || true
ufw default deny incoming 2>/dev/null
ufw default allow outgoing 2>/dev/null
ufw allow from 192.168.0.0/24 2>/dev/null
ufw allow 22/tcp   2>/dev/null
ufw allow 80/tcp   2>/dev/null
ufw allow 443/tcp  2>/dev/null
ufw allow 8443/tcp 2>/dev/null
ufw allow 445/tcp  2>/dev/null
ufw allow 139/tcp  2>/dev/null
ufw --force enable 2>/dev/null && log "UFW ativo"

# ===========================================================================
# 12. INICIAR SERVIÇOS
# ===========================================================================
header "12. SERVIÇOS"
for svc in smbd nmbd php8.3-fpm nginx fail2ban; do
    systemctl enable "$svc" 2>/dev/null || true
    systemctl restart "$svc" 2>/dev/null && log "$svc iniciado" || warn "$svc falhou"
done

# ===========================================================================
# RESUMO
# ===========================================================================
echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${GRN}║   SAMBA CDPNI v1.0 — INSTALAÇÃO CONCLUÍDA      ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Portal arquivos : https://${SAMBA_IP}           ║${NC}"
echo -e "${BLD}${GRN}║  Painel admin    : https://${SAMBA_IP}:8443      ║${NC}"
echo -e "${BLD}${GRN}║  Samba           : \\\\\\\\${SAMBA_IP} ou \\\\\\\\cdpni  ║${NC}"
echo -e "${BLD}${GRN}║  RAID 5          : /mnt/raid/shares/            ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Senha padrão: ${DEFAULT_PASS} (TROCAR!)                ║${NC}"
echo -e "${BLD}${GRN}║  Próximos passos:                               ║${NC}"
echo -e "${BLD}${GRN}║  1. sudo bash portal-v1.sh   (portal arquivos) ║${NC}"
echo -e "${BLD}${GRN}║  2. Trocar senhas dos usuários                  ║${NC}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════╝${NC}"