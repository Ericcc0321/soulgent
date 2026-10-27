# Calls Orca's local communication port (for read-only queries): python3 -I tools/dev/orca_call.py terminal.list '{"includeVisualLayouts":true}'
import json,os,socket,sys,uuid
m=json.load(open(os.path.expanduser('~/Library/Application Support/orca/orca-runtime.json')))
ep=[t for t in m['transports'] if t['kind']=='unix'][0]['endpoint']
s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(ep)
s.sendall((json.dumps({'id':str(uuid.uuid4()),'authToken':m['authToken'],'method':sys.argv[1],'params':json.loads(sys.argv[2] if len(sys.argv)>2 else '{}')})+'\n').encode())
buf=b''
while True:
    c=s.recv(65536)
    if not c: break
    buf+=c
    for line in buf.split(b'\n'):
        try:
            j=json.loads(line)
            if 'result' in j or 'error' in j: print(json.dumps(j,ensure_ascii=False)); sys.exit()
        except Exception: pass
