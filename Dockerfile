# OpenLDAP as Debian ships it, and nothing else: no startup scripts, no
# configuration generated from environment variables. slapd reads cn=config
# from /etc/ldap/slapd.d and keeps its data in /var/lib/ldap; whoever runs
# the container fills both. See README.md.
FROM docker.io/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# The package takes over a user "openldap" that already exists. Fixed ids,
# so that a volume keeps its owner whatever the package would have picked.
# The directory the package configures at install time is thrown away.
RUN groupadd --system --gid 911 openldap \
 && useradd --system --uid 911 --gid 911 --home-dir /var/lib/ldap --no-create-home --shell /usr/sbin/nologin openldap \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends slapd ldap-utils \
 && rm -rf /var/lib/apt/lists/* /etc/ldap/slapd.d /var/lib/ldap /run/slapd \
 && install -d -o openldap -g openldap -m 0750 /etc/ldap/slapd.d /var/lib/ldap /run/slapd

USER 911:911

# Unprivileged ports; publish them as 389 and 636.
EXPOSE 1389 1636

# In the foreground, with the statistics log on stderr.
ENTRYPOINT ["/usr/sbin/slapd"]
CMD ["-d", "stats", "-F", "/etc/ldap/slapd.d", "-h", "ldap://0.0.0.0:1389/ ldaps://0.0.0.0:1636/ ldapi://%2Frun%2Fslapd%2Fldapi"]
