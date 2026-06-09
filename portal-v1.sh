#!/bin/bash
# =============================================================================
# PORTAL CDPNI — v1.0
# Portal de acesso às pastas Samba via navegador
# Execute no servidor Samba: sudo bash portal-v1.sh
# Acesso: https://192.168.0.11  ou  https://cdpni
# =============================================================================
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GRN}[$(date '+%H:%M:%S')] ✔ $*${NC}"; }
warn()   { echo -e "${YLW}[$(date '+%H:%M:%S')] ⚠ $*${NC}"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}"; exit 1; }
header() { echo -e "\n${BLD}${CYN}══════════════════════════════${NC}";
           echo -e "${BLD}${CYN}  $*${NC}";
           echo -e "${BLD}${CYN}══════════════════════════════${NC}"; }
[[ $EUID -ne 0 ]] && error "Execute como root"

SAMBA_IP="192.168.0.11"
SAMBA_NAME="cdpni"
SAMBA_ROOT="/mnt/raid/shares"
APP_DIR="/opt/cdpni-portal"
VENV="${APP_DIR}/venv"
DATA_DIR="${APP_DIR}/data"
UPLOADS_DIR="${DATA_DIR}/uploads"
SERVICE="cdpni-portal"
ADMIN_USER="jpfagiani"
ROOT_USERS="sambadmin jpfagiani rcborges cpd supervisao"

# Mapa: nome_exibição → (pasta_disco, grupo_linux, ícone)
declare -A SHARE_MAP=(
    ["Administrativo"]="Administrativo:grp_administrativo:ti-users"
    ["AEVP"]="Aevp:grp_aevp:ti-certificate"
    ["Almoxarifado"]="Almoxarifado:grp_almoxarifado:ti-package"
    ["Cadastro"]="Cadastro:grp_cadastro:ti-id-badge"
    ["Canil"]="Canil:grp_canil:ti-paw"
    ["Chefia Turno I"]="Chefia_Turno_I:grp_chefia_1:ti-shield-star"
    ["Chefia Turno II"]="Chefia_Turno_II:grp_chefia_2:ti-shield-star"
    ["Chefia Turno III"]="Chefia_Turno_III:grp_chefia_3:ti-shield-star"
    ["Chefia Turno IV"]="Chefia_Turno_IV:grp_chefia_4:ti-shield-star"
    ["CIPA"]="Cipa:grp_cipa:ti-heart-handshake"
    ["Conexão Familiar"]="Conexao_Familiar:grp_conexao_familiar:ti-friends"
    ["CPD"]="CPD:grp_cpd:ti-server"
    ["CSD"]="csd:grp_csd:ti-building"
    ["Diretoria Geral"]="Diretoria_Geral:grp_diretoria:ti-crown"
    ["Educação"]="Educacao:grp_educacao:ti-school"
    ["Finanças"]="Financas:grp_financas:ti-cash"
    ["Inclusão"]="Inclusao:grp_inclusao:ti-user-plus"
    ["Infraestrutura"]="Infraestrutura:grp_infraestrutura:ti-tool"
    ["Núcleo de Pessoal"]="Nucleo_de_Pessoal:grp_nucleo_pessoal:ti-file-text"
    ["Papel de Parede"]="Papel_de_Parede:grp_papel_parede:ti-photo"
    ["Planilhas"]="Planilhas:grp_planilhas:ti-table"
    ["Portaria I"]="Portaria_Turno_I:grp_portaria:ti-door"
    ["Portaria II"]="Portaria_Turno_II:grp_portaria:ti-door"
    ["Portaria III"]="Portaria_Turno_III:grp_portaria:ti-door"
    ["Portaria IV"]="Portaria_Turno_IV:grp_portaria:ti-door"
    ["Público"]="Publico:grp_publico:ti-folder-open"
    ["Rol de Visitas"]="Rol_de_Visitas:grp_rol_visitas:ti-eye"
    ["Saúde"]="Saude:grp_saude:ti-first-aid-kit"
    ["Scanner"]="Scanner:grp_scanner:ti-scan"
    ["SIMIC"]="Simic:grp_simic:ti-database"
    ["Sindicância"]="Sindicancia:grp_sindicancia:ti-gavel"
    ["Supervisão"]="Supervisao:grp_supervisao:ti-shield-check"
)

# ===========================================================================
# 1. DEPENDÊNCIAS
# ===========================================================================
header "1. Dependências"
apt-get update -qq
apt-get install -y python3 python3-pip python3-pam nginx acl 2>/dev/null && log "Pacotes OK"
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
apt-get install -y "python3${PY_VER}-venv" 2>/dev/null || apt-get install -y python3.13-venv 2>/dev/null || true

# ===========================================================================
# 2. VIRTUALENV
# ===========================================================================
header "2. Virtualenv"
mkdir -p "${APP_DIR}" "${DATA_DIR}" "${UPLOADS_DIR}"

if [[ -d "${VENV}" ]]; then
    warn "Venv existente removido para garantir system-site-packages"
    rm -rf "${VENV}"
fi
python3 -m venv --system-site-packages "${VENV}" && log "Venv criado (system-site-packages)" || {
    warn "Falhou — tentando sem system-site-packages"
    python3 -m venv "${VENV}"
    # Copiar pam manualmente
    PAM_FILE=$(python3 -c "import pam; print(pam.__file__)" 2>/dev/null || true)
    [[ -n "$PAM_FILE" ]] && {
        SITE=$("${VENV}/bin/python3" -c "import site; print(site.getsitepackages()[0])")
        cp "$PAM_FILE" "${SITE}/" 2>/dev/null && log "pam copiado para venv"
    }
}
"${VENV}/bin/pip" install --quiet flask 2>/dev/null || true
"${VENV}/bin/python3" -c "import pam; print('PAM OK')" && log "PAM funcionando" || warn "PAM com problema"

# ===========================================================================
# 3. USUÁRIO E PERMISSÕES
# ===========================================================================
header "3. Usuário cdpni e PAM"
id cdpni &>/dev/null || useradd -r -s /bin/false -d "${APP_DIR}" cdpni

SHADOW_GRP=""
for g in shadow _shadow; do getent group "$g" &>/dev/null && { SHADOW_GRP="$g"; break; }; done
[[ -z "$SHADOW_GRP" ]] && { groupadd shadow 2>/dev/null || true; SHADOW_GRP="shadow"; }
chmod g+r /etc/shadow 2>/dev/null || true
chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true
usermod -aG "${SHADOW_GRP}" cdpni 2>/dev/null && log "cdpni → grupo ${SHADOW_GRP}"

cat > /etc/pam.d/cdpni-portal << 'PAMEOF'
auth    required   pam_unix.so
account required   pam_unix.so
PAMEOF

# ACL nas pastas Samba
[[ -d "${SAMBA_ROOT}" ]] && {
    command -v setfacl &>/dev/null && setfacl -R -m u:cdpni:rwx "${SAMBA_ROOT}" 2>/dev/null || \
        chmod -R o+rwx "${SAMBA_ROOT}" 2>/dev/null || true
    log "Permissões Samba OK"
}

# ===========================================================================
# 4. DADOS INICIAIS
# ===========================================================================
header "4. Dados iniciais"
[[ ! -f "${DATA_DIR}/portal_data.json" ]] && cat > "${DATA_DIR}/portal_data.json" << 'JSONEOF'
{
  "banners": [
    {
      "title": "Bem-vindo ao Portal CDPNI",
      "body": "Clique em uma pasta na lista à esquerda para abrir no Windows Explorer. Pastas com cadeado requerem autorização do administrador.",
      "date": "",
      "img": ""
    }
  ],
  "notices": [
    { "text": "Sistema de arquivos operacional.", "date": "", "type": "ok" }
  ],
  "right_info": [
    { "label": "Suporte TI", "value": "jpfagiani" },
    { "label": "Servidor",   "value": "CDPNI" },
    { "label": "RAID 5",     "value": "5 × 2TB (~8TB)" }
  ]
}
JSONEOF

chown -R cdpni:cdpni "${APP_DIR}"
chmod -R 750 "${APP_DIR}"
chmod 770 "${DATA_DIR}" "${UPLOADS_DIR}"

# ===========================================================================
# 5. APP.PY
# ===========================================================================
header "5. Criando app.py"
cat > "${APP_DIR}/app.py" << 'PYEOF'
#!/usr/bin/env python3
"""Portal CDPNI — v1.0 | Flask + PAM"""
import os, json, shutil, mimetypes, subprocess
from pathlib import Path
from datetime import datetime
from functools import wraps
import pam
from flask import Flask, request, session, redirect, url_for, send_file, jsonify, render_template_string, abort, Response

app = Flask(__name__)
app.secret_key = os.urandom(32)
app.config["MAX_CONTENT_LENGTH"] = 512 * 1024 * 1024

SAMBA_IP   = "192.168.0.11"
SAMBA_NAME = "cdpni"
SAMBA_ROOT = Path("/mnt/raid/shares")
DATA_FILE  = Path("/opt/cdpni-portal/data/portal_data.json")
UPLOADS    = Path("/opt/cdpni-portal/data/uploads")
ADMIN_USERS = {"sambadmin","jpfagiani","rcborges","cpd","supervisao"}
VERSION    = "1.0"
ROOT_USERS = {"sambadmin","jpfagiani","rcborges","cpd","supervisao"}

def is_admin(user):
    return user in ADMIN_USERS

# Mapa completo: label → (pasta_disco, grupo, ícone)
SHARES = {
    "Administrativo":   ("Administrativo",    "grp_administrativo",    "ti-users"),
    "AEVP":             ("Aevp",              "grp_aevp",              "ti-certificate"),
    "Almoxarifado":     ("Almoxarifado",       "grp_almoxarifado",      "ti-package"),
    "Cadastro":         ("Cadastro",           "grp_cadastro",          "ti-id-badge"),
    "Canil":            ("Canil",              "grp_canil",             "ti-paw"),
    "Chefia Turno I":   ("Chefia_Turno_I",     "grp_chefia_1",          "ti-shield-star"),
    "Chefia Turno II":  ("Chefia_Turno_II",    "grp_chefia_2",          "ti-shield-star"),
    "Chefia Turno III": ("Chefia_Turno_III",   "grp_chefia_3",          "ti-shield-star"),
    "Chefia Turno IV":  ("Chefia_Turno_IV",    "grp_chefia_4",          "ti-shield-star"),
    "CIPA":             ("Cipa",               "grp_cipa",              "ti-heart-handshake"),
    "Conexão Familiar": ("Conexao_Familiar",   "grp_conexao_familiar",  "ti-friends"),
    "CPD":              ("CPD",                "grp_cpd",               "ti-server"),
    "CSD":              ("csd",                "grp_csd",               "ti-building"),
    "Diretoria Geral":  ("Diretoria_Geral",    "grp_diretoria",         "ti-crown"),
    "Educação":         ("Educacao",           "grp_educacao",          "ti-school"),
    "Finanças":         ("Financas",           "grp_financas",          "ti-cash"),
    "Inclusão":         ("Inclusao",           "grp_inclusao",          "ti-user-plus"),
    "Infraestrutura":   ("Infraestrutura",     "grp_infraestrutura",    "ti-tool"),
    "Núcleo de Pessoal":("Nucleo_de_Pessoal",  "grp_nucleo_pessoal",    "ti-file-text"),
    "Papel de Parede":  ("Papel_de_Parede",    "grp_papel_parede",      "ti-photo"),
    "Planilhas":        ("Planilhas",          "grp_planilhas",         "ti-table"),
    "Portaria I":       ("Portaria_Turno_I",   "grp_portaria",          "ti-door"),
    "Portaria II":      ("Portaria_Turno_II",  "grp_portaria",          "ti-door"),
    "Portaria III":     ("Portaria_Turno_III", "grp_portaria",          "ti-door"),
    "Portaria IV":      ("Portaria_Turno_IV",  "grp_portaria",          "ti-door"),
    "Público":          ("Publico",            "grp_publico",           "ti-folder-open"),
    "Rol de Visitas":   ("Rol_de_Visitas",     "grp_rol_visitas",       "ti-eye"),
    "Saúde":            ("Saude",              "grp_saude",             "ti-first-aid-kit"),
    "Scanner":          ("Scanner",            "grp_scanner",           "ti-scan"),
    "SIMIC":            ("Simic",              "grp_simic",             "ti-database"),
    "Sindicância":      ("Sindicancia",        "grp_sindicancia",       "ti-gavel"),
    "Supervisão":       ("Supervisao",         "grp_supervisao",        "ti-shield-check"),
}

def get_groups(user):
    try:
        out = subprocess.check_output(["id","-Gn",user], stderr=subprocess.DEVNULL, text=True)
        return set(out.strip().split())
    except: return set()

def can_access(user, label):
    if user in ROOT_USERS: return True
    info = SHARES.get(label)
    return info is not None and info[1] in get_groups(user)

def auth_required(f):
    @wraps(f)
    def d(*a,**k):
        if "user" not in session: return redirect(url_for("login"))
        return f(*a,**k)
    return d

def load_data():
    try:
        if DATA_FILE.exists(): return json.loads(DATA_FILE.read_text())
    except: pass
    return {"banners":[],"notices":[],"right_info":[]}

def save_data(d): DATA_FILE.parent.mkdir(parents=True,exist_ok=True); DATA_FILE.write_text(json.dumps(d,ensure_ascii=False,indent=2))

def safe_path(disk, rel=""):
    base = (SAMBA_ROOT/disk).resolve()
    full = (base/rel.lstrip("/")).resolve() if rel else base
    if not str(full).startswith(str(base)): raise ValueError("Caminho inválido")
    return base, full

def fmt_size(n):
    if not n: return "—"
    for u in ["B","KB","MB","GB","TB"]:
        if n < 1024: return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TB"

def file_icon(ext):
    return {"pdf":"ti-file-type-pdf","docx":"ti-file-type-docx","doc":"ti-file-type-docx",
            "xlsx":"ti-file-spreadsheet","xls":"ti-file-spreadsheet","csv":"ti-file-spreadsheet",
            "pptx":"ti-presentation","ppt":"ti-presentation",
            "jpg":"ti-photo","jpeg":"ti-photo","png":"ti-photo","gif":"ti-photo","webp":"ti-photo",
            "mp4":"ti-video","avi":"ti-video","mkv":"ti-video",
            "mp3":"ti-music","wav":"ti-music",
            "zip":"ti-file-zip","rar":"ti-file-zip","7z":"ti-file-zip",
            "txt":"ti-file-text","log":"ti-file-text"}.get(ext.lower(),"ti-file")

CSS = """
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
:root{--tb:#1c3557;--bg:#f0f4f8;--bgw:#fff;--bd:#d0d7de;--bds:#b0bec8;
  --tx:#1a2a3a;--txs:#4a5a6a;--txm:#7a8a9a;--ac:#1c5fad;--acb:#e8f0fb;
  --gn:#2a7a3a;--gnb:#e8f5ec;--gnd:#9ad0aa;--rd:#a03030;--rdb:#fef0f0;--rdd:#f0b0b0;
  --am:#8a5a00;--amb:#fff8e6}
html,body{height:100%;background:var(--bg);color:var(--tx)}
body{display:flex;flex-direction:column;overflow:hidden}
/* LOGIN */
.login-wrap{min-height:100vh;background:linear-gradient(150deg,#0d2340,#1a3a5c);display:flex;align-items:center;justify-content:center;padding:20px}
.login-box{background:#fff;border-radius:14px;padding:40px 36px;width:400px;box-shadow:0 20px 60px rgba(0,0,0,.4);border:1px solid var(--bd)}
.login-logo{text-align:center;margin-bottom:28px}
.login-logo .crest{width:68px;height:68px;background:var(--acb);border-radius:50%;display:inline-flex;align-items:center;justify-content:center;border:2px solid #b5d4f4;margin-bottom:12px}
.login-logo .crest i{font-size:30px;color:var(--ac)}
.login-logo h1{font-size:15px;font-weight:600;line-height:1.4;color:var(--tx)}
.login-logo p{font-size:12px;color:var(--txm);margin-top:5px}
.login-box label{display:block;font-size:12px;font-weight:600;color:var(--txs);margin:16px 0 5px}
.login-box input{width:100%;border:1.5px solid #c0ccd8;border-radius:8px;padding:11px 13px;font-size:14px;color:var(--tx);font-family:inherit;outline:none;background:#fafbfc}
.login-box input:focus{border-color:var(--ac);box-shadow:0 0 0 3px rgba(28,95,173,.15)}
.login-btn{width:100%;margin-top:22px;padding:12px;background:var(--tb);color:#fff;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;font-family:inherit}
.login-btn:hover{background:#244e7a}
.login-err{margin-top:10px;font-size:12px;color:var(--rd);text-align:center;background:var(--rdb);border-radius:6px;padding:6px 10px;display:none}
.login-err.show{display:block}
/* TOPBAR */
.topbar{background:var(--tb);height:48px;padding:0 16px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.tb-left{display:flex;align-items:center;gap:10px;min-width:0}
.tb-logo{width:32px;height:32px;border-radius:8px;background:rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;flex-shrink:0}
.tb-logo i{color:#fff;font-size:16px}
.tb-info{min-width:0}
.tb-info .t1{font-size:11px;font-weight:500;color:#e8f0f8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tb-info .t2{font-size:9px;color:#7a9ec0}
.tb-right{display:flex;align-items:center;gap:6px;flex-shrink:0}
.tb-pill{display:flex;align-items:center;gap:4px;background:rgba(255,255,255,.1);border:0.5px solid rgba(255,255,255,.2);border-radius:20px;padding:4px 10px;color:#c0d8f0;font-size:11px}
.tb-pill i{font-size:12px}
.tb-btn{display:flex;align-items:center;gap:3px;padding:4px 9px;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;color:#a0c4e0;font-size:10px;cursor:pointer;background:transparent;font-family:inherit;text-decoration:none}
.tb-btn:hover{background:rgba(255,255,255,.1)}
.tb-btn i{font-size:12px}
/* LAYOUT */
.app-body{display:flex;flex:1;overflow:hidden}
/* SIDEBAR */
.sidebar{width:195px;min-width:195px;background:var(--bgw);border-right:0.5px solid var(--bd);display:flex;flex-direction:column;overflow:hidden;flex-shrink:0}
.sl-hdr{padding:10px 12px 8px;border-bottom:0.5px solid #eef0f2;display:flex;align-items:center;justify-content:space-between}
.sl-hdr span{font-size:9px;font-weight:500;color:var(--txm);text-transform:uppercase;letter-spacing:.8px}
.sl-search{padding:7px 10px;border-bottom:0.5px solid #eef0f2}
.sl-search input{width:100%;background:var(--bg);border:0.5px solid var(--bd);border-radius:6px;padding:5px 8px;font-size:11px;color:var(--tx);font-family:inherit;outline:none}
.sl-list{flex:1;overflow-y:auto;padding:4px 0}
.sl-item{display:flex;align-items:center;gap:8px;padding:7px 12px;cursor:pointer;border-left:2px solid transparent;text-decoration:none}
.sl-item:hover{background:var(--bg)}
.sl-item.active{background:var(--acb);border-left-color:var(--ac)}
.sl-item i.ico{font-size:13px;color:var(--txm);flex-shrink:0}
.sl-item.active i.ico{color:var(--ac)}
.sl-item .nm{font-size:11px;color:var(--txs);flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sl-item.active .nm{color:var(--ac);font-weight:500}
.sl-item .lk{font-size:10px;color:#c0d0e0}
.sl-item.noaccess .nm{color:var(--txm)}
.sl-item.noaccess i.ico{color:#c0d0e0}
/* CENTRO */
.center{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}
/* BANNER */
.banner-outer{background:var(--bgw);border-bottom:0.5px solid var(--bd);flex-shrink:0;overflow:hidden;height:138px;position:relative}
.banner-track{display:flex;transition:transform .45s ease;height:138px}
.banner-slide{min-width:100%;display:flex;flex-direction:row}
.slide-photo{width:200px;min-width:200px;height:138px;overflow:hidden;display:flex;align-items:center;justify-content:center;background:#eef0f2;flex-shrink:0}
.slide-photo img{width:100%;height:100%;object-fit:cover}
.slide-photo .ph{display:flex;flex-direction:column;align-items:center;gap:6px}
.slide-photo .ph i{font-size:28px;color:#b0c0d0}
.slide-photo .ph span{font-size:10px;color:#9aaab8}
.slide-txt{flex:1;padding:12px 14px;display:flex;flex-direction:column;min-width:0}
.slide-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px}
.slide-badge{display:inline-flex;align-items:center;gap:4px;background:var(--acb);color:var(--ac);font-size:9px;font-weight:500;padding:3px 9px;border-radius:20px;text-transform:uppercase;letter-spacing:.4px}
.slide-badge i{font-size:11px}
.slide-nav{display:flex;align-items:center;gap:5px}
.slide-nav button{background:var(--bg);border:0.5px solid var(--bd);border-radius:4px;padding:2px 7px;cursor:pointer;font-size:13px;color:var(--txs);font-family:inherit}
.slide-counter{font-size:10px;color:var(--txm)}
.slide-title{font-size:14px;font-weight:500;color:var(--tx);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-bottom:4px}
.slide-body{font-size:11px;color:var(--txs);line-height:1.5;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.slide-footer{display:flex;align-items:center;justify-content:space-between;margin-top:auto;padding-top:8px}
.slide-date{font-size:10px;color:var(--txm)}
.slide-dots{display:flex;gap:5px}
.slide-dot{width:6px;height:6px;border-radius:50%;background:var(--bd);cursor:pointer;border:none;padding:0;transition:background .2s}
.slide-dot.active{background:var(--ac)}
.banner-manage{position:absolute;bottom:8px;right:12px;display:flex;align-items:center;gap:4px;background:var(--tb);color:#fff;border:none;border-radius:5px;padding:3px 9px;font-size:9px;cursor:pointer;font-family:inherit;text-decoration:none}
.banner-empty{display:flex;align-items:center;justify-content:center;height:100%;color:var(--txm);font-size:12px;gap:8px}
/* FILE MANAGER */
.fm{flex:1;padding:12px 14px;display:flex;flex-direction:column;gap:8px;overflow:hidden;min-height:0}
.fm-hdr{display:flex;align-items:flex-start;justify-content:space-between;flex-shrink:0;flex-wrap:wrap;gap:8px}
.fm-title{display:flex;align-items:center;gap:8px;min-width:0}
.fm-title i{font-size:18px;color:var(--ac);flex-shrink:0}
.fm-title-txt{min-width:0}
.fm-title-txt h3{font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fm-path{font-size:10px;color:var(--txm);font-family:monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block;cursor:pointer}
.fm-path:hover{color:var(--ac)}
.fm-btns{display:flex;gap:5px;flex-wrap:wrap;flex-shrink:0}
.fmbtn{display:inline-flex;align-items:center;gap:4px;background:var(--bgw);border:0.5px solid var(--bds);border-radius:5px;padding:5px 10px;font-size:11px;color:var(--txs);cursor:pointer;font-family:inherit;white-space:nowrap}
.fmbtn:hover{background:var(--bg)}
.fmbtn i{font-size:12px}
.fmbtn.prim{background:var(--tb);border-color:var(--tb);color:#fff}
.fmbtn.prim:hover{background:#244e7a}
.fmbtn.grn{background:var(--gnb);border-color:var(--gnd);color:var(--gn)}
.fmbtn.red{background:var(--rdb);border-color:var(--rdd);color:var(--rd)}
.fmbtn:disabled{opacity:.4;cursor:default}
.fm-wrap{flex:1;background:var(--bgw);border:0.5px solid var(--bd);border-radius:6px;overflow-y:auto;min-height:0}
.fmbtn.red{background:var(--rdb);border-color:var(--rdd);color:var(--rd)}
table.fm{width:100%;border-collapse:collapse;font-size:12px}
table.fm th{background:var(--bg);padding:7px 10px;text-align:left;font-size:10px;font-weight:500;color:var(--txm);text-transform:uppercase;letter-spacing:.4px;border-bottom:0.5px solid var(--bd);position:sticky;top:0;z-index:1}
table.fm td{padding:6px 10px;border-bottom:0.5px solid #eef0f2;vertical-align:middle}
table.fm tr:last-child td{border-bottom:none}
table.fm tr:hover td{background:#fafbfc}
table.fm tr.selected td{background:var(--acb)}
.f-ico i{font-size:15px;color:#4a8ad4}
.f-ico.folder i{color:#d4931a}
.f-name{cursor:pointer;color:var(--tx);font-size:12px}
.f-name:hover{color:var(--ac);text-decoration:underline}
.f-size{color:var(--txm);text-align:right;font-family:monospace;font-size:11px}
.f-date{color:var(--txm);text-align:right;font-size:11px}
.f-acts{text-align:right;white-space:nowrap}
.fact{display:inline-flex;align-items:center;gap:2px;background:var(--bg);border:none;border-radius:4px;padding:3px 6px;font-size:10px;color:var(--txs);cursor:pointer;margin-left:2px;font-family:inherit}
.fact:hover{background:var(--bd)}
.fact.g{background:var(--gnb);color:var(--gn)}
.fact.r{background:var(--rdb);color:var(--rd)}
.fact i{font-size:11px}
.fm-empty{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;gap:10px;color:var(--txm);padding:40px;text-align:center}
.fm-empty i{font-size:40px}
.no-access{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;gap:12px;padding:40px;text-align:center}
.no-access i{font-size:48px;color:#c0d0e0}
.no-access h3{font-size:15px;font-weight:500}
.no-access p{font-size:12px;color:var(--txs);max-width:300px;line-height:1.5}
.no-access .na-path{font-size:11px;background:var(--bg);border:0.5px solid var(--bds);border-radius:5px;padding:4px 10px;font-family:monospace;color:var(--txm)}
.drop-zone{border:2px dashed var(--bds);border-radius:6px;padding:14px;text-align:center;font-size:11px;color:var(--txm);display:none;flex-shrink:0}
.drop-zone.active{background:var(--acb);border-color:var(--ac)}
/* SIDEBAR DIREITA */
.right-col{width:180px;min-width:180px;background:var(--bgw);border-left:0.5px solid var(--bd);overflow-y:auto;flex-shrink:0;padding:10px}
.rc{background:var(--bg);border:0.5px solid var(--bd);border-radius:8px;padding:10px;margin-bottom:10px}
.rc-title{font-size:9px;font-weight:500;color:var(--txm);text-transform:uppercase;letter-spacing:.8px;margin-bottom:8px;display:flex;align-items:center;gap:4px}
.rc-title i{font-size:12px}
.rc-row{display:flex;justify-content:space-between;align-items:center;margin-bottom:4px;gap:6px}
.rc-lbl{font-size:10px;color:var(--txm);flex-shrink:0}
.rc-val{font-size:10px;font-weight:500;text-align:right;word-break:break-word}
.dot-on{width:6px;height:6px;border-radius:50%;background:var(--gn);display:inline-block;margin-right:3px}
.notice{display:flex;gap:6px;margin-bottom:6px;padding-bottom:6px;border-bottom:0.5px solid #e8ecf0}
.notice:last-child{border-bottom:none;margin-bottom:0;padding-bottom:0}
.notice i{font-size:12px;color:#4a8ad4;flex-shrink:0;margin-top:1px}
.notice.w i{color:#c07820}
.notice.ok i{color:var(--gn)}
.notice-txt{font-size:10px;color:var(--txs);line-height:1.4}
.notice-dt{font-size:9px;color:var(--txm);margin-top:2px}
.acct-btn{display:flex;align-items:center;gap:5px;background:var(--bgw);border:0.5px solid var(--bds);border-radius:5px;padding:6px 8px;font-size:10px;color:var(--txs);cursor:pointer;width:100%;margin-bottom:5px;font-family:inherit;text-decoration:none}
.acct-btn:hover{background:var(--bg)}
.acct-btn i{font-size:12px}
/* STATUSBAR */
.statusbar{background:var(--bgw);border-top:0.5px solid var(--bd);height:28px;padding:0 16px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.statusbar span{font-size:9px;color:var(--txm)}
.st-on{display:flex;align-items:center;gap:4px;font-size:9px;color:var(--gn)}
/* MODAL */
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:900;display:flex;align-items:center;justify-content:center;padding:16px}
.modal{background:var(--bgw);border-radius:12px;padding:24px;width:480px;max-width:100%;max-height:90vh;overflow-y:auto;border:0.5px solid var(--bd)}
.modal h2{font-size:15px;font-weight:500;margin-bottom:16px;display:flex;align-items:center;gap:8px}
.modal h2 i{font-size:18px;color:var(--ac)}
.modal label{display:block;font-size:11px;font-weight:500;color:var(--txs);margin:12px 0 4px}
.modal input,.modal textarea,.modal select{width:100%;border:0.5px solid var(--bds);border-radius:6px;padding:8px 10px;font-size:13px;color:var(--tx);font-family:inherit;outline:none;background:var(--bgw)}
.modal input:focus,.modal textarea:focus{border-color:var(--ac)}
.modal textarea{resize:vertical;min-height:70px}
.modal-footer{display:flex;justify-content:flex-end;gap:8px;margin-top:20px}
.modal-footer button{padding:8px 16px;border-radius:6px;font-size:12px;cursor:pointer;border:none;font-family:inherit}
.btn-cancel{background:var(--bg);color:var(--txs)}
.btn-ok{background:var(--tb);color:#fff}
.btn-ok:hover{background:#244e7a}
.btn-del{background:var(--rdb);color:var(--rd);border:0.5px solid var(--rdd)!important}
.admin-item{background:var(--bg);border:0.5px solid var(--bd);border-radius:6px;padding:10px;margin-bottom:8px;position:relative}
.admin-item-acts{position:absolute;top:8px;right:8px;display:flex;gap:4px}
.upload-label{display:inline-flex;align-items:center;gap:4px;background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:5px 10px;font-size:11px;cursor:pointer;margin-top:6px}
.img-preview{width:80px;height:50px;object-fit:cover;border-radius:4px;border:0.5px solid var(--bd);margin-top:6px}
/* TOAST */
#toast-c{position:fixed;bottom:36px;right:20px;z-index:9999;display:flex;flex-direction:column;gap:6px}
.toast{background:var(--bgw);border:0.5px solid var(--bd);border-radius:8px;padding:10px 14px;font-size:12px;display:flex;align-items:center;gap:8px;min-width:220px;animation:sI .2s ease}
.toast.ok{border-left:2px solid var(--gn)}.toast.ok i{color:var(--gn)}
.toast.err{border-left:2px solid var(--rd)}.toast.err i{color:var(--rd)}
.toast.w{border-left:2px solid #c07820}.toast.w i{color:#c07820}
@keyframes sI{from{transform:translateX(20px);opacity:0}to{opacity:1}}
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--bds);border-radius:3px}
"""

PORTAL_HTML = r"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CDPNI — Portal de Arquivos</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>{{ css }}</style>
</head>
<body>
<div class="topbar">
  <div class="tb-left">
    <div class="tb-logo"><i class="ti ti-building-prison"></i></div>
    <div class="tb-info">
      <div class="t1">Centro de Detenção Provisória de Nova Independência</div>
      <div class="t2">Portal de Arquivos — CDPNI · {{ ip }}</div>
    </div>
  </div>
  <div class="tb-right">
    <div class="tb-pill"><i class="ti ti-user-circle"></i>{{ user }}</div>
    {% if is_admin %}<a href="/admin" class="tb-btn"><i class="ti ti-settings"></i>Admin</a>{% endif %}
    <button class="tb-btn" onclick="openChangePass()"><i class="ti ti-lock"></i>Senha</button>
    <a href="/logout" class="tb-btn"><i class="ti ti-logout"></i>Sair</a>
  </div>
</div>

<div class="app-body">
  <!-- SIDEBAR ESQUERDA -->
  <div class="sidebar">
    <div class="sl-hdr">
      <span>Compartilhamentos</span>
      <i class="ti ti-folders" style="font-size:13px;color:var(--txm)"></i>
    </div>
    <div class="sl-search">
      <input type="text" placeholder="Filtrar pastas..." oninput="filterSidebar(this.value)">
    </div>
    <div class="sl-list" id="sl-list">
      {% for name, info in shares.items() %}
      <div class="sl-item {% if not info.can %}noaccess{% endif %}"
           data-name="{{ name }}" data-disk="{{ info.disk }}" data-can="{{ 'true' if info.can else 'false' }}"
           onclick="handleShare(this)">
        <i class="ti {{ info.icon }} ico"></i>
        <span class="nm">{{ name }}</span>
        {% if not info.can %}<i class="ti ti-lock lk"></i>{% endif %}
      </div>
      {% endfor %}
    </div>
  </div>

  <!-- CENTRO -->
  <div class="center">
    <!-- BANNER ROTATIVO -->
    <div class="banner-outer">
      {% if banners %}
      <div class="banner-track" id="banner-track">
        {% for b in banners %}
        <div class="banner-slide">
          <div class="slide-photo">
            {% if b.img %}
            <img src="/banner-img/{{ b.img }}" alt="">
            {% else %}
            <div class="ph"><i class="ti ti-photo"></i><span>Sem imagem</span></div>
            {% endif %}
          </div>
          <div class="slide-txt">
            <div class="slide-top">
              <span class="slide-badge"><i class="ti ti-speakerphone"></i>Aviso</span>
              <div class="slide-nav">
                <button onclick="prevSlide()">‹</button>
                <span class="slide-counter" id="slide-cnt">{{ loop.index }}/{{ banners|length }}</span>
                <button onclick="nextSlide()">›</button>
              </div>
            </div>
            <div class="slide-title">{{ b.title }}</div>
            <div class="slide-body">{{ b.body }}</div>
            <div class="slide-footer">
              <span class="slide-date">{{ b.date }}</span>
              <div class="slide-dots">
                {% for _ in banners %}
                <button class="slide-dot {% if loop.index==1 %}active{% endif %}" onclick="goSlide({{ loop.index0 }})"></button>
                {% endfor %}
              </div>
            </div>
          </div>
        </div>
        {% endfor %}
      </div>
      {% else %}
      <div class="banner-empty">
        <i class="ti ti-photo"></i>
        <span>{% if is_admin %}Acesse Admin → Banners para adicionar avisos{% else %}Nenhum aviso{% endif %}</span>
      </div>
      {% endif %}
      {% if is_admin %}<a href="/admin?tab=banners" class="banner-manage"><i class="ti ti-edit"></i>Gerenciar</a>{% endif %}
    </div>

    <!-- GERENCIADOR DE ARQUIVOS -->
    <div class="fm" id="fm">
      <div class="fm-empty" id="fm-welcome">
        <i class="ti ti-folder-open"></i>
        <p>Clique em uma pasta para abrir no Explorer Windows</p>
      </div>
      <div id="fm-noaccess" style="display:none" class="no-access">
        <i class="ti ti-lock-access"></i>
        <h3>Acesso não autorizado</h3>
        <p>Você não tem permissão para acessar esta pasta. Entre em contato com o administrador.</p>
        <span class="na-path" id="na-path">—</span>
      </div>
      <div id="fm-content" style="display:none;flex:1;flex-direction:column;gap:8px">
        <div class="fm-hdr">
          <div class="fm-title">
            <i class="ti ti-folder-open" id="fm-icon"></i>
            <div class="fm-title-txt">
              <h3 id="fm-name">—</h3>
              <span class="fm-path" id="fm-path" onclick="copyPath()" title="Clique para copiar">—</span>
            </div>
          </div>
          <div class="fm-btns">
            <label class="fmbtn prim" style="cursor:pointer">
              <i class="ti ti-upload"></i>Enviar
              <input type="file" multiple style="display:none" onchange="uploadFiles(this)">
            </label>
            <button class="fmbtn" onclick="openMkdir()"><i class="ti ti-folder-plus"></i>Nova pasta</button>
            <button class="fmbtn grn" onclick="openExplorer()"><i class="ti ti-external-link"></i>Abrir Explorer</button>
            <button class="fmbtn red" id="btn-del" disabled onclick="deleteSelected()"><i class="ti ti-trash"></i>Excluir</button>
          </div>
        </div>
        <div class="fm-wrap" id="fm-wrap">
          <table class="fm">
            <thead><tr>
              <th style="width:32px"><input type="checkbox" id="sel-all" onchange="toggleAll(this)"></th>
              <th style="width:22px"></th>
              <th>Nome</th>
              <th style="width:80px;text-align:right">Tamanho</th>
              <th style="width:110px;text-align:right">Modificado</th>
              <th style="width:180px;text-align:right">Ações</th>
            </tr></thead>
            <tbody id="fm-tbody"></tbody>
          </table>
        </div>
        <div class="drop-zone" id="drop-zone">
          <i class="ti ti-cloud-upload" style="font-size:24px;display:block;margin-bottom:6px"></i>
          Arraste arquivos aqui para enviar
        </div>
      </div>
    </div>
  </div>

  <!-- SIDEBAR DIREITA -->
  <div class="right-col">
    <div class="rc">
      <div class="rc-title"><i class="ti ti-server"></i>Servidor</div>
      <div class="rc-row"><span class="rc-lbl">Status</span><span class="rc-val"><span class="dot-on"></span>Online</span></div>
      <div class="rc-row"><span class="rc-lbl">IP</span><span class="rc-val">{{ ip }}</span></div>
      <div class="rc-row"><span class="rc-lbl">RAID 5</span><span class="rc-val">Ativo</span></div>
      <div class="rc-row"><span class="rc-lbl">Espaço</span><span class="rc-val">~8 TB</span></div>
    </div>
    <div class="rc">
      <div class="rc-title"><i class="ti ti-bell"></i>Lembretes</div>
      {% for n in notices %}
      <div class="notice {{ n.type or '' }}">
        <i class="ti {% if n.type=='ok' %}ti-check{% elif n.type=='w' %}ti-alert-triangle{% else %}ti-info-circle{% endif %}"></i>
        <div><div class="notice-txt">{{ n.text }}</div>{% if n.date %}<div class="notice-dt">{{ n.date }}</div>{% endif %}</div>
      </div>
      {% else %}
      <div style="font-size:10px;color:var(--txm)">Nenhum lembrete</div>
      {% endfor %}
    </div>
    <div class="rc">
      <div class="rc-title"><i class="ti ti-info-circle"></i>Informações</div>
      {% for r in right_info %}
      <div class="rc-row"><span class="rc-lbl">{{ r.label }}</span><span class="rc-val">{{ r.value }}</span></div>
      {% else %}
      <div style="font-size:10px;color:var(--txm)">Sem informações</div>
      {% endfor %}
    </div>
    <div class="rc">
      <div class="rc-title"><i class="ti ti-key"></i>Minha conta</div>
      <button class="acct-btn" onclick="openChangePass()">
        <i class="ti ti-lock"></i>Trocar minha senha
      </button>
      {% if is_admin %}
      <a href="/admin?tab=users" class="acct-btn"><i class="ti ti-users"></i>Gerenciar usuários</a>
      <a href="/admin?tab=shares" class="acct-btn"><i class="ti ti-folders"></i>Compartilhamentos</a>
      {% endif %}
    </div>
  </div>
</div>

<div class="statusbar">
  <span>CDPNI — Centro de Detenção Provisória de Nova Independência</span>
  <span class="st-on"><span class="dot-on"></span>Samba ativo — cdpni.local</span>
  <span>Portal v{{ version }}</span>
</div>

<div id="toast-c"></div>

<script>
const SAMBA_IP = "{{ ip }}";
const SAMBA_NAME = "{{ name }}";
let curDisk = "", curCan = false;
const BTOTAL = {{ banners|length }};
let bIdx = 0;

function toast(m,t='ok',ms=3200){const icons={ok:'ti-check',err:'ti-alert-circle',w:'ti-alert-triangle'};const el=document.createElement('div');el.className=`toast ${t}`;el.innerHTML=`<i class="ti ${icons[t]||'ti-info-circle'}"></i><span>${m}</span>`;document.getElementById('toast-c').appendChild(el);setTimeout(()=>el.remove(),ms);}
async function fetchJ(url,data){const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});return r.json();}

function filterSidebar(q){q=q.toLowerCase();document.querySelectorAll('.sl-item').forEach(el=>el.style.display=el.dataset.name.toLowerCase().includes(q)?'':'none');}

let curRel = "";
let selItems = new Set();

function handleShare(el){
  const can = el.dataset.can === 'true';
  const disk = el.dataset.disk;
  const name = el.dataset.name;
  document.querySelectorAll('.sl-item').forEach(e=>e.classList.remove('active'));
  el.classList.add('active');
  curDisk = disk; curRel = ""; curCan = can;
  document.getElementById('fm-welcome').style.display='none';
  if(!can){
    document.getElementById('fm-noaccess').style.display='flex';
    document.getElementById('fm-content').style.display='none';
    document.getElementById('na-path').textContent=`\\\\${SAMBA_NAME}\\${disk}`;
    toast('Você não tem permissão para acessar esta pasta','err');
    return;
  }
  document.getElementById('fm-noaccess').style.display='none';
  document.getElementById('fm-content').style.display='flex';
  document.getElementById('fm-icon').className=el.querySelector('i.ico').className+' ';
  loadDir(disk, "");
}

async function loadDir(disk, rel){
  curDisk=disk; curRel=rel; selItems.clear();
  const path = rel ? `${disk}/${rel}` : disk;
  const r = await fetch(`/browse/${path}`).then(x=>x.json());
  if(!r.ok){toast(r.msg||'Erro ao listar','err');return;}
  document.getElementById('fm-name').textContent = r.label + (rel ? ' / '+rel.split('/').pop() : '');
  document.getElementById('fm-path').textContent = r.smb_path;
  document.getElementById('sel-all').checked = false;
  document.getElementById('btn-del').disabled = true;
  renderTable(r.items, disk, rel);
}

function renderTable(items, disk, rel){
  const tb = document.getElementById('fm-tbody');
  let html = '';
  if(rel){
    const parent = rel.includes('/') ? rel.rsplit('/',1)[0] : '';
    html += `<tr><td></td><td><div class="f-ico folder"><i class="ti ti-corner-left-up"></i></div></td>
      <td colspan="4"><span class="f-name" onclick="loadDir('${disk}','${parent}')">.. (voltar)</span></td></tr>`;
  }
  if(!items.length && !rel){
    tb.innerHTML='<tr><td colspan="6"><div class="fm-empty" style="padding:24px"><i class="ti ti-folder-open"></i><p>Pasta vazia</p></div></td></tr>';return;
  }
  items.forEach(it=>{
    const isDir = it.is_dir;
    const nameClick = isDir
      ? `loadDir('${disk}','${(rel?rel+'/':'')+it.name}')`
      : `dlFile('${disk}','${(rel?rel+'/':'')+it.name}')`;
    html += `<tr data-name="${it.name}">
      <td><input type="checkbox" class="row-cb" onchange="updateSel()"></td>
      <td><div class="f-ico ${isDir?'folder':''}"><i class="ti ${it.icon}"></i></div></td>
      <td><span class="f-name" onclick="${nameClick}">${it.name}</span></td>
      <td class="f-size">${it.size}</td>
      <td class="f-date">${it.date}</td>
      <td class="f-acts">
        ${!isDir?`<button class="fact" onclick="dlFile('${disk}','${(rel?rel+'/':'')+it.name}')"><i class="ti ti-download"></i>Baixar</button>`:''}
        <button class="fact g" onclick="openItem('${disk}','${(rel?rel+'/':'')+it.name}',${isDir})"><i class="ti ti-external-link"></i>Abrir</button>
        <button class="fact" onclick="openRename('${it.name}')"><i class="ti ti-edit"></i></button>
        <button class="fact r" onclick="delItem('${disk}','${(rel?rel+'/':'')+it.name}','${it.name}')"><i class="ti ti-trash"></i></button>
      </td></tr>`;
  });
  tb.innerHTML = html;
}

function updateSel(){
  selItems.clear();
  document.querySelectorAll('.row-cb:checked').forEach(cb=>selItems.add(cb.closest('tr').dataset.name));
  document.getElementById('btn-del').disabled = selItems.size===0;
}
function toggleAll(cb){document.querySelectorAll('.row-cb').forEach(c=>c.checked=cb.checked);updateSel();}

function dlFile(disk,rel){window.open(`/download/${disk}/${rel}`,'_blank');}

function openItem(disk,rel,isDir){
  const a=document.createElement('a');
  a.href=`/open-explorer/${encodeURIComponent(disk)}/${rel}`;
  a.download=disk+'.url';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
  toast('Abrindo no Explorer...','ok');
}

function openExplorer(){
  if(!curDisk)return;
  const url = curRel ? `/open-explorer/${encodeURIComponent(curDisk)}/${curRel}` : `/open-explorer/${encodeURIComponent(curDisk)}`;
  const a=document.createElement('a');a.href=url;a.download=curDisk+'.url';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
  toast('Abrindo no Explorer...','ok');
}

function copyPath(){
  const path=`\\\\${SAMBA_NAME}\\${curDisk}`+(curRel?'\\'+curRel.replace(/\//g,'\\\\'):'');
  navigator.clipboard.writeText(path).then(()=>toast('Caminho copiado!'));
}

async function uploadFiles(inp){
  for(const f of inp.files){
    toast(`Enviando ${f.name}...`,'w');
    const fd=new FormData();fd.append('file',f);
    const url = curRel ? `/upload/${curDisk}/${curRel}` : `/upload/${curDisk}`;
    const r=await fetch(url,{method:'POST',body:fd}).then(x=>x.json());
    r.ok?toast(`${f.name} enviado!`,'ok'):toast(r.msg||'Erro','err');
  }
  inp.value='';loadDir(curDisk,curRel);
}

function openMkdir(){
  openModal('Nova pasta','ti-folder-plus',
    '<label>Nome da pasta</label><input type="text" id="mkdir-n" placeholder="Ex: Relatórios 2026">',
    async()=>{
      const name=document.getElementById('mkdir-n').value.trim();
      if(!name){toast('Informe o nome','err');return false;}
      const r=await fetchJ(`/mkdir/${curDisk}`,{rel:curRel,name});
      r.ok?(toast('Pasta criada!'),loadDir(curDisk,curRel)):toast(r.msg||'Erro','err');
    });
}

function openRename(name){
  openModal('Renomear','ti-edit',
    `<label>Novo nome</label><input type="text" id="ren-n" value="${name}">`,
    async()=>{
      const nn=document.getElementById('ren-n').value.trim();
      if(!nn||nn===name)return false;
      const old=(curRel?curRel+'/':'')+name;
      const r=await fetchJ(`/rename/${curDisk}`,{old,newname:nn});
      r.ok?(toast('Renomeado!'),loadDir(curDisk,curRel)):toast(r.msg||'Erro','err');
    });
}

function delItem(disk,rel,name){
  openConfirm(`Excluir "${name}"?`,'Será movido para a lixeira.',async()=>{
    const r=await fetch(`/delete/${disk}/${rel}`,{method:'DELETE'}).then(x=>x.json());
    r.ok?(toast('Movido para lixeira.'),loadDir(curDisk,curRel)):toast(r.msg||'Erro','err');
  });
}

async function deleteSelected(){
  if(!selItems.size)return;
  openConfirm(`Excluir ${selItems.size} item(ns)?`,'Serão movidos para a lixeira.',async()=>{
    for(const name of selItems){
      const rel=(curRel?curRel+'/':'')+name;
      await fetch(`/delete/${curDisk}/${rel}`,{method:'DELETE'});
    }
    toast('Movidos para lixeira.'); loadDir(curDisk,curRel);
  });
}

// Drag & drop
const dz=document.getElementById('drop-zone');
const fw=document.getElementById('fm-wrap');
if(fw&&dz){
  fw.addEventListener('dragover',e=>{e.preventDefault();dz.style.display='block';dz.classList.add('active');});
  dz.addEventListener('dragleave',()=>{dz.classList.remove('active');dz.style.display='none';});
  dz.addEventListener('drop',async e=>{e.preventDefault();dz.style.display='none';dz.classList.remove('active');await uploadFiles({files:e.dataTransfer.files,value:''});});
}

function openConfirm(title,msg,onOk){
  const m=document.createElement('div');m.className='modal-bg';
  m.innerHTML=`<div class="modal" style="width:360px"><h2><i class="ti ti-alert-triangle" style="color:#c07820"></i>${title}</h2>
  <p style="font-size:12px;color:var(--txs);margin-bottom:8px">${msg}</p>
  <div class="modal-footer"><button class="btn-cancel" onclick="this.closest('.modal-bg').remove()">Cancelar</button>
  <button class="btn-del" id="mok">Confirmar</button></div></div>`;
  document.body.appendChild(m);
  m.querySelector('#mok').onclick=()=>{m.remove();onOk();};
}

// Banner rotativo
function goSlide(n){bIdx=n;const t=document.getElementById('banner-track');if(t)t.style.transform=`translateX(-${n*100}%)`;document.querySelectorAll('.slide-dot').forEach((d,i)=>d.classList.toggle('active',i===n));const c=document.getElementById('slide-cnt');if(c)c.textContent=`${n+1}/${BTOTAL}`;}
function nextSlide(){if(BTOTAL>0)goSlide((bIdx+1)%BTOTAL);}
function prevSlide(){if(BTOTAL>0)goSlide((bIdx-1+BTOTAL)%BTOTAL);}
if(BTOTAL>1)setInterval(nextSlide,5000);

// Trocar senha própria (com confirmação da senha atual)
function openChangePass(targetUser){
  const isSelf = !targetUser;
  const label = isSelf ? "Trocar minha senha" : `Resetar senha — ${targetUser}`;
  const bodyHtml = isSelf
    ? `<label>Senha atual</label><input type="password" id="cp-old" autocomplete="current-password">
       <label>Nova senha</label><input type="password" id="cp-new" autocomplete="new-password">
       <label>Confirmar nova senha</label><input type="password" id="cp-n2" autocomplete="new-password">`
    : `<p style="font-size:12px;color:var(--txs);margin-bottom:8px">Usuário: <strong>${targetUser}</strong></p>
       <label>Nova senha</label><input type="password" id="cp-new" autocomplete="new-password">
       <label>Confirmar nova senha</label><input type="password" id="cp-n2" autocomplete="new-password">`;
  openModal(label,'ti-lock',bodyHtml,async()=>{
    const n=document.getElementById('cp-new').value;
    const n2=document.getElementById('cp-n2').value;
    if(n!==n2){toast('Senhas não coincidem','err');return false;}
    if(n.length<4){toast('Senha muito curta','err');return false;}
    const payload={new:n};
    if(isSelf)payload.old=document.getElementById('cp-old')?.value||'';
    else payload.target=targetUser;
    const r=await fetchJ('/api/change-pass',payload);
    r.ok?toast(r.msg||'Senha alterada!'):toast(r.msg||'Erro','err');
    return r.ok;
  });
}

// Modal genérico
function openModal(title,icon,body,onOk){
  const m=document.createElement('div');m.className='modal-bg';
  m.innerHTML=`<div class="modal"><h2><i class="ti ${icon}"></i>${title}</h2><div>${body}</div>
  <div class="modal-footer"><button class="btn-cancel" onclick="this.closest('.modal-bg').remove()">Cancelar</button>
  <button class="btn-ok" id="mok">Confirmar</button></div></div>`;
  document.body.appendChild(m);
  m.querySelector('#mok').onclick=async()=>{const r=await onOk();if(r!==false)m.remove();};
  setTimeout(()=>m.querySelector('input')?.focus(),50);
}
</script>
</body></html>"""

LOGIN_HTML = r"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CDPNI — Login</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>{{ css }}</style>
</head>
<body>
<div class="login-wrap">
  <div class="login-box">
    <div class="login-logo">
      <div class="crest"><i class="ti ti-building-prison"></i></div>
      <h1>Centro de Detenção Provisória<br>de Nova Independência</h1>
      <p>Sistema de Acesso a Arquivos — CDPNI</p>
    </div>
    {% if error %}<div class="login-err show">{{ error }}</div>{% endif %}
    <form method="post" action="/login">
      <label>Usuário</label>
      <input type="text" name="user" placeholder="Login do sistema" autocomplete="username" required>
      <label>Senha</label>
      <input type="password" name="pass" placeholder="Senha" autocomplete="current-password" required>
      <button type="submit" class="login-btn">Entrar</button>
    </form>
    <div style="margin-top:16px;text-align:center;border-top:1px solid #e8ecf0;padding-top:14px">
      <a href="/setup-windows" style="font-size:11px;color:var(--txm)">
        <i class="ti ti-download" style="font-size:12px;vertical-align:middle"></i>
        Configurar acesso por nome (cdpni)
      </a>
    </div>
  </div>
</div>
</body></html>"""

# ── Rotas ────────────────────────────────────────────────────────────────────
@app.route("/login", methods=["GET","POST"])
def login():
    error = ""
    if request.method == "POST":
        user = request.form.get("user","").strip()
        passwd = request.form.get("pass","")
        if user and passwd:
            p = pam.pam()
            ok = p.authenticate(user, passwd, service="cdpni-portal")
            if not ok:
                p2 = pam.pam()
                ok = p2.authenticate(user, passwd)
            if ok:
                session["user"] = user
                return redirect("/")
            error = "Usuário ou senha inválidos"
        else:
            error = "Preencha todos os campos"
    return render_template_string(LOGIN_HTML, css=CSS, error=error)

@app.route("/logout")
def logout():
    session.clear(); return redirect("/login")

@app.route("/")
@auth_required
def index():
    user = session["user"]
    d = load_data()
    shares_info = {}
    for label, (disk, group, icon) in SHARES.items():
        shares_info[label] = type("S",(),{"disk":disk,"icon":icon,"can":can_access(user,label)})()
    return render_template_string(PORTAL_HTML, css=CSS,
        user=user, ip=SAMBA_IP, name=SAMBA_NAME, version=VERSION,
        is_admin=is_admin(user),
        shares=shares_info,
        banners=d.get("banners",[]),
        notices=d.get("notices",[]),
        right_info=d.get("right_info",[]))

@app.route("/open-explorer/<disk>")
@app.route("/open-explorer/<disk>/<path:rel>")
@auth_required
def open_explorer(disk, rel=""):
    server = SAMBA_NAME
    path = f"\\\\{server}\\{disk}"
    if rel: path += "\\" + rel.replace("/","\\")
    content = f"[InternetShortcut]\r\nURL=file:{path}\r\nIconIndex=0\r\n"
    return Response(content, mimetype="application/x-mswinurl",
        headers={"Content-Disposition": f"attachment; filename={disk}.url"})

@app.route("/setup-windows")
def setup_windows():
    content = (
        "# CDPNI — Execute como Administrador no PowerShell\r\n"
        '$h="C:\\Windows\\System32\\drivers\\etc\\hosts"\r\n'
        '$e="192.168.0.11  cdpni"\r\n'
        '$c=Get-Content $h -Raw\r\n'
        'if($c -notmatch "cdpni"){Add-Content $h "`n$e";Write-Host "OK: acesse https://cdpni" -ForegroundColor Green}\r\n'
        'else{Write-Host "cdpni ja configurado." -ForegroundColor Yellow}\r\n'
    )
    return Response(content, mimetype="text/plain",
        headers={"Content-Disposition": "attachment; filename=configurar-cdpni.ps1"})

@app.route("/banner-img/<filename>")
@auth_required
def banner_img(filename):
    p = UPLOADS / filename
    if not p.exists(): abort(404)
    return send_file(p, mimetype=mimetypes.guess_type(str(p))[0] or "image/jpeg")

@app.route("/api/change-pass", methods=["POST"])
@auth_required
def change_pass():
    d = request.json
    cur_user  = session["user"]
    target    = d.get("target", cur_user).strip()
    new_p     = d.get("new","")
    old_p     = d.get("old","")

    # Usuário comum só pode trocar a própria senha
    # Admin pode trocar qualquer senha sem confirmar a atual
    if target != cur_user and not is_admin(cur_user):
        return jsonify(ok=False, msg="Sem permissão para trocar senha de outro usuário")

    # Usuário comum precisa confirmar a senha atual via PAM
    if target == cur_user and not is_admin(cur_user):
        try:
            p = pam.pam()
            if not p.authenticate(cur_user, old_p, service="cdpni-portal"):
                p2 = pam.pam()
                if not p2.authenticate(cur_user, old_p):
                    return jsonify(ok=False, msg="Senha atual incorreta")
        except Exception:
            return jsonify(ok=False, msg="Erro ao verificar senha atual")

    if len(new_p) < 4:
        return jsonify(ok=False, msg="Senha muito curta (mínimo 4 caracteres)")

    # Alterar senha Samba
    cmd_smb = f'printf "%s\n%s\n" {new_p!r} {new_p!r} | sudo smbpasswd -s {target} 2>&1'
    out = subprocess.getoutput(cmd_smb)
    # Alterar senha Linux
    subprocess.run(f"echo '{target}:{new_p}' | sudo chpasswd", shell=True, stderr=subprocess.DEVNULL)

    if "Changed password" in out or "Password changed" in out or "Updated" in out:
        subprocess.run(f"logger -t cdpni-portal 'SENHA ALTERADA: {target} por {cur_user}'", shell=True)
        return jsonify(ok=True, msg=f"Senha de {target} alterada com sucesso")
    # Mesmo que smbpasswd não confirme, chpasswd pode ter funcionado
    return jsonify(ok=True, msg=f"Senha de {target} atualizada")

# ── Admin ─────────────────────────────────────────────────────────────────────
@app.route("/admin")
@auth_required
def admin():
    if not is_admin(session["user"]): return redirect("/")
    tab = request.args.get("tab","banners")
    d = load_data()
    users = []
    if tab == "users":
        try:
            raw = subprocess.check_output(["sudo","pdbedit","-L"], text=True, stderr=subprocess.DEVNULL)
            for line in raw.splitlines():
                if ":" in line:
                    name = line.split(":")[0]
                    grps = subprocess.getoutput(f"id -Gn {name} 2>/dev/null")
                    users.append({"name":name,"groups":grps})
        except: pass

    ADMIN_HTML = r"""<!DOCTYPE html><html lang="pt-BR"><head><meta charset="UTF-8">
<title>Admin — CDPNI</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>{{ css }}
body{overflow:auto;height:auto}
.c{max-width:860px;margin:20px auto;padding:0 16px}
.tabs{display:flex;gap:8px;margin-bottom:20px;flex-wrap:wrap}
.tab{padding:7px 14px;border-radius:6px;font-size:12px;cursor:pointer;border:0.5px solid var(--bds);background:var(--bgw);color:var(--txs);text-decoration:none}
.tab.on{background:var(--tb);border-color:var(--tb);color:#fff}
.item{background:var(--bg);border:0.5px solid var(--bd);border-radius:8px;padding:12px;margin-bottom:8px;position:relative}
.item-acts{position:absolute;top:10px;right:10px;display:flex;gap:6px}
.ea{background:var(--bgw);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:4px 8px;font-size:11px;cursor:pointer;text-decoration:none}
.da{background:var(--rdb);border:0.5px solid var(--rdd);color:var(--rd);border-radius:5px;padding:4px 8px;font-size:11px;cursor:pointer;border:none;font-family:inherit}
.img-p{width:90px;height:58px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-bottom:8px;display:block}
.flash{padding:10px 14px;border-radius:6px;font-size:12px;margin-bottom:14px;display:flex;align-items:center;gap:8px}
.fok{background:var(--gnb);color:var(--gn)}.ferr{background:var(--rdb);color:var(--rd)}
</style></head><body>
<div style="background:var(--tb);height:46px;display:flex;align-items:center;justify-content:space-between;padding:0 20px;flex-shrink:0">
  <span style="color:#e8f0f8;font-size:12px;font-weight:500">CDPNI — Administração</span>
  <a href="/" style="color:#a0c4e0;font-size:11px;text-decoration:none;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;padding:4px 10px">← Voltar</a>
</div>
<div class="c">
  {% if msg %}<div class="flash {{ 'fok' if mt=='ok' else 'ferr' }}">{{ msg }}</div>{% endif %}
  <div class="tabs">
    <a href="/admin?tab=banners"  class="tab {{ 'on' if tab=='banners'  }}">Banners</a>
    <a href="/admin?tab=notices"  class="tab {{ 'on' if tab=='notices'  }}">Lembretes</a>
    <a href="/admin?tab=rightinfo"class="tab {{ 'on' if tab=='rightinfo'}}">Col. Direita</a>
    <a href="/admin?tab=users"    class="tab {{ 'on' if tab=='users'    }}">Usuários</a>
    <a href="/admin?tab=shares"   class="tab {{ 'on' if tab=='shares'   }}">Compartilhamentos</a>
  </div>
  {% if tab=='banners' %}
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
    <strong style="font-size:13px">Banners / Avisos</strong>
    <a href="/admin/banner/new" class="tab on" style="font-size:11px;padding:5px 12px">+ Novo</a>
  </div>
  {% for b in banners %}
  <div class="item"><div class="item-acts">
    <a href="/admin/banner/edit/{{ loop.index0 }}" class="ea"><i class="ti ti-edit"></i>Editar</a>
    <form method="post" action="/admin/banner/del/{{ loop.index0 }}" style="display:inline" onsubmit="return confirm('Remover?')">
      <button type="submit" class="da"><i class="ti ti-trash"></i>Remover</button></form></div>
    {% if b.img %}<img src="/banner-img/{{ b.img }}" class="img-p">{% endif %}
    <div style="font-size:13px;font-weight:500">{{ b.title }}</div>
    <div style="font-size:11px;color:var(--txs);margin-top:4px">{{ b.body }}</div>
    {% if b.date %}<div style="font-size:10px;color:var(--txm);margin-top:4px">{{ b.date }}</div>{% endif %}
  </div>{% else %}<p style="font-size:12px;color:var(--txm)">Nenhum banner.</p>{% endfor %}

  {% elif tab=='notices' %}
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
    <strong style="font-size:13px">Lembretes</strong>
    <a href="/admin/notice/new" class="tab on" style="font-size:11px;padding:5px 12px">+ Novo</a>
  </div>
  {% for n in notices %}
  <div class="item"><div class="item-acts">
    <a href="/admin/notice/edit/{{ loop.index0 }}" class="ea"><i class="ti ti-edit"></i>Editar</a>
    <form method="post" action="/admin/notice/del/{{ loop.index0 }}" style="display:inline" onsubmit="return confirm('Remover?')">
      <button type="submit" class="da"><i class="ti ti-trash"></i>Remover</button></form></div>
    <div style="font-size:12px;font-weight:500">{{ n.text }}</div>
    <div style="font-size:10px;color:var(--txm)">{{ n.date }} — {{ n.type or 'info' }}</div>
  </div>{% else %}<p style="font-size:12px;color:var(--txm)">Nenhum lembrete.</p>{% endfor %}

  {% elif tab=='rightinfo' %}
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
    <strong style="font-size:13px">Coluna direita</strong>
    <a href="/admin/ri/new" class="tab on" style="font-size:11px;padding:5px 12px">+ Nova</a>
  </div>
  {% for r in right_info %}
  <div class="item"><div class="item-acts">
    <a href="/admin/ri/edit/{{ loop.index0 }}" class="ea"><i class="ti ti-edit"></i>Editar</a>
    <form method="post" action="/admin/ri/del/{{ loop.index0 }}" style="display:inline" onsubmit="return confirm('Remover?')">
      <button type="submit" class="da"><i class="ti ti-trash"></i>Remover</button></form></div>
    <div style="font-size:12px;font-weight:500">{{ r.label }}: <span style="font-weight:400;color:var(--txs)">{{ r.value }}</span></div>
  </div>{% else %}<p style="font-size:12px;color:var(--txm)">Sem informações.</p>{% endfor %}

  {% elif tab=='users' %}
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
    <strong style="font-size:13px">Usuários ({{ users|length }})</strong>
    <a href="/admin/user/new" class="tab on" style="font-size:11px;padding:5px 12px">+ Novo usuário</a>
  </div>
  {% for u in users %}
  <div class="item"><div class="item-acts">
    <button class="ea" onclick="resetPass('{{ u.name }}')"><i class="ti ti-key"></i>Resetar senha</button>
    <a href="/admin/user-groups/{{ u.name }}" class="ea"><i class="ti ti-users"></i>Grupos</a>
  </div>
  <div style="font-size:13px;font-weight:500"><i class="ti ti-user-circle" style="font-size:14px;vertical-align:-2px;margin-right:5px;color:var(--ac)"></i>{{ u.name }}</div>
  <div style="font-size:10px;color:var(--txm);margin-top:3px;max-width:600px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ u.groups }}</div>
  </div>{% endfor %}
  <script>
  function resetPass(u){
    const body=`<p style="font-size:12px;color:var(--txs);margin-bottom:10px">Resetar senha de <strong>${u}</strong></p>
    <label>Nova senha</label><input type="password" id="rp-n" autocomplete="new-password">
    <label>Confirmar</label><input type="password" id="rp-n2" autocomplete="new-password">`;
    const m=document.createElement('div');m.className='modal-bg';
    m.innerHTML=`<div class="modal"><h2><i class="ti ti-key"></i>Resetar senha</h2>${body}
    <div class="modal-footer"><button class="btn-cancel" onclick="this.closest('.modal-bg').remove()">Cancelar</button>
    <button class="btn-ok" id="mok">Confirmar</button></div></div>`;
    document.body.appendChild(m);
    m.querySelector('#mok').onclick=async()=>{
      const n=m.querySelector('#rp-n').value,n2=m.querySelector('#rp-n2').value;
      if(n!==n2){alert('Senhas não coincidem');return;}
      if(n.length<4){alert('Senha muito curta');return;}
      const r=await fetch('/api/change-pass',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({target:u,new:n})}).then(x=>x.json());
      alert(r.msg||(r.ok?'Senha alterada!':'Erro'));m.remove();
    };
    setTimeout(()=>m.querySelector('input').focus(),50);
  }
  </script>
  {% elif tab=='shares' %}
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
    <strong style="font-size:13px">Compartilhamentos ({{ shares_list|length }})</strong>
    <a href="/admin/share/new" class="tab on" style="font-size:11px;padding:5px 12px"><i class="ti ti-plus" style="font-size:11px"></i> Novo</a>
  </div>
  {% for s in shares_list %}
  <div class="item"><div class="item-acts">
    <form method="post" action="/admin/share/del/{{ s.name }}" style="display:inline"
          onsubmit="return confirm('Remover {{ s.name }}? A pasta no disco nao sera apagada.')">
      <button type="submit" class="da"><i class="ti ti-trash"></i>Remover</button>
    </form>
  </div>
  <div style="font-size:13px;font-weight:500">
    <i class="ti ti-folder" style="font-size:14px;vertical-align:-2px;margin-right:5px;color:#d4931a"></i>{{ s.name }}
  </div>
  <div style="font-size:10px;color:var(--txm);margin-top:3px">
    Pasta: {{ s.path }} | Grupo: {{ s.group }} | Visivel: {{ 'Sim' if s.browseable else 'Nao' }}
  </div>
  </div>
  {% else %}
  <p style="font-size:12px;color:var(--txm)">Nenhum compartilhamento configurado</p>
  {% endfor %}
  {% endif %}
</div></body></html>"""

    # Ler compartilhamentos do smb.conf
    shares_list = []
    if tab == "shares":
        try:
            import configparser, re as _re
            smb = configparser.ConfigParser(strict=False)
            smb.read("/etc/samba/smb.conf")
            for sec in smb.sections():
                if sec.lower() in ("global","homes","printers"): continue
                path   = smb.get(sec,"path","").strip()
                group  = smb.get(sec,"valid users","").strip()
                browse = smb.get(sec,"browseable","yes").strip().lower()
                shares_list.append({"name":sec,"path":path,"group":group,"browseable":browse!="no"})
        except: pass

    return render_template_string(ADMIN_HTML, css=CSS, tab=tab,
        msg=request.args.get("msg",""), mt=request.args.get("mt","ok"),
        banners=d.get("banners",[]), notices=d.get("notices",[]),
        right_info=d.get("right_info",[]), users=users, shares_list=shares_list)

FORM_HTML = r"""<!DOCTYPE html><html lang="pt-BR"><head><meta charset="UTF-8">
<title>Admin — CDPNI</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>{{ css }}body{overflow:auto;height:auto}
.c{max-width:600px;margin:32px auto;padding:0 16px}
.fc{background:var(--bgw);border:0.5px solid var(--bd);border-radius:10px;padding:24px}
.ft{font-size:16px;font-weight:500;margin-bottom:20px;display:flex;align-items:center;gap:8px}
.ft i{font-size:20px;color:var(--ac)}
label{display:block;font-size:12px;font-weight:500;color:var(--txs);margin:14px 0 4px}
input,textarea,select{width:100%;border:0.5px solid var(--bds);border-radius:6px;padding:9px 11px;font-size:13px;color:var(--tx);outline:none;font-family:inherit;background:var(--bgw)}
input:focus,textarea:focus{border-color:var(--ac)}
textarea{resize:vertical;min-height:80px}
.ub{display:inline-flex;align-items:center;gap:5px;background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:7px 14px;font-size:12px;cursor:pointer;margin-top:6px}
.img-c{width:120px;height:75px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-top:8px;display:block}
.img-p{width:120px;height:75px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-top:8px;display:none}
.fa{display:flex;justify-content:flex-end;gap:8px;margin-top:20px}
.bc{background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:6px;padding:9px 18px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center}
.bs{background:var(--tb);border:none;color:#fff;border-radius:6px;padding:9px 18px;font-size:13px;cursor:pointer}
</style></head><body>
<div style="background:var(--tb);height:46px;display:flex;align-items:center;justify-content:space-between;padding:0 20px">
  <span style="color:#e8f0f8;font-size:12px;font-weight:500">CDPNI — Administração</span>
  <a href="/admin?tab={{ back }}" style="color:#a0c4e0;font-size:11px;text-decoration:none;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;padding:4px 10px">← Voltar</a>
</div>
<div class="c"><div class="fc">
  <div class="ft"><i class="ti {{ icon }}"></i>{{ title }}</div>
  <form method="post" enctype="multipart/form-data">
    {{ body|safe }}
    <div class="fa">
      <a href="/admin?tab={{ back }}" class="bc">Cancelar</a>
      <button type="submit" class="bs">Salvar</button>
    </div>
  </form>
</div></div>
<script>function prev(i){const f=i.files[0];if(!f)return;const r=new FileReader();r.onload=e=>{const p=document.querySelector('.img-p');if(p){p.src=e.target.result;p.style.display='block';}};r.readAsDataURL(f);}</script>
</body></html>"""

    def form(tab, icon, title, body):
        return render_template_string(FORM_HTML, css=CSS, back=tab, icon=icon, title=title, body=body)

    # Banner CRUD
    @app.route("/admin/banner/new", methods=["GET","POST"])
    @auth_required
    def banner_new():
        if not is_admin(session["user"]): return redirect("/")
        if request.method == "POST":
            d = load_data(); img = ""
            if "img" in request.files and request.files["img"].filename:
                f = request.files["img"]
                ext = Path(f.filename).suffix
                fname = f"banner_{os.urandom(6).hex()}{ext}"
                f.save(UPLOADS/fname); img = fname
            d.setdefault("banners",[]).append({"title":request.form.get("title",""),"body":request.form.get("body",""),"date":request.form.get("date",""),"img":img})
            save_data(d); return redirect("/admin?tab=banners&msg=Aviso+adicionado&mt=ok")
        b = """<label>Título</label><input type="text" name="title" required placeholder="Título">
<label>Texto</label><textarea name="body" placeholder="Conteúdo"></textarea>
<label>Data</label><input type="text" name="date" placeholder="Ex: 05/06/2026">
<label>Imagem (opcional)</label>
<label class="ub"><i class="ti ti-photo"></i>Selecionar<input type="file" name="img" accept="image/*" style="display:none" onchange="prev(this)"></label>
<img class="img-p">"""
        return form("banners","ti-speakerphone","Novo aviso",b)

    @app.route("/admin/banner/edit/<int:i>", methods=["GET","POST"])
    @auth_required
    def banner_edit(i):
        if not is_admin(session["user"]): return redirect("/")
        d = load_data()
        if i >= len(d.get("banners",[])): return redirect("/admin?tab=banners")
        bnn = d["banners"][i]
        if request.method == "POST":
            bnn["title"]=request.form.get("title",""); bnn["body"]=request.form.get("body",""); bnn["date"]=request.form.get("date","")
            if "img" in request.files and request.files["img"].filename:
                f=request.files["img"]; ext=Path(f.filename).suffix; fname=f"banner_{os.urandom(6).hex()}{ext}"
                f.save(UPLOADS/fname); bnn["img"]=fname
            save_data(d); return redirect("/admin?tab=banners&msg=Atualizado&mt=ok")
        ci = f'<img src="/banner-img/{bnn["img"]}" class="img-c">' if bnn.get("img") else ""
        b = f"""<label>Título</label><input type="text" name="title" value="{bnn['title']}" required>
<label>Texto</label><textarea name="body">{bnn['body']}</textarea>
<label>Data</label><input type="text" name="date" value="{bnn['date']}">
{ci}<label>Nova imagem (vazio = manter)</label>
<label class="ub"><i class="ti ti-photo"></i>Selecionar<input type="file" name="img" accept="image/*" style="display:none" onchange="prev(this)"></label>
<img class="img-p">"""
        return form("banners","ti-edit","Editar aviso",b)

    @app.route("/admin/banner/del/<int:i>", methods=["POST"])
    @auth_required
    def banner_del(i):
        if not is_admin(session["user"]): return redirect("/")
        d=load_data()
        if 0<=i<len(d.get("banners",[])): d["banners"].pop(i); save_data(d)
        return redirect("/admin?tab=banners&msg=Removido&mt=ok")

    # Notice CRUD
    @app.route("/admin/notice/new", methods=["GET","POST"])
    @auth_required
    def notice_new():
        if not is_admin(session["user"]): return redirect("/")
        if request.method == "POST":
            d=load_data(); d.setdefault("notices",[]).append({"text":request.form.get("text",""),"date":request.form.get("date",""),"type":request.form.get("type","")})
            save_data(d); return redirect("/admin?tab=notices&msg=Adicionado&mt=ok")
        b="""<label>Texto</label><input type="text" name="text" required>
<label>Data</label><input type="text" name="date" placeholder="Ex: 30/06/2026">
<label>Tipo</label><select name="type"><option value="">Informação</option><option value="ok">Concluído</option><option value="w">Alerta</option></select>"""
        return form("notices","ti-bell","Novo lembrete",b)

    @app.route("/admin/notice/edit/<int:i>", methods=["GET","POST"])
    @auth_required
    def notice_edit(i):
        if not is_admin(session["user"]): return redirect("/")
        d=load_data()
        if i>=len(d.get("notices",[])): return redirect("/admin?tab=notices")
        n=d["notices"][i]
        if request.method=="POST":
            n["text"]=request.form.get("text",""); n["date"]=request.form.get("date",""); n["type"]=request.form.get("type","")
            save_data(d); return redirect("/admin?tab=notices&msg=Atualizado&mt=ok")
        b=f"""<label>Texto</label><input type="text" name="text" value="{n['text']}" required>
<label>Data</label><input type="text" name="date" value="{n['date']}">
<label>Tipo</label><select name="type"><option value="" {'selected' if not n['type'] else ''}>Informação</option>
<option value="ok" {'selected' if n['type']=='ok' else ''}>Concluído</option>
<option value="w" {'selected' if n['type']=='w' else ''}>Alerta</option></select>"""
        return form("notices","ti-edit","Editar lembrete",b)

    @app.route("/admin/notice/del/<int:i>", methods=["POST"])
    @auth_required
    def notice_del(i):
        if not is_admin(session["user"]): return redirect("/")
        d=load_data()
        if 0<=i<len(d.get("notices",[])): d["notices"].pop(i); save_data(d)
        return redirect("/admin?tab=notices&msg=Removido&mt=ok")

    # RightInfo CRUD
    @app.route("/admin/ri/new", methods=["GET","POST"])
    @auth_required
    def ri_new():
        if not is_admin(session["user"]): return redirect("/")
        if request.method=="POST":
            d=load_data(); d.setdefault("right_info",[]).append({"label":request.form.get("label",""),"value":request.form.get("value","")})
            save_data(d); return redirect("/admin?tab=rightinfo&msg=Adicionado&mt=ok")
        b="""<label>Rótulo</label><input type="text" name="label" required placeholder="Ex: Suporte TI">
<label>Valor</label><input type="text" name="value" required placeholder="Ex: jpfagiani">"""
        return form("rightinfo","ti-info-circle","Nova informação",b)

    @app.route("/admin/ri/edit/<int:i>", methods=["GET","POST"])
    @auth_required
    def ri_edit(i):
        if not is_admin(session["user"]): return redirect("/")
        d=load_data()
        if i>=len(d.get("right_info",[])): return redirect("/admin?tab=rightinfo")
        r=d["right_info"][i]
        if request.method=="POST":
            r["label"]=request.form.get("label",""); r["value"]=request.form.get("value","")
            save_data(d); return redirect("/admin?tab=rightinfo&msg=Atualizado&mt=ok")
        b=f"""<label>Rótulo</label><input type="text" name="label" value="{r['label']}" required>
<label>Valor</label><input type="text" name="value" value="{r['value']}" required>"""
        return form("rightinfo","ti-edit","Editar informação",b)

    @app.route("/admin/ri/del/<int:i>", methods=["POST"])
    @auth_required
    def ri_del(i):
        if not is_admin(session["user"]): return redirect("/")
        d=load_data()
        if 0<=i<len(d.get("right_info",[])): d["right_info"].pop(i); save_data(d)
        return redirect("/admin?tab=rightinfo&msg=Removido&mt=ok")

    @app.route("/admin/share/new", methods=["GET","POST"])
    @auth_required
    def share_new():
        if not is_admin(session["user"]): return redirect("/")
        msg = ""
        if request.method == "POST":
            name    = request.form.get("name","").strip().replace(" ","_")
            group   = request.form.get("group","").strip()
            browse  = "yes" if request.form.get("browseable") else "no"
            if not name or not group:
                msg = "Preencha todos os campos"
            else:
                share_path = f"{SAMBA_ROOT}/{name}"
                try:
                    Path(share_path).mkdir(parents=True, exist_ok=True)
                    subprocess.run(f"chown root:{group} {share_path}", shell=True)
                    subprocess.run(f"chmod 777 {share_path}", shell=True)
                    # Adicionar ao smb.conf
                    new_block = f"""
[{name}]
   path = {share_path}
   valid users = @{group} {" ".join(ROOT_USERS)}
   read only = no
   browseable = {browse}
   create mask = 0777
   directory mask = 0777
   force create mode = 0777
   force directory mode = 0777
"""
                    with open("/etc/samba/smb.conf","a") as f: f.write(new_block)
                    subprocess.run("systemctl reload smbd 2>/dev/null || systemctl restart smbd", shell=True)
                    subprocess.run(f"logger -t cdpni-portal 'SHARE CRIADO: {name} grupo={group} por {session["user"]}'", shell=True)
                    return redirect("/admin?tab=shares&msg=Compartilhamento+criado&mt=ok")
                except Exception as e:
                    msg = str(e)
        # Listar grupos disponíveis
        grps = subprocess.getoutput("getent group | awk -F: '{print $1}' | grep ^grp_ | sort").splitlines()
        b = f"""{'<p style="color:var(--rd);font-size:12px;margin-bottom:8px">'+msg+'</p>' if msg else ''}
<label>Nome do compartilhamento</label>
<input type="text" name="name" required placeholder="Ex: Novo_Setor">
<label>Grupo Linux</label>
<select name="group">{"".join(f'<option value="{g}">{g}</option>' for g in grps)}</select>
<label>Visível no Explorer</label>
<select name="browseable"><option value="1">Sim</option><option value="">Não</option></select>
<p style="font-size:11px;color:var(--txm);margin-top:8px">A pasta será criada em {SAMBA_ROOT}/[nome]</p>"""
        return form("shares","ti-folder-plus","Novo compartilhamento",b)

    @app.route("/admin/share/del/<name>", methods=["POST"])
    @auth_required
    def share_del(name):
        if not is_admin(session["user"]): return redirect("/")
        import configparser
        try:
            # Remover do smb.conf
            smb = configparser.ConfigParser(strict=False)
            smb.read("/etc/samba/smb.conf")
            if smb.has_section(name):
                smb.remove_section(name)
                with open("/etc/samba/smb.conf","w") as f: smb.write(f)
                subprocess.run("systemctl reload smbd 2>/dev/null || systemctl restart smbd", shell=True)
                subprocess.run(f"logger -t cdpni-portal 'SHARE REMOVIDO: {name} por {session["user"]}'", shell=True)
        except Exception as e:
            return redirect(f"/admin?tab=shares&msg={e}&mt=err")
        return redirect("/admin?tab=shares&msg=Compartilhamento+removido+do+Samba+(pasta+no+disco+mantida)&mt=ok")

    @app.route("/admin/user/new", methods=["GET","POST"])
    @auth_required
    def user_new():
        if not is_admin(session["user"]): return redirect("/")
        msg = ""
        if request.method == "POST":
            username = request.form.get("username","").strip()
            group    = request.form.get("group","").strip()
            passwd   = request.form.get("passwd","").strip()
            if not username or not group or not passwd:
                msg = "Preencha todos os campos"
            elif len(passwd) < 4:
                msg = "Senha muito curta"
            else:
                try:
                    subprocess.run(f"useradd -m -s /bin/bash -g {group} {username}", shell=True)
                    subprocess.run(f"echo '{username}:{passwd}' | chpasswd", shell=True)
                    subprocess.run(f"printf '%s\n%s\n' {passwd!r} {passwd!r} | smbpasswd -s -a {username}", shell=True)
                    subprocess.run(f"logger -t cdpni-portal 'USUARIO CRIADO: {username} grupo={group} por {session["user"]}'", shell=True)
                    return redirect("/admin?tab=users&msg=Usuário+criado&mt=ok")
                except Exception as e:
                    msg = str(e)
        grps = subprocess.getoutput("getent group | awk -F: '{print $1}' | grep ^grp_ | sort").splitlines()
        b = f"""{'<p style="color:var(--rd);font-size:12px;margin-bottom:8px">'+msg+'</p>' if msg else ''}
<label>Nome de usuário (login)</label>
<input type="text" name="username" required placeholder="Ex: novoagente" autocomplete="off">
<label>Grupo principal</label>
<select name="group">{"".join(f'<option value="{g}">{g}</option>' for g in grps)}</select>
<label>Senha inicial</label>
<input type="password" name="passwd" required placeholder="Mín. 4 caracteres" autocomplete="new-password">"""
        return form("users","ti-user-plus","Novo usuário",b)

    @app.route("/admin/user-groups/<username>", methods=["GET","POST"])
    @auth_required
    def user_groups(username):
        if not is_admin(session["user"]): return redirect("/")
        msg = ""
        if request.method == "POST":
            selected = request.form.getlist("groups")
            # Resetar grupos e aplicar os selecionados
            all_grps = subprocess.getoutput("getent group | awk -F: '{print $1}' | grep ^grp_").splitlines()
            primary = subprocess.getoutput(f"id -gn {username} 2>/dev/null").strip()
            for g in all_grps:
                if g in selected:
                    subprocess.run(f"usermod -aG {g} {username}", shell=True)
                else:
                    subprocess.run(f"gpasswd -d {username} {g} 2>/dev/null", shell=True)
            return redirect(f"/admin?tab=users&msg=Grupos+de+{username}+atualizados&mt=ok")
        all_grps = subprocess.getoutput("getent group | awk -F: '{print $1}' | grep ^grp_ | sort").splitlines()
        cur_grps = set(subprocess.getoutput(f"id -Gn {username} 2>/dev/null").split())
        checks = "".join(f'<div style="padding:3px 0"><label style="display:flex;align-items:center;gap:6px;font-size:12px;font-weight:400"><input type="checkbox" name="groups" value="{g}" {"checked" if g in cur_grps else ""}> {g}</label></div>' for g in all_grps)
        b = f'<p style="font-size:12px;color:var(--txs);margin-bottom:10px">Usuário: <strong>{username}</strong></p><div style="max-height:300px;overflow-y:auto;background:var(--bg);border:0.5px solid var(--bd);border-radius:6px;padding:10px">{checks}</div>'
        return form("users","ti-users",f"Grupos — {username}",b)

    @app.route("/admin/user-pass/<username>", methods=["GET","POST"])    @app.route("/admin/user-pass/<username>", methods=["GET","POST"])
    @auth_required
    def user_pass(username):
        if not is_admin(session["user"]): return redirect("/")
        msg = ""
        if request.method == "POST":
            new_p = request.form.get("new_pass","")
            if len(new_p) < 4: msg = "Senha muito curta"
            else:
                try:
                    subprocess.run(f'printf "%s\n%s\n" {new_p!r} {new_p!r} | sudo smbpasswd -s {username}', shell=True, check=True)
                    subprocess.run(f"echo '{username}:{new_p}' | sudo chpasswd", shell=True)
                    return redirect(f"/admin?tab=users&msg=Senha+de+{username}+alterada&mt=ok")
                except Exception as e: msg = str(e)
        b = f"""<p style="font-size:12px;color:var(--txs);margin-bottom:8px">Usuário: <strong>{username}</strong></p>
{'<p style="color:var(--rd);font-size:12px;margin-bottom:8px">'+msg+'</p>' if msg else ''}
<label>Nova senha</label><input type="password" name="new_pass" required placeholder="Mín. 4 caracteres">
<label>Confirmar</label><input type="password" name="confirm_pass" required>"""
        return form("users","ti-key",f"Resetar senha — {username}",b)

    return admin()

# ── Explorador de arquivos ───────────────────────────────────────────────────

@app.route("/browse/<path:share_path>")
@auth_required
def browse(share_path):
    parts = share_path.split("/", 1)
    disk  = parts[0]
    rel   = parts[1] if len(parts) > 1 else ""
    label = next((l for l,(d,_,__) in SHARES.items() if d==disk), disk)
    user  = session["user"]

    if not can_access(user, label):
        return jsonify(ok=False, access=False, msg="Sem permissão"), 403

    try:
        base, full = safe_path(disk, rel)
        if not full.is_dir(): abort(404)
        items = []
        for e in sorted(full.iterdir(), key=lambda x:(not x.is_dir(), x.name.lower())):
            if e.name.startswith("."): continue
            ext = e.suffix.lstrip(".").lower() if e.is_file() else ""
            st  = e.stat()
            items.append({
                "name":    e.name,
                "is_dir":  e.is_dir(),
                "size":    fmt_size(st.st_size) if e.is_file() else "—",
                "date":    datetime.fromtimestamp(st.st_mtime).strftime("%d/%m/%Y %H:%M"),
                "icon":    file_icon(ext) if e.is_file() else "ti-folder",
            })
        smb_path = f"\\\\{SAMBA_NAME}\\{disk}" + (f"\\{rel.replace('/','\\')}" if rel else "")
        return jsonify(ok=True, items=items, smb_path=smb_path, label=label, disk=disk, rel=rel)
    except Exception as e:
        return jsonify(ok=False, msg=str(e)), 500

@app.route("/upload/<disk>", methods=["POST"])
@app.route("/upload/<disk>/<path:rel>", methods=["POST"])
@auth_required
def upload(disk, rel=""):
    label = next((l for l,(d,_,__) in SHARES.items() if d==disk), disk)
    if not can_access(session["user"], label):
        return jsonify(ok=False, msg="Sem permissão"), 403
    f = request.files.get("file")
    if not f: return jsonify(ok=False, msg="Sem arquivo")
    try:
        base, full_dir = safe_path(disk, rel)
        dest = full_dir / f.filename
        f.save(dest)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/mkdir/<disk>", methods=["POST"])
@auth_required
def mkdir(disk):
    d = request.json or {}
    label = next((l for l,(dd,_,__) in SHARES.items() if dd==disk), disk)
    if not can_access(session["user"], label):
        return jsonify(ok=False, msg="Sem permissão"), 403
    try:
        base, full_dir = safe_path(disk, d.get("rel",""))
        new_dir = full_dir / d.get("name","")
        new_dir.mkdir(parents=True, exist_ok=False)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/rename/<disk>", methods=["POST"])
@auth_required
def rename(disk):
    d = request.json or {}
    label = next((l for l,(dd,_,__) in SHARES.items() if dd==disk), disk)
    if not can_access(session["user"], label):
        return jsonify(ok=False, msg="Sem permissão"), 403
    try:
        base, old_full = safe_path(disk, d.get("old",""))
        new_full = old_full.parent / d.get("newname","")
        old_full.rename(new_full)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/delete/<path:path>", methods=["DELETE"])
@auth_required
def delete(path):
    parts = path.split("/", 1)
    disk  = parts[0]; rel = parts[1] if len(parts)>1 else ""
    label = next((l for l,(d,_,__) in SHARES.items() if d==disk), disk)
    if not can_access(session["user"], label):
        return jsonify(ok=False, msg="Sem permissão"), 403
    try:
        base, full = safe_path(disk, rel)
        # Mover para lixeira em vez de apagar
        trash = SAMBA_ROOT / ".lixeira" / session["user"] / disk
        trash.mkdir(parents=True, exist_ok=True)
        dest = trash / (full.name + "_" + datetime.now().strftime("%Y%m%d%H%M%S"))
        full.rename(dest)
        return jsonify(ok=True, msg=f"Movido para lixeira")
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/download/<path:path>")
@auth_required
def download(path):
    parts = path.split("/", 1)
    disk  = parts[0]; rel = parts[1] if len(parts)>1 else ""
    label = next((l for l,(d,_,__) in SHARES.items() if d==disk), disk)
    if not can_access(session["user"], label):
        abort(403)
    try:
        base, full = safe_path(disk, rel)
        if not full.is_file(): abort(404)
        return send_file(full, as_attachment=True, download_name=full.name)
    except Exception:
        abort(404)

# Lixeira
@app.route("/lixeira")
@auth_required
def lixeira():
    user  = session["user"]
    trash = SAMBA_ROOT / ".lixeira" / user
    items = []
    if trash.exists():
        for share_dir in trash.iterdir():
            for f in share_dir.iterdir():
                st = f.stat()
                items.append({
                    "path":  str(f.relative_to(SAMBA_ROOT / ".lixeira")),
                    "name":  f.name,
                    "share": share_dir.name,
                    "size":  fmt_size(st.st_size if f.is_file() else 0),
                    "date":  datetime.fromtimestamp(st.st_mtime).strftime("%d/%m/%Y %H:%M"),
                })
    return jsonify(ok=True, items=items)

@app.route("/lixeira/restaurar", methods=["POST"])
@auth_required
def restaurar():
    d    = request.json or {}
    user = session["user"]
    path = d.get("path","")
    try:
        full = SAMBA_ROOT / ".lixeira" / path
        if not full.exists(): return jsonify(ok=False, msg="Arquivo não encontrado")
        # Restaurar para a pasta original (remove sufixo de timestamp)
        parts = full.name.rsplit("_", 1)
        orig_name = parts[0]
        disk_name = path.split("/")[1]
        label = next((l for l,(dd,_,__) in SHARES.items() if dd==disk_name), disk_name)
        dest_dir = SAMBA_ROOT / disk_name
        dest = dest_dir / orig_name
        full.rename(dest)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)
PYEOF

chmod 750 "${APP_DIR}/app.py"
log "app.py criado ($(wc -l < ${APP_DIR}/app.py) linhas)"

# ===========================================================================
# 6. SYSTEMD
# ===========================================================================
header "6. Serviço systemd"
cat > /etc/systemd/system/${SERVICE}.service << SVCEOF
[Unit]
Description=CDPNI Portal de Arquivos — Flask v1.0
After=network.target

[Service]
User=cdpni
Group=cdpni
WorkingDirectory=${APP_DIR}
ExecStart=${VENV}/bin/python ${APP_DIR}/app.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "${SERVICE}"
systemctl restart "${SERVICE}" 2>/dev/null || true
sleep 3

if systemctl is-active "${SERVICE}" &>/dev/null; then
    log "Portal ativo"
else
    warn "Portal não iniciou — verificando..."
    journalctl -u "${SERVICE}" --no-pager -n 15
fi

# ===========================================================================
# 7. NGINX
# ===========================================================================
header "7. Nginx"
SSL_DIR="/etc/nginx/ssl"
DOMAIN="cdpni.local"
nginx -t && systemctl reload nginx && log "Nginx recarregado" || warn "Verificar Nginx"

# ===========================================================================
# RESUMO
# ===========================================================================
echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${GRN}║   PORTAL CDPNI v1.0 — INSTALADO                    ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Portal  : https://${SAMBA_IP}  ou  https://cdpni  ║${NC}"
echo -e "${BLD}${GRN}║  Admin   : https://${SAMBA_IP}:8443                ║${NC}"
echo -e "${BLD}${GRN}║  Login   : usuário e senha do sistema               ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Sincronizar senhas:                                ║${NC}"
echo -e "${BLD}${GRN}║    smbpasswd -a jpfagiani                           ║${NC}"
echo -e "${BLD}${GRN}║    echo 'jpfagiani:SENHA' | chpasswd                ║${NC}"
echo -e "${BLD}${GRN}║  Logs: journalctl -u cdpni-portal -f                ║${NC}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════╝${NC}"