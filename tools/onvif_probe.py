"""Read-only ONVIF probe: GetCapabilities, GetProfiles, PTZ GetNodes. Credentials come from .env.
Usage: set -a; . .env; set +a; python3 onvif_probe.py [port ...]  (default ports: 8899 5000)"""
import base64
import hashlib
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone

NS = ('xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
      'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema"')


def call(url, body, user, pw):
    nonce = os.urandom(16)
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + pw.encode()).digest()).decode()
    sec = ('<Security xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
           f'<UsernameToken><Username>{user}</Username>'
           '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
           f'{digest}</Password><Nonce>{base64.b64encode(nonce).decode()}</Nonce>'
           f'<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{created}</Created>'
           '</UsernameToken></Security>')
    xml = f'<?xml version="1.0"?><s:Envelope {NS}><s:Header>{sec}</s:Header><s:Body>{body}</s:Body></s:Envelope>'
    req = urllib.request.Request(url, xml.encode(), {"Content-Type": "application/soap+xml"})
    try:
        return urllib.request.urlopen(req, timeout=5).read().decode()
    except urllib.error.HTTPError as e:
        return e.read().decode()
    except Exception as e:  # probe keeps going; the error text is the finding
        return f"<Text>{type(e).__name__}: {e}</Text>"


def tags(xml, name):
    return re.findall(rf"<[\w]*:?{name}[^>]*>([^<]*)<", xml)


ports = sys.argv[1:] or ["8899", "5000"]
for n in (1, 2, 3, 4):
    host = os.environ[f"CAM{n}_HOST"].split(":")[0]
    user, pw = os.environ[f"CAM{n}_USER"], os.environ[f"CAM{n}_PASS"]
    for port in ports:
        base = f"http://{host}:{port}/onvif/device_service"
        print(f"== CAM{n} {host}:{port}")
        try:
            caps = call(base, "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>", user, pw)
        except Exception as e:
            print("  no answer:", e)
            continue
        fault = tags(caps, "Text")
        if fault:
            print("  fault:", fault[0])
            continue
        # The camera advertises its own address/port (not always the one we reached it on): reuse host:port.
        xaddrs = [re.sub(r"//[^/]+", f"//{host}:{port}", x) for x in tags(caps, "XAddr")]
        print("  services:", [x.rsplit("/", 1)[-1] for x in xaddrs])
        media = next((x for x in xaddrs if "media" in x.lower()), None)
        ptz = next((x for x in xaddrs if "ptz" in x.lower()), None)
        if media:
            prof = call(media, "<trt:GetProfiles/>", user, pw)
            print("  profiles:", re.findall(r'Profiles[^>]*token="([^"]+)"', prof))
        if ptz:
            nodes = call(ptz, "<tptz:GetNodes/>", user, pw)
            print("  ptz nodes:", re.findall(r'PTZNode[^>]*token="([^"]+)"', nodes) or tags(nodes, "Text"))
        else:
            print("  no PTZ service advertised")
