# kernel-ci — build do kernel com Docker nativo (GitHub Actions)

Compila o kernel Samsung 4.14.190 do A52 (a52q) com os namespaces/cgroups que
faltam no kernel stock, direto na nuvem (grátis, ~40 min, sem instalar nada no PC).

## O que este repositório contém

```
.github/workflows/build.yml     workflow (workflow_dispatch + push)
configs/docker.fragment         opções de kernel a habilitar
docs/APRENDIZADOS.md            histórico completo: root, kernel, bootloop, rollback
README.md                       este arquivo
```

> Leia **`docs/APRENDIZADOS.md`** antes de mexer no kernel: ele documenta por que
> os guardas da Samsung (RKP/PROCA/DEFEX) precisam estar desligados e como
> recuperar o aparelho em caso de bootloop.

O **código-fonte do kernel NÃO fica no git**: ele é baixado de um *release asset*
(`kernel-src`) do próprio repositório, porque a árvore tem ~1,5 GB.

## Passo 1 — baixar o source oficial (manual, exige captcha)

1. https://opensource.samsung.com
2. Buscar: `SM-A525M`
3. Baixar **`SM-A525F_CIS_14_Opensource.zip`**
   (versão `A525FXXU6EWL3 / A525MUBU6EWL3`, Android 14 — mesma linha 4.14.190)
4. Salvar em `a52-server\downloads\kernel\`

## Passo 2 — publicar no GitHub

Com um token (fine-grained, permissões `Contents: write`, `Actions: write`,
`Metadata: read`), o script `publish.ps1` cria o repositório privado, sobe os
arquivos, cria o release `kernel-src` com o zip e dispara o build.

## Como disparar

**Pelo navegador:** Actions → `build-kernel` → *Run workflow*

| Input | Valores | Padrão | O que faz |
|---|---|---|---|
| `base` | `stock` / `defconfig` | `stock` | `stock` usa `configs/stock.config` (o `/proc/config.gz` do aparelho); `defconfig` parte da defconfig de vendor da árvore |
| `docker` | `true` / `false` | `true` | aplica `configs/docker.fragment` e publica o artifact `kernel-a52q-docker` |

**Pelo script:** `.\publish.ps1 -Token ... -SourceZip ...` (envia o source como
asset do release `kernel-src` e chama o workflow com os mesmos inputs).

Push que mexe em `configs/**` ou no próprio `build.yml` também dispara. Push em
`docs/**` **não** dispara, para não gastar minutos à toa.

## Passo 3 — pegar o resultado

Actions → run `build-kernel` → artifact (14 dias de retenção):

```
kernel-a52q-docker/     (ou kernel-a52q quando docker=false)
├── Image               kernel compilado (é o que vai para o boot.img)
├── config-final        .config usado de verdade, para auditoria
├── Image.sha256
└── BUILD.txt           commit, inputs, versões de clang/ld, data
```

## Passo 4 — virar boot.img e flashear (feito no PC/aparelho)

```powershell
# 1. envia o Image para o aparelho
adb push Image /data/local/tmp/Image
# 2. no aparelho (root), monta um boot novo com o kernel compilado
#    mantendo o ramdisk já patchado do Magisk:
#    magiskboot unpack boot_atual.img  ->  cp Image kernel  ->  magiskboot repack
# 3. reaplica o Magisk (patch do RKP/defex da Samsung) e flasha via Odin
```

## Toolchain

| Peça | Versão | Por quê |
|---|---|---|
| clang | 12.0.5 (`clang-r416183b`, prebuilt AOSP) | é a linha que a Samsung usou neste kernel |
| binutils | GNU ld **2.27** (prebuilt gcc 4.9) | LLD compila, mas o kernel morre calado no boot |

Os dois são baixados em tempo de build de `android.googlesource.com` (gitiles
archive) e o workflow cria os symlinks `aarch64-linux-gnu-*` a partir do prefixo
`aarch64-linux-android-*` do prebuilt.

## Opções habilitadas (configs/docker.fragment)

| Opção | Motivo |
|---|---|
| `PID_NS`, `IPC_NS`, `UTS_NS`, `NET_NS` | runc/docker |
| `USER_NS` | rootless (podman/docker rootless) |
| `CGROUP_DEVICE`, `CGROUP_PIDS` | regras de /dev e limite de processos |
| `OVERLAY_FS` | storage driver overlay2 |
| `BINFMT_MISC` | rodar binários de outras archs |
| `VETH`, `BRIDGE`, `VXLAN`, NAT/MASQUERADE | rede dos containers |
| `SECCOMP_FILTER`, `KEYS`, `POSIX_MQUEUE` | exigidos por várias imagens |

## Guardas da Samsung (obrigatório desligar)

`RKP_NS_PROT`, `RKP_KDP`, `RKP_DMAP_PROT`, `UH_RKP`, `RKP_MODULE_SUPPORT`,
`SECURITY_DEFEX`, `PROCA`, `FIVE`, `SECURITY_DSMS` — com bootloader destravado
eles não protegem nada, mas o hypervisor **mata** o kernel no boot quando o texto
não é o assinado (foi a causa do bootloop). Detalhes em
`docs/APRENDIZADOS.md` §7.2 e §8.

**Exceções que precisam ficar `=y`** (o código da Samsung chama as funções sem
`#ifdef`, então desligar quebra o link):

| Opção | Onde é chamada |
|---|---|
| `KNOX_NCM` | `net/core/sock.c`, `net/ipv4/udp.c` |
| `SEC_DEBUG` | `arch/arm64/kernel/traps.c` |

O workflow falha de propósito se alguma delas sair da config (`Conferir a
configuracao`), em vez de gerar um kernel que não liga.

## Rollback

O boot stock original está em
`a52-server\downloads\fw\extracted\boot\boot.img`, o boot bom com Magisk em
`downloads/kernel-build/rollback/a52_rollback.tar` (usar como **AP** no Odin).
Alternativa por `dd`:

```sh
su -c "dd if=/data/local/tmp/boot_backup.img of=/dev/block/by-name/boot"
```

Se o aparelho não der boot nem USB: forçar desligamento (`Power`+`Vol Baixo`,
~40 s, sem cabo) → Download Mode (`Vol Cima`+`Vol Baixo` + USB) → Odin.
