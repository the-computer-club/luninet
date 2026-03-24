# Windows Setup

This guide covers joining the asluni mesh network on Windows, including WireGuard, DNS resolution, and certificate trust for `.luni` services.

---

## Contents

1. [Install WireGuard](#1-install-wireguard)
2. [Configure the Tunnel](#2-configure-the-tunnel)
3. [Test the VPN](#3-test-the-vpn)
4. [Install DNSCrypt-Proxy](#4-install-dnscrypt-proxy)
5. [Configure DNS Forwarding](#5-configure-dns-forwarding)
6. [Set DNS to Use the Proxy](#6-set-dns-to-use-the-proxy)
7. [Trust the LuniNet Certificates](#7-trust-the-luninet-certificates)
8. [Test the Full Stack](#8-test-the-full-stack)

---

## 1. Install WireGuard

Download and run the official Windows installer:

**[wireguard-amd64-0.5.3.msi](https://download.wireguard.com/windows-client/wireguard-amd64-0.5.3.msi)**

Run through the installer with default options. WireGuard will open automatically when done.

---

## 2. Configure the Tunnel

1. In the WireGuard application, click **Add Tunnel → Add empty tunnel**
2. Name it `asluni`
3. You will see a pre-generated key pair — **copy your public key** and keep it for [joining the network](./docs/joining.md)
4. In the text editor, paste the contents of the latest peer list:

   **[wg-asluni.conf](https://github.com/the-computer-club/automous-zones/releases/download/latest/wg-asluni.conf)**

5. Prepend your `[Interface]` block above the peer list:

```ini
[Interface]
PrivateKey = <your private key shown in the dialog>
Address = 172.29.80.X/24   # your assigned IP from peers.nix
```

6. Click **Save**, then click **Activate**

---

## 3. Test the VPN

Open a command prompt (`cmd.exe` or PowerShell) and ping the DNS server:

```
ping 172.29.80.2
```

You should get replies. If not, check that the tunnel is active in the WireGuard UI and that your public key has been [added to the peer list](./docs/joining.md).

---

## 4. Install DNSCrypt-Proxy

DNSCrypt-Proxy handles forwarding `.luni` DNS queries to the VPN's nameserver, while leaving all other DNS queries unaffected.

1. Download the latest Windows 64-bit release:

   **[dnscrypt-proxy-win64-2.1.12.zip](https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.12/dnscrypt-proxy-win64-2.1.12.zip)**

2. Extract the archive somewhere permanent (e.g. `C:\dnscrypt-proxy\`)

3. Open PowerShell **as Administrator** and navigate to that folder:

```powershell
cd C:\dnscrypt-proxy
```

---

## 5. Configure DNS Forwarding

### 5a. Enable the forwarding rules file

Open `example-dnscrypt-proxy.toml` in a text editor. Find the `[forwarding_rules]` section and uncomment the `forwarding_rules` line:

```toml
forwarding_rules = 'forwarding-rules.txt'
```

Save the file and rename it to `dnscrypt-proxy.toml`.

### 5b. Create the forwarding rules

Rename `example-forwarding-rules.txt` to `forwarding-rules.txt`, then add the following two lines:

```
luni      172.29.80.2:5334
luni.b32  172.29.80.2:5333
```

### 5c. Install and start the service

From your Administrator PowerShell session in the dnscrypt-proxy folder:

```powershell
.\install-service.bat
.\dnscrypt-proxy.exe -service start
```

---

## 6. Set DNS to Use the Proxy

These commands configure your network adapters to use the local DNSCrypt-Proxy instance for DNS. Run both in **Administrator PowerShell**.

First, clear any existing DNS server assignments:

```powershell
wmic nicconfig where (IPEnabled=TRUE) call SetDNSServerSearchOrder ()
```

Then set the primary DNS to the local proxy:

```powershell
wmic nicconfig where (IPEnabled=TRUE) call SetDNSServerSearchOrder ("127.0.0.1")
```

Both commands should return `ReturnValue = 0` (success).

Verify DNS is working:

```
nslookup google.com
nslookup unallocatedspace.luni
```

Both should resolve. If `google.com` works but `unallocatedspace.luni` doesn't, the VPN tunnel may be down or your forwarding rules may have a typo.

---

## 7. Trust the LuniNet Certificates

Some `.luni` services use TLS with certificates issued by the LuniNet internal CA. You need to import the root certificate so your browser and system tools trust them.

### 7a. Save the certificates

Create the following files anywhere on your machine (e.g. your Downloads folder):

**`Root_CA.crt`**
```
-----BEGIN CERTIFICATE-----
MIIBfDCCASGgAwIBAgIQWqMOZzNfWUND5wu1M/arNjAKBggqhkjOPQQDAjAcMRow
GAYDVQQDExFMdW5pTmV0IFJvb3QgQ2VydDAeFw0yNTAzMjgwMzI1MDhaFw0zNTAz
MjYwMzI1MDhaMBwxGjAYBgNVBAMTEUx1bmlOZXQgUm9vdCBDZXJ0MFkwEwYHKoZI
zj0CAQYIKoZIzj0DAQcDQgAEhINKEPodjC8yHP7ezDFloGdnNGB+g9QntuUSlTQm
zP+p+zuPJJG6Gn+EiuU+09GQ6fPyYe8Vwr6SJOQd5YpA06NFMEMwDgYDVR0PAQH/
BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQEwHQYDVR0OBBYEFCN+JPhovFdnm8Zu
YwAYcPR28PVRMAoGCCqGSM49BAMCA0kAMEYCIQDMxtxApt363genVVthPKHNcfa2
32tLmdJiYsrr6aRdCwIhAKspcXS8VbEhXgSAHW79ElagYTPR+kraJ3eWJGzWa11C
-----END CERTIFICATE-----
```

**`allocatedspace_ca.crt`**
```
-----BEGIN CERTIFICATE-----
MIIBqzCCAVGgAwIBAgIQQ0GM0vSy6gVrpeLwjXp/PjAKBggqhkjOPQQDAjAcMRow
GAYDVQQDExFMdW5pTmV0IFJvb3QgQ2VydDAeFw0yNTAzMjgwMzMxMDRaFw0zNTAz
MjYwMzMxMDRaMCsxKTAnBgNVBAMTIEx1bmlOZXQgQ0EgdW5hbGxvY2F0ZWRzcGFj
ZS5sdW5pMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAENpsRx14ka0fieNqYsnAb
Z13geXRXvR5n9YJ1m8AbbiT4uWVF3N6OVDrrHcV9ERLu7VY8lI8ojSjAWWuAdakp
faNmMGQwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
BBYEFAs68DLCS663P33Xst4IavptFSN7MB8GA1UdIwQYMBaAFCN+JPhovFdnm8Zu
YwAYcPR28PVRMAoGCCqGSM49BAMCA0gAMEUCIQDpwXDQL2Fzjrln1ginaeTqq7dF
QzREttzO8ulAkNoRiwIgCaflXonMtBg2XLRqOKo28XHbKcwHsrzKEPCapDNGmk4=
-----END CERTIFICATE-----
```

### 7b. Import into the Windows certificate store

You need to import these into the **Local Machine** store (not the current user store), so they are trusted system-wide.

1. Press `Win + R`, type `mmc.exe`, and press Enter
2. Go to **File → Add/Remove Snap-in**
3. Select **Certificates** and click **Add**
4. When prompted, select **Computer account**, then **Local computer**, then click **Finish**
5. Click **OK** to close the snap-in dialog
6. In the left panel, expand **Certificates (Local Computer) → Trusted Root Certification Authorities → Certificates**
7. Right-click **Certificates** and choose **All Tasks → Import**
8. Follow the wizard, selecting `Root_CA.crt` when prompted for a file
9. Make sure the store is set to **Trusted Root Certification Authorities**, then complete the wizard
10. Repeat steps 7–9 for `allocatedspace_ca.crt`, importing it into the same store

> If your browser (e.g. Firefox) maintains its own certificate store, you may also need to import these there separately via the browser's certificate settings.

---

## 8. Test the Full Stack

With the tunnel active and DNS configured, you should now be able to reach `.luni` services by name over HTTPS:

```
curl https://unallocatedspace.luni
```

If you get a valid response, everything is working. If you get a certificate error, double-check that both certificates were imported into **Local Machine → Trusted Root Certification Authorities**, not the current user store.

---

## Troubleshooting

**`ping 172.29.80.2` times out**
The tunnel may not be active. Open WireGuard and check that the `asluni` tunnel shows as connected. Also verify that your public key was added to `peers.nix` and the PR was merged.

**`nslookup unallocatedspace.luni` fails but `nslookup google.com` works**
DNSCrypt-Proxy is running but forwarding isn't configured correctly. Check that `forwarding-rules.txt` exists in the same folder as the proxy and that `dnscrypt-proxy.toml` has `forwarding_rules = 'forwarding-rules.txt'` uncommented.

**`curl https://unallocatedspace.luni` returns a certificate error**
The root certificate wasn't imported correctly. Confirm it landed in **Local Machine → Trusted Root Certification Authorities** and not under the current user store. Restart your terminal after importing.

**DNS reverts after a reboot**
If your DNS settings reset, check whether another program (e.g. your network adapter's DHCP settings or a VPN client) is overwriting them. You may need to set the DNS server statically per-adapter in **Network Connections → Adapter Properties → IPv4 Settings**.
