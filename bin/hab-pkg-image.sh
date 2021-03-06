#!/bin/bash

KERNEL="core/linux"
INIT=(core/iproute2 core/busybox-static core/util-linux core/coreutils)
# If the variable `$DEBUG` is set, then print the shell commands as we execute.
if [ -n "${DEBUG:-}" ]; then
  set -x
  export DEBUG
fi

# ## Help

# **Internal** Prints help
print_help() {
  printf -- "$program $version
Habitat Package Image - Create a bootable disk image from a set of Habitat packages
USAGE:
  $program [PKG ..]
"
}

# **Internal** Exit the program with an error message and a status code.
#
# ```sh
# exit_with "Something bad went down" 55
# ```
exit_with() {
  if [ "${HAB_NOCOLORING:-}" = "true" ]; then
    printf -- "ERROR: $1\n"
  else
    case "${TERM:-}" in
      *term | xterm-* | rxvt | screen | screen-*)
        printf -- "\033[1;31mERROR: \033[1;37m$1\033[0m\n"
        ;;
      *)
        printf -- "ERROR: $1\n"
        ;;
    esac
  fi
  exit $2
}

find_system_commands() {
  if $(mktemp --version 2>&1 | grep -q 'GNU coreutils'); then
    _mktemp_cmd=$(command -v mktemp)
  else
    if $(/bin/mktemp --version 2>&1 | grep -q 'GNU coreutils'); then
      _mktemp_cmd=/bin/mktemp
    else
      exit_with "We require GNU mktemp to build images; aborting" 1
    fi
  fi
}
# **Internal** Find the internal path for a package
#
# ```
# _pkgpath_for "core/redis"
# ```
_pkgpath_for() {
  hab pkg path $1 | $bb sed -e "s,^$IMAGE_ROOT,,g"
}

build_image() {
  IMAGE_CONTEXT="$($_mktemp_cmd -t -d "${program}-XXXX")"
  IMAGE_ROOT="${IMAGE_CONTEXT}/hab_image_root"
  PKGS=($@)
  IMAGE_PKGS=($@ $KERNEL ${INIT[*]})
  pushd $IMAGE_CONTEXT > /dev/null
  PKG=${PKGS[0]}
  IMAGE_NAME=${PKG//\//-}
  dd if=/dev/zero of="${IMAGE_NAME}" bs=1M count=2048
  echo -e "n\n\n\n\n\nw" | fdisk "${IMAGE_NAME}"

  # -P flag *should* handle this for us, but for some reason doesn't create the partition devices.
  #  This is a workaround for that
  LOOPDEV=$(losetup -f $IMAGE_NAME --show)
  PART_LOOPDEV=$(losetup -o 1048576 -f $IMAGE_NAME --show)

  mkfs.ext4 $PART_LOOPDEV
  mkdir hab_image_root 
  mount $PART_LOOPDEV hab_image_root
  pushd hab_image_root
  env PKGS="${IMAGE_PKGS[*]}" NO_MOUNT=1 hab studio -r $IMAGE_ROOT -t bare new
  create_filesystem_layout
  install_bootloader
  copy_outside
}

package_name_with_version() {
  local ident_file=$(find $IMAGE_ROOT/hab/pkgs/$1 -name IDENT)
  cat $ident_file | awk 'BEGIN { FS = "/" }; { print $1 "-" $2 "-" $3 "-" $4 }'
}

create_filesystem_layout() {
  mkdir -p {bin,sbin,boot,dev,etc,home,lib,mnt,opt,proc,srv,sys}
  mkdir -p boot/grub
  mkdir -p usr/{sbin,bin,include,lib,share,src}
  mkdir -p var/{lib,lock,log,run,spool}
  install -d -m 0750 root 
  install -d -m 1777 tmp
  cp ${program_files_path}/{passwd,shadow,group,issue,profile,locale.sh,hosts,fstab} etc/
  install -Dm755 ${program_files_path}/simple.script usr/share/udhcpc/default.script
  install -Dm755 ${program_files_path}/startup etc/init.d/startup
  install -Dm755 ${program_files_path}/inittab etc/inittab
  install -Dm755 ${program_files_path}/udhcpc-run etc/rc.d/dhcpcd
  install -Dm755 ${program_files_path}/hab etc/rc.d/hab

  hab pkg binlink core/busybox-static bash -d ${PWD}/bin
  hab pkg binlink core/busybox-static login -d ${PWD}/bin
  hab pkg binlink core/busybox-static sh -d ${PWD}/bin
  hab pkg binlink core/busybox-static init -d ${PWD}/sbin
  hab pkg binlink core/hab hab -d ${PWD}/bin

  local _profile_path=""
  for pkg in ${IMAGE_PKGS[@]}; do 
    local _pkgpath_file="$(_pkgpath_for $pkg)/PATH"
    if [[ -f "${_pkgpath_file#/}" ]]; then
      if [[ -z "${_profile_path}" ]]; then
        _profile_path="$(cat ${_pkgpath_file})"
      else
        _profile_path="${_profile_path}:$(cat ${_pkgpath_file})"
      fi 
    fi
  done
  
  echo "export PATH=\${PATH}:${_profile_path}" >> etc/profile

  for pkg in ${PKGS[@]}; do 
    echo "hab sup load ${pkg} --force" >> etc/rc.d/hab
  done
  echo "hab sup run &" >> etc/rc.d/hab
}

install_bootloader() {
  PARTUUID=$(fdisk -l $IMAGE_CONTEXT/$IMAGE_NAME |grep "Disk identifier" |awk -F "0x" '{ print $2}')
  echo $PARTUUID
  cat <<EOB  > ${PWD}/boot/grub/grub.cfg 
linux $(hab pkg path core/linux)/boot/bzImage quiet root=/dev/sda1
boot
EOB

  grub-install --modules=part_msdos --boot-directory="${PWD}/boot" ${LOOPDEV} 
}

cleanup() {
  popd >/dev/null
  umount $IMAGE_ROOT
  rm -rf $IMAGE_CONTEXT
  losetup -d $LOOPDEV
  losetup -d $PART_LOOPDEV
}

copy_outside() {
  mv $IMAGE_CONTEXT/$IMAGE_NAME /src/results/$(package_name_with_version ${PKGS[0]}).raw
}

program=$(basename $0)
program_files_path=$(dirname $0)/../files

find_system_commands

if [[ -z "$@" ]]; then
  print_help
  exit_with "You must specify one or more Habitat packages to put in the image." 1
elif [[ "$@" == "--help" ]]; then
  print_help
else
  build_image $@
  cleanup
fi

