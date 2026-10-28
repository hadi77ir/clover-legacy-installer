#!/bin/bash

# The original author of this program, clover-linux-installer, is StarBrilliant.
# This file is released under General Public License version 3.
# You should have received a copy of General Public License text alongside with
# this program. If not, you can obtain it at http://gnu.org/copyleft/gpl.html .
# This program comes with no warranty, the author will not be resopnsible for
# any damage or problems caused by this program.

set -e

ESP_KBLOCKS=${ESP_KBLOCKS:-200}
DISK_KBLOCKS=${DISK_KBLOCKS:-250}
BOOTFILE=${BOOTFILE:-boot6}
VARIANT_MBR=${VARIANT_MBR:-ss}
VARIANT_PBR=${VARIANT_PBR:-f32}

log() {
    echo -ne '\e[1;34m==>\e[0m '>&2
    echo "$*" >&2
    "$@"
}

test_cmd() {
    if which "$1" &>/dev/null
    then
        true
    else
        echo "Error: cannot execute \"$1\", install the package \"$2\"">&2
        exit 2
    fi
}

test_args() {
    if [ "$1" -ne 2 ] && [ "$1" -ne 1 ]; then
        echo "Error: invalid arguments (got $1), check docs">&2
        exit 2
    fi
}

test_cmd 7z p7zip
test_cmd curl curl
test_cmd dd coreutils
test_cmd sfdisk gptfdisk
test_cmd sgdisk gptfdisk
test_cmd mdeltree mtools
test_cmd mcopy mtools
test_cmd gzip gzip
test_cmd mkdir coreutils
test_cmd python3 python3
test_cmd rm coreutils
test_cmd umount util-linux

test_args "$#"


TARGET_IMAGE="$1"
if [ -z "$TARGET_IMAGE" ]
then
    echo 'Invalid input, quitting.'>&2
    exit 1
fi

echo>&2
echo 'Starting build.'>&2

CLOVER_ARC=$2
if [ -z "$2" ]
then
    CLOVER_ARC="CloverV2.zip"
    if [ ! -f CloverV2.zip ]
    then
        log curl -o CloverV2.zip.part -C - -L "$(curl -s -S https://api.github.com/repos/CloverHackyColor/CloverBootloader/releases/latest | python3 ./parse-download-url.py)"
        log mv CloverV2.zip.part CloverV2.zip
    fi
fi

if [ ! -f "$CLOVER_ARC" ]
then
    echo "Error: archive not found">&2
    exit 2
fi


if [ -z "$TMPDIR" ]; then
    TMPDIR=$(mktemp -d)
fi


log mkdir "$TMPDIR/Clover"
log 7z x -o"$TMPDIR/Clover" "$CLOVER_ARC"
FIRST_FILE="$TMPDIR/Clover/"$(ls -AU "$TMPDIR/Clover/" | head -1)
if grep -q ".iso" <<< "$CLOVER_ARC"; then
    log 7z x -o"$TMPDIR/Clover/" "$FIRST_FILE"
fi

# validate clover archive
# boot sectors
CLOVER_SECTORS="CloverV2/BootSectors"
if [ ! -d "$TMPDIR/Clover/CloverV2/BootSectors" ]; then
    if [ -d "$TMPDIR/Clover/usr/standalone/i386" ]; then
        CLOVER_SECTORS="usr/standalone/i386"
    else
        echo "Error: invalid archive. only v1 iso and v2 zip and iso are supported">&2
        exit 2
    fi
fi

# efi folder
CLOVER_EFI="CloverV2/EFI"
if [ ! -d "$TMPDIR/Clover/CloverV2/EFI" ]; then
    if [ -d "$TMPDIR/Clover/EFI" ]; then
        CLOVER_EFI="EFI"
    else
        echo "Error: invalid archive. only v1 iso and v2 zip and iso are supported">&2
        exit 2
    fi
fi

CLOVER_LOADERS="CloverV2/Bootloaders/x64"
if [ ! -d "$TMPDIR/Clover/CloverV2/Bootloaders/x64" ]; then
    if [ -d "$TMPDIR/Clover/usr/standalone/i386/x64" ]; then
        CLOVER_LOADERS="usr/standalone/i386/x64"
    else
        echo "Error: invalid archive. only v1 iso and v2 zip and iso are supported">&2
        exit 2
    fi
fi



if [ ! -f "$TMPDIR/Clover/$CLOVER_SECTORS/boot0$VARIANT_MBR" ]
then

    echo "Error: mbr bootsector variant $VARIANT_MBR was not found">&2
    exit 2
fi

if [ ! -f "$TMPDIR/Clover/$CLOVER_SECTORS/boot1$VARIANT_PBR" ]
then

    echo "Error: partition bootsector variant $VARIANT_PBR was not found">&2
    exit 2
fi

if [ ! -f "$TMPDIR/Clover/$CLOVER_LOADERS/$BOOTFILE" ]
then

    echo "Error: bootloader variant $BOOTFILE was not found">&2
    exit 2
fi

log cp "$TMPDIR/Clover/$CLOVER_SECTORS/boot0$VARIANT_MBR" "$TMPDIR/boot0"
log cp "$TMPDIR/Clover/$CLOVER_SECTORS/boot1$VARIANT_PBR" "$TMPDIR/boot1"
log cp "$TMPDIR/Clover/$CLOVER_LOADERS/$BOOTFILE" "$TMPDIR/boot"

# create gpt
DISK_SIZE_K=$(expr $DISK_KBLOCKS '*' 512)
DISK_SIZE=$(expr $DISK_SIZE_K '*' 1024)
ESP_SIZE_K=$(expr $ESP_KBLOCKS '*' 512)
ESP_SIZE=$(expr $ESP_SIZE_K '*' 1024)

if [ "$ESP_SIZE_K" -ge "$DISK_SIZE_K" ]; then
    echo "Error: esp size greater than disk size">&2
    exit 2
fi

log rm -f "$TARGET_IMAGE"

TMP_IMAGE="$TMPDIR/final.img"
log truncate -s "$DISK_SIZE" "$TMP_IMAGE"
log sgdisk "$TMP_IMAGE" -o
log sgdisk "$TMP_IMAGE" -n '1::+'"$ESP_SIZE_K"'KiB' -t '1:ef00' -c '1:EFI'

# patch mbr
log dd if="$TMP_IMAGE" bs=512 count=1 >"$TMPDIR/origMBR"
log cp "$TMPDIR/origMBR" "$TMPDIR/newMBR"
log dd if="$TMPDIR/boot0" of="$TMPDIR/newMBR" bs=440 count=1 conv=notrunc
log dd if="$TMPDIR/newMBR" of="$TMP_IMAGE" bs=512 count=1 conv=nocreat,notrunc

# create esp
ESP_FILE="$TMPDIR/esp.img"
log mkfs.vfat -F 32 -C "$ESP_FILE" "$ESP_SIZE_K"

# patch pbr
log dd if="$ESP_FILE" bs=512 count=1 >"$TMPDIR/origPBR1"
log cp "$TMPDIR/boot1" "$TMPDIR/newPBR1"
log dd if="$TMPDIR/origPBR1" of="$TMPDIR/newPBR1" skip=3 seek=3 bs=1 count=87 conv=notrunc

# Assume the backup boot sector is located at 0xC00 (sector 6) as is mkfs.vfat default...
log dd if="$ESP_FILE" skip=6 bs=512 count=1 >"$TMPDIR/origPBR2"
log cp "$TMPDIR/boot1" "$TMPDIR/newPBR2"
log dd if="$TMPDIR/origPBR2" of="$TMPDIR/newPBR2" skip=3 seek=3 bs=1 count=87 conv=notrunc

log dd if="$TMPDIR/newPBR1" of="$ESP_FILE" bs=512 count=1 conv=nocreat,notrunc
log dd if="$TMPDIR/newPBR2" of="$ESP_FILE" seek=6 bs=512 count=1 conv=nocreat,notrunc

#log mdeltree -i "$ESP_FILE" ::EFI/CLOVER
# copy selected bootloader
log mcopy -i "$ESP_FILE" "$TMPDIR/boot" ::boot

# copy all loaders in case of alt sectors being used
for i in "$TMPDIR/Clover/$CLOVER_LOADERS"/*;
do
log mcopy -s -i "$ESP_FILE" "$i" ::
done

# copy efi files
log mcopy -s -i "$ESP_FILE" "$TMPDIR/Clover/$CLOVER_EFI" ::EFI
log mdel -i "$ESP_FILE" ::EFI/CLOVER/config.plist || true

# copy over target image
OFFSET=$(parted -s "$TMP_IMAGE" unit B print | awk '/^Number/{p=1;next}; p{gsub(/[^[:digit:]]/, "", $2); print $2}')
echo "ESP Offset found: $OFFSET">&2
OFFSET_BLOCKS=$(expr $OFFSET '/' 512)
ESP_BLOCKS=$(expr $ESP_KBLOCKS '*' 1024)
log dd if="$ESP_FILE" of="$TMP_IMAGE" bs=512 seek=$OFFSET_BLOCKS count=$ESP_BLOCKS conv=nocreat,notrunc

log mv "$TMP_IMAGE" "$TARGET_IMAGE"

echo>&2
echo 'Image has been built successfully.'>&2
