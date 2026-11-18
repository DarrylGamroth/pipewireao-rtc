# Render the common half-plane mask at pixel boundaries.
set contour base
set cntrparam levels discrete 0.5
unset surface
set table 'mask.dat'
splot 'seed-17.dat' using 1:2:7
unset table
set surface
unset contour

set terminal pngcairo size 1650,940 enhanced font 'DejaVu Sans,14'
set output 'figure.png'
set multiplot
set label 1 'SPIDERS   /   SCC mode bank comparison' at screen .06,.955 font ',26'
set label 2 'Unfringed intensity / stellar peak   ·   normal DM flat   ·   LLOWFS active   ·   outlined dark-hole region   ·   detector axes in λ/D' at screen .06,.91
set xrange [-14.06:14.06]
set yrange [-14.06:14.06]
set xtics (-10,0,10) nomirror out scale .35
set ytics (-10,0,10) nomirror out scale .35
set border 3
set tics font ',11'
unset key
array titles[4] = ['LLOWFS only', sprintf('%s SCC modes',ARG2), sprintf('%s SCC modes',ARG3), sprintf('%s minus %s  (×10^{-6})',ARG3,ARG2)]
array left[4] = [.060, .292, .524, .765]
limit = int(ARG1)
load 'means.gp'
set style textbox opaque margins .5,.35 fillcolor rgb '#ffffff' noborder

do for [row=1:2] {
    seed = row == 1 ? 17 : 73
    filename = sprintf('seed-%d.dat',seed)
    bottom = row == 1 ? .505 : .122
    do for [col=1:4] {
        set lmargin at screen left[col]
        set rmargin at screen left[col]+.1823
        set bmargin at screen bottom
        set tmargin at screen bottom+.32
        set title (row == 1 ? titles[col] : '') font ',17'
        set ylabel (col == 1 ? sprintf('Seed %d',seed) : '')
        set format y (col == 1 ? '%g' : '')
        set format x (row == 2 ? '%g' : '')
        unset colorbox
        if (col == 4) {
            unset logscale cb
            set palette defined (-1 '#225ea8',0 '#f7f7f7',1 '#b2182b')
            set cbrange [-limit:limit]
            if (row == 2) {
                set colorbox horizontal user origin .77,.054 size .175,.012
                set cbtics (sprintf('darker  −%d',limit) -limit,'0' 0,sprintf('+%d  brighter',limit) limit) scale 0
            }
        } else {
            set logscale cb
            set cbrange [8e-7:1.5e-4]
            set palette defined (0 '#000004',.2 '#3b0f70',.4 '#8c2981',.6 '#de4968',.8 '#fe9f6d',1 '#fcfdbf')
            if (row == 2 && col == 3) {
                set colorbox horizontal user origin .18,.054 size .39,.012
                set cbtics ('10^{-6}' 1e-6,'10^{-5}' 1e-5,'10^{-4}' 1e-4) scale 0
            }
        }
        value = mask_means[4*(row-1)+col]
        caption = col == 4 ? sprintf('Mask mean   %+.1f%%',value) : sprintf('Mask mean   %.3f ×10^{-5}',value)
        set label 3 caption at graph .035,.075 font ',12' textcolor rgb '#142537' boxed front
        plot filename using 1:2:(column(col+2)) with image, 'mask.dat' using 1:2 with lines lw 2 lc rgb '#25494a', \
            'mask.dat' using 1:2 with lines lw 1.1 lc rgb '#a9e2df'
        unset label 1
        unset label 2
    }
}
unset multiplot
unset output
