@echo off
dastub CARD.IMG > STUB.TXT
daping > T_STAT.TXT
daping /M > T_MATRIX.TXT
daping /L 0 > T_LBA0.TXT
daping /L 63 > T_LBA63.TXT
daping /B > T_BENCH.TXT
daping /C 5 0 > T_CYL.TXT
