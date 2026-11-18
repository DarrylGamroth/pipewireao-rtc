# Run from the evidence directory after paired.jl.
set terminal pngcairo size 1370,980 font 'DejaVu Sans,13'
set output 'recovery.png'
set datafile separator comma
set datafile columnheaders
set multiplot
set label 1 'SPIDERS   /   Multirate recovery on one mirror' at screen .105,.955 font ',24'
set label 2 '112 SCC modes · seed 17 · 100 Hz LLOWFS · 33⅓ Hz SCC · 0.1 s bins in model time' at screen .106,.92
set lmargin at screen .115
set rmargin at screen .965
set xrange [0:25.5]
set xtics 2.5 nomirror out scale .4
set ytics nomirror out scale .4
set border 3 lc rgb '#65717c'
set grid ytics lc rgb '#e0e3e8'
set key horizontal top left samplen 2 font ',11'
set style line 1 lw 2 lc rgb '#b34426'
set style line 3 lw 2 dt 4 lc rgb '#117947'
set style line 2 lw 1.8 dt 2 lc rgb '#1b6590'
set object 1 rect from 10.5,graph 0 to 12,graph 1 behind fc rgb '#d7edf3' fs solid 0.9 noborder
set arrow 1 from 16.51,graph 0 to 16.51,graph 1 nohead lc rgb '#b77c22' dt 3
set label 3 'SCC paused' at first 11.25,screen .87 center font ',11'
set arrow 2 from 18,graph 0 to 18,graph 1 nohead lc rgb '#117947' dt 3
set label 5 'Reset' at first 18.45,screen .87 center font ',11'
set label 4 'DM limit pulse' at first 16.51,screen .87 center font ',11'
set tmargin at screen .85
set bmargin at screen .615
set format x ''
set ylabel "LLOWFS residual\nRMS (nm OPD)" noenhanced
set logscale y
set format y '%g'
plot 'timeline.csv' using 1:5 with lines ls 1 title 'Reference restored', '' using 1:6 with lines ls 2 title 'Uninterrupted', 'protective-timeline.csv' using 1:3 with lines ls 3 title 'Protective reset'
unset label 1
unset label 2
unset label 3
unset label 4
unset label 5
unset key
set tmargin at screen .58
set bmargin at screen .345
set ylabel "Mean unfringed contrast"
set format y '10^{%L}'
set ytics autofreq
plot 'timeline.csv' using 1:3 with lines ls 1, '' using 1:4 with lines ls 2, 'protective-timeline.csv' using 1:2 with lines ls 3
set tmargin at screen .305
set bmargin at screen .09
set format x '%g'
set xlabel 'Model time (s)'
set ylabel "Largest DM step\n(native units)" noenhanced
set format y '%g'
plot 'timeline.csv' using 1:8 with lines ls 1, '' using 1:9 with lines ls 2, 'protective-timeline.csv' using 1:4 with lines ls 3
unset multiplot
unset output
