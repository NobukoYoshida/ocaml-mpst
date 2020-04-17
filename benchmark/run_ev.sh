#!/bin/bash
cd "$(dirname "$0")"
if [ $# -eq 0 ]
then
    QUOTA=10s
else
	QUOTA=$1
fi
echo running benchmark with quota of $QUOTA seconds.
set -e
set -v

dune build @ev/all

../_build/default/benchmark/ev/ev_pingpong.exe +time cycles alloc gc percentage speedup samples -quota $QUOTA -sexp >ev/results/table_sexp.txt
