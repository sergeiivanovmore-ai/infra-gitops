#!/bin/bash
# модуль проверок: пишет находки в $FIND, в stdout — новое число проверок
# --- 4. диск ---
CHECKS=$((CHECKS+1))
DPATH=$(th disk_path /)
PCT=$(df -P "$DPATH" | awk 'NR==2{gsub("%","",$5);print $5+0}')
INODE=$(df -Pi "$DPATH" | awk 'NR==2{gsub("%","",$5);print $5+0}')
FREE=$(df -Ph "$DPATH" | awk 'NR==2{print $4}')
WARN=$(th disk_warn_percent 70); CRIT=$(th disk_used_percent 80); INOC=$(th inode_used_percent 85)
if [ "${PCT:-0}" -ge "$CRIT" ]; then
  add p1 disk "диск заполнен выше порога" "занято: ${PCT}% (порог ${CRIT}%), свободно ${FREE}" "df -h $DPATH; du -x -h -d1 / | sort -h | tail"
elif [ "${PCT:-0}" -ge "$WARN" ]; then
  add p2 disk "диск приближается к порогу" "занято: ${PCT}% (порог ${WARN}%), свободно ${FREE}" "df -h $DPATH"
fi
if [ "${INODE:-0}" -ge "$INOC" ]; then
  add p2 disk "много использованных inode" "inode: ${INODE}% (порог ${INOC}%)" "df -i $DPATH"
fi
echo "$CHECKS"