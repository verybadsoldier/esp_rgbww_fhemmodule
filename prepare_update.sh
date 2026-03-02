#!/bin/bash
rm controls_espledcontroller.txt
find ./FHEM -type f \( ! -iname ".*" \) -print0 | while IFS= read -r -d '' f; 
  do
   out="UPD "$(stat -c %y  $f | cut -d. -f1 | awk '{printf "%s_%s",$1,$2}')" "$(stat -c %s $f)" ${f}"
   echo ${out//.\//} >> controls_espledcontroller.txt
done

# CHANGED file
echo "LedController last change:" > CHANGED
echo $(date +"%Y-%m-%d") >> CHANGED
echo " - $(git log -1 --pretty=%B)" >> CHANGED






