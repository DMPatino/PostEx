#!/usr/bin/env bash
# ===========================================================================
# grant_sudo.sh  —  Add a user to the admin/sudoers group across the boxes,
#                   over SSH as csra_admin.
#
# Adds the user to whichever admin group exists on each host (Debian: sudo,
# RHEL: wheel). Idempotent. DRY RUN first (--check), then confirm to apply.
#
#   ./grant_sudo.sh                 # defaults to eunwoo.jeong, saved IPs
#   ./grant_sudo.sh someone.else    # grant a different user
# ===========================================================================
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADMIN="csra_admin"
SUDO_USER_TO_ADD="${1:-eunwoo.jeong}"

command -v ansible-playbook >/dev/null || { echo "ERROR: ansible-playbook not found."; exit 1; }

echo "=== Grant sudo to '${SUDO_USER_TO_ADD}' (SSH as ${ADMIN}) ==="

# Saved default ranges — press Enter to use these (same 12 hosts).
DEFAULT_RANGES="172.24.10.150 172.24.10.180 172.24.19.66 172.24.19.44 172.24.19.68 172.24.18.99 172.24.18.135 172.24.21.12 172.24.21.71 172.24.21.42 172.24.22.75 172.24.22.19"
read -rp "IP ranges [Enter = saved default]: " RANGES
RANGES="${RANGES:-$DEFAULT_RANGES}"

HOSTS="$(python3 - "$RANGES" <<'PY'
import sys, re, ipaddress
out, seen = [], set()
for tok in re.split(r'[,\s]+', sys.argv[1].strip()):
    if not tok: continue
    try:
        if '/' in tok:
            for h in ipaddress.ip_network(tok, strict=False).hosts(): out.append(str(h))
        elif '-' in tok:
            base, rng = tok.rsplit('.', 1); lo, hi = rng.split('-')
            for i in range(int(lo), int(hi)+1): out.append(f"{base}.{i}")
        else:
            out.append(str(ipaddress.ip_address(tok)))
    except Exception as e: sys.stderr.write(f"skip {tok}: {e}\n")
for ip in out:
    if ip not in seen: seen.add(ip); print(ip)
PY
)"
[[ -n "$HOSTS" ]] || { echo "ERROR: no valid IPs."; exit 1; }
COUNT="$(printf '%s\n' "$HOSTS" | grep -c .)"
echo "Targeting ${COUNT} host(s)."

read -rsp "SSH password for ${ADMIN} (blank = key auth): " SSHPW; echo
read -rsp "sudo password for ${ADMIN} (blank = NOPASSWD):  " SUDOPW; echo
if [[ -n "$SSHPW" ]]; then
  command -v sshpass >/dev/null || { echo "ERROR: SSH password given but 'sshpass' not installed."; exit 1; }
fi

INV="$(mktemp)"; VARS="$(mktemp)"; PB="$(mktemp --suffix=.yml)"; chmod 600 "$INV" "$VARS"
cleanup(){ shred -u "$VARS" 2>/dev/null || rm -f "$VARS"; rm -f "$INV" "$PB"; }
trap cleanup EXIT

{ echo "[targets]"; printf '%s\n' "$HOSTS"; echo
  echo "[targets:vars]"; echo "ansible_user=${ADMIN}"; echo "ansible_connection=ssh"; } > "$INV"
{ [[ -n "$SSHPW"  ]] && echo "ansible_ssh_pass: \"${SSHPW}\""
  [[ -n "$SUDOPW" ]] && echo "ansible_become_pass: \"${SUDOPW}\""; } > "$VARS"

cat > "$PB" <<'YAML'
- name: Add user to the admin (sudoers) group
  hosts: targets
  become: true
  gather_facts: false
  vars:
    sudo_user: "{{ target_user }}"
  tasks:
    - name: Read group + passwd databases
      ansible.builtin.getent: { database: "{{ item }}" }
      loop: [group, passwd]

    - name: Pick the admin group(s) present on this host (sudo / wheel)
      ansible.builtin.set_fact:
        admin_groups: "{{ ['sudo','wheel'] | select('in', ansible_facts.getent_group.keys() | list) | list }}"

    - name: Report what will happen
      ansible.builtin.debug:
        msg: >-
          {{ inventory_hostname }}:
          user {{ 'PRESENT' if sudo_user in ansible_facts.getent_passwd.keys() | list else 'MISSING' }},
          admin group(s) {{ admin_groups | default([]) }}

    - name: Add {{ sudo_user }} to admin group(s)
      ansible.builtin.user:
        name: "{{ sudo_user }}"
        groups: "{{ admin_groups }}"
        append: true
      when:
        - admin_groups | length > 0
        - sudo_user in ansible_facts.getent_passwd.keys() | list

    - name: Confirm resulting group membership
      ansible.builtin.command: "id {{ sudo_user }}"
      register: idout
      changed_when: false
      failed_when: false

    - name: Show id output
      ansible.builtin.debug:
        msg: "{{ idout.stdout | default('user not found') }}"
YAML

export ANSIBLE_HOST_KEY_CHECKING=False
PBARGS=(-i "$INV" -e @"$VARS" -e "target_user=${SUDO_USER_TO_ADD}" "$PB")

echo
echo ">>> DRY RUN (--check): nothing changed"
ansible-playbook "${PBARGS[@]}" --check

echo
read -rp "Type YES to add '${SUDO_USER_TO_ADD}' to sudoers on ${COUNT} host(s): " OK
[[ "$OK" == "YES" ]] || { echo "Aborted. Nothing changed."; exit 0; }

echo
echo ">>> APPLYING"
ansible-playbook "${PBARGS[@]}"

echo
echo "=== Done. Check the 'id' output above — look for the admin group in each host's line. ==="
