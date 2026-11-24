# Permissão do i2c (DDC/CI) com regra udev

Corrige os erros `EACCES` que o PowerDevil (via libddcutil) registra ao abrir
`/dev/i2c-*` logo depois de acordar do sleep.

Testado em: Fedora 45, KDE Plasma 6.8.3, ddcutil 3.0.2, ASUS TUF F15 (Intel + NVIDIA em modo Hybrid).

## O que já existe

O pacote `ddcutil` instala `/usr/lib/udev/rules.d/60-ddcutil-i2c.rules`:

```
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", TAG+="uaccess"
```

- **`SUBSYSTEM=="i2c-dev"`**: vale para os devices `/dev/i2c-*` criados pelo
  módulo `i2c_dev`, que o ddcutil já carrega via
  `/usr/lib/modules-load.d/ddcutil.conf`.
- **`ATTRS{class}=="0x03*"`**: limita aos barramentos i2c que pertencem a uma
  placa de vídeo (classe PCI 0x03). Os i2c de touchpad, sensores etc. ficam de
  fora e continuam `crw-------`.
- **`TAG+="uaccess"`**: o systemd-logind dá um ACL de leitura e escrita ao
  usuário sentado na sessão ativa. É o `+` no `ls -l` e o `user:<você>:rw-` no
  `getfacl`. Não precisa de grupo nem de senha.

## Por que falha depois do sleep

Ao acordar, os devices i2c da placa de vídeo são recriados. Os ACLs do
`uaccess` são aplicados **alguns instantes depois** pelo logind. O PowerDevil
tenta abrir o barramento logo no resume, encontra o device só com
`root:root 0600` e recebe `EACCES`. No journal aparece assim:

```
org_kde_powerdevil: Open failed for /dev/i2c-16, errno=EACCES(-13): Permission denied
org_kde_powerdevil:    Group i2c does not exist
```

O próprio arquivo de regra do ddcutil comenta esse problema ("Some systems have
been seen to exhibit transitory EACCES errors on return from sleep when tag
uaccess is relied on") e sugere usar um grupo.

## A correção

Com um grupo, a permissão sai junto com a criação do device e não existe essa
janela de tempo:

```sh
sudo groupadd --system i2c
sudo usermod -aG i2c $USER
echo 'SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", GROUP="i2c", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/60-ddcutil-i2c-group.rules
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=i2c-dev
```

- **`GROUP="i2c", MODE="0660"`**: o dono continua root, o grupo `i2c` também
  pode ler e escrever, e os outros usuários não têm acesso. O filtro
  `ATTRS{class}=="0x03*"` fica para não abrir os i2c que não são de vídeo (a
  regra comentada no ddcutil não tem esse filtro).
- **`/etc/udev/rules.d/`**: regras nesse diretório têm prioridade sobre
  `/usr/lib/` e sobrevivem a atualizações do pacote. A regra `uaccess` original
  continua valendo junto, sem conflito.
- **`udevadm trigger`**: aplica a regra aos devices que já existem, sem
  reiniciar.

Depois de rodar, saia da sessão e entre de novo (ou reinicie) para o grupo novo
entrar em vigor.

### Conferir

```sh
id                       # deve listar i2c
ls -l /dev/i2c-*         # os de vídeo devem mostrar "root i2c"
ddcutil detect --brief
```

### Desfazer

```sh
sudo rm /etc/udev/rules.d/60-ddcutil-i2c-group.rules
sudo gpasswd -d $USER i2c
sudo groupdel i2c
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=i2c-dev
```

## O que talvez não valha a pena

Com a permissão funcionando, `ddcutil detect` mostrou as duas telas como
**"Invalid display"**:

- **eDP-1 (`/dev/i2c-11`)**: é o painel interno do notebook, que nunca tem
  DDC/CI. O brilho dele vem do `intel_backlight`, e isso já funciona.
- **DP-1 (`/dev/i2c-12`, ARZOPA)**: o ddcutil encontra o barramento, mas o
  monitor não responde ao DDC/CI. Muitos monitores portáteis não suportam
  DDC/CI, e em alguns ele vem desligado no menu (OSD).

Então a regra udev só acaba com os erros `EACCES` no log depois do resume. Ela
**não vai fazer** o brilho do ARZOPA controlar a luz de fundo de verdade. Para
isso o monitor precisaria ter DDC/CI ou uma opção para ativá-lo no menu. Sem
DDC/CI, o KWin controla o brilho do DP-1 escurecendo a imagem, não mudando a luz
de fundo.

Se o menu do monitor tiver uma opção de DDC/CI, vale ativar e rodar
`ddcutil detect` de novo antes de aplicar a regra.

## Relacionado

- [`fix-dim-after-resume.sh`](fix-dim-after-resume.sh): outro problema do
  resume, em que o escurecimento automático fica travado e as telas continuam
  escuras mesmo com o brilho em 100%.
