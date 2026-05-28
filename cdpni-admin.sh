#!/bin/bash
# =============================================================================
# CDPNI — GERENCIAMENTO DO SERVIDOR SAMBA
# Script de administração diária: usuários, grupos, shares, backup e diagnóstico
# Versão: 1.0 — Maio 2026
# Uso: bash cdpni-admin.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÕES
# ---------------------------------------------------------------------------
SAMBA_ROOT="/mnt/raid/shares"
RECYCLE_DIR="/mnt/raid/recycle"
RAID_DEVICE="/dev/md0"
RAID_MOUNT="/mnt/raid"
SMB_CONF="/etc/samba/smb.conf"
BACKUP_DIR="/mnt/raid/backups"
BACKUP_CONF_DIR="/root/backups/conf"
LOG_FILE="/var/log/cdpni-admin.log"
DEFAULT_PASS="1234"

# ---------------------------------------------------------------------------
# CORES
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $*${NC}" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}" | tee -a "$LOG_FILE"; }
info()   { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $*${NC}"; }
header() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════${NC}";
           echo -e "${BOLD}${BLUE}  $*${NC}";
           echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}\n"; }
ok()     { echo -e "${GREEN}  ✔ $*${NC}"; }
fail()   { echo -e "${RED}  ✘ $*${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Execute como root: su - && bash cdpni-admin.sh${NC}"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_CONF_DIR"

# ---------------------------------------------------------------------------
# FUNÇÕES AUXILIARES
# ---------------------------------------------------------------------------
confirmar() {
    local msg="${1:-Confirma?}"
    echo -en "${YELLOW}[?] ${msg} [s/N]: ${NC}"
    read -r RESP
    [[ "${RESP,,}" == "s" ]]
}

pausar() {
    echo -e "\n${CYAN}Pressione Enter para continuar...${NC}"
    read -r
}

usuario_existe_linux() { id "$1" &>/dev/null; }
usuario_existe_samba() { pdbedit -L 2>/dev/null | grep -q "^${1}:"; }
grupo_existe()         { getent group "$1" &>/dev/null; }
share_existe()         { grep -q "^\[${1}\]" "$SMB_CONF" 2>/dev/null; }

# =============================================================================
# MENU PRINCIPAL
# =============================================================================
menu_principal() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║      CDPNI — Administração Samba         ║"
        echo "  ║         $(date '+%d/%m/%Y  %H:%M')             ║"
        echo "  ╚══════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${GREEN}[1]${NC}  👤  Gerenciar Usuários"
        echo -e "  ${GREEN}[2]${NC}  👥  Gerenciar Grupos"
        echo -e "  ${GREEN}[3]${NC}  📁  Gerenciar Compartilhamentos"
        echo -e "  ${GREEN}[4]${NC}  🔄  Backup e Restauração"
        echo -e "  ${GREEN}[5]${NC}  🖥️   Status e Diagnóstico"
        echo -e "  ${GREEN}[6]${NC}  🗑️   Lixeira"
        echo -e "  ${GREEN}[7]${NC}  📊  Relatório de Uso de Disco"
        echo -e "  ${GREEN}[8]${NC}  🔧  Manutenção do RAID"
        echo -e "  ${GREEN}[9]${NC}  📋  Ver Logs"
        echo -e "  ${GREEN}[0]${NC}  Sair"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) menu_usuarios ;;
            2) menu_grupos ;;
            3) menu_shares ;;
            4) menu_backup ;;
            5) menu_status ;;
            6) menu_lixeira ;;
            7) relatorio_disco ;;
            8) menu_raid ;;
            9) menu_logs ;;
            0) echo ""; exit 0 ;;
            *) warn "Opção inválida" ; sleep 1 ;;
        esac
    done
}

# =============================================================================
# 1. GERENCIAMENTO DE USUÁRIOS
# =============================================================================
menu_usuarios() {
    while true; do
        clear
        header "GERENCIAMENTO DE USUÁRIOS"
        echo -e "  ${GREEN}[1]${NC}  Criar novo usuário"
        echo -e "  ${GREEN}[2]${NC}  Trocar senha de usuário"
        echo -e "  ${GREEN}[3]${NC}  Desativar usuário"
        echo -e "  ${GREEN}[4]${NC}  Reativar usuário"
        echo -e "  ${GREEN}[5]${NC}  Remover usuário do Samba"
        echo -e "  ${GREEN}[6]${NC}  Adicionar usuário a grupo"
        echo -e "  ${GREEN}[7]${NC}  Remover usuário de grupo"
        echo -e "  ${GREEN}[8]${NC}  Listar todos os usuários"
        echo -e "  ${GREEN}[9]${NC}  Ver detalhes de usuário"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) criar_usuario ;;
            2) trocar_senha ;;
            3) desativar_usuario ;;
            4) reativar_usuario ;;
            5) remover_usuario_samba ;;
            6) adicionar_a_grupo ;;
            7) remover_de_grupo ;;
            8) listar_usuarios ;;
            9) ver_usuario ;;
            0) return ;;
        esac
    done
}

criar_usuario() {
    header "CRIAR NOVO USUÁRIO"

    echo -en "  Login (sem espaços, minúsculas): "
    read -r LOGIN
    LOGIN="${LOGIN,,}"
    LOGIN="${LOGIN//[^a-z0-9_]/}"
    [[ -z "$LOGIN" ]] && { error "Login inválido"; pausar; return; }

    echo -en "  Nome completo: "
    read -r FULLNAME
    [[ -z "$FULLNAME" ]] && FULLNAME="$LOGIN"

    # Listar grupos disponíveis
    echo ""
    info "Grupos disponíveis:"
    getent group | grep "^grp_" | cut -d: -f1 | sort | column
    echo ""
    echo -en "  Grupo principal: "
    read -r PRIMARY
    [[ -z "$PRIMARY" ]] && { error "Grupo obrigatório"; pausar; return; }
    grupo_existe "$PRIMARY" || { error "Grupo '$PRIMARY' não existe"; pausar; return; }

    echo -en "  Grupos extras (separados por vírgula, ou Enter para nenhum): "
    read -r EXTRAS

    echo -en "  Senha (Enter para usar '$DEFAULT_PASS'): "
    read -rs SENHA
    echo ""
    [[ -z "$SENHA" ]] && SENHA="$DEFAULT_PASS"

    echo ""
    info "Resumo:"
    echo "  Login:    $LOGIN"
    echo "  Nome:     $FULLNAME"
    echo "  Grupo:    $PRIMARY"
    echo "  Extras:   ${EXTRAS:-nenhum}"
    echo ""

    confirmar "Criar usuário '$LOGIN'?" || { info "Cancelado"; pausar; return; }

    # Criar usuário Linux
    if usuario_existe_linux "$LOGIN"; then
        warn "Usuário Linux '$LOGIN' já existe — atualizando grupos"
        usermod -g "$PRIMARY" "$LOGIN" 2>/dev/null || true
        [[ -n "$EXTRAS" ]] && usermod -aG "$EXTRAS" "$LOGIN" 2>/dev/null || true
    else
        if [[ -n "$EXTRAS" ]]; then
            useradd -m -c "$FULLNAME" -s /usr/sbin/nologin -g "$PRIMARY" -G "$EXTRAS" "$LOGIN"
        else
            useradd -m -c "$FULLNAME" -s /usr/sbin/nologin -g "$PRIMARY" "$LOGIN"
        fi
        echo "${LOGIN}:${SENHA}" | chpasswd
        log "Usuário Linux criado: $LOGIN"
    fi

    # Registrar no Samba
    printf '%s\n%s\n' "$SENHA" "$SENHA" | smbpasswd -s -a "$LOGIN"
    smbpasswd -e "$LOGIN"

    # Criar lixeira pessoal
    mkdir -p "${RECYCLE_DIR}/${LOGIN}"
    chmod 700 "${RECYCLE_DIR}/${LOGIN}"
    chown "${LOGIN}:${PRIMARY}" "${RECYCLE_DIR}/${LOGIN}"

    log "Usuário Samba criado: $LOGIN ($FULLNAME)"
    echo -e "\n${GREEN}  ✔ Usuário '$LOGIN' criado com sucesso!${NC}"
    echo -e "  ${YELLOW}Senha: $SENHA${NC}"
    pausar
}

trocar_senha() {
    header "TROCAR SENHA"
    echo -en "  Login do usuário: "
    read -r LOGIN
    usuario_existe_samba "$LOGIN" || { error "Usuário '$LOGIN' não existe no Samba"; pausar; return; }

    echo -en "  Nova senha (Enter para gerar automaticamente): "
    read -rs SENHA
    echo ""

    if [[ -z "$SENHA" ]]; then
        SENHA=$(tr -dc 'A-Za-z0-9!@#' < /dev/urandom | head -c 12)
        info "Senha gerada: $SENHA"
    fi

    echo "${LOGIN}:${SENHA}" | chpasswd
    printf '%s\n%s\n' "$SENHA" "$SENHA" | smbpasswd -s "$LOGIN"
    log "Senha alterada: $LOGIN"
    echo -e "\n${GREEN}  ✔ Senha de '$LOGIN' atualizada: ${BOLD}$SENHA${NC}"
    pausar
}

desativar_usuario() {
    header "DESATIVAR USUÁRIO"
    echo -en "  Login: "
    read -r LOGIN
    usuario_existe_samba "$LOGIN" || { error "Usuário não existe no Samba"; pausar; return; }
    confirmar "Desativar '$LOGIN'?" || return
    smbpasswd -d "$LOGIN"
    log "Usuário desativado: $LOGIN"
    ok "Usuário '$LOGIN' desativado. Pode ser reativado a qualquer momento."
    pausar
}

reativar_usuario() {
    header "REATIVAR USUÁRIO"
    echo -en "  Login: "
    read -r LOGIN
    usuario_existe_samba "$LOGIN" || { error "Usuário não existe no Samba"; pausar; return; }
    smbpasswd -e "$LOGIN"
    log "Usuário reativado: $LOGIN"
    ok "Usuário '$LOGIN' reativado."
    pausar
}

remover_usuario_samba() {
    header "REMOVER DO SAMBA"
    echo -en "  Login: "
    read -r LOGIN
    usuario_existe_samba "$LOGIN" || { error "Usuário não existe no Samba"; pausar; return; }
    warn "O usuário Linux será mantido. Apenas o acesso Samba será removido."
    confirmar "Remover '$LOGIN' do Samba?" || return
    smbpasswd -x "$LOGIN" 2>/dev/null || true
    log "Usuário removido do Samba: $LOGIN"
    ok "Acesso Samba de '$LOGIN' revogado."
    pausar
}

adicionar_a_grupo() {
    header "ADICIONAR USUÁRIO A GRUPO"
    echo -en "  Login: "
    read -r LOGIN
    usuario_existe_linux "$LOGIN" || { error "Usuário '$LOGIN' não existe"; pausar; return; }

    echo ""
    info "Grupos disponíveis:"
    getent group | grep "^grp_" | cut -d: -f1 | sort | column
    echo ""
    echo -en "  Grupo: "
    read -r GRUPO
    grupo_existe "$GRUPO" || { error "Grupo não existe"; pausar; return; }

    usermod -aG "$GRUPO" "$LOGIN"
    log "Usuário $LOGIN adicionado ao grupo $GRUPO"
    ok "$LOGIN → $GRUPO"
    pausar
}

remover_de_grupo() {
    header "REMOVER USUÁRIO DE GRUPO"
    echo -en "  Login: "
    read -r LOGIN
    usuario_existe_linux "$LOGIN" || { error "Usuário não existe"; pausar; return; }
    echo -en "  Grupo: "
    read -r GRUPO
    gpasswd -d "$LOGIN" "$GRUPO" 2>/dev/null || { error "Erro ao remover"; pausar; return; }
    log "Usuário $LOGIN removido do grupo $GRUPO"
    ok "Feito."
    pausar
}

listar_usuarios() {
    header "USUÁRIOS SAMBA"
    printf "%-20s %-30s %-12s %s\n" "LOGIN" "NOME" "STATUS" "GRUPOS"
    echo "────────────────────────────────────────────────────────────────────────"
    while IFS=: read -r login uid fullname _; do
        FLAGS=$(pdbedit -v -u "$login" 2>/dev/null | awk '/Account Flags/{print $3}' | tr -d '[]')
        STATUS="Ativo"
        [[ "$FLAGS" == *D* ]] && STATUS="Desativado"
        GRUPOS=$(id -nG "$login" 2>/dev/null | tr ' ' ',' | sed 's/,$//')
        printf "%-20s %-30s %-12s %s\n" "$login" "${fullname:0:28}" "$STATUS" "${GRUPOS:0:50}"
    done < <(pdbedit -L 2>/dev/null | awk -F: '{print $1":"$2":"}')
    pausar
}

ver_usuario() {
    header "DETALHES DO USUÁRIO"
    echo -en "  Login: "
    read -r LOGIN
    usuario_existe_linux "$LOGIN" || { error "Usuário não existe"; pausar; return; }
    echo ""
    info "=== Sistema Linux ==="
    id "$LOGIN"
    echo ""
    info "=== Grupos ==="
    groups "$LOGIN"
    echo ""
    info "=== Samba ==="
    pdbedit -v -u "$LOGIN" 2>/dev/null || warn "Usuário não cadastrado no Samba"
    echo ""
    info "=== Lixeira ==="
    if [[ -d "${RECYCLE_DIR}/${LOGIN}" ]]; then
        du -sh "${RECYCLE_DIR}/${LOGIN}" 2>/dev/null || echo "  (vazia)"
    else
        echo "  Sem lixeira"
    fi
    pausar
}

# =============================================================================
# 2. GERENCIAMENTO DE GRUPOS
# =============================================================================
menu_grupos() {
    while true; do
        clear
        header "GERENCIAMENTO DE GRUPOS"
        echo -e "  ${GREEN}[1]${NC}  Criar novo grupo"
        echo -e "  ${GREEN}[2]${NC}  Listar grupos e membros"
        echo -e "  ${GREEN}[3]${NC}  Ver membros de um grupo"
        echo -e "  ${GREEN}[4]${NC}  Remover grupo (cuidado!)"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) criar_grupo ;;
            2) listar_grupos ;;
            3) ver_grupo ;;
            4) remover_grupo ;;
            0) return ;;
        esac
    done
}

criar_grupo() {
    header "CRIAR GRUPO"
    echo -en "  Nome do grupo (será prefixado com grp_): "
    read -r NOME
    NOME="${NOME,,}"
    NOME="grp_${NOME//[^a-z0-9_]/}"
    [[ -z "$NOME" || "$NOME" == "grp_" ]] && { error "Nome inválido"; pausar; return; }
    grupo_existe "$NOME" && { warn "Grupo '$NOME' já existe"; pausar; return; }
    groupadd "$NOME"
    log "Grupo criado: $NOME"
    ok "Grupo '$NOME' criado."
    pausar
}

listar_grupos() {
    header "GRUPOS E MEMBROS"
    printf "%-30s %-6s %s\n" "GRUPO" "GID" "MEMBROS"
    echo "────────────────────────────────────────────────────────────────"
    getent group | grep "^grp_" | sort | while IFS=: read -r name _ gid members; do
        printf "%-30s %-6s %s\n" "$name" "$gid" "${members:-  (sem membros)}"
    done
    pausar
}

ver_grupo() {
    header "MEMBROS DO GRUPO"
    echo -en "  Grupo: "
    read -r GRUPO
    grupo_existe "$GRUPO" || { error "Grupo não existe"; pausar; return; }
    echo ""
    info "Membros de $GRUPO:"
    getent group "$GRUPO" | cut -d: -f4 | tr ',' '\n' | while read -r u; do
        [[ -n "$u" ]] && echo "  - $u"
    done || echo "  (sem membros)"
    pausar
}

remover_grupo() {
    header "REMOVER GRUPO"
    warn "Remover um grupo que está em uso no smb.conf pode quebrar o acesso às pastas!"
    echo -en "  Grupo a remover: "
    read -r GRUPO
    grupo_existe "$GRUPO" || { error "Grupo não existe"; pausar; return; }
    grep -q "$GRUPO" "$SMB_CONF" && warn "Grupo '$GRUPO' está referenciado no smb.conf!"
    confirmar "Tem certeza que deseja remover '$GRUPO'?" || return
    groupdel "$GRUPO"
    log "Grupo removido: $GRUPO"
    ok "Grupo removido."
    pausar
}

# =============================================================================
# 3. GERENCIAMENTO DE COMPARTILHAMENTOS
# =============================================================================
menu_shares() {
    while true; do
        clear
        header "GERENCIAMENTO DE COMPARTILHAMENTOS"
        echo -e "  ${GREEN}[1]${NC}  Criar novo compartilhamento"
        echo -e "  ${GREEN}[2]${NC}  Listar compartilhamentos"
        echo -e "  ${GREEN}[3]${NC}  Ver detalhes de um share"
        echo -e "  ${GREEN}[4]${NC}  Ocultar/mostrar compartilhamento"
        echo -e "  ${GREEN}[5]${NC}  Adicionar usuário/grupo a um share"
        echo -e "  ${GREEN}[6]${NC}  Remover compartilhamento"
        echo -e "  ${GREEN}[7]${NC}  Recarregar configuração Samba"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) criar_share ;;
            2) listar_shares ;;
            3) ver_share ;;
            4) toggle_browse_share ;;
            5) adicionar_acesso_share ;;
            6) remover_share ;;
            7) recarregar_samba ;;
            0) return ;;
        esac
    done
}

criar_share() {
    header "CRIAR COMPARTILHAMENTO"

    echo -en "  Nome da pasta/share: "
    read -r NOME
    NOME="${NOME//[^a-zA-Z0-9_-]/}"
    [[ -z "$NOME" ]] && { error "Nome inválido"; pausar; return; }
    share_existe "$NOME" && { error "Share '$NOME' já existe"; pausar; return; }

    echo ""
    info "Grupos disponíveis:"
    getent group | grep "^grp_" | cut -d: -f1 | sort | column
    echo ""
    echo -en "  Grupo de acesso: "
    read -r GRUPO
    grupo_existe "$GRUPO" || { error "Grupo não existe"; pausar; return; }

    echo -en "  Visível na rede? [S/n]: "
    read -r VIS_INPUT
    VIS="yes"
    [[ "${VIS_INPUT,,}" == "n" ]] && VIS="no"

    echo -en "  Descrição (opcional): "
    read -r DESCRICAO
    [[ -z "$DESCRICAO" ]] && DESCRICAO="$NOME"

    DIR="${SAMBA_ROOT}/${NOME}"
    mkdir -p "$DIR"
    chmod -R 777 "$DIR"
    chown -R root:root "$DIR"

    # Backup do smb.conf
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d_%H%M%S)"

    cat >> "$SMB_CONF" << SHAREEOF

[${NOME}]
    comment      = ${DESCRICAO}
    path         = ${DIR}
    valid users  = @${GRUPO} sambadmin
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777
SHAREEOF

    testparm -s "$SMB_CONF" &>/dev/null || {
        error "smb.conf inválido! Restaurando backup..."
        cp "${SMB_CONF}.bak.$(date +%Y%m%d_%H%M%S)" "$SMB_CONF" 2>/dev/null || true
        pausar; return
    }

    smbcontrol smbd reload-config 2>/dev/null || systemctl reload smbd 2>/dev/null || true
    log "Share criado: $NOME ($GRUPO) em $DIR"
    ok "Share '$NOME' criado e ativo."
    pausar
}

listar_shares() {
    header "COMPARTILHAMENTOS ATIVOS"
    printf "%-25s %-8s %-35s %s\n" "NOME" "VISÍVEL" "CAMINHO" "USO DISCO"
    echo "────────────────────────────────────────────────────────────────────────────"
    grep "^\[" "$SMB_CONF" | grep -v "^\[global\]\|^\[Recycle\]" | tr -d '[]' | while read -r share; do
        PATH_SHARE=$(awk "/^\[${share}\]/{f=1} f && /path/{print \$3; exit}" "$SMB_CONF")
        BROWSE=$(awk "/^\[${share}\]/{f=1} f && /browseable/{print \$3; exit}" "$SMB_CONF")
        [[ -z "$BROWSE" ]] && BROWSE="yes"
        USO=""
        [[ -d "$PATH_SHARE" ]] && USO=$(du -sh "$PATH_SHARE" 2>/dev/null | cut -f1)
        printf "%-25s %-8s %-35s %s\n" "$share" "$BROWSE" "${PATH_SHARE:0:33}" "${USO:-N/D}"
    done
    pausar
}

ver_share() {
    header "DETALHES DO SHARE"
    echo -en "  Nome do share: "
    read -r NOME
    share_existe "$NOME" || { error "Share não existe"; pausar; return; }
    echo ""
    info "=== smb.conf ==="
    awk "/^\[${NOME}\]/{f=1} f{print; if(/^$/ && f>1) exit} {f++}" "$SMB_CONF" | head -20
    echo ""
    PATH_SHARE=$(awk "/^\[${NOME}\]/{f=1} f && /path/{print \$3; exit}" "$SMB_CONF")
    if [[ -n "$PATH_SHARE" && -d "$PATH_SHARE" ]]; then
        info "=== Disco ==="
        du -sh "$PATH_SHARE"
        echo "  Arquivos: $(find "$PATH_SHARE" -type f 2>/dev/null | wc -l)"
    fi
    pausar
}

toggle_browse_share() {
    header "OCULTAR/MOSTRAR SHARE"
    echo -en "  Nome do share: "
    read -r NOME
    share_existe "$NOME" || { error "Share não existe"; pausar; return; }
    ATUAL=$(awk "/^\[${NOME}\]/{f=1} f && /browseable/{print \$3; exit}" "$SMB_CONF")
    [[ "$ATUAL" == "no" ]] && NOVO="yes" || NOVO="no"
    info "Alterando de '$ATUAL' para '$NOVO'..."
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 -c "
import re, sys
with open('$SMB_CONF') as f: c = f.read()
in_share = False
lines = []
for line in c.splitlines():
    if re.match(r'^\[${NOME}\]', line): in_share = True
    elif re.match(r'^\[', line) and in_share: in_share = False
    if in_share and re.match(r'\s*browseable\s*=', line):
        line = re.sub(r'(browseable\s*=\s*)\S+', r'\g<1>$NOVO', line)
    lines.append(line)
with open('$SMB_CONF', 'w') as f: f.write('\n'.join(lines))
"
    smbcontrol smbd reload-config 2>/dev/null || true
    log "Share $NOME browseable=$NOVO"
    ok "Share '$NOME' agora está: $([ "$NOVO" = "yes" ] && echo "VISÍVEL" || echo "OCULTO")"
    pausar
}

adicionar_acesso_share() {
    header "ADICIONAR ACESSO A UM SHARE"
    echo -en "  Nome do share: "
    read -r NOME
    share_existe "$NOME" || { error "Share não existe"; pausar; return; }
    echo -en "  Usuário ou @grupo a adicionar: "
    read -r ENTIDADE
    [[ -z "$ENTIDADE" ]] && { error "Inválido"; pausar; return; }
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    sed -i "/^\[${NOME}\]/,/^\[/ s/\(valid users.*\)$/\1 ${ENTIDADE}/" "$SMB_CONF"
    smbcontrol smbd reload-config 2>/dev/null || true
    log "Acesso adicionado: $ENTIDADE → $NOME"
    ok "$ENTIDADE pode agora acessar '$NOME'."
    pausar
}

remover_share() {
    header "REMOVER COMPARTILHAMENTO"
    warn "Isso remove o share do smb.conf. Os ARQUIVOS são mantidos em disco."
    echo -en "  Nome do share: "
    read -r NOME
    share_existe "$NOME" || { error "Share não existe"; pausar; return; }
    confirmar "Remover share '$NOME' do smb.conf?" || return
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 -c "
import re
with open('$SMB_CONF') as f: c = f.read()
c = re.sub(r'\n\[${NOME}\][^\[]*', '', c)
with open('$SMB_CONF', 'w') as f: f.write(c)
"
    smbcontrol smbd reload-config 2>/dev/null || true
    log "Share removido: $NOME"
    ok "Share '$NOME' removido do smb.conf. Pasta em disco preservada."
    pausar
}

recarregar_samba() {
    header "RECARREGAR CONFIGURAÇÃO"
    testparm -s "$SMB_CONF" &>/dev/null || { error "smb.conf tem erros! Use 'testparm' para verificar."; pausar; return; }
    smbcontrol smbd reload-config && ok "Samba recarregado sem interromper conexões." || \
        systemctl restart smbd && ok "Samba reiniciado."
    log "Configuração Samba recarregada"
    pausar
}

# =============================================================================
# 4. BACKUP E RESTAURAÇÃO
# =============================================================================
menu_backup() {
    while true; do
        clear
        header "BACKUP E RESTAURAÇÃO"
        echo -e "  ${GREEN}[1]${NC}  Backup de configurações (smb.conf, usuários, grupos)"
        echo -e "  ${GREEN}[2]${NC}  Backup dos dados (rsync para outro destino)"
        echo -e "  ${GREEN}[3]${NC}  Backup completo (conf + dados)"
        echo -e "  ${GREEN}[4]${NC}  Restaurar configurações"
        echo -e "  ${GREEN}[5]${NC}  Listar backups disponíveis"
        echo -e "  ${GREEN}[6]${NC}  Agendar backup automático (cron)"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) backup_configuracoes ;;
            2) backup_dados ;;
            3) backup_completo ;;
            4) restaurar_configuracoes ;;
            5) listar_backups ;;
            6) agendar_backup ;;
            0) return ;;
        esac
    done
}

backup_configuracoes() {
    header "BACKUP DE CONFIGURAÇÕES"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DEST="${BACKUP_CONF_DIR}/conf_${TIMESTAMP}"
    mkdir -p "$DEST"

    info "Fazendo backup das configurações..."

    # smb.conf
    cp "$SMB_CONF" "${DEST}/smb.conf"
    ok "smb.conf"

    # Banco de senhas Samba
    [[ -f /etc/samba/passdb.tdb ]] && cp /etc/samba/passdb.tdb "${DEST}/passdb.tdb" && ok "passdb.tdb"
    [[ -f /var/lib/samba/private/passdb.tdb ]] && cp /var/lib/samba/private/passdb.tdb "${DEST}/passdb.tdb" && ok "passdb.tdb (private)"

    # Usuários e grupos Linux
    pdbedit -L -e smbpasswd:${DEST}/samba_users.txt 2>/dev/null && ok "Lista de usuários Samba"
    getent passwd | grep -v "^root\|nologin\|false" | awk -F: '$7 ~ /nologin/{print}' > "${DEST}/linux_users.txt" && ok "Usuários Linux"
    getent group | grep "^grp_" > "${DEST}/linux_groups.txt" && ok "Grupos Linux"

    # mdadm
    [[ -f /etc/mdadm/mdadm.conf ]] && cp /etc/mdadm/mdadm.conf "${DEST}/mdadm.conf" && ok "mdadm.conf"

    # Criar arquivo tar
    tar -czf "${BACKUP_CONF_DIR}/conf_${TIMESTAMP}.tar.gz" -C "${BACKUP_CONF_DIR}" "conf_${TIMESTAMP}/"
    rm -rf "$DEST"

    SIZE=$(du -sh "${BACKUP_CONF_DIR}/conf_${TIMESTAMP}.tar.gz" | cut -f1)
    log "Backup de configurações criado: conf_${TIMESTAMP}.tar.gz ($SIZE)"
    ok "Backup salvo em: ${BACKUP_CONF_DIR}/conf_${TIMESTAMP}.tar.gz"
    pausar
}

backup_dados() {
    header "BACKUP DOS DADOS (rsync)"
    echo ""
    echo -e "  Destino do backup:"
    echo -e "  ${GREEN}[1]${NC}  Disco externo/USB (montar antes)"
    echo -e "  ${GREEN}[2]${NC}  Servidor remoto via SSH"
    echo -e "  ${GREEN}[3]${NC}  Pasta local (outro disco)"
    echo -e "  ${GREEN}[0]${NC}  Voltar"
    echo ""
    echo -en "  Opção: "
    read -r TIPO

    case "$TIPO" in
        1)
            echo -en "  Ponto de montagem (ex: /media/backup): "
            read -r DEST
            [[ ! -d "$DEST" ]] && { error "Diretório não existe ou não está montado"; pausar; return; }
            DESTINO="${DEST}/samba_backup_$(date +%Y%m%d)"
            ;;
        2)
            echo -en "  Usuário@servidor (ex: root@192.168.0.12): "
            read -r REMOTE
            echo -en "  Caminho remoto (ex: /backup/cdpni): "
            read -r REMOTE_PATH
            DESTINO="${REMOTE}:${REMOTE_PATH}/samba_backup_$(date +%Y%m%d)"
            ;;
        3)
            echo -en "  Caminho destino: "
            read -r DEST
            [[ ! -d "$DEST" ]] && mkdir -p "$DEST"
            DESTINO="${DEST}/samba_backup_$(date +%Y%m%d)"
            ;;
        0) return ;;
        *) error "Opção inválida"; pausar; return ;;
    esac

    info "Iniciando rsync de ${SAMBA_ROOT}/ → ${DESTINO}"
    info "Isso pode demorar bastante dependendo do volume de dados..."
    echo ""

    rsync -avh --progress --delete \
        --exclude=".recycle/" \
        --exclude="*.tmp" \
        --exclude="~$*" \
        "${SAMBA_ROOT}/" "${DESTINO}/" 2>&1 | tee -a "$LOG_FILE"

    log "Backup de dados concluído → $DESTINO"
    ok "Backup concluído."
    pausar
}

backup_completo() {
    header "BACKUP COMPLETO"
    info "Executando backup de configurações + dados..."
    backup_configuracoes
    backup_dados
}

restaurar_configuracoes() {
    header "RESTAURAR CONFIGURAÇÕES"
    listar_backups
    echo ""
    echo -en "  Nome do arquivo de backup (ex: conf_20260524_143000.tar.gz): "
    read -r ARQUIVO
    FULL_PATH="${BACKUP_CONF_DIR}/${ARQUIVO}"
    [[ ! -f "$FULL_PATH" ]] && { error "Arquivo não encontrado: $FULL_PATH"; pausar; return; }

    warn "Isso irá sobrescrever o smb.conf atual!"
    confirmar "Restaurar configurações de '$ARQUIVO'?" || return

    TMPDIR=$(mktemp -d)
    tar -xzf "$FULL_PATH" -C "$TMPDIR"

    # Backup do atual antes de restaurar
    cp "$SMB_CONF" "${SMB_CONF}.bak.pre_restore.$(date +%Y%m%d_%H%M%S)"

    EXTRACTED=$(ls "$TMPDIR")
    [[ -f "${TMPDIR}/${EXTRACTED}/smb.conf" ]] && {
        cp "${TMPDIR}/${EXTRACTED}/smb.conf" "$SMB_CONF"
        ok "smb.conf restaurado"
    }
    [[ -f "${TMPDIR}/${EXTRACTED}/passdb.tdb" ]] && {
        systemctl stop smbd nmbd 2>/dev/null
        cp "${TMPDIR}/${EXTRACTED}/passdb.tdb" /etc/samba/passdb.tdb
        systemctl start smbd nmbd 2>/dev/null
        ok "passdb.tdb restaurado"
    }

    rm -rf "$TMPDIR"
    testparm -s "$SMB_CONF" &>/dev/null && smbcontrol smbd reload-config 2>/dev/null || true
    log "Configurações restauradas de: $ARQUIVO"
    ok "Restauração concluída."
    pausar
}

listar_backups() {
    header "BACKUPS DISPONÍVEIS"
    echo ""
    if [[ -d "$BACKUP_CONF_DIR" ]]; then
        printf "%-45s %s\n" "ARQUIVO" "TAMANHO"
        echo "────────────────────────────────────────────────────"
        ls -lh "${BACKUP_CONF_DIR}"/*.tar.gz 2>/dev/null | awk '{print $9, $5}' | \
            while read -r name size; do
                printf "%-45s %s\n" "$(basename "$name")" "$size"
            done || info "Nenhum backup encontrado em $BACKUP_CONF_DIR"
    else
        info "Pasta de backup ainda não existe"
    fi
    pausar
}

agendar_backup() {
    header "AGENDAR BACKUP AUTOMÁTICO"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  Backup de configurações diário (04:00)"
    echo -e "  ${GREEN}[2]${NC}  Backup de configurações + dados semanal (domingo 02:00)"
    echo -e "  ${GREEN}[3]${NC}  Personalizado"
    echo -e "  ${GREEN}[4]${NC}  Ver agendamentos atuais"
    echo -e "  ${GREEN}[0]${NC}  Voltar"
    echo ""
    echo -en "  Opção: "
    read -r OPT

    SCRIPT_PATH="$(realpath "$0")"

    case "$OPT" in
        1)
            echo "0 4 * * * root bash ${SCRIPT_PATH} --backup-conf" > /etc/cron.d/cdpni-backup
            ok "Backup de configurações agendado para 04:00 diariamente"
            log "Cron backup conf configurado"
            ;;
        2)
            cat > /etc/cron.d/cdpni-backup << CRONEOF
0 2 * * 0 root bash ${SCRIPT_PATH} --backup-conf
30 2 * * 0 root bash ${SCRIPT_PATH} --backup-dados
CRONEOF
            ok "Backup semanal agendado para domingo 02:00"
            log "Cron backup completo configurado"
            ;;
        3)
            echo -en "  Cron expression (ex: '0 3 * * *'): "
            read -r CRON_EXPR
            echo -en "  Tipo [conf/dados/completo]: "
            read -r TIPO
            echo "${CRON_EXPR} root bash ${SCRIPT_PATH} --backup-${TIPO}" > /etc/cron.d/cdpni-backup
            ok "Agendamento configurado"
            ;;
        4)
            [[ -f /etc/cron.d/cdpni-backup ]] && cat /etc/cron.d/cdpni-backup || info "Nenhum agendamento"
            ;;
    esac
    pausar
}

# =============================================================================
# 5. STATUS E DIAGNÓSTICO
# =============================================================================
menu_status() {
    clear
    header "STATUS DO SISTEMA"

    echo -e "${BOLD}── Serviços ─────────────────────────────────────────${NC}"
    for svc in smbd nmbd nginx php8.3-fpm fail2ban smartd chrony; do
        STATUS=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$STATUS" == "active" ]]; then
            printf "  ${GREEN}●${NC} %-20s ${GREEN}%s${NC}\n" "$svc" "$STATUS"
        else
            printf "  ${RED}●${NC} %-20s ${RED}%s${NC}\n" "$svc" "$STATUS"
        fi
    done

    echo ""
    echo -e "${BOLD}── RAID ──────────────────────────────────────────────${NC}"
    cat /proc/mdstat | grep -v "^Personalities\|^unused" | head -5

    echo ""
    echo -e "${BOLD}── Disco ─────────────────────────────────────────────${NC}"
    df -h /mnt/raid 2>/dev/null || echo "  RAID não montado!"

    echo ""
    echo -e "${BOLD}── Conexões Samba ────────────────────────────────────${NC}"
    CONN=$(smbstatus -S 2>/dev/null | grep -v "^$\|^-\|^Share\|no locked" | wc -l)
    echo "  Conexões ativas: $CONN"
    smbstatus -b 2>/dev/null | head -10 || true

    echo ""
    echo -e "${BOLD}── NTP ───────────────────────────────────────────────${NC}"
    chronyc tracking 2>/dev/null | grep "System time\|Reference\|Stratum" || echo "  chrony não disponível"

    echo ""
    echo -e "${BOLD}── Portas ────────────────────────────────────────────${NC}"
    ss -tlnp 2>/dev/null | grep -E ':139|:445|:443|:80' | awk '{print "  "$1,$4,$5}'

    pausar
}

# =============================================================================
# 6. LIXEIRA
# =============================================================================
menu_lixeira() {
    while true; do
        clear
        header "GERENCIAMENTO DE LIXEIRA"
        echo -e "  ${GREEN}[1]${NC}  Ver uso da lixeira por usuário"
        echo -e "  ${GREEN}[2]${NC}  Limpar lixeira de um usuário"
        echo -e "  ${GREEN}[3]${NC}  Limpar toda a lixeira"
        echo -e "  ${GREEN}[4]${NC}  Restaurar arquivo da lixeira"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) uso_lixeira ;;
            2) limpar_lixeira_usuario ;;
            3) limpar_lixeira_total ;;
            4) restaurar_lixeira ;;
            0) return ;;
        esac
    done
}

uso_lixeira() {
    header "USO DA LIXEIRA"
    TOTAL=$(du -sh "${RECYCLE_DIR}" 2>/dev/null | cut -f1)
    echo -e "  Total: ${YELLOW}${TOTAL}${NC}"
    echo ""
    printf "%-20s %s\n" "USUÁRIO" "TAMANHO"
    echo "──────────────────────────────"
    find "${RECYCLE_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r dir; do
        USER=$(basename "$dir")
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
        printf "%-20s %s\n" "$USER" "${SIZE:-0}"
    done
    pausar
}

limpar_lixeira_usuario() {
    header "LIMPAR LIXEIRA DO USUÁRIO"
    echo -en "  Login: "
    read -r LOGIN
    [[ ! -d "${RECYCLE_DIR}/${LOGIN}" ]] && { error "Lixeira não existe para '$LOGIN'"; pausar; return; }
    SIZE=$(du -sh "${RECYCLE_DIR}/${LOGIN}" | cut -f1)
    warn "Isso liberará $SIZE da lixeira de $LOGIN."
    confirmar "Confirma limpeza?" || return
    rm -rf "${RECYCLE_DIR:?}/${LOGIN:?}"/*
    mkdir -p "${RECYCLE_DIR}/${LOGIN}"
    chmod 700 "${RECYCLE_DIR}/${LOGIN}"
    chown "${LOGIN}:" "${RECYCLE_DIR}/${LOGIN}" 2>/dev/null || true
    log "Lixeira limpa: $LOGIN"
    ok "Lixeira de '$LOGIN' limpa."
    pausar
}

limpar_lixeira_total() {
    header "LIMPAR TODA A LIXEIRA"
    SIZE=$(du -sh "${RECYCLE_DIR}" 2>/dev/null | cut -f1)
    warn "Isso apagará PERMANENTEMENTE $SIZE de arquivos deletados de TODOS os usuários!"
    confirmar "Tem absoluta certeza?" || return
    find "${RECYCLE_DIR}" -mindepth 2 -delete 2>/dev/null || true
    log "Lixeira geral limpa"
    ok "Lixeira limpa."
    pausar
}

restaurar_lixeira() {
    header "RESTAURAR DA LIXEIRA"
    echo -en "  Login do usuário: "
    read -r LOGIN
    [[ ! -d "${RECYCLE_DIR}/${LOGIN}" ]] && { error "Sem lixeira para '$LOGIN'"; pausar; return; }

    echo ""
    info "Arquivos na lixeira de $LOGIN:"
    find "${RECYCLE_DIR}/${LOGIN}" -type f 2>/dev/null | head -30 | while read -r f; do
        echo "  ${f#${RECYCLE_DIR}/${LOGIN}/}"
    done
    echo ""

    echo -en "  Caminho relativo do arquivo (como mostrado acima): "
    read -r ARQUIVO_REL
    ORIGEM="${RECYCLE_DIR}/${LOGIN}/${ARQUIVO_REL}"
    [[ ! -f "$ORIGEM" ]] && { error "Arquivo não encontrado"; pausar; return; }

    echo -en "  Destino (ex: /mnt/raid/shares/Financas/): "
    read -r DESTINO
    mkdir -p "$DESTINO"
    cp "$ORIGEM" "$DESTINO/"
    log "Arquivo restaurado: $ARQUIVO_REL → $DESTINO"
    ok "Arquivo restaurado em $DESTINO"
    pausar
}

# =============================================================================
# 7. RELATÓRIO DE DISCO
# =============================================================================
relatorio_disco() {
    clear
    header "RELATÓRIO DE USO DE DISCO"

    echo -e "${BOLD}── RAID ──────────────────────────────────────────────${NC}"
    df -h "${RAID_MOUNT}"

    echo ""
    echo -e "${BOLD}── Por compartilhamento ─────────────────────────────${NC}"
    printf "%-30s %10s %10s\n" "SHARE" "TAMANHO" "ARQUIVOS"
    echo "────────────────────────────────────────────────────"
    find "${SAMBA_ROOT}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | while read -r dir; do
        SHARE=$(basename "$dir")
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
        FILES=$(find "$dir" -type f 2>/dev/null | wc -l)
        printf "%-30s %10s %10s\n" "$SHARE" "${SIZE:-0}" "$FILES"
    done

    echo ""
    echo -e "${BOLD}── Lixeira ───────────────────────────────────────────${NC}"
    du -sh "${RECYCLE_DIR}" 2>/dev/null || echo "  Vazia"

    echo ""
    echo -e "${BOLD}── Top 10 maiores arquivos ──────────────────────────${NC}"
    find "${SAMBA_ROOT}" -type f -printf '%s %p\n' 2>/dev/null | \
        sort -rn | head -10 | awk '{
            size=$1; $1=""
            if(size>1073741824) printf "  %6.1f GB  %s\n", size/1073741824, $0
            else if(size>1048576) printf "  %6.1f MB  %s\n", size/1048576, $0
            else printf "  %6.1f KB  %s\n", size/1024, $0
        }'
    pausar
}

# =============================================================================
# 8. MANUTENÇÃO DO RAID
# =============================================================================
menu_raid() {
    while true; do
        clear
        header "MANUTENÇÃO DO RAID"
        echo -e "  ${GREEN}[1]${NC}  Status detalhado"
        echo -e "  ${GREEN}[2]${NC}  Monitorar sincronização em tempo real"
        echo -e "  ${GREEN}[3]${NC}  Verificar integridade (check)"
        echo -e "  ${GREEN}[4]${NC}  Substituir disco com falha"
        echo -e "  ${GREEN}[5]${NC}  Ver log de alertas do RAID"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) mdadm --detail "${RAID_DEVICE}"; pausar ;;
            2) watch -n2 cat /proc/mdstat ;;
            3)
                warn "A verificação pode levar horas e impacta a performance!"
                confirmar "Iniciar verificação de integridade?" || continue
                echo check > /sys/block/md0/md/sync_action 2>/dev/null
                ok "Verificação iniciada. Acompanhe com 'watch cat /proc/mdstat'"
                pausar
                ;;
            4) substituir_disco_raid ;;
            5) cat /var/log/raid_alert.log 2>/dev/null || info "Sem alertas"; pausar ;;
            0) return ;;
        esac
    done
}

substituir_disco_raid() {
    header "SUBSTITUIR DISCO COM FALHA"
    echo ""
    mdadm --detail "${RAID_DEVICE}" | grep -E "State|Failed|/dev/sd"
    echo ""
    warn "Passos para substituir um disco:"
    echo "  1. Identifique o disco com falha acima"
    echo ""
    echo -en "  Disco com falha (ex: /dev/sdb): "
    read -r DISCO_FALHO
    [[ ! -b "$DISCO_FALHO" ]] && { error "Disco não encontrado"; pausar; return; }

    confirmar "Marcar $DISCO_FALHO como falho e remover?" || return
    mdadm "${RAID_DEVICE}" --fail "$DISCO_FALHO" 2>/dev/null || true
    sleep 2
    mdadm "${RAID_DEVICE}" --remove "$DISCO_FALHO" 2>/dev/null || true
    log "Disco removido do RAID: $DISCO_FALHO"
    ok "Disco marcado como falho e removido."
    echo ""
    info "Agora substitua fisicamente o disco e execute:"
    echo -e "  ${CYAN}mdadm ${RAID_DEVICE} --add /dev/sdNOVO${NC}"
    echo -e "  ${CYAN}watch cat /proc/mdstat${NC}  (para acompanhar a reconstrução)"
    pausar
}

# =============================================================================
# 9. LOGS
# =============================================================================
menu_logs() {
    while true; do
        clear
        header "LOGS DO SISTEMA"
        echo -e "  ${GREEN}[1]${NC}  Log de instalação"
        echo -e "  ${GREEN}[2]${NC}  Log do Samba (acesso por cliente)"
        echo -e "  ${GREEN}[3]${NC}  Log de auditoria (operações de arquivo)"
        echo -e "  ${GREEN}[4]${NC}  Log do painel web"
        echo -e "  ${GREEN}[5]${NC}  Log do RAID"
        echo -e "  ${GREEN}[6]${NC}  Log deste script (admin)"
        echo -e "  ${GREEN}[7]${NC}  Log em tempo real do Samba"
        echo -e "  ${GREEN}[0]${NC}  Voltar"
        echo ""
        echo -en "  Opção: "
        read -r OPT
        case "$OPT" in
            1) less /var/log/samba_setup.log 2>/dev/null || info "Log não encontrado" ;;
            2)
                echo -en "  IP do cliente (Enter para todos): "
                read -r IP
                if [[ -n "$IP" ]]; then
                    grep "$IP" /var/log/samba/log.* 2>/dev/null | less
                else
                    less /var/log/samba/log.smbd 2>/dev/null || ls /var/log/samba/
                fi
                ;;
            3) journalctl | grep "smbd_audit" | less ;;
            4) less /var/log/samba_panel.log 2>/dev/null || info "Log não encontrado" ;;
            5) less /var/log/raid_check.log 2>/dev/null || info "Log não encontrado" ;;
            6) less "$LOG_FILE" 2>/dev/null || info "Log não encontrado" ;;
            7) journalctl -fu smbd ;;
            0) return ;;
        esac
        pausar
    done
}

# =============================================================================
# MODO NÃO-INTERATIVO (chamado pelo cron)
# =============================================================================
if [[ "${1:-}" == "--backup-conf" ]]; then
    BACKUP_CONF_DIR="/root/backups/conf"
    mkdir -p "$BACKUP_CONF_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DEST="/tmp/conf_${TIMESTAMP}"
    mkdir -p "$DEST"
    cp "$SMB_CONF" "${DEST}/smb.conf" 2>/dev/null || true
    [[ -f /etc/samba/passdb.tdb ]] && cp /etc/samba/passdb.tdb "${DEST}/passdb.tdb" 2>/dev/null || true
    pdbedit -L -e smbpasswd:${DEST}/samba_users.txt 2>/dev/null || true
    getent group | grep "^grp_" > "${DEST}/linux_groups.txt" 2>/dev/null || true
    tar -czf "${BACKUP_CONF_DIR}/conf_${TIMESTAMP}.tar.gz" -C /tmp "conf_${TIMESTAMP}/"
    rm -rf "$DEST"
    # Manter apenas os 30 backups mais recentes
    ls -t "${BACKUP_CONF_DIR}"/*.tar.gz 2>/dev/null | tail -n +31 | xargs rm -f 2>/dev/null || true
    echo "[$(date)] Backup conf: conf_${TIMESTAMP}.tar.gz" >> "$LOG_FILE"
    exit 0
fi

if [[ "${1:-}" == "--backup-dados" ]]; then
    DEST_DIR="${BACKUP_DIR}/dados_$(date +%Y%m%d)"
    mkdir -p "$DEST_DIR"
    rsync -a --delete --exclude=".recycle/" --exclude="*.tmp" \
        "${SAMBA_ROOT}/" "${DEST_DIR}/" >> "$LOG_FILE" 2>&1
    echo "[$(date)] Backup dados: $DEST_DIR" >> "$LOG_FILE"
    exit 0
fi

# =============================================================================
# ENTRADA PRINCIPAL
# =============================================================================
menu_principal
