#!/bin/sh
# One-shot WoW 1.12.1 client data extractor.
# Runs inside a separate container; moves DBC/Maps/VMaps/Cameras into
# the persistent core-data volume.
set -e

echo "=== Stage 1: MapExtractor (DBC + Maps) ==="
cp -r /opt/superui-core/bin/Extractors /tmp/ext/
cd /tmp/ext
/opt/superui-core/bin/Extractors/MapExtractor -i /data 2>&1 | tail -5
echo "  -> MapExtractor done"

echo "=== Stage 2: VMapExtractor (raw visual maps, takes 10-20 min) ==="
/opt/superui-core/bin/Extractors/VMapExtractor -l -d /data/Data 2>&1 | tail -5
echo "  -> VMapExtractor done"

echo "=== Stage 3: VMapAssembler ==="
mkdir -p /tmp/ext/vmaps
/opt/superui-core/bin/Extractors/VMapAssembler /tmp/ext/vmaps /tmp/ext/Buildings 1 2>&1 | tail -5
echo "  -> VMapAssembler done"

echo "=== Stage 4: Move output to /opt/superui-core/data ==="
# Empty each subdir's contents without touching the mount point itself
for d in dbc maps Cameras vmaps; do
    if [ -d "/tmp/ext/$d" ]; then
        rm -rf "/opt/superui-core/data/$d"/* 2>/dev/null || true
        mv "/tmp/ext/$d"/* "/opt/superui-core/data/$d/" 2>/dev/null \
            || cp -r "/tmp/ext/$d/." "/opt/superui-core/data/$d/"
        size=$(du -sh "/opt/superui-core/data/$d" 2>/dev/null | cut -f1)
        echo "  -> moved $d ($size)"
    fi
done

echo "=== Done ==="
ls -la /opt/superui-core/data/
du -sh /opt/superui-core/data/* 2>/dev/null