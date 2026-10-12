# OpenLDAP Docker

A container image of [OpenLDAP](https://www.openldap.org/) (`slapd`) that is the Debian package and nothing else.

Most OpenLDAP images wrap the server in a startup script that generates the configuration from environment variables. Those wrappers are the part that gets abandoned. This image has none: you give `slapd` its configuration as a file, the way its own documentation describes, and it runs.

The one thing the image does for you is cap the limit of open files at 16384. `slapd` sizes its tables by that limit, and with the 1048576 that containerd hands out it takes about 350 MB of memory at start instead of 20. `slapd` on the `PATH` is a [ten-line wrapper](slapd-wrapper) that does this and then starts `/usr/sbin/slapd` with the same arguments.

- Debian 13 (trixie) with the packages `slapd` and `ldap-utils`, rebuilt every week for security updates.
- Runs as user and group `911`, with a read-only root filesystem if you like.
- Listens on `1389` (LDAP) and `1636` (LDAPS).
- No environment variables, no generated configuration.

## Tags

`ghcr.io/freifunkmuc/openldap-docker`

| Tag | Meaning |
|---|---|
| `2.6.10` | the version of `slapd` in the image; moves with every weekly rebuild |
| `2.6.10-20261013` | the build of that day |
| `latest` | the newest build |

Pin a digest if you want to decide yourself when an update arrives.

## How to use

The container needs three things from you:

| Path | What | Lifetime |
|---|---|---|
| `/etc/ldap/slapd.d` | the configuration (`cn=config`), loaded from an LDIF file | can be rebuilt at every start |
| `/var/lib/ldap` | the data | a volume |
| `/run/slapd` | PID file and the `ldapi` socket | temporary |

All three must be writable by uid `911`.

### The configuration

[`example/slapd.ldif`](example/slapd.ldif) is a complete configuration for one directory, `dc=example,dc=org`: MDB backend, the usual schemas, TLS, and access rules that let nobody search anonymously. Copy it and change the suffix.

It contains no password. The root DN (`cn=admin,dc=example,dc=org`) has no `olcRootPW`; it binds with the `userPassword` of its own entry in the directory, which you create with the data.

Load the file into an empty configuration directory before `slapd` starts:

```sh
slapadd -n0 -F /etc/ldap/slapd.d -l /config/slapd.ldif
```

If you do that at every start, into a directory that does not survive the container, the running configuration is always what the file says.

### With Docker Compose

```yml
services:
  openldap:
    image: ghcr.io/freifunkmuc/openldap-docker:2.6.10
    restart: always
    read_only: true
    entrypoint: ["sh", "-c"]
    command:
      - >-
        slapadd -n0 -F /etc/ldap/slapd.d -l /config/slapd.ldif &&
        exec slapd -d stats -F /etc/ldap/slapd.d
        -h "ldap://0.0.0.0:1389/ ldaps://0.0.0.0:1636/ ldapi://%2Frun%2Fslapd%2Fldapi"
    ports:
      - "636:1636"
    tmpfs:
      - /etc/ldap/slapd.d:uid=911,gid=911,mode=750
      - /run/slapd:uid=911,gid=911
    volumes:
      - data:/var/lib/ldap
      - ./slapd.ldif:/config/slapd.ldif:ro
      - ./tls:/tls:ro

volumes:
  data:
```

A new named volume belongs to root. Hand it to the server once:

```sh
docker compose run --rm --user 0 --entrypoint chown openldap 911:911 /var/lib/ldap
```

### With Kubernetes

Use an init container with the same image for `slapadd -n0`, an `emptyDir` for `/etc/ldap/slapd.d` and `/run/slapd`, a PersistentVolumeClaim for `/var/lib/ldap` and `fsGroup: 911`. The main container then needs no command at all.

### The first entries

An empty directory has no root entry and nobody who could log in. Create both offline, while `slapd` is not running on that volume:

```sh
slappasswd                      # prints the hash for userPassword
slapadd -n1 -F /etc/ldap/slapd.d -l /data.ldif
```

```ldif
dn: dc=example,dc=org
objectClass: top
objectClass: dcObject
objectClass: organization
o: Example
dc: example

dn: cn=admin,dc=example,dc=org
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: admin
userPassword: {SSHA}...
```

Data from another OpenLDAP server moves the same way: `slapcat -n1` there, `slapadd -n1` here. That keeps password hashes, `entryUUID` and timestamps.

### TLS

Mount certificate and key where your configuration expects them (`/tls/tls.crt` and `/tls/tls.key` in the example), readable by uid `911`. `slapd` reads them at start only, so restart the container after a renewal.

### Backup

`slapcat -n1 -F /etc/ldap/slapd.d` inside the running container prints the whole directory as LDIF.

## Testing

```sh
docker build -t openldap:test .
test/smoke.sh openldap:test
```

The test starts the image as described above and checks binds, searches, the access rules of the example and LDAPS. The workflow runs it before every push to the registry.

## License

The files in this repository are under the [MIT license](LICENSE). The image contains OpenLDAP under the [OpenLDAP Public License](https://www.openldap.org/software/release/license.html) and other Debian packages under their own licenses.
