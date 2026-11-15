# Aprendizados — Galaxy A52 (SM-A525M) como servidor Docker com root

Documento único com **tudo** que descobrimos na prática: aparelho, root, kernel,
build no CI, incidentes e recuperação. Serve como manual para repetir o processo
ou para outra pessoa continuar.

Última atualização: 2026-11-14

---

## 1. Objetivo

Transformar um Galaxy A52 (SM-A525M) parado em um **mini-servidor com Docker
nativo de verdade** (namespaces + cgroups reais, sem proot, sem VM), rodando:

- AdGuard Home / Pi-hole (DNS + bloqueio de anúncios)
- APIs de desenvolvimento (Node, Python, Postgres)
- Home Assistant
- Portainer + acesso remoto (SSH na 2222, Tailscale)

Restrição dura: em ARM64 só rodam imagens `arm64`/`arm/v7` (não existe KVM/x86).

---

## 2. Fatos do aparelho

| Item | Valor |
|---|---|
| Modelo | SM-A525M (a52q, ZTO) |
| Android | 14 — build `A525MUBSCFYF1` (UP1A.231005.007) |
| Kernel stock | `4.14.190-perf-28693687-abA525MUBSCFYF1` |
| RAM / livre | 5,6 GiB / ~100 GB |
| Partição boot | 100.663.296 bytes exatos |
| Módulos `.ko` | **não existem** no aparelho → Wi-Fi e cia. são built-in |

Consequência prática: `CONFIG_MODVERSIONS` é inútil aqui (não há módulo para
versionar), o que resolveu um erro de build (§7).

---

## 3. Bootloader destravado (irreversível)

Feito com o aparelho zerado e **Knox 0x1** (warranty_bit=1). Estado atual:

```
flash.locked=0            verifiedbootstate=orange
```

Ou seja: verificação de boot desligada, mas **toda** a stack de segurança da
Samsung (RKP/PROCA/DEFEX/KNOX) continua ativa **dentro do kernel** — e é ela que
causa o incidente do §8.

---

## 4. Root com Magisk

- Magisk **v31.1** (`app-debug.apk`), patch do `boot.img` via `boot_patch.sh`.
- A UI "Instalar" do app **crashava**; o patch foi feito pelo script na mão.
- Resultado: `su -c id` → `uid=0(root) context=u:r:magisk:s0`, persistente entre
  reboots. Magisk reporta *Ramdisk: Sim*, *Zygisk: Disabled*.

### 4.1 `vbmeta` — cuidado

Para o bootloader aceitar boot modificado, o `vbmeta` precisa ser gravado com
**apenas o flag de AVB desligado**, mantendo os *descriptors*. Um `vbmeta`
**vazio** faz o aparelho não bootar.

### 4.2 Ambiente Magisk incompleto (após wipe)

Sintoma: `Magisk environment incomplete, abort` ao tentar usar `magiskboot`.

Correção aplicada (funcionou):

1. `run-as com.topjohnwu.magisk` → empurrar os binários do APK para
   `/data/user_de/0/com.topjohnwu.magisk/install`
2. reiniciar
3. liberar a política do shell (UID 2000) via SQLite interno do Magisk:

```sh
magisk --sqlite "INSERT OR REPLACE INTO policies (uid,policy,logging,notification,until) VALUES (2000,2,1,1,0)"
```

`policy=2` = **Allow** (sem prompt). Depois disso `/data/adb/magisk` fica
completo (`magiskboot`, `busybox`, `boot_patch.sh`, `util_functions.sh`, ...).

---

## 5. Docker no kernel stock — falhou como previsto

Binários `docker-29.9.3` static arm64 rodam (`dockerd --version` OK), containerd
sobe, mas:

```
dockerd: mkdir /run/docker/plugins: read-only file system
```

`/run` não existe e `/` é `ext4` read-only + dm-verity. Além disso, `runc`
falha direto:

```
runc: error setting cgroup config for procHooks process:
      bpf_prog_query(BPF_CGROUP_DEVICE) failed: bpf: invalid argument
```

Causas: `CONFIG_CGROUP_DEVICE=n`, `CONFIG_PID_NS=n` (e IPC/USER_NS ausentes →
`unshare` retorna `EINVAL`). **Conclusão: kernel custom é obrigatório.**

---

## 6. Opções de kernel necessárias

Ausentes no stock (`/proc/config.gz`, 5507 opções):

| Opção | Para quê |
|---|---|
| `CONFIG_PID_NS` | namespace de PID (runc) |
| `CONFIG_IPC_NS` | namespace de IPC |
| `CONFIG_USER_NS` | rootless / segurança |
| `CONFIG_CGROUP_DEVICE` | regras de `/dev` (o erro do BPF) |
| `CONFIG_CGROUP_PIDS` | limite de processos |
| `CONFIG_BINFMT_MISC` | rodar binários extras |
| `CONFIG_VETH` | par de rede do container (já existia) |
| `CONFIG_OVERLAY_FS` | storage driver overlay2 (já existia) |

Já presentes no stock: `UTS_NS`, `NET_NS`, `CGROUPS`, `MEMCG`, `FREEZER`,
`SECCOMP(_FILTER)`, `BRIDGE`, `NF_NAT`, `IP_NF_*`.
`NF_TABLES` ausente → usar `iptables-legacy`.

O fragmento completo fica em `configs/docker.fragment`.

---

## 7. Build do kernel no GitHub Actions

Repo: **`geniinho/SM-A52`** (privado). Pasta local: `a52-server/kernel-ci/`.

- Source: `SM-A525F_CIS_14_Opensource.zip` (223 MB) — **asset do release**
  `kernel-src` (não vai para o git; a árvore tem ~1,5 GB).
- Defconfig: **`a52q_eur_open_defconfig`**
- Toolchain: clang 11 (`r416183b`) do espelho **LineageOS** (o tarball do
  googlesource via `+archive/...tar.gz` retorna **400** — não usar).

Comando final de build (o que funciona):

```sh
make -j$(nproc) O=out ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     CC=/opt/clang/bin/clang REAL_CC=/opt/clang/bin/clang \
     CLANG_TRIPLE=aarch64-linux-gnu- \
     LD=/opt/clang/bin/ld.lld AR=/opt/clang/bin/llvm-ar NM=/opt/clang/bin/llvm-nm \
     OBJCOPY=/opt/clang/bin/llvm-objcopy STRIP=/opt/clang/bin/llvm-strip \
     KCFLAGS=-Wno-error \
     DTC_EXT=$KS/tools/dtc CONFIG_BUILD_ARM64_DT_OVERLAY=y Image
```

### 7.1 Problemas encontrados e solução

| # | Problema | Solução |
|---|---|---|
| 1 | `scripts/gcc-wrapper.py` da Samsung é **Python 2** (não existe no Ubuntu 22.04) → todos os testes de compilador falham | passar `CC=` direto, ignorando o wrapper |
| 2 | `-Werror=strict-prototypes` quebra `techpack/audio` | `sed` no `Makefile` trocando `-Werror=...` por `-Wno-...` + `KCFLAGS=-Wno-error` |
| 3 | GNU ld 2.38 do Ubuntu não linka (`dangerous relocation` nos `___ksymtab`) | `ld.lld` + `llvm-ar/nm/objcopy/strip` |
| 4 | `genksyms` falha em `gsi_write_channel_scratch` e o `lld` recusa o CRC | `CONFIG_MODVERSIONS=n` (não há `.ko`, é inócuo) |
| 5 | Build de ~25 min por tentativa | cache do objtree (`actions/cache/restore|save`) → ~3 min depois do 1º |
| 6 | Cache restaurado ignorava fragment novo (config antigo voltava) | gravar `.fragment-hash` (sha256) dentro de `out/` e reconfigurar quando mudar |
| 7 | `${GITHUB_TOKEN}` não existe como env var | `env: GH_TOKEN: ${{ github.token }}` |
| 8 | `tail` comia a mensagem de erro | `set +e` + `tee /tmp/build.log` + `grep error:` |
| 9 | `setlocalversion` reclama de `.git` ausente | inofensivo |
| 10 | desligar `CONFIG_SEC_DEBUG` quebra `arch/arm64/kernel/traps.c` (chamadas a `sec_debug_*` sem `#ifdef`) | manter `SEC_DEBUG=y` (é só log) |
| 11 | desligar `CONFIG_KNOX_NCM` gera `undefined symbol: check_ncm_flag` / `knox_collect_conntrack_data` / `check_intermediate_flag` / `get_intermediate_timeout` (chamadas sem `#ifdef` em `net/core/sock.c`, `net/ipv4/udp.c`, conntrack) | manter `KNOX_NCM=y` (é só monitoramento de conexões) |

### 7.2 Segurança: NÃO depender dos hexpatches do Magisk

O `boot_patch.sh` aplica 3 hexpatches no kernel:

| Patch | Bytes procurados |
|---|---|
| Remove Samsung RKP | `49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054` |
| Remove Samsung defex | `821B8012` → `E2FF8F12` |
| Disable PROCA | `70726F63615F636F6E66696700` → `...6D616769736B00` |

**O clang 11 gera código diferente do clang 10 da Samsung**, então os padrões
RKP e PROCA **não existem** no Image compilado por nós — os patches falham
silenciosamente, mas o de **defex** casa e modifica o texto do kernel. Resultado:
kernel alterado + RKP ativo = hypervisor mata o boot (§8).

Solução definitiva: **desligar os guardas no `.config`**:

```config
# CONFIG_RKP_NS_PROT is not set
# CONFIG_RKP_KDP is not set
# CONFIG_RKP_DMAP_PROT is not set
# CONFIG_UH_RKP is not set
# CONFIG_RKP_MODULE_SUPPORT is not set
# CONFIG_SECURITY_DEFEX is not set
# CONFIG_PROCA is not set
# CONFIG_FIVE is not set
# CONFIG_SECURITY_DSMS is not set
```

⚠️ **`CONFIG_SEC_DEBUG` NÃO pode ser desligado**: `arch/arm64/kernel/traps.c`
chama `sec_debug_sched_msg()` e `sec_debug_summary_save_die_info()` **sem**
`#ifdef`, então desligar gera:

```
arch/arm64/kernel/traps.c:321: error: implicit declaration of function 'sec_debug_sched_msg'
```

⚠️ **`CONFIG_KNOX_NCM` também não**: `net/core/sock.c`, `net/ipv4/udp.c` e o
conntrack chamam `check_ncm_flag()`, `knox_collect_conntrack_data()`,
`check_intermediate_flag()` e `get_intermediate_timeout()` sem `#ifdef` →
`ld.lld: error: undefined symbol` no link final.

Nenhum dos dois faz verificação de integridade (são logs/monitoramento), então
podem ficar `=y` sem risco de o hypervisor matar o boot.

O workflow agora imprime o estado de cada opção e varre o `Image` pelos três
padrões, para saber antes de flashar se o boot é viável.

---

## 8. Incidente: bootloop com o kernel compilado (e como recuperar)

### Sintoma

Após `dd` do boot novo em `/dev/block/by-name/boot` e reboot, o aparelho entra
em **loop de reinício** e **nunca enumera no USB**:

```
0 dispositivos em 40 verificações de VID_04E8 / VID_18D1 / VID_05C6
```

Isso indica kernel morrendo **antes** de inicializar o USB (bem cedo), não
bootloader rejeitando imagem (nesse caso haveria tela de erro).

### Causa raiz

Defex patchado (texto do kernel modificado) **sem** RKP desativado → a
verificação de integridade no TZ/hypervisor da Samsung matou o kernel.
Ver §7.2.

### Recuperação (validada!)

1. **Forçar desligamento**: `Power` + `Vol Baixo` por ~40 s (com USB
   **desconectado**), ou os três botões por ~20 s. O USB conectado às vezes
   impede o desligamento.
2. **Download Mode**: `Vol Cima` + `Vol Baixo` (sem Power) + conectar USB →
   tela de aviso → toque curto em `Vol Cima`.
3. **Odin** (`Odin3_v3.14.4.exe`), device em `0:[COM5] Added!!`:
   - marcar **AP** → `rollback/a52_rollback.tar` (boot bom, 96 MB, contém `boot.img`)
   - **Start** → log termina com **`PASS!`** em verde
4. Aparelho reinicia sozinho, volta com root.

Backups que existem:

```
downloads/kernel-build/boot_backup_atual.img   boot que funcionava (Magisk)
downloads/kernel-build/boot_custom_magisk.img  boot do kernel experimental (o que travou)
downloads/kernel-build/rollback/a52_rollback.tar  pronto para Odin (AP)
downloads/fw/extracted/boot/boot.img           boot stock puro
```

### Dicas de automação do Odin (Windows)

- A tela era **2560x1440**: cliques com coordenadas erradas (baseadas em imagem
  reduzida 1920x1080) não faziam nada. `UIAutomation` retorna **pixels reais** —
  usar `BoundingRectangle` dela, não a screenshot redimensionada.
- Jogo em **tela cheia (DirectX)** captura o mouse e os cliques **não chegam** no
  Odin. Fechar/alt-tab o jogo antes.
- `SetForegroundWindow` é bloqueado pelo Windows; usar
  `AttachThreadInput(GetCurrentThreadId(), foregroundTid, true)` + `SetForegroundWindow`.
- Os controles do Odin são `Button`/`Edit` Win32 clássicos; dá para localizar por
  `FindWindowEx(parent, 0, "Button", "AP")` e até enviar `BM_CLICK` — mas o clique
  físico é mais confiável.
- O `OpenFileDialog` é moderno (Win11): setar o caminho no campo "Nome" e
  confirmar funciona; o campo é estreito, o texto aparece truncado — **verificar
  pelo `LastAccessTime` do arquivo** qual foi realmente lido.

---

## 9. Pipeline de repack (kernel novo + Magisk)

Validado no aparelho: unpack/repack produzem exatamente **100.663.296 bytes**
(tamanho da partição), kernel sempre em **gzip**.

```
magiskboot unpack  boot_stock.img        -> kernel, ramdisk.cpio, dtb
cp Image kernel                          (kernel novo, cru)
magiskboot repack  boot_stock.img novo   (regrava header/checksum/SIGNER/VBMETA)
BOOTMODE=true KEEPVERITY=false KEEPFORCEENCRYPT=true RECOVERYMODE=false \
  sh boot_patch.sh novo.img              (reaplica Magisk: ramdisk + hexpatches)
dd if=new-boot.img of=/dev/block/by-name/boot bs=4096
```

Information sections preservadas do stock: `SAMSUNG_SEANDROID`, `SIGNER_VER02`,
`VBMETA`, `OS_VERSION 11.0.0`, `OS_PATCH_LEVEL 2025-04`.

Scripts: `scripts/repack_boot.sh`, `scripts/flash-kernel.ps1`.

---

## 9.1 Incidente 2 — segundo bootloop e a pista do toolchain

Depois de desligar RKP/PROCA/DEFEX/FIVE/DSMS na config, o aparelho **continuou**
em loop (logo SAMSUNG → reinicia, sem enumerar USB). Ou seja: segurança não era
a única causa.

Evidência decisiva veio do banner de versão **dentro** dos kernels:

| Kernel | Compilador | Linker |
|---|---|---|
| stock que funciona | `clang version 10.0.7 for Android NDK` | `GNU ld (binutils 2.27)` |
| nosso | `clang version 12.0.5 (r416183b)` | `LLD 12.0.5` |

Como ler o banner de um `boot.img` sem `magiskboot` (Python):

```python
import struct, re, gzip, io
d = open('boot.img','rb').read()
ksz  = struct.unpack_from('<I', d, 8)[0]
page = struct.unpack_from('<I', d, 36)[0]
kern = d[page:page+ksz]
if kern[:2] == b'\x1f\x8b':
    kern = gzip.GzipFile(fileobj=io.BytesIO(kern)).read()
print(re.search(rb'Linux version [^\x00]{0,300}', kern).group(0).decode())
```

Hipóteses em aberto nessa altura:
1. **Linker**: kernel 4.14 ARM64 se auto-relocaliza (`R_AARCH64_RELATIVE`); o
   formato que o `ld.lld` produz pode não ser o que o relocador espera → crash
   antes do USB. A Samsung usou **GNU ld 2.27**.
2. **Config base errada**: estávamos partindo de `a52q_eur_open_defconfig`
   (variante A525F EUR) e não da config real do A525M.

Contramedida aplicada: o build agora aceita duas entradas (`workflow_dispatch`):
- `base`: `stock` (usa `configs/stock.config` = `/proc/config.gz` do aparelho,
  6739 opções) ou `defconfig`
- `docker`: `true|false` (aplica ou não o fragment)

`publish.ps1 -Base stock -Docker true` dispara nessa configuração.

---

## 10. Estado atual (2026-11-15) — DOCKER FUNCIONANDO

- ✅ Bootloader destravado, Magisk v31.1 com root persistente
- ✅ Kernel `4.14.190-perf` compilado por nós **bootando** no aparelho
- ✅ **Docker nativo rodando**: `Server Version 29.9.3`, overlayfs, cgroup v1
- ✅ Primeiro container executado (`arm64v8/alpine uname -a` → `aarch64 Linux`)
- ✅ Portainer rodando em `http://<ip-do-celular>:9000` (`--network host`)
- ✅ Persistência no boot via `/data/adb/service.d/docker.sh`
- ⏳ Pendente: reboots de confirmação, AdGuard/Pi-hole, Home Assistant,
  Tailscale/SSH

Detalhes do que destravou o boot: usando **`base=stock`** (o `/proc/config.gz`
do próprio aparelho) e **GNU ld 2.27** (prebuilt AOSP gcc 4.9) o kernel subiu —
ou seja, as duas hipóteses do incidente 2 estavam certas. O clang ficou 12.0.5
(não foi necessário o 10.0.7); o que importava era o **linker**.

---

## 11. Docker no Android: os 5 problemas e as soluções

Receita completa que fez o Docker funcionar (scripts em `a52-server/scripts/`).

| # | Problema | Solução |
|---|---|---|
| 1 | `mkdir /run/docker/plugins: read-only file system` — `/run` não existe | `mount -o remount,rw /` (o AVB está desligado no bootloader) + `mkdir /run` + `mount -t tmpfs tmpfs /run` |
| 2 | `--pidfile` padrão é `/var/run/docker.pid` (read-only) | `--pidfile /data/adb/docker/docker.pid` — e **não** escrever o pidfile por fora (o dockerd vê o PID vivo e aborta) |
| 3 | `lookup registry-1.docker.io on [::1]:53: connection refused` | Android não tem `/etc/resolv.conf`; criar `/system/etc/resolv.conf` com 1.1.1.1/8.8.8.8 |
| 4 | `x509: certificate signed by unknown authority` | `SSL_CERT_FILE=<bundle>` gerado de `/system/etc/security/cacerts/*.0` (+ `SSL_CERT_DIR`) |
| 5 | `bpf_prog_query(BPF_CGROUP_DEVICE) failed: bpf: invalid argument` | kernel 4.14 não suporta device-cgroup via eBPF (só 4.15+): rodar o dockerd num `unshare -m` com **cgroup v1** montado (ver `ns-cgroup.sh`) |
| 6 | `runc create failed: mountpoint for devices not found` (com cgroup v1) | o `runc` (1.1 e 1.3) não localiza o mount de `devices` neste kernel/Android. Solução: usar **`crun` 1.31 (static arm64)** como runtime padrão |

### Runtime: crun no lugar do runc

```sh
# baixar (PC) e instalar
# https://github.com/containers/crun/releases/download/1.31/crun-1.31-linux-arm64-disable-systemd
cp crun /data/adb/docker/bin/crun && chmod 755 /data/adb/docker/bin/crun
```

No start do dockerd:

```
--add-runtime crun=/data/adb/docker/bin/crun --default-runtime crun
```

Atenção: containers **criados antes** (ex.: Portainer) guardam `runc` no config —
é preciso recriá-los (`docker rm` + `docker run ... --runtime crun`).

### Comando final do dockerd

```sh
unshare -m /data/adb/docker/ns-cgroup.sh /data/adb/docker/bin/dockerd \
  --data-root /data/adb/docker/lib \
  --exec-root /data/adb/docker/run \
  --pidfile /data/adb/docker/docker.pid \
  -H unix:///data/adb/docker/docker.sock \
  --iptables=false --ip6tables=false --bridge=none \
  --add-runtime crun=/data/adb/docker/bin/crun --default-runtime crun
```

- `--bridge=none`: sem iptables não há NAT; os serviços usam `--network host`
- `ns-cgroup.sh`: `mount --make-rprivate /` (sem isso o Android remonta
  `/sys/fs/cgroup` no meio do boot e cobre a árvore v1), `mount -t tmpfs none
  /sys/fs/cgroup` e monta `devices memory pids cpu cpuacct cpuset freezer
  blkio net_prio` como cgroup v1
- `pkill containerd-shim` antes de subir: shims velhos ficam em namespaces
  antigos e quebram novas criações

### Estado do daemon (checagem)

```sh
export DOCKER_HOST=unix:///data/adb/docker/docker.sock
/data/adb/docker/bin/docker info | grep -E 'Server Version|Storage Driver|Cgroup'
# Server Version: 29.9.3 | overlayfs | cgroupfs | Cgroup Version: 1
```

### Serviços rodando

```sh
/data/adb/docker/bin/docker run -d --name portainer --restart=always \
  --network host --runtime crun \
  -v /data/adb/docker/data/portainer:/data \
  -v /data/adb/docker/docker.sock:/var/run/docker.sock \
  portainer/portainer-ce:latest
# UI: http://<ip-do-aparelho>:9000 (criar admin nos primeiros 5 min)
# ATENCAO: sem o bind de docker.sock o Portainer abre mas mostra
#          "No environments available" (nenhum ambiente para gerenciar)
# 2.43+: exige "setup token" do log (docker logs portainer | grep setup_token)
#        ou subir com --no-setup-token
```

### Scripts do projeto

| Arquivo | Função |
|---|---|
| `scripts/dockerd-android.sh` | start idempotente: /run, cgroups v1 (ns), DNS, TLS, dockerd |
| `scripts/ns-cgroup.sh` | monta a árvore cgroup v1 no namespace e faz `exec dockerd` |
| `scripts/docker-setup.ps1` | extrai o bundle static arm64 em `/data/adb/docker/bin`, instala start + `service.d` |
| `data/adb/service.d/docker.sh` | `sleep 25; sh /data/adb/docker/start.sh` no boot (Magisk) |
| `scripts/service-docker-watchdog.sh` | watchdog: espera `sys.boot_completed`, sobe o dockerd se estiver parado e re-checa a cada 60 s |

### 11.1 Energia e resiliência (aprendido na prática)

- Com o Docker ligado, o aparelho **precisa ficar na tomada**. Em 4% de bateria ele
  desligou, o Docker parou e o celular saiu da rede.
- Depois de desligar por bateria, o Android volta com USB em **"sem transferência de
  dados"** — é preciso tocar na notificação USB e escolher "Transferência de arquivos"
  para o `adb` voltar.
- Scripts do Magisk em `/data/adb` só rodam de forma confiável após o boot completo;
  usar um **watchdog** (acima) em vez de um `start` único evita ficar sem Docker
  quando o daemon morre.
- Para servidor 24/7: reserva DHCP no roteador, tela desligada, Wi-Fi sempre ativo e,
  idealmente, limite de carga ~80% para preservar a bateria.

---

## 12. Checklist antes de qualquer flash
1. `boot.img` atual salvo no PC (`dd` + `adb pull`).
2. `rollback/*.tar` pronto para Odin (AP) com o boot **que funciona**.
3. Confirmado que o `.config` do build tem `PID_NS/IPC_NS/USER_NS/CGROUP_*` = y
   e `RKP/PROCA/DEFEX/KNOX` desligados.
4. Confirmado que o `Image` **não** contém os padrões RKP/PROCA/defex (evita
   patch parcial e kernel mudo).
5. Cabo USB e Odin abertos **antes** de reiniciar.
6. Saber o caminho de saída do loop → Download Mode (§8).

---

## 13. Comandos úteis

```powershell
# estado do aparelho
adb devices -l
adb shell "uname -r; getprop sys.boot_completed; su -c id"

# reempacotar no aparelho
adb push Image /data/local/tmp/custom_Image
adb push scripts/repack_boot.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/repack_boot.sh /data/local/tmp/custom_Image'"

# gravar (com backup antes!)
adb shell "su -c 'dd if=/data/local/tmp/brepack/boot_atual.img of=/data/local/tmp/backup.img'"
adb shell "su -c 'dd if=/data/local/tmp/m/new-boot.img of=/dev/block/by-name/boot bs=4096 && sync'"

# config do kernel em uso
adb shell "su -c 'zcat /proc/config.gz | grep -E \"PID_NS|CGROUP_DEVICE\"'"
```

```powershell
# build no CI
$tok = Get-Content "$env:TEMP\opencode\.ghtok" -Raw
cd a52-server\kernel-ci
.\publish.ps1 -Token $tok.Trim() -SourceZip "..\downloads\kernel\SM-A525F_CIS_14_Opensource.zip" -Name SM-A52 -Private
```
