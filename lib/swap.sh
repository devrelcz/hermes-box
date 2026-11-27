# shellcheck shell=bash
# Host swap for setup.sh. The parameters allow testing against isolated files.
ensure_swap() (  # <swap file> <fstab> <active swaps>
  local swap_file="$1" fstab="$2" swaps="$3" available temporary created=0
  local size_mib=2048 reserve_mib=2048

  # Serialize attempts on this host. Never change swap configured by its owner.
  if ! exec 9<"$fstab" || ! flock -x 9 || [ ! -r "$swaps" ]; then
    printf '%s\n' "Could not check the server's swap settings." >&2
    return 1
  fi
  if awk '$1 !~ /^#/ && $3 == "swap" { found = 1 } END { exit !found }' "$fstab"; then
    printf '%s\n' "The server already has swap configured."
    return 0
  fi
  # A previous run may have activated our swap but stopped before saving it.
  if ! awk -v file="$swap_file" 'NR > 1 && $1 == file { found = 1 } END { exit !found }' "$swaps"; then
    if awk 'NR > 1 && NF { found = 1 } END { exit !found }' "$swaps"; then
      printf '%s\n' "The server already has active swap."
      return 0
    fi
    if [ -e "$swap_file" ] || [ -L "$swap_file" ]; then
      # Resume only a protected swap file created by this installer.
      if [ -L "$swap_file" ] || [ ! -f "$swap_file" ] ||
         [ "$(stat -c '%u:%a:%h' -- "$swap_file")" != "0:600:1" ] ||
         [ "$(blkid -p -s LABEL -o value "$swap_file")" != hobcrew-box ] ||
         [ "$(blkid -p -s TYPE -o value "$swap_file")" != swap ]; then
        printf '%s\n' "The path $swap_file is already in use." >&2
        return 1
      fi
    else
      available="$(df -Pm -- "$(dirname -- "$swap_file")" | awk 'NR == 2 { print $4 }')"
      if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < size_mib + reserve_mib )); then
        printf '%s\n' "The server needs 4 GiB of free disk space to add 2 GiB of swap." >&2
        return 1
      fi

      umask 077
      temporary="$(mktemp -- "${swap_file}.XXXXXX")" || return 1
      trap 'rm -f -- "$temporary"' EXIT
      if [ "$(findmnt -n -o FSTYPE --target "$temporary")" = btrfs ]; then
        chattr +C "$temporary" || return 1
      fi
      dd if=/dev/zero of="$temporary" bs=1M count="$size_mib" conv=fsync status=none &&
        mkswap -L hobcrew-box "$temporary" >/dev/null &&
        mv -T --no-clobber -- "$temporary" "$swap_file" &&
        [ ! -e "$temporary" ] || return 1
      created=1
    fi
    if ! swapon -- "$swap_file"; then
      if [ "$created" -eq 1 ]; then rm -f -- "$swap_file"; fi
      return 1
    fi
  fi
  # A leading newline also handles fstab files without a final newline.
  printf '\n%s none swap defaults 0 0\n' "$swap_file" >> "$fstab" || return 1
  printf '%s\n' "Swap is active and will start again when the server reboots."
)
