#!/bin/bash
# =============================================================================
# CDPNI — Aplicar Tema 1 (Azul Profissional) sem reinstalar
# Executa no servidor onde o painel já está instalado
# Uso: bash aplicar-tema1.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Execute como root: sudo bash aplicar-tema1.sh"

# Detectar qual servidor estamos
IS_GATEWAY=0
IS_SAMBA=0
[[ -f /opt/gateway-panel/app.py ]]          && IS_GATEWAY=1
[[ -f /var/www/samba-panel/public/index.php ]] && IS_SAMBA=1
[[ $IS_GATEWAY -eq 0 && $IS_SAMBA -eq 0 ]]  && err "Nenhum painel encontrado neste servidor."

echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  Aplicando Tema 1 — Azul Profissional        ${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}\n"

# ─────────────────────────────────────────────────────────────────────────────
# GATEWAY
# ─────────────────────────────────────────────────────────────────────────────
if [[ $IS_GATEWAY -eq 1 ]]; then
    info "Detectado: Gateway Panel em /opt/gateway-panel"

    PANEL_DIR="/opt/gateway-panel"
    TMPL="$PANEL_DIR/templates"

    # Backup
    TS=$(date +%Y%m%d_%H%M%S)
    cp "$TMPL/login.html"    "$TMPL/login.html.bak.$TS"
    cp "$TMPL/index.html"    "$TMPL/index.html.bak.$TS"
    log "Backup criado: *.bak.$TS"

    # CSS vars — substituir em todos os templates
    OLD_VARS='--bg:#242c3b;--surf:#2c3548;--surf2:#354159;--surf3:#3e4e6a'
    NEW_VARS='--bg:#0d1b2e;--surf:#112240;--surf2:#163052;--surf3:#1a3a62'

    for f in "$TMPL/login.html" "$TMPL/index.html" "$TMPL/relatorio.html"; do
        [[ -f "$f" ]] || continue
        sed -i \
            "s|--bg:#242c3b;--surf:#2c3548;--surf2:#354159;--surf3:#3e4e6a|--bg:#0d1b2e;--surf:#112240;--surf2:#163052;--surf3:#1a3a62|g" \
            "$f"
        sed -i \
            "s|--border:#354159;--border2:#3e4e6a|--border:#1e4070;--border2:#255090|g" \
            "$f"
        sed -i \
            "s|--text:#dde6f0;--text2:#b8c8d8;--text3:#7a90a8;--text4:#566578|--text:#d4e8f8;--text2:#9abcd4;--text3:#5a8ab4;--text4:#3a5e7a|g" \
            "$f"
        sed -i \
            "s|--green:#4db860;--green-bg:#1a2f1e;--green-bd:#2a4a30|--green:#3fd87a;--green-bg:#0a2518;--green-bd:#1a4a30|g" \
            "$f"
        sed -i \
            "s|--blue:#5ba8f5;--blue-bg:#182540;--blue-bd:#264268|--blue:#5ab8ff;--blue-bg:#081828;--blue-bd:#102840|g" \
            "$f"
        sed -i \
            "s|--red:#e05548;--red-bg:#2e1a1c;--red-bd:#4a282c|--red:#ff5a5a;--red-bg:#2a0f0f;--red-bd:#4a1f1f|g" \
            "$f"
        sed -i \
            "s|--yellow:#d4963a;--yellow-bg:#2a2218;--yellow-bd:#3e3420|--yellow:#ffb830;--yellow-bg:#2a1f08;--yellow-bd:#4a3510|g" \
            "$f"
        sed -i \
            "s|--cyan:#30bfd0;--cyan-bg:#122830;--cyan-bd:#1c3e4a|--cyan:#30d8f0;--cyan-bg:#081e28;--cyan-bd:#103040|g" \
            "$f"
        sed -i \
            "s|--purple:#9b7af0;--purple-bg:#201630;--purple-bd:#342248|--purple:#9a7aff;--purple-bg:#160e28;--purple-bd:#2a1e48|g" \
            "$f"
        sed -i \
            "s|--orange:#e07a32;--orange-bg:#281c10;--orange-bd:#3c2a18|--orange:#ff9a3a;--orange-bg:#281408;--orange-bd:#3c2010|g" \
            "$f"
        # Brand icon
        sed -i \
            "s|background:#3a8a4a;border-radius:7px|background:linear-gradient(135deg,#1a6fdf,#3a8fff);border-radius:7px|g" \
            "$f"
        sed -i \
            "s|--sans:'Inter',sans-serif|--sans:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif|g" \
            "$f"
        log "$(basename $f) atualizado"
    done

    # Reiniciar painel
    systemctl restart gateway-panel 2>/dev/null || true
    log "gateway-panel reiniciado"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SAMBA
# ─────────────────────────────────────────────────────────────────────────────
if [[ $IS_SAMBA -eq 1 ]]; then
    info "Detectado: Samba Panel em /var/www/samba-panel"

    PANEL_FILE="/var/www/samba-panel/public/index.php"
    TS=$(date +%Y%m%d_%H%M%S)
    cp "$PANEL_FILE" "${PANEL_FILE}.bak.$TS"
    log "Backup criado: index.php.bak.$TS"

    # Substituir CSS vars
    sed -i \
        "s|--bg:#0d1117;--bg2:#161b22;--bg3:#21262d;--border:#30363d;--text:#e6edf3;--muted:#8b949e;--accent:#2ea043;--accent2:#1f6feb;--danger:#da3633|--bg:#0d1b2e;--bg2:#112240;--bg3:#163052;--border:#1e4070;--text:#d4e8f8;--muted:#5a8ab4;--accent:#3a8fff;--accent2:#1a6fdf;--danger:#ff5a5a;--success:#3fd87a;--warning:#ffb830|g" \
        "$PANEL_FILE"

    # Login background
    sed -i \
        "s|background:radial-gradient(ellipse at 50% 0%,#0d2436,var(--bg) 70%)|background:var(--bg)|g" \
        "$PANEL_FILE"

    # Login box
    sed -i \
        "s|background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:2.5rem 2rem;width:340px;box-shadow:0 16px 48px rgba(0,0,0,.4)|background:var(--bg2);border:1px solid var(--border);border-radius:12px;overflow:hidden;width:340px|g" \
        "$PANEL_FILE"

    # Brand icon gradient
    sed -i \
        "s|background:linear-gradient(135deg,var(--accent2),var(--accent));border-radius:12px|background:linear-gradient(135deg,#1a6fdf,#3a8fff);border-radius:12px|g" \
        "$PANEL_FILE"

    # Sidebar logo text
    sed -i \
        "s|<h2>📁 CDPNI</h2><small>Painel de Arquivos</small>|<h2>Samba CDPNI</h2><small>v7.5 — Arquivos</small>|g" \
        "$PANEL_FILE"

    # Nav item active state
    sed -i \
        "s|background:rgba(31,111,235,.15);color:var(--accent2);border-right:2px solid var(--accent2)|background:#081828;color:var(--accent);border-color:#102840;border-radius:6px|g" \
        "$PANEL_FILE"

    # Stat card border top
    sed -i \
        "s|\.stat-card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:1rem 1.125rem}|.stat-card{background:var(--bg2);border:1px solid var(--border);border-top:3px solid var(--accent);border-radius:8px;padding:10px 12px}|g" \
        "$PANEL_FILE"

    # Card header background
    sed -i \
        "s|\.card-header{padding:.875rem 1.25rem;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.75rem}|.card-header{padding:10px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.6rem;background:var(--bg3)}|g" \
        "$PANEL_FILE"

    # Table header background
    sed -i \
        "s|background:var(--bg2);padding:8px 1.25rem;text-align:left|background:var(--bg3);padding:8px 14px;text-align:left|g" \
        "$PANEL_FILE"

    # Fix tag colors
    sed -i 's|background:rgba(46,160,67,.15);border-color:rgba(46,160,67,.3);color:#7ee787|background:#0a2518;border-color:#1a4a30;color:#3fd87a|g' "$PANEL_FILE"
    sed -i 's|background:rgba(218,54,51,.15);border-color:rgba(218,54,51,.3);color:#ffa198|background:#2a0f0f;border-color:#4a1f1f;color:#ff5a5a|g' "$PANEL_FILE"
    sed -i 's|background:rgba(46,160,67,.2);border-color:var(--accent);color:#7ee787|background:#0a2518;border-color:#1a4a30;color:#3fd87a|g' "$PANEL_FILE"
    sed -i 's|background:rgba(218,54,51,.2);border-color:var(--danger);color:#ffa198|background:#2a0f0f;border-color:#4a1f1f;color:#ff5a5a|g' "$PANEL_FILE"
    log "Tags e toasts corrigidos"

    # Restart nginx/php
    systemctl reload nginx  2>/dev/null || true
    systemctl restart php8.3-fpm 2>/dev/null || true
    log "Nginx/PHP recarregado"
fi

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Tema 1 aplicado com sucesso!                ${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo ""
[[ $IS_GATEWAY -eq 1 ]] && echo -e "  ${CYAN}Gateway:${NC} https://192.168.0.1:5000"
[[ $IS_SAMBA -eq 1 ]]   && echo -e "  ${CYAN}Samba:${NC}   https://192.168.0.11"
echo ""
echo -e "  ${YELLOW}Para reverter: restaure os arquivos .bak.*${NC}"
echo ""
