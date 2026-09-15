#!/usr/bin/env python3
"""Fake Sony a6400 for developing CinemaHUD without hardware.

Speaks enough of the Sony Camera Remote API to exercise the app:
  * SSDP responder (M-SEARCH for ScalarWebAPI)
  * GET  /dd.xml            device description
  * POST /sony/camera       JSON-RPC (getEvent long polling, set*, actTakePicture, startMovieRec, ...)
  * GET  /liveview          endless Sony-framed MJPEG stream (synthetic scene rendered with Pillow)

Usage: python3 tools/camerasim.py [--port 8080] [--fps 24]
"""
import argparse, io, json, math, socket, struct, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from PIL import Image, ImageDraw, ImageFont

SHUTTERS = ["30\"","15\"","8\"","4\"","2\"","1\"","1/2","1/4","1/8","1/15","1/30","1/50","1/60","1/100","1/125","1/250","1/500","1/1000","1/2000","1/4000"]
FNUMBERS = ["1.8","2.0","2.2","2.5","2.8","3.2","3.5","4.0","4.5","5.0","5.6","6.3","7.1","8.0","9.0","10","11","13","14","16","18","20","22"]
ISOS = ["AUTO","100","125","160","200","250","320","400","500","640","800","1000","1250","1600","2000","2500","3200","4000","5000","6400","8000","10000","12800","25600"]
FOCUS = ["AF-S","AF-C","DMF","MF"]
EXPOSURE_MODES = ["Program Auto","Aperture","Shutter","Manual"]
SHOOT_MODES = ["still","movie"]
APIS = ["getEvent","getVersions","getAvailableApiList","getMethodTypes","startLiveview","startLiveviewWithSize","stopLiveview",
        "setShutterSpeed","setFNumber","setIsoSpeedRate","setExposureCompensation","setWhiteBalance","setFocusMode","setExposureMode",
        "setShootMode","actHalfPressShutter","cancelHalfPressShutter","actTakePicture","startMovieRec","stopMovieRec",
        "setTouchAFPosition","cancelTouchAFPosition"]

class Camera:
    def __init__(self):
        self.lock = threading.Condition()
        self.version = 0
        self.status = "IDLE"
        self.shutter, self.fnumber, self.iso = "1/50", "2.8", "800"
        self.ev = 0
        self.wb_mode, self.color_temp = "Color Temperature", 5600
        self.focus_mode, self.focus_status = "AF-C", "Not Focusing"
        self.exposure_mode, self.shoot_mode = "Manual", "movie"
        self.touch_set, self.touch = False, [50.0, 50.0]
        self.rec_start = None
        self.shots = 0
        self.last_pictures = []
        self.changed = set()

    def bump(self, *keys):
        with self.lock:
            self.version += 1
            self.changed |= set(keys)
            self.lock.notify_all()

    def recording_time(self):
        return int(time.time() - self.rec_start) if self.rec_start else 0

    def event_items(self, only=None):
        def want(k): return only is None or k in only
        items = [None] * 40
        if want("availableApiList"): items[0] = {"type":"availableApiList","names":APIS}
        if want("cameraStatus"): items[1] = {"type":"cameraStatus","cameraStatus":self.status}
        if want("liveviewStatus"): items[3] = {"type":"liveviewStatus","liveviewStatus":True}
        if want("storageInformation"): items[10] = [{"type":"storageInformation","storageInformation":[{"numberOfRecordableImages":812,"recordableTime":47,"storageID":"Memory Card 1","storageDescription":"","recordTarget":True}]}]
        if want("exposureMode"): items[18] = {"type":"exposureMode","currentExposureMode":self.exposure_mode,"exposureModeCandidates":EXPOSURE_MODES}
        if want("shootMode"): items[21] = {"type":"shootMode","currentShootMode":self.shoot_mode,"shootModeCandidates":SHOOT_MODES}
        if want("exposureCompensation"): items[25] = {"type":"exposureCompensation","currentExposureCompensation":self.ev,"maxExposureCompensation":15,"minExposureCompensation":-15,"stepIndexOfExposureCompensation":1}
        if want("fNumber"): items[27] = {"type":"fNumber","currentFNumber":self.fnumber,"fNumberCandidates":FNUMBERS}
        if want("focusMode"): items[28] = {"type":"focusMode","currentFocusMode":self.focus_mode,"focusModeCandidates":FOCUS}
        if want("isoSpeedRate"): items[29] = {"type":"isoSpeedRate","currentIsoSpeedRate":self.iso,"isoSpeedRateCandidates":ISOS}
        if want("shutterSpeed"): items[32] = {"type":"shutterSpeed","currentShutterSpeed":self.shutter,"shutterSpeedCandidates":SHUTTERS}
        if want("whiteBalance"): items[33] = {"type":"whiteBalance","currentWhiteBalanceMode":self.wb_mode,"currentColorTemperature":self.color_temp,"checkAvailability":True}
        if want("touchAFPosition"): items[34] = {"type":"touchAFPosition","currentSet":self.touch_set,"currentTouchCoordinates":self.touch}
        if want("focusStatus"): items[35] = {"type":"focusStatus","focusStatus":self.focus_status}
        if want("batteryInfo"): items[36] = {"type":"batteryInfo","batteryInfo":[{"batteryID":"","status":"Active","additionalStatus":"","levelNumer":3,"levelDenom":4,"description":""}]}
        if want("recordingTime"): items[37] = {"type":"recordingTime","recordingTime":self.recording_time()}
        if want("numberOfShots"): items[38] = {"type":"numberOfShots","numberOfShots":self.shots}
        if want("takePicture") and self.last_pictures: items[5] = {"type":"takePicture","takePictureUrl":self.last_pictures}
        return items

CAM = Camera()

def rec_ticker():
    while True:
        time.sleep(1)
        if CAM.rec_start: CAM.bump("recordingTime")
threading.Thread(target=rec_ticker, daemon=True).start()

# ---------- frame rendering ----------
FONT = None
for cand in ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/SFNSMono.ttf", "/Library/Fonts/Arial.ttf"]:
    try: FONT = ImageFont.truetype(cand, 22); break
    except Exception: pass

def exposure_gain():
    try: sh = eval(CAM.shutter.replace('"', '')) if '/' in CAM.shutter or CAM.shutter.replace('"','').isdigit() else 1/50
    except Exception: sh = 1/50
    iso = 800 if CAM.iso == "AUTO" else float(CAM.iso)
    fn = float(CAM.fnumber)
    ev = math.log2((sh * iso) / (fn * fn)) - math.log2((1/50 * 800) / (2.8 * 2.8)) + CAM.ev / 3
    return 2 ** (ev * 0.5)

def render_frame(t, w=1024, h=680):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    gain = exposure_gain()
    warm = max(0, min(1, (CAM.color_temp - 2500) / 7400)) if CAM.wb_mode == "Color Temperature" else 0.45
    for y in range(0, h, 4):
        k = y / h
        r = int(min(255, (40 + 120 * k) * gain * (0.8 + 0.4 * warm)))
        g = int(min(255, (60 + 90 * k) * gain))
        b = int(min(255, (110 + 60 * (1 - k)) * gain * (1.2 - 0.4 * warm)))
        d.rectangle([0, y, w, y + 4], fill=(r, g, b))
    # a bright "sun" that clips (for zebras) and a moving subject (for peaking)
    sx, sy = w * 0.78, h * 0.22
    d.ellipse([sx - 70, sy - 70, sx + 70, sy + 70], fill=(int(min(255, 250 * gain)),) * 3)
    cx = w * 0.5 + math.sin(t * 0.8) * w * 0.25
    cy = h * 0.6 + math.cos(t * 0.5) * h * 0.1
    for i in range(6):
        c = int(min(255, (90 + 25 * i) * gain))
        d.rectangle([cx - 120 + i * 20, cy - 80 + i * 14, cx + 120 - i * 20, cy + 80 - i * 14], outline=(c, c, c), width=3)
    d.text((24, h - 44), f"SIM  {CAM.shutter}  F{CAM.fnumber}  ISO {CAM.iso}  {CAM.focus_mode}", fill=(255, 255, 255), font=FONT)
    buf = io.BytesIO(); img.save(buf, "JPEG", quality=80); return buf.getvalue()

def liveview_packet(seq, jpeg):
    ts = int(time.time() * 1000) & 0xFFFFFFFF
    common = struct.pack(">BBHI", 0xFF, 0x01, seq & 0xFFFF, ts)
    size = len(jpeg); pad = (4 - size % 4) % 4
    ph = b"\x24\x35\x68\x79" + bytes([size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF, pad]) + bytes(120)
    return common + ph + jpeg + bytes(pad)

# ---------- HTTP ----------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *args): pass

    def do_GET(self):
        if self.path == "/dd.xml":
            host = self.headers.get("Host", f"127.0.0.1:{self.server.server_port}")
            body = f"""<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:av="urn:schemas-sony-com:av"><device>
<friendlyName>ILCE-6400 (sim)</friendlyName><modelName>ILCE-6400</modelName>
<av:X_ScalarWebAPI_DeviceInfo><av:X_ScalarWebAPI_ServiceList>
<av:X_ScalarWebAPI_Service><av:X_ScalarWebAPI_ServiceType>camera</av:X_ScalarWebAPI_ServiceType><av:X_ScalarWebAPI_ActionList_URL>http://{host}/sony</av:X_ScalarWebAPI_ActionList_URL></av:X_ScalarWebAPI_Service>
</av:X_ScalarWebAPI_ServiceList></av:X_ScalarWebAPI_DeviceInfo></device></root>""".encode()
            self.send_response(200); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/liveview"):
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream"); self.send_header("Connection", "close"); self.end_headers()
            seq, t0 = 0, time.time()
            try:
                while True:
                    self.wfile.write(liveview_packet(seq, render_frame(time.time() - t0))); self.wfile.flush()
                    seq += 1; time.sleep(1.0 / self.server.fps)
            except (BrokenPipeError, ConnectionResetError): pass
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        method, params, rid = req.get("method"), req.get("params", []), req.get("id", 1)
        try: result = self.dispatch(method, params)
        except ApiError as e: result = {"error": [e.code, e.msg]}
        if "error" not in result: result = {"result": result}
        result["id"] = rid
        body = json.dumps(result).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def dispatch(self, m, p):
        host = self.headers.get("Host", f"127.0.0.1:{self.server.server_port}")
        if m == "getAvailableApiList": return [APIS]
        if m == "getVersions": return [["1.0","1.1","1.2","1.3"]]
        if m == "getMethodTypes": return []
        if m == "getEvent":
            if p and p[0]:
                with CAM.lock:
                    v0 = CAM.version; deadline = time.time() + 8
                    while CAM.version == v0 and time.time() < deadline: CAM.lock.wait(timeout=deadline - time.time())
                    if CAM.version == v0: raise ApiError(2, "Timeout")
                    changed = set(CAM.changed); CAM.changed.clear()
                return CAM.event_items(changed)
            return CAM.event_items()
        if m in ("startLiveview", "startLiveviewWithSize"): return [f"http://{host}/liveview"]
        if m == "stopLiveview": return []
        if m == "setShutterSpeed": self.check(p[0], SHUTTERS); CAM.shutter = p[0]; CAM.bump("shutterSpeed"); return [0]
        if m == "setFNumber": self.check(p[0], FNUMBERS); CAM.fnumber = p[0]; CAM.bump("fNumber"); return [0]
        if m == "setIsoSpeedRate": self.check(p[0], ISOS); CAM.iso = p[0]; CAM.bump("isoSpeedRate"); return [0]
        if m == "setExposureCompensation":
            if not -15 <= int(p[0]) <= 15: raise ApiError(3, "Illegal Argument")
            CAM.ev = int(p[0]); CAM.bump("exposureCompensation"); return [0]
        if m == "setWhiteBalance":
            CAM.wb_mode = p[0]
            if p[1]: CAM.color_temp = int(p[2])
            CAM.bump("whiteBalance"); return [0]
        if m == "setFocusMode": self.check(p[0], FOCUS); CAM.focus_mode = p[0]; CAM.bump("focusMode"); return [0]
        if m == "setExposureMode": self.check(p[0], EXPOSURE_MODES); CAM.exposure_mode = p[0]; CAM.bump("exposureMode"); return [0]
        if m == "setShootMode": self.check(p[0], SHOOT_MODES); CAM.shoot_mode = p[0]; CAM.bump("shootMode"); return [0]
        if m == "actHalfPressShutter":
            CAM.focus_status = "Focusing"; CAM.bump("focusStatus")
            def done(): time.sleep(0.6); CAM.focus_status = "Focused"; CAM.bump("focusStatus")
            threading.Thread(target=done, daemon=True).start(); return []
        if m == "cancelHalfPressShutter": CAM.focus_status = "Not Focusing"; CAM.bump("focusStatus"); return []
        if m == "actTakePicture":
            if CAM.status != "IDLE": raise ApiError(40400, "Shooting Fail")
            CAM.status = "StillCapturing"; CAM.bump("cameraStatus"); time.sleep(0.4)
            CAM.shots += 1; CAM.last_pictures = [f"http://{host}/postview/{CAM.shots}.jpg"]
            CAM.status = "IDLE"; CAM.bump("cameraStatus", "numberOfShots", "takePicture"); return [CAM.last_pictures]
        if m == "startMovieRec":
            if CAM.status != "IDLE": raise ApiError(1, "Not Available Now")
            CAM.status = "MovieRecording"; CAM.rec_start = time.time(); CAM.bump("cameraStatus", "recordingTime"); return [0]
        if m == "stopMovieRec":
            if CAM.status != "MovieRecording": raise ApiError(1, "Not Available Now")
            CAM.status = "IDLE"; CAM.rec_start = None; CAM.bump("cameraStatus", "recordingTime"); return [f"http://{host}/thumb.jpg"]
        if m == "setTouchAFPosition":
            CAM.touch = [float(p[0]), float(p[1])]; CAM.touch_set = True; CAM.focus_status = "Focused"
            CAM.bump("touchAFPosition", "focusStatus"); return [{"AFResult": True, "AFType": "Touch"}]
        if m == "cancelTouchAFPosition": CAM.touch_set = False; CAM.bump("touchAFPosition"); return []
        raise ApiError(12, "No Such Method")

    def check(self, v, allowed):
        if v not in allowed: raise ApiError(3, "Illegal Argument")

class ApiError(Exception):
    def __init__(self, code, msg): self.code, self.msg = code, msg

# ---------- SSDP ----------
def ssdp_responder(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except Exception: pass
    s.bind(("", 1900))
    mreq = struct.pack("4sl", socket.inet_aton("239.255.255.250"), socket.INADDR_ANY)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    while True:
        data, addr = s.recvfrom(2048)
        if b"M-SEARCH" in data and b"ScalarWebAPI" in data:
            # answer with an address the searcher can reach
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); probe.connect(addr); my_ip = probe.getsockname()[0]; probe.close()
            resp = (f"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: http://{my_ip}:{port}/dd.xml\r\n"
                    f"SERVER: UPnP/1.0 SonyImagingDevice/1.0\r\nST: urn:schemas-sony-com:service:ScalarWebAPI:1\r\nUSN: uuid:sim::urn:schemas-sony-com:service:ScalarWebAPI:1\r\n\r\n")
            s.sendto(resp.encode(), addr)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--port", type=int, default=8080); ap.add_argument("--fps", type=float, default=24); ap.add_argument("--no-ssdp", action="store_true")
    a = ap.parse_args()
    if not a.no_ssdp: threading.Thread(target=ssdp_responder, args=(a.port,), daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", a.port), Handler); srv.fps = a.fps; srv.daemon_threads = True
    print(f"camerasim: JSON-RPC at http://127.0.0.1:{a.port}/sony/camera, liveview /liveview, SSDP {'off' if a.no_ssdp else 'on'}")
    srv.serve_forever()
