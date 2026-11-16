"""Remove the throwaway development certificates that automatic signing creates on each
cloud build, so they never pile up against Apple's per-account limit.
Only certificates Apple labels "Created via API" are touched."""
import json
import os
import time
import urllib.request

import jwt

key = open(os.environ["KEY_PATH"]).read()
now = int(time.time())
token = jwt.encode(
    {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]},
)
if isinstance(token, bytes):
    token = token.decode()
base = "https://api.appstoreconnect.apple.com/v1/certificates"


def call(url, method="GET"):
    request = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else {}


listing = call(base + "?filter%5BcertificateType%5D=DEVELOPMENT,IOS_DEVELOPMENT&limit=200")
removed = 0
for cert in listing.get("data", []):
    name = (cert.get("attributes") or {}).get("displayName") or ""
    if "Created via API" in name:
        call(base + "/" + cert["id"], method="DELETE")
        removed += 1
print("Temporary development certificates removed:", removed)
