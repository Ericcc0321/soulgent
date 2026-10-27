# Lists the tab titles in each Orca workspace layout, and the number of orphan terminals (for debugging the spotlight's "no match for tabs"): python3 -I tools/dev/orca_layouts.py
import json, os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
out = subprocess.run([sys.executable, '-I', os.path.join(here, 'orca_call.py'), 'terminal.list', '{"includeVisualLayouts":true}'],
                     capture_output=True, text=True).stdout
j = json.loads(out)['result']
def groups(n, acc):
    if isinstance(n, dict):
        if isinstance(n.get('tabs'), list): acc.append(n)
        for v in n.values(): groups(v, acc)
    elif isinstance(n, list):
        for v in n: groups(v, acc)
    return acc
for l in j.get('visualLayouts', []):
    print(l.get('worktreePath', '').split('/')[-1], [[t.get('title') for t in g['tabs']] for g in groups(l.get('root'), [])])
orph = [t for t in j['terminals'] if t.get('orphaned')]
print('orphaned', len(orph), 'of', len(j['terminals']))
for t in orph: print('  orphan', t['worktreePath'].split('/')[-1], t['handle'])
