#!/usr/bin/env bash

set -euxo pipefail

: ${CONFIG_PATH:="$HOME/config"}
: ${GCODE_PATH:="$HOME/gcode"}

: ${KLIPPER_REPO:="https://github.com/KevinOConnor/klipper.git"}
: ${KLIPPER_PATH:="$HOME/klipper"}
: ${KLIPPY_VENV_PATH:="$HOME/venv/klippy"}

: ${MOONRAKER_REPO:="https://github.com/Arksine/moonraker"}
: ${MOONRAKER_PATH:="$HOME/moonraker"}
: ${MOONRAKER_VENV_PATH:="$HOME/venv/moonraker"}

: ${CLIENT:="fluidd"}
: ${CLIENT_PATH:="$HOME/www"}

if [ $(id -u) = 0 ]; then
    echo "This script must not run as root"
    exit 1
fi

################################################################################
# PRE
################################################################################

sudo apk add git unzip python2 python2-dev libffi-dev make gcc g++ \
ncurses-dev avrdude gcc-avr binutils-avr avr-libc \
python3 py3-virtualenv \
python3-dev freetype-dev fribidi-dev harfbuzz-dev jpeg-dev lcms2-dev openjpeg-dev tcl-dev tiff-dev tk-dev zlib-dev \
jq udev

sudo rc-update del mdev sysinit
sudo setup-udev

case $CLIENT in
  fluidd)
    CLIENT_RELEASE_URL=`curl -s https://api.github.com/repos/cadriel/fluidd/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  mainsail)
    CLIENT_RELEASE_URL=`curl -s https://api.github.com/repos/meteyou/mainsail/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  *)
    echo "Unknown client $CLIENT (choose fluidd or mainsail)"
    exit 2
    ;;
esac

################################################################################
# KLIPPER
################################################################################

mkdir -p $CONFIG_PATH $GCODE_PATH

test -d $KLIPPER_PATH || git clone $KLIPPER_REPO $KLIPPER_PATH
test -d $KLIPPY_VENV_PATH || virtualenv -p python2 $KLIPPY_VENV_PATH
$KLIPPY_VENV_PATH/bin/python -m pip install --upgrade pip
$KLIPPY_VENV_PATH/bin/pip install -r $KLIPPER_PATH/scripts/klippy-requirements.txt

sudo tee /etc/init.d/klipper <<EOF
#!/sbin/openrc-run
command="$KLIPPY_VENV_PATH/bin/python"
command_args="$KLIPPER_PATH/klippy/klippy.py $CONFIG_PATH/printer.cfg -l /tmp/klippy.log -a /tmp/klippy_uds"
command_background=true
command_user="$USER"
pidfile="/run/klipper.pid"
EOF

sudo chmod +x /etc/init.d/klipper
sudo rc-update add klipper
sudo service klipper start

################################################################################
# MOONRAKER
################################################################################

sudo apk add libsodium curl-dev

test -d $MOONRAKER_PATH || git clone $MOONRAKER_REPO $MOONRAKER_PATH
test -d $MOONRAKER_VENV_PATH || virtualenv -p python3 $MOONRAKER_VENV_PATH
$MOONRAKER_VENV_PATH/bin/python -m pip install --upgrade pip
$MOONRAKER_VENV_PATH/bin/pip install -r $MOONRAKER_PATH/scripts/moonraker-requirements.txt

sudo tee /etc/init.d/moonraker <<EOF
#!/sbin/openrc-run
command="$MOONRAKER_VENV_PATH/bin/python"
command_args="$MOONRAKER_PATH/moonraker/moonraker.py"
command_background=true
command_user="$USER"
pidfile="/run/moonraker.pid"
depend() {
  before klipper
}
EOF

sudo chmod a+x /etc/init.d/moonraker

cat > $HOME/moonraker.conf <<EOF
[server]
host: 0.0.0.0
config_path: $CONFIG_PATH

[authorization]
trusted_clients:
  192.168.1.0/24

[octoprint_compat]

[update_manager]

[update_manager client fluidd]
type: web
repo: cadriel/fluidd
path: ~/www
EOF

sudo rc-update add moonraker
sudo service moonraker start

################################################################################
# MAINSAIL/FLUIDD
################################################################################

sudo apk add caddy curl

sudo tee /etc/caddy/Caddyfile <<EOF
:80

encode gzip

root * $CLIENT_PATH

@moonraker {
  path /server/* /websocket /printer/* /access/* /api/* /machine/*
}

route @moonraker {
  reverse_proxy localhost:7125
}

route /webcam {
  reverse_proxy localhost:8081
}

route {
  try_files {path} {path}/ /index.html
  file_server
}
EOF

test -d $CLIENT_PATH && rm -rf $CLIENT_PATH
mkdir -p $CLIENT_PATH
(cd $CLIENT_PATH && wget -q -O $CLIENT.zip $CLIENT_RELEASE_URL && unzip $CLIENT.zip && rm $CLIENT.zip)

sudo rc-update add caddy
sudo service caddy start

################################################################################
# AUTO DELETE OLD GCODE
################################################################################

sudo tee /etc/periodic/15min/klipper <<END
#!/bin/sh
find $GCODE_PATH -mtime +5 -type f -delete
END

sudo chmod a+x /etc/periodic/15min/klipper

sudo service crond start
sudo rc-update add crond

# UPDATE SCRIPT

cat > $HOME/update <<EOF
#!/usr/bin/env bash

set -exo pipefail

: \${CLIENT:="$CLIENT"}
: \${CLIENT_PATH:="$CLIENT_PATH"}

case \$CLIENT in
  fluidd)
    CLIENT_RELEASE_URL=`curl -s https://api.github.com/repos/cadriel/fluidd/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  mainsail)
    CLIENT_RELEASE_URL=`curl -s https://api.github.com/repos/meteyou/mainsail/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  *)
    echo "Unknown client \$CLIENT (choose fluidd or mainsail)"
    exit 2
    ;;
esac

# KLIPPER
sudo service klipper stop
(cd $KLIPPER_PATH && git fetch && git rebase origin/master)
$KLIPPY_VENV_PATH/bin/pip install -r $KLIPPER_PATH/scripts/klippy-requirements.txt
test -z "\$FLASH_DEVICE" || (cd $KLIPPER_PATH && make && make flash)
sudo service klipper start

# MOONRAKER
sudo service moonraker stop
(cd $MOONRAKER_PATH && git fetch && git rebase origin/master)
$MOONRAKER_VENV_PATH/bin/pip install -r ~/moonraker/scripts/moonraker-requirements.txt
sudo service moonraker start

# CLIENT
rm -Rf \$CLIENT_PATH
mkdir -p \$CLIENT_PATH
(cd \$CLIENT_PATH && wget -q -O \$CLIENT.zip \$CLIENT_RELEASE_URL && unzip \$CLIENT.zip && rm \$CLIENT.zip)
sudo service caddy start
EOF

chmod a+x $HOME/update
