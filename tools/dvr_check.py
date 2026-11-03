"""Read-only check of Xiongmai cameras via python-dvr (port 34567). Credentials come from .env."""
import json
import os
import sys

from dvrip import DVRIPCam

# Cameras with port 34567 open; indexes follow .env (CAM1=.115, CAM3=.117, CAM4=.118).
for n in (1, 3, 4):
    host = os.environ[f"CAM{n}_HOST"].split(":")[0]
    cam = DVRIPCam(host, user=os.environ[f"CAM{n}_USER"], password=os.environ[f"CAM{n}_PASS"])
    print(f"== CAM{n} {host}")
    try:
        if not cam.login():
            print("login failed")
            continue
        print("system:", json.dumps(cam.get_system_info()))
        print("encode:", json.dumps(cam.get_info("Simplify.Encode")))
    except Exception as e:
        print("error:", e, file=sys.stderr)
    finally:
        cam.close()
