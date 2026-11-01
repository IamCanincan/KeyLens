#!/bin/sh
set -u
cd "/mnt/d/Github Repositories/TS-AUTO-ADD" || exit 1
rm -rf /tmp/klmod /data/adb
mkdir -p /tmp/klmod /data/adb/tricky_store /data/adb/modules/tricky_store /data/adb/modules/keylens
cp -r module/* /tmp/klmod/
mkdir -p /tmp/klmod/bin && cp rust/target/release/keylens /tmp/klmod/bin/keylens && chmod +x /tmp/klmod/bin/keylens
printf 'id=tricky_store\nversion=v1.9.9\n' > /data/adb/modules/tricky_store/module.prop
printf 'com.a\ncom.b?\n' > /data/adb/tricky_store/target.txt
printf '2026-10-05\nsystem=2026-10-01\n' > /data/adb/tricky_store/security_patch.txt
printf 'id=keylens\nname=KeyLens\nversion=v3.0.1\ndescription=ok\n' > /data/adb/modules/keylens/module.prop
echo "== shell 路径"
KL_USE_RUST=0 sh /tmp/klmod/webui.sh targets 2>&1 | head -5
echo "== rust 路径"
KL_USE_RUST=1 sh /tmp/klmod/webui.sh targets 2>&1 | head -5
