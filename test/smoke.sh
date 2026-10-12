#!/usr/bin/env bash
# Starts the image the way the README describes (not root, read-only root
# filesystem, configuration from example/slapd.ldif) with a few entries and
# checks that it behaves: binds, searches, access rules, TLS.
# Usage: test/smoke.sh <image>
set -euo pipefail

image=${1:?usage: $0 <image>}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
name=openldap-smoke-$$
volume=$name-data
base=dc=example,dc=org

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "${work:?}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  docker logs "$name" 2>&1 | tail -20 >&2 || true
  exit 1
}

admin_pw=$(openssl rand -hex 12)
user_pw=$(openssl rand -hex 12)
admin_hash=$(docker run --rm --entrypoint slappasswd "$image" -s "$admin_pw")
user_hash=$(docker run --rm --entrypoint slappasswd "$image" -s "$user_pw")

mkdir "$work/config" "$work/tls"
cp "$root/example/slapd.ldif" "$work/config/"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost \
  -keyout "$work/tls/tls.key" -out "$work/tls/tls.crt" 2>/dev/null
chmod -R a+rX "$work"
chmod a+r "$work/tls/tls.key"

cat >"$work/data.ldif" <<EOF
dn: $base
objectClass: top
objectClass: dcObject
objectClass: organization
o: Example
dc: example

dn: cn=admin,$base
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: admin
userPassword: $admin_hash

dn: ou=people,$base
objectClass: organizationalUnit
ou: people

dn: uid=jdoe,ou=people,$base
objectClass: inetOrgPerson
objectClass: posixAccount
cn: Jane Doe
sn: Doe
uid: jdoe
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/jdoe
mail: jdoe@example.org
userPassword: $user_hash
EOF

docker volume create "$volume" >/dev/null
docker run --rm --user 0 -v "$volume:/var/lib/ldap" --entrypoint chown "$image" 911:911 /var/lib/ldap

# The open-files limit a container gets under containerd; the image has to
# cope with it (slapd-wrapper).
mounts=(--read-only
  --ulimit nofile=1048576:1048576
  --tmpfs /etc/ldap/slapd.d:uid=911,gid=911,mode=750
  --tmpfs /run/slapd:uid=911,gid=911
  -v "$volume:/var/lib/ldap"
  -v "$work/config:/config:ro"
  -v "$work/tls:/tls:ro"
  -v "$work/data.ldif:/data.ldif:ro")

# Configuration and data are loaded offline, then slapd starts on both.
docker run -d --name "$name" "${mounts[@]}" --entrypoint sh "$image" -c '
  slapadd -n0 -F /etc/ldap/slapd.d -l /config/slapd.ldif &&
  slapadd -n1 -F /etc/ldap/slapd.d -l /data.ldif &&
  exec slapd -d stats -F /etc/ldap/slapd.d \
    -h "ldap://0.0.0.0:1389/ ldaps://0.0.0.0:1636/ ldapi://%2Frun%2Fslapd%2Fldapi"' >/dev/null

search() { docker exec -e LDAPTLS_REQCERT=never "$name" ldapsearch -x -LLL "$@" 2>&1 || true; }

for _ in $(seq 1 30); do
  search -H ldap://localhost:1389 -s base -b "" namingContexts | grep -q namingContexts && break
  sleep 1
done

[[ $(docker exec "$name" id -u) == 911 ]] || fail "slapd does not run as uid 911"

rss=$(docker exec "$name" awk '/VmRSS/ {print $2}' /proc/1/status)
((rss < 102400)) || fail "slapd takes $((rss / 1024)) MB right after the start"

search -H ldap://localhost:1389 -s base -b "" namingContexts | grep -q "namingContexts: $base" ||
  fail "the root DSE is not readable anonymously"

[[ $(search -H ldap://localhost:1389 -b "$base" dn | grep -c '^dn:') == 0 ]] ||
  fail "an anonymous search returns entries"

[[ $(search -H ldap://localhost:1389 -D "cn=admin,$base" -w "$admin_pw" -b "$base" dn | grep -c '^dn:') == 4 ]] ||
  fail "the root DN does not see all four entries"

search -H ldap://localhost:1389 -D "cn=admin,$base" -w wrong -b "$base" dn | grep -q "Invalid credentials" ||
  fail "a wrong password is not rejected"

search -H ldap://localhost:1389 -D "uid=jdoe,ou=people,$base" -w "$user_pw" -b "$base" "(mail=jdoe@*)" uid |
  grep -q '^uid: jdoe' || fail "a user cannot bind and search"

[[ $(search -H ldap://localhost:1389 -D "uid=jdoe,ou=people,$base" -w "$user_pw" -b "cn=admin,$base" -s base userPassword |
  grep -c '^userPassword') == 0 ]] || fail "a user can read another entry's password hash"

search -H ldaps://localhost:1636 -s base -b "" namingContexts | grep -q namingContexts ||
  fail "LDAPS does not answer"

echo "smoke test passed: $(docker run --rm --entrypoint dpkg-query "$image" -W -f '${Package} ${Version}' slapd)"
