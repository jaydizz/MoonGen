#!/usr/bin/bash
DIR="/home/cff29/benchmarks/$1_$2"
SIZE="$2"
ssh jd-ma2 "mkdir $DIR"
#declare -a arr=(0.1 0.5 1 2 3 4 5 6 7 8 9)
declare -a arr=(0.5 1 1.5 2.0 2.5 3.0 3.5 4.0 4.5 5.0 5.5 6.0)

function_to_fork() {
   ssh jd-ma2 " echo 'framesize=$SIZE' > $DIR/runfile ; sleep 30; perf record -C 1 -o $DIR/run_$1.raw -F 150 -a -g -- sleep 120 ; sleep 10; echo '${1}Mpps;run_$1.folded' >> $DIR/runfile"
}
for i in "${arr[@]}"
do
	function_to_fork $i &
 	./build/MoonGen ./jd-ma/benchmark.lua --size=60 --rate=${i}Mp/s --flows=1 --time=180 0 1
done
	

