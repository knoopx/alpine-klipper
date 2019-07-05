#!/usr/bin/env bash

set -ex

# params

: ${KLIPPER_REPO:="https://github.com/KevinOConnor/klipper.git"}
: ${KLIPPER_DIR:="$HOME/klipper"}
: ${KLIPPER_DWC2_DIR:="$HOME/klipper-dwc2"}
: ${VIRTUALENV_DIR:="$HOME/klippy-env"}
: ${DWC2_RELEASE_URL:="https://github.com/chrishamm/DuetWebControl/releases/download/2.0.0-RC7/DuetWebControl-Duet2.zip"}
: ${DWC2_DIR:="$HOME/sdcard/dwc2/web"}

if [ "$EUID" -eq 0 ]; then
    echo "This script must not run as root"
    exit -1
fi

# klipper

sudo apk --update add git
git clone $KLIPPER_REPO $KLIPPER_DIR

grep testing /etc/apk/repositories || echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" | sudo tee -a /etc/apk/repositories
sudo apk --update add py2-virtualenv python2-dev libffi-dev build-base ncurses-dev libusb-dev avrdude gcc-avr binutils-avr avr-libc stm32flash dfu-util newlib-arm-none-eabi gcc-arm-none-eabi binutils-arm-none-eabi

test -d ${VIRTUALENV_DIR} || virtualenv ${VIRTUALENV_DIR}
${VIRTUALENV_DIR}/bin/pip install -r ${KLIPPER_DIR}/scripts/klippy-requirements.txt

# init script

sudo /bin/sh -c "cat > /etc/init.d/klipper" << EOF
#!/sbin/openrc-run
command="${VIRTUALENV_DIR}/bin/python"
command_args="${KLIPPER_DIR}/klippy/klippy.py $HOME/printer.cfg -l /tmp/klippy.log"
command_background=true
command_user="$USER"
pidfile="/run/$RC_SVCNAME/$RC_SVCNAME.pid"
depend() {
  need net
}
EOF

sudo chmod +x /etc/init.d/klipper
sudo rc-update add klipper

# Klipper DWC2

${VIRTUALENV_DIR}/bin/pip install tornado==5.1.1
git clone https://github.com/Stephan3/dwc2-for-klipper.git $KLIPPER_DWC2_DIR
ln -s "$KLIPPER_DWC2_DIR/web_dwc2.py" "$KLIPPER_DIR/klippy/extras/web_dwc2.py"

patch -N $KLIPPER_DIR/klippy/gcode.py << EOF
diff --git a/klippy/gcode.py b/klippy/gcode.py
--- a/klippy/gcode.py
+++ b/klippy/gcode.py
@@ -28,6 +28,7 @@ class GCodeParser:
         self.partial_input = ""
         self.pending_commands = []
         self.bytes_read = 0
+        self.respond_callbacks = []
         self.input_log = collections.deque([], 50)
         # Command handling
         self.is_printer_ready = False
@@ -292,7 +293,8 @@ class GCodeParser:
             self._process_commands(script.split('\n'), need_ack=False)
     def get_mutex(self):
         return self.mutex
-    # Response handling
+    def register_respond_callback(self, callback):
+        self.respond_callbacks.append(callback)
     def ack(self, msg=None):
         if not self.need_ack or self.is_fileinput:
             return
@@ -309,6 +311,8 @@ class GCodeParser:
             return
         try:
             os.write(self.fd, msg+"\n")
+            for callback in self.respond_callbacks:
+                callback(msg+"\n")
         except os.error:
             logging.exception("Write g-code response")
     def respond_info(self, msg, log=True):
EOF

# DWC2
mkdir -p $DWC2_DIR
unzip -o <(curl -sL $DWC2_RELEASE_URL) -d $DWC2_DIR
find $DWC2_DIR -iname "*.gz" -exec gunzip -f {} \;
