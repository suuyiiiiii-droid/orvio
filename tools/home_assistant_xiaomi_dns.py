"""Refresh the two Xiaomi endpoints inside this Home Assistant container."""

import concurrent.futures
import http.client
import ipaddress
import json
import socket
import ssl
import sys
from pathlib import Path
from urllib.parse import urlencode


ENDPOINTS = {"ha.api.io.mi.com": 443, "cn-ha.mqtt.io.mi.com": 8883}
HOSTS = Path("/etc/hosts")
BEGIN = "# BEGIN T1 XIAOMI ROUTES"
END = "# END T1 XIAOMI ROUTES"


def dns_addresses(host, context):
    # Home Assistant already uses Cloudflare for encrypted DNS fallback.
    connection = http.client.HTTPSConnection("1.1.1.1", timeout=8, context=context)
    try:
        path = "/dns-query?" + urlencode({"name": host, "type": "A"})
        connection.request("GET", path, headers={
            "Host": "cloudflare-dns.com", "Accept": "application/dns-json",
        })
        with connection.getresponse() as response:
            if response.status != 200:
                return []
            result = json.loads(response.read(8192))
        if result.get("Status") != 0:
            return []
        addresses = (ipaddress.ip_address(row["data"])
                     for row in result.get("Answer", []) if row["type"] == 1)
        return list(dict.fromkeys(str(ip) for ip in addresses if ip.version == 4 and ip.is_global))
    finally:
        connection.close()


def reachable(host, port, ip, context):
    try:
        with socket.create_connection((ip, port), timeout=9) as connection:
            with context.wrap_socket(connection, server_hostname=host) as tls:
                if port != 443:
                    return True
                tls.sendall(f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode("ascii"))
                return tls.recv(64).startswith(b"HTTP/")
    except OSError:
        return False


def select_address(host, port, current, context):
    if current and reachable(host, port, current, context):
        return current
    try:
        candidates = dns_addresses(host, context)
    except (OSError, ValueError, http.client.HTTPException):
        return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        probes = {pool.submit(reachable, host, port, ip, context): ip for ip in candidates}
        for probe in concurrent.futures.as_completed(probes):
            if probe.result():
                for pending in probes:
                    pending.cancel()
                return probes[probe]
    return None


def split_hosts(content):
    if BEGIN not in content and END not in content:
        return content, {}
    if content.count(BEGIN) != 1 or content.count(END) != 1:
        raise ValueError("Invalid T1 hosts section")
    before, _, rest = content.partition(BEGIN + "\n")
    section, separator, after = rest.partition(END + "\n")
    if not separator:
        raise ValueError("Invalid T1 hosts section")
    current = {}
    for line in section.splitlines():
        address, name = line.split()
        if name not in ENDPOINTS or not ipaddress.ip_address(address).is_global:
            raise ValueError("Unexpected entry in T1 hosts section")
        current[name] = address
    return before + after, current


def render_hosts(base, addresses):
    if not addresses:
        return base
    if base and not base.endswith("\n"):
        base += "\n"
    return base + BEGIN + "\n" + "".join(
        f"{address} {name}\n" for name, address in sorted(addresses.items())
    ) + END + "\n"


def main():
    original = HOSTS.read_text(encoding="utf-8")
    base, current = split_hosts(original)
    manual = {name for line in base.splitlines() for name in line.split("#", 1)[0].split()[1:]}
    if manual.intersection(ENDPOINTS):
        sys.exit("Existing Xiaomi hosts entries must be reviewed before installing T1 routes.")
    context = ssl.create_default_context()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(ENDPOINTS)) as pool:
        work = {name: pool.submit(select_address, name, port, current.get(name), context)
                for name, port in ENDPOINTS.items()}
        results = {name: future.result() for name, future in work.items()}
    addresses = {name: results[name] or current.get(name) for name in ENDPOINTS}
    updated = render_hosts(base, {name: ip for name, ip in addresses.items() if ip})
    if updated != original:
        # Docker mounts /etc/hosts, so the file must be updated in place.
        with HOSTS.open("r+", encoding="utf-8") as file:
            if file.read() != original:
                sys.exit("Hosts changed while checking Xiaomi routes. Will try again later.")
            file.seek(0)
            file.write(updated)
            file.truncate()
        print("T1_XIAOMI_ROUTES_UPDATED")
    for name, address in results.items():
        print(f"{name}: {'TLS verified' if address else 'no reachable address verified'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
