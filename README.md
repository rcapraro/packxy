

# Forti SOCKS Proxy

This project starts an `openfortivpn` connection and exposes a local SOCKS5 proxy for internal access such as `packsolutions.local`.

It is intended to be used with:

* Docker Compose
* a Linux host or Linux VM
* a **local PAC file on macOS** so only selected domains use the SOCKS5 proxy

## What this project does

* connects to your Forti VPN with `openfortivpn`
* exposes a SOCKS5 proxy on port `1080`
* lets your Mac or browser send only `packsolutions.local` traffic through the VPN proxy
* keeps all other traffic direct by using a local PAC file

## Requirements

* Docker
* Docker Compose
* a Linux host or Linux VM
* access to `/dev/ppp`
* Forti VPN credentials
* if required, a valid OTP / 2FA token

## Before you start

Make sure these files exist in the project directory:

* `docker-compose.yml`
* `Dockerfile`
* `entrypoint.sh`
* `danted.conf`
* `.env`

## Configure `.env`

Edit `.env` and set your VPN values:

```env
FORTI_HOST=vpn.example.com
FORTI_PORT=443
FORTI_USER=myuser
FORTI_PASS=mypassword
FORTI_TRUSTED_CERT=abcdef1234567890abcdef1234567890abcdef12
FORTI_REALM=
FORTI_OTP=
FORTI_NO_FTM_PUSH=
FORTI_OTP_PROMPT=
```

## Important note about OTP

Do **not** usually store a real OTP permanently in `.env`.

OTP codes expire quickly, so the normal workflow is:

* keep `FORTI_OTP=` empty in `.env`
* provide a fresh token only when starting the container

## Build the container

### Bash

```bash
docker compose build --no-cache
```

### Zsh

```zsh
docker compose build --no-cache
```

### Fish

```fish
docker compose build --no-cache
```

## Start the container

### Start without OTP

Use this only if your VPN does not require a token.

#### Bash

```bash
docker compose up -d
```

#### Zsh

```zsh
docker compose up -d
```

#### Fish

```fish
docker compose up -d
```

### Start with OTP

Use this if your VPN requires a token.

#### Bash

```bash
FORTI_OTP=123456 docker compose up -d
```

Or:

```bash
export FORTI_OTP=123456
docker compose up -d
unset FORTI_OTP
```

#### Zsh

```zsh
FORTI_OTP=123456 docker compose up -d
```

Or:

```zsh
export FORTI_OTP=123456
docker compose up -d
unset FORTI_OTP
```

#### Fish

```fish
env FORTI_OTP=123456 docker compose up -d
```

Or:

```fish
set -x FORTI_OTP 123456
docker compose up -d
set -e FORTI_OTP
```

## Rebuild and start again

If you changed the Dockerfile, entrypoint, or config:

### Bash

```bash
docker compose up -d --build
```

### Zsh

```zsh
docker compose up -d --build
```

### Fish

```fish
docker compose up -d --build
```

## Stop the container

### Bash

```bash
docker compose stop
```

### Zsh

```zsh
docker compose stop
```

### Fish

```fish
docker compose stop
```

## Stop and remove the container

### Bash

```bash
docker compose down
```

### Zsh

```zsh
docker compose down
```

### Fish

```fish
docker compose down
```

## Restart the container

### Bash

```bash
docker compose restart
```

### Zsh

```zsh
docker compose restart
```

### Fish

```fish
docker compose restart
```

## View logs

### Follow logs live

#### Bash

```bash
docker compose logs -f
```

#### Zsh

```zsh
docker compose logs -f
```

#### Fish

```fish
docker compose logs -f
```

### Show logs once

#### Bash

```bash
docker compose logs
```

#### Zsh

```zsh
docker compose logs
```

#### Fish

```fish
docker compose logs
```

## Check container status

### Bash

```bash
docker compose ps
```

### Zsh

```zsh
docker compose ps
```

### Fish

```fish
docker compose ps
```

## Configure OTP behavior

### Use OTP token

If your VPN requires a one-time token, start the stack with `FORTI_OTP`.

#### Bash

```bash
FORTI_OTP=123456 docker compose up -d
```

#### Zsh

```zsh
FORTI_OTP=123456 docker compose up -d
```

#### Fish

```fish
env FORTI_OTP=123456 docker compose up -d
```

### Force code-based OTP instead of FortiToken push

If your FortiGate offers push approval and you want OTP code mode instead, set:

```env
FORTI_NO_FTM_PUSH=1
```

### Help OTP prompt detection

If the VPN challenge text is not detected correctly, set:

```env
FORTI_OTP_PROMPT=Enter
```

## What the PAC file does

The PAC file tells macOS or your browser:

* when to use the SOCKS proxy
* when to connect directly

In this setup, the goal is:

* `*.packsolutions.local` goes through the SOCKS5 proxy
* all other traffic goes directly to the internet

Without a PAC file, if you set a SOCKS proxy manually, many apps will try to send **all** traffic through that proxy.

## Create a local PAC file on macOS

Choose a folder, for example:

```text
/Users/yourname/Proxy
```

### Create the folder

#### Bash

```bash
mkdir -p ~/Proxy
```

#### Zsh

```zsh
mkdir -p ~/Proxy
```

#### Fish

```fish
mkdir -p ~/Proxy
```

### Create the file

You can use any editor. For example with `nano`:

#### Bash

```bash
nano ~/Proxy/packsolutions.pac
```

#### Zsh

```zsh
nano ~/Proxy/packsolutions.pac
```

#### Fish

```fish
nano ~/Proxy/packsolutions.pac
```

If you prefer TextEdit:

#### Bash

```bash
open -e ~/Proxy/packsolutions.pac
```

#### Zsh

```zsh
open -e ~/Proxy/packsolutions.pac
```

#### Fish

```fish
open -e ~/Proxy/packsolutions.pac
```

## PAC file content

Use this if your SOCKS proxy is reachable at `192.168.1.50:1080`:

```javascript
function FindProxyForURL(url, host) {
    if (
        dnsDomainIs(host, "packsolutions.local") ||
        shExpMatch(host, "*.packsolutions.local")
    ) {
        return "SOCKS5 192.168.1.50:1080";
    }
    return "DIRECT";
}
```

Replace:

* `192.168.1.50` with your Linux host or VM IP
* `1080` if your SOCKS proxy listens on another port
* `packsolutions.local` if you want another internal domain

## PAC file examples

### Proxy on a Linux VM

If your SOCKS proxy runs in a VM at `192.168.1.50`, use:

```javascript
function FindProxyForURL(url, host) {
    if (
        dnsDomainIs(host, "packsolutions.local") ||
        shExpMatch(host, "*.packsolutions.local")
    ) {
        return "SOCKS5 192.168.1.50:1080";
    }
    return "DIRECT";
}
```

### Proxy on the same machine as the browser

If the browser and SOCKS proxy run on the same machine, use:

```javascript
function FindProxyForURL(url, host) {
    if (
        dnsDomainIs(host, "packsolutions.local") ||
        shExpMatch(host, "*.packsolutions.local")
    ) {
        return "SOCKS5 127.0.0.1:1080";
    }
    return "DIRECT";
}
```

## Configure macOS to use the local PAC file

Go to:

* System Settings
* Network
* select your active network
* Details
* Proxies
* enable **Automatic Proxy Configuration**

Then enter the local file URL:

```text
file:///Users/yourname/Proxy/packsolutions.pac
```

Important:

* use `file:///...`, not `~/...`
* the path must be absolute
* if you move the file later, update the URL in macOS settings

## Check the local PAC file

### Bash

```bash
cat ~/Proxy/packsolutions.pac
```

### Zsh

```zsh
cat ~/Proxy/packsolutions.pac
```

### Fish

```fish
cat ~/Proxy/packsolutions.pac
```

## Test the SOCKS proxy directly

Use `curl` with remote DNS through SOCKS:

### Bash

```bash
curl --socks5-hostname 127.0.0.1:1080 https://app.packsolutions.local
```

### Zsh

```zsh
curl --socks5-hostname 127.0.0.1:1080 https://app.packsolutions.local
```

### Fish

```fish
curl --socks5-hostname 127.0.0.1:1080 https://app.packsolutions.local
```

If the proxy is on a VM, replace `127.0.0.1` with the VM IP.

`--socks5-hostname` is important because it makes the hostname resolve through the SOCKS proxy side instead of locally.

## Common commands

| Action | Command |
|---|---|
| Build | `docker compose build --no-cache` |
| Start | `docker compose up -d` |
| Start with rebuild | `docker compose up -d --build` |
| Stop | `docker compose stop` |
| Remove | `docker compose down` |
| Restart | `docker compose restart` |
| Show logs | `docker compose logs` |
| Follow logs | `docker compose logs -f` |
| Status | `docker compose ps` |

## Troubleshooting

### `openfortivpn` does not connect

Check:

* `FORTI_HOST`
* `FORTI_USER`
* `FORTI_PASS`
* `FORTI_TRUSTED_CERT`
* `FORTI_REALM`
* OTP validity

Then inspect logs:

```bash
docker compose logs -f
```

### `VPN did not create ppp0`

Usually this means one of these:

* `/dev/ppp` is not available
* the container is not running on a real Linux host or Linux VM
* VPN authentication failed
* OTP expired

### OTP fails repeatedly

Try:

* using a fresh token
* setting `FORTI_NO_FTM_PUSH=1`
* setting `FORTI_OTP_PROMPT=Enter`
* stopping and starting again instead of restarting an already running container

### PAC file does not work

Check:

* the local PAC file path is correct
* macOS proxy settings are applied to the active interface
* the IP in the PAC file points to the SOCKS proxy host
* your browser is using system proxy settings

### PAC file is loaded but traffic still does not route

Check:

* the domain in the PAC file matches exactly
* you used `dnsDomainIs(host, "packsolutions.local")` and `*.packsolutions.local`
* the SOCKS proxy is reachable on the configured IP and port
* the app you are testing actually uses system proxy settings

## Recommended workflow

1. Edit `.env`
2. Build the image
3. Start with a fresh OTP if needed
4. Check logs
5. Create the local PAC file on macOS
6. Configure macOS to use the PAC file
7. Test access to `packsolutions.local`

## Example workflows

### Bash

```bash
docker compose build --no-cache
FORTI_OTP=123456 docker compose up -d
docker compose logs -f
```

### Zsh

```zsh
docker compose build --no-cache
FORTI_OTP=123456 docker compose up -d
docker compose logs -f
```

### Fish

```fish
docker compose build --no-cache
env FORTI_OTP=123456 docker compose up -d
docker compose logs -f
```

## Security notes

* do not keep real OTP codes in `.env`
* be careful storing VPN passwords in plain text
* do not expose the SOCKS proxy to untrusted networks
* if possible, bind the proxy only on trusted interfaces

## References

* `openfortivpn`: <https://github.com/adrienverge/openfortivpn>
* `openfortivpn` man page: <https://manpages.ubuntu.com/manpages/noble/man1/openfortivpn.1.html>
* Docker: <https://docs.docker.com/>