#!/usr/bin/env python3
"""Check unchanged protocol-6 fixture admission/save/restore; no modern acceptance."""
from pathlib import Path
import json,subprocess,hashlib
root=Path(__file__).resolve().parents[3]; base=root/'docs/acceptance/modern-editor'; catalog=json.loads((base/'fixtures.json').read_text())['fixtures']
binary=root/'.build/debug/editor-bridge'
p=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
def call(value):
    p.stdin.write(json.dumps(value,ensure_ascii=False)+'\n');p.stdin.flush()
    return json.loads(p.stdout.readline())
receipt={'qualification':'Unchanged protocol-6 body admission/save/restore only; modern protocol7 semantics and host acceptance remain pending.','baseCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'checks':[],'sourceHashes':{}}
try:
    for name in ['unicode','mixed','nested','wide-table','long','legacy-mixed','legacy-collision','legacy-5001']:
        info=catalog[name]; data=(base/info['path']).read_bytes(); document=json.loads(data)
        request={'command':'create','session':name,'actorID':'a','collaborationVersion':6,'documentID':info['documentID'],'epoch':info['epoch'],'blocks':document['blocks']}
        result=call(request);assert result['ok'],(name,result)
        assert result['value']['blocks']==document['blocks'],name
        saved=call({'command':'save','session':name});assert saved['ok'],name
        restored=call({'command':'restore','session':name+'-restored','actorID':'a','snapshot':saved['value']});assert restored['ok'],(name,restored)
        assert restored['value']['blocks']==document['blocks'],name
        assert not restored['value']['canUndo'] and not restored['value']['canRedo'],name
        receipt['checks'].append({'fixture':name,'admission':'passed','saveRestore':'passed','blocksPreserved':len(document['blocks']),'sha256':hashlib.sha256(data).hexdigest()})
        print(name,'admit/save/restore passed',flush=True)
    invalid=json.loads((base/catalog['unsupported-inline']['path']).read_text())
    result=call({'command':'create','session':'unadmittable','actorID':'a','collaborationVersion':6,'documentID':'st140-invalid','epoch':'fixture-epoch','blocks':invalid['blocks']})
    assert not result['ok'];receipt['checks'].append({'fixture':'unsupported-inline','admission':'rejected as expected','error':result['error']})
    result=call({'command':'create','session':'protocol7-old-client','actorID':'a','collaborationVersion':7,'documentID':'st140-rejected7','epoch':'fixture-epoch','blocks':[]})
    assert not result['ok'];receipt['checks'].append({'fixture':'old client protocol7 request','admission':'rejected as expected','error':result['error']})
    for path in sorted((root/'Sources/BlockEditorCore').glob('*.swift')):receipt['sourceHashes'][str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
    (base/'legacy-input-checks.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
finally:
    p.stdin.close();p.wait(timeout=30)
print('8 real legacy body admission/save/restore passes; two expected rejections. No modern runtime claims.')
