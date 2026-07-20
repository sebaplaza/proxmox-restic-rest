# proxmox-restic-rest

One-command deploy of a hardened [restic REST server](https://github.com/restic/rest-server)
inside a minimal Alpine LXC on Proxmox VE.

It gives you a network backup target that:

- runs in a tiny unprivileged Alpine container (256 MB RAM, 2 GB rootfs),
- stores the repository on a **host directory you choose** (bind-mounted — put it on your big array),
- serves restic over HTTP with **htpasswd** auth and **`--private-repos`** isolation,
- runs **append-only** by default: clients can add snapshots but cannot delete or
  overwrite them, so a stolen or compromised laptop can't wipe your backup history.

Perfect as the "landing zone" for pushing backups from laptops/desktops with
[restic](https://restic.net/) or [Backrest](https://github.com/garethgeorge/backrest).

## Install

Run on the Proxmox VE host, as root:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sebaplaza/proxmox-restic-rest/main/restic-rest.sh)"
```

At the end it prints the repository URL and how to initialise it from a client.

## Configuration

Everything is overridable via environment variables:

| Variable         | Default                          | Description                              |
|------------------|----------------------------------|------------------------------------------|
| `CTID`           | next free id                     | Container ID                             |
| `HOSTNAME`       | `restic-rest`                    | Container hostname                       |
| `MEMORY`         | `256`                            | RAM in MB                                |
| `ROOTFS_STORAGE` | `local-lvm`                      | Storage backing the rootfs              |
| `ROOTFS_SIZE`    | `2`                              | Rootfs size in GB                        |
| `BRIDGE`         | `vmbr0`                          | Network bridge                           |
| `REPO_PATH`      | `/mnt/mergerfs/backups/restic`   | **Host** dir holding the repository      |
| `MOUNT_POINT`    | `/mnt/repo`                      | Path inside the container                |
| `REST_PORT`      | `8000`                           | Port rest-server listens on              |
| `REST_USER`      | `backup`                         | htpasswd username                        |
| `REST_PASS`      | generated                        | htpasswd password                        |
| `REST_VERSION`   | `0.14.0`                         | rest-server release to install           |
| `APPEND_ONLY`    | `1`                              | `1` = append-only (recommended)          |

Example — a repo on a ZFS dataset, custom user, fixed id:

```sh
CTID=120 REPO_PATH=/mnt/tank/backups REST_USER=laptop \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/sebaplaza/proxmox-restic-rest/main/restic-rest.sh)"
```

## Using it from a client

```sh
# With --private-repos the path MUST start with the username (here: "backup").
export RESTIC_REPOSITORY='rest:http://backup:PASSWORD@<lxc-ip>:8000/backup/'
export RESTIC_PASSWORD='your-encryption-password'   # encrypts the repo; keep it safe
restic init
restic backup ~/Documents
```

In [Backrest](https://github.com/garethgeorge/backrest), add a repo with the same
`rest:http://…/<username>/` URI and encryption password.

## Pruning with append-only

Because clients can't delete, retention (`restic forget --prune`) must run
**server-side**. Add a cron job inside the container that operates on the repo
directly on disk (the append-only restriction only applies to the HTTP layer):

```sh
# inside the container, e.g. /etc/periodic/daily/prune
restic -r /mnt/repo/<username> forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

## Notes

- HTTP only by default. On an untrusted network, put it behind TLS
  (`rest-server --tls --tls-cert … --tls-key …`) or a reverse proxy / tunnel.
- The repository storage lives on `REPO_PATH`; the container rootfs stays tiny.
- Unprivileged container: the bind-mount target on the host is chowned to
  `100000:100000` so the container root can write to it.

## License

MIT
