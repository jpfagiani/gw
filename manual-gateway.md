# Manual de Instalação — Servidor Gateway
**CDPNI — Debian 13 (Trixie) | gateway-v37.1.sh**

---

## Sumário

1. [Visão Geral](#1-visão-geral)
2. [Pré-requisitos de Hardware](#2-pré-requisitos-de-hardware)
3. [Pré-requisitos de Software](#3-pré-requisitos-de-software)
4. [Topologia de Rede](#4-topologia-de-rede)
5. [Instalação Passo a Passo](#5-instalação-passo-a-passo)
6. [Estrutura de Diretórios Criados](#6-estrutura-de-diretórios-criados)
7. [Serviços Instalados](#7-serviços-instalados)
8. [Configurações de Rede](#8-configurações-de-rede)
9. [Firewall (nftables)](#9-firewall-nftables)
10. [Proxy Squid com SSL Bump](#10-proxy-squid-com-ssl-bump)
11. [DNS (BIND9)](#11-dns-bind9)
12. [NTP (Chrony)](#12-ntp-chrony)
13. [Painel Web de Administração](#13-painel-web-de-administração)
14. [WPAD — Autoconfiguração de Proxy](#14-wpad--autoconfiguração-de-proxy)
15. [Política de Acesso à Internet](#15-política-de-acesso-à-internet)
16. [Integração com o Servidor Samba](#16-integração-com-o-servidor-samba)
17. [Comandos de Manutenção](#17-comandos-de-manutenção)
18. [Solução de Problemas](#18-solução-de-problemas)

---

## 1. Visão Geral

O servidor gateway atua como ponto central da rede interna, fornecendo:

- **Roteamento e NAT** entre a LAN interna (`192.168.0.0/24`) e a rede WAN corporativa (`10.14.29.0/24`)
- **Proxy HTTP/HTTPS** com inspeção SSL (Squid + SSL Bump) e controle de acesso por IP
- **DNS cache e forwarder** (BIND9) com zonas internas para `cdpni.local`, `wpad.lan` e detectores de internet (NCSI)
- **NTP** (Chrony) servindo a LAN inteira
- **Firewall** (nftables) com política padrão DROP
- **Painel web** de administração na porta 5000
- **WPAD** para autoconfiguração de proxy nos clientes

---

## 2. Pré-requisitos de Hardware

| Item | Mínimo | Recomendado |
|---|---|---|
| CPU | 2 núcleos | 4 núcleos |
| RAM | 2 GB | 4 GB |
| Disco sistema | 20 GB | 40 GB SSD |
| Interfaces de rede | **2 obrigatórias** | 2 (WAN + LAN) |

> **Atenção:** O servidor precisa obrigatoriamente de duas interfaces de rede: uma para a WAN (rede corporativa `10.14.29.x`) e uma para a LAN (`192.168.0.x`).

---

## 3. Pré-requisitos de Software

- **Debian 13 (Trixie)** instalação mínima (sem ambiente gráfico)
- Acesso root (usuário `root` ou `sudo su -`)
- Script `gateway-v37.1.sh` copiado para o servidor
- Conectividade com repositórios Debian durante a instalação (rede WAN ativa)

### Preparação antes de executar

```bash
# 1. Verificar Debian 13
cat /etc/os-release | grep VERSION_CODENAME

# 2. Verificar interfaces de rede disponíveis
ip link show

# 3. Verificar conectividade com DNS corporativo
ping -c2 10.14.8.20

# 4. Dar permissão de execução ao script
chmod +x gateway-v37.1.sh

# 5. Executar como root
su -
bash gateway-v37.1.sh
```

---

## 4. Topologia de Rede

```
Internet / Rede Corporativa
         │
    [WAN: 10.14.29.x]
         │
  ┌──────────────┐
  │   GATEWAY    │  192.168.0.1 (LAN)
  │ 192.168.0.1  │  10.14.29.x  (WAN — IP configurado na instalação)
  │ Squid :3128  │
  │ BIND9  :53   │
  │ Chrony :123  │
  │ Painel :5000 │
  │ WPAD   :8080 │
  └──────────────┘
         │
    [LAN: 192.168.0.0/24]
         │
    ┌────┴────────────┐
    │                 │
[Clientes]    [Samba: 192.168.0.11]
192.168.0.x
```

### Rede de Monitoramento (opcional)

Durante a instalação é oferecida a opção de criar um alias `192.168.1.1/24` na interface LAN. Essa rede recebe acesso irrestrito ao proxy e à internet, indicada para equipamentos de monitoramento ou gerenciamento.

---

## 5. Instalação Passo a Passo

### 5.1 Iniciar o script

```bash
bash gateway-v37.1.sh
```

### 5.2 Perguntas interativas

O script fará as seguintes perguntas em sequência:

**Interfaces de rede:**
```
Interface WAN (externa) [padrão: ethX]: eth0
Interface LAN (interna) [padrão: ethX]: eth1
```
> Use `ip link show` para identificar os nomes corretos das interfaces antes de executar.

**Modo WAN:**
```
Modo WAN [1=DHCP / 2=Estático]: 2
IP da WAN (ex: 10.14.29.10/24): 10.14.29.10/24
Gateway da WAN: 10.14.29.1
```

**LAN:**
```
IP da LAN (ex: 192.168.0.1/24) [padrão: 192.168.0.1/24]: (Enter)
```

**Rede de monitoramento:**
```
Configurar IP 192.168.1.1/24 como alias na LAN? [S/n]: S
```

**Confirmação:**
```
Confirmar e aplicar configuração de rede? [S/n]: S
```

**Cache do Squid:**
O script detecta automaticamente a RAM disponível e calcula o cache. Nenhuma entrada necessária.

### 5.3 Progresso da instalação

A instalação percorre as seguintes etapas automaticamente após confirmar a rede:

| Etapa | O que faz |
|---|---|
| 1. Rede | Configura `/etc/network/interfaces`, hostname, `/etc/hosts` |
| 2. Pacotes | `apt-get update`, `apt-get upgrade`, instala todos os pacotes |
| 3. Sysctl | Ativa IP forwarding, ajusta parâmetros de rede e conntrack |
| 4. Chrony | Configura NTP com servidor interno + pools públicos como fallback |
| 5. BIND9 | DNS com views LAN/WAN, zonas locais, WPAD, CDPNI |
| 6. SSL/CA | Gera CA raiz para SSL Bump do Squid |
| 7. Squid | Proxy com SSL Bump, ACLs, política de acesso |
| 8. nftables | Firewall com NAT, forward, regras Samba |
| 9. NAT 1:1 | Script de atualização dinâmica de NAT |
| 10. WPAD/Nginx | Serve `proxy.pac`, `wpad.dat` e download da CA |
| 11. Painel Flask | Painel web de administração |
| 12. Resumo | Exibe senha do painel e próximos passos |

### 5.4 Duração estimada

- Com boa conexão à rede WAN: **10–15 minutos**
- Com rede lenta (apt download): **20–40 minutos**

### 5.5 Após a instalação

```bash
# Verificar todos os serviços
systemctl status squid bind9 nftables chrony nginx

# Verificar o painel
curl -k https://192.168.0.1:5000

# Reiniciar o servidor para garantir que tudo sobe corretamente no boot
reboot
```

---

## 6. Estrutura de Diretórios Criados

### Configurações principais

```
/etc/
├── network/
│   └── interfaces                    # Configuração WAN e LAN (ifupdown)
├── hosts                             # gateway.lan, cdpni.local
├── resolv.conf                       # nameserver 127.0.0.1 + DNS corporativos
├── sysctl.d/
│   └── 99-gateway.conf               # ip_forward, conntrack, buffers
│
├── bind/
│   ├── named.conf.options            # ACLs, forwarders corporativos
│   ├── named.conf.local              # Views lan_view / wan_view
│   ├── named.conf.root-hints         # Neutralizado (zonas em views)
│   ├── named.conf.default-zones      # Neutralizado (zonas em views)
│   └── zones/
│       ├── db.0.168.192              # Zona reversa LAN
│       ├── db.wpad.lan               # WPAD → gateway IP
│       ├── db.ncsi                   # NCSI (msftconnecttest, gstatic)
│       ├── db.cdpni.local            # cdpni.local → 192.168.0.11
│       ├── db.backup.local           # backup.local → 192.168.0.12
│       ├── db.srv13.local            # srv13.local → 192.168.0.13
│       └── db.srv14.local            # srv14.local → 192.168.0.14
│
├── chrony/
│   └── chrony.conf                   # NTP: servidor interno + pools públicos
│
├── squid/
│   ├── squid.conf                    # Proxy principal com SSL Bump
│   ├── ssl_cert/
│   │   ├── gateway-ca.key            # Chave privada da CA
│   │   ├── gateway-ca.crt            # Certificado CA (instalar nos clientes)
│   │   └── gateway-ca.der            # CA em formato DER (Windows)
│   ├── ips_totais.txt                # IPs com acesso completo
│   ├── ips_parciais.txt              # IPs com acesso parcial (horário)
│   ├── ips_bloqueados.txt            # IPs com acesso restrito
│   ├── ips_excecao_horario.txt       # IPs com horário especial
│   ├── sites_liberados.txt           # Sites sempre permitidos
│   ├── sites_bloqueados.txt          # Sites sempre bloqueados
│   └── sites_teams.txt               # Microsoft Teams (sempre liberado)
│
├── nftables/
│   ├── nat_1to1.txt                  # NAT 1:1 (IP externo:IP interno)
│   ├── ips_externos_liberados.txt    # IPs WAN com acesso à LAN
│   └── ips_rede_wan.txt              # Sub-rede WAN para roteamento
│
├── nginx/
│   └── sites-available/
│       └── gateway-wpad              # Servidor WPAD (:8080) + CA download
│
├── sudoers.d/
│   └── gateway-panel                 # Permissões sudo para o painel
│
└── gateway-panel.env                 # Variáveis de ambiente (senha do painel)
```

### Aplicação (Painel)

```
/opt/gateway-panel/
├── venv/                             # Ambiente virtual Python (Flask + Gunicorn)
├── app.py                            # Aplicação Flask principal
└── templates/                        # Templates HTML do painel
```

### Web (WPAD)

```
/var/www/gateway-wpad/
├── index.html                        # Página de instrução aos clientes
├── proxy.pac                         # Arquivo PAC de autoconfiguração
├── wpad.dat                          # Mesmo conteúdo do proxy.pac (padrão WPAD)
└── ca                                # Link/conteúdo para download da CA
```

### Scripts utilitários

```
/usr/local/bin/
├── update-nat1to1.sh                 # Atualiza regras NAT 1:1 dinamicamente
├── sync-gateway-ca.sh                # Sincroniza CA para clientes
└── gateway-panel-senha.sh            # Troca a senha do painel web
```

### Logs

```
/var/log/
├── squid/
│   └── access.log                    # Log de acessos do proxy
├── samba_setup.log                   # (gateway não usa, mas referência)
└── gateway-panel/
    ├── access.log                    # Log de acesso ao painel web
    └── error.log                     # Log de erros do Gunicorn
```

### Systemd

```
/etc/systemd/system/
└── gateway-panel.service             # Serviço do painel web (Gunicorn)
```

---

## 7. Serviços Instalados

| Serviço | Porta | Descrição |
|---|---|---|
| `squid` | 3128 (TCP) | Proxy HTTP/HTTPS |
| `squid` | 3129 (TCP) | SSL Bump intercept |
| `named` (BIND9) | 53 (TCP/UDP) | DNS |
| `chrony` | 123 (UDP) | NTP |
| `nginx` | 8080 (TCP) | WPAD + download CA |
| `gateway-panel` | 5000 (TCP) | Painel de administração |

### Verificar status de todos os serviços

```bash
for svc in squid bind9 chrony nginx gateway-panel nftables; do
    echo -n "$svc: "
    systemctl is-active $svc
done
```

---

## 8. Configurações de Rede

### Interfaces

O arquivo `/etc/network/interfaces` é gerado com base nas respostas da instalação:

```
auto lo
iface lo inet loopback

auto eth0                    # WAN
iface eth0 inet static
    address 10.14.29.10
    netmask 255.255.255.0
    gateway 10.14.29.1
    dns-nameservers 10.14.8.20 10.14.8.16 10.1.6.222

auto eth1                    # LAN
iface eth1 inet static
    address 192.168.0.1
    netmask 255.255.255.0
```

### DNS corporativos (forwarders BIND9)

| Servidor | IP | Função |
|---|---|---|
| DNS primário | `10.14.8.20` | Corporativo principal |
| DNS secundário | `10.1.6.222` | Corporativo secundário |
| DNS terciário | `10.14.8.16` | Corporativo terciário |

### Zonas DNS internas

| Zona | Resolve para | Finalidade |
|---|---|---|
| `cdpni.local` | `192.168.0.11` | Servidor Samba |
| `wpad.lan` | `192.168.0.1` | Autoconfiguração de proxy |
| `backup.local` | `192.168.0.12` | Servidor de backup |
| `msftconnecttest.com` | `192.168.0.1` | NCSI Windows |
| `connectivitycheck.gstatic.com` | `192.168.0.1` | NCSI Android |

---

## 9. Firewall (nftables)

### Política padrão

- **INPUT:** `accept` (serviços locais)
- **FORWARD:** `drop` (tudo bloqueado por padrão, apenas regras explícitas passam)
- **OUTPUT:** `accept`

### Regras notáveis no FORWARD

| Origem | Destino | Portas | Ação |
|---|---|---|---|
| LAN `192.168.0.0/24` | LAN `192.168.0.0/24` | todas | accept |
| LAN | WAN | todas | accept (proxy filtra) |
| qualquer | `192.168.0.11` | 139, 445 TCP | accept (Samba) |
| qualquer | `192.168.0.11` | 137, 138 UDP | accept (Samba NetBIOS) |
| qualquer | `192.168.0.11` | 80, 443 TCP | accept (painel Samba) |
| LAN | DNS corporativos | 53 | accept |
| LAN | DNS externo | 53 | drop (forçar DNS interno) |

### NAT

- **Masquerade:** tráfego da LAN sai pela WAN com o IP do gateway
- **NAT 1:1:** mapeamento de IPs externos para internos (configurável em `/etc/nftables/nat_1to1.txt`)

### Comandos úteis

```bash
# Listar regras ativas
nft list ruleset

# Recarregar após edição manual
nft -f /etc/nftables.conf

# Ver conexões ativas
conntrack -L | head -20
```

---

## 10. Proxy Squid com SSL Bump

### Como funciona

O Squid intercepta **todo** o tráfego HTTP e HTTPS da LAN:
- **HTTP** (porta 3128): filtrado diretamente
- **HTTPS** (porta 3129): interceptado via SSL Bump — o Squid apresenta um certificado assinado pela CA interna, inspeciona o conteúdo e aplica as ACLs

### Instalação do certificado CA nos clientes

Para que o SSL Bump funcione sem avisos de segurança, **todos os clientes Windows devem instalar a CA do gateway:**

1. Acessar `http://192.168.0.1:8080` no navegador do cliente
2. Clicar em **"Baixar Certificado CA"**
3. Instalar como **"Autoridade de Certificação Raiz Confiável"**

Ou via GPO para toda a rede:
```
Política de Grupo → Configurações do Windows → 
Configurações de Segurança → Diretivas de Chave Pública → 
Autoridades de Certificação Raiz Confiáveis
```

### Sites que NÃO passam pelo SSL Bump

O Samba e domínios `.local` são configurados com `ssl_bump splice` — o tráfego passa sem inspeção:

```
acl no_bump_samba_ip  dst 192.168.0.11
acl no_bump_samba_dns ssl::server_name_regex cdpni\.local$ cdpni$
ssl_bump splice no_bump_samba_ip
ssl_bump splice no_bump_samba_dns
```

### Arquivos de controle de acesso

Todos em `/etc/squid/`:

| Arquivo | Descrição |
|---|---|
| `ips_totais.txt` | IPs com acesso irrestrito à internet |
| `ips_parciais.txt` | IPs com acesso em horário comercial |
| `ips_bloqueados.txt` | IPs com acesso restrito (apenas gov, bancos, liberados) |
| `ips_excecao_horario.txt` | IPs com horário especial diferente do padrão |
| `sites_liberados.txt` | Domínios sempre liberados para todos |
| `sites_bloqueados.txt` | Domínios sempre bloqueados |

```bash
# Adicionar IP com acesso total
echo "192.168.0.50" >> /etc/squid/ips_totais.txt
squid -k reconfigure

# Adicionar IP bloqueado
echo "192.168.0.99" >> /etc/squid/ips_bloqueados.txt
squid -k reconfigure

# Verificar log de acesso
tail -f /var/log/squid/access.log
```

---

## 11. DNS (BIND9)

### Views configuradas

**`wan_view`** — clientes na rede `10.14.29.0/24`:
- Apenas forwarders corporativos
- Sem zonas internas

**`lan_view`** — clientes na rede `192.168.0.0/24` e `192.168.1.0/24`:
- Forwarders corporativos
- Zonas internas: `cdpni.local`, `wpad.lan`, `backup.local`, NCSI
- Zona reversa da LAN

### Testar resolução DNS

```bash
# Do gateway, testar resolução interna
dig @127.0.0.1 cdpni.local
dig @127.0.0.1 wpad.lan

# Testar resolução externa
dig @127.0.0.1 google.com

# Verificar status
rndc status
systemctl status bind9
```

### Adicionar entrada DNS interna

```bash
# Editar a zona correspondente
nano /etc/bind/zones/db.cdpni.local

# Adicionar linha, por exemplo:
# novo   IN  A  192.168.0.20

# Recarregar
rndc reload
```

---

## 12. NTP (Chrony)

O gateway serve NTP para toda a LAN. Os clientes devem usar `192.168.0.1` como servidor NTP.

```bash
# Verificar sincronismo
chronyc tracking
chronyc sources -v

# Forçar sincronismo imediato
chronyc makestep
```

---

## 13. Painel Web de Administração

### Acesso

```
URL:    http://192.168.0.1:5000
Usuário: admin
Senha:   (exibida no final da instalação — salvar!)
```

### Recuperar/trocar a senha

```bash
# Ver senha atual ou definir nova
gateway-panel-senha.sh

# Ou definir diretamente
gateway-panel-senha.sh MinhaNovaSenh@123
```

### Funcionalidades do painel

- Gerenciar arquivos de IPs (`ips_totais`, `ips_bloqueados`, etc.)
- Gerenciar listas de sites
- Configurar NAT 1:1
- Recarregar configurações do Squid e nftables
- Visualizar logs de acesso em tempo real
- Relatórios de uso por IP e domínio

### Arquivos de ambiente

```bash
# Ver configuração atual do painel
cat /etc/gateway-panel.env

# Reiniciar o painel
systemctl restart gateway-panel
```

---

## 14. WPAD — Autoconfiguração de Proxy

O WPAD permite que os clientes configurem o proxy automaticamente sem intervenção manual.

### Funcionamento

1. O cliente Windows consulta `wpad.lan` via DNS
2. O BIND9 resolve `wpad.lan` para `192.168.0.1`
3. O cliente baixa `http://wpad.lan:8080/wpad.dat`
4. O arquivo PAC instrui o cliente a usar `192.168.0.1:3128` como proxy para tráfego externo
5. Tráfego para `*.local`, `*.lan` e `192.168.x.x` vai direto (sem proxy)

### Configuração manual no Windows (alternativa)

Caso o WPAD automático não funcione:

```
Painel de Controle → Opções de Internet → Conexões → 
Configurações da LAN → Usar script de configuração automática
URL: http://192.168.0.1:8080/proxy.pac
```

---

## 15. Política de Acesso à Internet

| Grupo | Acesso |
|---|---|
| `ips_totais.txt` | Irrestrito |
| `ips_parciais.txt` | Horário comercial (configurável) |
| `ips_excecao_horario.txt` | Horário especial |
| `ips_bloqueados.txt` | Apenas: gov.br, bancos, sites_liberados, Teams |
| IPs não listados | Bloqueado (deny all) |
| Rede monitoramento `192.168.1.x` | Irrestrito |

> **Importante:** Todos os IPs da LAN devem estar em algum dos arquivos de controle. IPs não listados são completamente bloqueados.

---

## 16. Integração com o Servidor Samba

O gateway já vem pré-configurado para o Samba em `192.168.0.11`:

- **nftables:** portas `137/138/139/445` abertas na chain `forward` para `192.168.0.11`
- **Squid:** `ssl_bump splice` para `192.168.0.11` e `cdpni.local` (sem inspeção SSL)
- **BIND9:** zona `cdpni.local` → `192.168.0.11`
- **PAC file:** `*.local` vai direto (sem proxy)

> **Não é necessário** executar o `gateway_samba_rules.sh` gerado pelo `samba.sh` — as regras já estão incluídas no gateway.

---

## 17. Comandos de Manutenção

### Reiniciar serviços

```bash
systemctl restart squid         # Proxy
systemctl restart bind9         # DNS
systemctl restart nftables      # Firewall
systemctl restart chrony        # NTP
systemctl restart nginx         # WPAD
systemctl restart gateway-panel # Painel web
```

### Recarregar sem reiniciar

```bash
squid -k reconfigure            # Squid recarrega squid.conf
rndc reload                     # BIND9 recarrega zonas
nft -f /etc/nftables.conf       # Reaplica regras de firewall
```

### Verificar logs em tempo real

```bash
tail -f /var/log/squid/access.log           # Acessos do proxy
journalctl -fu squid                        # Log do Squid
journalctl -fu bind9                        # Log do DNS
journalctl -fu gateway-panel               # Log do painel
```

### Atualizar NAT 1:1

```bash
# Editar mapeamentos
nano /etc/nftables/nat_1to1.txt

# Aplicar
/usr/local/bin/update-nat1to1.sh
```

---

## 18. Solução de Problemas

### Clientes sem acesso à internet

```bash
# 1. Verificar se o IP está nas listas
grep "192.168.0.X" /etc/squid/ips_*.txt

# 2. Verificar se o proxy está respondendo
curl -x 192.168.0.1:3128 http://google.com

# 3. Verificar logs do Squid
tail -50 /var/log/squid/access.log | grep "192.168.0.X"
```

### DNS não resolve

```bash
# Testar localmente
dig @127.0.0.1 google.com

# Verificar se o BIND está ouvindo
ss -tlnp | grep :53

# Verificar erros
journalctl -u bind9 --since "10 min ago"
```

### Painel web inacessível

```bash
systemctl status gateway-panel
journalctl -fu gateway-panel
# Verificar porta
ss -tlnp | grep :5000
```

### Squid não inicia

```bash
# Validar configuração
squid -k parse

# Ver log detalhado
journalctl -u squid --since "5 min ago"

# Verificar permissões do cache
ls -la /var/lib/squid/
chown -R proxy:proxy /var/lib/squid/
```

### Verificação completa pós-instalação

```bash
#!/bin/bash
echo "=== SERVIÇOS ==="
for s in squid bind9 chrony nginx nftables gateway-panel; do
    printf "%-20s %s\n" "$s:" "$(systemctl is-active $s)"
done

echo -e "\n=== PORTAS ==="
ss -tlnp | grep -E ':53|:3128|:3129|:5000|:8080|:123'

echo -e "\n=== DNS INTERNO ==="
dig @127.0.0.1 cdpni.local +short
dig @127.0.0.1 wpad.lan +short

echo -e "\n=== NTP ==="
chronyc tracking | grep "System time"

echo -e "\n=== FIREWALL ==="
nft list chain inet filter forward | head -5
```

---

*Gerado automaticamente com base em gateway-v37.1.sh — CDPNI 2026*
