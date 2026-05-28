# Manual de Instalação — Servidor Samba / Arquivos
**CDPNI — Debian 13 (Trixie) | samba-v6.7.sh**

---

## Sumário

1. [Visão Geral](#1-visão-geral)
2. [Pré-requisitos de Hardware](#2-pré-requisitos-de-hardware)
3. [Pré-requisitos de Software](#3-pré-requisitos-de-software)
4. [Ordem de Instalação](#4-ordem-de-instalação)
5. [Instalação Passo a Passo](#5-instalação-passo-a-passo)
6. [Estrutura de Diretórios Criados](#6-estrutura-de-diretórios-criados)
7. [RAID 5 — Detalhes](#7-raid-5--detalhes)
8. [Compartilhamentos Criados](#8-compartilhamentos-criados)
9. [Usuários e Grupos](#9-usuários-e-grupos)
10. [Política de Acesso por Compartilhamento](#10-política-de-acesso-por-compartilhamento)
11. [Lixeira (Recycle Bin)](#11-lixeira-recycle-bin)
12. [Auditoria de Acessos](#12-auditoria-de-acessos)
13. [Painel Web de Administração](#13-painel-web-de-administração)
14. [Firewall (UFW)](#14-firewall-ufw)
15. [Monitoramento RAID](#15-monitoramento-raid)
16. [S.M.A.R.T.](#16-smart)
17. [Acesso pelo Windows](#17-acesso-pelo-windows)
18. [Comandos de Manutenção](#18-comandos-de-manutenção)
19. [Solução de Problemas](#19-solução-de-problemas)

---

## 1. Visão Geral

O servidor Samba CDPNI é o servidor de arquivos da organização. Fornece:

- **32 pastas compartilhadas** via protocolo SMB2/SMB3
- **RAID 5** com 5 discos de 2TB (~80GB úteis por configuração, ~8TB no hardware real)
- **Controle de acesso** por grupo Samba (`valid users`) com permissões 777 no filesystem
- **Lixeira** (Recycle Bin) individual por usuário
- **Auditoria** completa de operações (open, read, write, rename, delete)
- **Painel web** de gerenciamento via HTTPS
- **Monitoramento** do RAID com alertas por e-mail

---

## 2. Pré-requisitos de Hardware

| Item | Mínimo | Recomendado |
|---|---|---|
| CPU | 2 núcleos | 4 núcleos |
| RAM | 4 GB | 8 GB |
| Disco sistema | 20 GB | 40 GB SSD |
| **Discos RAID** | **5 × 2TB** | **5 × 2TB iguais** |
| Interface de rede | 1 (1 Gbps) | 1 Gbps |

> **Atenção crítica:** Os 5 discos de RAID **serão completamente apagados** durante a instalação. Certifique-se de que não contêm dados importantes.

---

## 3. Pré-requisitos de Software

- **Debian 13 (Trixie)** instalação mínima
- **Gateway já instalado e funcionando** (o Samba depende do DNS e NTP do gateway)
- Acesso root
- Script `samba-v6.7.sh` copiado para o servidor

### Verificações antes de instalar

```bash
# 1. Verificar Debian 13
cat /etc/os-release | grep VERSION_CODENAME

# 2. Verificar discos disponíveis
lsblk -dno NAME,SIZE,TYPE | grep disk

# 3. Verificar conectividade com o gateway
ping -c2 192.168.0.1

# 4. Verificar resolução DNS (deve funcionar via gateway)
nslookup google.com 192.168.0.1

# 5. Dar permissão e executar
chmod +x samba-v6.7.sh
su -
bash samba-v6.7.sh
```

---

## 4. Ordem de Instalação

> **O Gateway deve ser instalado PRIMEIRO.** O servidor Samba depende de:
> - DNS do gateway para resolução de nomes
> - NTP do gateway para sincronismo de hora (crítico para autenticação Samba)
> - Regras de firewall do gateway já configuradas para `192.168.0.11`

```
Passo 1: Instalar gateway (gateway-v37.1.sh)
Passo 2: Verificar que gateway está funcionando
Passo 3: Instalar Samba (samba-v6.7.sh)
Passo 4: Configurar clientes Windows
```

---

## 5. Instalação Passo a Passo

### 5.1 Iniciar o script

```bash
bash samba-v6.7.sh
```

### 5.2 Única pergunta interativa

O script detecta automaticamente os discos disponíveis e exibe:

```
DISPOSITIVO     TAMANHO    MODELO                 STATUS
/dev/sda        20G        SISTEMA                Em uso (/)
/dev/sdb        2.0T       WDC WD20EZRZ           Disponível
/dev/sdc        2.0T       WDC WD20EZRZ           Disponível
/dev/sdd        2.0T       WDC WD20EZRZ           Disponível
/dev/sde        2.0T       WDC WD20EZRZ           Disponível
/dev/sdf        2.0T       WDC WD20EZRZ           Disponível

RAID 5: 5 × 2TB = ~8TB úteis | Tolerância: 1 disco

⚠  TODOS OS DADOS NOS DISCOS SERÃO APAGADOS!
Confirma? [s/N]: s
```

> O script detecta automaticamente o disco do sistema e **exclui ele** dos discos para o RAID.

### 5.3 Progresso automático

| Etapa | O que faz |
|---|---|
| 1. Detecção HDs | Identifica e lista todos os discos |
| 2. Pacotes | Atualiza sistema, instala Samba, Nginx, PHP 8.3, mdadm, etc. |
| 3. Rede | Configura IP estático `192.168.0.11/24`, hostname `cdpni` |
| 3b. NTP | Instala/configura Chrony apontando para o gateway |
| 4. RAID 5 | Cria array RAID5 com os 5 discos |
| 5. XFS | Formata o RAID com XFS, monta em `/mnt/raid` |
| 6. Grupos | Cria todos os grupos `grp_*` no sistema |
| 7. Diretórios | Cria as 32 pastas em `/mnt/raid/shares/` com permissão 777 |
| 8. Usuários | Cria usuários Linux + Samba com senha `1234` |
| 9. smb.conf | Gera configuração completa do Samba |
| 10. Firewall | Configura UFW (portas Samba + painel) |
| 10b. Gateway | Gera script de integração (informativo — gateway já tem as regras) |
| 11. Fail2ban | Configura proteção contra força bruta |
| 12. S.M.A.R.T. | Configura monitoramento de saúde dos discos |
| 13. RAID monitor | Script de checagem horária com alerta por e-mail |
| 13b. Logrotate | Configura rotação de logs |
| 14. Painel web | Nginx + PHP + HTTPS + API de gerenciamento |
| 15. Resumo | Exibe URL, senhas e próximos passos |

### 5.4 Duração estimada

- **10–20 minutos** (a maior parte é o `apt-get` e a criação do RAID)

> O RAID 5 inicia a sincronização em background. O progresso pode ser visto com:
> ```bash
> watch cat /proc/mdstat
> ```
> A sincronização leva **60–90 minutos** para 5 × 2TB. O servidor funciona normalmente durante esse processo.

### 5.5 Após a instalação

```bash
# Trocar senhas padrão imediatamente
smbpasswd sambadmin
smbpasswd cpd
smbpasswd jpfagiani

# Verificar serviços
systemctl status smbd nmbd nginx php8.3-fpm fail2ban

# Reiniciar para testar boot completo
reboot
```

---

## 6. Estrutura de Diretórios Criados

### Dados (RAID)

```
/mnt/raid/                            # Ponto de montagem do RAID 5
├── shares/                           # Raiz de todos os compartilhamentos
│   ├── Administrativo/
│   ├── Aevp/
│   ├── Almoxarifado/
│   ├── Cadastro/
│   ├── Canil/
│   ├── Chefia_Turno_I/
│   ├── Chefia_Turno_II/
│   ├── Chefia_Turno_III/
│   ├── Chefia_Turno_IV/
│   ├── Cipa/
│   ├── Conexao_Familiar/
│   ├── CPD/                          # OCULTO — acesso direto: \\192.168.0.11\CPD
│   ├── csd/
│   ├── Diretoria_Geral/
│   ├── Educacao/
│   ├── Financas/
│   ├── Inclusao/
│   ├── Infraestrutura/
│   ├── Nucleo_de_Pessoal/
│   ├── Papel_de_Parede/
│   ├── Planilhas/
│   ├── Portaria_Turno_I/
│   ├── Portaria_Turno_II/
│   ├── Portaria_Turno_III/
│   ├── Portaria_Turno_IV/
│   ├── Publico/
│   ├── Rol_de_Visitas/
│   ├── Saude/
│   ├── Scanner/
│   ├── Simic/
│   ├── Sindicancia/
│   └── Supervisao/
│
└── recycle/                          # Lixeira global (chmod 1777)
    ├── sambadmin/                    # Lixeira individual por usuário
    ├── cpd/
    ├── adm/
    └── [demais usuários]/
```

### Configurações Samba

```
/etc/samba/
├── smb.conf                          # Configuração principal
├── smb.conf.bak.YYYYMMDD_HHMMSS     # Backup automático gerado pela instalação
└── passdb.tdb                        # Banco de senhas Samba
```

### Systemd override

```
/etc/systemd/system/
└── smbd.service.d/
    └── raid-dependency.conf          # smbd aguarda /mnt/raid estar montado
```

### Painel Web

```
/var/www/samba-panel/
├── config.php                        # Configuração do painel (hash da senha admin)
└── public/
    ├── index.php                     # Interface web principal
    └── api/
        └── index.php                 # API REST do painel
```

### SSL do Painel

```
/etc/nginx/
├── ssl/
│   ├── cdpni.crt                     # Certificado SSL autoassinado (10 anos)
│   └── cdpni.key                     # Chave privada SSL
└── sites-available/
    └── samba-panel                   # Configuração Nginx (HTTP→HTTPS + PHP-FPM)
```

### Logs

```
/var/log/
├── samba/
│   └── log.<hostname>                # Log por cliente conectado
├── samba_setup.log                   # Log completo da instalação
├── samba_panel.log                   # Log de ações no painel web
├── raid_check.log                    # Log horário do RAID
└── raid_alert.log                    # Alertas de problemas no RAID
```

### Monitoramento e Cron

```
/usr/local/bin/
└── raid_check.sh                     # Script de monitoramento do RAID

/etc/cron.d/
└── raid_monitor                      # Executa raid_check.sh a cada hora

/etc/logrotate.d/
└── samba-cdpni                       # Rotação de logs (semanal, 4-8 semanas)
```

### mdadm

```
/etc/mdadm/
└── mdadm.conf                        # Configuração do RAID (gerada pelo mdadm --detail --scan)
```

### Segurança

```
/etc/sudoers.d/
└── samba-panel                       # Permite www-data executar comandos Samba

/etc/fail2ban/jail.d/
└── samba.conf                        # Proteção contra força bruta (5 tentativas, ban 1h)
```

### NTP

```
/etc/chrony/
└── chrony.conf                       # Aponta para gateway (192.168.0.1)
```

---

## 7. RAID 5 — Detalhes

| Parâmetro | Valor |
|---|---|
| Dispositivo | `/dev/md0` |
| Nível | RAID 5 |
| Discos | 5 |
| Chunk | 512K |
| Layout | left-symmetric |
| Metadata | 1.2 |
| Nome | `data` (aparece como `cdpni:data`) |
| Filesystem | XFS |
| Mount | `/mnt/raid` |
| Opções mount | `noatime,nodiratime,allocsize=64m,largeio` |
| Tolerância | 1 disco com falha |
| Capacidade útil | ~8TB (4 de 5 discos) |

### Comandos RAID

```bash
# Status detalhado
mdadm --detail /dev/md0

# Status resumido
cat /proc/mdstat

# Monitorar sincronização em tempo real
watch -n2 cat /proc/mdstat

# Simular falha de disco (NUNCA em produção)
# mdadm /dev/md0 --fail /dev/sdX

# Remover disco com falha
mdadm /dev/md0 --remove /dev/sdX

# Adicionar disco de reposição
mdadm /dev/md0 --add /dev/sdX

# Verificar integridade (pode demorar horas)
echo check > /sys/block/md0/md/sync_action
```

### fstab

O RAID é montado via UUID no `/etc/fstab`:
```
UUID=xxxx-xxxx  /mnt/raid  xfs  defaults,noatime,nodiratime,allocsize=64m,largeio  0  2
```

---

## 8. Compartilhamentos Criados

| # | Nome | Grupo de Acesso | Visível na Rede |
|---|---|---|---|
| 1 | Administrativo | grp_administrativo | Sim |
| 2 | Aevp | grp_aevp | Sim |
| 3 | Almoxarifado | grp_almoxarifado | Sim |
| 4 | Cadastro | grp_cadastro | Sim |
| 5 | Canil | grp_canil | Sim |
| 6 | Chefia_Turno_I | grp_chefia_turno + grp_csd + grp_sindicancia | Sim |
| 7 | Chefia_Turno_II | grp_chefia_turno + grp_csd + grp_sindicancia | Sim |
| 8 | Chefia_Turno_III | grp_chefia_turno + grp_csd + grp_sindicancia | Sim |
| 9 | Chefia_Turno_IV | grp_chefia_turno + grp_csd + grp_sindicancia | Sim |
| 10 | Cipa | grp_cipa | Sim |
| 11 | Conexao_Familiar | grp_conexao_familiar | Sim |
| 12 | **CPD** | grp_cpd | **NÃO (oculto)** |
| 13 | csd | grp_csd | Sim |
| 14 | Diretoria_Geral | grp_diretoria | Sim |
| 15 | Educacao | grp_educacao | Sim |
| 16 | Financas | grp_financas | Sim |
| 17 | Inclusao | grp_inclusao | Sim |
| 18 | Infraestrutura | grp_infraestrutura | Sim |
| 19 | Nucleo_de_Pessoal | grp_nucleo_pessoal | Sim |
| 20 | Papel_de_Parede | grp_papel_parede | Sim |
| 21 | Planilhas | grp_planilhas | Sim |
| 22 | Portaria_Turno_I | grp_portaria | Sim |
| 23 | Portaria_Turno_II | grp_portaria | Sim |
| 24 | Portaria_Turno_III | grp_portaria | Sim |
| 25 | Portaria_Turno_IV | grp_portaria | Sim |
| 26 | Publico | grp_publico | Sim |
| 27 | Rol_de_Visitas | grp_rol_visitas | Sim |
| 28 | Saude | grp_saude | Sim |
| 29 | Scanner | grp_scanner | Sim |
| 30 | Simic | grp_simic | Sim |
| 31 | Sindicancia | grp_sindicancia | Sim |
| 32 | Supervisao | grp_supervisao | Sim |
| — | Recycle | sambadmin (somente) | Não |

> **CPD oculto:** Não aparece na listagem de rede, mas é acessível digitando diretamente `\\192.168.0.11\CPD` ou `\\cdpni.local\CPD`.

---

## 9. Usuários e Grupos

### Usuários criados (senha padrão: `1234`)

| Login | Nome | Acesso |
|---|---|---|
| `sambadmin` | Administrador Samba | **Todos os compartilhamentos** |
| `cpd` | CPD - Acesso Total | **Todos os compartilhamentos** |
| `jpfagiani` | JP Fagiani | **Todos os compartilhamentos** |
| `rcborges` | RC Borges | **Todos os compartilhamentos** |
| `supervisao` | Supervisao | **Todos os compartilhamentos** |
| `adm` | Administrativo | Administrativo |
| `aevp` | AEVP | Aevp |
| `almoxarifado` | Almoxarifado | Almoxarifado |
| `cadastro` | Cadastro | Cadastro |
| `canil` | Canil | Canil |
| `chefia1` | Chefia Turno I | Todos os Chefia_Turno_* |
| `chefia2` | Chefia Turno II | Todos os Chefia_Turno_* |
| `chefia3` | Chefia Turno III | Todos os Chefia_Turno_* |
| `chefia4` | Chefia Turno IV | Todos os Chefia_Turno_* |
| `cipa` | CIPA | Cipa |
| `conexao` | Conexao Familiar | Conexao_Familiar |
| `csd` | CSD | csd + Chefia_Turno_* + Rol_de_Visitas + Sindicancia |
| `dg` | Diretoria Geral | Diretoria_Geral |
| `educacao` | Educacao | Educacao |
| `financas` | Financas | Financas |
| `inclusao` | Inclusao | Inclusao |
| `infra` | Infraestrutura | Infraestrutura |
| `npessoal` | Nucleo de Pessoal | Nucleo_de_Pessoal |
| `portaria` | Portaria | Portaria_Turno_I/II/III/IV |
| `publico` | Publico | Publico |
| `rol` | Rol de Visitas | Rol_de_Visitas |
| `saude` | Saude | Saude |
| `simic` | Simic | Simic |
| `sindicancia` | Sindicancia | Sindicancia + Chefia_Turno_* + Rol + csd |

### Grupos criados

Todos com prefixo `grp_`:

```
grp_administrativo    grp_aevp           grp_almoxarifado
grp_cadastro          grp_canil          grp_chefia_turno
grp_cipa              grp_conexao_familiar  grp_cpd
grp_csd               grp_diretoria      grp_educacao
grp_financas          grp_inclusao       grp_infraestrutura
grp_nucleo_pessoal    grp_papel_parede   grp_planilhas
grp_portaria          grp_publico        grp_rol_visitas
grp_saude             grp_scanner        grp_simic
grp_sindicancia       grp_supervisao
```

> **Importante:** Trocar as senhas padrão `1234` imediatamente após a instalação.

---

## 10. Política de Acesso por Compartilhamento

O controle de acesso é feito **exclusivamente pelo Samba** via `valid users`. O filesystem tem permissão 777 em todas as pastas.

### Regra geral

- Cada pasta pertence a um grupo `grp_*`
- Somente membros do grupo (e `sambadmin`) podem acessar
- Exceção: pastas `Chefia_Turno_*` também aceitam `grp_csd` e `grp_sindicancia`

### Permissões de arquivo criado

- Arquivos novos: `0664` (leitura para o grupo, escrita para o dono)
- Pastas novas: `0777` (acesso total para todos no grupo)

---

## 11. Lixeira (Recycle Bin)

O Samba está configurado com o módulo `recycle`. Ao deletar um arquivo no Windows:

1. O arquivo vai para `/mnt/raid/recycle/<usuario>/` em vez de ser apagado
2. A estrutura de diretórios original é preservada (`recycle:keeptree = yes`)
3. Versões anteriores são mantidas com timestamp (`recycle:versions = yes`)
4. Arquivos maiores que **1 GB** não vão para a lixeira
5. Arquivos temporários (`*.tmp`, `~$*`, `Thumbs.db`) são excluídos da lixeira

### Recuperar arquivo deletado

```bash
# Ver arquivos na lixeira de um usuário
ls -la /mnt/raid/recycle/usuario/

# Restaurar arquivo
cp /mnt/raid/recycle/usuario/pasta/arquivo.docx /mnt/raid/shares/Pasta/arquivo.docx

# Limpar lixeira de um usuário
rm -rf /mnt/raid/recycle/usuario/*
```

---

## 12. Auditoria de Acessos

O módulo `full_audit` registra no syslog (`/var/log/syslog` ou `journald`) com facility `local5`:

Operações registradas: `open`, `read`, `write`, `renameat`, `unlink`, `mkdir`, `rmdir`

```bash
# Ver acessos recentes
journalctl | grep "smbd_audit" | tail -50

# Filtrar por usuário
journalctl | grep "smbd_audit" | grep "joao|"

# Filtrar por compartilhamento
journalctl | grep "smbd_audit" | grep "|Financas|"

# Exportar auditoria do dia
journalctl --since today | grep "smbd_audit" > /tmp/auditoria-$(date +%Y%m%d).txt
```

Formato do log: `usuario|IP_cliente|compartilhamento operação arquivo`

---

## 13. Painel Web de Administração

### Acesso

```
URL:      https://192.168.0.11
          https://cdpni.local
Usuário:  admin
Senha:    admin  (trocar imediatamente!)
```

> O certificado SSL é autoassinado. O navegador exibirá aviso — clique em "Avançado" → "Prosseguir".

### Funcionalidades

- **Dashboard:** status do Samba, RAID, disco, conexões ativas, uptime
- **Usuários:** criar, listar, resetar senha, habilitar/desabilitar, revogar acesso
- **Grupos:** criar grupos, adicionar/remover membros
- **Compartilhamentos:** listar shares com uso de disco, criar novos shares

### Trocar senha do painel

```bash
# Editar o hash no config.php
php -r "echo password_hash('NovaSenha', PASSWORD_BCRYPT);"
# Copiar o resultado e substituir em PANEL_PASS no config.php
nano /var/www/samba-panel/config.php
```

---

## 14. Firewall (UFW)

### Portas abertas

| Porta | Protocolo | Serviço |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (redireciona para HTTPS) |
| 137 | UDP | Samba NetBIOS Name |
| 138 | UDP | Samba NetBIOS Datagram |
| 139 | TCP | Samba NetBIOS Session |
| 443 | TCP | HTTPS (painel web) |
| 445 | TCP | Samba SMB direto |

Toda a rede `192.168.0.0/24` tem acesso liberado.

```bash
# Ver status do firewall
ufw status verbose

# Ver regras numeradas
ufw status numbered
```

---

## 15. Monitoramento RAID

O script `/usr/local/bin/raid_check.sh` executa a cada hora via cron e:

1. Verifica se há discos com falha (`Failed Devices > 0`)
2. Verifica se o array está degradado (`degraded` no estado)
3. Verifica se o estado é `clean` ou `active`
4. Se qualquer problema detectado: envia e-mail para `root` e registra em `/var/log/raid_alert.log`
5. Sempre registra o estado completo em `/var/log/raid_check.log`

```bash
# Executar verificação manual
/usr/local/bin/raid_check.sh

# Ver log de alertas
cat /var/log/raid_alert.log

# Ver histórico de status
tail -100 /var/log/raid_check.log

# Verificar e-mails enviados
cat /var/mail/root
```

---

## 16. S.M.A.R.T.

O `smartd` monitora a saúde física dos discos e envia alertas para `root`:

- **Verificação curta (Short):** diariamente às 02:00
- **Verificação longa (Long):** aos sábados às 03:00

```bash
# Status do smartd
systemctl status smartd

# Testar disco manualmente
smartctl -a /dev/sdb

# Iniciar teste curto
smartctl -t short /dev/sdb

# Ver resultado
smartctl -l selftest /dev/sdb
```

---

## 17. Acesso pelo Windows

### Primeira vez (configurar proxy e CA)

Antes de acessar o Samba, o cliente Windows deve ter o proxy configurado:

1. Acessar `http://192.168.0.1:8080` no navegador
2. Baixar e instalar o certificado CA do gateway
3. O proxy já deve ser configurado automaticamente via WPAD

### Acessar o servidor de arquivos

**Pelo Explorador de Arquivos:**
```
\\192.168.0.11
\\cdpni.local
```

**Mapear unidade de rede:**
1. Abrir "Este Computador" → "Mapear unidade de rede"
2. Unidade: `Z:` (ou outra letra)
3. Pasta: `\\192.168.0.11\Financas` (substitua pelo compartilhamento)
4. Marcar "Conectar usando credenciais diferentes"
5. Usuário: `financas` | Senha: `1234`

**Acessar CPD (pasta oculta):**
```
\\192.168.0.11\CPD
```
*(a pasta não aparece na listagem mas é acessível diretamente)*

### Solução para erro "Não está acessível"

Se aparecer erro ao acessar:

```
1. Verificar se o Samba está rodando:
   ssh root@192.168.0.11
   systemctl status smbd

2. Verificar conectividade:
   ping 192.168.0.11

3. Testar porta 445:
   Test-NetConnection -ComputerName 192.168.0.11 -Port 445
```

---

## 18. Comandos de Manutenção

### Samba

```bash
# Status detalhado
systemctl status smbd nmbd

# Reiniciar Samba
systemctl restart smbd nmbd

# Recarregar smb.conf sem derrubar conexões ativas
smbcontrol smbd reload-config

# Listar conexões ativas
smbstatus

# Listar conexões por share
smbstatus -S

# Listar usuários conectados
smbstatus -u

# Validar smb.conf
testparm -s /etc/samba/smb.conf

# Ver log do Samba
tail -f /var/log/samba/log.smbd
journalctl -fu smbd
```

### Usuários Samba

```bash
# Trocar senha
smbpasswd usuario

# Adicionar novo usuário Samba (usuário Linux deve existir)
useradd -m -s /usr/sbin/nologin -g grp_setor novouser
echo "novouser:1234" | chpasswd
printf '1234\n1234\n' | smbpasswd -s -a novouser
smbpasswd -e novouser

# Desativar usuário temporariamente
smbpasswd -d usuario

# Reativar
smbpasswd -e usuario

# Remover do Samba (mantém usuário Linux)
smbpasswd -x usuario

# Listar todos os usuários Samba
pdbedit -L

# Ver detalhes de um usuário
pdbedit -v -u usuario
```

### Grupos

```bash
# Criar novo grupo
groupadd grp_novosetor

# Adicionar usuário a grupo
usermod -aG grp_novosetor usuario
gpasswd -a usuario grp_novosetor

# Remover usuário de grupo
gpasswd -d usuario grp_novosetor

# Ver membros de um grupo
getent group grp_financas
```

### Disco e RAID

```bash
# Uso do disco
df -h /mnt/raid

# Uso por compartilhamento
du -sh /mnt/raid/shares/*

# Status do RAID
cat /proc/mdstat
mdadm --detail /dev/md0

# Verificar filesystem XFS
xfs_info /mnt/raid
xfs_check /dev/md0   # Não fazer com RAID montado
```

---

## 19. Solução de Problemas

### Usuário não consegue acessar pasta

```bash
# Verificar se usuário existe no Samba
pdbedit -L | grep usuario

# Verificar grupos do usuário
id usuario
groups usuario

# Verificar se está no grupo correto
getent group grp_setor

# Verificar smb.conf para o share
testparm -s | grep -A10 "\[NomeDaShare\]"
```

### Samba não inicia após reboot

```bash
# Verificar se RAID está montado
mount | grep /mnt/raid
cat /proc/mdstat

# Se RAID não montou, montar manualmente
mdadm --assemble /dev/md0
mount /mnt/raid

# Reiniciar Samba
systemctl restart smbd nmbd
```

### Lixeira não funciona

```bash
# Verificar permissões
ls -la /mnt/raid/recycle/
chmod 1777 /mnt/raid/recycle/

# Verificar lixeira do usuário
ls -la /mnt/raid/recycle/usuario/
chmod 700 /mnt/raid/recycle/usuario/
chown usuario:grp_setor /mnt/raid/recycle/usuario/
```

### Verificação completa pós-instalação

```bash
#!/bin/bash
echo "=== RAID ==="
cat /proc/mdstat | head -5

echo -e "\n=== DISCO ==="
df -h /mnt/raid

echo -e "\n=== SERVIÇOS ==="
for s in smbd nmbd nginx php8.3-fpm fail2ban smartd; do
    printf "%-20s %s\n" "$s:" "$(systemctl is-active $s)"
done

echo -e "\n=== SAMBA OUVINDO ==="
ss -tlnp | grep -E ':139|:445'

echo -e "\n=== USUÁRIOS SAMBA ==="
pdbedit -L | wc -l
echo "usuários cadastrados"

echo -e "\n=== SHARES ==="
testparm -s 2>/dev/null | grep "^\[" | grep -v global | wc -l
echo "compartilhamentos"

echo -e "\n=== NTP ==="
chronyc tracking 2>/dev/null | grep "System time" || echo "chrony não disponível"
```

---

*Gerado automaticamente com base em samba-v6.7.sh — CDPNI 2026*
