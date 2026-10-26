# OpenLDAP as Debian ships it: no configuration generated from environment
# variables, no startup logic beyond one limit (slapd-wrapper). slapd reads cn=config
# from /etc/ldap/slapd.d and keeps its data in /var/lib/ldap; whoever runs
# the container fills both. See README.md.
FROM docker.io/library/debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

# The package takes over a user "openldap" that already exists. Fixed ids,
# so that a volume keeps its owner whatever the package would have picked.
# The directory the package configures at install time is thrown away.
RUN groupadd --system --gid 911 openldap \
 && useradd --system --uid 911 --gid 911 --home-dir /var/lib/ldap --no-create-home --shell /usr/sbin/nologin openldap \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends slapd ldap-utils \
 && rm -rf /var/lib/apt/lists/* /etc/ldap/slapd.d /var/lib/ldap /run/slapd \
 && install -d -o openldap -g openldap -m 0750 /etc/ldap/slapd.d /var/lib/ldap /run/slapd

# "slapd" on the PATH is this wrapper, which caps the limit of open files
# and then starts the real one with the same arguments. See the file.
COPY slapd-wrapper /usr/local/bin/slapd

USER 911:911

# Unprivileged ports; publish them as 389 and 636.
EXPOSE 1389 1636

# In the foreground, with the statistics log on stderr.
ENTRYPOINT ["/usr/local/bin/slapd"]
CMD ["-d", "stats", "-F", "/etc/ldap/slapd.d", "-h", "ldap://0.0.0.0:1389/ ldaps://0.0.0.0:1636/ ldapi://%2Frun%2Fslapd%2Fldapi"]
