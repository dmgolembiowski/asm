#!/bin/bash
set -e

# builds asm.usb (a raw image which can be written to a flashdrive)

msg()  { printf '\033[0;36;7m*\033[27m %s\033[0m%s\n' "$*" >&2; }
inf()  { printf '\033[1;92;7m+\033[27m %s\033[0m%s\n' "$*" >&2; }
warn() { printf '\033[0;33;7m!\033[27m %s\033[0m%s\n' "$*" >&2; }
err()  { printf '\033[1;91;7mx\033[27m %s\033[0m%s\n' "$*" >&2; }
absreal() { realpath "$1" || readlink -f "$1"; }


# osx support; choose macports or homebrew:
#   port install qemu coreutils findutils gnutar gsed gawk xorriso e2fsprogs
#   brew install qemu coreutils findutils gnu-tar gnu-sed gawk xorriso e2fsprogs
gtar=$(command -v gtar || command -v gnutar) || true
[ ! -z "$gtar" ] && command -v gfind >/dev/null && {
	tar()  { $gtar "$@"; }
	sed()  { gsed  "$@"; }
	find() { gfind "$@"; }
	sort() { gsort "$@"; }
	command -v grealpath >/dev/null &&
		realpath() { grealpath "$@"; }
    
    export PATH="/usr/local/opt/e2fsprogs/sbin/:$PATH"
    macos=1
}


td=$(mktemp --tmpdir -d asm.XXXXX || mktemp -d -t asm.XXXXX)
trap "rv=$?; rm -rf $td; tput smam || printf '\033[?7h'; exit $rv" INT TERM EXIT

profile=
sz=1.8
iso=
iso_out=
usb_out=asm.usb
b=$td/b
mirror=https://mirrors.edge.kernel.org/alpine


help() {
    sed -r $'s/^( +)(-\w+ +)([A-Z]\w* +)/\\1\\2\e[36m\\3\e[0m/; s/(.*default: )(.*)/\\1\e[35m\\2\e[0m/' <<EOF

arguments:
  -i ISO    original/input alpine release iso
  -p NAME   profile to apply, default: <NONE>
  -s SZ     fat32 partition size in GiB, default: $sz
  -m URL    mirror (for iso/APKs), default: $mirror
  -ou PATH  output path for usb image, default: ${usb_out:-DISABLED}
  -oi PATH  output path for isohybrid, default: ${iso_out:-DISABLED}
  -b PATH   build-dir, default: $b

notes:
  -s cannot be smaller than the source iso

examples:
  $0 -i dl/alpine-extended-3.16.2-x86_64.iso
  $0 -i dl/alpine-extended-3.16.2-x86_64.iso -oi asm.iso -s 3.6 -b b
  $0 -i dl/alpine-extended-3.16.2-x86_64.iso -p webkiosk
  $0 -i dl/alpine-standard-3.16.2-x86.iso -s 0.2 -p r0cbox

EOF
    exit 1
}


err=
while [ "$1" ]; do
    k="$1"; shift
    v="$1"; shift || true
    case "$k" in
        -i)  iso="$v"; ;;
        -s)  sz="$v";  ;;
        -b)  b="$v";   ;;
        -p)  profile="$v"; ;;
        -ou) usb_out="$v"; ;;
        -oi) iso_out="$v"; ;;
        -m)  mirror="${v%/}"; ;;
        *)   err "unexpected argument: $k"; help; ;;
    esac
done

[ -z "$iso" ] && {
    err "need argument -i (path to original alpine iso, will be downloaded if it does not exist)"
    help
}

printf '%s\n' "$iso" | grep -q : && {
    err "the argument to -i should be a local path, not a URL -- it will be downloaded if it does not exist"
    help
}

[ ! "$profile" ] || [ -e "p/$profile" ] || {
    err "selected profile does not exist: $PWD/p/$profile"
    exit 1
}

isoname="${iso##*/}"
read flavor ver arch < <(echo "$isoname" |
  awk -F- '{sub(/.iso$/,"");v=$3;sub(/.[^.]+$/,"",v);print$2,v,$4}')

[ $macos ] && {
    accel="-M accel=hvf"
    video=""
} || {
    accel="-enable-kvm"
    video="-vga qxl"
}

need() {
    command -v $1 >/dev/null || {
        err need $1
        err=1
    }
}
qemu=qemu-system-$arch
[ $arch = x86 ] && qemu=${qemu}_64
command -v $qemu >/dev/null || qemu=$(
    PATH="/usr/libexec:$PATH" command -v qemu-kvm || echo $qemu)
need $qemu
need qemu-img
need bc
need truncate
need mkfs.ext3
[ "$iso_out" ] && need xorrisofs
[ $err ] && exit 1

need_root=
mkfs.ext3 -h 2>&1 | grep -qE '\[-d\b' ||
    need_root=1

[ $need_root ] && [ $(id -u) -ne 0 ] && {
    err "you must run this as root,"
    err "because your mkfs.ext3 is too old to have -d"
    exit 1
}

mkdir -p "$(dirname "$iso")"
iso="$(absreal "$iso")"

[ -e "$iso" ] || {
    iso_url="$mirror/v$ver/releases/$arch/$isoname"
    msg "iso not found; downloading from $iso_url"
    need wget
    need sha512sum
    [ $err ] && exit 1

    mkdir -p "$(dirname "$iso")"
    wget "$iso_url" -O "$iso" || {
        rm -f "$iso"; exit 1
    }
    wget "$iso_url.sha512" -O "$iso.sha512" || {
        rm -f "$iso.sha512"
        warn "iso.sha512 not found on mirror; trying the yaml"
        yaml_url="$mirror/v$ver/releases/$arch/latest-releases.yaml"
        wget "$yaml_url" -O "$iso.yaml" || {
            rm -f "$iso.yaml"; exit 1
        }
        awk -v iso="$isoname" '/^-/{o=0} $2==iso{o=1} o&&/sha512:/{print$2}' "$iso.yaml" > "$iso.sha512"
    }
    msg "verifying checksum:"
    (cat "$iso.sha512"; sha512sum "$iso") |
    awk '1;v&&v!=$1{exit 1}{v=$1}' || {
        err "sha512 verification of the downloaded iso failed"
        mv "$iso"{,.corrupt}
        exit 1
    }
}

usb_out="$(absreal "$usb_out")"
[ "$iso_out" ] &&
    rm -f "$iso_out" &&
    iso_out="$(absreal "$iso_out")"

# build-env: prepare apkovl
rm -rf $b
mkdir -p $b/fs/sm/img
cp -pR etc $b/

# live-env: add apkovl + asm contents
msg "copying sources to $b"
cp -pR etc sm $b/fs/sm/img/
[ "$profile" ] &&
    (cd p/$profile && tar -c *) |
    tar -xC $b/fs/sm/img/

pushd $b >/dev/null

# both-envs: add mirror and profile info
tee fs/sm/img/etc/profile.d/asm-profile.sh >fs/sm/asm.sh <<EOF
export IVER=$ver
export IARCH=$arch
export MIRROR=$mirror
export AN=$profile
EOF

# live-env: finalize apkovl
( cd fs/sm/img
  tar -czvf the.apkovl.tar.gz etc
  rm -rf etc )

# build-env: finalize apkovl (tty1 is ttyS0 due to -nographic)
sed -ri 's/^tty1/ttyS0/' etc/inittab
tar -czvf fs/the.apkovl.tar.gz etc

cat >>fs/sm/asm.sh <<'EOF'
set -ex
eh() {
    [ $? -eq 0 ] && exit 0
    printf "\033[A\033[1;37;41m\n\n  asm build failed; blanking partition header  \n\033[0m\n"
    sync; head -c1024 /dev/zero >/dev/vda
    poweroff
}
trap eh INT TERM EXIT

log hello from asm builder
sed -ri 's/for i in \$initrds; do/for i in ${initrds\/\/,\/ }; do/' /sbin/setup-bootable
c="apk add -q util-linux sfdisk syslinux dosfstools"
if ! $c; then
    wrepo
    $c
fi
if apk add -q sfdisk; then
    echo ',,0c,*' | sfdisk -q --label dos /dev/vda
else
    # deadcode -- this branch is never taken --
    # left for reference if you REALLY cant install sfdisk
    printf '%s\n' o n p 1 '' '' t c a 1 w | fdisk -ub512 /dev/vda
fi
mdev -s
mkfs.vfat -n ASM /dev/vda1
log setup-bootable
setup-bootable -v /media/cdrom/ /dev/vda1
echo 1 | fsck.vfat -w /dev/vda1 | grep -vE '^  , '

log disabling modloop verification
mount -t vfat /dev/vda1 /mnt
( cd /mnt/boot;
for f in */syslinux.cfg */grub.cfg; do sed -ri '
    s/( quiet)( .*|$)/\1\2 modloop_verify=no /;
    s/(^TIMEOUT )[0-9]{2}$/\110/;
    s/(^set timeout=)[0-9]$/\11/;
    ' $f; 
done )

log adding ./sm/
cp -pR $AR/sm/img/* /mnt/ 2>&1 | grep -vF 'preserve ownership of' || true

f=$AR/sm/img/sm/post-build.sh
[ -e $f ] && log $f && $SHELL $f

log all done -- shutting down
sync
fstrim -v /mnt || true
echo; df -h /mnt; echo
umount /mnt
poweroff
EOF
chmod 755 fs/sm/asm.sh

echo
msg "ovl size calculation..."
# 32 KiB per inode + apparentsize x1.1 + 8 MiB padding, ceil to 512b
osz=$(find fs -printf '%s\n' | awk '{n++;s+=$1}END{print int((n*32*1024+s*1.1+8*1024*1024)/512)*512}')
msg "ovl size estimate $osz"
truncate -s $osz ovl.img
a="-T big -I 128 -O ^ext_attr"
mkfs.ext3 -Fd fs $a ovl.img || {
    mkfs.ext3 -F $a ovl.img
    mkdir m
    mount ovl.img m
    cp -prT fs m
    umount m
    rmdir m
}

# user-provided; ceil to 512b
sz=$(echo "(($sz*1024*1024*1024+511)/512)*512" | tr , . | LC_ALL=C bc)
truncate -s ${sz} asm.usb

mkfifo s.{in,out}
[ $flavor = virt ] && kern=virt || kern=lts
(awk '1;/^ISOLINUX/{exit}' <s.out; echo "$kern console=ttyS0" >s.in; cat s.out) &

cores=$(lscpu -p | awk -F, '/^[0-9]+,/{t[$2":"$3":"$4]=1} END{n=0;for(v in t)n++;print n}')

$qemu $accel -nographic -serial pipe:s -cdrom "$iso" -cpu host -smp $cores -m 1024 \
  -drive format=raw,if=virtio,discard=unmap,file=asm.usb \
  -drive format=raw,if=virtio,discard=unmap,file=ovl.img

# builder nukes the partition header on error; check if it did
od -v <asm.usb | awk 'NR>4{exit e}{$1=""}/[^0 ]/{e=1}END{exit e}' && {
    err some of the build steps failed
    exit 1
}

popd >/dev/null
mv $b/asm.usb "$usb_out"
rm -rf $b

[ "$iso_out" ] && {
    c="mount -o ro,offset=1048576 $usb_out $b"
    mkdir $b
    $c || sudo $c || {
        warn "please run the following as root:"
        echo "    $c" >&2
        while sleep 0.2; do
            [ -e $b/the.apkovl.tar.gz ] &&
                sleep 1 && break
        done
    }
    [ -e $b/the.apkovl.tar.gz ] || {
        err failed to mount the usb image for iso conversion
        exit 1
    }
    msg now building "$iso_out" ...
    # https://github.com/alpinelinux/aports/blob/569ab4c43cba612670f1a153a077b42474c33267/scripts/mkimg.base.sh
    xorrisofs \
      -quiet \
      -output "$iso_out" \
      -full-iso9660-filenames \
      -joliet \
      -rational-rock \
      -sysid LINUX \
      -volid asm-$(date +%Y-%m%d-%H%M%S) \
      -isohybrid-mbr $b/boot/syslinux/isohdpfx.bin \
      -eltorito-boot boot/syslinux/isolinux.bin \
      -eltorito-catalog boot/syslinux/boot.cat \
      -no-emul-boot \
      -boot-load-size 4 \
      -boot-info-table \
      -eltorito-alt-boot \
      -e boot/grub/efi.img \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      -follow-links \
      $b && rv= || rv=$?

    c="umount $b"
    $c || sudo $c || {
        warn "please run the following as root:"
        echo "    $c" >&2
        while sleep 0.2; do
            [ ! -e $b/the.apkovl.tar.gz ] &&
                sleep 1 && break
        done
    }
    rmdir $b
    [ $rv ] &&
        exit $rv
}

cat <<EOF

=======================================================================

alpine-service-mode was built successfully (nice)

you can now write the image to a usb flashdrive:
  cat $usb_out >/dev/sdi && sync

or compress it for uploading:
  pigz $usb_out

or try it in qemu:
  $qemu $accel $video -drive format=raw,file=$usb_out -m 512
  $qemu $accel $video -drive format=raw,file=$usb_out -net bridge,br=virhost0 -net nic,model=virtio -m 128

EOF
