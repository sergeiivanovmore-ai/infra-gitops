#!/usr/bin/env python3
import json, sys
src, md_path, js_path, ts, node, checks = sys.argv[1:7]
rows = []
for line in open(src, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    parts = (line.split('|') + [''] * 5)[:5]
    rows.append(dict(severity=parts[0], id=parts[1], summary=parts[2], metric=parts[3], detail=parts[4]))
order = {'p1': 0, 'ci': 1, 'p2': 2, 'log': 3}
rows.sort(key=lambda r: order.get(r['severity'], 9))
bad = [r for r in rows if r['severity'] in ('p1', 'ci')]
overall = 'P1' if bad else ('P2' if any(r['severity'] == 'p2' for r in rows) else 'OK')
labels = {'p1': 'P1 - будит', 'ci': 'CI - красный прогон', 'p2': 'P2 - в ленту', 'log': 'в лог'}
out = ['# Отчёт о здоровье VPS', '', '- время: ' + ts, '- узел: ' + node,
       '- итог: ' + overall, '- проверок: ' + checks + ', отклонений: ' + str(len(rows)), '']
for sev in ('p1', 'ci', 'p2', 'log'):
    group = [r for r in rows if r['severity'] == sev]
    if not group:
        continue
    out.append('## ' + labels[sev])
    out.append('')
    for r in group:
        out.append('- ' + r['id'] + ' — ' + r['summary'] + ' — ' + r['metric'])
        if r['detail']:
            out.append('  - шаги: ' + r['detail'])
    out.append('')
text = '\n'.join(out)
open(md_path, 'w', encoding='utf-8').write(text + '\n')
json.dump({'generated': ts, 'node': node, 'overall': overall, 'checks': int(checks),
           'findings': rows}, open(js_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
sys.stdout.write(text + '\n')
sys.exit(1 if bad else 0)